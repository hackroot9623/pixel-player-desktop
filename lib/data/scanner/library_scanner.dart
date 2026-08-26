import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:path/path.dart' as p;

import '../models/models.dart';

/// Replaces `data/worker/MediaStoreSyncWorker` and friends. Desktop has no
/// MediaStore, so the library is built by walking the user's music folders and
/// reading tags directly.
class ScanProgress {
  const ScanProgress(this.scanned, this.total, this.currentPath);

  final int scanned;
  final int total;
  final String currentPath;

  double get fraction => total == 0 ? 0 : scanned / total;
}

class ScanRequest {
  const ScanRequest({
    required this.roots,
    required this.artworkDir,
    required this.artistDelimiters,
    required this.multiArtistEnabled,
  });

  final List<String> roots;
  final String artworkDir;

  /// From `DelimiterConfigScreen` — strings that separate multiple artists in
  /// one tag value.
  final List<String> artistDelimiters;
  final bool multiArtistEnabled;
}

/// Defaults mirrored from the Android delimiter settings.
const defaultArtistDelimiters = [
  ';',
  '/',
  '|',
  ' & ',
  ' feat. ',
  ' feat ',
  ' ft. ',
  ' ft ',
  ' with ',
  ' vs. ',
  ' vs ',
  ' x ',
];

const _coverFileNames = [
  'cover',
  'folder',
  'front',
  'album',
  'albumart',
  'artwork',
];
const _coverExtensions = ['.jpg', '.jpeg', '.png', '.webp'];

/// Stable 62-bit id derived from a name, so album/artist ids survive rescans
/// without an auto-increment table. FNV-1a, masked to stay inside SQLite's
/// signed 64-bit integer range.
int stableId(String value) {
  var hash = 0xcbf29ce484222325;
  for (final unit in value.toLowerCase().trim().codeUnits) {
    hash ^= unit;
    hash = (hash * 0x100000001b3) & 0x3FFFFFFFFFFFFFFF;
  }
  return hash;
}

/// Splits a raw artist tag into individual artists.
List<String> splitArtists(String raw, List<String> delimiters) {
  var parts = <String>[raw];
  for (final delimiter in delimiters) {
    parts = parts
        .expand(
          (part) => part.split(
            RegExp(RegExp.escape(delimiter), caseSensitive: false),
          ),
        )
        .toList();
  }
  final cleaned = <String>[];
  for (final part in parts) {
    final trimmed = part.trim();
    if (trimmed.isEmpty) continue;
    if (cleaned.any((c) => c.toLowerCase() == trimmed.toLowerCase())) continue;
    cleaned.add(trimmed);
  }
  return cleaned.isEmpty ? [raw.trim()] : cleaned;
}

/// Walks [roots] and returns every readable audio file.
List<File> collectAudioFiles(List<String> roots) {
  final files = <File>[];
  final seen = <String>{};
  for (final root in roots) {
    final dir = Directory(root);
    if (!dir.existsSync()) continue;
    for (final entity in dir.listSync(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final ext = p.extension(entity.path).toLowerCase();
      if (!supportedFileExtensions.contains(ext)) continue;
      if (!seen.add(entity.path)) continue;
      files.add(entity);
    }
  }
  return files;
}

/// Runs the scan on a background isolate and streams progress.
Stream<ScanProgress> scanLibrary(
  ScanRequest request, {
  required void Function(List<Song>) onDone,
}) {
  final receive = ReceivePort();
  final controller = StreamController<ScanProgress>();

  Isolate.spawn(_scanIsolate, (receive.sendPort, request)).then((isolate) {
    receive.listen((message) {
      if (message is ScanProgress) {
        controller.add(message);
      } else if (message is List<Song>) {
        onDone(message);
        controller.close();
        receive.close();
        isolate.kill();
      } else if (message is String) {
        controller.addError(message);
        controller.close();
        receive.close();
        isolate.kill();
      }
    });
  });

  return controller.stream;
}

void _scanIsolate((SendPort, ScanRequest) args) {
  final (port, request) = args;
  try {
    final files = collectAudioFiles(request.roots);
    final songs = <Song>[];
    final artworkCache = <int, String?>{};
    Directory(request.artworkDir).createSync(recursive: true);

    for (var i = 0; i < files.length; i++) {
      final file = files[i];
      if (i % 25 == 0 || i == files.length - 1) {
        port.send(ScanProgress(i + 1, files.length, file.path));
      }
      final song = _readSong(file, request, artworkCache);
      if (song != null) songs.add(song);
    }
    port.send(songs);
  } catch (e) {
    port.send('$e');
  }
}

Song? _readSong(
  File file,
  ScanRequest request,
  Map<int, String?> artworkCache,
) {
  AudioMetadata? meta;
  try {
    meta = readMetadata(file, getImage: true);
  } catch (_) {
    // Unreadable tags are not fatal: fall back to the filename so the track
    // still shows up and can be played.
  }
  final stat = file.statSync();
  final title = _nonEmpty(meta?.title) ?? p.basenameWithoutExtension(file.path);
  final rawArtist = _nonEmpty(meta?.artist) ?? 'Unknown artist';
  final album = _nonEmpty(meta?.album) ?? 'Unknown album';

  final artistNames = request.multiArtistEnabled
      ? splitArtists(rawArtist, request.artistDelimiters)
      : [rawArtist];
  final performers = meta?.performers ?? const <String>[];
  for (final performer in performers) {
    final trimmed = performer.trim();
    if (trimmed.isEmpty) continue;
    if (artistNames.any((a) => a.toLowerCase() == trimmed.toLowerCase())) {
      continue;
    }
    artistNames.add(trimmed);
  }

  final artists = [
    for (var i = 0; i < artistNames.length; i++)
      ArtistRef(
        id: stableId(artistNames[i]),
        name: artistNames[i],
        isPrimary: i == 0,
      ),
  ];

  // ponytail: album identity is (album title, primary artist). Compilations
  // tagged with per-track artists will split into several albums until the tag
  // reader exposes ALBUMARTIST (phase 4, TagLib).
  final albumArtist = artistNames.first;
  final albumId = stableId('$album $albumArtist');

  final artPath = artworkCache.putIfAbsent(
    albumId,
    () => _resolveArtwork(file, meta, albumId, request.artworkDir),
  );

  return Song(
    id: file.path,
    title: title,
    artist: artistNames.first,
    artistId: artists.first.id,
    artists: artists,
    album: album,
    albumId: albumId,
    albumArtist: albumArtist,
    path: file.path,
    albumArtPath: artPath,
    duration: meta?.duration?.inMilliseconds ?? 0,
    genre: (meta?.genres ?? const []).isEmpty ? null : meta!.genres.first,
    lyrics: _nonEmpty(meta?.lyrics),
    trackNumber: meta?.trackNumber ?? 0,
    discNumber: meta?.discNumber,
    year: meta?.year?.year ?? 0,
    dateAdded: stat.changed.millisecondsSinceEpoch,
    dateModified: stat.modified.millisecondsSinceEpoch,
    mimeType: _mimeForExtension(p.extension(file.path)),
    bitrate: meta?.bitrate,
    sampleRate: meta?.sampleRate,
  );
}

/// Embedded cover first, then a `cover.jpg`-style sidecar in the same folder —
/// the same precedence the Android app applies to MediaStore art vs. folder art.
String? _resolveArtwork(
  File file,
  AudioMetadata? meta,
  int albumId,
  String artworkDir,
) {
  final pictures = meta?.pictures ?? const <Picture>[];
  if (pictures.isNotEmpty) {
    final picture = pictures.firstWhere(
      (pic) => pic.pictureType == PictureType.coverFront,
      orElse: () => pictures.first,
    );
    final ext = picture.mimetype.contains('png') ? 'png' : 'jpg';
    final out = File(p.join(artworkDir, '$albumId.$ext'));
    if (!out.existsSync()) out.writeAsBytesSync(picture.bytes);
    return out.path;
  }
  final dir = Directory(p.dirname(file.path));
  for (final entity in dir.listSync(followLinks: false)) {
    if (entity is! File) continue;
    final name = p.basenameWithoutExtension(entity.path).toLowerCase();
    final ext = p.extension(entity.path).toLowerCase();
    if (_coverExtensions.contains(ext) && _coverFileNames.contains(name)) {
      return entity.path;
    }
  }
  return null;
}

String? _nonEmpty(String? value) {
  if (value == null) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

String _mimeForExtension(String extension) => switch (extension.toLowerCase()) {
  '.mp3' => 'audio/mpeg',
  '.flac' => 'audio/flac',
  '.m4a' || '.mp4' || '.mov' => 'audio/mp4',
  '.ogg' => 'audio/ogg',
  '.opus' => 'audio/opus',
  '.wav' => 'audio/wav',
  '.aif' || '.aiff' || '.aifc' => 'audio/aiff',
  '.ape' => 'audio/x-ape',
  _ => 'audio/*',
};
