import 'dart:async';
import 'dart:convert';
import 'dart:io';

// Downloading a Spotify playlist, by driving spotdl.
//
// What these downloaders actually do is worth stating, because it shapes
// everything here: nobody decrypts Spotify. Spotify's audio is DRM-protected and
// untouched by this. What happens is that the *metadata* for a playlist is read
// from Spotify, each track is then found on YouTube, downloaded, transcoded, and
// finally tagged with the Spotify metadata and cover art. A "Spotify downloader"
// is a YouTube downloader wearing Spotify's tags.
//
// spotdl already does all of that, so this drives it rather than reimplementing
// it. The reason is not the line count: YouTube breaks audio extraction every few
// weeks, and spotdl and yt-dlp absorb that upstream. A reimplementation here
// would mean owning that maintenance for no gain.
//
// spotdl is not bundled — the user installs it, exactly as with yt-dlp.

/// One line of spotdl's output, understood.
sealed class SpotdlEvent {
  const SpotdlEvent();
}

/// How many tracks the query turned out to hold.
class SpotdlTotal extends SpotdlEvent {
  const SpotdlTotal(this.count, {this.name = ''});

  final int count;
  final String name;
}

class SpotdlDownloaded extends SpotdlEvent {
  const SpotdlDownloaded(this.track);

  final String track;
}

/// Already on disk, so spotdl left it alone.
class SpotdlSkipped extends SpotdlEvent {
  const SpotdlSkipped(this.track, {this.reason = ''});

  final String track;
  final String reason;
}

class SpotdlFailed extends SpotdlEvent {
  const SpotdlFailed(this.track, this.error);

  final String track;
  final String error;
}

/// Anything else, kept for the log pane.
///
/// Nothing is thrown away: when spotdl disagrees with what this code expects —
/// a renamed flag, a new message shape — the log is what makes it visible
/// instead of leaving a silent stall.
class SpotdlLog extends SpotdlEvent {
  const SpotdlLog(this.line);

  final String line;
}

/// What to write to disk.
enum DownloadFormat {
  mp3('mp3', 'MP3', 'Plays everywhere. Transcoded, so a little quality is lost.'),
  m4a('m4a', 'M4A', 'Usually the original YouTube audio, no transcode.'),
  opus('opus', 'Opus', 'Best quality per byte; some old players cannot read it.'),
  flac('flac', 'FLAC', 'Lossless container around lossy audio — bigger, not better.');

  const DownloadFormat(this.flag, this.label, this.note);

  final String flag;
  final String label;
  final String note;
}

/// The arguments for one download.
///
/// Pure, so the command line is inspectable and testable. Flags follow spotdl
/// v4's CLI; [SpotdlClient.version] is what confirms the binary is there, and any
/// disagreement about a flag surfaces as spotdl's own error text in the log
/// rather than as a silent failure.
/// The search providers, in the order spotdl should try them.
///
/// Not spotdl's default, which is `youtube-music` alone — and that provider is
/// currently broken: it builds its client as `YTMusic(language="de")`, and with
/// ytmusicapi 1.12 a German-language search parses to nothing. Measured on the
/// same query: 0 results in German, 60 in English, so every track failed with
/// "returned no usable results after 3 attempts". `--audio` takes a fallback
/// chain, so naming both means a dead first provider costs a retry rather than
/// the whole run.
const defaultAudioProviders = ['youtube-music', 'youtube'];

List<String> spotdlArguments({
  required String url,
  required String outputDirectory,
  DownloadFormat format = DownloadFormat.mp3,
  String bitrate = 'auto',
  String? cookiesFile,
  int threads = 4,
  bool overwriteExisting = false,
  List<String> audioProviders = defaultAudioProviders,
}) => [
  'download',
  url,
  // The template decides the filenames; {output-ext} follows --format.
  '--output',
  '$outputDirectory/{artists} - {title}.{output-ext}',
  '--format',
  format.flag,
  '--bitrate',
  bitrate,
  '--threads',
  '$threads',
  if (audioProviders.isNotEmpty) ...['--audio', ...audioProviders],
  // Skip rather than redownload: the usual reason to run this twice is to pick
  // up what a playlist gained since last time.
  '--overwrite',
  overwriteExisting ? 'force' : 'skip',
  // Without this, failures are summarised and the detail is lost.
  '--print-errors',
  if (cookiesFile != null && cookiesFile.isNotEmpty) ...[
    '--cookie-file',
    cookiesFile,
  ],
];

/// Whether a failure is YouTube refusing to serve audio without a sign-in.
///
/// Two ways to tell. yt-dlp's own wording — which spotdl usually swallows — and
/// spotdl's bare `YT-DLP download error -`, printed with nothing after the dash
/// because it never captured the reason. Verified against the real pair: yt-dlp
/// answered "Sign in to confirm you're not a bot" for the same video that
/// reached the app as an empty error.
bool looksLikeBotWall(String text) {
  final line = text.toLowerCase();
  // The apostrophe in yt-dlp's message is a typographic one, so it is not
  // matched on.
  if (line.contains('not a bot') || line.contains('sign in to confirm')) {
    return true;
  }
  if (line.contains('--cookies') || line.contains('cookie-file')) return true;
  return line.contains('yt-dlp download error');
}

/// Removes terminal colour codes, which spotdl emits when it thinks it has a
/// terminal. Without this every pattern below has to match around escape
/// sequences.
String stripAnsi(String line) =>
    line.replaceAll(RegExp(r'\x1B\[[0-9;?]*[a-zA-Z]'), '');

final _total = RegExp(r'Found (\d+) songs?(?: in (.+?))?(?:\s*\(.*\))?$');
final _downloaded = RegExp(r'^Downloaded\s+"(.+?)"');
final _skipped = RegExp(r'^Skipping\s+(.+?)\s*\((.+?)\)\s*$');
final _lookupFailed = RegExp(r'^LookupError:\s*(?:No results found for song:\s*)?(.+)$');
final _searchFailed = RegExp(
  r'^(?:YouTube Music|YouTube|SoundCloud|Bandcamp|Piped) returned no usable '
  r'results for (.+?)(?:\s+(?:after|on attempt).*)?$',
);
final _providerFailed = RegExp(r'^(\w*(?:Error|Exception)):\s*(.+)$');

/// Reads one line of spotdl output.
///
/// Deliberately forgiving: an unrecognised line becomes a [SpotdlLog] rather
/// than an error, because spotdl's wording changes between versions and a parser
/// that insists on knowing every line would break on an upgrade.
SpotdlEvent parseSpotdlLine(String raw) {
  final line = stripAnsi(raw).trim();
  if (line.isEmpty) return const SpotdlLog('');

  if (_total.firstMatch(line) case final match?) {
    return SpotdlTotal(
      int.parse(match.group(1)!),
      name: match.group(2)?.trim() ?? '',
    );
  }
  if (_downloaded.firstMatch(line) case final match?) {
    return SpotdlDownloaded(match.group(1)!.trim());
  }
  if (_skipped.firstMatch(line) case final match?) {
    return SpotdlSkipped(
      match.group(1)!.trim(),
      reason: match.group(2)!.trim(),
    );
  }
  if (_lookupFailed.firstMatch(line) case final match?) {
    return SpotdlFailed(match.group(1)!.trim(), 'no match found on YouTube');
  }
  // Counted rather than logged: a whole playlist failing this way showed
  // "0 downloaded" with nothing failed and no reason on screen, which is exactly
  // what a real run looked like.
  if (_searchFailed.firstMatch(line) case final match?) {
    return SpotdlFailed(
      match.group(1)!.trim(),
      'the search returned nothing usable',
    );
  }
  if (_providerFailed.firstMatch(line) case final match?) {
    // spotdl prints "YT-DLP download error -" and stops, having never captured
    // yt-dlp's reason, so the dash is part of the detail rather than the detail
    // being empty — which is what a test caught here. Trim the dangling
    // punctuation and say the reason is missing.
    final detail = match.group(2)!.trim().replaceAll(RegExp(r'[\s:-]+$'), '');
    final reasonless = detail.isEmpty ||
        RegExp(r'(error|exception)$', caseSensitive: false).hasMatch(detail);
    return SpotdlFailed(
      '',
      [
        match.group(1),
        if (detail.isNotEmpty) ': $detail',
        if (reasonless) ' (spotdl gave no detail)',
      ].join(),
    );
  }
  return SpotdlLog(line);
}

/// A process that is running, reduced to what a download needs.
///
/// Wrapping `Process` rather than using it directly is what makes the whole
/// client testable: a fake supplies a stream of lines and an exit code, with no
/// binary involved.
class RunningProcess {
  RunningProcess({
    required this.lines,
    required this.exitCode,
    required this.kill,
  });

  /// stdout and stderr merged, one line at a time — spotdl reports progress on
  /// both and the order between them matters to a reader.
  final Stream<String> lines;
  final Future<int> exitCode;
  final void Function() kill;
}

typedef ProcessLauncher =
    Future<RunningProcess> Function(String executable, List<String> arguments);

/// Starts a real process.
Future<RunningProcess> startSystemProcess(
  String executable,
  List<String> arguments,
) async {
  // runInShell false: a playlist URL is data, never something a shell gets to
  // interpret.
  final process = await Process.start(
    executable,
    arguments,
    runInShell: false,
  );

  final lines = StreamGroup.merge([
    process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
    process.stderr.transform(utf8.decoder).transform(const LineSplitter()),
  ]);

  return RunningProcess(
    lines: lines,
    exitCode: process.exitCode,
    kill: () => process.kill(),
  );
}

/// Minimal stream merge, so this does not pull in `async` for one function.
class StreamGroup {
  static Stream<T> merge<T>(List<Stream<T>> streams) {
    final controller = StreamController<T>();
    var open = streams.length;
    for (final stream in streams) {
      stream.listen(
        controller.add,
        onError: controller.addError,
        onDone: () {
          if (--open == 0) controller.close();
        },
      );
    }
    return controller.stream;
  }
}

class SpotdlClient {
  SpotdlClient({
    this.executable = 'spotdl',
    ProcessLauncher? launcher,
  }) : _launch = launcher ?? startSystemProcess;

  final String executable;
  final ProcessLauncher _launch;

  RunningProcess? _current;

  /// The installed version, or null when spotdl is not on the PATH.
  Future<String?> version() async {
    try {
      final process = await _launch(executable, ['--version']);
      final output = await process.lines.take(1).join();
      final code = await process.exitCode;
      if (code != 0) return null;
      final version = stripAnsi(output).trim();
      return version.isEmpty ? null : version;
    } catch (_) {
      // Not installed, or not executable. Either way there is nothing to run.
      return null;
    }
  }

  /// Runs one download, reporting as it goes.
  ///
  /// The stream closes when spotdl exits. A non-zero exit with no failures
  /// reported becomes a final [SpotdlFailed], so a silent crash cannot look like
  /// success.
  Stream<SpotdlEvent> download({
    required String url,
    required String outputDirectory,
    DownloadFormat format = DownloadFormat.mp3,
    String bitrate = 'auto',
    String? cookiesFile,
    int threads = 4,
    bool overwriteExisting = false,
    List<String> audioProviders = defaultAudioProviders,
  }) async* {
    final process = await _launch(
      executable,
      spotdlArguments(
        url: url,
        outputDirectory: outputDirectory,
        format: format,
        bitrate: bitrate,
        cookiesFile: cookiesFile,
        threads: threads,
        overwriteExisting: overwriteExisting,
        audioProviders: audioProviders,
      ),
    );
    _current = process;

    var sawFailure = false;
    try {
      await for (final line in process.lines) {
        final event = parseSpotdlLine(line);
        if (event is SpotdlFailed) sawFailure = true;
        yield event;
      }

      final code = await process.exitCode;
      if (code != 0 && !sawFailure) {
        yield SpotdlFailed('', 'spotdl exited with code $code');
      }
    } finally {
      _current = null;
    }
  }

  /// Stops the running download, if there is one.
  void cancel() {
    _current?.kill();
    _current = null;
  }
}
