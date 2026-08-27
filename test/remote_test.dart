import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixelplay_desktop/data/remote/jellyfin_source.dart';
import 'package:pixelplay_desktop/data/remote/navidrome_source.dart';
import 'package:pixelplay_desktop/data/remote/remote_account.dart';
import 'package:pixelplay_desktop/data/remote/remote_source.dart';

/// No servers here, so every request goes through a fake. That also lets the
/// tests assert what was *sent* — the signing is the part a live server would
/// silently accept or reject without telling you why.
class _FakeHttpClient implements HttpClient {
  _FakeHttpClient({this.status = 200, this.body = '{}', this.throwing});

  int status;
  String body;
  Object? throwing;

  /// Successive replies, for the paged and multi-call paths.
  final List<({int status, String body})> queued = [];
  final List<_FakeRequest> requests = [];

  _FakeRequest get last => requests.last;

  ({int status, String body}) _next() =>
      queued.isNotEmpty ? queued.removeAt(0) : (status: status, body: body);

  @override
  Future<HttpClientRequest> getUrl(Uri url) async => _make(url, 'GET');

  @override
  Future<HttpClientRequest> postUrl(Uri url) async => _make(url, 'POST');

  @override
  Future<HttpClientRequest> deleteUrl(Uri url) async => _make(url, 'DELETE');

  _FakeRequest _make(Uri url, String method) {
    if (throwing != null) throw throwing!;
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
  _FakeRequest(this.uri, this.method, {required this.status, required this.body});

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

/// Fixed sequence, so a signed URL is reproducible in a test.
class _FixedRandom implements Random {
  @override
  int nextInt(int max) => 7 % max;

  @override
  noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName} is not used');
}

RemoteAccount _navidrome({String url = 'https://music.example.com'}) =>
    RemoteAccount(
      id: 'nd-1',
      kind: RemoteKind.navidrome,
      serverUrl: url,
      username: 'elieser',
      password: 'hunter2',
    );

RemoteAccount _jellyfin({String? token = 'tok-abc', String? userId = 'u-1'}) =>
    RemoteAccount(
      id: 'jf-1',
      kind: RemoteKind.jellyfin,
      serverUrl: 'https://jelly.example.com',
      username: 'elieser',
      password: 'hunter2',
      accessToken: token,
      userId: userId,
    );

String _subsonic(Map<String, Object?> payload) => jsonEncode({
  'subsonic-response': {'status': 'ok', 'version': '1.16.1', ...payload},
});

void main() {
  group('account', () {
    test('a bare host gets https and loses a trailing slash', () {
      expect(
        _navidrome(url: 'music.example.com/').normalizedUrl,
        'https://music.example.com',
      );
      expect(
        _navidrome(url: 'http://nas:4533//').normalizedUrl,
        'http://nas:4533',
      );
    });

    test('a plain http address is left alone', () {
      // A self-hosted server on a LAN is usually http, and silently upgrading
      // it to https would just fail to connect.
      expect(
        _navidrome(url: 'http://192.168.1.4:4533').normalizedUrl,
        'http://192.168.1.4:4533',
      );
    });

    test('it round-trips through storage', () {
      final account = _jellyfin();
      final restored = RemoteAccount.fromJson(account.toJson());
      expect(restored.id, account.id);
      expect(restored.kind, RemoteKind.jellyfin);
      expect(restored.accessToken, 'tok-abc');
      expect(restored.userId, 'u-1');
      expect(restored.password, 'hunter2');
    });

    test('Jellyfin needs a token and a user id, Subsonic does not', () {
      expect(_jellyfin().isAuthenticated, isTrue);
      expect(_jellyfin(token: null).isAuthenticated, isFalse);
      expect(_jellyfin(userId: null).isAuthenticated, isFalse);
      expect(_navidrome().isAuthenticated, isTrue);
    });

    test('song ids carry the account, and come back apart', () {
      final id = remoteSongId(_navidrome(), 'track-9');
      expect(id, 'navidrome:nd-1:track-9');
      expect(remoteItemId(id), 'track-9');
      expect(isRemoteSongId(id), isTrue);
      // A local song is an absolute path, which must not be mistaken for one.
      expect(isRemoteSongId('/home/me/Music/a.mp3'), isFalse);
      expect(remoteItemId('/home/me/Music/a.mp3'), isNull);
    });

    test('an item id containing a colon survives the round trip', () {
      final id = remoteSongId(_jellyfin(), 'weird:id:9');
      expect(remoteItemId(id), 'weird:id:9');
    });
  });

  group('navidrome', () {
    NavidromeSource source(_FakeHttpClient http) =>
        NavidromeSource(_navidrome(), httpClient: http, random: _FixedRandom());

    test('requests are signed with a salted md5, never the password', () async {
      final http = _FakeHttpClient(body: _subsonic({}));
      await source(http).connect();

      final uri = http.last.uri;
      expect(uri.path, '/rest/ping.view');
      final salt = uri.queryParameters['s']!;
      expect(salt, hasLength(12));
      expect(
        uri.queryParameters['t'],
        md5.convert(utf8.encode('hunter2$salt')).toString(),
      );
      expect(uri.queryParameters['u'], 'elieser');
      expect(uri.queryParameters['f'], 'json');
      // The password itself must never appear in the request.
      expect(uri.toString(), isNot(contains('hunter2')));
    });

    test('the salt changes between requests', () async {
      // A reused salt would make the token a stand-in for the password.
      final http = _FakeHttpClient(body: _subsonic({}));
      final real = NavidromeSource(_navidrome(), httpClient: http);
      await real.connect();
      await real.connect();
      expect(
        http.requests[0].uri.queryParameters['s'],
        isNot(http.requests[1].uri.queryParameters['s']),
      );
    });

    test('a failure inside a 200 is reported', () async {
      // Subsonic answers 200 and puts the error in the envelope.
      final http = _FakeHttpClient(
        body: jsonEncode({
          'subsonic-response': {
            'status': 'failed',
            'error': {'code': 40, 'message': 'Wrong username or password.'},
          },
        }),
      );
      await expectLater(
        source(http).connect(),
        throwsA(
          isA<RemoteException>().having(
            (e) => e.message,
            'message',
            contains('rejected that username or password'),
          ),
        ),
      );
    });

    test('a non-Subsonic server is called out', () async {
      final http = _FakeHttpClient(body: '{"hello":"world"}');
      await expectLater(
        source(http).connect(),
        throwsA(
          isA<RemoteException>().having(
            (e) => e.message,
            'message',
            contains('not answer like a Subsonic server'),
          ),
        ),
      );
    });

    test('albums and their tracks become playable songs', () async {
      final http = _FakeHttpClient()
        ..queued.addAll([
          (
            status: 200,
            body: _subsonic({
              'albumList2': {
                'album': [
                  {'id': 'al-1', 'name': 'Sin Blasfemias'},
                ],
              },
            }),
          ),
          (
            status: 200,
            body: _subsonic({
              'album': {
                'id': 'al-1',
                'song': [
                  {
                    'id': 'tr-1',
                    'title': 'Al Sudeste',
                    'artist': 'Moneda Dura',
                    'album': 'Sin Blasfemias',
                    'duration': 249,
                    'track': 3,
                    'year': 2001,
                    'genre': 'Rock',
                    'bitRate': 320,
                    'contentType': 'audio/mpeg',
                    'starred': '2024-01-01T00:00:00Z',
                  },
                ],
              },
            }),
          ),
        ]);

      final songs = await source(http).songs();
      expect(songs, hasLength(1));
      final song = songs.single;
      expect(song.id, 'navidrome:nd-1:tr-1');
      expect(song.title, 'Al Sudeste');
      expect(song.duration, 249000, reason: 'seconds become milliseconds');
      expect(song.trackNumber, 3);
      expect(song.isFavorite, isTrue, reason: 'starred');
      expect(song.bitrate, 320);

      // The path has to be a URL the player can open directly.
      final path = Uri.parse(song.path);
      expect(path.scheme, 'https');
      expect(path.path, '/rest/stream.view');
      expect(path.queryParameters['id'], 'tr-1');
      expect(path.queryParameters['t'], isNotNull);
      expect(song.albumArtPath, contains('/rest/getCoverArt.view'));
    });

    test('a short page ends the walk instead of looping', () async {
      final http = _FakeHttpClient(body: _subsonic({}));
      final songs = await source(http).songs();
      expect(songs, isEmpty);
      expect(http.requests, hasLength(1));
    });

    test('no connection is reported in plain language', () async {
      final http = _FakeHttpClient(
        throwing: const SocketException('no route to host'),
      );
      await expectLater(
        source(http).connect(),
        throwsA(
          isA<RemoteException>().having(
            (e) => e.message,
            'message',
            contains('Could not reach music.example.com'),
          ),
        ),
      );
    });
  });

  group('jellyfin', () {
    JellyfinSource source(_FakeHttpClient http, {RemoteAccount? account}) =>
        JellyfinSource(account ?? _jellyfin(), httpClient: http);

    test('login posts the password and keeps what came back', () async {
      final http = _FakeHttpClient(
        body: jsonEncode({
          'AccessToken': 'tok-new',
          'User': {'Id': 'user-42', 'Name': 'Elieser'},
        }),
      );
      final connected = await source(
        http,
        account: _jellyfin(token: null, userId: null),
      ).connect();

      expect(http.last.uri.path, '/Users/AuthenticateByName');
      expect(http.last.method, 'POST');
      expect(jsonDecode(http.last.sentBody), {
        'Username': 'elieser',
        'Pw': 'hunter2',
      });
      // The login request must not carry a stale token.
      final auth = (http.last.headers as _FakeHeaders).values['authorization']!;
      expect(auth, contains('MediaBrowser Client="PixelPlayer"'));
      expect(auth, isNot(contains('Token=')));

      expect(connected.accessToken, 'tok-new');
      expect(connected.userId, 'user-42');
      expect(connected.displayName, 'Elieser');
    });

    test('a login that returns no token is an error, not a silent success', () async {
      final http = _FakeHttpClient(body: jsonEncode({'User': {'Id': 'u'}}));
      await expectLater(
        source(http, account: _jellyfin(token: null)).connect(),
        throwsA(isA<RemoteException>()),
      );
    });

    test('bad credentials are reported as such', () async {
      final http = _FakeHttpClient(status: 401, body: 'Unauthorized');
      await expectLater(
        source(http, account: _jellyfin(token: null)).connect(),
        throwsA(
          isA<RemoteException>()
              .having((e) => e.message, 'message', contains('rejected'))
              .having((e) => e.statusCode, 'status', 401),
        ),
      );
    });

    test('item queries carry the token in a header', () async {
      final http = _FakeHttpClient(body: jsonEncode({'Items': []}));
      await source(http).songs();

      expect(http.last.uri.path, '/Users/u-1/Items');
      expect(http.last.uri.queryParameters['IncludeItemTypes'], 'Audio');
      expect(http.last.uri.queryParameters['Recursive'], 'true');
      expect(
        (http.last.headers as _FakeHeaders).values['authorization'],
        contains('Token="tok-abc"'),
      );
      // The browse request keeps the token out of the URL.
      expect(http.last.uri.toString(), isNot(contains('tok-abc')));
    });

    test('items become playable songs, with ticks converted', () async {
      final http = _FakeHttpClient(
        body: jsonEncode({
          'Items': [
            {
              'Id': 'item-1',
              'Name': 'Como Fué',
              'Album': 'Mágico',
              'AlbumId': 'al-9',
              'AlbumArtist': 'Benny Moré',
              'Artists': ['Benny Moré'],
              // 3:29 in Jellyfin's 100-nanosecond ticks.
              'RunTimeTicks': 2090000000,
              'IndexNumber': 2,
              'ProductionYear': 1959,
              'Genres': ['Son'],
              'UserData': {'IsFavorite': true},
            },
          ],
        }),
      );

      final songs = await source(http).songs();
      final song = songs.single;
      expect(song.id, 'jellyfin:jf-1:item-1');
      expect(song.title, 'Como Fué');
      expect(song.duration, 209000);
      expect(song.trackNumber, 2);
      expect(song.year, 1959);
      expect(song.genre, 'Son');
      expect(song.isFavorite, isTrue);

      // mpv fetches the stream itself and cannot send the header, so this one
      // URL carries the key.
      final path = Uri.parse(song.path);
      expect(path.path, '/Audio/item-1/stream');
      expect(path.queryParameters['static'], 'true');
      expect(path.queryParameters['api_key'], 'tok-abc');
      expect(song.albumArtPath, contains('/Items/al-9/Images/Primary'));
    });

    test('browsing without a token fails before the request', () async {
      final http = _FakeHttpClient();
      await expectLater(
        source(http, account: _jellyfin(token: null)).songs(),
        throwsA(isA<RemoteException>()),
      );
      expect(http.requests, isEmpty);
    });

    test('paging stops on a short page', () async {
      final http = _FakeHttpClient(body: jsonEncode({'Items': []}));
      await source(http).songs();
      expect(http.requests, hasLength(1));
    });
  });
}
