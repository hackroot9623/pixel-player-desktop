import 'dart:io';
import 'dart:typed_data';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
// ParserTag is the base type the setters hang off; the package exports the
// setters but not the type itself.
import 'package:audio_metadata_reader/src/metadata/base.dart' show ParserTag;
import 'package:path/path.dart' as p;

/// Tag writing, replacing the TagLib side of the Android `EditSongSheet`.
///
/// `audio_metadata_reader` ships writers for ID3v2/v1, MP4, FLAC, RIFF and
/// APEv2, so this needs no native dependency — but it does not cover every
/// container it can *read*, hence [canWriteTags].

/// Containers with a writer. Ogg and Opus can be read but not written, so the
/// UI has to say so rather than failing at save time.
const writableExtensions = {
  '.mp3',
  '.m4a',
  '.mp4',
  '.flac',
  '.wav',
  '.ape',
};

bool canWriteTags(String path) =>
    writableExtensions.contains(p.extension(path).toLowerCase());

/// Fields the editor can change. Null means "leave alone", which is what makes
/// the same object usable for editing many songs at once.
class TagEdit {
  const TagEdit({
    this.title,
    this.artist,
    this.album,
    this.genre,
    this.year,
    this.trackNumber,
    this.trackTotal,
    this.discNumber,
    this.discTotal,
    this.lyrics,
    this.artwork,
    this.removeArtwork = false,
  });

  final String? title;
  final String? artist;
  final String? album;
  final String? genre;
  final int? year;
  final int? trackNumber;
  final int? trackTotal;
  final int? discNumber;
  final int? discTotal;
  final String? lyrics;

  /// Replacement cover art.
  final Uint8List? artwork;
  final bool removeArtwork;

  bool get isEmpty =>
      title == null &&
      artist == null &&
      album == null &&
      genre == null &&
      year == null &&
      trackNumber == null &&
      trackTotal == null &&
      discNumber == null &&
      lyrics == null &&
      artwork == null &&
      !removeArtwork;

  /// Applies the non-null fields to a metadata object.
  void applyTo(ParserTag metadata) {
    if (title != null) metadata.setTitle(title);
    if (artist != null) metadata.setArtist(artist);
    if (album != null) metadata.setAlbum(album);
    if (genre != null) metadata.setGenres([genre!]);
    if (year != null) metadata.setYear(DateTime(year!));
    if (trackNumber != null) metadata.setTrackNumber(trackNumber);
    if (trackTotal != null) metadata.setTrackTotal(trackTotal);
    if (discNumber != null) metadata.setCD(discNumber, discTotal);
    if (lyrics != null) metadata.setLyrics(lyrics);
    if (removeArtwork) {
      metadata.setPictures([]);
    } else if (artwork != null) {
      metadata.setPictures([
        Picture(artwork!, _mimeFor(artwork!), PictureType.coverFront),
      ]);
    }
  }
}

class TagWriteException implements Exception {
  TagWriteException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Writes [edit] into [file].
///
/// The write goes to a copy which is then re-read to prove it still parses,
/// and only then replaces the original. Tag writers rewrite container headers,
/// and these are the user's only copies of their music — a half-written file is
/// not an acceptable failure mode.
void writeTags(File file, TagEdit edit) {
  if (edit.isEmpty) return;
  if (!canWriteTags(file.path)) {
    throw TagWriteException(
      'Cannot write tags to ${p.extension(file.path)} files',
    );
  }

  final temporary = File('${file.path}.pixelplay-tmp');
  try {
    file.copySync(temporary.path);
    updateMetadata(temporary, edit.applyTo);

    // Prove the result is still readable before it replaces anything.
    final check = readMetadata(temporary, getImage: false);
    if (check.duration == null && check.title == null) {
      throw TagWriteException('The file did not survive the edit');
    }
    // And prove the edit actually landed. Some writers only rewrite tags that
    // are already present — the RIFF writer replaces an existing LIST/INFO
    // chunk but will not add one, and the ID3 writer needs an existing ID3v2
    // tag — so a file without them silently keeps its old values. Saying
    // nothing there would be worse than failing.
    final unwritten = _fieldsThatDidNotStick(edit, check);
    if (unwritten.isNotEmpty) {
      throw TagWriteException(
        'This file has no writable tag block, so '
        '${unwritten.join(', ')} could not be saved. Converting it to FLAC or '
        'a tagged MP3 will fix it.',
      );
    }

    // rename() is atomic within a filesystem, so the original is never
    // partially overwritten.
    temporary.renameSync(file.path);
  } on TagWriteException {
    if (temporary.existsSync()) temporary.deleteSync();
    rethrow;
  } catch (error) {
    if (temporary.existsSync()) temporary.deleteSync();
    throw TagWriteException('$error');
  }
}

/// Which of the verifiable fields the container refused to store.
///
/// Only title, artist and album are checked: every writer supports them, so a
/// mismatch means the tag block itself was not written, while the remaining
/// fields vary by container and would give false alarms.
List<String> _fieldsThatDidNotStick(TagEdit edit, AudioMetadata written) {
  final missed = <String>[];
  if (edit.title != null && written.title?.trim() != edit.title!.trim()) {
    missed.add('title');
  }
  if (edit.artist != null && written.artist?.trim() != edit.artist!.trim()) {
    missed.add('artist');
  }
  if (edit.album != null && written.album?.trim() != edit.album!.trim()) {
    missed.add('album');
  }
  return missed;
}

String _mimeFor(Uint8List bytes) {
  // Sniff rather than trust a file extension the bytes may not match.
  if (bytes.length > 8 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47) {
    return 'image/png';
  }
  return 'image/jpeg';
}
