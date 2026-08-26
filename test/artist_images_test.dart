import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pixelplay_desktop/data/artists/artist_image_repository.dart';
import 'package:pixelplay_desktop/data/db/database.dart';
import 'package:pixelplay_desktop/data/models/models.dart';

/// The point of this layer is that it does not go back to the network, so the
/// tests count requests. A fake HttpClient is the only way to see that.
class _FakeHttpClient implements HttpClient {
  _FakeHttpClient({this.searchBody, this.imageBytes, this.failWith});

  String? searchBody;
  List<int>? imageBytes;

  /// Thrown from the search request, to exercise the failure path.
  Object? failWith;

  int searchCalls = 0;
  int downloadCalls = 0;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    final isSearch = url.host == 'api.deezer.com';
    if (isSearch) {
      searchCalls++;
      if (failWith != null) throw failWith!;
      return _FakeRequest(url, body: searchBody ?? '{"data":[]}');
    }
    downloadCalls++;
    return _FakeRequest(url, bytes: imageBytes ?? const []);
  }

  @override
  void close({bool force = false}) {}

  @override
  noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName} is not used');
}

class _FakeRequest implements HttpClientRequest {
  _FakeRequest(this.uri, {this.body, this.bytes});

  @override
  final Uri uri;
  final String? body;
  final List<int>? bytes;

  @override
  final HttpHeaders headers = _FakeHeaders();

  @override
  Future<HttpClientResponse> close() async =>
      _FakeResponse(body: body, bytes: bytes);

  @override
  noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName} is not used');
}

class _FakeHeaders implements HttpHeaders {
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}

  @override
  noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName} is not used');
}

class _FakeResponse extends Stream<List<int>> implements HttpClientResponse {
  _FakeResponse({String? body, List<int>? bytes})
    : _data = bytes ?? (body == null ? const [] : body.codeUnits);

  final List<int> _data;

  @override
  int get statusCode => HttpStatus.ok;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream<List<int>>.value(_data).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName} is not used');
}

const _hit = '''
{"data":[{"id":42,"name":"Moneda Dura","picture_xl":"https://cdn/x.jpg"}]}
''';

void main() {
  late Directory tmp;
  late MusicDatabase db;
  late Artist artist;

  Artist reload() => db.allArtists().single;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('pixelplay_artists');
    db = await MusicDatabase.open(tmp.path);
    db.replaceLibrary([
      Song(
        id: '/music/a.mp3',
        title: 'Track',
        artist: 'Moneda Dura',
        artistId: 7,
        artists: const [ArtistRef(id: 7, name: 'Moneda Dura', isPrimary: true)],
        album: 'Album',
        albumId: 1,
        path: '/music/a.mp3',
        duration: 1000,
      ),
    ]);
    artist = reload();
  });

  tearDown(() async {
    db.close();
    await tmp.delete(recursive: true);
  });

  ArtistImageRepository repository(_FakeHttpClient client) =>
      ArtistImageRepository(db, tmp.path, httpClient: client);

  test('a fresh artist has never been looked up', () {
    expect(artist.imageStatus, ArtistImageStatus.unknown);
    expect(artist.imageLookedUp, isFalse);
    expect(artist.effectiveImageUrl, isNull);
  });

  test('a successful fetch is cached and not repeated', () async {
    final client = _FakeHttpClient(searchBody: _hit, imageBytes: [1, 2, 3]);
    final result = await repository(client).fetch(artist);

    expect(result.imageStatus, ArtistImageStatus.ok);
    expect(result.effectiveImageUrl, isNotNull);
    expect(File(result.effectiveImageUrl!).existsSync(), isTrue);
    expect(client.searchCalls, 1);
    expect(client.downloadCalls, 1);

    // Opening the artist again must not touch the network.
    await repository(client).fetch(reload());
    expect(client.searchCalls, 1, reason: 'served from the cache');
    expect(client.downloadCalls, 1);
  });

  test('"no such artist" is remembered, so it is not asked again', () async {
    final client = _FakeHttpClient(searchBody: '{"data":[]}');
    final result = await repository(client).fetch(artist);

    expect(result.imageStatus, ArtistImageStatus.notFound);
    expect(result.imageError, isNull, reason: 'a miss is not an error');
    expect(client.searchCalls, 1);

    await repository(client).fetch(reload());
    expect(client.searchCalls, 1, reason: 'a recorded miss is respected');
  });

  test('a failure is recorded with a readable reason', () async {
    final client = _FakeHttpClient(
      failWith: const SocketException('nope'),
    );
    final result = await repository(client).fetch(artist);

    expect(result.imageStatus, ArtistImageStatus.failed);
    expect(result.imageStatus.isFailure, isTrue);
    expect(result.imageError, 'No connection');
    expect(client.searchCalls, 1);

    // Auto-fetch does not hammer a failing endpoint on every visit...
    await repository(client).fetch(reload());
    expect(client.searchCalls, 1);

    // ...but the retry on the avatar forces it, and can then succeed.
    final retryClient = _FakeHttpClient(
      searchBody: _hit,
      imageBytes: [4, 5, 6],
    );
    final retried = await repository(retryClient).fetch(reload(), force: true);
    expect(retryClient.searchCalls, 1);
    expect(retried.imageStatus, ArtistImageStatus.ok);
    expect(retried.imageError, isNull);
  });

  test('a rescan does not lose the picture or the lookup history', () async {
    final client = _FakeHttpClient(searchBody: _hit, imageBytes: [1, 2, 3]);
    await repository(client).fetch(artist);
    final path = reload().effectiveImageUrl;
    expect(path, isNotNull);

    // replaceLibrary clears `artists`, which is exactly why the cache lives in
    // its own table. Before that it wiped every downloaded picture.
    db.replaceLibrary([
      Song(
        id: '/music/a.mp3',
        title: 'Track',
        artist: 'Moneda Dura',
        artistId: 7,
        artists: const [ArtistRef(id: 7, name: 'Moneda Dura', isPrimary: true)],
        album: 'Album',
        albumId: 1,
        path: '/music/a.mp3',
        duration: 1000,
      ),
    ]);

    final after = reload();
    expect(after.effectiveImageUrl, path, reason: 'survived the rescan');
    expect(after.imageStatus, ArtistImageStatus.ok);
    await repository(client).fetch(after);
    expect(client.searchCalls, 1, reason: 'and still no refetch');
  });

  test('a chosen picture wins and is copied into the cache', () async {
    final source = File(p.join(tmp.path, 'mine.png'))
      ..writeAsBytesSync([9, 9, 9]);
    final client = _FakeHttpClient(searchBody: _hit, imageBytes: [1, 2, 3]);
    await repository(client).fetch(artist);

    final stored = await repository(client).setCustomImage(reload(), source);
    expect(p.isWithin(tmp.path, stored), isTrue, reason: 'copied, not linked');

    final after = reload();
    expect(after.customImageUri, stored);
    expect(
      after.effectiveImageUrl,
      stored,
      reason: 'the chosen picture takes precedence over the downloaded one',
    );

    // Deleting the original must not break the library.
    source.deleteSync();
    expect(File(reload().effectiveImageUrl!).existsSync(), isTrue);
  });

  test('clearing forgets the outcome so the next visit looks again', () async {
    final client = _FakeHttpClient(searchBody: _hit, imageBytes: [1, 2, 3]);
    await repository(client).fetch(artist);
    expect(reload().imageLookedUp, isTrue);

    repository(client).clear(reload());
    final cleared = reload();
    expect(cleared.effectiveImageUrl, isNull);
    expect(cleared.imageLookedUp, isFalse);

    await repository(client).fetch(cleared);
    expect(client.searchCalls, 2, reason: 'looked up afresh after clearing');
  });

  test('the batch fetch only visits artists never looked up', () async {
    final client = _FakeHttpClient(searchBody: '{"data":[]}');
    await repository(client).fetch(artist);
    expect(db.artistsMissingImages(), isEmpty);

    await repository(client).fetchMissing().drain<void>();
    expect(client.searchCalls, 1, reason: 'nothing left to look up');
  });
}
