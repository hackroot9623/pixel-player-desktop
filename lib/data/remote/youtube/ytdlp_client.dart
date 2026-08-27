import 'dart:async';
import 'dart:convert';
import 'dart:io';

// Wraps the `yt-dlp` binary.
//
// There is no official API that can feed a music player: the YouTube Data API
// hands out metadata only and requires playback through its own embedded
// player, so every client that actually plays audio extracts it. yt-dlp is the
// pragmatic choice on a desktop — it is a normal command-line tool the user
// installs, and when YouTube changes its ciphers their package manager fixes it
// rather than a PixelPlayer release.
//
// Extracting audio is outside YouTube's terms of service. That is the user's
// call to make; this code neither hides it nor works around any protection
// beyond what yt-dlp itself does.

/// Runs a process. The seam that lets the tests assert the exact argument list
/// without yt-dlp installed.
abstract class ProcessRunner {
  Future<ProcessResult> run(String executable, List<String> arguments);
}

class SystemProcessRunner implements ProcessRunner {
  const SystemProcessRunner();

  @override
  Future<ProcessResult> run(String executable, List<String> arguments) =>
      // runInShell stays false: arguments go straight to execve, so a search
      // query containing a quote, a semicolon or a backtick is data, never
      // something the shell can act on.
      Process.run(executable, arguments, runInShell: false);
}

/// A failure worth showing the user.
class YtDlpException implements Exception {
  const YtDlpException(this.message, {this.detail});

  final String message;
  final String? detail;

  @override
  String toString() => message;
}

/// One track as yt-dlp describes it.
class YtEntry {
  const YtEntry({
    required this.id,
    required this.title,
    this.uploader,
    this.album,
    this.artist,
    this.durationSeconds,
    this.thumbnail,
  });

  /// Parses one `--dump-json` object. Returns null for anything unplayable.
  static YtEntry? fromJson(Map<String, Object?> json) {
    final id = json['id'];
    if (id is! String || id.isEmpty) return null;
    final title = json['title'];
    // Removed and private videos still appear in playlist listings, with the
    // title standing in for the error.
    if (title is! String ||
        title == '[Deleted video]' ||
        title == '[Private video]') {
      return null;
    }

    return YtEntry(
      id: id,
      title: title,
      uploader: json['uploader'] as String? ?? json['channel'] as String?,
      // Music on YouTube Music carries real tags; a plain video does not.
      album: json['album'] as String?,
      artist: json['artist'] as String? ?? json['creator'] as String?,
      durationSeconds: (json['duration'] as num?)?.round(),
      thumbnail: _bestThumbnail(json),
    );
  }

  final String id;
  final String title;
  final String? uploader;
  final String? album;
  final String? artist;
  final int? durationSeconds;
  final String? thumbnail;

  String get watchUrl => 'https://music.youtube.com/watch?v=$id';

  static String? _bestThumbnail(Map<String, Object?> json) {
    final direct = json['thumbnail'];
    if (direct is String && direct.isNotEmpty) return direct;
    final list = json['thumbnails'];
    if (list is List && list.isNotEmpty) {
      // Last entry is the largest in yt-dlp's ordering.
      for (final candidate in list.reversed) {
        if (candidate is Map && candidate['url'] is String) {
          return candidate['url'] as String;
        }
      }
    }
    return null;
  }
}

/// Talks to yt-dlp.
class YtDlpClient {
  const YtDlpClient({
    this.executable = 'yt-dlp',
    this.runner = const SystemProcessRunner(),
    this.cookiesFromBrowser,
    this.cookiesFile,
    this.timeout = const Duration(minutes: 2),
  });

  /// Path or bare name of the binary.
  final String executable;
  final ProcessRunner runner;

  /// When set, yt-dlp reads that browser's cookies. Off unless the user asks:
  /// it reaches into their browser profile, which is a bigger ask than a search.
  ///
  /// Chromium-based browsers on Linux keep this database locked and encrypted
  /// while running, so this often fails unless the browser is fully closed —
  /// which is why [cookiesFile] exists.
  final String? cookiesFromBrowser;

  /// A Netscape-format `cookies.txt`, exported from the browser once.
  ///
  /// Preferred over [cookiesFromBrowser] when both are set: a file works
  /// whether or not the browser is open, and needs no access to its profile.
  final String? cookiesFile;

  final Duration timeout;

  /// Browsers yt-dlp can read cookies from.
  static const supportedBrowsers = [
    'brave',
    'chrome',
    'chromium',
    'edge',
    'firefox',
    'opera',
    'safari',
    'vivaldi',
  ];

  /// Arguments every invocation carries.
  List<String> _baseArguments() => [
    // Ignore the user's own yt-dlp config: a post-processor or an output
    // template set for their command-line use would break the JSON parsing.
    '--ignore-config',
    '--no-warnings',
    // A file wins: it does not care whether the browser is running.
    if (cookiesFile != null && cookiesFile!.isNotEmpty)
      ...['--cookies', cookiesFile!]
    else if (cookiesFromBrowser != null && cookiesFromBrowser!.isNotEmpty)
      ...['--cookies-from-browser', cookiesFromBrowser!],
  ];

  /// The installed version, or null when the binary is not there.
  Future<String?> version() async {
    try {
      final result = await runner
          .run(executable, ['--version'])
          .timeout(timeout);
      if (result.exitCode != 0) return null;
      return (result.stdout as String).trim();
    } on ProcessException {
      return null;
    } on TimeoutException {
      return null;
    }
  }

  /// Searches YouTube and returns the top [limit] matches.
  ///
  /// `ytsearch` is yt-dlp's own search prefix; there is no YouTube Music
  /// equivalent, so the query goes to YouTube and the results are played from
  /// the same streams YouTube Music serves.
  Future<List<YtEntry>> search(String query, {int limit = 25}) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return const [];
    // The query is one argument: `ytsearch25:whatever the user typed`. Even a
    // query full of shell metacharacters is inert, since no shell is involved.
    return _entries([
      ..._baseArguments(),
      '--dump-json',
      '--flat-playlist',
      'ytsearch$limit:$trimmed',
    ]);
  }

  /// Every track behind a playlist, album or single-track URL.
  Future<List<YtEntry>> entriesForUrl(String url) async {
    final trimmed = url.trim();
    if (!_looksLikeYouTube(trimmed)) {
      throw const YtDlpException(
        'That does not look like a YouTube or YouTube Music link.',
      );
    }
    return _entries([
      ..._baseArguments(),
      '--dump-json',
      '--flat-playlist',
      trimmed,
    ]);
  }

  /// A direct audio URL for one video.
  ///
  /// These are time-limited and tied to the requesting IP, which is why nothing
  /// caches them: they are resolved at the moment of playback.
  ///
  /// Observed against live YouTube: listing and search work anonymously, but
  /// this call is frequently answered with "Sign in to confirm you're not a
  /// bot" unless cookies are supplied. So [cookiesFromBrowser] is usually
  /// required for playback, not just for reaching a private library.
  Future<String> resolveStreamUrl(String videoId) async {
    final result = await _run([
      ..._baseArguments(),
      '--no-playlist',
      // Audio only, best available. mpv is handed the URL directly, so this must
      // be a single stream rather than a manifest needing muxing.
      '--format',
      'bestaudio[acodec!=none]/bestaudio/best',
      '--get-url',
      'https://www.youtube.com/watch?v=$videoId',
    ]);

    final urls = (result.stdout as String)
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.startsWith('http'))
        .toList();
    if (urls.isEmpty) {
      throw YtDlpException(
        'yt-dlp did not return a playable stream for that track.',
        detail: _stderrOf(result),
      );
    }
    return urls.first;
  }

  Future<List<YtEntry>> _entries(List<String> arguments) async {
    final result = await _run(arguments);
    final entries = <YtEntry>[];
    for (final line in (result.stdout as String).split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || !trimmed.startsWith('{')) continue;
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is! Map<String, Object?>) continue;
        final entry = YtEntry.fromJson(decoded);
        if (entry != null) entries.add(entry);
      } on FormatException {
        // One malformed line should not lose the whole listing.
        continue;
      }
    }
    return entries;
  }

  Future<ProcessResult> _run(List<String> arguments) async {
    ProcessResult result;
    try {
      result = await runner.run(executable, arguments).timeout(timeout);
    } on ProcessException catch (error) {
      throw YtDlpException(
        'yt-dlp was not found. Install it from your package manager '
        '(package yt-dlp), or set its path in the YouTube settings.',
        detail: error.message,
      );
    } on TimeoutException {
      throw YtDlpException(
        'yt-dlp did not finish within ${timeout.inSeconds}s.',
      );
    }

    if (result.exitCode != 0) throw _describe(result);
    return result;
  }

  YtDlpException _describe(ProcessResult result) {
    final stderr = _stderrOf(result) ?? '';
    final lower = stderr.toLowerCase();

    final message = switch (lower) {
      final text when text.contains('sign in to confirm') ||
          text.contains('bot') =>
        'YouTube would not serve the audio without a signed-in session. Add '
            'cookies in the YouTube settings — an exported cookies.txt is the '
            'most reliable. Signing in with Google does not help here: the '
            'playback servers check cookies, not a Google token.',
      final text when text.contains('private video') =>
        'That video is private.',
      final text when text.contains('video unavailable') ||
          text.contains('is not available') =>
        'That video is unavailable — it may be region-locked or removed.',
      final text when text.contains('members-only') =>
        'That video is members-only.',
      final text when text.contains('unsupported url') =>
        'yt-dlp does not recognise that link.',
      final text when text.contains('could not copy') &&
          text.contains('cookie') ||
          text.contains('unable to decrypt') =>
        'Could not read that browser’s cookies — it locks them while running. '
            'Close the browser, or export a cookies.txt and point at that '
            'instead.',
      final text when text.contains('unable to download') &&
          text.contains('api page') =>
        'YouTube refused the request. Updating yt-dlp usually fixes this.',
      _ => 'yt-dlp failed (exit ${result.exitCode}).',
    };
    return YtDlpException(message, detail: stderr.isEmpty ? null : stderr);
  }

  String? _stderrOf(ProcessResult result) {
    final value = result.stderr;
    if (value is! String) return null;
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;
    // yt-dlp is chatty; the tail carries the actual reason.
    final lines = trimmed.split('\n');
    return lines.length <= 6 ? trimmed : lines.sublist(lines.length - 6).join('\n');
  }

  bool _looksLikeYouTube(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) return false;
    const hosts = {
      'youtube.com',
      'www.youtube.com',
      'm.youtube.com',
      'music.youtube.com',
      'youtu.be',
    };
    return hosts.contains(uri.host);
  }
}
