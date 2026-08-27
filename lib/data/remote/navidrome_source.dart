import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import '../models/models.dart';
import 'remote_account.dart';
import 'remote_source.dart';

/// Port of `NavidromeApiService` + `NavidromeRepository`.
///
/// Subsonic's API: every call is `/rest/<method>.view` with the credentials in
/// the query string, authenticated as `t=md5(password + salt)` with a fresh
/// random salt per request, so the password itself never goes over the wire.
class NavidromeSource extends RemoteSource {
  NavidromeSource(
    super.account, {
    super.httpClient,
    super.timeout,
    Random? random,
  }) : _random = random ?? Random.secure();

  /// Injectable so a test can assert the exact signed URL.
  final Random _random;

  static const apiVersion = '1.16.1';
  static const clientName = 'PixelPlayer';

  /// The salt is per request, as the spec intends: a fixed salt would turn the
  /// token into a password-equivalent that never changes.
  String _salt() {
    const alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789';
    return List.generate(
      12,
      (_) => alphabet[_random.nextInt(alphabet.length)],
    ).join();
  }

  /// Signed URL for one Subsonic method.
  ///
  /// The credentials travel in the query string because the protocol has no
  /// other channel — which is also why the stream URL can be handed straight to
  /// mpv. It only ever addresses the user's own server.
  Uri uriFor(String method, [Map<String, String> params = const {}]) {
    final salt = _salt();
    final token = md5.convert(utf8.encode('${account.password}$salt')).toString();
    return Uri.parse('${account.normalizedUrl}/rest/$method.view').replace(
      queryParameters: {
        'u': account.username,
        't': token,
        's': salt,
        'v': apiVersion,
        'c': clientName,
        'f': 'json',
        ...params,
      },
    );
  }

  /// Unwraps the `subsonic-response` envelope, which reports its own failures
  /// inside a 200.
  Future<Map<String, Object?>> _call(
    String method, [
    Map<String, String> params = const {},
  ]) async {
    final json = await getJson(uriFor(method, params));
    final response = json['subsonic-response'];
    if (response is! Map<String, Object?>) {
      throw const RemoteException(
        'That server did not answer like a Subsonic server. Check the address.',
      );
    }
    if (response['status'] == 'failed') {
      final error = response['error'];
      final message = error is Map ? error['message'] : null;
      final code = error is Map ? error['code'] : null;
      throw RemoteException(
        // 40 is "wrong username or password" in the Subsonic spec.
        code == 40
            ? 'The server rejected that username or password.'
            : 'The server refused the request${message == null ? '' : ': $message'}',
        detail: message is String ? message : null,
      );
    }
    return response;
  }

  @override
  Future<RemoteAccount> connect() async {
    await _call('ping');
    // Subsonic has no session to keep: a successful ping is the whole login.
    return account;
  }

  @override
  Future<List<Song>> songs() async {
    // Walking albums is the only portable way to enumerate a Subsonic library:
    // there is no "all songs" method, and search3 caps out.
    final albums = <Map<String, Object?>>[];
    const pageSize = 500;
    for (var offset = 0; ; offset += pageSize) {
      final response = await _call('getAlbumList2', {
        'type': 'alphabeticalByName',
        'size': '$pageSize',
        'offset': '$offset',
      });
      final list = response['albumList2'];
      final page = list is Map ? list['album'] : null;
      if (page is! List || page.isEmpty) break;
      albums.addAll(page.whereType<Map<String, Object?>>());
      if (page.length < pageSize) break;
    }

    final songs = <Song>[];
    for (final album in albums) {
      final id = album['id'];
      if (id is! String) continue;
      final response = await _call('getAlbum', {'id': id});
      final detail = response['album'];
      final tracks = detail is Map ? detail['song'] : null;
      if (tracks is! List) continue;
      for (final track in tracks.whereType<Map<String, Object?>>()) {
        final song = _song(track);
        if (song != null) songs.add(song);
      }
    }
    return songs;
  }

  Song? _song(Map<String, Object?> track) {
    final id = track['id'];
    if (id is! String) return null;
    final title = track['title'] as String? ?? 'Unknown';
    final artist = track['artist'] as String? ?? 'Unknown artist';
    final album = track['album'] as String? ?? 'Unknown album';
    // Subsonic ids are opaque strings; hash them for the int fields the local
    // model uses for grouping.
    final artistId = (track['artistId'] as String? ?? artist).hashCode.abs();
    final albumId = (track['albumId'] as String? ?? album).hashCode.abs();

    return Song(
      id: remoteSongId(account, id),
      title: title,
      artist: artist,
      artistId: artistId,
      artists: [ArtistRef(id: artistId, name: artist, isPrimary: true)],
      album: album,
      albumId: albumId,
      albumArtist: track['albumArtist'] as String?,
      // Already signed, so the player can open it as-is.
      path: streamUrl(id).toString(),
      albumArtPath: artUrl(id),
      duration: ((track['duration'] as num?)?.toInt() ?? 0) * 1000,
      genre: track['genre'] as String?,
      trackNumber: (track['track'] as num?)?.toInt() ?? 0,
      discNumber: (track['discNumber'] as num?)?.toInt(),
      year: (track['year'] as num?)?.toInt() ?? 0,
      mimeType: track['contentType'] as String?,
      bitrate: (track['bitRate'] as num?)?.toInt(),
      isFavorite: track['starred'] != null,
    );
  }

  /// `stream.view` transcodes on demand; `maxBitRate: 0` means "as uploaded".
  Uri streamUrl(String itemId, {int maxBitRate = 0}) => uriFor('stream', {
    'id': itemId,
    if (maxBitRate > 0) 'maxBitRate': '$maxBitRate',
  });

  @override
  String? artUrl(String itemId, {int size = 512}) =>
      uriFor('getCoverArt', {'id': itemId, 'size': '$size'}).toString();

  /// Star and unstar, so a like made here survives on the server.
  Future<void> setStarred(String itemId, {required bool starred}) =>
      _call(starred ? 'star' : 'unstar', {'id': itemId});
}
