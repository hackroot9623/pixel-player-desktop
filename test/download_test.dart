import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pixelplay_desktop/data/download/download_controller.dart';
import 'package:pixelplay_desktop/data/download/spotdl_client.dart';

/// spotdl is not installed here, and would not be run in a test even if it were.
/// What is testable — and what breaks in practice — is the command line, the
/// reading of spotdl's output, and the bookkeeping on top of it.

/// A process that never existed: a scripted list of lines and an exit code.
ProcessLauncher fakeLauncher(
  List<String> lines, {
  int exitCode = 0,
  List<List<String>>? recordArguments,
  Completer<void>? killed,
}) => (executable, arguments) async {
  recordArguments?.add([executable, ...arguments]);
  return RunningProcess(
    lines: Stream.fromIterable(lines),
    exitCode: Future.value(exitCode),
    kill: () => killed?.complete(),
  );
};

void main() {
  group('the command line', () {
    List<String> args({
      String url = 'https://open.spotify.com/playlist/abc',
      String out = '/music/Downloads',
      DownloadFormat format = DownloadFormat.mp3,
      String bitrate = 'auto',
      String? cookies,
      bool overwrite = false,
    }) => spotdlArguments(
      url: url,
      outputDirectory: out,
      format: format,
      bitrate: bitrate,
      cookiesFile: cookies,
      overwriteExisting: overwrite,
    );

    test('it is a download with the link and an output template', () {
      final line = args();
      expect(line.first, 'download');
      expect(line, contains('https://open.spotify.com/playlist/abc'));
      // The extension follows --format rather than being hardcoded.
      expect(
        line[line.indexOf('--output') + 1],
        '/music/Downloads/{artists} - {title}.{output-ext}',
      );
    });

    test('the format and bitrate are passed through', () {
      final line = args(format: DownloadFormat.opus, bitrate: '320k');
      expect(line[line.indexOf('--format') + 1], 'opus');
      expect(line[line.indexOf('--bitrate') + 1], '320k');
    });

    test('a second run skips what is already there by default', () {
      // The usual reason to run twice is to pick up what a playlist gained.
      expect(args()[args().indexOf('--overwrite') + 1], 'skip');
      expect(
        args(overwrite: true)[args(overwrite: true).indexOf('--overwrite') + 1],
        'force',
      );
    });

    test('cookies are passed only when there are some', () {
      expect(args().contains('--cookie-file'), isFalse);
      expect(args(cookies: '').contains('--cookie-file'), isFalse);

      final line = args(cookies: '/home/me/cookies.txt');
      expect(line[line.indexOf('--cookie-file') + 1], '/home/me/cookies.txt');
    });

    test('errors are asked for, so failures carry their reason', () {
      expect(args(), contains('--print-errors'));
    });

    test('a link with shell characters stays one argument', () {
      // Arguments go straight to execve, and this is the test that says so.
      final line = args(url: 'https://open.spotify.com/playlist/a;rm -rf /');
      expect(line, contains('https://open.spotify.com/playlist/a;rm -rf /'));
    });
  });

  group('reading spotdl output', () {
    test('colour codes do not confuse the parser', () {
      expect(stripAnsi('\x1B[32mDownloaded\x1B[0m "A - B"'), 'Downloaded "A - B"');
      final event = parseSpotdlLine('\x1B[32mDownloaded\x1B[0m "A - B": url');
      expect(event, isA<SpotdlDownloaded>());
    });

    test('the total and playlist name are picked up', () {
      final event = parseSpotdlLine('Found 42 songs in My Mix (playlist)');
      expect(event, isA<SpotdlTotal>());
      expect((event as SpotdlTotal).count, 42);
      expect(event.name, 'My Mix');
    });

    test('a single song still gives a total', () {
      expect((parseSpotdlLine('Found 1 song in X (album)') as SpotdlTotal).count, 1);
    });

    test('a downloaded track is recognised', () {
      final event = parseSpotdlLine(
        'Downloaded "Moneda Dura - Al Sudeste": https://music.youtube.com/w?v=1',
      );
      expect((event as SpotdlDownloaded).track, 'Moneda Dura - Al Sudeste');
    });

    test('a skipped track carries why', () {
      final event = parseSpotdlLine(
        'Skipping Moneda Dura - Al Sudeste (file already exists)',
      );
      expect(event, isA<SpotdlSkipped>());
      expect((event as SpotdlSkipped).track, 'Moneda Dura - Al Sudeste');
      expect(event.reason, 'file already exists');
    });

    test('a track with no match is a failure, not a skip', () {
      // It is the difference between "you already have it" and "you do not".
      final event = parseSpotdlLine(
        'LookupError: No results found for song: Obscure B-Side',
      );
      expect(event, isA<SpotdlFailed>());
      expect((event as SpotdlFailed).track, 'Obscure B-Side');
    });

    test('a provider error is reported with its class', () {
      final event = parseSpotdlLine(
        'AudioProviderError: YT-DLP download error - Sign in to confirm',
      );
      expect(event, isA<SpotdlFailed>());
      expect((event as SpotdlFailed).error, contains('AudioProviderError'));
      expect(event.error, contains('Sign in to confirm'));
    });

    test('an error with no detail says so instead of dangling a dash', () {
      // Exactly what a real run produced: spotdl relays yt-dlp's failure as
      // "YT-DLP download error -" without ever capturing the reason.
      final event = parseSpotdlLine('AudioProviderError: YT-DLP download error -');
      expect(event, isA<SpotdlFailed>());
      expect(
        (event as SpotdlFailed).error,
        'AudioProviderError: YT-DLP download error (spotdl gave no detail)',
      );
      expect(event.error, isNot(endsWith('-')));
    });

    test('anything unrecognised is kept as a log line', () {
      // spotdl's wording changes between versions; a parser that insisted on
      // knowing every line would break on the next upgrade.
      final event = parseSpotdlLine('Processing query: https://open.spotify…');
      expect(event, isA<SpotdlLog>());
      expect((event as SpotdlLog).line, contains('Processing query'));
    });

    test('blank lines are empty logs, not noise', () {
      expect((parseSpotdlLine('   ') as SpotdlLog).line, isEmpty);
    });
  });

  group('recognising the YouTube sign-in wall', () {
    test("yt-dlp's own wording is recognised", () {
      // The real message, curly apostrophe and all, which is why the match is
      // on "not a bot" rather than the whole phrase.
      expect(
        looksLikeBotWall(
          'ERROR: [youtube] OzDB1Nu6hf4: Sign in to confirm you\u2019re not a '
          'bot. Use --cookies-from-browser or --cookies for the authentication.',
        ),
        isTrue,
      );
    });

    test("spotdl's detail-less relay is recognised too", () {
      // spotdl swallows the reason, so this is all the app usually sees.
      expect(
        looksLikeBotWall('AudioProviderError: YT-DLP download error -'),
        isTrue,
      );
    });

    test('an ordinary failure is not mistaken for it', () {
      for (final line in [
        'LookupError: No results found for song: Obscure B-Side',
        'Skipping A - Two (file already exists)',
        'Downloaded "A - One": https://x',
        'YouTube Music returned no usable results for daft punk',
      ]) {
        expect(looksLikeBotWall(line), isFalse, reason: line);
      }
    });

    test('the controller raises it from a log line or a failure', () async {
      var controller = DownloadController(
        client: SpotdlClient(
          launcher: fakeLauncher([
            'Found 1 song in X (album)',
            'AudioProviderError: YT-DLP download error -',
          ]),
        ),
      );
      await controller.start(
        url: _link,
        outputDirectory: '${Directory.systemTemp.path}/pixelplay-dl-test',
      );
      expect(controller.needsCookies, isTrue);
      controller.dispose();

      // And a clean run must not claim it.
      controller = DownloadController(
        client: SpotdlClient(
          launcher: fakeLauncher([
            'Found 1 song in X (album)',
            'Downloaded "A - One": https://x',
          ]),
        ),
      );
      await controller.start(
        url: _link,
        outputDirectory: '${Directory.systemTemp.path}/pixelplay-dl-test',
      );
      expect(controller.needsCookies, isFalse);
      controller.dispose();
    });
  });

  group('recognising a Spotify link', () {
    test('the shapes people paste are accepted', () {
      for (final link in [
        'https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M',
        'https://open.spotify.com/album/1DFixLWuPkv3KT3TnV35m3',
        'https://open.spotify.com/track/4cOdK2wGLETKBW3PvgPWqT',
        'https://open.spotify.com/artist/0OdUWJ0sBjDrqHygGUXeCF',
        // The mobile app adds a locale segment.
        'https://open.spotify.com/intl-es/track/4cOdK2wGLETKBW3PvgPWqT',
        'spotify:playlist:37i9dQZF1DXcBWIGoYBM5M',
      ]) {
        expect(looksLikeSpotifyLink(link), isTrue, reason: link);
      }
    });

    test('a query string does not break it', () {
      expect(
        looksLikeSpotifyLink(
          'https://open.spotify.com/playlist/abc?si=1234&pt=x',
        ),
        isTrue,
      );
    });

    test('anything else is refused before a process starts', () {
      for (final link in [
        '',
        'not a url',
        'https://music.youtube.com/playlist?list=abc',
        'https://open.spotify.com/',
        'https://notspotify.com/playlist/abc',
        // A lookalike host must not pass.
        'https://open.spotify.com.evil.test/playlist/abc',
      ]) {
        expect(looksLikeSpotifyLink(link), isFalse, reason: '"$link"');
      }
    });
  });

  group('the download controller', () {
    late DownloadController controller;

    DownloadController build(
      List<String> lines, {
      int exitCode = 0,
      List<List<String>>? recorded,
      Completer<void>? killed,
      List<String>? rescanned,
    }) => DownloadController(
      client: SpotdlClient(
        launcher: fakeLauncher(
          lines,
          exitCode: exitCode,
          recordArguments: recorded,
          killed: killed,
        ),
      ),
      onFinished: (directory) async => rescanned?.add(directory),
    );

    tearDown(() => controller.dispose());

    test('a run counts what happened', () async {
      controller = build([
        'Processing query: https://open.spotify.com/playlist/abc',
        'Found 3 songs in My Mix (playlist)',
        'Downloaded "A - One": https://x',
        'Skipping A - Two (file already exists)',
        'LookupError: No results found for song: A - Three',
      ]);

      await controller.start(
        url: 'https://open.spotify.com/playlist/abc',
        outputDirectory: '${Directory.systemTemp.path}/pixelplay-dl-test',
      );

      expect(controller.total, 3);
      expect(controller.playlistName, 'My Mix');
      expect(controller.downloaded, ['A - One']);
      expect(controller.skipped.single.track, 'A - Two');
      expect(controller.failed.single.track, 'A - Three');
      expect(controller.handled, 3);
      expect(controller.progress, 1.0);
      expect(controller.running, isFalse);
    });

    test('progress is unknown until the total arrives', () async {
      controller = build(['Processing query: x']);
      expect(controller.progress, isNull);
    });

    test('the library is rescanned only when something arrived', () async {
      final rescanned = <String>[];
      final dir = '${Directory.systemTemp.path}/pixelplay-dl-test';

      controller = build([
        'Found 1 song in X (album)',
        'Skipping A - Two (file already exists)',
      ], rescanned: rescanned);
      await controller.start(url: _link, outputDirectory: dir);
      // Nothing new on disk, so nothing to rescan.
      expect(rescanned, isEmpty);
      controller.dispose();

      controller = build([
        'Found 1 song in X (album)',
        'Downloaded "A - One": https://x',
      ], rescanned: rescanned);
      await controller.start(url: _link, outputDirectory: dir);
      expect(rescanned, [dir]);
    });

    test('a crash with no reported failure is still a failure', () async {
      // Otherwise a spotdl that dies on startup looks like a clean run that
      // found nothing.
      controller = build(['some noise'], exitCode: 2);
      await controller.start(
        url: _link,
        outputDirectory: '${Directory.systemTemp.path}/pixelplay-dl-test',
      );

      expect(controller.failed, hasLength(1));
      expect(controller.failed.single.error, contains('code 2'));
    });

    test('a bad link is refused without starting anything', () async {
      final recorded = <List<String>>[];
      controller = build(const [], recorded: recorded);

      await controller.start(
        url: 'https://music.youtube.com/playlist?list=x',
        outputDirectory: '${Directory.systemTemp.path}/pixelplay-dl-test',
      );

      expect(controller.error, contains('does not look like a Spotify link'));
      expect(recorded, isEmpty);
      expect(controller.running, isFalse);
    });

    test('an empty link says so', () async {
      controller = build(const []);
      await controller.start(url: '  ', outputDirectory: '/tmp');
      expect(controller.error, contains('Paste a Spotify'));
    });

    test('stopping kills the process and is remembered', () async {
      final killed = Completer<void>();
      // A stream that never ends, so the run is still going when it is stopped.
      controller = DownloadController(
        client: SpotdlClient(
          launcher: (executable, arguments) async => RunningProcess(
            lines: StreamController<String>().stream,
            exitCode: Completer<int>().future,
            kill: () => killed.complete(),
          ),
        ),
      );

      final run = controller.start(
        url: _link,
        outputDirectory: '${Directory.systemTemp.path}/pixelplay-dl-test',
      );
      await Future<void>.delayed(Duration.zero);
      expect(controller.running, isTrue);

      controller.cancel();
      expect(controller.cancelled, isTrue);
      await killed.future.timeout(const Duration(seconds: 2));
      run.ignore();
    });

    test('the log is capped so a long playlist cannot grow forever', () async {
      controller = build([
        for (var i = 0; i < 900; i++) 'Processing line $i',
      ]);
      await controller.start(
        url: _link,
        outputDirectory: '${Directory.systemTemp.path}/pixelplay-dl-test',
      );

      expect(controller.log.length, 500);
      // The newest lines are the ones kept.
      expect(controller.log.last, contains('899'));
    });

    test('a missing spotdl is detected rather than assumed', () async {
      controller = build(const [], exitCode: 127);
      await controller.probe();
      expect(controller.probed, isTrue);
      expect(controller.available, isFalse);
    });

    test('an installed spotdl reports its version', () async {
      controller = build(['4.2.11']);
      await controller.probe();
      expect(controller.available, isTrue);
      expect(controller.version, '4.2.11');
    });
  });
}

const _link = 'https://open.spotify.com/playlist/abc';
