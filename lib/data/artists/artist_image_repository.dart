import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../db/database.dart';
import '../models/models.dart';

/// Ported from `data/image/` + the Deezer half of `ArtistSettingsScreen`.
///
/// Android keeps an LRU memory cache plus a database cache; here the downloaded
/// file *is* the cache — the path is stored on the artist row, so a restart
/// costs nothing and offline still shows the picture.
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

  /// Downloads and caches an image for [artist], returning its local path.
  ///
  /// Returns null when Deezer has no match or the network is unavailable —
  /// neither is an error for a local music player.
  Future<String?> fetch(Artist artist) async {
    final existing = artist.effectiveImageUrl;
    if (existing != null && File(existing).existsSync()) return existing;

    final url = await _lookup(artist.name);
    if (url == null) return null;

    final bytes = await _download(url);
    if (bytes == null || bytes.isEmpty) return null;

    await _dir.create(recursive: true);
    final file = File(p.join(_dir.path, '${artist.id}.jpg'));
    await file.writeAsBytes(bytes);
    _db.setArtistImage(artist.id, file.path);
    return file.path;
  }

  /// Fills in every artist that has no picture yet, reporting progress.
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

  /// Forgets both images for an artist, leaving the placeholder.
  void clear(Artist artist) {
    for (final path in [artist.imageUrl, artist.customImageUri]) {
      if (path == null) continue;
      final file = File(path);
      if (file.existsSync() && p.isWithin(_dir.path, path)) file.deleteSync();
    }
    _db.setArtistImage(artist.id, null);
    _db.setArtistCustomImage(artist.id, null);
  }

  /// `GET /search/artist` on Deezer's public API — no key required.
  Future<String?> _lookup(String name) async {
    try {
      final uri = Uri.https('api.deezer.com', '/search/artist', {
        'q': name,
        'limit': '1',
      });
      final request = await _client.getUrl(uri).timeout(_timeout);
      request.headers.set(HttpHeaders.userAgentHeader, _userAgent);
      final response = await request.close().timeout(_timeout);
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        return null;
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
        if (url is String && url.isNotEmpty) return url;
      }
      return null;
    } on SocketException {
      return null;
    } on HttpException {
      return null;
    }
  }

  Future<List<int>?> _download(String url) async {
    try {
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
    } on SocketException {
      return null;
    } on HttpException {
      return null;
    }
  }
}
