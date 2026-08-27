import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixelplay_desktop/data/remote/drive/drive_source.dart';
import 'package:pixelplay_desktop/data/remote/drive/google_oauth.dart';
import 'package:pixelplay_desktop/data/remote/remote_account.dart';
import 'package:pixelplay_desktop/data/remote/remote_source.dart';
import 'package:pixelplay_desktop/player/player_service.dart';

/// No Google project here, so everything runs against a fake. The parts worth
/// testing are the ones a live Drive would not tell you about anyway: how a
/// file name and a folder tree turn into a library, and what the query asks for.

class _FakeHttpClient implements HttpClient {
  _FakeHttpClient({this.status = 200, this.body = '{}'});

  int status;
  String body;

  final List<({int status, String body})> queued = [];
  final List<_FakeRequest> requests = [];

  _FakeRequest get last => requests.last;

  ({int status, String body}) _next() =>
      queued.isNotEmpty ? queued.removeAt(0) : (status: status, body: body);

  @override
  Future<HttpClientRequest> getUrl(Uri url) async => _make(url, 'GET');

  @override
  Future<HttpClientRequest> postUrl(Uri url) async => _make(url, 'POST');

  _FakeRequest _make(Uri url, String method) {
    final reply = _next();
    final request = _FakeRequest(
      url,
      method,
      status: reply.status,
      body: reply.body,
    );
    requests.add(request);
    return request;
  }

  @override
  void close({bool force = false}) {}

  @override
  noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName} is not used');
}

class _FakeRequest implements HttpClientRequest {
  _FakeRequest(
    this.uri,
    this.method, {
    required this.status,
    required this.body,
  });

  @override
  final Uri uri;
  @override
  final String method;
  final int status;
  final String body;

  final _written = StringBuffer();
  String get sentBody => _written.toString();

  @override
  final HttpHeaders headers = _FakeHeaders();

  @override
  void write(Object? object) => _written.write(object);

  @override
  Future<HttpClientResponse> close() async =>
      _FakeResponse(status: status, body: body);

  @override
  noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName} is not used');
}

class _FakeHeaders implements HttpHeaders {
  final values = <String, String>{};

  @override
  ContentType? contentType;

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) =>
      values[name.toLowerCase()] = '$value';

  @override
  String? value(String name) => values[name.toLowerCase()];

  @override
  noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName} is not used');
}

class _FakeResponse extends Stream<List<int>> implements HttpClientResponse {
  _FakeResponse({required int status, required this.body})
    : statusCode = status;

  @override
  final int statusCode;
  final String body;

  @override
  final HttpHeaders headers = _FakeHeaders();

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream<List<int>>.value(utf8.encode(body)).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName} is not used');
}

RemoteAccount _account({
  String clientId = 'client-1',
  String? refreshToken = 'refresh-1',
  String accessToken = 'access-1',
  DateTime? expiresAt,
  String folder = '',
}) => RemoteAccount(
  id: 'drive-1',
  kind: RemoteKind.drive,
  serverUrl: '',
  username: '',
  password: '',
  extra: {
    if (clientId.isNotEmpty) driveClientIdKey: clientId,
    if (refreshToken != null) 'refresh_token': refreshToken,
    'access_token': accessToken,
    'expires_at': (expiresAt ?? DateTime.now().add(const Duration(hours: 1)))
        .toIso8601String(),
    if (folder.isNotEmpty) driveFolderKey: folder,
  },
);

/// Two pages of folders then one page of files, which is the shape [songs]
/// always fetches in.
void _stubLibrary(
  _FakeHttpClient http, {
  required String folders,
  required String files,
}) => http.queued.addAll([
  (status: 200, body: folders),
  (status: 200, body: files),
]);

void main() {
  group('file names', () {
    ParsedFileName parse(String name) => DriveSource.parseFileName(name);

    test('a plain name loses only its extension', () {
      expect(parse('Al Sudeste.mp3').title, 'Al Sudeste');
      expect(parse('Al Sudeste.mp3').trackNumber, 0);
      expect(parse('Al Sudeste.mp3').artist, isNull);
    });

    test('a leading track number is read and removed', () {
      expect(parse('03 Al Sudeste.flac').trackNumber, 3);
      expect(parse('03 Al Sudeste.flac').title, 'Al Sudeste');
      expect(parse('03 - Al Sudeste.flac').title, 'Al Sudeste');
      expect(parse('03. Al Sudeste.flac').title, 'Al Sudeste');
    });

    test('a year is not mistaken for a track number', () {
      // Four digits is a year or part of the title, never track 199.
      final parsed = parse('1999 Party Over.mp3');
      expect(parsed.trackNumber, 0);
      expect(parsed.title, '1999 Party Over');
    });

    test('an artist before a dash is split out', () {
      final parsed = parse('Moneda Dura - Al Sudeste.mp3');
      expect(parsed.artist, 'Moneda Dura');
      expect(parsed.title, 'Al Sudeste');
    });

    test('a track number and an artist together both come out', () {
      final parsed = parse('05 - Moneda Dura - Al Sudeste.mp3');
      expect(parsed.trackNumber, 5);
      expect(parsed.artist, 'Moneda Dura');
      expect(parsed.title, 'Al Sudeste');
    });

    test('underscores read as spaces', () {
      expect(parse('Al_Sudeste.mp3').title, 'Al Sudeste');
    });

    test('a hyphen inside a word is left alone', () {
      // "Non-Stop" is one word; only " - " separates fields.
      expect(parse('Non-Stop.mp3').title, 'Non-Stop');
      expect(parse('Non-Stop.mp3').artist, isNull);
    });

    test('a name that is nothing but an extension keeps something', () {
      expect(parse('.mp3').title, '.mp3');
      expect(parse('01 - .mp3').title, isNotEmpty);
    });

    test('a dotted name keeps everything before the last dot', () {
      expect(parse('Track 1. Live at Home.flac').title, isNotEmpty);
      expect(parse('a.b.c.mp3').title, 'a.b.c');
    });
  });

  group('naming from the folder tree', () {
    late DriveSource source;

    setUp(() => source = DriveSource(_account(), httpClient: _FakeHttpClient()));

    const folders = {
      'artist': DriveFolder(id: 'artist', name: 'Moneda Dura'),
      'album': DriveFolder(
        id: 'album',
        name: 'Sin Blasfemias',
        parentId: 'artist',
      ),
    };

    test('album comes from the folder, artist from the one above', () {
      final song = source.songFor(
        const DriveFile(
          id: 'f1',
          name: '02 Al Sudeste.mp3',
          mimeType: 'audio/mpeg',
          parentId: 'album',
        ),
        folders: folders,
        streamUrl: Uri.parse('https://example/f1'),
      );

      expect(song.title, 'Al Sudeste');
      expect(song.album, 'Sin Blasfemias');
      expect(song.artist, 'Moneda Dura');
      expect(song.albumArtist, 'Moneda Dura');
      expect(song.trackNumber, 2);
      // Drive reports no duration; mpv fills it in on playback.
      expect(song.duration, 0);
    });

    test('a folder name beats an artist guessed from the file name', () {
      // The folder is the user's own filing; the file name is a guess.
      final song = source.songFor(
        const DriveFile(
          id: 'f2',
          name: 'Someone Else - Al Sudeste.mp3',
          mimeType: 'audio/mpeg',
          parentId: 'album',
        ),
        folders: folders,
        streamUrl: Uri.parse('https://example/f2'),
      );
      expect(song.artist, 'Moneda Dura');
    });

    test('a loose file falls back to the file name', () {
      final song = source.songFor(
        const DriveFile(
          id: 'f3',
          name: 'Moneda Dura - Al Sudeste.mp3',
          mimeType: 'audio/mpeg',
        ),
        folders: const {},
        streamUrl: Uri.parse('https://example/f3'),
      );

      expect(song.artist, 'Moneda Dura');
      expect(song.album, 'Google Drive');
      expect(song.albumArtist, isNull);
    });

    test('a file with nothing to go on still gets a usable row', () {
      final song = source.songFor(
        const DriveFile(id: 'f4', name: 'track.mp3', mimeType: 'audio/mpeg'),
        folders: const {},
        streamUrl: Uri.parse('https://example/f4'),
      );

      expect(song.title, 'track');
      expect(song.artist, 'Unknown artist');
    });

    test('an album directly in My Drive has no artist folder above it', () {
      final song = source.songFor(
        const DriveFile(
          id: 'f5',
          name: 'Al Sudeste.mp3',
          mimeType: 'audio/mpeg',
          parentId: 'album',
        ),
        folders: const {
          'album': DriveFolder(id: 'album', name: 'Sin Blasfemias'),
        },
        streamUrl: Uri.parse('https://example/f5'),
      );

      expect(song.album, 'Sin Blasfemias');
      expect(song.artist, 'Unknown artist');
    });

    test('song ids are namespaced to the account', () {
      final song = source.songFor(
        const DriveFile(id: 'f6', name: 'x.mp3', mimeType: 'audio/mpeg'),
        folders: const {},
        streamUrl: Uri.parse('https://example/f6'),
      );

      expect(song.id, 'drive:drive-1:f6');
      expect(remoteKindOfSongId(song.id), RemoteKind.drive);
      expect(remoteItemId(song.id), 'f6');
    });
  });

  group('listing', () {
    test('the query excludes trash and asks for the fields it uses', () async {
      final http = _FakeHttpClient();
      _stubLibrary(http, folders: '{"files":[]}', files: '{"files":[]}');

      await DriveSource(_account(), httpClient: http).songs();

      final folderQuery = http.requests.first.uri.queryParameters['q']!;
      expect(folderQuery, contains('application/vnd.google-apps.folder'));
      expect(folderQuery, contains('trashed = false'));

      final fileQuery = http.requests.last.uri.queryParameters['q']!;
      expect(fileQuery, contains("mimeType contains 'audio/'"));
      expect(fileQuery, contains('trashed = false'));
      expect(
        http.requests.last.uri.queryParameters['fields'],
        contains('nextPageToken'),
      );
    });

    test('a chosen folder limits the file query', () async {
      final http = _FakeHttpClient();
      _stubLibrary(http, folders: '{"files":[]}', files: '{"files":[]}');

      await DriveSource(
        _account(folder: 'folder-9'),
        httpClient: http,
      ).songs();

      expect(
        http.requests.last.uri.queryParameters['q'],
        contains("'folder-9' in parents"),
      );
    });

    test('no folder means the whole drive', () async {
      final http = _FakeHttpClient();
      _stubLibrary(http, folders: '{"files":[]}', files: '{"files":[]}');

      await DriveSource(_account(), httpClient: http).songs();
      expect(
        http.requests.last.uri.queryParameters['q'],
        isNot(contains('in parents')),
      );
    });

    test('shared drives are included', () async {
      // Otherwise a library on a shared drive is invisible for no visible
      // reason.
      final http = _FakeHttpClient();
      _stubLibrary(http, folders: '{"files":[]}', files: '{"files":[]}');

      await DriveSource(_account(), httpClient: http).songs();
      final params = http.requests.last.uri.queryParameters;
      expect(params['supportsAllDrives'], 'true');
      expect(params['includeItemsFromAllDrives'], 'true');
    });

    test('every page of files is read', () async {
      final http = _FakeHttpClient()
        ..queued.addAll([
          (status: 200, body: '{"files":[]}'),
          (
            status: 200,
            body: '{"nextPageToken":"p2","files":['
                '{"id":"a","name":"One.mp3","mimeType":"audio/mpeg"}]}',
          ),
          (
            status: 200,
            body: '{"files":['
                '{"id":"b","name":"Two.mp3","mimeType":"audio/mpeg"}]}',
          ),
        ]);

      final songs = await DriveSource(_account(), httpClient: http).songs();

      expect(songs.map((s) => s.title), ['One', 'Two']);
      expect(http.requests.last.uri.queryParameters['pageToken'], 'p2');
    });

    test('non-audio files are dropped, audio Drive mislabels is kept', () async {
      // Drive hands back `application/octet-stream` for plenty of real audio,
      // so the query is deliberately loose and the extension decides.
      final http = _FakeHttpClient();
      _stubLibrary(
        http,
        folders: '{"files":[]}',
        files: '''
{"files":[
  {"id":"a","name":"Song.mp3","mimeType":"audio/mpeg"},
  {"id":"b","name":"notes.txt","mimeType":"application/octet-stream"},
  {"id":"c","name":"Song.opus","mimeType":"application/octet-stream"},
  {"id":"d","name":"Song.FLAC","mimeType":"application/octet-stream"},
  {"id":"e","name":"noextension","mimeType":"application/octet-stream"}
]}''',
      );

      final songs = await DriveSource(_account(), httpClient: http).songs();
      expect(songs.map((s) => s.id.split(':').last), ['a', 'c', 'd']);
    });

    test('a file with no id is skipped rather than crashing the load', () async {
      final http = _FakeHttpClient();
      _stubLibrary(
        http,
        folders: '{"files":[{"name":"nameless folder"}]}',
        files: '{"files":[{"name":"ghost.mp3","mimeType":"audio/mpeg"},'
            '{"id":"a","name":"Real.mp3","mimeType":"audio/mpeg"}]}',
      );

      final songs = await DriveSource(_account(), httpClient: http).songs();
      expect(songs, hasLength(1));
    });

    test('the stored token is used without a needless refresh', () async {
      final http = _FakeHttpClient();
      _stubLibrary(http, folders: '{"files":[]}', files: '{"files":[]}');

      await DriveSource(_account(), httpClient: http).songs();

      // Two listing calls and nothing else: no trip to the token endpoint.
      expect(http.requests, hasLength(2));
      expect(
        (http.requests.first.headers as _FakeHeaders).value('authorization'),
        'Bearer access-1',
      );
    });

    test('an expired token is refreshed first, and the new one is kept', () async {
      final http = _FakeHttpClient()
        ..queued.addAll([
          (
            status: 200,
            body: '{"access_token":"access-2","expires_in":3600}',
          ),
          (status: 200, body: '{"files":[]}'),
          (status: 200, body: '{"files":[]}'),
        ]);

      RemoteAccount? saved;
      await DriveSource(
        _account(expiresAt: DateTime.now().subtract(const Duration(hours: 2))),
        httpClient: http,
        onSession: (account) => saved = account,
      ).songs();

      expect(http.requests.first.uri.host, 'oauth2.googleapis.com');
      expect(saved, isNotNull);
      expect(saved!.extra['access_token'], 'access-2');
      // Google does not rotate refresh tokens, so the old one must survive.
      expect(saved!.extra['refresh_token'], 'refresh-1');
      expect(
        (http.requests[1].headers as _FakeHeaders).value('authorization'),
        'Bearer access-2',
      );
    });

    test('an account that never signed in says so', () async {
      final http = _FakeHttpClient();
      await expectLater(
        DriveSource(_account(refreshToken: null), httpClient: http).songs(),
        throwsA(
          isA<RemoteException>().having(
            (e) => e.message,
            'message',
            contains('signed in'),
          ),
        ),
      );
      expect(http.requests, isEmpty);
    });

    test('Drive has no cover art to offer', () {
      // The picture is inside the file, which would mean downloading it.
      expect(
        DriveSource(_account(), httpClient: _FakeHttpClient()).artUrl('a'),
        isNull,
      );
    });
  });

  group('streaming', () {
    test('the stream URL is the media download endpoint', () {
      final url = DriveSource(
        _account(),
        httpClient: _FakeHttpClient(),
      ).streamUrl('file-7');

      expect(url.host, 'www.googleapis.com');
      expect(url.path, '/drive/v3/files/file-7');
      expect(url.queryParameters['alt'], 'media');
      // No token in the URL: Drive only takes it as a header, and a URL leaks
      // into logs and crash reports.
      expect(url.toString(), isNot(contains('access')));
    });

    test('the header carries the bearer token', () {
      expect(driveStreamHeaders('abc'), {'Authorization': 'Bearer abc'});
    });

    test('the player matches registered headers by URL prefix', () {
      PlayerService.remoteStreamHeaders.clear();
      PlayerService.remoteStreamHeaders['https://www.googleapis.com/drive/v3/'] =
          driveStreamHeaders('abc');

      expect(
        PlayerService.headersForUrl(
          'https://www.googleapis.com/drive/v3/files/x?alt=media',
        ),
        {'Authorization': 'Bearer abc'},
      );
      // A Jellyfin or Navidrome URL signs itself and must not pick this up.
      expect(
        PlayerService.headersForUrl('https://music.example.com/rest/stream'),
        isNull,
      );
      PlayerService.remoteStreamHeaders.clear();
    });
  });

  group('accounts', () {
    test('a client ID is what makes the account complete', () {
      expect(_account().isComplete, isTrue);
      expect(_account(clientId: '').isComplete, isFalse);
    });

    test('holding a refresh token is what counts as signed in', () {
      // Access tokens last an hour; the refresh token is the session.
      expect(_account().isAuthenticated, isTrue);
      expect(_account(refreshToken: null).isAuthenticated, isFalse);
    });

    test('the account is titled without a host, having no server', () {
      expect(_account().title, 'Google Drive');
    });
  });

  group('tokens', () {
    test('a session round-trips through storage', () {
      final tokens = GoogleTokens(
        accessToken: 'a',
        refreshToken: 'r',
        expiresAt: DateTime.parse('2030-01-01T00:00:00Z'),
      );
      final restored = GoogleTokens.fromStorage(tokens.storage)!;

      expect(restored.accessToken, 'a');
      expect(restored.refreshToken, 'r');
      expect(restored.expiresAt, tokens.expiresAt);
      expect(restored.isExpired, isFalse);
    });

    test('no refresh token means no session at all', () {
      expect(GoogleTokens.fromStorage(const {}), isNull);
      expect(
        GoogleTokens.fromStorage(const {'access_token': 'a'}),
        isNull,
      );
    });

    test('an unreadable expiry is treated as expired', () {
      // Better to spend a refresh than to send a token that may be dead.
      final restored = GoogleTokens.fromStorage(const {
        'refresh_token': 'r',
        'expires_at': 'not a date',
      })!;
      expect(restored.isExpired, isTrue);
    });

    test('a token about to die counts as expired', () {
      expect(
        GoogleTokens(
          accessToken: 'a',
          refreshToken: 'r',
          expiresAt: DateTime.now().add(const Duration(seconds: 20)),
        ).isExpired,
        isTrue,
      );
    });
  });

  group('OAuth', () {
    const auth = GoogleOAuth(clientId: 'client-1', clientSecret: 'secret');

    test('the verifier is RFC 7636 shaped', () {
      final verifier = GoogleOAuth.createVerifier();
      expect(verifier.length, inInclusiveRange(43, 128));
      expect(RegExp(r'^[A-Za-z0-9\-._~]+$').hasMatch(verifier), isTrue);
      expect(verifier, isNot(GoogleOAuth.createVerifier()));
    });

    test('the challenge is unpadded base64url of the SHA-256', () {
      const verifier = 'abc123';
      expect(
        GoogleOAuth.challengeFor(verifier),
        base64Url
            .encode(sha256.convert(ascii.encode(verifier)).bytes)
            .replaceAll('=', ''),
      );
      expect(GoogleOAuth.challengeFor(verifier), isNot(contains('=')));
    });

    test('the authorize URL sends the challenge, never the verifier', () {
      final verifier = GoogleOAuth.createVerifier();
      final url = auth.authorizeUrl(verifier: verifier, state: 'st');

      expect(url.host, 'accounts.google.com');
      expect(url.queryParameters['code_challenge_method'], 'S256');
      expect(
        url.queryParameters['code_challenge'],
        GoogleOAuth.challengeFor(verifier),
      );
      expect(url.toString(), isNot(contains(verifier)));
    });

    test('offline access is requested, or there is no refresh token', () {
      // Without both of these Google issues no refresh token and the session
      // dies in an hour with no way to renew it.
      final url = auth.authorizeUrl(verifier: 'v', state: 's');
      expect(url.queryParameters['access_type'], 'offline');
      expect(url.queryParameters['prompt'], 'consent');
    });

    test('the scope is read-only', () {
      expect(driveScopes.single, endsWith('drive.readonly'));
      expect(
        auth.authorizeUrl(verifier: 'v', state: 's').queryParameters['scope'],
        contains('readonly'),
      );
    });

    test('the redirect is loopback only', () {
      expect(auth.redirectUri, 'http://127.0.0.1:8890');
    });

    test('signing in without a client ID fails before the browser opens', () {
      expect(
        const GoogleOAuth(clientId: '  ').authorize(),
        throwsA(
          isA<GoogleAuthException>().having(
            (e) => e.message,
            'message',
            contains('client ID'),
          ),
        ),
      );
    });

    test('the code exchange sends the verifier and the secret', () async {
      final http = _FakeHttpClient(
        body: '{"access_token":"a","refresh_token":"r","expires_in":3600}',
      );
      final tokens = await GoogleOAuth(
        clientId: 'client-1',
        clientSecret: 'secret',
        httpClient: http,
      ).exchangeCode(code: 'the-code', verifier: 'the-verifier');

      final sent = http.last.sentBody;
      expect(sent, contains('code_verifier=the-verifier'));
      expect(sent, contains('client_secret=secret'));
      expect(sent, contains('grant_type=authorization_code'));
      expect(tokens.refreshToken, 'r');
    });

    test('a client with no secret sends none', () async {
      final http = _FakeHttpClient(
        body: '{"access_token":"a","expires_in":3600}',
      );
      await GoogleOAuth(
        clientId: 'client-1',
        httpClient: http,
      ).refresh('r');

      expect(http.last.sentBody, isNot(contains('client_secret')));
    });

    test('a refresh keeps the old refresh token', () async {
      // Google only sends one on first consent, so losing it means signing in
      // again.
      final http = _FakeHttpClient(
        body: '{"access_token":"a2","expires_in":3600}',
      );
      final tokens = await GoogleOAuth(
        clientId: 'c',
        httpClient: http,
      ).refresh('original');

      expect(tokens.accessToken, 'a2');
      expect(tokens.refreshToken, 'original');
    });

    Future<String> messageFor(String body, {int status = 400}) async {
      final http = _FakeHttpClient(status: status, body: body);
      try {
        await GoogleOAuth(clientId: 'c', httpClient: http).refresh('r');
        return 'no error';
      } on GoogleAuthException catch (error) {
        return error.message;
      }
    }

    test('a revoked grant tells the user to sign in again', () async {
      expect(
        await messageFor('{"error":"invalid_grant"}'),
        contains('Sign in again'),
      );
    });

    test('a redirect mismatch names the URI to register', () async {
      expect(
        await messageFor(
          '{"error":"invalid_request",'
          '"error_description":"Bad redirect_uri"}',
        ),
        contains('127.0.0.1:8890'),
      );
    });

    test('a bad client is reported as one', () async {
      expect(
        await messageFor('{"error":"invalid_client"}'),
        contains('did not recognise'),
      );
    });

    test('a reply that is not JSON is reported, not thrown raw', () async {
      final http = _FakeHttpClient(status: 200, body: '<html>nope</html>');
      await expectLater(
        GoogleOAuth(clientId: 'c', httpClient: http).refresh('r'),
        throwsA(isA<GoogleAuthException>()),
      );
    });

    test('a success with no access token is still a failure', () async {
      expect(
        await messageFor('{"expires_in":3600}', status: 200),
        contains('no access token'),
      );
    });
  });
}
