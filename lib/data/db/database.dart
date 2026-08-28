import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../models/models.dart';

/// Replaces the Room setup in `data/database/` (48 files of entities, DAOs and
/// migrations). Raw SQL keeps the whole schema readable in one place and needs
/// no codegen step; the DAO surface is the method list below.
///
/// ponytail: single connection, synchronous. sqlite3 via FFI is fast enough for
/// libraries in the tens of thousands of tracks; move scan writes to an isolate
/// with its own connection if a scan ever blocks the UI noticeably.
class MusicDatabase {
  MusicDatabase._(this._db);

  final Database _db;

  static const schemaVersion = 3;

  static Future<MusicDatabase> open(String directory) async {
    await Directory(directory).create(recursive: true);
    final db = sqlite3.open(p.join(directory, 'pixelplay.db'));
    db.execute('PRAGMA journal_mode = WAL');
    db.execute('PRAGMA foreign_keys = ON');
    final instance = MusicDatabase._(db);
    instance._migrate();
    return instance;
  }

  void close() => _db.close();

  void _migrate() {
    final current = _db.select('PRAGMA user_version').first.values.first as int;
    if (current >= schemaVersion) return;
    // Every statement below is `IF NOT EXISTS`, so re-running the whole block
    // is how an older database picks up tables added by a later version.
    // Column changes, when they come, will need their own ALTER step here.
    _db.execute('''
      CREATE TABLE IF NOT EXISTS songs (
        id            TEXT PRIMARY KEY,
        title         TEXT NOT NULL,
        artist        TEXT NOT NULL,
        artist_id     INTEGER NOT NULL,
        album         TEXT NOT NULL,
        album_id      INTEGER NOT NULL,
        album_artist  TEXT,
        path          TEXT NOT NULL UNIQUE,
        album_art_path TEXT,
        duration      INTEGER NOT NULL,
        genre         TEXT,
        lyrics        TEXT,
        track_number  INTEGER NOT NULL DEFAULT 0,
        disc_number   INTEGER,
        year          INTEGER NOT NULL DEFAULT 0,
        date_added    INTEGER NOT NULL DEFAULT 0,
        date_modified INTEGER NOT NULL DEFAULT 0,
        mime_type     TEXT,
        bitrate       INTEGER,
        sample_rate   INTEGER
      );
      CREATE INDEX IF NOT EXISTS idx_songs_album ON songs(album_id);
      CREATE INDEX IF NOT EXISTS idx_songs_artist ON songs(artist_id);
      CREATE INDEX IF NOT EXISTS idx_songs_title ON songs(title COLLATE NOCASE);

      CREATE TABLE IF NOT EXISTS artists (
        id               INTEGER PRIMARY KEY,
        name             TEXT NOT NULL UNIQUE,
        image_url        TEXT,
        custom_image_uri TEXT
      );

      CREATE TABLE IF NOT EXISTS song_artists (
        song_id    TEXT NOT NULL REFERENCES songs(id) ON DELETE CASCADE,
        artist_id  INTEGER NOT NULL REFERENCES artists(id) ON DELETE CASCADE,
        is_primary INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (song_id, artist_id)
      );

      CREATE TABLE IF NOT EXISTS albums (
        id             INTEGER PRIMARY KEY,
        title          TEXT NOT NULL,
        artist         TEXT NOT NULL,
        album_artist   TEXT,
        year           INTEGER NOT NULL DEFAULT 0,
        date_added     INTEGER NOT NULL DEFAULT 0,
        album_art_path TEXT
      );

      CREATE TABLE IF NOT EXISTS favorites (
        song_id  TEXT PRIMARY KEY REFERENCES songs(id) ON DELETE CASCADE,
        liked_at INTEGER NOT NULL
      );

      CREATE TABLE IF NOT EXISTS playlists (
        id                TEXT PRIMARY KEY,
        name              TEXT NOT NULL,
        created_at        INTEGER NOT NULL,
        last_modified     INTEGER NOT NULL,
        is_ai_generated   INTEGER NOT NULL DEFAULT 0,
        is_queue_generated INTEGER NOT NULL DEFAULT 0,
        cover_image_path  TEXT,
        cover_color_argb  INTEGER,
        cover_icon_name   TEXT,
        cover_shape_type  TEXT,
        source            TEXT NOT NULL DEFAULT 'LOCAL'
      );

      CREATE TABLE IF NOT EXISTS playlist_songs (
        playlist_id TEXT NOT NULL REFERENCES playlists(id) ON DELETE CASCADE,
        song_id     TEXT NOT NULL,
        position    INTEGER NOT NULL,
        PRIMARY KEY (playlist_id, position)
      );

      CREATE TABLE IF NOT EXISTS playback_history (
        id        INTEGER PRIMARY KEY AUTOINCREMENT,
        song_id   TEXT NOT NULL,
        played_at INTEGER NOT NULL,
        ms_played INTEGER NOT NULL DEFAULT 0
      );
      CREATE INDEX IF NOT EXISTS idx_history_played_at
        ON playback_history(played_at DESC);

      CREATE TABLE IF NOT EXISTS search_history (
        query       TEXT PRIMARY KEY,
        searched_at INTEGER NOT NULL
      );

      CREATE TABLE IF NOT EXISTS music_folders (
        path    TEXT PRIMARY KEY,
        enabled INTEGER NOT NULL DEFAULT 1
      );

      -- Deliberately not a column on `artists`: replaceLibrary clears that
      -- table on every rescan, which would throw away downloaded and
      -- user-chosen pictures along with the lookup history.
      CREATE TABLE IF NOT EXISTS artist_images (
        artist_id   INTEGER PRIMARY KEY,
        image_path  TEXT,
        custom_path TEXT,
        remote_id   INTEGER,
        remote_name TEXT,
        status      TEXT NOT NULL DEFAULT 'unknown',
        error       TEXT,
        fetched_at  INTEGER
      );

      CREATE TABLE IF NOT EXISTS lyrics (
        song_id   TEXT PRIMARY KEY,
        content   TEXT NOT NULL,
        is_synced INTEGER NOT NULL DEFAULT 0,
        source    TEXT,
        offset_ms INTEGER NOT NULL DEFAULT 0
      );
    ''');
    // Carry across anything the old per-artist columns already held, so an
    // upgrade does not re-download what the user already has.
    if (current == 2) {
      _db.execute('''
        INSERT OR IGNORE INTO artist_images
          (artist_id, image_path, custom_path, status)
        SELECT id, image_url, custom_image_uri,
               CASE WHEN image_url IS NULL THEN 'unknown' ELSE 'ok' END
        FROM artists
        WHERE image_url IS NOT NULL OR custom_image_uri IS NOT NULL
      ''');
    }
    _db.execute('PRAGMA user_version = $schemaVersion');
  }

  // ---------------------------------------------------------------- folders

  List<String> allFolders({bool onlyEnabled = false}) => _db
      .select(
        onlyEnabled
            ? 'SELECT path FROM music_folders WHERE enabled = 1 ORDER BY path'
            : 'SELECT path FROM music_folders ORDER BY path',
      )
      .map((r) => r['path'] as String)
      .toList();

  void addFolder(String path) => _db.execute(
    'INSERT OR IGNORE INTO music_folders(path, enabled) VALUES (?, 1)',
    [path],
  );

  void removeFolder(String path) =>
      _db.execute('DELETE FROM music_folders WHERE path = ?', [path]);

  void setFolderEnabled(String path, bool enabled) => _db.execute(
    'UPDATE music_folders SET enabled = ? WHERE path = ?',
    [enabled ? 1 : 0, path],
  );

  // ------------------------------------------------------------------ sync

  /// Replaces the whole library in one transaction, the desktop equivalent of
  /// the `MediaStoreSyncWorker` full pass.
  void replaceLibrary(List<Song> songs) {
    _db.execute('BEGIN');
    try {
      _db.execute('DELETE FROM song_artists');
      _db.execute('DELETE FROM songs');
      _db.execute('DELETE FROM artists');
      _db.execute('DELETE FROM albums');

      final songStmt = _db.prepare('''
        INSERT INTO songs (id, title, artist, artist_id, album, album_id,
          album_artist, path, album_art_path, duration, genre, lyrics,
          track_number, disc_number, year, date_added, date_modified,
          mime_type, bitrate, sample_rate)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
      ''');
      final artistStmt = _db.prepare(
        'INSERT OR IGNORE INTO artists (id, name) VALUES (?, ?)',
      );
      final songArtistStmt = _db.prepare(
        'INSERT OR IGNORE INTO song_artists (song_id, artist_id, is_primary) '
        'VALUES (?, ?, ?)',
      );
      final albumStmt = _db.prepare('''
        INSERT INTO albums (id, title, artist, album_artist, year, date_added,
          album_art_path)
        VALUES (?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET
          album_art_path = COALESCE(albums.album_art_path, excluded.album_art_path),
          year = MAX(albums.year, excluded.year)
      ''');

      for (final s in songs) {
        songStmt.execute([
          s.id,
          s.title,
          s.artist,
          s.artistId,
          s.album,
          s.albumId,
          s.albumArtist,
          s.path,
          s.albumArtPath,
          s.duration,
          s.genre,
          s.lyrics,
          s.trackNumber,
          s.discNumber,
          s.year,
          s.dateAdded,
          s.dateModified,
          s.mimeType,
          s.bitrate,
          s.sampleRate,
        ]);
        albumStmt.execute([
          s.albumId,
          s.album,
          s.albumArtist ?? s.artist,
          s.albumArtist,
          s.year,
          s.dateAdded,
          s.albumArtPath,
        ]);
        for (final a in s.artists.isEmpty
            ? [ArtistRef(id: s.artistId, name: s.artist, isPrimary: true)]
            : s.artists) {
          artistStmt.execute([a.id, a.name]);
          songArtistStmt.execute([s.id, a.id, a.isPrimary ? 1 : 0]);
        }
      }
      songStmt.close();
      artistStmt.close();
      songArtistStmt.close();
      albumStmt.close();
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// Replaces one song's row, for a file whose tags were just edited.
  ///
  /// Keeps its artists in step, and leaves favourites, playlists and history
  /// alone — they key off the song id, which is the file path.
  void upsertSong(Song song) {
    _db.execute('BEGIN');
    try {
      _db.execute('DELETE FROM song_artists WHERE song_id = ?', [song.id]);
      _db.execute(
        '''
        INSERT INTO songs (id, title, artist, artist_id, album, album_id,
          album_artist, path, album_art_path, duration, genre, lyrics,
          track_number, disc_number, year, date_added, date_modified,
          mime_type, bitrate, sample_rate)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET
          title = excluded.title, artist = excluded.artist,
          artist_id = excluded.artist_id, album = excluded.album,
          album_id = excluded.album_id, album_artist = excluded.album_artist,
          album_art_path = excluded.album_art_path,
          duration = excluded.duration, genre = excluded.genre,
          lyrics = excluded.lyrics, track_number = excluded.track_number,
          disc_number = excluded.disc_number, year = excluded.year,
          date_modified = excluded.date_modified,
          mime_type = excluded.mime_type, bitrate = excluded.bitrate,
          sample_rate = excluded.sample_rate
        ''',
        [
          song.id,
          song.title,
          song.artist,
          song.artistId,
          song.album,
          song.albumId,
          song.albumArtist,
          song.path,
          song.albumArtPath,
          song.duration,
          song.genre,
          song.lyrics,
          song.trackNumber,
          song.discNumber,
          song.year,
          song.dateAdded,
          song.dateModified,
          song.mimeType,
          song.bitrate,
          song.sampleRate,
        ],
      );
      _db.execute(
        '''
        INSERT INTO albums (id, title, artist, album_artist, year, date_added,
          album_art_path)
        VALUES (?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET
          album_art_path = excluded.album_art_path,
          year = MAX(albums.year, excluded.year)
        ''',
        [
          song.albumId,
          song.album,
          song.albumArtist ?? song.artist,
          song.albumArtist,
          song.year,
          song.dateAdded,
          song.albumArtPath,
        ],
      );
      for (final artist in song.artists.isEmpty
          ? [ArtistRef(id: song.artistId, name: song.artist, isPrimary: true)]
          : song.artists) {
        _db.execute(
          'INSERT OR IGNORE INTO artists (id, name) VALUES (?, ?)',
          [artist.id, artist.name],
        );
        _db.execute(
          'INSERT OR IGNORE INTO song_artists (song_id, artist_id, is_primary) '
          'VALUES (?,?,?)',
          [song.id, artist.id, artist.isPrimary ? 1 : 0],
        );
      }
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  // --------------------------------------------------------- artist images

  /// Records the outcome of a lookup, successful or not, so it is not
  /// repeated on every visit to the artist.
  void saveArtistImage(
    int artistId, {
    String? imagePath,
    int? remoteId,
    String? remoteName,
    required ArtistImageStatus status,
    String? error,
  }) => _db.execute(
    '''
    INSERT INTO artist_images
      (artist_id, image_path, remote_id, remote_name, status, error, fetched_at)
    VALUES (?,?,?,?,?,?,?)
    ON CONFLICT(artist_id) DO UPDATE SET
      image_path = COALESCE(excluded.image_path, artist_images.image_path),
      remote_id = COALESCE(excluded.remote_id, artist_images.remote_id),
      remote_name = COALESCE(excluded.remote_name, artist_images.remote_name),
      status = excluded.status,
      error = excluded.error,
      fetched_at = excluded.fetched_at
    ''',
    [
      artistId,
      imagePath,
      remoteId,
      remoteName,
      status.name,
      error,
      DateTime.now().millisecondsSinceEpoch,
    ],
  );

  /// A picture the user chose, which wins over the remote one.
  void setArtistCustomImage(int artistId, String? path) => _db.execute(
    '''
    INSERT INTO artist_images (artist_id, custom_path, status)
    VALUES (?, ?, 'unknown')
    ON CONFLICT(artist_id) DO UPDATE SET custom_path = excluded.custom_path
    ''',
    [artistId, path],
  );

  void clearArtistImage(int artistId) =>
      _db.execute('DELETE FROM artist_images WHERE artist_id = ?', [artistId]);

  /// Artists that have never been looked up, for the batch fetch.
  List<Artist> artistsMissingImages() => allArtists()
      .where((artist) => artist.effectiveImageUrl == null && !artist.imageLookedUp)
      .toList();

  // ----------------------------------------------------------------- reads

  static const _songSelect = '''
    SELECT s.*, (f.song_id IS NOT NULL) AS is_favorite
    FROM songs s LEFT JOIN favorites f ON f.song_id = s.id
  ''';

  Song _song(Row r, {List<ArtistRef> artists = const []}) => Song(
    id: r['id'] as String,
    title: r['title'] as String,
    artist: r['artist'] as String,
    artistId: r['artist_id'] as int,
    artists: artists,
    album: r['album'] as String,
    albumId: r['album_id'] as int,
    albumArtist: r['album_artist'] as String?,
    path: r['path'] as String,
    albumArtPath: r['album_art_path'] as String?,
    duration: r['duration'] as int,
    genre: r['genre'] as String?,
    lyrics: r['lyrics'] as String?,
    isFavorite: (r['is_favorite'] as int? ?? 0) != 0,
    trackNumber: r['track_number'] as int,
    discNumber: r['disc_number'] as int?,
    year: r['year'] as int,
    dateAdded: r['date_added'] as int,
    dateModified: r['date_modified'] as int,
    mimeType: r['mime_type'] as String?,
    bitrate: r['bitrate'] as int?,
    sampleRate: r['sample_rate'] as int?,
  );

  /// Song-id -> all its artists, resolved in one query so song lists do not
  /// fan out into N+1 lookups.
  Map<String, List<ArtistRef>> _artistsBySong() {
    final map = <String, List<ArtistRef>>{};
    for (final r in _db.select('''
      SELECT sa.song_id, a.id, a.name, sa.is_primary
      FROM song_artists sa JOIN artists a ON a.id = sa.artist_id
    ''')) {
      map.putIfAbsent(r['song_id'] as String, () => []).add(
        ArtistRef(
          id: r['id'] as int,
          name: r['name'] as String,
          isPrimary: (r['is_primary'] as int) != 0,
        ),
      );
    }
    return map;
  }

  List<Song> allSongs() {
    final artists = _artistsBySong();
    return _db
        .select('$_songSelect ORDER BY s.title COLLATE NOCASE')
        .map((r) => _song(r, artists: artists[r['id']] ?? const []))
        .toList();
  }

  List<Song> songsByIds(List<String> ids) {
    if (ids.isEmpty) return const [];
    final placeholders = List.filled(ids.length, '?').join(',');
    final artists = _artistsBySong();
    final rows = _db.select(
      '$_songSelect WHERE s.id IN ($placeholders)',
      ids,
    );
    final byId = {
      for (final r in rows)
        r['id'] as String: _song(r, artists: artists[r['id']] ?? const []),
    };
    // Preserve the caller's order (queue snapshots, playlists, history).
    return [for (final id in ids) if (byId[id] != null) byId[id]!];
  }

  List<Song> songsForAlbum(int albumId) {
    final artists = _artistsBySong();
    return _db
        .select(
          '$_songSelect WHERE s.album_id = ? '
          'ORDER BY s.disc_number, s.track_number, s.title COLLATE NOCASE',
          [albumId],
        )
        .map((r) => _song(r, artists: artists[r['id']] ?? const []))
        .toList();
  }

  List<Song> songsForArtist(int artistId) {
    final artists = _artistsBySong();
    return _db
        .select('''
          SELECT s.*, (f.song_id IS NOT NULL) AS is_favorite
          FROM songs s
          LEFT JOIN favorites f ON f.song_id = s.id
          WHERE s.id IN (SELECT song_id FROM song_artists WHERE artist_id = ?)
          ORDER BY s.album COLLATE NOCASE, s.disc_number, s.track_number
        ''', [artistId])
        .map((r) => _song(r, artists: artists[r['id']] ?? const []))
        .toList();
  }

  List<Song> songsForGenre(String genre) {
    final artists = _artistsBySong();
    return _db
        .select(
          '$_songSelect WHERE s.genre = ? ORDER BY s.title COLLATE NOCASE',
          [genre],
        )
        .map((r) => _song(r, artists: artists[r['id']] ?? const []))
        .toList();
  }

  List<Song> songsInDirectory(String dir, {bool recursive = false}) {
    final artists = _artistsBySong();
    final pattern = recursive ? '$dir${p.separator}%' : null;
    final rows = recursive
        ? _db.select(
            '$_songSelect WHERE s.path LIKE ? ORDER BY s.title COLLATE NOCASE',
            [pattern],
          )
        : _db.select(
            '$_songSelect WHERE s.path LIKE ? AND s.path NOT LIKE ? '
            'ORDER BY s.track_number, s.title COLLATE NOCASE',
            ['$dir${p.separator}%', '$dir${p.separator}%${p.separator}%'],
          );
    return rows
        .map((r) => _song(r, artists: artists[r['id']] ?? const []))
        .toList();
  }

  List<Song> favoriteSongs() {
    final artists = _artistsBySong();
    return _db
        .select('''
          SELECT s.*, 1 AS is_favorite, f.liked_at
          FROM songs s JOIN favorites f ON f.song_id = s.id
          ORDER BY f.liked_at DESC
        ''')
        .map((r) => _song(r, artists: artists[r['id']] ?? const []))
        .toList();
  }

  List<Album> allAlbums() => _db
      .select('''
        SELECT a.*, COUNT(s.id) AS song_count
        FROM albums a LEFT JOIN songs s ON s.album_id = a.id
        GROUP BY a.id
        ORDER BY a.title COLLATE NOCASE
      ''')
      .map(
        (r) => Album(
          id: r['id'] as int,
          title: r['title'] as String,
          artist: r['artist'] as String,
          albumArtist: r['album_artist'] as String?,
          year: r['year'] as int,
          dateAdded: r['date_added'] as int,
          albumArtPath: r['album_art_path'] as String?,
          songCount: r['song_count'] as int,
        ),
      )
      .toList();

  Album? album(int id) => allAlbums().where((a) => a.id == id).firstOrNull;

  List<Album> albumsForArtist(int artistId) => _db
      .select('''
        SELECT a.*, COUNT(s.id) AS song_count
        FROM albums a JOIN songs s ON s.album_id = a.id
        WHERE s.id IN (SELECT song_id FROM song_artists WHERE artist_id = ?)
        GROUP BY a.id
        ORDER BY a.year DESC, a.title COLLATE NOCASE
      ''', [artistId])
      .map(
        (r) => Album(
          id: r['id'] as int,
          title: r['title'] as String,
          artist: r['artist'] as String,
          albumArtist: r['album_artist'] as String?,
          year: r['year'] as int,
          dateAdded: r['date_added'] as int,
          albumArtPath: r['album_art_path'] as String?,
          songCount: r['song_count'] as int,
        ),
      )
      .toList();

  List<Artist> allArtists() => _db
      .select('''
        SELECT a.id, a.name, i.image_path, i.custom_path, i.status, i.error,
               COUNT(DISTINCT sa.song_id) AS song_count,
               COUNT(DISTINCT s.album_id) AS album_count
        FROM artists a
        LEFT JOIN artist_images i ON i.artist_id = a.id
        LEFT JOIN song_artists sa ON sa.artist_id = a.id
        LEFT JOIN songs s ON s.id = sa.song_id
        GROUP BY a.id
        HAVING song_count > 0
        ORDER BY a.name COLLATE NOCASE
      ''')
      .map(
        (r) => Artist(
          id: r['id'] as int,
          name: r['name'] as String,
          songCount: r['song_count'] as int,
          albumCount: r['album_count'] as int,
          imageUrl: r['image_path'] as String?,
          customImageUri: r['custom_path'] as String?,
          imageStatus: _artistImageStatus(r['status'] as String?),
          imageError: r['error'] as String?,
        ),
      )
      .toList();

  static ArtistImageStatus _artistImageStatus(String? name) =>
      ArtistImageStatus.values.firstWhere(
        (status) => status.name == name,
        orElse: () => ArtistImageStatus.unknown,
      );

  Artist? artist(int id) => allArtists().where((a) => a.id == id).firstOrNull;

  List<Genre> allGenres() => _db
      .select('''
        SELECT genre, COUNT(*) AS song_count FROM songs
        WHERE genre IS NOT NULL AND TRIM(genre) <> ''
        GROUP BY genre ORDER BY genre COLLATE NOCASE
      ''')
      .map(
        (r) => Genre(
          id: r['genre'] as String,
          name: r['genre'] as String,
          songCount: r['song_count'] as int,
        ),
      )
      .toList();

  /// Directory tree derived from song paths — the desktop stand-in for
  /// `FolderExplorerScreen`'s MediaStore-backed listing.
  List<MusicFolder> foldersIn(String? parent) {
    final paths = _db
        .select('SELECT path FROM songs')
        .map((r) => r['path'] as String);
    final direct = <String, int>{};
    final deep = <String, int>{};
    for (final path in paths) {
      final dir = p.dirname(path);
      if (parent == null) {
        // Top level: one entry per configured root that actually has songs.
        for (final root in allFolders()) {
          if (p.equals(dir, root) || p.isWithin(root, dir)) {
            deep[root] = (deep[root] ?? 0) + 1;
            if (p.equals(dir, root)) direct[root] = (direct[root] ?? 0) + 1;
          }
        }
        continue;
      }
      if (!p.isWithin(parent, dir) && !p.equals(dir, parent)) continue;
      if (p.equals(dir, parent)) {
        direct[parent] = (direct[parent] ?? 0) + 1;
        continue;
      }
      final rel = p.relative(dir, from: parent);
      final child = p.join(parent, p.split(rel).first);
      deep[child] = (deep[child] ?? 0) + 1;
    }
    final entries = parent == null ? deep.keys : deep.keys;
    return [
      for (final dir in entries)
        MusicFolder(
          path: dir,
          name: p.basename(dir).isEmpty ? dir : p.basename(dir),
          songCount: deep[dir] ?? 0,
          subdirCount: _countSubdirs(dir),
        ),
    ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  }

  int _countSubdirs(String dir) {
    final children = <String>{};
    for (final r in _db.select(
      'SELECT path FROM songs WHERE path LIKE ?',
      ['$dir${p.separator}%'],
    )) {
      final songDir = p.dirname(r['path'] as String);
      if (p.equals(songDir, dir)) continue;
      children.add(p.split(p.relative(songDir, from: dir)).first);
    }
    return children.length;
  }

  List<Song> search(String query, {int limit = 200}) {
    final like = '%${query.trim()}%';
    final artists = _artistsBySong();
    return _db
        .select('''
          $_songSelect
          WHERE s.title LIKE ? OR s.artist LIKE ? OR s.album LIKE ?
             OR s.genre LIKE ?
          ORDER BY
            CASE WHEN s.title LIKE ? THEN 0 ELSE 1 END,
            s.title COLLATE NOCASE
          LIMIT ?
        ''', [like, like, like, like, '${query.trim()}%', limit])
        .map((r) => _song(r, artists: artists[r['id']] ?? const []))
        .toList();
  }

  int songCount() =>
      _db.select('SELECT COUNT(*) AS c FROM songs').first['c'] as int;

  // ------------------------------------------------------------- favorites

  void setFavorite(String songId, bool favorite) {
    if (favorite) {
      _db.execute(
        'INSERT OR REPLACE INTO favorites(song_id, liked_at) VALUES (?, ?)',
        [songId, DateTime.now().millisecondsSinceEpoch],
      );
    } else {
      _db.execute('DELETE FROM favorites WHERE song_id = ?', [songId]);
    }
  }

  bool isFavorite(String songId) =>
      _db
          .select('SELECT 1 FROM favorites WHERE song_id = ?', [songId])
          .isNotEmpty;

  // ------------------------------------------------------------- playlists

  List<Playlist> allPlaylists() {
    final songIds = <String, List<String>>{};
    for (final r in _db.select(
      'SELECT playlist_id, song_id FROM playlist_songs ORDER BY position',
    )) {
      songIds
          .putIfAbsent(r['playlist_id'] as String, () => [])
          .add(r['song_id'] as String);
    }
    return _db
        .select('SELECT * FROM playlists ORDER BY name COLLATE NOCASE')
        .map(
          (r) => Playlist(
            id: r['id'] as String,
            name: r['name'] as String,
            songIds: songIds[r['id']] ?? const [],
            createdAt: r['created_at'] as int,
            lastModified: r['last_modified'] as int,
            isAiGenerated: (r['is_ai_generated'] as int) != 0,
            isQueueGenerated: (r['is_queue_generated'] as int) != 0,
            coverImagePath: r['cover_image_path'] as String?,
            coverColorArgb: r['cover_color_argb'] as int?,
            coverIconName: r['cover_icon_name'] as String?,
            coverShapeType: r['cover_shape_type'] as String?,
            source: r['source'] as String,
          ),
        )
        .toList();
  }

  Playlist? playlist(String id) =>
      allPlaylists().where((pl) => pl.id == id).firstOrNull;

  void upsertPlaylist(Playlist playlist) {
    _db.execute('BEGIN');
    try {
      _db.execute(
        '''
        INSERT INTO playlists (id, name, created_at, last_modified,
          is_ai_generated, is_queue_generated, cover_image_path,
          cover_color_argb, cover_icon_name, cover_shape_type, source)
        VALUES (?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET
          name = excluded.name,
          last_modified = excluded.last_modified,
          cover_image_path = excluded.cover_image_path,
          cover_color_argb = excluded.cover_color_argb,
          cover_icon_name = excluded.cover_icon_name,
          cover_shape_type = excluded.cover_shape_type
        ''',
        [
          playlist.id,
          playlist.name,
          playlist.createdAt,
          playlist.lastModified,
          playlist.isAiGenerated ? 1 : 0,
          playlist.isQueueGenerated ? 1 : 0,
          playlist.coverImagePath,
          playlist.coverColorArgb,
          playlist.coverIconName,
          playlist.coverShapeType,
          playlist.source,
        ],
      );
      _db.execute('DELETE FROM playlist_songs WHERE playlist_id = ?', [
        playlist.id,
      ]);
      final stmt = _db.prepare(
        'INSERT INTO playlist_songs(playlist_id, song_id, position) '
        'VALUES (?,?,?)',
      );
      for (var i = 0; i < playlist.songIds.length; i++) {
        stmt.execute([playlist.id, playlist.songIds[i], i]);
      }
      stmt.close();
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  void deletePlaylist(String id) =>
      _db.execute('DELETE FROM playlists WHERE id = ?', [id]);

  // --------------------------------------------------------------- history

  /// Opens a listening event and returns its row id.
  ///
  /// The duration is filled in when the track stops, so "recently played"
  /// updates the moment something starts while the time listened stays honest.
  int startPlayback(String songId, {DateTime? at}) {
    _db.execute(
      'INSERT INTO playback_history(song_id, played_at, ms_played) '
      'VALUES (?,?,0)',
      [songId, (at ?? DateTime.now()).millisecondsSinceEpoch],
    );
    return _db.lastInsertRowId;
  }

  /// Records how much of the track was actually heard.
  void finishPlayback(int eventId, int msPlayed) => _db.execute(
    'UPDATE playback_history SET ms_played = ? WHERE id = ?',
    [msPlayed < 0 ? 0 : msPlayed, eventId],
  );

  /// Whole event in one call, for imports and tests.
  void recordPlayback(String songId, {int msPlayed = 0, DateTime? at}) =>
      _db.execute(
        'INSERT INTO playback_history(song_id, played_at, ms_played) '
        'VALUES (?,?,?)',
        [songId, (at ?? DateTime.now()).millisecondsSinceEpoch, msPlayed],
      );

  /// Distinct song ids, most recently played first.
  List<String> recentlyPlayedIds({int limit = 64}) => _db
      .select(
        'SELECT song_id, MAX(played_at) AS last FROM playback_history '
        'GROUP BY song_id ORDER BY last DESC LIMIT ?',
        [limit],
      )
      .map((r) => r['song_id'] as String)
      .toList();

  /// Play counts for the stats screen and Daily Mix weighting.
  Map<String, int> playCounts() => {
    for (final r in _db.select(
      'SELECT song_id, COUNT(*) AS c FROM playback_history GROUP BY song_id',
    ))
      r['song_id'] as String: r['c'] as int,
  };

  int totalListenedMs() =>
      (_db
              .select('SELECT COALESCE(SUM(ms_played), 0) AS s FROM playback_history')
              .first['s'] as int?) ??
      0;

  int totalPlays() =>
      _db.select('SELECT COUNT(*) AS c FROM playback_history').first['c'] as int;

  // ---------------------------------------------------------------- lyrics

  /// Cached lyrics for a song, or null when nothing has been stored yet.
  /// Replaces `LyricsDao` + `LyricsEntity`.
  ({String content, bool isSynced, String? source, int offsetMs})? lyricsFor(
    String songId,
  ) {
    final rows = _db.select('SELECT * FROM lyrics WHERE song_id = ?', [songId]);
    if (rows.isEmpty) return null;
    final row = rows.first;
    return (
      content: row['content'] as String,
      isSynced: (row['is_synced'] as int) != 0,
      source: row['source'] as String?,
      offsetMs: row['offset_ms'] as int,
    );
  }

  void saveLyrics(
    String songId, {
    required String content,
    required bool isSynced,
    String? source,
    int offsetMs = 0,
  }) => _db.execute(
    'INSERT OR REPLACE INTO lyrics(song_id, content, is_synced, source, '
    'offset_ms) VALUES (?,?,?,?,?)',
    [songId, content, isSynced ? 1 : 0, source, offsetMs],
  );

  void setLyricsOffset(String songId, int offsetMs) => _db.execute(
    'UPDATE lyrics SET offset_ms = ? WHERE song_id = ?',
    [offsetMs, songId],
  );

  void deleteLyrics(String songId) =>
      _db.execute('DELETE FROM lyrics WHERE song_id = ?', [songId]);

  /// Listening time per hour of the day (0-23), for the daily-rhythm chart.
  Map<int, int> listeningByHour({DateTime? since}) {
    final rows = _db.select(
      'SELECT played_at, ms_played FROM playback_history WHERE played_at >= ?',
      [since?.millisecondsSinceEpoch ?? 0],
    );
    final byHour = <int, int>{};
    for (final row in rows) {
      final at = DateTime.fromMillisecondsSinceEpoch(row['played_at'] as int);
      byHour[at.hour] = (byHour[at.hour] ?? 0) + (row['ms_played'] as int);
    }
    return byHour;
  }

  /// Listening time per calendar day, most recent [days] days, oldest first.
  ///
  /// Empty days are present with a zero, so a chart does not have to invent the
  /// gaps.
  List<(DateTime day, int ms)> listeningByDay({int days = 30}) {
    final today = DateTime.now();
    final start = DateTime(
      today.year,
      today.month,
      today.day,
    ).subtract(Duration(days: days - 1));
    final totals = <DateTime, int>{
      for (var i = 0; i < days; i++) start.add(Duration(days: i)): 0,
    };
    for (final row in _db.select(
      'SELECT played_at, ms_played FROM playback_history WHERE played_at >= ?',
      [start.millisecondsSinceEpoch],
    )) {
      final at = DateTime.fromMillisecondsSinceEpoch(row['played_at'] as int);
      final day = DateTime(at.year, at.month, at.day);
      if (!totals.containsKey(day)) continue;
      totals[day] = totals[day]! + (row['ms_played'] as int);
    }
    final ordered = totals.keys.toList()..sort();
    return [for (final day in ordered) (day, totals[day]!)];
  }

  /// Consecutive days up to today with any listening at all.
  int listeningStreakDays() {
    final days = <DateTime>{};
    for (final row in _db.select(
      'SELECT played_at FROM playback_history WHERE ms_played > 0',
    )) {
      final at = DateTime.fromMillisecondsSinceEpoch(row['played_at'] as int);
      days.add(DateTime(at.year, at.month, at.day));
    }
    if (days.isEmpty) return 0;
    final now = DateTime.now();
    var cursor = DateTime(now.year, now.month, now.day);
    // A streak may legitimately end yesterday, if today has no listening yet.
    if (!days.contains(cursor)) {
      cursor = cursor.subtract(const Duration(days: 1));
      if (!days.contains(cursor)) return 0;
    }
    var streak = 0;
    while (days.contains(cursor)) {
      streak++;
      cursor = cursor.subtract(const Duration(days: 1));
    }
    return streak;
  }

  /// Songs ranked by time listened rather than play count — a track skipped
  /// twenty times is not a favourite.
  List<(String songId, int ms, int plays)> topSongsByTime({
    int limit = 25,
    DateTime? since,
  }) => _db
      .select(
        'SELECT song_id, SUM(ms_played) AS ms, COUNT(*) AS plays '
        'FROM playback_history WHERE played_at >= ? '
        'GROUP BY song_id HAVING ms > 0 ORDER BY ms DESC LIMIT ?',
        [since?.millisecondsSinceEpoch ?? 0, limit],
      )
      .map((r) => (r['song_id'] as String, r['ms'] as int, r['plays'] as int))
      .toList();

  /// Time listened per artist, joined through the song's artists.
  List<(int artistId, String name, int ms)> topArtistsByTime({
    int limit = 25,
    DateTime? since,
  }) => _db
      .select(
        'SELECT ar.id, ar.name, SUM(h.ms_played) AS ms '
        'FROM playback_history h '
        'JOIN song_artists sa ON sa.song_id = h.song_id '
        'JOIN artists ar ON ar.id = sa.artist_id '
        'WHERE h.played_at >= ? '
        'GROUP BY ar.id HAVING ms > 0 ORDER BY ms DESC LIMIT ?',
        [since?.millisecondsSinceEpoch ?? 0, limit],
      )
      .map((r) => (r['id'] as int, r['name'] as String, r['ms'] as int))
      .toList();

  List<(int albumId, String title, int ms)> topAlbumsByTime({
    int limit = 25,
    DateTime? since,
  }) => _db
      .select(
        'SELECT al.id, al.title, SUM(h.ms_played) AS ms '
        'FROM playback_history h '
        'JOIN songs s ON s.id = h.song_id '
        'JOIN albums al ON al.id = s.album_id '
        'WHERE h.played_at >= ? '
        'GROUP BY al.id HAVING ms > 0 ORDER BY ms DESC LIMIT ?',
        [since?.millisecondsSinceEpoch ?? 0, limit],
      )
      .map((r) => (r['id'] as int, r['title'] as String, r['ms'] as int))
      .toList();

  int totalListenedMsSince(DateTime since) =>
      (_db
              .select(
                'SELECT COALESCE(SUM(ms_played), 0) AS s '
                'FROM playback_history WHERE played_at >= ?',
                [since.millisecondsSinceEpoch],
              )
              .first['s']
          as int?) ??
      0;

  /// When each song was last played, for the smart playlists.
  Map<String, int> lastPlayedAt() => {
    for (final r in _db.select(
      'SELECT song_id, MAX(played_at) AS last FROM playback_history '
      'GROUP BY song_id',
    ))
      r['song_id'] as String: r['last'] as int,
  };

  // -------------------------------------------------------- search history

  // ---------------------------------------------------------------- backup
  //
  // Narrow readers and writers for the backup file, rather than exposing the
  // connection: a backup needs whole tables, which nothing else in the app does.

  /// Every stored lyric, keyed by song id.
  List<({String songId, String content, bool isSynced, String? source, int offsetMs})>
  allLyrics() => [
    for (final row in _db.select('SELECT * FROM lyrics'))
      (
        songId: row['song_id'] as String,
        content: row['content'] as String,
        isSynced: (row['is_synced'] as int) != 0,
        source: row['source'] as String?,
        offsetMs: row['offset_ms'] as int,
      ),
  ];

  /// Listening history, newest first.
  ///
  /// Capped because this table grows without limit and a backup is meant to be
  /// mailable; the oldest rows are the least interesting.
  List<({String songId, int playedAt, int msPlayed})> allPlaybackHistory({
    int limit = 20000,
  }) => [
    for (final row in _db.select(
      'SELECT song_id, played_at, ms_played FROM playback_history '
      'ORDER BY played_at DESC LIMIT ?',
      [limit],
    ))
      (
        songId: row['song_id'] as String,
        playedAt: row['played_at'] as int,
        msPlayed: row['ms_played'] as int,
      ),
  ];

  /// Writes one history row at its original time, which [recordPlayback] cannot
  /// do because it stamps now.
  void insertPlayback({
    required String songId,
    required int playedAt,
    required int msPlayed,
  }) => _db.execute(
    'INSERT INTO playback_history(song_id, played_at, ms_played) VALUES (?,?,?)',
    [songId, playedAt, msPlayed],
  );

  /// True when this song already has history at this instant, so restoring the
  /// same backup twice does not double every play count.
  bool hasPlaybackAt(String songId, int playedAt) => _db
      .select(
        'SELECT 1 FROM playback_history WHERE song_id = ? AND played_at = ? '
        'LIMIT 1',
        [songId, playedAt],
      )
      .isNotEmpty;

  /// The remote identity found for each artist, by name.
  ///
  /// Names rather than ids, and no local file paths: the ids are per-database and
  /// the cached image lives in this machine's cache directory.
  List<({String artist, int? remoteId, String? remoteName})>
  allArtistImageIdentities() => [
    for (final row in _db.select('''
      SELECT a.name AS name, i.remote_id AS remote_id, i.remote_name AS remote_name
      FROM artist_images i
      JOIN artists a ON a.id = i.artist_id
      WHERE i.remote_id IS NOT NULL OR i.remote_name IS NOT NULL
    '''))
      (
        artist: row['name'] as String,
        remoteId: row['remote_id'] as int?,
        remoteName: row['remote_name'] as String?,
      ),
  ];

  /// Remembers a remote identity for an artist without claiming to have the
  /// picture: the fetcher can then skip the search when it next runs.
  void rememberArtistIdentity(
    int artistId, {
    int? remoteId,
    String? remoteName,
  }) => _db.execute(
    '''
    INSERT INTO artist_images (artist_id, remote_id, remote_name, status)
    VALUES (?,?,?,'unknown')
    ON CONFLICT(artist_id) DO UPDATE SET
      remote_id = COALESCE(excluded.remote_id, artist_images.remote_id),
      remote_name = COALESCE(excluded.remote_name, artist_images.remote_name)
    ''',
    [artistId, remoteId, remoteName],
  );

  void recordSearch(String query) {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return;
    _db.execute(
      'INSERT OR REPLACE INTO search_history(query, searched_at) VALUES (?,?)',
      [trimmed, DateTime.now().millisecondsSinceEpoch],
    );
  }

  List<String> searchHistory({int limit = 12}) => _db
      .select(
        'SELECT query FROM search_history ORDER BY searched_at DESC LIMIT ?',
        [limit],
      )
      .map((r) => r['query'] as String)
      .toList();

  void clearSearchHistory() => _db.execute('DELETE FROM search_history');
}
