import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/models.dart';
import '../tags/tag_writer.dart';
import 'metadata_lookup.dart';

// Finding the covers a library is missing.
//
// The unit of work is the album, not the song: one lookup covers every track,
// which matters because MusicBrainz allows one request a second — a 4000-song
// library with 300 coverless albums is five minutes, not an hour.
//
// Two steps on purpose. Find downloads and shows what it found; Apply writes it.
// Nothing is written to a file until the second step, so a wrong cover is
// something the user sees as a thumbnail rather than something they discover
// later in their tags.

/// An album with no cover, and the files that make it up.
class CoverlessAlbum {
  const CoverlessAlbum({
    required this.albumId,
    required this.album,
    required this.artist,
    required this.songs,
  });

  final int albumId;
  final String album;
  final String artist;
  final List<Song> songs;

  /// Whether there is enough to search with. An album tag of "" would send
  /// MusicBrainz a query matching everything.
  bool get isSearchable => album.trim().isNotEmpty;
}

/// The albums in [songs] that have no cover art.
///
/// Grouped by album id, and the artist used for the search is the album artist
/// when there is one — searching a compilation by its first track's performer
/// finds the wrong release.
List<CoverlessAlbum> coverlessAlbums(Iterable<Song> songs) {
  final groups = <int, List<Song>>{};
  for (final song in songs) {
    final art = song.albumArtPath;
    // A path recorded for a file that has since gone is still a missing cover.
    if (art != null && art.isNotEmpty && File(art).existsSync()) continue;
    groups.putIfAbsent(song.albumId, () => []).add(song);
  }

  final albums = [
    for (final entry in groups.entries)
      CoverlessAlbum(
        albumId: entry.key,
        album: entry.value.first.album,
        artist: _albumArtistOf(entry.value),
        songs: entry.value..sort((a, b) => a.trackNumber.compareTo(b.trackNumber)),
      ),
  ];
  // Biggest first: the album with twelve coverless tracks is the one worth
  // fixing before the stray single.
  albums.sort((a, b) {
    final bySize = b.songs.length.compareTo(a.songs.length);
    return bySize != 0 ? bySize : a.album.toLowerCase().compareTo(b.album.toLowerCase());
  });
  return albums;
}

String _albumArtistOf(List<Song> songs) {
  for (final song in songs) {
    final albumArtist = song.albumArtist;
    if (albumArtist != null && albumArtist.trim().isNotEmpty) return albumArtist;
  }
  return songs.first.artist;
}

enum CoverState { pending, searching, found, notFound, skipped, written, failed }

/// What was found for one album, and what happened when it was written.
class CoverCandidate {
  CoverCandidate(this.album);

  final CoverlessAlbum album;

  CoverState state = CoverState.pending;
  MetadataMatch? match;
  Uint8List? artwork;
  String? error;

  /// Whether Apply should write this one. Off for anything not found, and the
  /// user can clear it for a cover they do not like.
  bool selected = true;

  bool get hasArtwork => artwork != null && artwork!.isNotEmpty;
}

/// Writes tags. The seam that keeps the real writer out of the tests.
typedef CoverWriter = Map<String, String> Function(List<Song> songs, TagEdit edit);

/// Finds and applies missing covers.
class CoverFixer extends ChangeNotifier {
  CoverFixer({
    required this.lookup,
    required this.writer,
    this.onFinished,
  });


  final MetadataLookup lookup;
  final CoverWriter writer;

  /// Called once covers have been written, so the library can reload.
  final Future<void> Function()? onFinished;

  final _candidates = <CoverCandidate>[];
  bool _searching = false;
  bool _applying = false;
  bool _cancelled = false;
  int _written = 0;
  final _failures = <String, String>{};

  List<CoverCandidate> get candidates => List.unmodifiable(_candidates);
  bool get searching => _searching;
  bool get applying => _applying;
  bool get busy => _searching || _applying;
  bool get cancelled => _cancelled;

  /// Files whose cover was written.
  int get written => _written;
  Map<String, String> get failures => Map.unmodifiable(_failures);

  int get found => _candidates.where((c) => c.state == CoverState.found).length;
  int get selectedCount =>
      _candidates.where((c) => c.selected && c.hasArtwork).length;
  int get searched => _candidates
      .where((c) => c.state != CoverState.pending && c.state != CoverState.searching)
      .length;

  double? get progress =>
      _candidates.isEmpty ? null : searched / _candidates.length;

  /// Lists the albums with no cover. Nothing leaves the machine here.
  void scan(Iterable<Song> songs) {
    _candidates
      ..clear()
      ..addAll([for (final album in coverlessAlbums(songs)) CoverCandidate(album)]);
    for (final candidate in _candidates) {
      if (!candidate.album.isSearchable) {
        candidate.state = CoverState.skipped;
        candidate.error = 'No album tag to search with';
        candidate.selected = false;
      }
    }
    _written = 0;
    _failures.clear();
    _cancelled = false;
    notifyListeners();
  }

  /// Looks each album up and downloads what it finds.
  Future<void> find() async {
    if (busy) return;
    _searching = true;
    _cancelled = false;
    notifyListeners();

    for (final candidate in _candidates) {
      if (_cancelled) break;
      if (candidate.state == CoverState.skipped) continue;
      if (candidate.hasArtwork) continue;

      candidate
        ..state = CoverState.searching
        ..error = null;
      notifyListeners();

      try {
        final matches = await lookup.searchAlbums(
          album: candidate.album.album,
          artist: candidate.album.artist,
        );
        final match = matches.isEmpty ? null : matches.first;
        // Even with no MusicBrainz release there is still Deezer, which is keyed
        // by name rather than by id.
        final artwork = match != null
            ? await lookup.cover(match)
            : await lookup.coverFromDeezer(
                album: candidate.album.album,
                artist: candidate.album.artist,
              );

        if (artwork == null || artwork.isEmpty) {
          candidate
            ..state = CoverState.notFound
            ..selected = false
            ..match = match;
        } else {
          candidate
            ..state = CoverState.found
            ..match = match
            ..artwork = artwork
            ..selected = true;
        }
      } on MetadataLookupException catch (failure) {
        candidate
          ..state = CoverState.failed
          ..error = failure.message
          ..selected = false;
      }
      notifyListeners();
    }

    _searching = false;
    notifyListeners();
  }

  /// Writes the selected covers into the files.
  Future<void> apply() async {
    if (busy) return;
    _applying = true;
    _cancelled = false;
    _written = 0;
    _failures.clear();
    notifyListeners();

    var wroteSomething = false;
    for (final candidate in _candidates) {
      if (_cancelled) break;
      if (!candidate.selected || !candidate.hasArtwork) continue;

      // Only the artwork: this screen is about covers, and quietly rewriting an
      // album or a year the user never asked about is how a batch tool loses
      // trust.
      final failures = writer(
        candidate.album.songs,
        TagEdit(artwork: candidate.artwork),
      );
      _failures.addAll(failures);
      final written = candidate.album.songs.length - failures.length;
      _written += written;
      if (written > 0) wroteSomething = true;
      candidate.state = failures.isEmpty
          ? CoverState.written
          : CoverState.failed;
      if (failures.isNotEmpty) {
        candidate.error = failures.values.first;
      }
      notifyListeners();
    }

    _applying = false;
    notifyListeners();
    if (wroteSomething) await onFinished?.call();
  }

  void toggle(CoverCandidate candidate, bool selected) {
    candidate.selected = selected && candidate.hasArtwork;
    notifyListeners();
  }

  void selectAll(bool selected) {
    for (final candidate in _candidates) {
      candidate.selected = selected && candidate.hasArtwork;
    }
    notifyListeners();
  }

  /// Stops after the album in flight. What is already written stays.
  void cancel() {
    if (!busy) return;
    _cancelled = true;
    notifyListeners();
  }
}
