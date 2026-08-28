import 'dart:io';

import '../db/database.dart';
import '../models/models.dart';
import '../../player/equalizer.dart';
import '../prefs/settings.dart';
import '../remote/remote_account.dart';
import 'backup_format.dart';

// Building a backup, and applying one.
//
// The rules, so they are in one place rather than implied by ten call sites:
//
//  * Restore adds; it does not replace. A playlist that already exists gets the
//    backup's songs merged into it rather than being overwritten, because the
//    common case is restoring onto a library that has since moved on.
//  * Songs are matched by path first, then by tags. A reference that matches
//    neither is counted as skipped and reported, never silently dropped.
//  * Nothing secret is written. Remote accounts travel without their passwords,
//    so a restore recreates the server and asks for the password again.

class BackupService {
  BackupService(this._db, this._settings);

  final MusicDatabase _db;
  final Settings _settings;

  /// Builds a backup of [sections].
  BackupFile build({
    required Set<BackupSection> sections,
    required String appVersion,
  }) {
    final songsById = {for (final song in _db.allSongs()) song.id: song};
    SongRef? refFor(String songId) {
      final song = songsById[songId];
      return song == null ? null : SongRef.of(song);
    }

    final modules = <String, Object?>{};

    if (sections.contains(BackupSection.playlists)) {
      modules[BackupSection.playlists.key] = [
        for (final playlist in _db.allPlaylists())
          {
            'name': playlist.name,
            'createdAt': playlist.createdAt,
            'lastModified': playlist.lastModified,
            'isAiGenerated': playlist.isAiGenerated,
            'coverColorArgb': playlist.coverColorArgb,
            'coverIconName': playlist.coverIconName,
            'coverShapeType': playlist.coverShapeType,
            'songs': [
              for (final songId in playlist.songIds)
                if (refFor(songId) case final ref?) ref.toJson(),
            ],
          },
      ];
    }

    if (sections.contains(BackupSection.favorites)) {
      modules[BackupSection.favorites.key] = [
        for (final song in _db.favoriteSongs()) SongRef.of(song).toJson(),
      ];
    }

    if (sections.contains(BackupSection.lyrics)) {
      modules[BackupSection.lyrics.key] = [
        for (final entry in _db.allLyrics())
          if (refFor(entry.songId) case final ref?)
            {
              'song': ref.toJson(),
              'content': entry.content,
              'isSynced': entry.isSynced,
              'source': entry.source,
              'offsetMs': entry.offsetMs,
            },
      ];
    }

    if (sections.contains(BackupSection.history)) {
      modules[BackupSection.history.key] = [
        for (final entry in _db.allPlaybackHistory())
          if (refFor(entry.songId) case final ref?)
            {
              'song': ref.toJson(),
              'playedAt': entry.playedAt,
              'msPlayed': entry.msPlayed,
            },
      ];
    }

    if (sections.contains(BackupSection.searchHistory)) {
      modules[BackupSection.searchHistory.key] = _db.searchHistory();
    }

    if (sections.contains(BackupSection.artistImages)) {
      modules[BackupSection.artistImages.key] = [
        for (final entry in _db.allArtistImageIdentities())
          {
            'artist': entry.artist,
            'remoteId': entry.remoteId,
            'remoteName': entry.remoteName,
          },
      ];
    }

    if (sections.contains(BackupSection.folders)) {
      modules[BackupSection.folders.key] = _db.allFolders();
    }

    if (sections.contains(BackupSection.settings)) {
      modules[BackupSection.settings.key] = _settings.exportPreferences();
    }

    if (sections.contains(BackupSection.equalizer)) {
      modules[BackupSection.equalizer.key] = _settings.equalizer.toJson();
    }

    if (sections.contains(BackupSection.accounts)) {
      modules[BackupSection.accounts.key] = [
        for (final account in _settings.remoteAccounts)
          _accountWithoutSecrets(account),
      ];
    }

    return BackupFile(
      createdAt: DateTime.now(),
      appVersion: appVersion,
      platform: Platform.operatingSystem,
      modules: modules,
    );
  }

  /// An account with every secret removed.
  ///
  /// Kept as a named function because it is the one place a mistake would put a
  /// password in a file the user emails to themselves.
  static Map<String, Object?> _accountWithoutSecrets(RemoteAccount account) => {
    'kind': account.kind.storageKey,
    'serverUrl': account.serverUrl,
    'username': account.username,
    'displayName': account.displayName,
    'extra': {
      for (final entry in account.extra.entries)
        if (!isSecretPreference(entry.key) &&
            entry.key != 'access_token' &&
            entry.key != 'refresh_token' &&
            entry.key != 'session')
          entry.key: entry.value,
    },
  };

  /// Applies [sections] from [file].
  Future<RestoreReport> apply(
    BackupFile file, {
    required Set<BackupSection> sections,
  }) async {
    final report = RestoreReport();
    final matcher = SongMatcher(_db.allSongs());

    for (final section in sections) {
      if (!file.modules.containsKey(section.key)) continue;
      try {
        await _applySection(section, file, matcher, report);
      } catch (error) {
        // One bad section must not take the rest of the restore with it.
        report.failures.add('${section.label}: $error');
      }
    }
    return report;
  }

  Future<void> _applySection(
    BackupSection section,
    BackupFile file,
    SongMatcher matcher,
    RestoreReport report,
  ) async {
    switch (section) {
      case BackupSection.playlists:
        _restorePlaylists(file, matcher, report);
      case BackupSection.favorites:
        _restoreFavorites(file, matcher, report);
      case BackupSection.lyrics:
        _restoreLyrics(file, matcher, report);
      case BackupSection.history:
        _restoreHistory(file, matcher, report);
      case BackupSection.searchHistory:
        for (final query in file.listFor(section) ?? const []) {
          if (query is! String || query.trim().isEmpty) continue;
          _db.recordSearch(query);
          report.add(section, restored: 1);
        }
      case BackupSection.artistImages:
        _restoreArtistImages(file, report);
      case BackupSection.folders:
        for (final path in file.listFor(section) ?? const []) {
          if (path is! String) continue;
          // A folder that is not on this machine would show as an empty root and
          // confuse the next scan.
          if (!Directory(path).existsSync()) {
            report.add(section, skipped: 1);
            continue;
          }
          _db.addFolder(path);
          if (!_settings.musicFolders.contains(path)) {
            _settings.musicFolders = [..._settings.musicFolders, path];
          }
          report.add(section, restored: 1);
        }
      case BackupSection.settings:
        final values = file.mapFor(section);
        if (values == null) return;
        report.add(
          section,
          restored: await _settings.importPreferences(values),
        );
      case BackupSection.equalizer:
        final values = file.mapFor(section);
        if (values == null) return;
        _settings.equalizer = EqualizerState.fromJson(values);
        report.add(section, restored: 1);
      case BackupSection.accounts:
        _restoreAccounts(file, report);
    }
  }

  void _restorePlaylists(
    BackupFile file,
    SongMatcher matcher,
    RestoreReport report,
  ) {
    final existing = {
      for (final playlist in _db.allPlaylists())
        playlist.name.toLowerCase(): playlist,
    };

    for (final raw in file.listFor(BackupSection.playlists) ?? const []) {
      if (raw is! Map) continue;
      final name = '${raw['name'] ?? ''}'.trim();
      if (name.isEmpty) continue;

      final songIds = <String>[];
      var skipped = 0;
      for (final entry in (raw['songs'] as List? ?? const [])) {
        final ref = SongRef.fromJson(entry);
        if (ref == null) continue;
        final song = matcher.match(ref);
        if (song == null) {
          skipped++;
          continue;
        }
        songIds.add(song.id);
      }

      final previous = existing[name.toLowerCase()];
      // Merged rather than replaced: the library has usually moved on since the
      // backup, and losing songs to a restore is worse than a longer playlist.
      final List<String> merged = previous == null
          ? songIds
          : [
              ...previous.songIds,
              ...songIds.where((id) => !previous.songIds.contains(id)),
            ];

      final now = DateTime.now().millisecondsSinceEpoch;
      _db.upsertPlaylist(
        Playlist(
          // Keep the existing playlist's id when merging into it; a new one
          // gets an id of its own rather than the backup's, which belonged to
          // another database.
          id: previous?.id ??
              'restored-${DateTime.now().microsecondsSinceEpoch}-'
                  '${name.hashCode.abs()}',
          name: previous?.name ?? name,
          songIds: merged,
          createdAt: (raw['createdAt'] as num?)?.toInt() ??
              previous?.createdAt ??
              now,
          lastModified: now,
          isAiGenerated: raw['isAiGenerated'] == true,
          coverColorArgb: (raw['coverColorArgb'] as num?)?.toInt(),
          coverIconName: raw['coverIconName'] as String?,
          coverShapeType: raw['coverShapeType'] as String?,
        ),
      );
      report.add(
        BackupSection.playlists,
        restored: 1,
        skipped: skipped > 0 ? skipped : 0,
      );
    }
  }

  void _restoreFavorites(
    BackupFile file,
    SongMatcher matcher,
    RestoreReport report,
  ) {
    for (final entry in file.listFor(BackupSection.favorites) ?? const []) {
      final ref = SongRef.fromJson(entry);
      final song = ref == null ? null : matcher.match(ref);
      if (song == null) {
        report.add(BackupSection.favorites, skipped: 1);
        continue;
      }
      _db.setFavorite(song.id, true);
      report.add(BackupSection.favorites, restored: 1);
    }
  }

  void _restoreLyrics(
    BackupFile file,
    SongMatcher matcher,
    RestoreReport report,
  ) {
    for (final entry in file.listFor(BackupSection.lyrics) ?? const []) {
      if (entry is! Map) continue;
      final ref = SongRef.fromJson(entry['song']);
      final song = ref == null ? null : matcher.match(ref);
      final content = entry['content'];
      if (song == null || content is! String || content.isEmpty) {
        report.add(BackupSection.lyrics, skipped: 1);
        continue;
      }
      _db.saveLyrics(
        song.id,
        content: content,
        isSynced: entry['isSynced'] == true,
        source: entry['source'] as String?,
        offsetMs: (entry['offsetMs'] as num?)?.toInt() ?? 0,
      );
      report.add(BackupSection.lyrics, restored: 1);
    }
  }

  void _restoreHistory(
    BackupFile file,
    SongMatcher matcher,
    RestoreReport report,
  ) {
    for (final entry in file.listFor(BackupSection.history) ?? const []) {
      if (entry is! Map) continue;
      final ref = SongRef.fromJson(entry['song']);
      final song = ref == null ? null : matcher.match(ref);
      final playedAt = (entry['playedAt'] as num?)?.toInt();
      if (song == null || playedAt == null) {
        report.add(BackupSection.history, skipped: 1);
        continue;
      }
      // Restoring the same file twice must not double every play count.
      if (_db.hasPlaybackAt(song.id, playedAt)) {
        report.add(BackupSection.history, skipped: 1);
        continue;
      }
      _db.insertPlayback(
        songId: song.id,
        playedAt: playedAt,
        msPlayed: (entry['msPlayed'] as num?)?.toInt() ?? 0,
      );
      report.add(BackupSection.history, restored: 1);
    }
  }

  void _restoreArtistImages(BackupFile file, RestoreReport report) {
    final byName = {
      for (final artist in _db.allArtists()) artist.name.toLowerCase(): artist,
    };

    for (final entry in file.listFor(BackupSection.artistImages) ?? const []) {
      if (entry is! Map) continue;
      final artist = byName['${entry['artist'] ?? ''}'.toLowerCase()];
      if (artist == null) {
        report.add(BackupSection.artistImages, skipped: 1);
        continue;
      }
      // Only the remote identity travels: the picture itself is a file in this
      // machine's cache, so what this saves is the lookup, not the download.
      _db.rememberArtistIdentity(
        artist.id,
        remoteId: (entry['remoteId'] as num?)?.toInt(),
        remoteName: entry['remoteName'] as String?,
      );
      report.add(BackupSection.artistImages, restored: 1);
    }
  }

  void _restoreAccounts(BackupFile file, RestoreReport report) {
    final existing = _settings.remoteAccounts;

    for (final entry in file.listFor(BackupSection.accounts) ?? const []) {
      if (entry is! Map) continue;
      final kind = RemoteKind.fromStorageKey(entry['kind'] as String?);
      if (kind == null) {
        report.add(BackupSection.accounts, skipped: 1);
        continue;
      }
      final serverUrl = '${entry['serverUrl'] ?? ''}';
      final username = '${entry['username'] ?? ''}';

      // Same server and user means it is already here; adding a second copy
      // would leave the user with two rows to sign into.
      final already = existing.any(
        (account) =>
            account.kind == kind &&
            account.serverUrl == serverUrl &&
            account.username == username,
      );
      if (already) {
        report.add(BackupSection.accounts, skipped: 1);
        continue;
      }

      _settings.upsertRemoteAccount(
        RemoteAccount(
          id: '${kind.storageKey}-${DateTime.now().microsecondsSinceEpoch}',
          kind: kind,
          serverUrl: serverUrl,
          username: username,
          // Deliberately empty: the backup never carried it.
          password: '',
          displayName: entry['displayName'] as String?,
          extra: {
            for (final e in (entry['extra'] as Map? ?? const {}).entries)
              '${e.key}': '${e.value}',
          },
        ),
      );
      report.add(BackupSection.accounts, restored: 1);
    }
  }
}
