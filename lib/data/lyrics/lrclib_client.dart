import 'dart:convert';
import 'dart:io';

/// Ported from `data/network/lyrics/LrcLibApiService` + `LrcLibResponse`.
///
/// Retrofit/OkHttp on Android; here `dart:io`'s HttpClient is enough for two
/// GET endpoints, so the port adds no dependency.
class LrcLibResult {
  const LrcLibResult({
    required this.id,
    required this.trackName,
    required this.artistName,
    required this.albumName,
    required this.durationSeconds,
    this.plainLyrics,
    this.syncedLyrics,
  });

  final int id;
  final String trackName;
  final String artistName;
  final String albumName;
  final double durationSeconds;
  final String? plainLyrics;
  final String? syncedLyrics;

  bool get hasSynced => (syncedLyrics ?? '').trim().isNotEmpty;
  bool get hasAny => hasSynced || (plainLyrics ?? '').trim().isNotEmpty;

  static LrcLibResult fromJson(Map<String, dynamic> json) => LrcLibResult(
    id: (json['id'] as num?)?.toInt() ?? 0,
    trackName: json['trackName'] as String? ?? json['name'] as String? ?? '',
    artistName: json['artistName'] as String? ?? '',
    albumName: json['albumName'] as String? ?? '',
    durationSeconds: (json['duration'] as num?)?.toDouble() ?? 0,
    plainLyrics: json['plainLyrics'] as String?,
    syncedLyrics: json['syncedLyrics'] as String?,
  );
}

class LrcLibClient {
  LrcLibClient({HttpClient? httpClient})
    : _client = httpClient ?? (HttpClient()..connectionTimeout = _timeout);

  static const _host = 'lrclib.net';
  static const _timeout = Duration(seconds: 10);

  /// LRCLIB asks clients to identify themselves.
  static const _userAgent =
      'PixelPlayerDesktop (https://github.com/PixelPlayerHQ/PixelPlayer)';

  final HttpClient _client;

  void close() => _client.close(force: true);

  /// `GET /api/get` — the exact-match lookup.
  Future<LrcLibResult?> get({
    required String trackName,
    required String artistName,
    required String albumName,
    required int durationSeconds,
  }) async {
    final body = await _request('/api/get', {
      'track_name': trackName,
      'artist_name': artistName,
      'album_name': albumName,
      'duration': '$durationSeconds',
    });
    if (body == null) return null;
    final json = jsonDecode(body);
    if (json is! Map<String, dynamic>) return null;
    return LrcLibResult.fromJson(json);
  }

  /// `GET /api/search` — fuzzy search, for when the exact lookup misses and the
  /// user picks from a list.
  Future<List<LrcLibResult>> search({
    String? query,
    String? trackName,
    String? artistName,
    String? albumName,
  }) async {
    final body = await _request('/api/search', {
      if (query != null && query.isNotEmpty) 'q': query,
      if (trackName != null && trackName.isNotEmpty) 'track_name': trackName,
      if (artistName != null && artistName.isNotEmpty) 'artist_name': artistName,
      if (albumName != null && albumName.isNotEmpty) 'album_name': albumName,
    });
    if (body == null) return const [];
    final json = jsonDecode(body);
    if (json is! List) return const [];
    return [
      for (final item in json)
        if (item is Map<String, dynamic>) LrcLibResult.fromJson(item),
    ];
  }

  Future<String?> _request(String path, Map<String, String> query) async {
    try {
      final uri = Uri.https(_host, path, query);
      final request = await _client.getUrl(uri).timeout(_timeout);
      request.headers.set(HttpHeaders.userAgentHeader, _userAgent);
      final response = await request.close().timeout(_timeout);
      if (response.statusCode == HttpStatus.notFound) {
        // A miss is normal, not an error.
        await response.drain<void>();
        return null;
      }
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        throw HttpException('LRCLIB returned ${response.statusCode}', uri: uri);
      }
      return response.transform(utf8.decoder).join();
    } on SocketException {
      // Offline is an expected state for a local music player.
      return null;
    }
  }
}
