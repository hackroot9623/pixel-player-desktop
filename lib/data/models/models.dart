/// Domain models, ported from `data/model/` (Song.kt, LibraryModels.kt,
/// Genre.kt, PlayList.kt, MusicFolder.kt).
library;

class ArtistRef {
  const ArtistRef({required this.id, required this.name, this.isPrimary = false});

  final int id;
  final String name;
  final bool isPrimary;
}

class Song {
  const Song({
    required this.id,
    required this.title,
    required this.artist,
    required this.artistId,
    this.artists = const [],
    required this.album,
    required this.albumId,
    this.albumArtist,
    required this.path,
    this.albumArtPath,
    required this.duration,
    this.genre,
    this.lyrics,
    this.isFavorite = false,
    this.trackNumber = 0,
    this.discNumber,
    this.year = 0,
    this.dateAdded = 0,
    this.dateModified = 0,
    this.mimeType,
    this.bitrate,
    this.sampleRate,
  });

  final String id;
  final String title;

  /// Legacy single-artist display string; prefer [displayArtist].
  final String artist;
  final int artistId;
  final List<ArtistRef> artists;
  final String album;
  final int albumId;
  final String? albumArtist;

  /// Absolute path on disk. Desktop has no MediaStore content URIs, so this is
  /// what both the player and the metadata reader consume.
  final String path;

  /// Path to the extracted cover file in the app cache, or an external
  /// `cover.jpg`-style sidecar next to the audio file.
  final String? albumArtPath;
  final int duration; // milliseconds
  final String? genre;
  final String? lyrics;
  final bool isFavorite;
  final int trackNumber;
  final int? discNumber;
  final int year;
  final int dateAdded; // epoch millis
  final int dateModified; // epoch millis
  final String? mimeType;
  final int? bitrate;
  final int? sampleRate;

  /// From `Song.displayArtist` — all artists joined, primary first.
  String get displayArtist {
    if (artists.isEmpty) return artist;
    final sorted = [...artists]
      ..sort((a, b) => (b.isPrimary ? 1 : 0) - (a.isPrimary ? 1 : 0));
    return sorted.map((a) => a.name).join(', ');
  }

  ArtistRef get primaryArtist =>
      artists.where((a) => a.isPrimary).firstOrNull ??
      artists.firstOrNull ??
      ArtistRef(id: artistId, name: artist, isPrimary: true);

  Duration get durationValue => Duration(milliseconds: duration);

  Song copyWith({bool? isFavorite, String? lyrics, String? albumArtPath}) => Song(
    id: id,
    title: title,
    artist: artist,
    artistId: artistId,
    artists: artists,
    album: album,
    albumId: albumId,
    albumArtist: albumArtist,
    path: path,
    albumArtPath: albumArtPath ?? this.albumArtPath,
    duration: duration,
    genre: genre,
    lyrics: lyrics ?? this.lyrics,
    isFavorite: isFavorite ?? this.isFavorite,
    trackNumber: trackNumber,
    discNumber: discNumber,
    year: year,
    dateAdded: dateAdded,
    dateModified: dateModified,
    mimeType: mimeType,
    bitrate: bitrate,
    sampleRate: sampleRate,
  );

  @override
  bool operator ==(Object other) => other is Song && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

class Album {
  const Album({
    required this.id,
    required this.title,
    required this.artist,
    required this.year,
    required this.dateAdded,
    this.albumArtPath,
    required this.songCount,
    this.albumArtist,
  });

  final int id;
  final String title;
  final String artist;
  final int year;
  final int dateAdded;
  final String? albumArtPath;
  final int songCount;
  final String? albumArtist;
}

class Artist {
  const Artist({
    required this.id,
    required this.name,
    required this.songCount,
    this.albumCount = 0,
    this.imageUrl,
    this.customImageUri,
  });

  final int id;
  final String name;
  final int songCount;
  final int albumCount;

  /// Remote artist image (Deezer) — populated in phase 4.
  final String? imageUrl;

  /// User-supplied local image, wins over [imageUrl].
  final String? customImageUri;

  String? get effectiveImageUrl {
    final custom = customImageUri;
    if (custom != null && custom.trim().isNotEmpty) return custom;
    final remote = imageUrl;
    if (remote != null && remote.trim().isNotEmpty) return remote;
    return null;
  }
}

class Genre {
  const Genre({required this.id, required this.name, this.songCount = 0});

  final String id;
  final String name;
  final int songCount;
}

enum PlaylistShapeType { circle, smoothRect, rotatedPill, star }

class Playlist {
  const Playlist({
    required this.id,
    required this.name,
    required this.songIds,
    required this.createdAt,
    required this.lastModified,
    this.isAiGenerated = false,
    this.isQueueGenerated = false,
    this.coverImagePath,
    this.coverColorArgb,
    this.coverIconName,
    this.coverShapeType,
    this.source = 'LOCAL',
  });

  final String id;
  final String name;
  final List<String> songIds;
  final int createdAt;
  final int lastModified;
  final bool isAiGenerated;
  final bool isQueueGenerated;
  final String? coverImagePath;
  final int? coverColorArgb;
  final String? coverIconName;
  final String? coverShapeType;
  final String source;

  int get songCount => songIds.length;
}

/// From `data/model/MusicFolder.kt` — a directory node in the folder browser.
class MusicFolder {
  const MusicFolder({
    required this.path,
    required this.name,
    required this.songCount,
    required this.subdirCount,
  });

  final String path;
  final String name;
  final int songCount;
  final int subdirCount;
}
