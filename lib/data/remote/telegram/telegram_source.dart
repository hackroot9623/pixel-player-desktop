import 'dart:async';

import '../../models/models.dart';
import '../remote_account.dart';
import '../remote_source.dart';
import 'tdlib_client.dart';

/// Port of `TelegramRepository` + `TelegramCacheManager`.
///
/// Telegram is not a music server: there is no catalogue to list, only chats
/// holding audio messages. So a "library" here is the audio in the chats the
/// user picked, and playback needs the file on disk first — which is what
/// `TelegramStreamProxy` papers over on Android by serving a partial download
/// over localhost.
class TelegramSource {
  TelegramSource({required this.account, required this.client});

  final RemoteAccount account;
  final TdlibClient client;

  /// A chat the user can pick audio from.
  static const savedMessagesTitle = 'Saved Messages';

  /// Chats with their ids, most recent first.
  Future<List<({int id, String title})>> chats({int limit = 200}) async {
    final reply = await client.request({
      '@type': 'getChats',
      'chat_list': {'@type': 'chatListMain'},
      'limit': limit,
    });
    final ids = (reply['chat_ids'] as List?)?.whereType<num>() ?? const [];

    final chats = <({int id, String title})>[];
    for (final id in ids) {
      try {
        final chat = await client.request({
          '@type': 'getChat',
          'chat_id': id.toInt(),
        });
        chats.add((
          id: id.toInt(),
          title: chat['title'] as String? ?? 'Chat ${id.toInt()}',
        ));
      } on TdlibException {
        // A chat that cannot be read is not worth failing the whole list for.
        continue;
      }
    }
    return chats;
  }

  /// Every audio message in [chatId], oldest request first.
  ///
  /// `searchChatMessages` with the audio filter is what the Android repository
  /// uses; it pages backwards from `from_message_id`.
  Future<List<Song>> audioIn(int chatId, {int pageSize = 100}) async {
    final songs = <Song>[];
    var fromMessageId = 0;

    while (true) {
      final reply = await client.request({
        '@type': 'searchChatMessages',
        'chat_id': chatId,
        'query': '',
        'from_message_id': fromMessageId,
        'offset': 0,
        'limit': pageSize,
        'filter': {'@type': 'searchMessagesFilterAudio'},
      });
      final messages =
          (reply['messages'] as List?)?.whereType<Map<String, Object?>>() ??
          const [];
      if (messages.isEmpty) break;

      for (final message in messages) {
        final song = songFromMessage(account, chatId, message);
        if (song != null) songs.add(song);
      }

      final last = messages.last['id'];
      if (last is! num || messages.length < pageSize) break;
      fromMessageId = last.toInt();
    }
    return songs;
  }

  /// Audio across every configured chat.
  Future<List<Song>> songs() async {
    final ids = telegramChatIds(account);
    if (ids.isEmpty) return const [];
    final songs = <Song>[];
    for (final id in ids) {
      songs.addAll(await audioIn(id));
    }
    return songs;
  }

  /// Makes sure the file behind [song] is on disk, and returns its path.
  ///
  /// TDLib downloads to its own files directory and reports progress through
  /// `updateFile`; `synchronous: true` means the reply waits for the whole file,
  /// which is the honest version of "streaming" without a proxy in front.
  Future<String> download(
    Song song, {
    void Function(double progress)? onProgress,
    Duration timeout = const Duration(minutes: 10),
  }) async {
    final fileId = telegramFileId(song);
    if (fileId == null) {
      throw const TdlibException('That track has no Telegram file behind it.');
    }

    // Already cached: TDLib keeps completed downloads between runs.
    final existing = await client.request({
      '@type': 'getFile',
      'file_id': fileId,
    });
    final localPath = _completedPath(existing);
    if (localPath != null) return localPath;

    StreamSubscription<Map<String, Object?>>? progressSub;
    if (onProgress != null) {
      progressSub = client.updates.listen((event) {
        if (event['@type'] != 'updateFile') return;
        final file = event['file'];
        if (file is! Map<String, Object?>) return;
        if ((file['id'] as num?)?.toInt() != fileId) return;
        final expected = (file['expected_size'] as num?)?.toInt() ?? 0;
        final local = file['local'];
        final downloaded = local is Map
            ? (local['downloaded_size'] as num?)?.toInt() ?? 0
            : 0;
        if (expected > 0) onProgress((downloaded / expected).clamp(0.0, 1.0));
      });
    }

    try {
      final reply = await client.request({
        '@type': 'downloadFile',
        'file_id': fileId,
        'priority': 32,
        'offset': 0,
        'limit': 0,
        'synchronous': true,
      }, timeout: timeout);
      final path = _completedPath(reply);
      if (path == null) {
        throw const TdlibException(
          'Telegram finished the download but reported no file.',
        );
      }
      return path;
    } finally {
      await progressSub?.cancel();
    }
  }

  String? _completedPath(Map<String, Object?> file) {
    final local = file['local'];
    if (local is! Map) return null;
    final complete = local['is_downloading_completed'] == true;
    final path = local['path'];
    return (complete && path is String && path.isNotEmpty) ? path : null;
  }
}

/// The chat ids an account is configured to read, from [RemoteAccount.extra].
List<int> telegramChatIds(RemoteAccount account) {
  final raw = account.extra['chats'];
  if (raw == null || raw.trim().isEmpty) return const [];
  return [
    for (final part in raw.split(','))
      if (int.tryParse(part.trim()) != null) int.parse(part.trim()),
  ];
}

/// A Telegram song's id encodes the chat and message it came from, so it
/// survives a restart, and the TDLib file id, so it can be downloaded.
///
/// TDLib file ids are only valid for one session, which is why the message id is
/// carried too: the file id can always be looked up again from the message.
String telegramSongId(RemoteAccount account, int chatId, int messageId) =>
    remoteSongId(account, '$chatId/$messageId');

/// The TDLib file id stashed on a song, or null when it is not a Telegram song.
int? telegramFileId(Song song) {
  // Kept in mimeType-adjacent territory would be wrong; the scheme is explicit.
  final marker = song.lyrics;
  if (marker == null || !marker.startsWith('tg-file:')) return null;
  return int.tryParse(marker.substring('tg-file:'.length));
}

/// Turns one `message` with an audio payload into a [Song].
///
/// Pure, so the mapping is testable against real TDLib JSON without a session.
Song? songFromMessage(
  RemoteAccount account,
  int chatId,
  Map<String, Object?> message,
) {
  final messageId = (message['id'] as num?)?.toInt();
  if (messageId == null) return null;
  final content = message['content'];
  if (content is! Map<String, Object?>) return null;

  // Music arrives either as an audio message or as a plain file attachment,
  // and the Android repository accepts both.
  final audio = switch (content['@type']) {
    'messageAudio' => content['audio'],
    'messageDocument' => content['document'],
    _ => null,
  };
  if (audio is! Map<String, Object?>) return null;

  final file = audio['audio'] ?? audio['document'];
  if (file is! Map<String, Object?>) return null;
  final fileId = (file['id'] as num?)?.toInt();
  if (fileId == null) return null;

  final mime = audio['mime_type'] as String?;
  final fileName = audio['file_name'] as String?;
  // A document has to look like audio before it is offered as a track.
  if (content['@type'] == 'messageDocument' && !_soundsLikeAudio(mime, fileName)) {
    return null;
  }

  final title = (audio['title'] as String?)?.trim();
  final performer = (audio['performer'] as String?)?.trim();
  final artist = (performer == null || performer.isEmpty)
      ? 'Telegram'
      : performer;
  final album = (audio['album'] as String?)?.trim();

  final local = file['local'];
  final cachedPath = local is Map && local['is_downloading_completed'] == true
      ? local['path'] as String?
      : null;

  return Song(
    id: telegramSongId(account, chatId, messageId),
    title: (title == null || title.isEmpty)
        ? (fileName ?? 'Telegram audio')
        : title,
    artist: artist,
    artistId: artist.hashCode.abs(),
    artists: [
      ArtistRef(id: artist.hashCode.abs(), name: artist, isPrimary: true),
    ],
    album: (album == null || album.isEmpty) ? 'Telegram' : album,
    albumId: ((album == null || album.isEmpty) ? 'Telegram' : album)
        .hashCode
        .abs(),
    // Empty until downloaded: nothing can play this straight from Telegram, so
    // the UI resolves the file before handing it to the player.
    path: cachedPath ?? '',
    duration: ((audio['duration'] as num?)?.toInt() ?? 0) * 1000,
    mimeType: mime,
    // Where the file id lives, so download() can find it without another query.
    lyrics: 'tg-file:$fileId',
    dateAdded: ((message['date'] as num?)?.toInt() ?? 0) * 1000,
  );
}

bool _soundsLikeAudio(String? mime, String? fileName) {
  if (mime != null && mime.startsWith('audio/')) return true;
  final name = fileName?.toLowerCase();
  if (name == null) return false;
  return const [
    '.mp3',
    '.flac',
    '.m4a',
    '.aac',
    '.ogg',
    '.opus',
    '.wav',
    '.wma',
    '.alac',
  ].any(name.endsWith);
}
