import 'dart:io';

import 'package:path/path.dart' as p;

import '../db/database.dart';
import '../models/lyrics.dart';
import '../models/models.dart';
import 'lrc_parser.dart';
import 'lrclib_client.dart';

/// Ported from `data/repository/LyricsRepositoryImpl`.
///
/// Resolution order follows the user's [LyricsSourcePreference]. Whatever is
/// found is cached in the `lyrics` table, so the network is consulted at most
/// once per track — and never at all for tracks that ship their own lyrics.
class LyricsRepository {
  LyricsRepository(this._db, {LrcLibClient? client})
    : _client = client ?? LrcLibClient();

  final MusicDatabase _db;
  final LrcLibClient _client;

  void dispose() => _client.close();

  /// Returns the cached lyrics without touching the network.
  Lyrics? cached(Song song) {
    final row = _db.lyricsFor(song.id);
    if (row == null) return null;
    return parseLyrics(
      row.content,
      source: LyricsSource.fromName(row.source),
      offsetMs: row.offsetMs,
    );
  }

  /// Full lookup. [allowNetwork] is false when the user has auto-fetch off, so
  /// the local sources are still consulted.
  Future<Lyrics?> resolve(
    Song song, {
    required LyricsSourcePreference preference,
    bool allowNetwork = true,
    bool forceRefresh = false,
  }) async {
    if (!forceRefresh) {
      final cachedLyrics = cached(song);
      if (cachedLyrics != null && !cachedLyrics.isEmpty) return cachedLyrics;
    }

    for (final source in preference.order) {
      final found = switch (source) {
        LyricsSource.embedded => _fromEmbedded(song),
        LyricsSource.local => _fromSidecar(song),
        LyricsSource.remote => allowNetwork ? await _fromRemote(song) : null,
        LyricsSource.manual => null,
      };
      if (found != null && !found.isEmpty) {
        _store(song, found);
        return found;
      }
    }
    return null;
  }

  Lyrics? _fromEmbedded(Song song) {
    final embedded = song.lyrics;
    if (embedded == null || embedded.trim().isEmpty) return null;
    return parseLyrics(embedded, source: LyricsSource.embedded);
  }

  /// A `.lrc` (or `.txt`) file sitting next to the audio file — how desktop
  /// libraries usually carry synced lyrics.
  Lyrics? _fromSidecar(Song song) {
    final withoutExtension = p.withoutExtension(song.path);
    for (final extension in const ['.lrc', '.LRC', '.txt']) {
      final file = File('$withoutExtension$extension');
      if (!file.existsSync()) continue;
      try {
        return parseLyrics(
          file.readAsStringSync(),
          source: LyricsSource.local,
        );
      } on FileSystemException {
        continue;
      }
    }
    return null;
  }

  Future<Lyrics?> _fromRemote(Song song) async {
    final result = await _client.get(
      trackName: song.title,
      artistName: song.primaryArtist.name,
      albumName: song.album,
      durationSeconds: (song.duration / 1000).round(),
    );
    return _fromResult(result);
  }

  Lyrics? _fromResult(LrcLibResult? result) {
    if (result == null || !result.hasAny) return null;
    final content = result.hasSynced ? result.syncedLyrics! : result.plainLyrics!;
    return parseLyrics(content, source: LyricsSource.remote);
  }

  /// Backs the "fetch lyrics" dialog (`FetchLyricsDialog`).
  Future<List<LrcLibResult>> search({String? query, Song? song}) =>
      _client.search(
        query: query,
        trackName: song?.title,
        artistName: song?.primaryArtist.name,
        albumName: song?.album,
      );

  /// Applies a search result the user picked.
  Lyrics? applyResult(Song song, LrcLibResult result) {
    final lyrics = _fromResult(result);
    if (lyrics != null) _store(song, lyrics);
    return lyrics;
  }

  /// Saves hand-edited lyrics (`EditSongSheet`'s lyrics field).
  Lyrics? saveManual(Song song, String content) {
    final lyrics = parseLyrics(content, source: LyricsSource.manual);
    if (lyrics == null) {
      _db.deleteLyrics(song.id);
      return null;
    }
    _store(song, lyrics);
    return lyrics;
  }

  void setOffset(Song song, int offsetMs) {
    _db.setLyricsOffset(song.id, offsetMs);
  }

  void clear(Song song) => _db.deleteLyrics(song.id);

  void _store(Song song, Lyrics lyrics) => _db.saveLyrics(
    song.id,
    content: toLrc(lyrics),
    isSynced: lyrics.isSynced,
    source: lyrics.source.name,
    offsetMs: lyrics.offsetMs,
  );
}
