import 'dart:convert';

import '../models/models.dart';
import '../smart/smart_playlists.dart';
import 'ai_client.dart';
import 'ai_prompts.dart';
import 'ai_response_cleaner.dart';

// Port of `data/ai/AiPlaylistGenerator`.
//
// The model never sees the library. It gets a scored sample of candidate
// tracks and returns IDs, which are matched back against the real library —
// so a hallucinated track cannot end up in a playlist, it just gets dropped.

/// What the request is allowed to cost, ported from the AI preferences.
class AiSampleOptions {
  const AiSampleOptions({
    this.sampleSize = 40,
    this.safeTokenLimit = true,
    this.includeExtendedFields = false,
  });

  /// How many candidate tracks to describe to the model.
  final int sampleSize;

  /// The Kotlin doubles the sample when this is off. On by default: a large
  /// pool is what makes a request expensive.
  final bool safeTokenLimit;

  /// Adds album, duration and favourite flags per track. Better picks, more
  /// tokens.
  final bool includeExtendedFields;

  int get effectiveSampleSize =>
      safeTokenLimit ? sampleSize : sampleSize * 2;
}

/// The candidate pool, ranked the way `DailyMixManager.getTopCandidatesForAi`
/// ranks it: what you actually listen to first, with unplayed tracks behind.
///
/// Pure, so the pool the model would see is testable without a network.
List<({Song song, int score})> rankCandidates(
  List<Song> songs,
  ListeningStats stats, {
  int limit = 100,
}) {
  final ranked = [
    for (final song in songs)
      (
        song: song,
        // 0-100. Listening time dominates, a like is worth a nudge, and play
        // count breaks ties between tracks with similar time.
        score: _score(song, stats),
      ),
  ]..sort((a, b) {
    final byScore = b.score.compareTo(a.score);
    return byScore != 0 ? byScore : a.song.title.compareTo(b.song.title);
  });
  return ranked.take(limit).toList();
}

int _score(Song song, ListeningStats stats) {
  final listenedMs = stats.msListened[song.id] ?? 0;
  final plays = stats.playCounts[song.id] ?? 0;
  // Roughly: an hour of listening saturates the listening component.
  final listening = (listenedMs / 3600000 * 70).clamp(0, 70).round();
  final played = (plays * 5).clamp(0, 20);
  final liked = song.isFavorite ? 10 : 0;
  return (listening + played + liked).clamp(0, 100);
}

/// Builds the user-side prompt: the request, the target length, and the pool.
///
/// Separate from the request so a test can assert what the model is told —
/// including that no absolute file path is ever sent, since a song's ID is its
/// path and that would leak the user's directory layout to a third party.
String buildPlaylistPrompt({
  required String request,
  required List<({Song song, int score})> candidates,
  required int minLength,
  required int maxLength,
  AiSampleOptions options = const AiSampleOptions(),
  String userDigest = '',
}) {
  final pool = StringBuffer();
  for (var i = 0; i < candidates.length; i++) {
    final (song: song, score: score) = candidates[i];
    if (i > 0) pool.write(',\n');
    final entry = <String, Object?>{
      // The index is the handle the model returns, not the path.
      'id': '$i',
      't': _clip(song.title, 40),
      'a': _clip(song.displayArtist, 25),
      'g': _clip(song.genre ?? '?', 15),
      's': score,
      if (options.includeExtendedFields) ...{
        'al': _clip(song.album, 25),
        'd': (song.duration / 1000).round(),
        'f': song.isFavorite ? 1 : 0,
      },
    };
    pool.write(jsonEncode(entry));
  }

  return [
    if (userDigest.trim().isNotEmpty) userDigest.trim(),
    '<request>',
    '<query>${_clip(request, 500)}</query>',
    '<target_length>$minLength-$maxLength tracks</target_length>',
    '</request>',
    '<candidate_pool>',
    '[$pool]',
    '</candidate_pool>',
  ].join('\n');
}

String _clip(String value, int max) {
  final cleaned = value.replaceAll('"', "'").trim();
  return cleaned.length > max ? cleaned.substring(0, max) : cleaned;
}

/// A short summary of listening habits, so the model has some idea who it is
/// curating for. The Android `UserProfileDigestGenerator` builds a much richer
/// one; this keeps it to the genres and artists, which is what the prompt
/// actually uses.
String buildUserDigest(
  List<Song> songs,
  ListeningStats stats, {
  int topCount = 5,
}) {
  if (stats.isEmpty) return '';
  final byArtist = <String, int>{};
  final byGenre = <String, int>{};
  for (final song in songs) {
    final listened = stats.msListened[song.id] ?? 0;
    if (listened <= 0) continue;
    byArtist[song.displayArtist] =
        (byArtist[song.displayArtist] ?? 0) + listened;
    final genre = song.genre;
    if (genre != null && genre.trim().isNotEmpty) {
      byGenre[genre] = (byGenre[genre] ?? 0) + listened;
    }
  }
  if (byArtist.isEmpty) return '';

  String top(Map<String, int> counts) =>
      (counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value)))
          .take(topCount)
          .map((entry) => entry.key)
          .join(', ');

  return [
    '<user_profile>',
    '<top_artists>${top(byArtist)}</top_artists>',
    if (byGenre.isNotEmpty) '<top_genres>${top(byGenre)}</top_genres>',
    '</user_profile>',
  ].join('\n');
}

/// Maps the model's answer back to real tracks.
///
/// Anything that is not an index into the pool is dropped, and so are
/// duplicates: a model repeating a track would otherwise put it in twice.
List<Song> resolvePlaylist(
  String rawResponse,
  List<({Song song, int score})> candidates,
) {
  final array = extractJsonArray(cleanJsonResponse(rawResponse));
  if (array == null) {
    throw const AiException(
      'The model did not return a playlist. Smaller models often struggle '
      'with this — try a more capable one in AI settings.',
    );
  }

  final Object? decoded;
  try {
    decoded = jsonDecode(array);
  } on FormatException catch (error) {
    throw AiException(
      'The model returned malformed JSON.',
      detail: error.message,
    );
  }
  if (decoded is! List) {
    throw const AiException('The model returned something other than a list.');
  }

  final chosen = <Song>[];
  final seen = <String>{};
  for (final entry in decoded) {
    // Models variously answer with "3", 3, or {"id": "3"}.
    final raw = switch (entry) {
      final String value => value,
      final num value => value.toString(),
      final Map<Object?, Object?> value => '${value['id'] ?? ''}',
      _ => '',
    };
    final index = int.tryParse(raw.trim());
    if (index == null || index < 0 || index >= candidates.length) continue;
    final song = candidates[index].song;
    if (seen.add(song.id)) chosen.add(song);
  }

  if (chosen.isEmpty) {
    throw const AiException(
      'The model picked tracks that are not in your library. Try again, or '
      'reword the request.',
    );
  }
  return chosen;
}

/// Ties it together: rank, prompt, ask, resolve.
class AiPlaylistGenerator {
  const AiPlaylistGenerator(this.client);

  final AiClient client;

  /// Returns the tracks, plus the model that answered so a recovered model can
  /// be written back to settings.
  Future<({List<Song> songs, String model})> generate({
    required String request,
    required List<Song> library,
    required ListeningStats stats,
    int minLength = 15,
    int maxLength = 25,
    String model = '',
    AiParams params = const AiParams(),
    AiSampleOptions options = const AiSampleOptions(),
    List<Song>? candidatePool,
    AiPromptType type = AiPromptType.playlist,
  }) async {
    final pool = candidatePool != null && candidatePool.isNotEmpty
        ? candidatePool
        : library;
    final candidates = rankCandidates(
      pool,
      stats,
      limit: options.effectiveSampleSize,
    );
    if (candidates.isEmpty) {
      throw const AiException('There is nothing in your library to pick from.');
    }

    final result = await client.generate(
      systemPrompt: buildSystemPrompt(type),
      prompt: buildPlaylistPrompt(
        request: request,
        candidates: candidates,
        minLength: minLength,
        maxLength: maxLength,
        options: options,
        userDigest: buildUserDigest(library, stats),
      ),
      model: model,
      params: params,
    );

    return (
      songs: resolvePlaylist(result.text, candidates),
      model: result.model,
    );
  }
}
