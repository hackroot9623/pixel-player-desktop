import 'models.dart';

/// Ported from `data/model/SortOption.kt` and `data/model/LibraryTabId.kt`.
///
/// The Kotlin version is a sealed class hierarchy with one object per option;
/// an enum plus per-tab comparator lookup expresses the same set without 500
/// lines of boilerplate.
enum SortOption {
  songDefaultOrder('SONG_DEFAULT', 'Default'),
  songTitleAZ('SONG_TITLE_AZ', 'Title A-Z'),
  songTitleZA('SONG_TITLE_ZA', 'Title Z-A'),
  songArtist('SONG_ARTIST', 'Artist A-Z'),
  songArtistDesc('SONG_ARTIST_DESC', 'Artist Z-A'),
  songAlbum('SONG_ALBUM', 'Album A-Z'),
  songAlbumDesc('SONG_ALBUM_DESC', 'Album Z-A'),
  songDuration('SONG_DURATION', 'Longest first'),
  songDurationAsc('SONG_DURATION_ASC', 'Shortest first'),
  songDateAdded('SONG_DATE_ADDED', 'Newest first'),
  songDateAddedAsc('SONG_DATE_ADDED_ASC', 'Oldest first'),

  albumTitleAZ('ALBUM_TITLE_AZ', 'Title A-Z'),
  albumTitleZA('ALBUM_TITLE_ZA', 'Title Z-A'),
  albumArtist('ALBUM_ARTIST', 'Artist A-Z'),
  albumArtistDesc('ALBUM_ARTIST_DESC', 'Artist Z-A'),
  albumReleaseYear('ALBUM_YEAR', 'Newest release'),
  albumReleaseYearAsc('ALBUM_YEAR_ASC', 'Oldest release'),
  albumDateAdded('ALBUM_DATE_ADDED', 'Recently added'),
  albumSizeDesc('ALBUM_SIZE_DESC', 'Most songs'),
  albumSizeAsc('ALBUM_SIZE_ASC', 'Fewest songs'),

  artistNameAZ('ARTIST_NAME_AZ', 'Name A-Z'),
  artistNameZA('ARTIST_NAME_ZA', 'Name Z-A'),
  artistNumSongsDesc('ARTIST_SONGS_DESC', 'Most songs'),
  artistNumSongsAsc('ARTIST_SONGS_ASC', 'Fewest songs'),

  playlistNameAZ('PLAYLIST_NAME_AZ', 'Name A-Z'),
  playlistNameZA('PLAYLIST_NAME_ZA', 'Name Z-A'),
  playlistDateCreated('PLAYLIST_CREATED', 'Newest first'),
  playlistDateCreatedAsc('PLAYLIST_CREATED_ASC', 'Oldest first'),

  folderNameAZ('FOLDER_NAME_AZ', 'Name A-Z'),
  folderNameZA('FOLDER_NAME_ZA', 'Name Z-A'),
  folderSongCountDesc('FOLDER_SONGS_DESC', 'Most songs'),
  folderSongCountAsc('FOLDER_SONGS_ASC', 'Fewest songs'),
  folderSubdirCountDesc('FOLDER_SUBDIRS_DESC', 'Most subfolders'),
  folderSubdirCountAsc('FOLDER_SUBDIRS_ASC', 'Fewest subfolders'),

  likedSongDateLiked('LIKED_DATE', 'Recently liked'),
  likedSongDateLikedAsc('LIKED_DATE_ASC', 'First liked'),
  likedSongTitleAZ('LIKED_TITLE_AZ', 'Title A-Z'),
  likedSongTitleZA('LIKED_TITLE_ZA', 'Title Z-A'),
  likedSongArtist('LIKED_ARTIST', 'Artist A-Z'),
  likedSongArtistDesc('LIKED_ARTIST_DESC', 'Artist Z-A'),
  likedSongAlbum('LIKED_ALBUM', 'Album A-Z'),
  likedSongAlbumDesc('LIKED_ALBUM_DESC', 'Album Z-A');

  const SortOption(this.storageKey, this.label);

  final String storageKey;
  final String label;

  static SortOption fromKey(String key, SortOption fallback) =>
      values.firstWhere((o) => o.storageKey == key, orElse: () => fallback);
}

enum LibraryTabId {
  songs('SONGS', 'Songs', SortOption.songTitleAZ),
  albums('ALBUMS', 'Albums', SortOption.albumTitleAZ),
  artists('ARTIST', 'Artists', SortOption.artistNameAZ),
  genres('GENRES', 'Genres', SortOption.artistNameAZ),
  playlists('PLAYLISTS', 'Playlists', SortOption.playlistNameAZ),
  folders('FOLDERS', 'Folders', SortOption.folderNameAZ),
  liked('LIKED', 'Liked', SortOption.likedSongDateLiked);

  const LibraryTabId(this.storageKey, this.title, this.defaultSort);

  final String storageKey;
  final String title;
  final SortOption defaultSort;

  /// Options offered in the sort sheet for this tab, in display order.
  List<SortOption> get sortOptions => switch (this) {
    LibraryTabId.songs => const [
      SortOption.songDefaultOrder,
      SortOption.songTitleAZ,
      SortOption.songTitleZA,
      SortOption.songArtist,
      SortOption.songArtistDesc,
      SortOption.songAlbum,
      SortOption.songAlbumDesc,
      SortOption.songDuration,
      SortOption.songDurationAsc,
      SortOption.songDateAdded,
      SortOption.songDateAddedAsc,
    ],
    LibraryTabId.albums => const [
      SortOption.albumTitleAZ,
      SortOption.albumTitleZA,
      SortOption.albumArtist,
      SortOption.albumArtistDesc,
      SortOption.albumReleaseYear,
      SortOption.albumReleaseYearAsc,
      SortOption.albumDateAdded,
      SortOption.albumSizeDesc,
      SortOption.albumSizeAsc,
    ],
    LibraryTabId.artists || LibraryTabId.genres => const [
      SortOption.artistNameAZ,
      SortOption.artistNameZA,
      SortOption.artistNumSongsDesc,
      SortOption.artistNumSongsAsc,
    ],
    LibraryTabId.playlists => const [
      SortOption.playlistNameAZ,
      SortOption.playlistNameZA,
      SortOption.playlistDateCreated,
      SortOption.playlistDateCreatedAsc,
    ],
    LibraryTabId.folders => const [
      SortOption.folderNameAZ,
      SortOption.folderNameZA,
      SortOption.folderSongCountDesc,
      SortOption.folderSongCountAsc,
      SortOption.folderSubdirCountDesc,
      SortOption.folderSubdirCountAsc,
    ],
    LibraryTabId.liked => const [
      SortOption.likedSongDateLiked,
      SortOption.likedSongDateLikedAsc,
      SortOption.likedSongTitleAZ,
      SortOption.likedSongTitleZA,
      SortOption.likedSongArtist,
      SortOption.likedSongArtistDesc,
      SortOption.likedSongAlbum,
      SortOption.likedSongAlbumDesc,
    ],
  };

  static LibraryTabId fromStorageKey(String key) => values.firstWhere(
    (t) => t.storageKey == key,
    orElse: () => LibraryTabId.songs,
  );
}

int _ci(String a, String b) => a.toLowerCase().compareTo(b.toLowerCase());

List<Song> sortSongs(List<Song> songs, SortOption option) {
  final out = [...songs];
  switch (option) {
    case SortOption.songDefaultOrder:
      break;
    case SortOption.songTitleAZ:
    case SortOption.likedSongTitleAZ:
      out.sort((a, b) => _ci(a.title, b.title));
    case SortOption.songTitleZA:
    case SortOption.likedSongTitleZA:
      out.sort((a, b) => _ci(b.title, a.title));
    case SortOption.songArtist:
    case SortOption.likedSongArtist:
      out.sort((a, b) => _ci(a.displayArtist, b.displayArtist));
    case SortOption.songArtistDesc:
    case SortOption.likedSongArtistDesc:
      out.sort((a, b) => _ci(b.displayArtist, a.displayArtist));
    case SortOption.songAlbum:
    case SortOption.likedSongAlbum:
      out.sort((a, b) => _ci(a.album, b.album));
    case SortOption.songAlbumDesc:
    case SortOption.likedSongAlbumDesc:
      out.sort((a, b) => _ci(b.album, a.album));
    case SortOption.songDuration:
      out.sort((a, b) => b.duration.compareTo(a.duration));
    case SortOption.songDurationAsc:
      out.sort((a, b) => a.duration.compareTo(b.duration));
    case SortOption.songDateAdded:
    case SortOption.likedSongDateLiked:
      out.sort((a, b) => b.dateAdded.compareTo(a.dateAdded));
    case SortOption.songDateAddedAsc:
    case SortOption.likedSongDateLikedAsc:
      out.sort((a, b) => a.dateAdded.compareTo(b.dateAdded));
    default:
      out.sort((a, b) => _ci(a.title, b.title));
  }
  return out;
}

List<Album> sortAlbums(List<Album> albums, SortOption option) {
  final out = [...albums];
  switch (option) {
    case SortOption.albumTitleZA:
      out.sort((a, b) => _ci(b.title, a.title));
    case SortOption.albumArtist:
      out.sort((a, b) => _ci(a.artist, b.artist));
    case SortOption.albumArtistDesc:
      out.sort((a, b) => _ci(b.artist, a.artist));
    case SortOption.albumReleaseYear:
      out.sort((a, b) => b.year.compareTo(a.year));
    case SortOption.albumReleaseYearAsc:
      out.sort((a, b) => a.year.compareTo(b.year));
    case SortOption.albumDateAdded:
      out.sort((a, b) => b.dateAdded.compareTo(a.dateAdded));
    case SortOption.albumSizeDesc:
      out.sort((a, b) => b.songCount.compareTo(a.songCount));
    case SortOption.albumSizeAsc:
      out.sort((a, b) => a.songCount.compareTo(b.songCount));
    default:
      out.sort((a, b) => _ci(a.title, b.title));
  }
  return out;
}

List<Artist> sortArtists(List<Artist> artists, SortOption option) {
  final out = [...artists];
  switch (option) {
    case SortOption.artistNameZA:
      out.sort((a, b) => _ci(b.name, a.name));
    case SortOption.artistNumSongsDesc:
      out.sort((a, b) => b.songCount.compareTo(a.songCount));
    case SortOption.artistNumSongsAsc:
      out.sort((a, b) => a.songCount.compareTo(b.songCount));
    default:
      out.sort((a, b) => _ci(a.name, b.name));
  }
  return out;
}

List<Playlist> sortPlaylists(List<Playlist> playlists, SortOption option) {
  final out = [...playlists];
  switch (option) {
    case SortOption.playlistNameZA:
      out.sort((a, b) => _ci(b.name, a.name));
    case SortOption.playlistDateCreated:
      out.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    case SortOption.playlistDateCreatedAsc:
      out.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    default:
      out.sort((a, b) => _ci(a.name, b.name));
  }
  return out;
}

List<MusicFolder> sortFolders(List<MusicFolder> folders, SortOption option) {
  final out = [...folders];
  switch (option) {
    case SortOption.folderNameZA:
      out.sort((a, b) => _ci(b.name, a.name));
    case SortOption.folderSongCountDesc:
      out.sort((a, b) => b.songCount.compareTo(a.songCount));
    case SortOption.folderSongCountAsc:
      out.sort((a, b) => a.songCount.compareTo(b.songCount));
    case SortOption.folderSubdirCountDesc:
      out.sort((a, b) => b.subdirCount.compareTo(a.subdirCount));
    case SortOption.folderSubdirCountAsc:
      out.sort((a, b) => a.subdirCount.compareTo(b.subdirCount));
    default:
      out.sort((a, b) => _ci(a.name, b.name));
  }
  return out;
}
