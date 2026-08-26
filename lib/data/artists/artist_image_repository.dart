import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../db/database.dart';
import '../models/models.dart';

/// Ported from `data/image/` + the Deezer half of `ArtistSettingsScreen`.
///
/// Android keeps an LRU memory cache plus a database cache; here the downloaded
/// file *is* the cache, and its path plus the lookup outcome live in
/// `artist_images` — a table deliberately outside `artists`, which a rescan
/// clears. So a restart costs nothing, offline still shows the picture, and a
/// miss is not retried on every visit.
class ArtistImageRepository {
  ArtistImageRepository(this._db, this._artworkDir, {HttpClient? httpClient})
    : _client = httpClient ?? (HttpClient()..connectionTimeout = _timeout);

  static const _timeout = Duration(seconds: 10);
  static const _userAgent =
      'PixelPlayerDesktop (https://github.com/PixelPlayerHQ/PixelPlayer)';

  final MusicDatabase _db;
  final String _artworkDir;
  final HttpClient _client;

  void dispose() => _client.close(force: true);

  Directory get _dir => Directory(p.join(_artworkDir, 'artists'));

  /// Resolves an image for [artist], consulting the cache first.
  ///
  /// Every outcome is written to the cache, including "no such artist" and
  /// failures, so opening the artist again does not repeat the request. Only a
  /// [force]d call (the retry on the avatar) goes back to the network after a
  /// recorded result.
  Future<Artist> fetch(Artist artist, {bool force = false}) async {
    final cached = artist.effectiveImageUrl;
    if (!force && cached != null && File(cached).existsSync()) return artist;

    // A recorded miss or failure is respected until the user asks again.
    if (!force && artist.imageLookedUp) return artist;

    final ({int? id, String? name, String url}) match;
    try {
      final found = await _lookup(artist.name);
      if (found == null) {
        _db.saveArtistImage(artist.id, status: ArtistImageStatus.notFound);
        return _reload(artist);
      }
      match = found;
    } on Exception catch (error) {
      _db.saveArtistImage(
        artist.id,
        status: ArtistImageStatus.failed,
        error: _readable(error),
      );
      return _reload(artist);
    }

    try {
      final bytes = await _download(match.url);
      if (bytes == null || bytes.isEmpty) {
        _db.saveArtistImage(
          artist.id,
          status: ArtistImageStatus.failed,
          error: 'The image could not be downloaded',
        );
        return _reload(artist);
      }
      await _dir.create(recursive: true);
      final file = File(p.join(_dir.path, '${artist.id}.jpg'));
      await file.writeAsBytes(bytes);
      _db.saveArtistImage(
        artist.id,
        imagePath: file.path,
        remoteId: match.id,
        remoteName: match.name,
        status: ArtistImageStatus.ok,
      );
      return _reload(artist);
    } on Exception catch (error) {
      _db.saveArtistImage(
        artist.id,
        status: ArtistImageStatus.failed,
        error: _readable(error),
      );
      return _reload(artist);
    }
  }

  /// Re-reads the row so callers get the stored status, not a stale copy.
  Artist _reload(Artist artist) => _db.artist(artist.id) ?? artist;

  String _readable(Object error) => switch (error) {
    SocketException() => 'No connection',
    HttpException(:final message) => message,
    _ => 'Lookup failed',
  };

  /// Fills in every artist that has never been looked up, reporting progress.
  Stream<(int done, int total)> fetchMissing() async* {
    final missing = _db.artistsMissingImages();
    for (var i = 0; i < missing.length; i++) {
      await fetch(missing[i]);
      yield (i + 1, missing.length);
    }
  }

  /// A picture the user picked. Copied into the cache directory so the library
  /// does not break if they move or delete the original.
  Future<String> setCustomImage(Artist artist, File source) async {
    await _dir.create(recursive: true);
    final destination = File(
      p.join(_dir.path, 'custom-${artist.id}${p.extension(source.path)}'),
    );
    await source.copy(destination.path);
    _db.setArtistCustomImage(artist.id, destination.path);
    return destination.path;
  }

  void clearCustomImage(Artist artist) =>
      _db.setArtistCustomImage(artist.id, null);

  /// Forgets everything cached for an artist, including the recorded outcome,
  /// so the next visit looks it up afresh.
  void clear(Artist artist) {
    for (final path in [artist.imageUrl, artist.customImageUri]) {
      if (path == null) continue;
      final file = File(path);
      if (file.existsSync() && p.isWithin(_dir.path, path)) file.deleteSync();
    }
    _db.clearArtistImage(artist.id);
  }

  /// `GET /search/artist` on Deezer's public API — no key required.
  ///
  /// Returns null when there is genuinely no match. Throws when the lookup
  /// itself failed, so the two can be cached differently.
  Future<({int? id, String? name, String url})?> _lookup(String name) async {
    final uri = Uri.https('api.deezer.com', '/search/artist', {
      'q': name,
      'limit': '1',
    });
    final request = await _client.getUrl(uri).timeout(_timeout);
    request.headers.set(HttpHeaders.userAgentHeader, _userAgent);
    final response = await request.close().timeout(_timeout);
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>();
      throw HttpException('Deezer returned ${response.statusCode}', uri: uri);
    }
    final json = jsonDecode(await response.transform(utf8.decoder).join());
    if (json is! Map<String, dynamic>) return null;
    final data = json['data'];
    if (data is! List || data.isEmpty) return null;
    final artist = data.first;
    if (artist is! Map<String, dynamic>) return null;
    // Prefer the largest, falling back through the sizes Deezer offers.
    for (final key in ['picture_xl', 'picture_big', 'picture_medium']) {
      final url = artist[key];
      if (url is String && url.isNotEmpty) {
        return (
          id: (artist['id'] as num?)?.toInt(),
          name: artist['name'] as String?,
          url: url,
        );
      }
    }
    return null;
  }

  Future<List<int>?> _download(String url) async {
    final request = await _client.getUrl(Uri.parse(url)).timeout(_timeout);
    request.headers.set(HttpHeaders.userAgentHeader, _userAgent);
    final response = await request.close().timeout(_timeout);
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>();
      return null;
    }
    final bytes = <int>[];
    await response.forEach(bytes.addAll);
    return bytes;
  }
}
