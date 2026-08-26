import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../data/artists/artist_image_repository.dart';
import '../data/db/database.dart';
import '../data/lyrics/lrclib_client.dart';
import '../data/lyrics/lyrics_repository.dart';
import '../data/models/lyrics.dart';
import '../data/models/models.dart';
import '../data/models/sort_option.dart';
import '../data/prefs/settings.dart';
import '../data/scanner/library_scanner.dart';
import '../data/tags/tag_writer.dart';
import '../player/player_service.dart';

/// Riverpod replaces Hilt (`di/`) plus the 49 `presentation/viewmodel` classes.
/// Both of the roots below are overridden in `main()` once the async
/// initialisation has completed.
final settingsProvider = ChangeNotifierProvider<Settings>(
  (ref) => throw StateError('settingsProvider must be overridden in main()'),
);

final databaseProvider = Provider<MusicDatabase>(
  (ref) => throw StateError('databaseProvider must be overridden in main()'),
);

/// Absolute path of the extracted-artwork cache, set up in `main()`.
final artworkDirProvider = Provider<String>(
  (ref) => throw StateError('artworkDirProvider must be overridden in main()'),
);

final playerProvider = ChangeNotifierProvider<PlayerService>((ref) {
  // `read`, not `watch`: Settings is a ChangeNotifier, and watching it would
  // tear down and recreate the whole player on every preference write.
  // ChangeNotifierProvider disposes the notifier itself, so registering
  // `service.dispose` here as well would dispose it twice.
  return PlayerService(
    ref.watch(databaseProvider),
    ref.read(settingsProvider),
  );
});

// ---------------------------------------------------------------- library

class LibraryState {
  const LibraryState({
    this.songs = const [],
    this.albums = const [],
    this.artists = const [],
    this.genres = const [],
    this.playlists = const [],
    this.favorites = const [],
    this.scanning = false,
    this.scanProgress,
    this.error,
  });

  final List<Song> songs;
  final List<Album> albums;
  final List<Artist> artists;
  final List<Genre> genres;
  final List<Playlist> playlists;
  final List<Song> favorites;
  final bool scanning;
  final ScanProgress? scanProgress;
  final String? error;

  bool get isEmpty => songs.isEmpty;

  LibraryState copyWith({
    List<Song>? songs,
    List<Album>? albums,
    List<Artist>? artists,
    List<Genre>? genres,
    List<Playlist>? playlists,
    List<Song>? favorites,
    bool? scanning,
    ScanProgress? scanProgress,
    String? error,
  }) => LibraryState(
    songs: songs ?? this.songs,
    albums: albums ?? this.albums,
    artists: artists ?? this.artists,
    genres: genres ?? this.genres,
    playlists: playlists ?? this.playlists,
    favorites: favorites ?? this.favorites,
    scanning: scanning ?? this.scanning,
    scanProgress: scanning == false ? null : (scanProgress ?? this.scanProgress),
    error: error,
  );
}

/// The desktop counterpart of `MusicRepositoryImpl` + `LibraryViewModel`.
class LibraryNotifier extends StateNotifier<LibraryState> {
  LibraryNotifier(this._db, this._settings, this._artworkDir)
    : super(const LibraryState()) {
    reload();
    // Folders are configured but nothing has been indexed yet (first run after
    // setup, or the database was cleared) — index in the background, the way
    // `MediaStoreSyncWorker` kicks off on Android.
    if (state.songs.isEmpty && _db.allFolders(onlyEnabled: true).isNotEmpty) {
      rescan();
    }
  }

  final MusicDatabase _db;
  final Settings _settings;
  final String _artworkDir;

  /// Re-reads everything from SQLite. Cheap enough to call after any mutation.
  void reload() {
    state = state.copyWith(
      songs: _db.allSongs(),
      albums: _db.allAlbums(),
      artists: _db.allArtists(),
      genres: _db.allGenres(),
      playlists: _db.allPlaylists(),
      favorites: _db.favoriteSongs(),
    );
  }

  Future<void> addFolder(String path) async {
    _db.addFolder(path);
    _settings.musicFolders = _db.allFolders();
    await rescan();
  }

  Future<void> removeFolder(String path) async {
    _db.removeFolder(path);
    _settings.musicFolders = _db.allFolders();
    await rescan();
  }

  List<String> get folders => _db.allFolders();

  Future<void> rescan() async {
    if (state.scanning) return;
    final roots = _db.allFolders(onlyEnabled: true);
    if (roots.isEmpty) {
      _db.replaceLibrary(const []);
      reload();
      return;
    }
    state = state.copyWith(scanning: true);
    final done = Completer<void>();
    scanLibrary(
      ScanRequest(
        roots: roots,
        artworkDir: _artworkDir,
        artistDelimiters: _settings.artistDelimiters,
        multiArtistEnabled: _settings.multiArtistEnabled,
      ),
      onDone: (songs) {
        _db.replaceLibrary(songs);
        state = state.copyWith(scanning: false);
        reload();
        if (!done.isCompleted) done.complete();
      },
    ).listen(
      (progress) => state = state.copyWith(scanProgress: progress, scanning: true),
      onError: (Object e) {
        state = state.copyWith(scanning: false, error: '$e');
        if (!done.isCompleted) done.complete();
      },
    );
    return done.future;
  }

  // ------------------------------------------------------------ mutations

  void toggleFavorite(Song song) {
    _db.setFavorite(song.id, !_db.isFavorite(song.id));
    reload();
  }

  Playlist createPlaylist(String name, {List<String> songIds = const []}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final playlist = Playlist(
      id: 'pl_$now',
      name: name,
      songIds: songIds,
      createdAt: now,
      lastModified: now,
    );
    _db.upsertPlaylist(playlist);
    reload();
    return playlist;
  }

  void renamePlaylist(Playlist playlist, String name) {
    _db.upsertPlaylist(
      Playlist(
        id: playlist.id,
        name: name,
        songIds: playlist.songIds,
        createdAt: playlist.createdAt,
        lastModified: DateTime.now().millisecondsSinceEpoch,
        isAiGenerated: playlist.isAiGenerated,
        isQueueGenerated: playlist.isQueueGenerated,
        coverImagePath: playlist.coverImagePath,
        coverColorArgb: playlist.coverColorArgb,
        coverIconName: playlist.coverIconName,
        coverShapeType: playlist.coverShapeType,
        source: playlist.source,
      ),
    );
    reload();
  }

  void setPlaylistSongs(Playlist playlist, List<String> songIds) {
    _db.upsertPlaylist(
      Playlist(
        id: playlist.id,
        name: playlist.name,
        songIds: songIds,
        createdAt: playlist.createdAt,
        lastModified: DateTime.now().millisecondsSinceEpoch,
        isAiGenerated: playlist.isAiGenerated,
        isQueueGenerated: playlist.isQueueGenerated,
        coverImagePath: playlist.coverImagePath,
        coverColorArgb: playlist.coverColorArgb,
        coverIconName: playlist.coverIconName,
        coverShapeType: playlist.coverShapeType,
        source: playlist.source,
      ),
    );
    reload();
  }

  void addToPlaylist(Playlist playlist, List<String> songIds) => setPlaylistSongs(
    playlist,
    [...playlist.songIds, ...songIds.where((id) => !playlist.songIds.contains(id))],
  );

  void deletePlaylist(String id) {
    _db.deletePlaylist(id);
    reload();
  }
}

final libraryProvider = StateNotifierProvider<LibraryNotifier, LibraryState>(
  // Settings is read, not watched, for the same reason as playerProvider: a
  // preference write must not restart an in-flight scan. Widgets that need to
  // react to a setting watch `settingsProvider` themselves.
  (ref) => LibraryNotifier(
    ref.watch(databaseProvider),
    ref.read(settingsProvider),
    ref.watch(artworkDirProvider),
  ),
);

// --------------------------------------------------------------- selectors

final songsForAlbumProvider = Provider.family<List<Song>, int>((ref, albumId) {
  ref.watch(libraryProvider);
  return ref.watch(databaseProvider).songsForAlbum(albumId);
});

final songsForArtistProvider = Provider.family<List<Song>, int>((ref, artistId) {
  ref.watch(libraryProvider);
  return ref.watch(databaseProvider).songsForArtist(artistId);
});

final albumsForArtistProvider = Provider.family<List<Album>, int>((ref, artistId) {
  ref.watch(libraryProvider);
  return ref.watch(databaseProvider).albumsForArtist(artistId);
});

final songsForGenreProvider = Provider.family<List<Song>, String>((ref, genre) {
  ref.watch(libraryProvider);
  return ref.watch(databaseProvider).songsForGenre(genre);
});

final foldersProvider = Provider.family<List<MusicFolder>, String?>((ref, parent) {
  ref.watch(libraryProvider);
  return ref.watch(databaseProvider).foldersIn(parent);
});

final songsInFolderProvider = Provider.family<List<Song>, String>((ref, dir) {
  ref.watch(libraryProvider);
  return ref.watch(databaseProvider).songsInDirectory(dir);
});

/// Whether a song is liked, straight from the database.
///
/// The `Song` objects held in the player's queue are snapshots taken when the
/// queue was built, so their `isFavorite` never changes — reading it made the
/// player's like button inert. This is the single source of truth.
final isFavoriteProvider = Provider.family<bool, String>((ref, songId) {
  ref.watch(libraryProvider);
  return ref.watch(databaseProvider).isFavorite(songId);
});

final recentlyPlayedProvider = Provider<List<Song>>((ref) {
  ref.watch(libraryProvider);
  final db = ref.watch(databaseProvider);
  return db.songsByIds(db.recentlyPlayedIds());
});

/// "Your Mix" / Daily Mix preview — weighted by play count, with unheard
/// tracks mixed in so the row is never empty on a fresh library.
final dailyMixProvider = Provider<List<Song>>((ref) {
  final library = ref.watch(libraryProvider);
  if (library.songs.isEmpty) return const [];
  final counts = ref.watch(databaseProvider).playCounts();
  final ranked = [...library.songs]
    ..sort((a, b) => (counts[b.id] ?? 0).compareTo(counts[a.id] ?? 0));
  final played = ranked.where((s) => (counts[s.id] ?? 0) > 0).take(12).toList();
  final rest = [...library.songs]..shuffle();
  return [
    ...played,
    ...rest.where((s) => !played.contains(s)).take(20 - played.length),
  ];
});

class SearchResults {
  const SearchResults({
    this.songs = const [],
    this.albums = const [],
    this.artists = const [],
    this.playlists = const [],
  });

  final List<Song> songs;
  final List<Album> albums;
  final List<Artist> artists;
  final List<Playlist> playlists;

  bool get isEmpty =>
      songs.isEmpty && albums.isEmpty && artists.isEmpty && playlists.isEmpty;
}

final searchQueryProvider = StateProvider<String>((ref) => '');

final searchResultsProvider = Provider<SearchResults>((ref) {
  final query = ref.watch(searchQueryProvider).trim().toLowerCase();
  final library = ref.watch(libraryProvider);
  if (query.isEmpty) return const SearchResults();
  bool hit(String value) => value.toLowerCase().contains(query);
  return SearchResults(
    songs: ref.watch(databaseProvider).search(query),
    albums: library.albums
        .where((a) => hit(a.title) || hit(a.artist))
        .take(30)
        .toList(),
    artists: library.artists.where((a) => hit(a.name)).take(30).toList(),
    playlists: library.playlists.where((pl) => hit(pl.name)).take(30).toList(),
  );
});

final libraryTabProvider = StateProvider<LibraryTabId>(
  (ref) => LibraryTabId.songs,
);

// ------------------------------------------------------------------- theme

/// Album-art driven `ColorScheme`, the desktop stand-in for the Android app's
/// `ColorSchemePair` extraction. `ColorScheme.fromImageProvider` runs the same
/// Material color quantiser that Compose's dynamic color uses.
/// Quantising artwork is expensive (tens of ms), so results are memoised by
/// artwork path + palette style. Without this, revisiting a track re-ran the
/// whole extraction and the theme visibly lagged behind the music.
final _schemeCache = <String, (ColorScheme, ColorScheme)>{};

final albumArtSchemeProvider = FutureProvider<(ColorScheme, ColorScheme)?>((
  ref,
) async {
  final settings = ref.watch(settingsProvider);
  if (!settings.useAlbumArtColors) return null;

  // `select` is load-bearing: watching the whole player re-ran this provider on
  // every position tick, so the extraction never finished before being thrown
  // away and the colours arrived long after the track changed.
  final artPath = ref.watch(
    playerProvider.select((player) => player.current?.albumArtPath),
  );
  if (artPath == null) return null;

  final variant = settings.paletteStyle;
  final key = '$artPath|${variant.name}';
  final cached = _schemeCache[key];
  if (cached != null) return cached;

  if (!File(artPath).existsSync()) return null;
  final image = FileImage(File(artPath));
  final light = await ColorScheme.fromImageProvider(
    provider: image,
    dynamicSchemeVariant: variant,
  );
  final dark = await ColorScheme.fromImageProvider(
    provider: image,
    brightness: Brightness.dark,
    dynamicSchemeVariant: variant,
  );
  final result = (light, dark);
  // Bounded so a long listening session cannot grow it without limit.
  if (_schemeCache.length > 64) _schemeCache.clear();
  _schemeCache[key] = result;
  return result;
});

// ------------------------------------------------------------------- stats

class LibraryStats {
  const LibraryStats({
    required this.songCount,
    required this.albumCount,
    required this.artistCount,
    required this.totalDuration,
    required this.totalPlays,
    required this.listenedDuration,
  });

  final int songCount;
  final int albumCount;
  final int artistCount;
  final Duration totalDuration;
  final int totalPlays;
  final Duration listenedDuration;
}

final statsProvider = Provider<LibraryStats>((ref) {
  final library = ref.watch(libraryProvider);
  final db = ref.watch(databaseProvider);
  return LibraryStats(
    songCount: library.songs.length,
    albumCount: library.albums.length,
    artistCount: library.artists.length,
    totalDuration: Duration(
      milliseconds: library.songs.fold(0, (sum, s) => sum + s.duration),
    ),
    totalPlays: db.totalPlays(),
    listenedDuration: Duration(milliseconds: db.totalListenedMs()),
  );
});

/// Default music directory offered on the setup screen.
Future<String?> defaultMusicDirectory() async {
  final dir = await getDownloadsDirectory();
  final home = Platform.environment['HOME'];
  for (final candidate in [
    if (home != null) p.join(home, 'Music'),
    if (dir != null) dir.path,
  ]) {
    if (Directory(candidate).existsSync()) return candidate;
  }
  return null;
}

// ------------------------------------------------------------------ lyrics

final lyricsRepositoryProvider = Provider<LyricsRepository>((ref) {
  final repository = LyricsRepository(ref.watch(databaseProvider));
  ref.onDispose(repository.dispose);
  return repository;
});

/// Lyrics for the playing track, resolved through the user's source order.
///
/// Keyed on the song id only, so the lookup is not repeated while the track
/// plays — and, unlike a plain `watch(playerProvider)`, position ticks cannot
/// restart the network request.
final currentLyricsProvider = FutureProvider<Lyrics?>((ref) async {
  final song = ref.watch(playerProvider.select((player) => player.current));
  if (song == null) return null;
  final settings = ref.watch(settingsProvider);
  return ref
      .watch(lyricsRepositoryProvider)
      .resolve(
        song,
        preference: settings.lyricsSource,
        allowNetwork: settings.autoFetchLyrics,
      );
});

/// Search results for the "fetch lyrics" dialog.
final lyricsSearchProvider = FutureProvider.family<List<LrcLibResult>, String>((
  ref,
  query,
) async {
  if (query.trim().isEmpty) return const [];
  return ref.watch(lyricsRepositoryProvider).search(query: query);
});

// -------------------------------------------------------------------- tags

final artistImageRepositoryProvider = Provider<ArtistImageRepository>((ref) {
  final repository = ArtistImageRepository(
    ref.watch(databaseProvider),
    ref.watch(artworkDirProvider),
  );
  ref.onDispose(repository.dispose);
  return repository;
});

/// Writes tags to disk and refreshes just that song's row.
///
/// A full rescan would be wasteful and would lose the user's place; re-reading
/// the one file keeps the library honest about what is actually in it.
class TagEditor {
  TagEditor(this._db, this._settings, this._artworkDir);

  final MusicDatabase _db;
  final Settings _settings;
  final String _artworkDir;

  /// Applies [edit] to every song given, returning the failures by song id.
  ///
  /// Carries on after a failure: with a multi-song edit, one unwritable file
  /// should not abandon the rest.
  Map<String, String> apply(List<Song> songs, TagEdit edit) {
    final failures = <String, String>{};
    for (final song in songs) {
      final file = File(song.path);
      if (!file.existsSync()) {
        failures[song.id] = 'File is missing';
        continue;
      }
      try {
        writeTags(file, edit);
        final refreshed = readSongFile(
          file,
          artworkDir: _artworkDir,
          artistDelimiters: _settings.artistDelimiters,
          multiArtistEnabled: _settings.multiArtistEnabled,
        );
        if (refreshed != null) _db.upsertSong(refreshed);
      } on TagWriteException catch (error) {
        failures[song.id] = error.message;
      }
    }
    return failures;
  }
}

final tagEditorProvider = Provider<TagEditor>(
  (ref) => TagEditor(
    ref.watch(databaseProvider),
    ref.read(settingsProvider),
    ref.watch(artworkDirProvider),
  ),
);
