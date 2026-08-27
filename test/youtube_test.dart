import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pixelplay_desktop/data/remote/remote_account.dart';
import 'package:pixelplay_desktop/data/remote/remote_source.dart';
import 'package:pixelplay_desktop/data/remote/youtube/youtube_source.dart';
import 'package:pixelplay_desktop/data/remote/youtube/ytdlp_client.dart';

/// yt-dlp is a subprocess, so the runner is faked. That also lets the tests
/// assert the exact argument list, which is where the interesting properties
/// live: no shell is involved, so a search query cannot inject anything.
class _FakeRunner implements ProcessRunner {
  _FakeRunner({this.stdout = '', this.stderr = '', this.exitCode = 0, this.throwing});

  String stdout;
  String stderr;
  int exitCode;
  Object? throwing;

  /// Replies in order, for the multi-call paths.
  final List<({String stdout, String stderr, int exitCode})> queued = [];

  final calls = <({String executable, List<String> arguments})>[];

  List<String> get lastArguments => calls.last.arguments;

  @override
  Future<ProcessResult> run(String executable, List<String> arguments) async {
    calls.add((executable: executable, arguments: arguments));
    if (throwing != null) throw throwing!;
    if (queued.isNotEmpty) {
      final next = queued.removeAt(0);
      return ProcessResult(0, next.exitCode, next.stdout, next.stderr);
    }
    return ProcessResult(0, exitCode, stdout, stderr);
  }
}

RemoteAccount _account({
  String urls = '',
  String? cookies,
  String? cookiesFile,
  bool liked = false,
  String? executable,
}) => RemoteAccount(
  id: 'yt-1',
  kind: RemoteKind.youtube,
  serverUrl: '',
  username: '',
  password: '',
  extra: {
    if (urls.isNotEmpty) 'urls': urls,
    if (cookies != null) 'cookiesBrowser': cookies,
    if (cookiesFile != null) 'cookiesFile': cookiesFile,
    if (liked) 'liked': 'true',
    if (executable != null) 'executable': executable,
  },
);

String _entryJson({
  String id = 'abc123',
  String title = 'Al Sudeste',
  String? uploader = 'Moneda Dura - Topic',
  String? artist,
  String? album,
  num? duration = 249,
  String? thumbnail = 'https://i.ytimg.com/vi/abc123/maxres.jpg',
}) => jsonEncode({
  'id': id,
  'title': title,
  if (uploader != null) 'uploader': uploader,
  if (artist != null) 'artist': artist,
  if (album != null) 'album': album,
  if (duration != null) 'duration': duration,
  if (thumbnail != null) 'thumbnail': thumbnail,
});

void main() {
  group('invocation', () {
    test('a search runs one process with the query as a single argument', () async {
      final runner = _FakeRunner(stdout: _entryJson());
      final client = YtDlpClient(runner: runner);
      await client.search('moneda dura', limit: 10);

      expect(runner.calls, hasLength(1));
      expect(runner.calls.single.executable, 'yt-dlp');
      expect(runner.lastArguments, contains('--dump-json'));
      expect(runner.lastArguments, contains('--flat-playlist'));
      expect(runner.lastArguments.last, 'ytsearch10:moneda dura');
    });

    test('a query full of shell metacharacters stays one inert argument', () async {
      // The whole reason runInShell is false. If this ever became a shell
      // string, this query would be a command.
      const nasty = r'''rm -rf ~; echo `whoami` && $(id) | tee /tmp/x "quoted"''';
      final runner = _FakeRunner(stdout: '');
      await YtDlpClient(runner: runner).search(nasty);

      final args = runner.lastArguments;
      expect(args.last, 'ytsearch25:$nasty');
      // Exactly one argument carries it, and nothing was split on the way.
      expect(args.where((a) => a.contains('whoami')), hasLength(1));
    });

    test('a cookies file wins over the browser', () async {
      // Chromium-based browsers lock their cookie database while running, so a
      // file is the reliable option and must take precedence when both are set.
      final runner = _FakeRunner(stdout: '');
      await YtDlpClient(
        runner: runner,
        cookiesFromBrowser: 'brave',
        cookiesFile: '/home/me/cookies.txt',
      ).search('x');

      final args = runner.lastArguments;
      expect(args, contains('--cookies'));
      expect(args[args.indexOf('--cookies') + 1], '/home/me/cookies.txt');
      expect(args, isNot(contains('--cookies-from-browser')));
    });

    test('a locked cookie database is explained, with the way out', () async {
      final runner = _FakeRunner(
        exitCode: 1,
        stderr: 'ERROR: Could not copy Brave cookie database. '
            'Unable to decrypt cookies.',
      );
      await expectLater(
        YtDlpClient(runner: runner, cookiesFromBrowser: 'brave')
            .resolveStreamUrl('abc'),
        throwsA(
          isA<YtDlpException>().having(
            (e) => e.message,
            'message',
            allOf(contains('locks them'), contains('cookies.txt')),
          ),
        ),
      );
    });

    test('the bot wall says cookies, and that Google sign-in is not it', () async {
      // Observed live: search works anonymously but the audio does not. The
      // message has to point at the mechanism that actually helps.
      final runner = _FakeRunner(
        exitCode: 1,
        stderr: 'ERROR: [youtube] abc: Sign in to confirm you are not a bot.',
      );
      await expectLater(
        YtDlpClient(runner: runner).resolveStreamUrl('abc'),
        throwsA(
          isA<YtDlpException>().having(
            (e) => e.message,
            'message',
            allOf(contains('cookies'), contains('Google')),
          ),
        ),
      );
    });

    test('cookies are only passed when a browser is configured', () async {
      final without = _FakeRunner(stdout: '');
      await YtDlpClient(runner: without).search('x');
      expect(without.lastArguments, isNot(contains('--cookies-from-browser')));

      final with_ = _FakeRunner(stdout: '');
      await YtDlpClient(runner: with_, cookiesFromBrowser: 'brave').search('x');
      final args = with_.lastArguments;
      expect(args, contains('--cookies-from-browser'));
      expect(args[args.indexOf('--cookies-from-browser') + 1], 'brave');
    });

    test('the configured binary path is honoured', () async {
      final runner = _FakeRunner(stdout: '');
      await YtDlpClient(
        executable: '/opt/bin/yt-dlp',
        runner: runner,
      ).search('x');
      expect(runner.calls.single.executable, '/opt/bin/yt-dlp');
    });

    test('a missing binary is reported with installation guidance', () async {
      final runner = _FakeRunner(
        throwing: const ProcessException('yt-dlp', [], 'No such file', 2),
      );
      await expectLater(
        YtDlpClient(runner: runner).search('x'),
        throwsA(
          isA<YtDlpException>().having(
            (e) => e.message,
            'message',
            contains('yt-dlp was not found'),
          ),
        ),
      );
    });

    test('version returns null rather than throwing when absent', () async {
      final runner = _FakeRunner(
        throwing: const ProcessException('yt-dlp', [], 'nope', 2),
      );
      expect(await YtDlpClient(runner: runner).version(), isNull);
    });

    test('version reports what the binary printed', () async {
      final runner = _FakeRunner(stdout: '2025.08.11\n');
      expect(await YtDlpClient(runner: runner).version(), '2025.08.11');
    });
  });

  group('listing', () {
    test('one JSON object per line becomes one entry each', () async {
      final runner = _FakeRunner(
        stdout: [
          _entryJson(id: 'a', title: 'First'),
          _entryJson(id: 'b', title: 'Second'),
          '',
        ].join('\n'),
      );
      final entries = await YtDlpClient(runner: runner).search('x');
      expect(entries.map((e) => e.id), ['a', 'b']);
      expect(entries.first.title, 'First');
    });

    test('deleted and private videos are dropped', () async {
      // They still appear in playlist listings, with the title as the reason.
      final runner = _FakeRunner(
        stdout: [
          _entryJson(id: 'a'),
          _entryJson(id: 'b', title: '[Deleted video]'),
          _entryJson(id: 'c', title: '[Private video]'),
        ].join('\n'),
      );
      final entries = await YtDlpClient(runner: runner).search('x');
      expect(entries.map((e) => e.id), ['a']);
    });

    test('a malformed line does not lose the rest of the listing', () async {
      final runner = _FakeRunner(
        stdout: ['{not json', _entryJson(id: 'good')].join('\n'),
      );
      final entries = await YtDlpClient(runner: runner).search('x');
      expect(entries.map((e) => e.id), ['good']);
    });

    test('the largest thumbnail is taken from a thumbnails array', () async {
      final runner = _FakeRunner(
        stdout: jsonEncode({
          'id': 'a',
          'title': 'T',
          'thumbnails': [
            {'url': 'small.jpg'},
            {'url': 'large.jpg'},
          ],
        }),
      );
      final entries = await YtDlpClient(runner: runner).search('x');
      expect(entries.single.thumbnail, 'large.jpg');
    });

    test('a non-YouTube link is refused before running anything', () async {
      final runner = _FakeRunner();
      await expectLater(
        YtDlpClient(runner: runner).entriesForUrl('https://example.com/a.mp3'),
        throwsA(isA<YtDlpException>()),
      );
      expect(runner.calls, isEmpty);
    });

    test('YouTube and YouTube Music links are both accepted', () async {
      for (final url in [
        'https://music.youtube.com/playlist?list=abc',
        'https://www.youtube.com/watch?v=abc',
        'https://youtu.be/abc',
      ]) {
        final runner = _FakeRunner(stdout: _entryJson());
        await YtDlpClient(runner: runner).entriesForUrl(url);
        expect(runner.lastArguments.last, url);
      }
    });
  });

  group('resolving a stream', () {
    test('it asks for audio only and returns the URL', () async {
      final runner = _FakeRunner(
        stdout: 'https://rr1.googlevideo.com/videoplayback?abc\n',
      );
      final url = await YtDlpClient(runner: runner).resolveStreamUrl('abc123');

      expect(url, 'https://rr1.googlevideo.com/videoplayback?abc');
      final args = runner.lastArguments;
      expect(args, contains('--get-url'));
      expect(args, contains('--no-playlist'));
      expect(
        args[args.indexOf('--format') + 1],
        'bestaudio[acodec!=none]/bestaudio/best',
      );
      expect(args.last, 'https://www.youtube.com/watch?v=abc123');
    });

    test('no URL in the output is an error, not an empty string', () async {
      final runner = _FakeRunner(stdout: '\n');
      await expectLater(
        YtDlpClient(runner: runner).resolveStreamUrl('abc'),
        throwsA(isA<YtDlpException>()),
      );
    });

    test('yt-dlp failures are translated into something actionable', () async {
      final cases = {
        'ERROR: Sign in to confirm you are not a bot': 'signed-in session',
        'ERROR: Video unavailable': 'unavailable',
        'ERROR: Private video': 'private',
        'ERROR: This video is members-only content': 'members-only',
        'ERROR: Unsupported URL: https://x': 'does not recognise',
      };
      for (final entry in cases.entries) {
        final runner = _FakeRunner(exitCode: 1, stderr: entry.key);
        await expectLater(
          YtDlpClient(runner: runner).resolveStreamUrl('abc'),
          throwsA(
            isA<YtDlpException>().having(
              (e) => e.message.toLowerCase(),
              'message',
              contains(entry.value),
            ),
          ),
          reason: entry.key,
        );
      }
    });

    test('an unrecognised failure still carries yt-dlp own words', () async {
      final runner = _FakeRunner(exitCode: 1, stderr: 'ERROR: something odd');
      await expectLater(
        YtDlpClient(runner: runner).resolveStreamUrl('abc'),
        throwsA(
          isA<YtDlpException>()
              .having((e) => e.message, 'message', contains('exit 1'))
              .having((e) => e.detail, 'detail', contains('something odd')),
        ),
      );
    });
  });

  group('mapping to songs', () {
    test('an entry becomes a song with no path until it is played', () {
      // A YouTube stream URL expires and is address-bound, so storing one in
      // the library would hand the player a dead link.
      final song = songFromEntry(
        _account(),
        YtEntry.fromJson(jsonDecode(_entryJson()) as Map<String, Object?>)!,
      );
      expect(song.id, 'youtube:yt-1:abc123');
      expect(song.title, 'Al Sudeste');
      expect(song.duration, 249000);
      expect(song.albumArtPath, startsWith('https://'));
      expect(song.path, isEmpty);
      expect(youtubeVideoId(song), 'abc123');
      expect(remoteKindOfSongId(song.id), RemoteKind.youtube);
    });

    test('the auto-generated " - Topic" channel suffix is stripped', () {
      final song = songFromEntry(
        _account(),
        YtEntry.fromJson(jsonDecode(_entryJson()) as Map<String, Object?>)!,
      );
      expect(song.artist, 'Moneda Dura');
    });

    test('real music tags win over the channel name', () {
      final song = songFromEntry(
        _account(),
        YtEntry.fromJson(
          jsonDecode(
                _entryJson(artist: 'Benny Moré', album: 'Mágico'),
              )
              as Map<String, Object?>,
        )!,
      );
      expect(song.artist, 'Benny Moré');
      expect(song.album, 'Mágico');
    });

    test('a plain video falls back to sensible labels', () {
      final song = songFromEntry(
        _account(),
        YtEntry.fromJson(
          jsonDecode(_entryJson(uploader: null, duration: null))
              as Map<String, Object?>,
        )!,
      );
      expect(song.artist, 'YouTube');
      expect(song.album, 'YouTube Music');
      expect(song.duration, 0);
    });
  });

  group('configuration', () {
    test('links are stored one per line', () {
      final account = _account(
        urls: 'https://music.youtube.com/playlist?list=a\n'
            'https://music.youtube.com/playlist?list=b',
      );
      expect(youtubeSourceUrls(account), hasLength(2));
      expect(youtubeSourceUrls(_account()), isEmpty);
    });

    test('Liked Music needs cookies, not just the switch', () {
      // Without a signed-in session the playlist is simply not visible, so the
      // switch alone must not put it in the library.
      expect(youtubeUseLikedMusic(_account(liked: true)), isFalse);
      expect(
        youtubeUseLikedMusic(_account(liked: true, cookies: 'brave')),
        isTrue,
      );
      // A file counts as a session just as much as a browser does.
      expect(
        youtubeUseLikedMusic(_account(liked: true, cookiesFile: '/c.txt')),
        isTrue,
      );
      expect(youtubeUseLikedMusic(_account(cookies: 'brave')), isFalse);
    });

    test('either cookie source counts as having cookies', () {
      expect(youtubeHasCookies(_account()), isFalse);
      expect(youtubeHasCookies(_account(cookies: 'firefox')), isTrue);
      expect(youtubeHasCookies(_account(cookiesFile: '/c.txt')), isTrue);
      expect(youtubeCookiesFile(_account(cookiesFile: '  ')), isNull);
    });

    test('the executable defaults to whatever is on PATH', () {
      expect(youtubeExecutable(_account()), 'yt-dlp');
      expect(
        youtubeExecutable(_account(executable: '/opt/bin/yt-dlp')),
        '/opt/bin/yt-dlp',
      );
    });

    test('an account with nothing configured has an empty library', () async {
      final runner = _FakeRunner();
      final source = YoutubeSource(
        account: _account(),
        client: YtDlpClient(runner: runner),
      );
      expect(await source.songs(), isEmpty);
      expect(runner.calls, isEmpty, reason: 'nothing to fetch');
    });
  });

  group('building the library', () {
    test('every configured link contributes, without duplicates', () async {
      final runner = _FakeRunner()
        ..queued.addAll([
          (stdout: _entryJson(id: 'a'), stderr: '', exitCode: 0),
          // The same track in a second playlist, plus a new one.
          (
            stdout: [_entryJson(id: 'a'), _entryJson(id: 'b')].join('\n'),
            stderr: '',
            exitCode: 0,
          ),
        ]);
      final source = YoutubeSource(
        account: _account(
          urls: 'https://music.youtube.com/playlist?list=one\n'
              'https://music.youtube.com/playlist?list=two',
        ),
        client: YtDlpClient(runner: runner),
      );

      final songs = await source.songs();
      expect(songs.map((s) => youtubeVideoId(s)), ['a', 'b']);
    });

    test('one failing link does not lose the others', () async {
      final runner = _FakeRunner()
        ..queued.addAll([
          (stdout: '', stderr: 'ERROR: Private video', exitCode: 1),
          (stdout: _entryJson(id: 'good'), stderr: '', exitCode: 0),
        ]);
      final source = YoutubeSource(
        account: _account(
          urls: 'https://music.youtube.com/playlist?list=gone\n'
              'https://music.youtube.com/playlist?list=fine',
        ),
        client: YtDlpClient(runner: runner),
      );
      final songs = await source.songs();
      expect(songs.map((s) => youtubeVideoId(s)), ['good']);
    });

    test('Liked Music is fetched first when enabled', () async {
      final runner = _FakeRunner(stdout: _entryJson());
      final source = YoutubeSource(
        account: _account(liked: true, cookies: 'brave'),
        client: YtDlpClient(runner: runner, cookiesFromBrowser: 'brave'),
      );
      await source.songs();
      expect(runner.calls.first.arguments.last, YoutubeSource.likedMusicUrl);
    });
  });
}
