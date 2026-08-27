import '../../models/models.dart';

/// Matches Spotify tracks against the local library.
///
/// This is the whole reason the importer can exist: Spotify will hand over what
/// is in a playlist but never the audio, so a track is only useful here if we
/// can find it in something we can actually play. Matching is fuzzy by
/// necessity — the same recording is "Song", "Song - Remastered 2011" and
/// "Song (feat. Someone)" depending on who tagged it.
///
/// Pure functions, so the scoring can be tested against the awkward cases
/// rather than guessed at.

/// One track as Spotify describes it.
class SpotifyTrack {
  const SpotifyTrack({
    required this.id,
    required this.title,
    required this.artists,
    this.album,
    this.durationMs,
    this.isrc,
  });

  final String id;
  final String title;
  final List<String> artists;
  final String? album;
  final int? durationMs;

  /// The recording's industry identifier. Kept because the API gives it for
  /// free and it would settle a match exactly — but nothing can be done with it
  /// until the local library stores one too.
  final String? isrc;

  String get primaryArtist => artists.isEmpty ? '' : artists.first;
}

/// How a Spotify track ended up paired with a local song.
enum MatchConfidence {
  /// Title, artist and duration all agree closely.
  strong,

  /// Title and artist agree but the duration differs, or the title needed
  /// heavy normalisation. Worth importing, worth flagging.
  loose,

  /// Nothing close enough.
  none,
}

class TrackMatch {
  const TrackMatch({
    required this.track,
    this.song,
    this.confidence = MatchConfidence.none,
    this.score = 0,
  });

  final SpotifyTrack track;
  final Song? song;
  final MatchConfidence confidence;

  /// 0..100, for ordering the near-misses when a human reviews them.
  final int score;

  bool get matched => song != null && confidence != MatchConfidence.none;
}

/// Noise that says nothing about which recording this is.
final _noise = RegExp(
  r'\b(remaster(ed)?|remasterizado|deluxe|edition|edición|version|versión|'
  r'mono|stereo|explicit|clean|bonus|track|album|single|radio edit|'
  r'original motion picture soundtrack|soundtrack)\b',
  caseSensitive: false,
);

/// Bracketed asides: "(feat. X)", "[Live]", "- Remastered 2011".
final _asides = RegExp(r'[\(\[\{][^\)\]\}]*[\)\]\}]');
final _trailingDash = RegExp(r'\s+-\s+.*$');
final _featuring = RegExp(
  r'\b(feat\.?|ft\.?|featuring|con)\b.*$',
  caseSensitive: false,
);
/// Apostrophes vanish rather than becoming a gap, so "Don't Stop" and a
/// local tag spelling it "Dont Stop" normalise to the same thing.
final _apostrophes = RegExp(r"['\u2019\u02BC\u0060]");
final _punctuation = RegExp(r"[^\p{L}\p{N}\s]", unicode: true);
final _spaces = RegExp(r'\s+');

/// Strips everything that varies between two taggings of one recording.
///
/// Accents go too: a library tagged "Mágico" and a Spotify entry spelling it
/// "Magico" are the same album.
String normaliseTitle(String value) {
  var text = value.toLowerCase();
  text = text.replaceAll(_asides, ' ');
  text = text.replaceAll(_featuring, ' ');
  // Only strip a trailing dash clause when it is noise, so "Song - Part Two"
  // survives while "Song - Remastered" does not.
  final dashMatch = _trailingDash.firstMatch(text);
  if (dashMatch != null && _noise.hasMatch(dashMatch.group(0)!)) {
    text = text.replaceAll(_trailingDash, ' ');
  }
  text = text.replaceAll(_noise, ' ');
  text = _stripAccents(text);
  text = text.replaceAll(_apostrophes, '');
  text = text.replaceAll(_punctuation, ' ');
  return text.replaceAll(_spaces, ' ').trim();
}

/// Artist names, normalised and split so "A & B" matches "A, B".
Set<String> normaliseArtists(Iterable<String> names) {
  final parts = <String>{};
  for (final name in names) {
    for (final piece in name.split(RegExp(r'[,&/;]|\bfeat\.?\b|\bft\.?\b|\by\b'))) {
      final cleaned = normaliseTitle(piece);
      if (cleaned.isNotEmpty) parts.add(cleaned);
    }
  }
  return parts;
}

String _stripAccents(String value) {
  const from = 'áàäâãåéèëêíìïîóòöôõúùüûñçÁÀÄÂÃÅÉÈËÊÍÌÏÎÓÒÖÔÕÚÙÜÛÑÇ';
  const to = 'aaaaaaeeeeiiiiooooouuuuncAAAAAAEEEEIIIIOOOOOUUUUNC';
  final buffer = StringBuffer();
  for (final rune in value.runes) {
    final char = String.fromCharCode(rune);
    final index = from.indexOf(char);
    buffer.write(index == -1 ? char : to[index]);
  }
  return buffer.toString();
}

/// Scores how well one local song answers a Spotify track, 0..100.
int scoreMatch(SpotifyTrack track, Song song) {
  final wantedTitle = normaliseTitle(track.title);
  final haveTitle = normaliseTitle(song.title);
  if (wantedTitle.isEmpty || haveTitle.isEmpty) return 0;

  var score = 0;

  // Title carries the most weight: an exact normalised match, or one contained
  // in the other, which covers a tagged "(Album Version)" that survived.
  if (wantedTitle == haveTitle) {
    score += 55;
  } else if (haveTitle.contains(wantedTitle) ||
      wantedTitle.contains(haveTitle)) {
    score += 38;
  } else {
    // Word overlap, for transposed or partially different titles.
    final wanted = wantedTitle.split(' ').toSet();
    final have = haveTitle.split(' ').toSet();
    final shared = wanted.intersection(have).length;
    final ratio = shared / wanted.length;
    if (ratio < 0.6) return 0; // Too far apart to be the same song.
    score += (ratio * 30).round();
  }

  // Artist agreement. A shared name is worth a lot; the local tag often lists
  // fewer artists than Spotify does.
  final wantedArtists = normaliseArtists(track.artists);
  final haveArtists = normaliseArtists([
    song.artist,
    if (song.albumArtist != null) song.albumArtist!,
    ...song.artists.map((a) => a.name),
  ]);
  if (wantedArtists.isNotEmpty && haveArtists.isNotEmpty) {
    if (wantedArtists.intersection(haveArtists).isNotEmpty) {
      score += 30;
    } else if (wantedArtists.any(
      (wanted) => haveArtists.any(
        (have) => have.contains(wanted) || wanted.contains(have),
      ),
    )) {
      score += 18;
    } else {
      // Same title, different artist is usually a cover, not the recording.
      score -= 25;
    }
  }

  // Duration, when both know it. Two seconds is tagging noise; ten is a
  // different edit.
  final wantedMs = track.durationMs;
  if (wantedMs != null && wantedMs > 0 && song.duration > 0) {
    final delta = (wantedMs - song.duration).abs();
    if (delta <= 2000) {
      score += 15;
    } else if (delta <= 5000) {
      score += 8;
    } else if (delta > 15000) {
      score -= 15;
    }
  }

  // Album agreement is a light tiebreaker between pressings.
  final wantedAlbum = track.album;
  if (wantedAlbum != null) {
    final a = normaliseTitle(wantedAlbum);
    final b = normaliseTitle(song.album);
    if (a.isNotEmpty && a == b) score += 8;
  }

  return score.clamp(0, 100);
}

/// Pairs one Spotify track with the best candidate in [library].
///
/// Spotify supplies an ISRC, which would settle a match outright — but the
/// local library does not store one: the scanner never reads it and there is no
/// column for it. Adding that would be a schema migration plus a tag-reader
/// change, so matching is by title, artist and duration until then.
TrackMatch matchTrack(SpotifyTrack track, List<Song> library) {
  Song? best;
  var bestScore = 0;
  for (final song in library) {
    final score = scoreMatch(track, song);
    if (score > bestScore) {
      bestScore = score;
      best = song;
    }
  }

  if (best == null || bestScore < 55) {
    return TrackMatch(track: track, score: bestScore);
  }
  return TrackMatch(
    track: track,
    song: best,
    // 85 is "title, artist and duration all agreed"; below that something had
    // to be forgiven, so the import flags it for a human.
    confidence: bestScore >= 85 ? MatchConfidence.strong : MatchConfidence.loose,
    score: bestScore,
  );
}

/// Matches a whole playlist, keeping Spotify's order.
List<TrackMatch> matchTracks(List<SpotifyTrack> tracks, List<Song> library) => [
  for (final track in tracks) matchTrack(track, library),
];

/// What a search on another source should be given for an unmatched track.
///
/// Title plus primary artist, without the noise — the same normalisation the
/// matcher uses, so a YouTube search is looking for the same thing.
String searchQueryFor(SpotifyTrack track) {
  final title = normaliseTitle(track.title);
  final artist = normaliseTitle(track.primaryArtist);
  return artist.isEmpty ? title : '$artist $title';
}
