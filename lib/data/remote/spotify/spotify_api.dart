import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'spotify_auth.dart';
import 'spotify_match.dart';

// The read-only slice of the Spotify Web API the importer needs.
//
// Deliberately small: playlists, their tracks, and saved tracks and albums.
// Nothing here can play audio — Spotify does not expose it, and no scope this
// asks for would help.

/// A playlist as it appears in a listing.
class SpotifyPlaylist {
  const SpotifyPlaylist({
    required this.id,
    required this.name,
    required this.trackCount,
    this.owner,
    this.imageUrl,
  });

  final String id;
  final String name;
  final int trackCount;
  final String? owner;
  final String? imageUrl;
}

/// Reads a Spotify library.
class SpotifyApi {
  SpotifyApi({
    required this.auth,
    required SpotifyTokens tokens,
    HttpClient? httpClient,
    this.timeout = const Duration(seconds: 30),
    this.onTokensRefreshed,
  }) : _tokens = tokens,
       _http = httpClient ?? HttpClient();

  final SpotifyAuth auth;
  final HttpClient _http;
  final Duration timeout;

  /// Called whenever the tokens change, so the caller can persist them —
  /// Spotify rotates the refresh token and losing it means signing in again.
  final void Function(SpotifyTokens tokens)? onTokensRefreshed;

  SpotifyTokens _tokens;
  SpotifyTokens get tokens => _tokens;

  static const _base = 'https://api.spotify.com/v1';

  /// The signed-in user's display name, which doubles as a connection check.
  Future<String?> me() async {
    final json = await _get(Uri.parse('$_base/me'));
    return json['display_name'] as String? ?? json['id'] as String?;
  }

  /// Every playlist the user owns or follows.
  Future<List<SpotifyPlaylist>> playlists() async {
    final results = <SpotifyPlaylist>[];
    var next = Uri.parse('$_base/me/playlists').replace(
      queryParameters: {'limit': '50'},
    );

    while (true) {
      final json = await _get(next);
      for (final item in (json['items'] as List? ?? const [])) {
        if (item is! Map<String, Object?>) continue;
        final id = item['id'];
        if (id is! String) continue;
        final images = item['images'];
        results.add(
          SpotifyPlaylist(
            id: id,
            name: item['name'] as String? ?? 'Untitled',
            trackCount:
                ((item['tracks'] as Map?)?['total'] as num?)?.toInt() ?? 0,
            owner: (item['owner'] as Map?)?['display_name'] as String?,
            imageUrl: (images is List && images.isNotEmpty)
                ? (images.first as Map)['url'] as String?
                : null,
          ),
        );
      }
      final following = json['next'];
      if (following is! String) break;
      next = Uri.parse(following);
    }
    return results;
  }

  /// The tracks in one playlist, in order.
  Future<List<SpotifyTrack>> playlistTracks(String playlistId) => _tracksFrom(
    Uri.parse('$_base/playlists/$playlistId/tracks').replace(
      queryParameters: {
        'limit': '100',
        // Only the fields the matcher uses: a playlist of 500 tracks is a lot
        // of JSON otherwise.
        'fields':
            'next,items(track(id,name,duration_ms,artists(name),'
            'album(name),external_ids(isrc)))',
      },
    ),
  );

  /// The user's Liked Songs.
  Future<List<SpotifyTrack>> savedTracks() => _tracksFrom(
    Uri.parse('$_base/me/tracks').replace(
      queryParameters: {
        'limit': '50',
        'fields':
            'next,items(track(id,name,duration_ms,artists(name),'
            'album(name),external_ids(isrc)))',
      },
    ),
  );

  Future<List<SpotifyTrack>> _tracksFrom(Uri start) async {
    final tracks = <SpotifyTrack>[];
    var next = start;
    while (true) {
      final json = await _get(next);
      for (final item in (json['items'] as List? ?? const [])) {
        if (item is! Map<String, Object?>) continue;
        final track = parseTrack(item['track']);
        if (track != null) tracks.add(track);
      }
      final following = json['next'];
      if (following is! String) break;
      next = Uri.parse(following);
    }
    return tracks;
  }

  /// Parses one `track` object. Public so the parsing can be tested directly.
  static SpotifyTrack? parseTrack(Object? raw) {
    if (raw is! Map<String, Object?>) return null;
    final id = raw['id'];
    final name = raw['name'];
    // Local files added to a Spotify playlist, and podcast episodes, come
    // through with a null id and cannot be matched or looked up.
    if (id is! String || name is! String) return null;

    return SpotifyTrack(
      id: id,
      title: name,
      artists: [
        for (final artist in (raw['artists'] as List? ?? const []))
          if (artist is Map && artist['name'] is String)
            artist['name'] as String,
      ],
      album: (raw['album'] as Map?)?['name'] as String?,
      durationMs: (raw['duration_ms'] as num?)?.toInt(),
      isrc: (raw['external_ids'] as Map?)?['isrc'] as String?,
    );
  }

  Future<Map<String, Object?>> _get(Uri uri, {bool retrying = false}) async {
    await _ensureFreshToken();

    try {
      final request = await _http.getUrl(uri);
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer ${_tokens.accessToken}',
      );
      final response = await request.close().timeout(timeout);
      final text = await response.transform(utf8.decoder).join();

      if (response.statusCode == HttpStatus.unauthorized && !retrying) {
        // The token died earlier than its expiry claimed; refresh once.
        await _refresh();
        return _get(uri, retrying: true);
      }
      if (response.statusCode == HttpStatus.tooManyRequests) {
        final retryAfter =
            int.tryParse(response.headers.value('retry-after') ?? '') ?? 2;
        throw SpotifyAuthException(
          'Spotify is rate-limiting this account. Wait about '
          '${retryAfter}s and try again.',
        );
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw SpotifyAuthException(
          switch (response.statusCode) {
            403 =>
              'Spotify refused that request. Some endpoints need a Premium '
                  'account, or your app may not have the right scopes.',
            404 => 'That playlist no longer exists on Spotify.',
            _ => 'Spotify returned an error (${response.statusCode}).',
          },
          detail: text.length > 300 ? text.substring(0, 300) : text,
        );
      }

      final decoded = jsonDecode(text);
      if (decoded is! Map<String, Object?>) {
        throw const SpotifyAuthException('Spotify sent an unexpected reply.');
      }
      return decoded;
    } on SpotifyAuthException {
      rethrow;
    } on SocketException catch (error) {
      throw SpotifyAuthException(
        'Could not reach Spotify.',
        detail: error.message,
      );
    } on TimeoutException {
      throw const SpotifyAuthException('Spotify did not answer in time.');
    }
  }

  Future<void> _ensureFreshToken() async {
    if (_tokens.isExpired) await _refresh();
  }

  Future<void> _refresh() async {
    if (_tokens.refreshToken.isEmpty) {
      throw const SpotifyAuthException(
        'The Spotify session expired and there is no refresh token. Connect '
        'again.',
      );
    }
    _tokens = await auth.refresh(_tokens.refreshToken);
    onTokensRefreshed?.call(_tokens);
  }

  void close() => _http.close(force: true);
}
