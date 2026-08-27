import '../../models/models.dart';
import '../remote_account.dart';
import '../remote_source.dart';
import 'ytdlp_client.dart';

/// YouTube Music as a source.
///
/// There is nothing to enumerate the way a Jellyfin server can be enumerated, so
/// a "library" here is whatever the user pointed at: playlist, album and mix
/// URLs, plus their own Liked Music when they have allowed cookie access. Search
/// is the other half, and it is what most of this gets used for.
class YoutubeSource {
  const YoutubeSource({required this.account, required this.client});

  final RemoteAccount account;
  final YtDlpClient client;

  /// The user's own liked tracks. Only reachable with cookies.
  static const likedMusicUrl = 'https://music.youtube.com/playlist?list=LM';

  /// Tracks from every configured URL, plus Liked Music when cookies are on.
  ///
  /// One failing URL does not lose the rest: a playlist that has been made
  /// private should cost that playlist, not the whole library.
  Future<List<Song>> songs() async {
    final urls = [
      if (youtubeUseLikedMusic(account)) likedMusicUrl,
      ...youtubeSourceUrls(account),
    ];
    if (urls.isEmpty) return const [];

    final songs = <Song>[];
    final seen = <String>{};
    for (final url in urls) {
      try {
        for (final entry in await client.entriesForUrl(url)) {
          final song = songFromEntry(account, entry);
          // The same track appears in several playlists often enough to matter.
          if (seen.add(song.id)) songs.add(song);
        }
      } on YtDlpException {
        continue;
      }
    }
    return songs;
  }

  /// Searches, and returns results as playable [Song]s.
  Future<List<Song>> search(String query, {int limit = 25}) async {
    final entries = await client.search(query, limit: limit);
    return [for (final entry in entries) songFromEntry(account, entry)];
  }

  /// Resolves the stream URL for one track, at the moment it is played.
  Future<String> resolve(Song song) {
    final id = youtubeVideoId(song);
    if (id == null) {
      throw const YtDlpException('That track has no YouTube video behind it.');
    }
    return client.resolveStreamUrl(id);
  }
}

/// URLs the account is configured to read, one per line in [RemoteAccount.extra].
List<String> youtubeSourceUrls(RemoteAccount account) {
  final raw = account.extra['urls'];
  if (raw == null || raw.trim().isEmpty) return const [];
  return [
    for (final line in raw.split('\n'))
      if (line.trim().isNotEmpty) line.trim(),
  ];
}

/// Whether to include the user's Liked Music. Requires cookies to be set.
bool youtubeUseLikedMusic(RemoteAccount account) =>
    account.extra['liked'] == 'true' && youtubeHasCookies(account);

/// The browser yt-dlp should take cookies from, or null for none.
String? youtubeCookiesBrowser(RemoteAccount account) {
  final value = account.extra['cookiesBrowser'];
  return (value == null || value.isEmpty) ? null : value;
}

/// An exported cookies.txt to use instead of reading the browser directly.
String? youtubeCookiesFile(RemoteAccount account) {
  final value = account.extra['cookiesFile'];
  return (value == null || value.trim().isEmpty) ? null : value.trim();
}

/// Whether this account has any cookie source at all — which is, in practice,
/// what decides whether playback works.
bool youtubeHasCookies(RemoteAccount account) =>
    youtubeCookiesFile(account) != null ||
    youtubeCookiesBrowser(account) != null;

/// Where the binary lives, when it is not simply on PATH.
String youtubeExecutable(RemoteAccount account) {
  final value = account.extra['executable'];
  return (value == null || value.trim().isEmpty) ? 'yt-dlp' : value.trim();
}

/// The video id carried by a YouTube song.
String? youtubeVideoId(Song song) {
  final item = remoteItemId(song.id);
  if (item == null) return null;
  return item.isEmpty ? null : item;
}

/// Maps one yt-dlp entry onto the app's [Song].
///
/// `path` is left empty on purpose: a YouTube stream URL expires and is bound to
/// the requesting address, so baking one into the library would hand the player
/// a link that is dead by the time anyone presses play. It is resolved per track
/// at playback instead.
Song songFromEntry(RemoteAccount account, YtEntry entry) {
  // Music uploads carry real artist tags; ordinary videos only have a channel,
  // and "Some Channel - Topic" is YouTube's auto-generated artist channel.
  final rawArtist = entry.artist ?? entry.uploader ?? 'YouTube';
  final artist = rawArtist.endsWith(' - Topic')
      ? rawArtist.substring(0, rawArtist.length - ' - Topic'.length)
      : rawArtist;
  final album = entry.album?.trim();

  return Song(
    id: remoteSongId(account, entry.id),
    title: entry.title,
    artist: artist,
    artistId: artist.hashCode.abs(),
    artists: [
      ArtistRef(id: artist.hashCode.abs(), name: artist, isPrimary: true),
    ],
    album: (album == null || album.isEmpty) ? 'YouTube Music' : album,
    albumId: ((album == null || album.isEmpty) ? 'YouTube Music' : album)
        .hashCode
        .abs(),
    path: '',
    // A thumbnail URL, which the artwork widgets already fetch over the network.
    albumArtPath: entry.thumbnail,
    duration: (entry.durationSeconds ?? 0) * 1000,
  );
}
