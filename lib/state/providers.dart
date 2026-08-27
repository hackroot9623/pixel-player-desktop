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
import '../data/remote/jellyfin_source.dart';
import '../data/remote/navidrome_source.dart';
import '../data/remote/remote_library.dart';
import '../data/remote/telegram/tdlib_client.dart';
import '../data/remote/telegram/telegram_credentials.dart';
import '../data/remote/telegram/telegram_source.dart';
import '../data/remote/youtube/youtube_source.dart';
import '../data/remote/youtube/ytdlp_client.dart';
import '../data/remote/drive/drive_source.dart';
import '../data/remote/drive/google_oauth.dart';
import '../data/remote/remote_account.dart';
import '../data/remote/remote_source.dart';
import '../data/scanner/library_scanner.dart';
import '../data/ai/ai_client.dart';
import '../data/ai/ai_playlist_generator.dart';
import '../data/smart/smart_playlists.dart';
import '../data/tags/tag_writer.dart';
import '../player/equalizer.dart';
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

  Playlist createPlaylist(
    String name, {
    List<String> songIds = const [],
    bool aiGenerated = false,
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final playlist = Playlist(
      id: 'pl_$now',
      name: name,
      songIds: songIds,
      createdAt: now,
      lastModified: now,
      isAiGenerated: aiGenerated,
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

/// The AI client for whichever provider is configured.
///
/// Rebuilt when the provider, key or endpoint changes, so a key pasted in
/// settings takes effect without a restart.
final aiClientProvider = Provider<AiClient>((ref) {
  final settings = ref.watch(settingsProvider);
  final provider = settings.aiProvider;
  final client = AiClient(
    provider: provider,
    apiKey: settings.apiKey(provider),
    baseUrl: provider.hasConfigurableUrl
        ? settings.aiBaseUrl(provider)
        : null,
  );
  ref.onDispose(client.close);
  return client;
});

/// Whether the AI features can be used at all.
final aiConfiguredProvider = Provider<bool>((ref) {
  final settings = ref.watch(settingsProvider);
  final provider = settings.aiProvider;
  if (provider.requiresApiKey && settings.apiKey(provider).isEmpty) {
    return false;
  }
  return !provider.hasConfigurableUrl ||
      settings.aiBaseUrl(provider).isNotEmpty ||
      provider.baseUrl.isNotEmpty;
});

/// The generation knobs from settings.
final aiParamsProvider = Provider<AiParams>((ref) {
  final settings = ref.watch(settingsProvider);
  return AiParams(
    temperature: settings.aiTemperature,
    topP: settings.aiTopP,
    topK: settings.aiTopK,
    maxTokens: settings.aiMaxTokens,
  );
});

final aiSampleOptionsProvider = Provider<AiSampleOptions>((ref) {
  final settings = ref.watch(settingsProvider);
  return AiSampleOptions(
    sampleSize: settings.aiSampleSize,
    safeTokenLimit: settings.aiSafeTokenLimit,
    includeExtendedFields: settings.aiExtendedFields,
  );
});

/// The models the configured key can use, for the picker in AI settings.
final aiModelsProvider = FutureProvider.autoDispose<List<String>>(
  (ref) => ref.watch(aiClientProvider).listModels(),
);

/// Builds a playlist from a written request.
///
/// Returns the tracks; it does not save or play them, so the sheet can show
/// what it got before the user commits to it.
Future<List<Song>> generateAiPlaylist(
  WidgetRef ref, {
  required String request,
  int minLength = 15,
  int maxLength = 25,
}) async {
  final settings = ref.read(settingsProvider);
  final provider = settings.aiProvider;
  final generator = AiPlaylistGenerator(ref.read(aiClientProvider));

  final result = await generator.generate(
    request: request,
    library: ref.read(libraryProvider).songs,
    stats: ref.read(listeningStatsProvider),
    minLength: minLength,
    maxLength: maxLength,
    model: settings.aiModel(provider),
    params: ref.read(aiParamsProvider),
    options: ref.read(aiSampleOptionsProvider),
  );

  // If the chosen model was retired and the client fell back, remember the one
  // that worked rather than failing the same way on every future request.
  if (result.model != settings.aiModel(provider) &&
      result.model.isNotEmpty) {
    settings.setAiModel(provider, result.model);
  }
  return result.songs;
}

/// The listening facts the smart playlists and the mix are built from.
final listeningStatsProvider = Provider<ListeningStats>((ref) {
  ref.watch(libraryProvider);
  final db = ref.watch(databaseProvider);
  return ListeningStats(
    msListened: {
      for (final (songId, ms, _) in db.topSongsByTime(limit: 100000))
        songId: ms,
    },
    playCounts: db.playCounts(),
    lastPlayedAt: db.lastPlayedAt(),
  );
});

/// "Your Mix" — weighted towards what you actually listen to, with unheard
/// tracks mixed in, and seeded by the date so it is stable for the day.
final dailyMixProvider = Provider<List<Song>>((ref) {
  final library = ref.watch(libraryProvider);
  if (library.songs.isEmpty) return const [];
  return buildDailyMix(library.songs, ref.watch(listeningStatsProvider));
});

/// One computed playlist per smart rule.
final smartPlaylistProvider =
    Provider.family<List<Song>, SmartPlaylistRule>((ref, rule) {
      final library = ref.watch(libraryProvider);
      if (library.songs.isEmpty) return const [];
      return evaluateSmartPlaylist(
        rule,
        library.songs,
        ref.watch(listeningStatsProvider),
      );
    });

/// Only the rules that currently have something in them, so the library does
/// not show four empty rows on a fresh install.
final populatedSmartPlaylistsProvider =
    Provider<List<(SmartPlaylistRule, List<Song>)>>((ref) {
      final result = <(SmartPlaylistRule, List<Song>)>[];
      for (final rule in SmartPlaylistRule.values) {
        final songs = ref.watch(smartPlaylistProvider(rule));
        if (songs.isNotEmpty) result.add((rule, songs));
      }
      return result;
    });

/// Suggested tracks to top up a playlist with.
final quickFillProvider = Provider.family<List<Song>, String>((
  ref,
  playlistId,
) {
  final library = ref.watch(libraryProvider);
  final playlist = library.playlists
      .where((pl) => pl.id == playlistId)
      .firstOrNull;
  if (playlist == null) return const [];
  final seed = ref.watch(databaseProvider).songsByIds(playlist.songIds);
  if (seed.isEmpty) return const [];
  return quickFill(seed, library.songs, ref.watch(listeningStatsProvider));
});

/// Everything the statistics screen shows, for one period.
class StatsSummary {
  const StatsSummary({
    required this.songCount,
    required this.albumCount,
    required this.artistCount,
    required this.libraryDuration,
    required this.listened,
    required this.plays,
    required this.streakDays,
    required this.byHour,
    required this.byDay,
    required this.topSongs,
    required this.topArtists,
    required this.topAlbums,
  });

  final int songCount;
  final int albumCount;
  final int artistCount;
  final Duration libraryDuration;
  final Duration listened;
  final int plays;
  final int streakDays;

  /// Hour of day (0-23) -> milliseconds listened.
  final Map<int, int> byHour;
  final List<(DateTime day, int ms)> byDay;
  final List<(Song song, Duration listened, int plays)> topSongs;
  final List<(String name, Duration listened)> topArtists;
  final List<(String title, Duration listened)> topAlbums;

  bool get hasHistory => listened > Duration.zero;
}

/// The window the statistics screen is showing.
enum StatsPeriod {
  week('Last 7 days', 7),
  month('Last 30 days', 30),
  year('Last year', 365),
  all('All time', null);

  const StatsPeriod(this.label, this.days);

  final String label;
  final int? days;

  DateTime? get since => days == null
      ? null
      : DateTime.now().subtract(Duration(days: days!));
}

final statsPeriodProvider = StateProvider<StatsPeriod>(
  (ref) => StatsPeriod.month,
);

final statsSummaryProvider = Provider<StatsSummary>((ref) {
  final library = ref.watch(libraryProvider);
  final db = ref.watch(databaseProvider);
  final period = ref.watch(statsPeriodProvider);
  final since = period.since;

  final songsById = {for (final song in library.songs) song.id: song};
  return StatsSummary(
    songCount: library.songs.length,
    albumCount: library.albums.length,
    artistCount: library.artists.length,
    libraryDuration: Duration(
      milliseconds: library.songs.fold(0, (sum, s) => sum + s.duration),
    ),
    listened: Duration(
      milliseconds: since == null
          ? db.totalListenedMs()
          : db.totalListenedMsSince(since),
    ),
    plays: db.totalPlays(),
    streakDays: db.listeningStreakDays(),
    byHour: db.listeningByHour(since: since),
    byDay: db.listeningByDay(days: period.days ?? 30),
    topSongs: [
      for (final (songId, ms, plays) in db.topSongsByTime(since: since))
        if (songsById[songId] != null)
          (songsById[songId]!, Duration(milliseconds: ms), plays),
    ],
    topArtists: [
      for (final (_, name, ms) in db.topArtistsByTime(since: since))
        (name, Duration(milliseconds: ms)),
    ],
    topAlbums: [
      for (final (_, title, ms) in db.topAlbumsByTime(since: since))
        (title, Duration(milliseconds: ms)),
    ],
  );
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

/// Artwork for the quantiser: a remote cover is a URL, a local one a file that
/// may since have been deleted.
ImageProvider? _artworkImage(String artPath) {
  if (artPath.startsWith('http://') || artPath.startsWith('https://')) {
    return NetworkImage(artPath);
  }
  final file = File(artPath);
  return file.existsSync() ? FileImage(file) : null;
}

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

  final image = _artworkImage(artPath);
  if (image == null) return null;
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

/// The light/dark scheme pair for one specific cover, for tiles that colour
/// themselves from their own artwork rather than from the playing track.
///
/// Shares [_schemeCache] with [albumArtSchemeProvider], so a cover that has
/// already themed the app costs nothing here. Returns null when there is no
/// artwork, or when the user has turned album-art colours off — the caller then
/// falls back to the plain surface roles.
final artworkSchemesProvider =
    FutureProvider.family<(ColorScheme, ColorScheme)?, String?>((
      ref,
      artPath,
    ) async {
      final settings = ref.watch(settingsProvider);
      if (!settings.useAlbumArtColors || artPath == null) return null;

      final variant = settings.paletteStyle;
      final key = '$artPath|${variant.name}';
      final cached = _schemeCache[key];
      if (cached != null) return cached;

      final image = _artworkImage(artPath);
      if (image == null) return null;
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
      if (_schemeCache.length > 64) _schemeCache.clear();
      _schemeCache[key] = result;
      return result;
    });

// -------------------------------------------------------------- equalizer

/// The equalizer setting, applied to mpv on every change and stored so it
/// survives a restart.
class EqualizerController extends StateNotifier<EqualizerState> {
  EqualizerController(this._settings, this._player)
    : super(_settings.equalizer);

  final Settings _settings;
  final PlayerService _player;

  void _apply(EqualizerState next) {
    state = next;
    _settings.equalizer = next;
    // mpv takes `af` live, so this is heard immediately rather than on the next
    // track.
    _player.applyAudioFilter(next.filter);
  }

  void setEnabled(bool enabled) => _apply(state.copyWith(enabled: enabled));

  void setGain(int band, int gain) => _apply(state.withGain(band, gain));

  /// Applies a preset, switching the equalizer on if it was off — tapping a
  /// preset and hearing nothing would read as a bug.
  void selectPreset(EqualizerPreset preset) =>
      _apply(state.withPreset(preset).copyWith(enabled: true));

  void setBassBoost(int strength) =>
      _apply(state.copyWith(bassBoost: strength));

  void setVirtualizer(int strength) =>
      _apply(state.copyWith(virtualizer: strength));

  void setLoudness(int strength) => _apply(state.copyWith(loudness: strength));

  /// Back to flat with the effects off, leaving the equalizer switched on.
  void reset() => _apply(
    EqualizerState(enabled: state.enabled, gains: EqualizerPreset.flat.gains),
  );
}

final equalizerProvider =
    StateNotifierProvider<EqualizerController, EqualizerState>(
      (ref) => EqualizerController(
        ref.watch(settingsProvider),
        ref.watch(playerProvider),
      ),
    );

// ---------------------------------------------------------- remote sources

/// Builds the client for one account. Kept out of the widgets so a screen never
/// has to know which protocol it is talking to.
RemoteSource remoteSourceFor(RemoteAccount account) => switch (account.kind) {
  RemoteKind.jellyfin => JellyfinSource(account),
  RemoteKind.navidrome => NavidromeSource(account),
  // Telegram is not an HTTP server: it holds a TDLib session and needs an
  // interactive login, so it lives behind telegramSourceProvider instead.
  RemoteKind.telegram => throw StateError(
    'Telegram is served by telegramSourceProvider',
  ),
  RemoteKind.youtube => throw StateError(
    'YouTube is served by youtubeSourceProvider',
  ),
  // Drive is ordinary HTTP once a token is in hand, but the token has to be
  // stored when it is renewed and mpv has to be told about the header, so it
  // comes through driveSourceFor instead.
  RemoteKind.drive => throw StateError('Drive is served by driveSourceFor'),
};

/// Builds a Drive client that saves its renewed session and registers the
/// bearer header mpv needs to open a Drive stream.
DriveSource driveSourceFor(Ref ref, RemoteAccount account) {
  final settings = ref.read(settingsProvider);
  return DriveSource(
    account,
    onSession: (renewed) {
      settings.upsertRemoteAccount(renewed);
      registerDriveHeaders(renewed);
    },
  );
}

/// Teaches the player how to authorise a Drive stream URL.
///
/// Drive's download endpoint takes a bearer header and nothing else — no signed
/// URL, no token in the query — so the header has to reach mpv when the queue
/// is opened.
void registerDriveHeaders(RemoteAccount account) {
  final token = driveTokens(account)?.accessToken ?? '';
  if (token.isEmpty) return;
  PlayerService.remoteStreamHeaders['https://www.googleapis.com/drive/v3/'] =
      driveStreamHeaders(token);
}

/// Runs the browser consent for a Drive account and stores the session.
Future<RemoteAccount> connectDriveAccount(
  WidgetRef ref,
  RemoteAccount account,
) async {
  final oauth = GoogleOAuth(
    clientId: driveClientId(account),
    clientSecret: driveClientSecret(account),
  );
  final tokens = await oauth.authorize();
  final connected = account.copyWith(
    extra: {...account.extra, ...tokens.storage},
  );
  ref.read(settingsProvider).upsertRemoteAccount(connected);
  registerDriveHeaders(connected);
  ref.invalidate(remoteSongsProvider(connected.id));
  return connected;
}

/// The application's own Telegram credentials, if this build has them.
///
/// Present when compiled with `--dart-define=TELEGRAM_API_ID/HASH` or when a
/// `telegram_app.json` sits beside the app's data. When present the user only
/// signs in with a phone number and a code, as on Android.
final telegramAppCredentialsProvider = Provider<TelegramAppCredentials>(
  (ref) => TelegramAppCredentials.resolve(
    configDirectory: p.dirname(ref.watch(artworkDirProvider)),
  ),
);

/// Where TDLib keeps its session and downloaded files.
final telegramDirectoriesProvider =
    Provider<({String database, String files})>((ref) {
      final root = ref.watch(artworkDirProvider);
      final base = p.join(p.dirname(root), 'telegram');
      return (
        database: p.join(base, 'db'),
        files: p.join(base, 'files'),
      );
    });

/// The live TDLib client for one account.
///
/// One per account and kept alive: TDLib holds a socket to Telegram and a
/// session on disk, so tearing it down between screens would mean logging in
/// again. It is started lazily, because creating it dials Telegram.
final telegramClientProvider =
    Provider.family<TdlibClient, String>((ref, accountId) {
      final account = ref
          .watch(remoteAccountsProvider)
          .where((entry) => entry.id == accountId)
          .firstOrNull;
      if (account == null) {
        throw const TdlibException('That Telegram account is gone.');
      }
      final dirs = ref.watch(telegramDirectoriesProvider);
      // An account can carry its own pair, for someone who would rather use
      // their own registration; otherwise the build's own is used.
      final appCredentials = ref.watch(telegramAppCredentialsProvider);
      final own = TelegramAppCredentials.fromStrings(
        account.extra['apiId'] ?? '',
        account.extra['apiHash'] ?? '',
      );
      final credentials = own.isPresent ? own : appCredentials;
      if (!credentials.isPresent) {
        throw const TdlibException(
          'This build has no Telegram api_id. Add one in the Telegram setup, '
          'or build with --dart-define=TELEGRAM_API_ID and TELEGRAM_API_HASH.',
        );
      }
      final client = TdlibClient(
        transport: FfiTdlibTransport.open(
          explicitPath: account.extra['libraryPath'],
        ),
        apiId: credentials.apiId,
        apiHash: credentials.apiHash,
        databaseDirectory: p.join(dirs.database, account.id),
        filesDirectory: p.join(dirs.files, account.id),
      );
      client.start();
      ref.onDispose(client.close);
      return client;
    });

final telegramSourceProvider =
    Provider.family<TelegramSource, String>((ref, accountId) {
      final account = ref
          .watch(remoteAccountsProvider)
          .firstWhere((entry) => entry.id == accountId);
      return TelegramSource(
        account: account,
        client: ref.watch(telegramClientProvider(accountId)),
      );
    });

/// Downloads the file behind a Telegram song and plays the queue from it.
///
/// Telegram has no streamable URL — the Android app fakes one with a localhost
/// proxy over a partial download. Here the file is fetched first and then handed
/// to the player as an ordinary local file, and the next track is fetched in the
/// background so a queue keeps moving.
Future<void> playTelegramQueue(
  WidgetRef ref,
  List<Song> songs, {
  int startIndex = 0,
  void Function(double progress)? onProgress,
}) async {
  if (songs.isEmpty) return;
  final accountId = ref.read(activeSourceProvider);
  if (accountId == null) return;
  final source = ref.read(telegramSourceProvider(accountId));

  Future<Song> resolve(Song song) async {
    if (song.path.isNotEmpty && File(song.path).existsSync()) return song;
    final path = await source.download(song, onProgress: onProgress);
    return song.copyWith(path: path);
  }

  final first = await resolve(songs[startIndex]);
  final queue = [...songs]..[startIndex] = first;
  await ref.read(playerProvider).playQueue(queue, startIndex: startIndex);

  // Warm the next track so the gap between songs is not a download.
  if (startIndex + 1 < songs.length) {
    unawaited(
      resolve(songs[startIndex + 1]).catchError((_) => songs[startIndex + 1]),
    );
  }
}

final remoteAccountsProvider = Provider<List<RemoteAccount>>(
  (ref) => ref.watch(settingsProvider).remoteAccounts,
);

/// The tracks one account offers.
///
/// Remote libraries are held in memory rather than written into the local
/// database: a rescan calls `replaceLibrary`, which would drop them, and a
/// server's catalogue is its own business rather than something to mirror.
final remoteSongsProvider =
    FutureProvider.family<List<Song>, String>((ref, accountId) async {
      final account = ref
          .watch(remoteAccountsProvider)
          .where((entry) => entry.id == accountId)
          .firstOrNull;
      if (account == null) return const [];

      if (account.kind == RemoteKind.youtube) {
        return ref.watch(youtubeSourceProvider(accountId)).songs();
      }

      if (account.kind == RemoteKind.drive) {
        final source = driveSourceFor(ref, account);
        ref.onDispose(source.close);
        final songs = await source.songs();
        // The token may have been the stored one rather than a fresh one, in
        // which case onSession never fired and mpv still needs the header.
        registerDriveHeaders(account);
        return songs;
      }

      if (account.kind == RemoteKind.telegram) {
        // No sign-in step here: TDLib restores its own session, and the setup
        // screen is what drives an interactive login.
        return ref.watch(telegramSourceProvider(accountId)).songs();
      }

      final source = remoteSourceFor(account);
      ref.onDispose(source.close);
      if (!account.isAuthenticated) {
        // Jellyfin tokens expire; signing in again here keeps the browse screen
        // working without sending the user back to Accounts.
        final refreshed = await source.connect();
        ref.read(settingsProvider).upsertRemoteAccount(refreshed);
        final reconnected = remoteSourceFor(refreshed);
        ref.onDispose(reconnected.close);
        return reconnected.songs();
      }
      return source.songs();
    });

/// Signs in and stores whatever the server returned. Returns the saved account.
Future<RemoteAccount> connectRemoteAccount(
  WidgetRef ref,
  RemoteAccount account,
) async {
  final source = remoteSourceFor(account);
  try {
    final connected = await source.connect();
    ref.read(settingsProvider).upsertRemoteAccount(connected);
    ref.invalidate(remoteSongsProvider(connected.id));
    return connected;
  } finally {
    source.close();
  }
}

/// Which source the browse screens show: null is the local library.
final activeSourceProvider = Provider<String?>((ref) {
  final settings = ref.watch(settingsProvider);
  final id = settings.activeSourceId;
  if (id == null) return null;
  // A stored id whose account has gone falls back to local rather than showing
  // an empty library.
  final exists = settings.remoteAccounts.any((account) => account.id == id);
  return exists ? id : null;
});

/// The account behind [activeSourceProvider], or null when showing local files.
final activeAccountProvider = Provider<RemoteAccount?>((ref) {
  final id = ref.watch(activeSourceProvider);
  if (id == null) return null;
  return ref
      .watch(remoteAccountsProvider)
      .where((account) => account.id == id)
      .firstOrNull;
});

/// The library the browse screens should read.
///
/// Either the scanned local library or a server's catalogue presented in the
/// same shape, so Home, Search, Library and the detail screens work against a
/// remote account without knowing about one. Playlists, folders and tag editing
/// stay local — those are properties of files on this machine.
final activeLibraryProvider = Provider<LibraryState>((ref) {
  final accountId = ref.watch(activeSourceProvider);
  if (accountId == null) return ref.watch(libraryProvider);

  final remote = ref.watch(remoteSongsProvider(accountId));
  final local = ref.watch(libraryProvider);
  return remote.when(
    loading: () => const LibraryState(scanning: true),
    error: (error, _) => LibraryState(
      error: error is RemoteException
          ? error.message
          : 'Could not load this server.',
    ),
    data: (songs) {
      final grouped = groupSongs(songs);
      return LibraryState(
        songs: songs,
        albums: grouped.albums,
        artists: grouped.artists,
        genres: grouped.genres,
        // A server's own playlists are not ported yet; the local ones would be
        // misleading here, since their tracks are not on this server.
        playlists: const [],
        favorites: [
          for (final song in songs)
            if (song.isFavorite) song,
        ],
        scanProgress: local.scanProgress,
      );
    },
  );
});

// ------------------------------------------------------------ youtube music

/// The yt-dlp-backed YouTube Music source for one account.
final youtubeSourceProvider =
    Provider.family<YoutubeSource, String>((ref, accountId) {
      final account = ref
          .watch(remoteAccountsProvider)
          .firstWhere((entry) => entry.id == accountId);
      return YoutubeSource(
        account: account,
        client: YtDlpClient(
          executable: youtubeExecutable(account),
          cookiesFromBrowser: youtubeCookiesBrowser(account),
          cookiesFile: youtubeCookiesFile(account),
        ),
      );
    });

/// The installed yt-dlp version, or null when the binary cannot be found.
final ytDlpVersionProvider =
    FutureProvider.autoDispose.family<String?, String>((ref, accountId) {
      final account = ref
          .watch(remoteAccountsProvider)
          .where((entry) => entry.id == accountId)
          .firstOrNull;
      return YtDlpClient(
        executable: account == null ? 'yt-dlp' : youtubeExecutable(account),
      ).version();
    });

/// Search results, for the YouTube browse screen.
final youtubeSearchProvider = FutureProvider.autoDispose
    .family<List<Song>, ({String accountId, String query})>((ref, args) async {
      if (args.query.trim().isEmpty) return const [];
      return ref
          .watch(youtubeSourceProvider(args.accountId))
          .search(args.query);
    });

/// Plays a YouTube queue, resolving each stream URL as it is needed.
///
/// A YouTube stream URL expires and is tied to the requesting address, so unlike
/// a Jellyfin stream it cannot be kept in the library and replayed later. The
/// chosen track is therefore resolved and played at once, and the rest of the
/// queue is resolved one at a time in the background and appended as it lands —
/// resolving the whole queue up front would mean one yt-dlp run per track before
/// a single note played.
///
/// [onProgress] reports how many tracks are ready, for the UI to show.
Future<void> playYoutubeQueue(
  WidgetRef ref,
  List<Song> songs, {
  int startIndex = 0,
  void Function(int resolved, int total)? onProgress,
}) async {
  if (songs.isEmpty) return;
  final accountId = ref.read(activeSourceProvider);
  if (accountId == null) return;
  final source = ref.read(youtubeSourceProvider(accountId));
  final player = ref.read(playerProvider);

  final chosen = songs[startIndex];
  await player.playQueue([
    chosen.copyWith(path: await source.resolve(chosen)),
  ]);
  onProgress?.call(1, songs.length);

  // Everything after the chosen track, then everything before it: what "play
  // from here" implies for the rest of a list.
  final rest = [
    ...songs.sublist(startIndex + 1),
    ...songs.sublist(0, startIndex),
  ];

  unawaited(
    Future(() async {
      var resolved = 1;
      for (final song in rest) {
        try {
          final url = await source.resolve(song);
          await player.addToQueue([song.copyWith(path: url)]);
          resolved++;
          onProgress?.call(resolved, songs.length);
        } on YtDlpException {
          // One unavailable track should not stop the queue filling.
          continue;
        }
      }
    }),
  );
}

/// Plays [songs], routing by where the chosen track comes from.
///
/// A local file can go straight to the player, but a YouTube track needs its
/// stream URL resolved first and a Telegram track needs its file downloaded.
/// Every "play" affordance in the UI goes through here so none of them has to
/// know which.
Future<void> playSongs(
  WidgetRef ref,
  List<Song> songs, {
  int startIndex = 0,
}) async {
  if (songs.isEmpty) return;
  final index = startIndex.clamp(0, songs.length - 1);
  switch (remoteKindOfSongId(songs[index].id)) {
    case RemoteKind.youtube:
      await playYoutubeQueue(ref, songs, startIndex: index);
    case RemoteKind.telegram:
      await playTelegramQueue(ref, songs, startIndex: index);
    case _:
      await ref.read(playerProvider).playQueue(songs, startIndex: index);
  }
}

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

/// The artist image, fetched on first watch.
///
/// Opening the artist screen is what triggers the lookup — no button press —
/// and the repository records every outcome, so this resolves from the cache
/// on every later visit.
final artistImageProvider = FutureProvider.family<Artist, int>((
  ref,
  artistId,
) async {
  ref.watch(libraryProvider);
  final artist = ref.watch(databaseProvider).artist(artistId);
  if (artist == null) throw StateError('No artist $artistId');
  return ref.watch(artistImageRepositoryProvider).fetch(artist);
});

/// Retries a failed lookup, bypassing the recorded outcome.
Future<void> retryArtistImage(WidgetRef ref, Artist artist) async {
  await ref.read(artistImageRepositoryProvider).fetch(artist, force: true);
  ref.invalidate(artistImageProvider(artist.id));
}
