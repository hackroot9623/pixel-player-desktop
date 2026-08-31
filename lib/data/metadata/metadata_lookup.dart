import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

// Looking up what a song actually is.
//
// MusicBrainz for the words, the Cover Art Archive for the picture, Deezer when
// the archive has nothing — which is common for anything not mainstream. All
// three are free and need no account, which is the whole reason for the choice:
// a tagger that stops working when a key expires is worse than no tagger.
//
// Nothing here writes to a file. A lookup produces a [MetadataMatch]; turning
// that into tags is `tag_writer.dart`'s job, and the user presses Save. That
// separation is deliberate — a wrong match that silently rewrote correct tags
// would be the worst thing this feature could do.

/// MusicBrainz asks for an identifying User-Agent and blocks generic ones.
const metadataUserAgent =
    'PixelPlayerDesktop/1.0 (https://github.com/hackroot9623/pixel-player-desktop)';

/// One candidate the user can accept.
class MetadataMatch {
  const MetadataMatch({
    required this.title,
    required this.artist,
    required this.album,
    this.albumArtist,
    this.year,
    this.trackNumber,
    this.trackTotal,
    this.discNumber,
    this.discTotal,
    this.releaseId,
    this.recordingId,
    this.country,
    this.status,
    this.primaryType,
    this.secondaryTypes = const [],
    this.score = 0,
    this.length,
  });

  final String title;
  final String artist;
  final String album;
  final String? albumArtist;
  final int? year;
  final int? trackNumber;
  final int? trackTotal;
  final int? discNumber;
  final int? discTotal;

  /// MusicBrainz release id — what the Cover Art Archive is keyed by.
  final String? releaseId;
  final String? recordingId;
  final String? country;

  /// "Official", "Bootleg", "Promotion".
  final String? status;

  /// "Album", "Single", "EP" — and the secondary types that say it is a live
  /// recording or a compilation.
  final String? primaryType;
  final List<String> secondaryTypes;

  /// MusicBrainz's own confidence, 0–100.
  final int score;
  final Duration? length;

  /// Whether this release is a live recording, a compilation or a remix rather
  /// than the album the song came out on.
  bool get isSecondaryRelease => secondaryTypes.any(
    (type) => const {
      'Live',
      'Compilation',
      'Remix',
      'DJ-mix',
      'Mixtape/Street',
      'Demo',
    }.contains(type),
  );

  /// The order candidates are shown in.
  ///
  /// MusicBrainz's own score answers "does this text match", not "is this the
  /// release the file came from". Searching for a well-known song frequently
  /// puts a live album or a greatest-hits compilation first, all scoring 100,
  /// and tagging a studio track as live is a wrong answer that looks right. So
  /// the secondary types are demoted and unofficial releases with them.
  int get rank =>
      score -
      (isSecondaryRelease ? 30 : 0) -
      (status == 'Official' ? 0 : 10) -
      // A song does appear on its own single, but someone tagging a file wants
      // the album it came out on. Live verification against MusicBrainz put
      // "Dissident #2" above "Ten" for Pearl Jam's "Black" — both scoring 100.
      (const {'Single', 'EP'}.contains(primaryType) ? 15 : 0);

  /// "1982 · Album · track 3 of 10", for the candidate list.
  String get summary => [
    if (year != null) '$year',
    if (album.isNotEmpty) album,
    for (final type in secondaryTypes) type,
    if (trackNumber != null)
      trackTotal != null ? 'track $trackNumber of $trackTotal' : 'track $trackNumber',
    if (discTotal != null && discTotal! > 1) 'disc $discNumber of $discTotal',
    ?country,
  ].join(' · ');
}

/// Escapes the characters Lucene treats as syntax.
///
/// Without this a title holding a colon or a quote — "Album: Reloaded", 'Say
/// "Yes"' — is read as query syntax and MusicBrainz answers 400 or nonsense.
String luceneEscape(String value) => value.replaceAllMapped(
  RegExp(r'[+\-&|!(){}\[\]^"~*?:\\/]'),
  (match) => '\\${match.group(0)}',
);

/// The query for a song search. Fielded, so a title is not matched against an
/// artist name.
String musicBrainzRecordingQuery({
  required String title,
  String artist = '',
  String album = '',
}) => [
  if (title.trim().isNotEmpty) 'recording:"${luceneEscape(title.trim())}"',
  if (artist.trim().isNotEmpty) 'artist:"${luceneEscape(artist.trim())}"',
  if (album.trim().isNotEmpty) 'release:"${luceneEscape(album.trim())}"',
].join(' AND ');

/// The query for an album search, used when fixing covers a whole album at a
/// time.
String musicBrainzReleaseQuery({
  required String album,
  String artist = '',
}) => [
  if (album.trim().isNotEmpty) 'release:"${luceneEscape(album.trim())}"',
  if (artist.trim().isNotEmpty) 'artist:"${luceneEscape(artist.trim())}"',
].join(' AND ');

/// Where the Cover Art Archive keeps the front cover of a release.
///
/// [size] is one of 250, 500, 1200; anything else is served as the full image.
/// 500 is the default because it is what the app draws, and a 1200 costs four
/// times the bytes for no visible gain.
String coverArtUrl(String releaseId, {int size = 500}) =>
    'https://coverartarchive.org/release/$releaseId/front-$size';

/// Reads a MusicBrainz recording search.
///
/// One recording can appear on many releases, and the release is what decides
/// the album, the year and the track number — so each release becomes its own
/// candidate. [releasesPerRecording] caps that, since a famous song has dozens
/// of compilation appearances and a list of eighty rows helps nobody.
List<MetadataMatch> parseRecordingMatches(
  String body, {
  int releasesPerRecording = 3,
}) {
  final decoded = _decodeMap(body);
  final recordings = decoded?['recordings'];
  if (recordings is! List) return const [];

  final matches = <MetadataMatch>[];
  for (final entry in recordings) {
    if (entry is! Map) continue;
    final title = _string(entry['title']);
    if (title.isEmpty) continue;

    final artist = _artistCredit(entry['artist-credit']);
    final score = _int(entry['score']) ?? 0;
    final lengthMs = _int(entry['length']);
    final length = lengthMs == null ? null : Duration(milliseconds: lengthMs);
    final recordingId = _string(entry['id']);

    final releases = entry['releases'];
    if (releases is! List || releases.isEmpty) {
      // A recording with no release still tells you the title and artist.
      matches.add(
        MetadataMatch(
          title: title,
          artist: artist,
          album: '',
          score: score,
          length: length,
          recordingId: recordingId.isEmpty ? null : recordingId,
        ),
      );
      continue;
    }

    for (final release in releases.take(releasesPerRecording)) {
      if (release is! Map) continue;
      final media = release['media'];
      final track = _firstTrack(media);
      final group = release['release-group'];
      matches.add(
        MetadataMatch(
          title: title,
          artist: artist,
          album: _string(release['title']),
          albumArtist: _artistCredit(release['artist-credit'], fallback: artist),
          year: _year(release['date']),
          trackNumber: track.number,
          trackTotal: track.total,
          discNumber: track.disc,
          discTotal: media is List && media.isNotEmpty ? media.length : null,
          releaseId: _string(release['id']).isEmpty
              ? null
              : _string(release['id']),
          recordingId: recordingId.isEmpty ? null : recordingId,
          country: _string(release['country']).isEmpty
              ? null
              : _string(release['country']),
          status: _string(release['status']).isEmpty
              ? null
              : _string(release['status']),
          primaryType: group is Map
              ? (_string(group['primary-type']).isEmpty
                    ? null
                    : _string(group['primary-type']))
              : null,
          secondaryTypes: group is Map ? _strings(group['secondary-types']) : const [],
          score: score,
          length: length,
        ),
      );
    }
  }

  // MusicBrainz orders by score already, but flattening releases mixes them up,
  // and a live album scoring 100 should not sit above the studio original.
  matches.sort((a, b) {
    final byRank = b.rank.compareTo(a.rank);
    if (byRank != 0) return byRank;
    // The earliest release of an album is normally the one a file came from.
    return (a.year ?? 9999).compareTo(b.year ?? 9999);
  });
  return matches;
}

/// Reads a MusicBrainz release search — the album-level shape.
List<MetadataMatch> parseReleaseMatches(String body) {
  final decoded = _decodeMap(body);
  final releases = decoded?['releases'];
  if (releases is! List) return const [];

  return [
    for (final entry in releases)
      if (entry is Map)
        if (_string(entry['title']).isNotEmpty)
          MetadataMatch(
            title: '',
            artist: _artistCredit(entry['artist-credit']),
            album: _string(entry['title']),
            albumArtist: _artistCredit(entry['artist-credit']),
            year: _year(entry['date']),
            trackTotal: _int(entry['track-count']),
            releaseId: _string(entry['id']).isEmpty
                ? null
                : _string(entry['id']),
            country: _string(entry['country']).isEmpty
                ? null
                : _string(entry['country']),
            status: _string(entry['status']).isEmpty
                ? null
                : _string(entry['status']),
            secondaryTypes: entry['release-group'] is Map
                ? _strings((entry['release-group'] as Map)['secondary-types'])
                : const [],
            score: _int(entry['score']) ?? 0,
          ),
  ];
}

/// The cover URL out of a Deezer album search, largest first.
String? parseDeezerCover(String body) {
  final decoded = _decodeMap(body);
  final data = decoded?['data'];
  if (data is! List || data.isEmpty) return null;
  final album = data.first;
  if (album is! Map) return null;
  for (final key in ['cover_xl', 'cover_big', 'cover_medium', 'cover']) {
    final url = album[key];
    if (url is String && url.isNotEmpty) return url;
  }
  return null;
}

/// Whether these bytes are an image, and which kind.
///
/// The Cover Art Archive answers 404 with an HTML page, and a redirect chain
/// that ends somewhere unexpected would otherwise be written into a file as if
/// it were a cover.
bool looksLikeImage(List<int> bytes) {
  if (bytes.length < 4) return false;
  // JPEG, PNG, WebP (RIFF), GIF.
  if (bytes[0] == 0xFF && bytes[1] == 0xD8) return true;
  if (bytes[0] == 0x89 && bytes[1] == 0x50) return true;
  if (bytes[0] == 0x52 && bytes[1] == 0x49) return true;
  if (bytes[0] == 0x47 && bytes[1] == 0x49) return true;
  return false;
}

class MetadataLookupException implements Exception {
  const MetadataLookupException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Asks MusicBrainz, the Cover Art Archive and Deezer.
class MetadataLookup {
  MetadataLookup({
    HttpClient? httpClient,
    // MusicBrainz allows one request a second and means it. Tests pass zero.
    this.minimumInterval = const Duration(seconds: 1),
  }) : _client = httpClient ?? (HttpClient()..connectionTimeout = _timeout);

  static const _timeout = Duration(seconds: 15);

  final HttpClient _client;
  final Duration minimumInterval;

  DateTime? _lastMusicBrainzRequest;

  void dispose() => _client.close(force: true);

  /// Candidates for one song.
  Future<List<MetadataMatch>> searchSongs({
    required String title,
    String artist = '',
    String album = '',
    // Deliberately large. A search result lists one release per recording, and
    // MusicBrainz holds a separate recording for every live and compilation
    // appearance of a well-known song — asking for ten of them returns ten live
    // albums and never the studio one. Verified against the real API.
    int limit = 25,
  }) async {
    final query = musicBrainzRecordingQuery(
      title: title,
      artist: artist,
      album: album,
    );
    if (query.isEmpty) return const [];
    final body = await _musicBrainz('recording', query, limit);
    return parseRecordingMatches(body);
  }

  /// Candidates for one album.
  Future<List<MetadataMatch>> searchAlbums({
    required String album,
    String artist = '',
    int limit = 5,
  }) async {
    final query = musicBrainzReleaseQuery(album: album, artist: artist);
    if (query.isEmpty) return const [];
    final body = await _musicBrainz('release', query, limit);
    final matches = parseReleaseMatches(body)
      ..sort((a, b) => b.rank.compareTo(a.rank));
    return matches;
  }

  /// The cover for a match: the archive first, Deezer if it has none.
  ///
  /// Returns null when neither has one, which is a normal outcome and not an
  /// error.
  Future<Uint8List?> cover(MetadataMatch match, {int size = 500}) async {
    final releaseId = match.releaseId;
    if (releaseId != null) {
      final bytes = await _download(Uri.parse(coverArtUrl(releaseId, size: size)));
      if (bytes != null && looksLikeImage(bytes)) return bytes;
    }
    return coverFromDeezer(album: match.album, artist: match.artist);
  }

  /// Deezer's cover for an album, by name. The fallback, and also the only
  /// option for a match with no MusicBrainz release.
  Future<Uint8List?> coverFromDeezer({
    required String album,
    String artist = '',
  }) async {
    if (album.trim().isEmpty) return null;
    final search = Uri.https('api.deezer.com', '/search/album', {
      'q': [
        'album:"${album.trim()}"',
        if (artist.trim().isNotEmpty) 'artist:"${artist.trim()}"',
      ].join(' '),
      'limit': '1',
    });
    final body = await _text(search);
    if (body == null) return null;
    final url = parseDeezerCover(body);
    if (url == null) return null;
    final bytes = await _download(Uri.parse(url));
    return bytes != null && looksLikeImage(bytes) ? bytes : null;
  }

  Future<String> _musicBrainz(String entity, String query, int limit) async {
    final uri = Uri.https('musicbrainz.org', '/ws/2/$entity', {
      'query': query,
      'fmt': 'json',
      'limit': '$limit',
    });

    // MusicBrainz answers 503 both when a client exceeds one request a second
    // and, often, when its own server is busy — "The MusicBrainz web server is
    // currently busy" is its wording. It means wait, not unavailable. Live
    // testing hit it repeatedly and reported it as an unreachable server, so
    // there are three attempts with a growing pause, and the message says what
    // to do rather than blaming the connection.
    const backoff = [Duration(seconds: 2), Duration(seconds: 5)];
    for (var attempt = 0; attempt < 3; attempt++) {
      await _waitForRateLimit();
      final answer = await _fetch(uri);
      switch (answer) {
        case _Answer(:final String body):
          return body;
        case _Answer(status: 503) when attempt < backoff.length:
          await Future<void>.delayed(backoff[attempt]);
        case _Answer(status: 503):
          throw const MetadataLookupException(
            'MusicBrainz is asking for a slower pace. Wait a moment and try '
            'again.',
          );
        case _Answer(:final int status):
          throw MetadataLookupException('MusicBrainz answered $status.');
        case _Answer():
          throw const MetadataLookupException(
            'MusicBrainz could not be reached. Check the connection and try '
            'again.',
          );
      }
    }
    throw const MetadataLookupException('MusicBrainz could not be reached.');
  }

  /// One request a second, measured from the last one rather than slept
  /// unconditionally — a user who types slowly should not be made to wait.
  Future<void> _waitForRateLimit() async {
    if (minimumInterval == Duration.zero) return;
    final last = _lastMusicBrainzRequest;
    _lastMusicBrainzRequest = DateTime.now();
    if (last == null) return;
    final since = DateTime.now().difference(last);
    if (since < minimumInterval) {
      await Future<void>.delayed(minimumInterval - since);
    }
  }

  Future<String?> _text(Uri uri) async => (await _fetch(uri)).body;

  /// The body, or the status that explains why there is none.
  Future<_Answer> _fetch(Uri uri) async {
    try {
      final request = await _client.getUrl(uri).timeout(_timeout);
      request.headers.set(HttpHeaders.userAgentHeader, metadataUserAgent);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response = await request.close().timeout(_timeout);
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        return _Answer(status: response.statusCode);
      }
      return _Answer(body: await response.transform(utf8.decoder).join());
    } on SocketException {
      return const _Answer();
    } on TimeoutException {
      return const _Answer();
    } on HttpException {
      return const _Answer();
    }
  }

  Future<Uint8List?> _download(Uri uri) async {
    try {
      final request = await _client.getUrl(uri).timeout(_timeout);
      request.headers.set(HttpHeaders.userAgentHeader, metadataUserAgent);
      final response = await request.close().timeout(_timeout);
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        return null;
      }
      final bytes = <int>[];
      await response.forEach(bytes.addAll);
      return Uint8List.fromList(bytes);
    } on SocketException {
      return null;
    } on TimeoutException {
      return null;
    } on HttpException {
      return null;
    }
  }
}

/// A body, or the status code that came instead of one. Status is null when the
/// request never reached a server at all.
class _Answer {
  const _Answer({this.body, this.status});

  final String? body;
  final int? status;
}

Map<String, Object?>? _decodeMap(String body) {
  try {
    final decoded = jsonDecode(body);
    return decoded is Map<String, Object?> ? decoded : null;
  } on FormatException {
    return null;
  }
}

String _string(Object? value) => value is String ? value : '';

List<String> _strings(Object? value) => value is List
    ? [for (final entry in value) if (entry is String) entry]
    : const [];

int? _int(Object? value) => switch (value) {
  final int value => value,
  final num value => value.toInt(),
  final String value => int.tryParse(value),
  _ => null,
};

/// The year out of MusicBrainz's partial dates: "1982", "1982-05", "1982-05-01".
int? _year(Object? value) {
  final text = _string(value);
  if (text.length < 4) return null;
  return int.tryParse(text.substring(0, 4));
}

/// Joins an artist credit, keeping the join phrases: "Simon & Garfunkel",
/// "Queen feat. David Bowie".
String _artistCredit(Object? credit, {String fallback = ''}) {
  if (credit is! List || credit.isEmpty) return fallback;
  final parts = <String>[];
  for (final entry in credit) {
    if (entry is! Map) continue;
    final name = _string(entry['name']).isNotEmpty
        ? _string(entry['name'])
        : _string((entry['artist'] as Map?)?['name']);
    if (name.isEmpty) continue;
    parts.add(name);
    final join = _string(entry['joinphrase']);
    if (join.isNotEmpty) parts.add(join);
  }
  final joined = parts.join().replaceAll(RegExp(r'\s+'), ' ').trim();
  return joined.isEmpty ? fallback : joined;
}

int? _offsetPosition(Object? offset) {
  final value = _int(offset);
  return value == null ? null : value + 1;
}

/// The track this recording is on, out of a release's media list.
({int? number, int? total, int? disc}) _firstTrack(Object? media) {
  if (media is! List) return (number: null, total: null, disc: null);
  for (final medium in media) {
    if (medium is! Map) continue;
    final tracks = medium['track'];
    final total = _int(medium['track-count']);
    final disc = _int(medium['position']);
    if (tracks is List && tracks.isNotEmpty && tracks.first is Map) {
      final track = tracks.first as Map;
      return (
        // A search result carries `number` (a string, and "A1" on vinyl) and a
        // 0-based `track-offset`, but no `position`. So: the integer if there is
        // one, else the offset, which is always right even for vinyl sides.
        number:
            _int(track['position']) ??
            _int(track['number']) ??
            _offsetPosition(medium['track-offset']),
        total: total,
        disc: disc,
      );
    }
  }
  return (number: null, total: null, disc: null);
}
