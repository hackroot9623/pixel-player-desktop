import 'dart:convert';

import '../models/models.dart';

// The backup file, and the rules for reading one.
//
// Ported from the Android app's module-based backup: a manifest, one payload per
// section, and a restore that takes the sections the user picked rather than all
// or nothing. Same section keys, so a file from either app is at least legible to
// the other.
//
// The desktop problem Android does not have: a backup is often restored on a
// different machine, where the music lives at a different path. So every song
// reference carries its tags as well as its path, and matching falls back to the
// tags when the path is not there.
//
// Nothing secret goes in. Passwords, API keys and OAuth tokens are left out by
// construction — a backup is a file people email to themselves.

/// What the file says it is, so a JSON file of something else is refused.
const backupFormat = 'pixelplayer-desktop-backup';

/// The format version. Readers accept anything up to this.
const backupVersion = 1;

/// One restorable section.
enum BackupSection {
  playlists('playlists', 'Playlists', 'Your playlists and their order.'),
  favorites('favorites', 'Favourites', 'Songs you marked as favourite.'),
  lyrics('lyrics', 'Lyrics', 'Lyrics you saved or imported, and their offsets.'),
  history(
    'playback_history',
    'Listening history',
    'What you played and when — the basis for play counts and stats.',
  ),
  searchHistory('search_history', 'Search history', 'Recent search terms.'),
  artistImages(
    'artist_images',
    'Artist images',
    'Cached artist pictures, and any you chose yourself.',
  ),
  folders('music_folders', 'Music folders', 'Which folders are scanned.'),
  settings(
    'global_settings',
    'Settings',
    'Themes, playback and app preferences. Never passwords or keys.',
  ),
  equalizer('equalizer', 'Equalizer', 'Your bands and effects.'),
  accounts(
    'remote_accounts',
    'Remote accounts',
    'Servers and usernames, without their passwords — you will be asked for '
        'those again.',
  );

  const BackupSection(this.key, this.label, this.description);

  final String key;
  final String label;
  final String description;

  static BackupSection? fromKey(String key) {
    for (final section in values) {
      if (section.key == key) return section;
    }
    return null;
  }
}

/// A song, identified in a way that survives moving to another machine.
class SongRef {
  const SongRef({
    required this.path,
    required this.title,
    required this.artist,
    required this.album,
  });

  final String path;
  final String title;
  final String artist;
  final String album;

  Map<String, Object?> toJson() => {
    'path': path,
    'title': title,
    'artist': artist,
    'album': album,
  };

  static SongRef? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final path = raw['path'];
    if (path is! String) return null;
    return SongRef(
      path: path,
      title: '${raw['title'] ?? ''}',
      artist: '${raw['artist'] ?? ''}',
      album: '${raw['album'] ?? ''}',
    );
  }

  static SongRef of(Song song) => SongRef(
    path: song.path,
    title: song.title,
    artist: song.displayArtist,
    album: song.album,
  );

  /// The key used when matching by tags rather than by path.
  String get tagKey => tagKeyFor(title: title, artist: artist, album: album);
}

/// A loose key for the same recording across two libraries.
///
/// Lower-cased and stripped of everything but letters and digits: the same file
/// ripped twice differs by punctuation and spacing far more often than by words.
String tagKeyFor({
  required String title,
  required String artist,
  required String album,
}) {
  String clean(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  return '${clean(title)}|${clean(artist)}|${clean(album)}';
}

/// Resolves the songs in a backup against the songs in this library.
///
/// Path first, because it is exact. Tags second, for a library that moved. A
/// reference that matches neither is reported rather than dropped silently, so
/// the restore can say how much of a playlist survived.
class SongMatcher {
  SongMatcher(Iterable<Song> library) {
    for (final song in library) {
      _byPath[song.path] = song;
      // First writer wins: with duplicates in the library, the earlier one is as
      // good a choice as any and at least it is stable.
      _byTags.putIfAbsent(
        tagKeyFor(
          title: song.title,
          artist: song.displayArtist,
          album: song.album,
        ),
        () => song,
      );
    }
  }

  final _byPath = <String, Song>{};
  final _byTags = <String, Song>{};

  Song? match(SongRef ref) {
    final byPath = _byPath[ref.path];
    if (byPath != null) return byPath;
    // Only worth trying when there is something to match on.
    if (ref.title.isEmpty) return null;
    return _byTags[ref.tagKey];
  }
}

/// A backup file, read or about to be written.
class BackupFile {
  const BackupFile({
    required this.createdAt,
    required this.appVersion,
    required this.platform,
    required this.modules,
    this.version = backupVersion,
  });

  final DateTime createdAt;
  final String appVersion;
  final String platform;

  /// Section key → payload. Unknown keys are kept on read so a file from a newer
  /// version survives a round trip through an older one.
  final Map<String, Object?> modules;

  final int version;

  /// Which known sections this file actually carries.
  List<BackupSection> get sections => [
    for (final section in BackupSection.values)
      if (modules.containsKey(section.key)) section,
  ];

  Map<String, Object?> toJson() => {
    'format': backupFormat,
    'version': version,
    'createdAt': createdAt.toIso8601String(),
    'app': {'version': appVersion, 'platform': platform},
    'modules': modules,
  };

  String encode() =>
      const JsonEncoder.withIndent('  ').convert(toJson());

  /// Reads a file, or throws [BackupException] with something worth reading.
  static BackupFile decode(String text) {
    final Object? raw;
    try {
      raw = jsonDecode(text);
    } on FormatException {
      throw const BackupException('That file is not a PixelPlayer backup.');
    }
    if (raw is! Map) {
      throw const BackupException('That file is not a PixelPlayer backup.');
    }
    if (raw['format'] != backupFormat) {
      throw const BackupException(
        'That file is not a PixelPlayer backup — it may be a backup from the '
        'Android app, which uses a different format.',
      );
    }

    final version = raw['version'];
    if (version is! int || version < 1) {
      throw const BackupException('That backup does not say which version it '
          'is, so it cannot be read safely.');
    }
    if (version > backupVersion) {
      throw BackupException(
        'That backup was written by a newer version of PixelPlayer (format '
        '$version, this build reads up to $backupVersion). Update first.',
      );
    }

    final modules = raw['modules'];
    if (modules is! Map) {
      throw const BackupException('That backup has no contents.');
    }

    final app = raw['app'];
    return BackupFile(
      version: version,
      createdAt:
          DateTime.tryParse('${raw['createdAt'] ?? ''}') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      appVersion: '${(app is Map ? app['version'] : null) ?? 'unknown'}',
      platform: '${(app is Map ? app['platform'] : null) ?? 'unknown'}',
      modules: {
        for (final entry in modules.entries) '${entry.key}': entry.value,
      },
    );
  }

  /// The payload for one section, or null when the file does not carry it.
  List<Object?>? listFor(BackupSection section) {
    final payload = modules[section.key];
    return payload is List ? payload : null;
  }

  Map<String, Object?>? mapFor(BackupSection section) {
    final payload = modules[section.key];
    return payload is Map
        ? {for (final entry in payload.entries) '${entry.key}': entry.value}
        : null;
  }
}

/// Preference keys never written to a backup.
///
/// A backup is a file people email to themselves, so every secret is left out by
/// construction rather than by remembering to filter it at each call site.
bool isSecretPreference(String key) {
  const secrets = {
    'spotify_refresh_token',
    'telegram_api_hash',
  };
  if (secrets.contains(key)) return true;
  return key.contains('api_key') ||
      key.contains('apikey') ||
      key.contains('password') ||
      key.contains('token') ||
      key.contains('secret') ||
      key.contains('client_id') ||
      // Remote accounts are their own section, and that one strips passwords.
      key == 'remote_accounts';
}

/// What a restore did, so the UI can report it honestly.
class RestoreReport {
  RestoreReport();

  final restored = <BackupSection, int>{};
  final skipped = <BackupSection, int>{};
  final failures = <String>[];

  void add(BackupSection section, {int restored = 0, int skipped = 0}) {
    this.restored[section] = (this.restored[section] ?? 0) + restored;
    if (skipped > 0) {
      this.skipped[section] = (this.skipped[section] ?? 0) + skipped;
    }
  }

  int get totalRestored =>
      restored.values.fold(0, (sum, count) => sum + count);

  int get totalSkipped => skipped.values.fold(0, (sum, count) => sum + count);

  bool get anythingRestored => totalRestored > 0;
}

class BackupException implements Exception {
  const BackupException(this.message);

  final String message;

  @override
  String toString() => message;
}
