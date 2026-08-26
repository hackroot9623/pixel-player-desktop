import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pixelplay_desktop/data/db/database.dart';
import 'package:pixelplay_desktop/data/models/models.dart';
import 'package:pixelplay_desktop/data/smart/smart_playlists.dart';

Song song(
  String id, {
  bool favorite = false,
  int addedDaysAgo = 500,
  String artist = 'Artist',
  int artistId = 1,
  int albumId = 1,
  String? genre,
}) {
  final added = DateTime.now().subtract(Duration(days: addedDaysAgo));
  return Song(
    id: id,
    title: id,
    artist: artist,
    artistId: artistId,
    artists: [ArtistRef(id: artistId, name: artist, isPrimary: true)],
    album: 'Album $albumId',
    albumId: albumId,
    path: '/music/$id.mp3',
    duration: 200000,
    isFavorite: favorite,
    dateAdded: added.millisecondsSinceEpoch,
    genre: genre,
  );
}

int daysAgo(int days) =>
    DateTime.now().subtract(Duration(days: days)).millisecondsSinceEpoch;

void main() {
  group('smart playlist rules', () {
    test('Top Played ranks by time listened, not play count', () {
      final songs = [song('a'), song('b'), song('c')];
      // 'b' was started far more often but barely heard: skipping is not
      // listening, so it must not outrank 'a'.
      final stats = ListeningStats(
        msListened: {'a': 600000, 'b': 5000, 'c': 120000},
        playCounts: {'a': 3, 'b': 40, 'c': 2},
      );
      final result = evaluateSmartPlaylist(
        SmartPlaylistRule.topPlayed,
        songs,
        stats,
      );
      expect(result.map((s) => s.id), ['a', 'c', 'b']);
    });

    test('Top Played excludes anything never listened to', () {
      final result = evaluateSmartPlaylist(
        SmartPlaylistRule.topPlayed,
        [song('a'), song('b')],
        const ListeningStats(msListened: {'a': 1000}),
      );
      expect(result.map((s) => s.id), ['a']);
    });

    test('Recently Played is ordered by last play', () {
      final result = evaluateSmartPlaylist(
        SmartPlaylistRule.recentlyPlayed,
        [song('a'), song('b'), song('c')],
        ListeningStats(
          lastPlayedAt: {'a': daysAgo(5), 'b': daysAgo(1), 'c': daysAgo(30)},
        ),
      );
      expect(result.map((s) => s.id), ['b', 'a', 'c']);
    });

    test('Forgotten Favourites needs a like, a play, and a long gap', () {
      final songs = [
        song('liked-old', favorite: true), // qualifies
        song('liked-recent', favorite: true), // played last week
        song('liked-never', favorite: true), // never played
        song('unliked-old'), // old but not liked
      ];
      final stats = ListeningStats(
        lastPlayedAt: {
          'liked-old': daysAgo(90),
          'liked-recent': daysAgo(7),
          'unliked-old': daysAgo(120),
        },
      );
      final result = evaluateSmartPlaylist(
        SmartPlaylistRule.forgottenFavorites,
        songs,
        stats,
      );
      expect(
        result.map((s) => s.id),
        ['liked-old'],
        reason: 'a like never played was never remembered, so not forgotten',
      );
    });

    test('Forgotten Favourites puts the longest-neglected first', () {
      final songs = [
        song('older', favorite: true),
        song('newer', favorite: true),
      ];
      final result = evaluateSmartPlaylist(
        SmartPlaylistRule.forgottenFavorites,
        songs,
        ListeningStats(
          lastPlayedAt: {'older': daysAgo(200), 'newer': daysAgo(40)},
        ),
      );
      expect(result.map((s) => s.id), ['older', 'newer']);
    });

    test('New Gems is recently added and barely played', () {
      final songs = [
        song('new-unplayed', addedDaysAgo: 3),
        song('new-played-twice', addedDaysAgo: 5),
        song('new-played-lots', addedDaysAgo: 5),
        song('old-unplayed', addedDaysAgo: 400),
      ];
      final result = evaluateSmartPlaylist(
        SmartPlaylistRule.newGems,
        songs,
        const ListeningStats(
          playCounts: {'new-played-twice': 2, 'new-played-lots': 9},
        ),
      );
      expect(result.map((s) => s.id), ['new-unplayed', 'new-played-twice']);
    });

    test('rules cope with an empty library and no history', () {
      for (final rule in SmartPlaylistRule.values) {
        expect(
          evaluateSmartPlaylist(rule, const [], const ListeningStats()),
          isEmpty,
          reason: rule.title,
        );
        expect(
          evaluateSmartPlaylist(rule, [song('a')], const ListeningStats()),
          isA<List<Song>>(),
          reason: '${rule.title} must not throw without history',
        );
      }
    });

    test('storage keys round-trip', () {
      for (final rule in SmartPlaylistRule.values) {
        expect(SmartPlaylistRule.fromStorageKey(rule.storageKey), rule);
      }
      expect(SmartPlaylistRule.fromStorageKey(null), isNull);
      expect(SmartPlaylistRule.fromStorageKey('nonsense'), isNull);
    });
  });

  group('daily mix', () {
    final library = [for (var i = 0; i < 60; i++) song('s$i')];
    final stats = ListeningStats(
      msListened: {for (var i = 0; i < 10; i++) 's$i': (10 - i) * 60000},
    );

    test('is stable for a day and different the next', () {
      final day = DateTime(2026, 8, 26);
      final first = buildDailyMix(library, stats, day: day);
      final again = buildDailyMix(library, stats, day: day);
      expect(
        first.map((s) => s.id),
        again.map((s) => s.id),
        reason: 'the same day must give the same mix, not reshuffle per build',
      );

      final tomorrow = buildDailyMix(
        library,
        stats,
        day: day.add(const Duration(days: 1)),
      );
      expect(
        tomorrow.map((s) => s.id),
        isNot(first.map((s) => s.id)),
        reason: 'and a new day must give a new one',
      );
    });

    test('mixes the familiar with the unheard, without duplicates', () {
      final mix = buildDailyMix(library, stats, size: 25);
      expect(mix.length, 25);
      expect(mix.map((s) => s.id).toSet().length, 25, reason: 'no duplicates');
      final familiar = mix.where((s) => stats.msListened.containsKey(s.id));
      expect(familiar, isNotEmpty, reason: 'some of what you listen to');
      expect(
        familiar.length,
        lessThan(mix.length),
        reason: 'and some you have not heard',
      );
    });

    test('fills up from one bucket when the other is short', () {
      // Everything has been listened to: there is no "new" bucket to draw on.
      final allFamiliar = ListeningStats(
        msListened: {for (final s in library) s.id: 1000},
      );
      expect(buildDailyMix(library, allFamiliar, size: 25).length, 25);

      // And nothing has: no familiar bucket.
      expect(buildDailyMix(library, const ListeningStats(), size: 25).length, 25);
    });

    test('a library smaller than the mix returns what there is', () {
      final mix = buildDailyMix([song('a'), song('b')], stats, size: 25);
      expect(mix.length, 2);
      expect(buildDailyMix(const [], stats), isEmpty);
    });
  });

  group('quick fill', () {
    test('prefers the same artist, then album, then genre', () {
      final seed = [song('seed', artistId: 1, albumId: 1, genre: 'Rock')];
      final library = [
        ...seed,
        song('same-artist', artistId: 1, albumId: 9, genre: 'Jazz'),
        song('same-album', artistId: 5, albumId: 1, genre: 'Jazz'),
        song('same-genre', artistId: 6, albumId: 8, genre: 'Rock'),
        song('unrelated', artistId: 7, albumId: 7, genre: 'Techno'),
      ];
      final result = quickFill(seed, library, const ListeningStats());

      expect(
        result.map((s) => s.id),
        ['same-artist', 'same-album', 'same-genre'],
      );
      expect(
        result.map((s) => s.id),
        isNot(contains('unrelated')),
        reason: 'nothing in common is noise, not filler',
      );
      expect(
        result.map((s) => s.id),
        isNot(contains('seed')),
        reason: 'what is already there is not a suggestion',
      );
    });

    test('breaks ties towards what has been listened to', () {
      final seed = [song('seed', artistId: 1, genre: 'Rock')];
      final library = [
        ...seed,
        song('quiet', artistId: 2, albumId: 4, genre: 'Rock'),
        song('loved', artistId: 3, albumId: 5, genre: 'Rock'),
      ];
      final result = quickFill(
        seed,
        library,
        const ListeningStats(msListened: {'loved': 900000}),
      );
      expect(result.first.id, 'loved');
    });

    test('an empty seed or library yields nothing', () {
      expect(quickFill(const [], [song('a')], const ListeningStats()), isEmpty);
      expect(quickFill([song('a')], const [], const ListeningStats()), isEmpty);
      expect(
        quickFill([song('a')], [song('a')], const ListeningStats(), count: 0),
        isEmpty,
      );
    });
  });

  group('listening history in the database', () {
    late Directory tmp;
    late MusicDatabase db;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('pixelplay_stats');
      db = await MusicDatabase.open(tmp.path);
      db.replaceLibrary([song('a'), song('b', artistId: 2, artist: 'Other')]);
    });

    tearDown(() async {
      db.close();
      await tmp.delete(recursive: true);
    });

    test('a play is opened then closed with the time actually heard', () {
      final id = db.startPlayback('a');
      expect(db.totalListenedMs(), 0, reason: 'nothing heard yet');
      expect(db.recentlyPlayedIds(), ['a'], reason: 'but already recent');

      db.finishPlayback(id, 90000);
      expect(db.totalListenedMs(), 90000);
      expect(db.topSongsByTime().single, ('a', 90000, 1));
    });

    test('time is attributed per artist and album', () {
      db.recordPlayback('a', msPlayed: 60000);
      db.recordPlayback('b', msPlayed: 30000);

      final artists = db.topArtistsByTime();
      expect(artists.first.$2, 'Artist');
      expect(artists.first.$3, 60000);
      expect(db.topAlbumsByTime().first.$3, 90000, reason: 'both share album 1');
    });

    test('a streak counts consecutive days up to today', () {
      final now = DateTime.now();
      for (final days in [0, 1, 2, 5]) {
        db.recordPlayback(
          'a',
          msPlayed: 1000,
          at: now.subtract(Duration(days: days)),
        );
      }
      expect(db.listeningStreakDays(), 3, reason: 'today, -1, -2, then a gap');
    });

    test('a streak that ended yesterday still counts', () {
      final now = DateTime.now();
      db.recordPlayback(
        'a',
        msPlayed: 1000,
        at: now.subtract(const Duration(days: 1)),
      );
      db.recordPlayback(
        'a',
        msPlayed: 1000,
        at: now.subtract(const Duration(days: 2)),
      );
      expect(db.listeningStreakDays(), 2);
    });

    test('no history means no streak', () {
      expect(db.listeningStreakDays(), 0);
      db.startPlayback('a'); // opened but nothing heard
      expect(db.listeningStreakDays(), 0);
    });

    test('per-day totals cover the whole window, gaps included', () {
      db.recordPlayback(
        'a',
        msPlayed: 5000,
        at: DateTime.now().subtract(const Duration(days: 2)),
      );
      final days = db.listeningByDay(days: 7);
      expect(days.length, 7);
      expect(days.map((d) => d.$2).reduce((a, b) => a + b), 5000);
      expect(days.first.$1.isBefore(days.last.$1), isTrue, reason: 'oldest first');
    });

    test('hour buckets follow when the play happened', () {
      final at = DateTime(2026, 8, 26, 14, 30);
      db.recordPlayback('a', msPlayed: 7000, at: at);
      expect(db.listeningByHour()[14], 7000);
    });

    test('a period filter excludes older plays', () {
      final now = DateTime.now();
      db.recordPlayback('a', msPlayed: 1000, at: now);
      db.recordPlayback(
        'a',
        msPlayed: 9000,
        at: now.subtract(const Duration(days: 40)),
      );
      expect(db.totalListenedMs(), 10000);
      expect(
        db.totalListenedMsSince(now.subtract(const Duration(days: 7))),
        1000,
      );
      expect(
        db.topSongsByTime(since: now.subtract(const Duration(days: 7))).single.$2,
        1000,
      );
    });
  });
}
