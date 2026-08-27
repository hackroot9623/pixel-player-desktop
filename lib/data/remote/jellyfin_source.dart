import 'dart:io';

import '../models/models.dart';
import 'remote_account.dart';
import 'remote_source.dart';

/// Port of `JellyfinApiService` + `JellyfinRepository`.
///
/// Jellyfin authenticates once and then wants the token in an `Authorization:
/// MediaBrowser …` header. Stream URLs are the exception: mpv fetches those
/// itself and cannot carry the header, so those alone use `api_key`, which is
/// the mechanism Jellyfin documents for exactly this case.
class JellyfinSource extends RemoteSource {
  JellyfinSource(super.account, {super.httpClient, super.timeout});

  static const clientName = 'PixelPlayer';
  static const clientVersion = '1.0.0';
  static const deviceName = 'Desktop';

  /// Stable per install would be better, but the server only uses this to name
  /// the session in its dashboard.
  static const deviceId = 'pixelplay-desktop';

  String _authHeader({String? token}) {
    final base =
        'MediaBrowser Client="$clientName", Device="$deviceName", '
        'DeviceId="$deviceId", Version="$clientVersion"';
    final actual = token ?? account.accessToken;
    return actual == null || actual.isEmpty ? base : '$base, Token="$actual"';
  }

  @override
  void authorise(HttpClientRequest request) =>
      request.headers.set(HttpHeaders.authorizationHeader, _authHeader());

  @override
  Future<RemoteAccount> connect() async {
    final response = await postJson(
      Uri.parse('${account.normalizedUrl}/Users/AuthenticateByName'),
      {'Username': account.username, 'Pw': account.password},
      headers: {HttpHeaders.authorizationHeader: _authHeader(token: '')},
    );

    final token = response['AccessToken'];
    final user = response['User'];
    final userId = user is Map ? user['Id'] : null;
    if (token is! String || userId is! String) {
      throw const RemoteException(
        'The server accepted the login but returned no token.',
      );
    }
    return account.copyWith(
      accessToken: token,
      userId: userId,
      displayName: account.displayName ??
          (user is Map ? user['Name'] as String? : null),
    );
  }

  @override
  Future<List<Song>> songs() async {
    if (!account.isAuthenticated) {
      throw const RemoteException('Sign in to this server first.');
    }

    final songs = <Song>[];
    const pageSize = 500;
    for (var index = 0; ; index += pageSize) {
      final response = await getJson(
        Uri.parse('${account.normalizedUrl}/Users/${account.userId}/Items')
            .replace(
              queryParameters: {
                'IncludeItemTypes': 'Audio',
                'Recursive': 'true',
                'SortBy': 'Album,SortName',
                'SortOrder': 'Ascending',
                'Fields': 'Genres,MediaSources,ParentId',
                'StartIndex': '$index',
                'Limit': '$pageSize',
              },
            ),
      );
      final items = response['Items'];
      if (items is! List || items.isEmpty) break;
      for (final item in items.whereType<Map<String, Object?>>()) {
        final song = _song(item);
        if (song != null) songs.add(song);
      }
      if (items.length < pageSize) break;
    }
    return songs;
  }

  Song? _song(Map<String, Object?> item) {
    final id = item['Id'];
    if (id is! String) return null;
    final artist = (item['AlbumArtist'] as String?) ??
        ((item['Artists'] as List?)?.whereType<String>().firstOrNull) ??
        'Unknown artist';
    final album = item['Album'] as String? ?? 'Unknown album';
    final artistId = ((item['AlbumArtistId'] as String?) ?? artist).hashCode.abs();
    final albumId = ((item['AlbumId'] as String?) ?? album).hashCode.abs();
    // Jellyfin reports durations in ticks: 10,000 per millisecond.
    final ticks = (item['RunTimeTicks'] as num?)?.toInt() ?? 0;

    return Song(
      id: remoteSongId(account, id),
      title: item['Name'] as String? ?? 'Unknown',
      artist: artist,
      artistId: artistId,
      artists: [
        for (final name
            in (item['Artists'] as List?)?.whereType<String>() ?? [artist])
          ArtistRef(id: name.hashCode.abs(), name: name, isPrimary: name == artist),
      ],
      album: album,
      albumId: albumId,
      albumArtist: item['AlbumArtist'] as String?,
      path: streamUrl(id).toString(),
      albumArtPath: artUrl(item['AlbumId'] as String? ?? id),
      duration: ticks ~/ 10000,
      genre: (item['Genres'] as List?)?.whereType<String>().firstOrNull,
      trackNumber: (item['IndexNumber'] as num?)?.toInt() ?? 0,
      discNumber: (item['ParentIndexNumber'] as num?)?.toInt(),
      year: (item['ProductionYear'] as num?)?.toInt() ?? 0,
      isFavorite:
          (item['UserData'] as Map?)?['IsFavorite'] as bool? ?? false,
    );
  }

  /// `static=true` asks for the original file rather than a transcode.
  Uri streamUrl(String itemId) =>
      Uri.parse('${account.normalizedUrl}/Audio/$itemId/stream').replace(
        queryParameters: {
          'static': 'true',
          if (account.accessToken != null) 'api_key': account.accessToken!,
        },
      );

  @override
  String? artUrl(String itemId, {int size = 512}) =>
      Uri.parse('${account.normalizedUrl}/Items/$itemId/Images/Primary')
          .replace(
            queryParameters: {
              'maxWidth': '$size',
              if (account.accessToken != null) 'api_key': account.accessToken!,
            },
          )
          .toString();

  /// Mirrors a like back to the server.
  Future<void> setFavorite(String itemId, {required bool favorite}) async {
    final uri = Uri.parse(
      '${account.normalizedUrl}/Users/${account.userId}/FavoriteItems/$itemId',
    );
    if (favorite) {
      await postJson(uri, const {});
    } else {
      // Jellyfin uses DELETE to unfavourite; the reply carries no body worth
      // parsing, so a bare request is enough.
      final request = await http.deleteUrl(uri);
      authorise(request);
      await request.close();
    }
  }
}
