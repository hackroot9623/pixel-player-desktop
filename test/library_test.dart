import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pixelplay_desktop/data/db/database.dart';
import 'package:pixelplay_desktop/data/models/models.dart';
import 'package:pixelplay_desktop/data/models/sort_option.dart';
import 'package:pixelplay_desktop/data/scanner/library_scanner.dart';

/// One end-to-end check over the pieces that would silently rot: tag reading,
/// multi-artist splitting, the SQLite schema, and the sort comparators.
///
/// Point it at a folder of audio files with `MUSIC_DIR=/path/to/music`; without
/// that the scanner-backed cases are skipped and the pure logic still runs.
void main() {
  test('splitArtists honours the configured delimiters', () {
    expect(
      splitArtists('Alpha feat. Beta', defaultArtistDelimiters),
      ['Alpha', 'Beta'],
    );
    expect(splitArtists('Alpha & Beta', defaultArtistDelimiters), [
      'Alpha',
      'Beta',
    ]);
    expect(splitArtists('AC/DC', const [';']), ['AC/DC']);
    // Duplicates collapse, case-insensitively.
    expect(splitArtists('Alpha; alpha', defaultArtistDelimiters), ['Alpha']);
  });

  test('stableId is deterministic and fits SQLite integers', () {
    final id = stableId('Album One Alpha');
    expect(id, stableId('album one alpha'));
    expect(id, greaterThan(0));
    expect(id, lessThan(0x4000000000000000));
  });

  test('sort comparators order by the requested key', () {
    Song song(String title, String artist, int duration) => Song(
      id: title,
      title: title,
      artist: artist,
      artistId: stableId(artist),
      album: 'A',
      albumId: 1,
      path: '/tmp/$title',
      duration: duration,
    );
    final songs = [
      song('Beta', 'Zoe', 300),
      song('alpha', 'Adam', 100),
      song('Gamma', 'Mia', 200),
    ];
    expect(
      sortSongs(songs, SortOption.songTitleAZ).map((s) => s.title),
      ['alpha', 'Beta', 'Gamma'],
    );
    expect(
      sortSongs(songs, SortOption.songTitleZA).map((s) => s.title),
      ['Gamma', 'Beta', 'alpha'],
    );
    expect(
      sortSongs(songs, SortOption.songDuration).first.title,
      'Beta',
    );
    expect(
      sortSongs(songs, SortOption.songDurationAsc).first.title,
      'alpha',
    );
    expect(
      sortSongs(songs, SortOption.songArtist).map((s) => s.artist),
      ['Adam', 'Mia', 'Zoe'],
    );
  });

  test('scan then query round-trips through SQLite', () async {
    final musicDir = Platform.environment['MUSIC_DIR'];
    if (musicDir == null || !Directory(musicDir).existsSync()) {
      markTestSkipped('set MUSIC_DIR to a folder of audio files');
      return;
    }
    final tmp = await Directory.systemTemp.createTemp('pixelplay_test');
    addTearDown(() => tmp.delete(recursive: true));

    final files = collectAudioFiles([musicDir]);
    expect(files, isNotEmpty, reason: 'no supported audio files in $musicDir');

    final db = await MusicDatabase.open(tmp.path);
    addTearDown(db.close);
    db.addFolder(musicDir);

    final songs = <Song>[];
    final done = Completer<void>();
    scanLibrary(
      ScanRequest(
        roots: [musicDir],
        artworkDir: p.join(tmp.path, 'artwork'),
        artistDelimiters: defaultArtistDelimiters,
        multiArtistEnabled: true,
      ),
      onDone: (result) {
        songs.addAll(result);
        done.complete();
      },
    ).listen(null);
    await done.future;

    expect(songs.length, files.length);
    db.replaceLibrary(songs);

    expect(db.songCount(), songs.length);
    expect(db.allSongs().length, songs.length);
    expect(db.allAlbums(), isNotEmpty);
    expect(db.allArtists(), isNotEmpty);
    // Every album row must be reachable from its songs.
    for (final album in db.allAlbums()) {
      expect(db.songsForAlbum(album.id), isNotEmpty);
      expect(album.songCount, db.songsForAlbum(album.id).length);
    }
    for (final artist in db.allArtists()) {
      expect(db.songsForArtist(artist.id), isNotEmpty);
    }

    // Favourites, playlists and history all key off song ids.
    final first = db.allSongs().first;
    db.setFavorite(first.id, true);
    expect(db.isFavorite(first.id), isTrue);
    expect(db.favoriteSongs().single.id, first.id);

    final playlist = Playlist(
      id: 'pl_test',
      name: 'Test',
      songIds: [for (final s in db.allSongs()) s.id],
      createdAt: 1,
      lastModified: 1,
    );
    db.upsertPlaylist(playlist);
    expect(db.playlist('pl_test')!.songIds, playlist.songIds);
    // songsByIds must preserve the caller's order, playlists depend on it.
    final reversed = playlist.songIds.reversed.toList();
    expect([for (final s in db.songsByIds(reversed)) s.id], reversed);

    db.recordPlayback(first.id, msPlayed: 1234);
    expect(db.recentlyPlayedIds(), [first.id]);
    expect(db.playCounts()[first.id], 1);
    expect(db.totalListenedMs(), 1234);

    expect(db.search(first.title), isNotEmpty);
    expect(db.foldersIn(null), isNotEmpty);
  });
}
