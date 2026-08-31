import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pixelplay_desktop/data/metadata/cover_fixer.dart';
import 'package:pixelplay_desktop/data/metadata/metadata_lookup.dart';
import 'package:pixelplay_desktop/data/models/models.dart';
import 'package:pixelplay_desktop/data/tags/tag_writer.dart';

/// The JSON shapes below are trimmed copies of real answers from
/// musicbrainz.org and api.deezer.com, keys and all — including the details that
/// are easy to guess wrong: a track `number` that is a string, no `position` in
/// a search result, a 0-based `track-offset`, and a partial date.

const _recordingSearch = '''
{"count":2,"recordings":[
  {"id":"rec-1","score":100,"title":"A Horse With No Name","length":246920,
   "artist-credit":[{"name":"America"}],
   "releases":[
     {"id":"live-1","title":"The Grand Cayman Concert","status":"Official",
      "date":"2018-11-09","country":"US","track-count":16,
      "release-group":{"primary-type":"Album","secondary-types":["Live"]},
      "media":[{"position":1,"format":"CD","track":[{"number":"16","title":"A Horse With No Name"}],
                "track-count":16,"track-offset":15}]},
     {"id":"studio-1","title":"America","status":"Official","date":"1971-12",
      "country":"GB","track-count":12,
      "release-group":{"primary-type":"Album"},
      "media":[{"position":1,"format":"CD","track":[{"number":"3","title":"A Horse With No Name"}],
                "track-count":12,"track-offset":2}]}]},
  {"id":"rec-2","score":72,"title":"A Horse With No Name (live)",
   "artist-credit":[{"name":"America"}]}]}
''';

const _releaseSearch = '''
{"count":2,"releases":[
  {"id":"rel-live","score":100,"title":"Greatest Hits","status":"Official",
   "date":"1998","track-count":18,"country":"US",
   "artist-credit":[{"name":"America"}],
   "release-group":{"primary-type":"Album","secondary-types":["Compilation"]}},
  {"id":"rel-studio","score":98,"title":"America","status":"Official",
   "date":"1971-12","track-count":12,
   "artist-credit":[{"name":"America"}],
   "release-group":{"primary-type":"Album"}}]}
''';

const _deezerAlbums = '''
{"data":[{"id":1,"title":"America","cover":"https://e-cdn/small.jpg",
          "cover_xl":"https://e-cdn/1000.jpg"}],"total":1}
''';

Song song({
  required String id,
  String album = 'America',
  int albumId = 1,
  String artist = 'America',
  String? albumArtist,
  String? albumArtPath,
  int trackNumber = 1,
}) => Song(
  id: id,
  title: id,
  artist: artist,
  artistId: 1,
  album: album,
  albumId: albumId,
  albumArtist: albumArtist,
  path: '/music/$id.mp3',
  albumArtPath: albumArtPath,
  duration: 1000,
  trackNumber: trackNumber,
  year: 0,
  dateAdded: 0,
  dateModified: 0,
);

void main() {
  group('building a MusicBrainz query', () {
    test('the fields are searched separately', () {
      final query = musicBrainzRecordingQuery(
        title: 'Black',
        artist: 'Pearl Jam',
        album: 'Ten',
      );
      expect(query, 'recording:"Black" AND artist:"Pearl Jam" AND release:"Ten"');
    });

    test('an empty field is left out rather than searched for nothing', () {
      expect(musicBrainzRecordingQuery(title: 'Black'), 'recording:"Black"');
      expect(musicBrainzRecordingQuery(title: 'Black', artist: '  '),
          'recording:"Black"');
    });

    test('Lucene syntax in a title is escaped', () {
      // Without this, MusicBrainz reads the colon as a field separator and the
      // quotes as string delimiters, and answers 400 or nonsense.
      final query = musicBrainzRecordingQuery(title: 'Album: Say "Yes"');
      expect(query, r'recording:"Album\: Say \"Yes\""');
    });

    test('every reserved character is escaped', () {
      expect(luceneEscape('a+b-c&d|e!f(g)h{i}j[k]l^m"n~o*p?q:r\\s/t'),
          r'a\+b\-c\&d\|e\!f\(g\)h\{i\}j\[k\]l\^m\"n\~o\*p\?q\:r\\s\/t');
    });

    test('an album query needs only the album', () {
      expect(musicBrainzReleaseQuery(album: 'Ten'), 'release:"Ten"');
      expect(musicBrainzReleaseQuery(album: '', artist: 'x'), 'artist:"x"');
    });
  });

  group('reading a recording search', () {
    final matches = parseRecordingMatches(_recordingSearch);

    test('one candidate per release, plus the release-less recording', () {
      // Two releases on the first recording, and the second recording has none.
      expect(matches, hasLength(3));
    });

    test('the studio album outranks the live one despite an equal score', () {
      // Both score 100 in MusicBrainz. Tagging a studio track as live is a wrong
      // answer that looks right, so a Live release is demoted.
      expect(matches.first.album, 'America');
      expect(matches.first.year, 1971);
      expect(matches.any((m) => m.secondaryTypes.contains('Live')), isTrue);
      expect(matches.indexWhere((m) => m.album == 'The Grand Cayman Concert'),
          greaterThan(0));
    });

    test('the track number survives being a string', () {
      final studio = matches.firstWhere((m) => m.album == 'America');
      expect(studio.trackNumber, 3);
      expect(studio.trackTotal, 12);
      expect(studio.discNumber, 1);
      expect(studio.discTotal, 1);
    });

    test('a partial date gives the year', () {
      expect(matches.firstWhere((m) => m.album == 'America').year, 1971);
    });

    test('title, artist and length come through', () {
      expect(matches.first.title, 'A Horse With No Name');
      expect(matches.first.artist, 'America');
      expect(matches.first.length, const Duration(milliseconds: 246920));
    });

    test('a recording with no releases still offers title and artist', () {
      final bare = matches.firstWhere((m) => m.album.isEmpty);
      expect(bare.title, 'A Horse With No Name (live)');
      expect(bare.releaseId, isNull);
    });

    test('the artist credit keeps its join phrases', () {
      final matches = parseRecordingMatches('''
        {"recordings":[{"id":"r","score":90,"title":"Under Pressure",
          "artist-credit":[{"name":"Queen","joinphrase":" & "},{"name":"David Bowie"}]}]}
      ''');
      expect(matches.single.artist, 'Queen & David Bowie');
    });

    test('junk is skipped rather than fatal', () {
      expect(parseRecordingMatches('not json'), isEmpty);
      expect(parseRecordingMatches('{"recordings":"nope"}'), isEmpty);
      expect(parseRecordingMatches('{"recordings":[{"score":1},"x"]}'), isEmpty);
    });

    test('a famous song does not produce eighty rows', () {
      final many = parseRecordingMatches(_recordingSearch, releasesPerRecording: 1);
      expect(many, hasLength(2));
    });
  });

  group('reading an album search', () {
    test('a compilation is demoted below the original album', () {
      final matches = parseReleaseMatches(_releaseSearch)
        ..sort((a, b) => b.rank.compareTo(a.rank));
      expect(matches.first.album, 'America');
      expect(matches.first.trackTotal, 12);
    });

    test('rank accounts for status as well as type', () {
      const official = MetadataMatch(
          title: '', artist: '', album: 'a', score: 90, status: 'Official');
      const bootleg = MetadataMatch(
          title: '', artist: '', album: 'a', score: 90, status: 'Bootleg');
      expect(official.rank, greaterThan(bootleg.rank));
    });
  });

  test('the cover archive URL is keyed by release', () {
    expect(coverArtUrl('abc'), 'https://coverartarchive.org/release/abc/front-500');
    expect(coverArtUrl('abc', size: 1200),
        'https://coverartarchive.org/release/abc/front-1200');
  });

  group('the Deezer fallback', () {
    test('the largest cover wins', () {
      expect(parseDeezerCover(_deezerAlbums), 'https://e-cdn/1000.jpg');
    });

    test('no results is null, not an error', () {
      expect(parseDeezerCover('{"data":[]}'), isNull);
      expect(parseDeezerCover('rubbish'), isNull);
    });
  });

  group('recognising an image', () {
    test('the formats a cover arrives in are accepted', () {
      expect(looksLikeImage([0xFF, 0xD8, 0xFF, 0xE0]), isTrue); // JPEG
      expect(looksLikeImage([0x89, 0x50, 0x4E, 0x47]), isTrue); // PNG
      expect(looksLikeImage([0x52, 0x49, 0x46, 0x46]), isTrue); // WebP
    });

    test("the archive's 404 page is not written into a tag as a cover", () {
      expect(looksLikeImage('<!DOCTYPE html><html>'.codeUnits), isFalse);
      expect(looksLikeImage([0x00]), isFalse);
    });
  });

  group('finding the albums with no cover', () {
    test('songs are grouped by album, biggest first', () {
      final albums = coverlessAlbums([
        song(id: 'a', album: 'Ten', albumId: 2),
        song(id: 'b', album: 'Ten', albumId: 2),
        song(id: 'c', album: 'America', albumId: 1),
      ]);
      expect(albums.map((a) => a.album), ['Ten', 'America']);
      expect(albums.first.songs, hasLength(2));
    });

    test('an album that already has a cover is left out', () {
      // A path that exists — this test file itself, so no fixture is needed.
      final albums = coverlessAlbums([
        song(id: 'a', albumArtPath: 'test/metadata_test.dart'),
        song(id: 'b', albumId: 2, album: 'Ten'),
      ]);
      expect(albums.map((a) => a.album), ['Ten']);
    });

    test('a recorded path whose file has gone still counts as missing', () {
      final albums = coverlessAlbums([
        song(id: 'a', albumArtPath: '/nonexistent/artwork/1.jpg'),
      ]);
      expect(albums, hasLength(1));
    });

    test('the album artist is what gets searched, not the first performer', () {
      // On a compilation the first track's performer finds the wrong release.
      final albums = coverlessAlbums([
        song(id: 'a', artist: 'Nina Simone', albumArtist: 'Various Artists'),
      ]);
      expect(albums.single.artist, 'Various Artists');
    });

    test('tracks come back in track order', () {
      final albums = coverlessAlbums([
        song(id: 'b', trackNumber: 2),
        song(id: 'a', trackNumber: 1),
      ]);
      expect(albums.single.songs.map((s) => s.id), ['a', 'b']);
    });

    test('an album with no name is not searchable', () {
      final albums = coverlessAlbums([song(id: 'a', album: '')]);
      expect(albums.single.isSearchable, isFalse);
    });
  });

  group('the cover fixer', () {
    late _FakeLookup lookup;
    late CoverFixer fixer;
    late List<(List<Song>, TagEdit)> writes;
    late Map<String, String> failures;
    var reloaded = 0;

    setUp(() {
      lookup = _FakeLookup();
      writes = [];
      failures = {};
      reloaded = 0;
      fixer = CoverFixer(
        lookup: lookup,
        writer: (songs, edit) {
          writes.add((songs, edit));
          return failures;
        },
        onFinished: () async => reloaded++,
      );
    });

    tearDown(() {
      fixer.dispose();
      lookup.dispose();
    });

    test('a scan finds nothing to do on a library that has its covers', () {
      fixer.scan([song(id: 'a', albumArtPath: 'test/metadata_test.dart')]);
      expect(fixer.candidates, isEmpty);
      expect(fixer.progress, isNull);
    });

    test('found covers are offered, then written', () async {
      fixer.scan([song(id: 'a'), song(id: 'b')]);
      expect(fixer.candidates, hasLength(1));

      await fixer.find();
      expect(fixer.found, 1);
      expect(fixer.candidates.single.state, CoverState.found);
      expect(fixer.candidates.single.match?.album, 'America');
      // Nothing is written by the search.
      expect(writes, isEmpty);

      await fixer.apply();
      expect(writes, hasLength(1));
      // Both tracks of the album, artwork only — no album or year rewritten.
      expect(writes.single.$1.map((s) => s.id), ['a', 'b']);
      expect(writes.single.$2.artwork, isNotNull);
      expect(writes.single.$2.album, isNull);
      expect(writes.single.$2.year, isNull);
      expect(fixer.written, 2);
      expect(reloaded, 1);
      expect(fixer.candidates.single.state, CoverState.written);
    });

    test('an album with nothing found is not written', () async {
      lookup.artwork = null;
      fixer.scan([song(id: 'a')]);
      await fixer.find();

      expect(fixer.candidates.single.state, CoverState.notFound);
      expect(fixer.candidates.single.selected, isFalse);
      await fixer.apply();
      expect(writes, isEmpty);
      expect(reloaded, 0);
    });

    test('an unsearchable album is skipped before any request', () async {
      fixer.scan([song(id: 'a', album: '')]);
      await fixer.find();
      expect(lookup.albumSearches, isEmpty);
      expect(fixer.candidates.single.state, CoverState.skipped);
      expect(fixer.candidates.single.error, contains('No album tag'));
    });

    test('a lookup failure is reported and does not stop the rest', () async {
      lookup.failOn = {'America'};
      fixer.scan([
        song(id: 'a'),
        song(id: 'b', album: 'Ten', albumId: 2),
      ]);
      await fixer.find();

      final failed = fixer.candidates.firstWhere((c) => c.album.album == 'America');
      expect(failed.state, CoverState.failed);
      expect(failed.error, contains('could not be reached'));
      expect(
        fixer.candidates.firstWhere((c) => c.album.album == 'Ten').state,
        CoverState.found,
      );
    });

    test('the search is by album artist and album', () async {
      fixer.scan([song(id: 'a', artist: 'x', albumArtist: 'Various Artists')]);
      await fixer.find();
      expect(lookup.albumSearches, [('America', 'Various Artists')]);
    });

    test('a write failure is surfaced per file', () async {
      failures = {'a': 'Tags cannot be written to this format'};
      fixer.scan([song(id: 'a')]);
      await fixer.find();
      await fixer.apply();

      expect(fixer.written, 0);
      expect(fixer.failures, hasLength(1));
      expect(fixer.candidates.single.state, CoverState.failed);
      // Nothing was written, so there is nothing to rescan for.
      expect(reloaded, 0);
    });

    test('deselecting one leaves it alone', () async {
      fixer.scan([song(id: 'a')]);
      await fixer.find();
      fixer.selectAll(false);
      expect(fixer.selectedCount, 0);

      await fixer.apply();
      expect(writes, isEmpty);
    });

    test('selection cannot be turned on for a cover that was never found', () {
      lookup.artwork = null;
      fixer.scan([song(id: 'a')]);
      fixer.selectAll(true);
      expect(fixer.selectedCount, 0);
    });
  });
}

/// A lookup that answers from the fixtures above without a network.
class _FakeLookup extends MetadataLookup {
  _FakeLookup() : super(minimumInterval: Duration.zero);

  final albumSearches = <(String, String)>[];
  Set<String> failOn = const {};
  Uint8List? artwork = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3]);

  @override
  Future<List<MetadataMatch>> searchAlbums({
    required String album,
    String artist = '',
    int limit = 5,
  }) async {
    albumSearches.add((album, artist));
    if (failOn.contains(album)) {
      throw const MetadataLookupException(
        'MusicBrainz could not be reached. Check the connection and try again.',
      );
    }
    return [
      MetadataMatch(
        title: '',
        artist: artist,
        album: album == 'America' ? 'America' : album,
        releaseId: 'rel-$album',
        score: 100,
      ),
    ];
  }

  @override
  Future<Uint8List?> cover(MetadataMatch match, {int size = 500}) async =>
      artwork;

  @override
  Future<Uint8List?> coverFromDeezer({
    required String album,
    String artist = '',
  }) async => artwork;
}
