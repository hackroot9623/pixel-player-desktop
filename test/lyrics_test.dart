import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pixelplay_desktop/data/db/database.dart';
import 'package:pixelplay_desktop/data/lyrics/lrc_parser.dart';
import 'package:pixelplay_desktop/data/lyrics/lrclib_client.dart';
import 'package:pixelplay_desktop/data/lyrics/lyrics_repository.dart';
import 'package:pixelplay_desktop/data/models/lyrics.dart';
import 'package:pixelplay_desktop/data/models/models.dart';

const _lrc = '''
[ti:Test Track]
[ar:Test Artist]
[offset:250]
[00:01.00]First line
[00:05.50]Second line
[00:09.25]
[00:12.00]Third line
[01:02.10]Last line
''';

void main() {
  group('LRC parsing', () {
    test('reads timestamps, metadata and the offset tag', () {
      final lyrics = parseLyrics(_lrc, source: LyricsSource.local)!;
      expect(lyrics.isSynced, isTrue);
      expect(lyrics.source, LyricsSource.local);
      expect(lyrics.offsetMs, 250, reason: 'from the [offset:] tag');
      expect(lyrics.synced!.length, 5);
      expect(lyrics.synced!.first.timeMs, 1000);
      expect(lyrics.synced!.first.line, 'First line');
      expect(lyrics.synced![1].timeMs, 5500);
      // Empty lyric lines survive as instrumental gaps.
      expect(lyrics.synced![2].isBlank, isTrue);
      expect(lyrics.synced!.last.timeMs, 62100, reason: 'mm:ss over a minute');
      // Metadata tags must not leak into the text.
      expect(lyrics.plain, isNot(contains('Test Track')));
    });

    test('an explicit offset overrides the file tag', () {
      final lyrics = parseLyrics(
        _lrc,
        source: LyricsSource.local,
        offsetMs: -800,
      )!;
      expect(lyrics.offsetMs, -800);
    });

    test('handles a repeated line carrying several timestamps', () {
      final lyrics = parseLyrics(
        '[00:10.00][00:40.00][01:10.00]Chorus',
        source: LyricsSource.remote,
      )!;
      expect(lyrics.synced!.map((line) => line.timeMs), [10000, 40000, 70000]);
      expect(
        lyrics.synced!.every((line) => line.line == 'Chorus'),
        isTrue,
      );
    });

    test('reads enhanced word-level timings', () {
      final lyrics = parseLyrics(
        '[00:01.00]<00:01.00>Hello <00:01.50>big <00:02.00>world',
        source: LyricsSource.remote,
      )!;
      final line = lyrics.synced!.single;
      expect(line.line, 'Hello big world', reason: 'word tags stripped');
      expect(line.words, isNotNull);
      expect(line.words!.map((w) => w.timeMs), [1000, 1500, 2000]);
      expect(line.words!.map((w) => w.word.trim()), ['Hello', 'big', 'world']);
    });

    test('falls back to plain text when there are no timestamps', () {
      final lyrics = parseLyrics(
        'Just a line\nAnd another',
        source: LyricsSource.embedded,
      )!;
      expect(lyrics.isSynced, isFalse);
      expect(lyrics.plain, ['Just a line', 'And another']);
    });

    test('empty input yields nothing', () {
      expect(parseLyrics('   \n\n', source: LyricsSource.embedded), isNull);
    });

    test('strips zero-width and bidi characters', () {
      final lyrics = parseLyrics(
        '[00:01.00]Clean\u200Bline\u202E',
        source: LyricsSource.remote,
      )!;
      expect(lyrics.synced!.single.line, 'Cleanline');
    });

    test('round-trips through toLrc', () {
      final original = parseLyrics(_lrc, source: LyricsSource.local)!;
      final reparsed = parseLyrics(
        toLrc(original),
        source: LyricsSource.local,
      )!;
      expect(reparsed.offsetMs, original.offsetMs);
      expect(
        reparsed.synced!.map((line) => (line.timeMs, line.line)),
        original.synced!.map((line) => (line.timeMs, line.line)),
      );
    });

    test('formatTimestamp pads to mm:ss.xx', () {
      expect(formatTimestamp(0), '00:00.00');
      expect(formatTimestamp(1000), '00:01.00');
      expect(formatTimestamp(62100), '01:02.10');
      expect(formatTimestamp(-5), '00:00.00');
    });
  });

  group('active line lookup', () {
    final lyrics = parseLyrics(_lrc, source: LyricsSource.local)!;

    test('returns -1 before the first line, then tracks position', () {
      // First line is at 1000 ms, and the offset shifts it 250 ms later.
      expect(lyrics.activeIndexAt(const Duration(milliseconds: 500)), -1);
      expect(lyrics.activeIndexAt(const Duration(milliseconds: 1300)), 0);
      expect(lyrics.activeIndexAt(const Duration(milliseconds: 6000)), 1);
      expect(lyrics.activeIndexAt(const Duration(seconds: 30)), 3);
      expect(lyrics.activeIndexAt(const Duration(minutes: 5)), 4);
    });

    test('is stable across every millisecond of the track', () {
      // A binary search that mis-handles boundaries would jump backwards.
      var previous = -1;
      for (var ms = 0; ms < 70000; ms += 50) {
        final index = lyrics.activeIndexAt(Duration(milliseconds: ms));
        expect(index, greaterThanOrEqualTo(previous));
        previous = index;
      }
      expect(previous, lyrics.synced!.length - 1);
    });
  });

  group('LyricsRepository', () {
    late Directory tmp;
    late MusicDatabase db;

    Song song({String? embedded}) => Song(
      id: p.join(tmp.path, 'track.mp3'),
      title: 'Track',
      artist: 'Artist',
      artistId: 1,
      album: 'Album',
      albumId: 1,
      path: p.join(tmp.path, 'track.mp3'),
      duration: 210000,
      lyrics: embedded,
    );

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('pixelplay_lyrics');
      db = await MusicDatabase.open(tmp.path);
    });

    tearDown(() async {
      db.close();
      await tmp.delete(recursive: true);
    });

    test('embeddedFirst prefers the tag over a sidecar file', () async {
      File(p.join(tmp.path, 'track.lrc')).writeAsStringSync(
        '[00:01.00]From the sidecar',
      );
      final repository = LyricsRepository(db);
      final lyrics = await repository.resolve(
        song(embedded: '[00:01.00]From the tag'),
        preference: LyricsSourcePreference.embeddedFirst,
        allowNetwork: false,
      );
      expect(lyrics!.source, LyricsSource.embedded);
      expect(lyrics.synced!.single.line, 'From the tag');
    });

    test('localFirst prefers the sidecar file over the tag', () async {
      File(p.join(tmp.path, 'track.lrc')).writeAsStringSync(
        '[00:01.00]From the sidecar',
      );
      final repository = LyricsRepository(db);
      final lyrics = await repository.resolve(
        song(embedded: '[00:01.00]From the tag'),
        preference: LyricsSourcePreference.localFirst,
        allowNetwork: false,
      );
      expect(lyrics!.source, LyricsSource.local);
      expect(lyrics.synced!.single.line, 'From the sidecar');
    });

    test('caches what it resolves, so a second call needs no sources', () async {
      final repository = LyricsRepository(db);
      final track = song(embedded: '[00:02.00]Cached line');
      await repository.resolve(
        track,
        preference: LyricsSourcePreference.embeddedFirst,
        allowNetwork: false,
      );

      final cached = repository.cached(track);
      expect(cached, isNotNull);
      expect(cached!.synced!.single.line, 'Cached line');

      // Resolving a song with no sources at all now returns the cache.
      final again = await repository.resolve(
        song(),
        preference: LyricsSourcePreference.embeddedFirst,
        allowNetwork: false,
      );
      expect(again!.synced!.single.line, 'Cached line');
    });

    test('offset survives a round trip through the database', () async {
      final repository = LyricsRepository(db);
      final track = song(embedded: '[00:01.00]Line');
      await repository.resolve(
        track,
        preference: LyricsSourcePreference.embeddedFirst,
        allowNetwork: false,
      );
      repository.setOffset(track, -1500);
      expect(repository.cached(track)!.offsetMs, -1500);
    });

    test('manual edits are stored and can be cleared', () async {
      final repository = LyricsRepository(db);
      final track = song();
      final saved = repository.saveManual(track, '[00:03.00]Hand written');
      expect(saved!.source, LyricsSource.manual);
      expect(repository.cached(track)!.synced!.single.line, 'Hand written');

      repository.clear(track);
      expect(repository.cached(track), isNull);
    });

    test('returns null when nothing has lyrics and the network is off', () async {
      final repository = LyricsRepository(db);
      final lyrics = await repository.resolve(
        song(),
        preference: LyricsSourcePreference.apiFirst,
        allowNetwork: false,
      );
      expect(lyrics, isNull);
    });
  });

  test('LrcLibResult reads the LRCLIB payload shape', () {
    final result = LrcLibResult.fromJson({
      'id': 42,
      'trackName': 'Track',
      'artistName': 'Artist',
      'albumName': 'Album',
      'duration': 210.5,
      'plainLyrics': 'plain',
      'syncedLyrics': '[00:01.00]synced',
    });
    expect(result.id, 42);
    expect(result.durationSeconds, 210.5);
    expect(result.hasSynced, isTrue);
    expect(result.hasAny, isTrue);

    final empty = LrcLibResult.fromJson({'id': 1, 'name': 'Only a name'});
    expect(empty.trackName, 'Only a name');
    expect(empty.hasSynced, isFalse);
    expect(empty.hasAny, isFalse);
  });
}
