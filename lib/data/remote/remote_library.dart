import '../models/models.dart';

/// Builds the album, artist and genre lists a remote server's song list
/// implies.
///
/// The local library gets these from SQL views over the scanned files. A remote
/// account has no database behind it, so the same shape is derived in memory —
/// which is what lets the ordinary Home, Search and Library screens work
/// against a server without knowing one is there.
({List<Album> albums, List<Artist> artists, List<Genre> genres}) groupSongs(
  List<Song> songs,
) {
  final albumSongs = <int, List<Song>>{};
  final artistSongs = <int, List<Song>>{};
  final artistNames = <int, String>{};
  final artistAlbums = <int, Set<int>>{};
  final genreCounts = <String, int>{};

  for (final song in songs) {
    albumSongs.putIfAbsent(song.albumId, () => []).add(song);

    // A track can credit several artists; each one should list it.
    final refs = song.artists.isEmpty
        ? [ArtistRef(id: song.artistId, name: song.artist, isPrimary: true)]
        : song.artists;
    for (final ref in refs) {
      artistSongs.putIfAbsent(ref.id, () => []).add(song);
      artistNames[ref.id] = ref.name;
      artistAlbums.putIfAbsent(ref.id, () => {}).add(song.albumId);
    }

    final genre = song.genre?.trim();
    if (genre != null && genre.isNotEmpty) {
      genreCounts[genre] = (genreCounts[genre] ?? 0) + 1;
    }
  }

  final albums = [
    for (final entry in albumSongs.entries)
      Album(
        id: entry.key,
        title: entry.value.first.album,
        artist: entry.value.first.albumArtist ?? entry.value.first.artist,
        year: entry.value
            .map((song) => song.year)
            .fold(0, (a, b) => b > a ? b : a),
        dateAdded: entry.value
            .map((song) => song.dateAdded)
            .fold(0, (a, b) => b > a ? b : a),
        // The first track with a cover speaks for the album.
        albumArtPath: entry.value
            .map((song) => song.albumArtPath)
            .firstWhere((path) => path != null, orElse: () => null),
        songCount: entry.value.length,
        albumArtist: entry.value.first.albumArtist,
      ),
  ]..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));

  final artists = [
    for (final entry in artistSongs.entries)
      Artist(
        id: entry.key,
        name: artistNames[entry.key] ?? 'Unknown artist',
        songCount: entry.value.length,
        albumCount: artistAlbums[entry.key]?.length ?? 0,
      ),
  ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

  final genres = [
    for (final entry in genreCounts.entries)
      Genre(id: entry.key, name: entry.key, songCount: entry.value),
  ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

  return (albums: albums, artists: artists, genres: genres);
}
