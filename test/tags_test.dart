import 'dart:io';
import 'dart:typed_data';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pixelplay_desktop/data/db/database.dart';
import 'package:pixelplay_desktop/data/models/models.dart';
import 'package:pixelplay_desktop/data/scanner/library_scanner.dart';
import 'package:pixelplay_desktop/data/tags/tag_writer.dart';

/// Writes a real, playable 0.2s silent WAV. RIFF has a writer, so this is a
/// genuine end-to-end tag round trip with no fixtures checked into the repo.
File writeSilentWav(String path, {bool withInfoChunk = true}) {
  const sampleRate = 8000;
  const dataBytes = (sampleRate ~/ 5) * 2;
  final out = BytesBuilder();
  void ascii(String value) => out.add(value.codeUnits);
  void u32(int value) => out.add(
    Uint8List(4)..buffer.asByteData().setUint32(0, value, Endian.little),
  );
  void u16(int value) => out.add(
    Uint8List(2)..buffer.asByteData().setUint16(0, value, Endian.little),
  );

  ascii('RIFF');
  u32(36 + dataBytes);
  ascii('WAVE');
  ascii('fmt ');
  u32(16);
  u16(1);
  u16(1);
  u32(sampleRate);
  u32(sampleRate * 2);
  u16(2);
  u16(16);
  // A LIST/INFO chunk with one entry. The RIFF writer rewrites this block but
  // will not create one, so a fixture without it cannot be tagged at all.
  if (withInfoChunk) {
    final info = BytesBuilder();
    info.add('INFO'.codeUnits);
    info.add('INAM'.codeUnits);
    info.add(
      Uint8List(4)..buffer.asByteData().setUint32(0, 8, Endian.little),
    );
    info.add('untitled'.codeUnits);
    final infoBytes = info.toBytes();
    ascii('LIST');
    u32(infoBytes.length);
    out.add(infoBytes);
  }

  ascii('data');
  u32(dataBytes);
  out.add(Uint8List(dataBytes));

  final bytes = out.toBytes();
  // Patch the RIFF size now that the payload is known.
  bytes.buffer.asByteData().setUint32(4, bytes.length - 8, Endian.little);
  return File(path)..writeAsBytesSync(bytes);
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('pixelplay_tags');
  });

  tearDown(() async => tmp.delete(recursive: true));

  group('format support', () {
    test('only containers with a writer are offered', () {
      expect(canWriteTags('/music/a.mp3'), isTrue);
      expect(canWriteTags('/music/a.flac'), isTrue);
      expect(canWriteTags('/music/a.m4a'), isTrue);
      expect(canWriteTags('/music/a.wav'), isTrue);
      expect(canWriteTags('/music/A.MP3'), isTrue, reason: 'case-insensitive');
      // Readable but not writable by the metadata package.
      expect(canWriteTags('/music/a.ogg'), isFalse);
      expect(canWriteTags('/music/a.opus'), isFalse);
      expect(canWriteTags('/music/a.aiff'), isFalse);
    });

    test('writing an unsupported format fails without touching the file', () {
      final file = File(p.join(tmp.path, 'track.ogg'))
        ..writeAsBytesSync([1, 2, 3, 4]);
      expect(
        () => writeTags(file, const TagEdit(title: 'Nope')),
        throwsA(isA<TagWriteException>()),
      );
      expect(file.readAsBytesSync(), [1, 2, 3, 4]);
      // And no temporary file left behind.
      expect(
        Directory(tmp.path).listSync().length,
        1,
        reason: 'no leftover .pixelplay-tmp',
      );
    });
  });

  group('TagEdit', () {
    test('an empty edit is a no-op', () {
      expect(const TagEdit().isEmpty, isTrue);
      expect(const TagEdit(title: 'x').isEmpty, isFalse);
      expect(const TagEdit(removeArtwork: true).isEmpty, isFalse);

      // A no-op edit must not even open the file.
      final file = File(p.join(tmp.path, 'missing.mp3'));
      expect(() => writeTags(file, const TagEdit()), returnsNormally);
      expect(file.existsSync(), isFalse);
    });
  });

  group('writing tags', () {
    test('round-trips through a real file', () {
      final file = writeSilentWav(p.join(tmp.path, 'track.wav'));
      writeTags(
        file,
        const TagEdit(
          title: 'New Title',
          artist: 'New Artist',
          album: 'New Album',
        ),
      );

      final read = readMetadata(file, getImage: false);
      expect(read.title, 'New Title');
      expect(read.artist, 'New Artist');
      expect(read.album, 'New Album');
      // The audio itself has to survive the edit.
      expect(read.duration, isNotNull);
      expect(read.duration!.inMilliseconds, greaterThan(0));
    });

    test('leaves untouched fields alone', () {
      final file = writeSilentWav(p.join(tmp.path, 'track.wav'));
      writeTags(file, const TagEdit(title: 'First', artist: 'Keep Me'));
      writeTags(file, const TagEdit(title: 'Second'));

      final read = readMetadata(file, getImage: false);
      expect(read.title, 'Second');
      expect(read.artist, 'Keep Me', reason: 'a null field means leave alone');
    });

    test('a container with no tag block fails loudly', () {
      // Without a LIST/INFO chunk the RIFF writer has nothing to rewrite and
      // drops the edit on the floor. That has to surface as an error.
      final file = writeSilentWav(
        p.join(tmp.path, 'bare.wav'),
        withInfoChunk: false,
      );
      expect(
        () => writeTags(file, const TagEdit(title: 'Nope')),
        throwsA(
          isA<TagWriteException>().having(
            (e) => e.message,
            'message',
            contains('no writable tag block'),
          ),
        ),
      );
      // And the original is untouched.
      expect(readMetadata(file, getImage: false).title, isNull);
    });

    test('a failed write leaves the original intact', () {
      // Not a real WAV: the writer will choke on it.
      final file = File(p.join(tmp.path, 'broken.wav'))
        ..writeAsBytesSync(List.filled(64, 0));
      final before = file.readAsBytesSync();

      expect(
        () => writeTags(file, const TagEdit(title: 'Nope')),
        throwsA(isA<TagWriteException>()),
      );
      expect(
        file.readAsBytesSync(),
        before,
        reason: 'the write goes to a copy and only renames over on success',
      );
      expect(
        Directory(tmp.path).listSync().whereType<File>().length,
        1,
        reason: 'the temporary copy is cleaned up',
      );
    });
  });

  group('library refresh after an edit', () {
    test('the song row follows what is now in the file', () async {
      final db = await MusicDatabase.open(tmp.path);
      addTearDown(db.close);
      final artworkDir = p.join(tmp.path, 'artwork');

      final file = writeSilentWav(p.join(tmp.path, 'track.wav'));
      writeTags(
        file,
        const TagEdit(title: 'Before', artist: 'Alpha', album: 'Old'),
      );
      final original = readSongFile(file, artworkDir: artworkDir)!;
      db.replaceLibrary([original]);
      expect(db.allSongs().single.title, 'Before');

      // Mark it liked and queue it, to prove an edit does not lose either.
      db.setFavorite(original.id, true);
      db.upsertPlaylist(
        Playlist(
          id: 'pl',
          name: 'Mix',
          songIds: [original.id],
          createdAt: 1,
          lastModified: 1,
        ),
      );

      writeTags(
        file,
        const TagEdit(title: 'After', artist: 'Beta', album: 'New'),
      );
      final refreshed = readSongFile(file, artworkDir: artworkDir)!;
      db.upsertSong(refreshed);

      final stored = db.allSongs().single;
      expect(stored.title, 'After');
      expect(stored.artist, 'Beta');
      expect(stored.album, 'New');
      expect(
        stored.isFavorite,
        isTrue,
        reason: 'the id is the file path, so the like survives',
      );
      expect(db.playlist('pl')!.songIds, [original.id]);
      // The old artist should no longer be attached to this song.
      expect(
        db.allArtists().where((a) => a.name == 'Beta').length,
        1,
        reason: 'the new artist is linked',
      );
      expect(
        db.songsForArtist(stableId('Alpha')),
        isEmpty,
        reason: 'the old artist link is dropped',
      );
    });
  });
}
