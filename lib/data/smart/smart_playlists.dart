import 'dart:math';

import '../models/models.dart';

/// Ported from `data/model/SmartPlaylistRule.kt`.
///
/// These are computed, not stored: the rule is the playlist, so it re-evaluates
/// as listening changes rather than going stale.
enum SmartPlaylistRule {
  topPlayed(
    'top_played',
    'Top Played',
    'The tracks you have spent the most time with.',
  ),
  recentlyPlayed(
    'recently_played',
    'Recently Played',
    'What you have been listening to lately.',
  ),
  forgottenFavorites(
    'forgotten_favorites',
    'Forgotten Favourites',
    'Liked tracks you have not played in a long while.',
  ),
  newGems(
    'new_gems',
    'New Gems',
    'Recently added, and barely played yet.',
  );

  const SmartPlaylistRule(this.storageKey, this.title, this.subtitle);

  final String storageKey;
  final String title;
  final String subtitle;

  static SmartPlaylistRule? fromStorageKey(String? key) {
    if (key == null || key.trim().isEmpty) return null;
    for (final rule in values) {
      if (rule.storageKey == key) return rule;
    }
    return null;
  }
}

/// The listening facts the rules need, so they stay pure and testable.
class ListeningStats {
  const ListeningStats({
    this.msListened = const {},
    this.playCounts = const {},
    this.lastPlayedAt = const {},
  });

  /// Song id -> total milliseconds listened.
  final Map<String, int> msListened;

  /// Song id -> number of times started.
  final Map<String, int> playCounts;

  /// Song id -> epoch millis of the most recent play.
  final Map<String, int> lastPlayedAt;

  bool get isEmpty =>
      msListened.isEmpty && playCounts.isEmpty && lastPlayedAt.isEmpty;
}

/// Evaluates [rule] over the library.
///
/// [now] is injected so the time-relative rules can be tested without waiting.
List<Song> evaluateSmartPlaylist(
  SmartPlaylistRule rule,
  List<Song> songs,
  ListeningStats stats, {
  int limit = 100,
  DateTime? now,
}) {
  final today = now ?? DateTime.now();
  final result = switch (rule) {
    SmartPlaylistRule.topPlayed => _byListeningTime(songs, stats),
    SmartPlaylistRule.recentlyPlayed => _byLastPlayed(songs, stats),
    SmartPlaylistRule.forgottenFavorites => _forgottenFavorites(
      songs,
      stats,
      today,
    ),
    SmartPlaylistRule.newGems => _newGems(songs, stats, today),
  };
  return result.take(limit).toList();
}

List<Song> _byListeningTime(List<Song> songs, ListeningStats stats) {
  final played = [
    for (final song in songs)
      if ((stats.msListened[song.id] ?? 0) > 0) song,
  ]..sort(
    (a, b) =>
        (stats.msListened[b.id] ?? 0).compareTo(stats.msListened[a.id] ?? 0),
  );
  return played;
}

List<Song> _byLastPlayed(List<Song> songs, ListeningStats stats) {
  final played = [
    for (final song in songs)
      if (stats.lastPlayedAt.containsKey(song.id)) song,
  ]..sort(
    (a, b) =>
        (stats.lastPlayedAt[b.id] ?? 0).compareTo(stats.lastPlayedAt[a.id] ?? 0),
  );
  return played;
}

/// Liked, played at least once, and not touched for a month or more.
///
/// A liked track that was never played is not "forgotten" — it was never
/// remembered — so those are excluded.
List<Song> _forgottenFavorites(
  List<Song> songs,
  ListeningStats stats,
  DateTime now,
) {
  final cutoff = now.subtract(const Duration(days: 30)).millisecondsSinceEpoch;
  final candidates = [
    for (final song in songs)
      if (song.isFavorite &&
          (stats.lastPlayedAt[song.id] ?? 0) > 0 &&
          stats.lastPlayedAt[song.id]! < cutoff)
        song,
  ]..sort(
    // Longest-neglected first.
    (a, b) =>
        (stats.lastPlayedAt[a.id] ?? 0).compareTo(stats.lastPlayedAt[b.id] ?? 0),
  );
  return candidates;
}

/// Added in the last month, played at most twice.
List<Song> _newGems(List<Song> songs, ListeningStats stats, DateTime now) {
  final cutoff = now.subtract(const Duration(days: 30)).millisecondsSinceEpoch;
  final candidates = [
    for (final song in songs)
      if (song.dateAdded >= cutoff && (stats.playCounts[song.id] ?? 0) <= 2)
        song,
  ]..sort((a, b) => b.dateAdded.compareTo(a.dateAdded));
  return candidates;
}

/// Ported from `DailyMixSection` / the Daily Mix generator.
///
/// Weighted by how much each track has been listened to, with unplayed tracks
/// mixed in so the row is never empty and never only the same few songs. The
/// shuffle is seeded by the date, so the mix is stable for a whole day and
/// different tomorrow — regenerating on every rebuild made it useless.
List<Song> buildDailyMix(
  List<Song> songs,
  ListeningStats stats, {
  int size = 25,
  DateTime? day,
}) {
  if (songs.isEmpty) return const [];
  final today = day ?? DateTime.now();
  final seed = today.year * 10000 + today.month * 100 + today.day;
  final random = Random(seed);

  final favourites = <Song>[];
  final rest = <Song>[];
  for (final song in songs) {
    if ((stats.msListened[song.id] ?? 0) > 0 || song.isFavorite) {
      favourites.add(song);
    } else {
      rest.add(song);
    }
  }

  // Roughly two thirds familiar, one third new, and whatever is missing from
  // one bucket is taken from the other.
  final familiarTarget = (size * 0.6).round();
  favourites.sort(
    (a, b) =>
        (stats.msListened[b.id] ?? 0).compareTo(stats.msListened[a.id] ?? 0),
  );

  // Draw from the top slice rather than strictly the top, so a familiar mix is
  // not the same running order every day.
  final familiarPool = favourites.take(max(familiarTarget * 3, 20)).toList()
    ..shuffle(random);
  rest.shuffle(random);

  final picked = <Song>[
    ...familiarPool.take(familiarTarget),
    ...rest.take(size - familiarTarget),
  ];
  if (picked.length < size) {
    // One bucket ran dry: top up from everything else, without duplicating.
    final chosen = picked.map((song) => song.id).toSet();
    final filler = [
      for (final song in [...familiarPool, ...rest])
        if (!chosen.contains(song.id)) song,
    ];
    picked.addAll(filler.take(size - picked.length));
  }
  return (picked..shuffle(random)).take(size).toList();
}

/// Ported from `QuickFillScreen` — top a playlist up with material that fits
/// what is already in it.
///
/// Scores candidates by how much they share with the seed tracks: same artist
/// counts most, then album, then genre. Ties break towards more-listened
/// tracks so the filler is not obscure padding.
List<Song> quickFill(
  List<Song> seed,
  List<Song> library,
  ListeningStats stats, {
  int count = 20,
}) {
  if (library.isEmpty || count <= 0) return const [];
  final present = seed.map((song) => song.id).toSet();
  final artists = <int>{for (final song in seed) ...song.artists.map((a) => a.id)}
    ..addAll(seed.map((song) => song.artistId));
  final albums = {for (final song in seed) song.albumId};
  final genres = {
    for (final song in seed)
      if (song.genre != null) song.genre!.toLowerCase(),
  };

  int score(Song song) {
    var value = 0;
    if (song.artists.any((a) => artists.contains(a.id)) ||
        artists.contains(song.artistId)) {
      value += 6;
    }
    if (albums.contains(song.albumId)) value += 3;
    final genre = song.genre?.toLowerCase();
    if (genre != null && genres.contains(genre)) value += 2;
    if (song.isFavorite) value += 1;
    return value;
  }

  final candidates = [
    for (final song in library)
      if (!present.contains(song.id)) song,
  ];
  candidates.sort((a, b) {
    final byScore = score(b).compareTo(score(a));
    if (byScore != 0) return byScore;
    return (stats.msListened[b.id] ?? 0).compareTo(stats.msListened[a.id] ?? 0);
  });
  // Anything with nothing in common is not a fill, it is noise.
  return [
    for (final song in candidates)
      if (score(song) > 0) song,
  ].take(count).toList();
}
