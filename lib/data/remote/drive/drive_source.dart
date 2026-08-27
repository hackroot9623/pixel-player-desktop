import 'dart:io';

import '../../models/models.dart';
import '../remote_account.dart';
import '../remote_source.dart';
import 'google_oauth.dart';

// Google Drive as a music library.
//
// Drive is a filing cabinet, not a music server: it knows a file's name, size
// and folder, and nothing about what is inside it. There are no tags, no
// durations and no cover art in the metadata, so everything the library shows
// is derived from the layout — the folder a track sits in is its album, the
// folder above that is the artist, and the file name is the title.
//
// That mirrors how people actually keep music on Drive, and it is honest about
// its limits: a flat dump of files gets titles and nothing else. Duration is
// left at zero, and mpv reports the real one once a track plays.
//
// Playback streams straight from Drive. The URL needs an `Authorization`
// header, which mpv can carry, so nothing is downloaded first.

/// Where Drive account settings live inside [RemoteAccount.extra].
const driveClientIdKey = 'client_id';
const driveClientSecretKey = 'client_secret';
const driveFolderKey = 'folder_id';

String driveClientId(RemoteAccount account) =>
    account.extra[driveClientIdKey]?.trim() ?? '';

String driveClientSecret(RemoteAccount account) =>
    account.extra[driveClientSecretKey]?.trim() ?? '';

/// The folder to look in, or empty for the whole Drive.
String driveFolderId(RemoteAccount account) =>
    account.extra[driveFolderKey]?.trim() ?? '';

/// The stored session, or null when the user has never signed in.
GoogleTokens? driveTokens(RemoteAccount account) =>
    GoogleTokens.fromStorage(account.extra);

/// The header a Drive stream URL needs, for whoever opens it.
Map<String, String> driveStreamHeaders(String accessToken) => {
  'Authorization': 'Bearer $accessToken',
};

class DriveSource extends RemoteSource {
  DriveSource(
    super.account, {
    super.httpClient,
    super.timeout,
    GoogleOAuth? oauth,
    this.onSession,
  }) : oauth =
           oauth ??
           GoogleOAuth(
             clientId: driveClientId(account),
             clientSecret: driveClientSecret(account),
             httpClient: httpClient,
           );

  final GoogleOAuth oauth;

  /// Called whenever the session is renewed, so the caller can store the new
  /// token. Google's access tokens last an hour; without this every load would
  /// spend a round trip refreshing one it had already been given.
  final void Function(RemoteAccount account)? onSession;

  static const _api = 'https://www.googleapis.com/drive/v3';

  /// The access token in use, refreshed by [connect].
  String _accessToken = '';

  /// Mime types Drive reports for audio it recognises, plus the containers it
  /// gets wrong. Drive labels some `.m4a` and `.opus` files as video or as
  /// `application/octet-stream`, so extensions are checked as well.
  static const _audioExtensions = {
    'mp3',
    'flac',
    'm4a',
    'aac',
    'ogg',
    'oga',
    'opus',
    'wav',
    'wma',
    'aiff',
    'aif',
    'alac',
  };

  @override
  void authorise(HttpClientRequest request) {
    if (_accessToken.isEmpty) return;
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $_accessToken');
  }

  /// Renews the access token and returns the account with the new session.
  ///
  /// There is no password to check: the browser consent has already happened,
  /// and all that is left is exchanging the refresh token for an hour of
  /// access.
  @override
  Future<RemoteAccount> connect() async {
    final stored = driveTokens(account);
    if (stored == null) {
      throw const RemoteException(
        'This Google account has not been signed in yet. Open its setup screen '
        'and sign in with your browser.',
      );
    }
    if (driveClientId(account).isEmpty) {
      throw const RemoteException(
        'Add the Google client ID for this account before loading it.',
      );
    }

    try {
      final fresh = await oauth.refresh(stored.refreshToken);
      _accessToken = fresh.accessToken;
      final renewed = account.copyWith(
        extra: {...account.extra, ...fresh.storage},
        displayName: account.displayName,
      );
      onSession?.call(renewed);
      return renewed;
    } on GoogleAuthException catch (error) {
      throw RemoteException(error.message, detail: error.detail);
    }
  }

  /// Uses the stored token when it is still good, refreshing only if it is not.
  Future<void> _ensureToken() async {
    if (_accessToken.isNotEmpty) return;
    final stored = driveTokens(account);
    if (stored != null && !stored.isExpired && stored.accessToken.isNotEmpty) {
      _accessToken = stored.accessToken;
      return;
    }
    await connect();
  }

  /// The access token this source is currently using, for whoever opens the
  /// stream URLs.
  String get accessToken => _accessToken;

  @override
  Future<List<Song>> songs() async {
    await _ensureToken();

    // Folders first: a track's album and artist come from where it sits, so the
    // tree has to be known before the files can be named.
    final folders = await _folders();
    final files = await _audioFiles();

    return [
      for (final file in files)
        songFor(file, folders: folders, streamUrl: streamUrl(file.id)),
    ];
  }

  /// Drive has no cover art in its metadata: the picture is inside the file,
  /// which would mean downloading it.
  @override
  String? artUrl(String itemId, {int size = 512}) => null;

  /// The playable URL for a file. Needs [driveStreamHeaders] to open.
  Uri streamUrl(String fileId) =>
      Uri.parse('$_api/files/$fileId').replace(queryParameters: {
        'alt': 'media',
        // Shared drives are otherwise invisible to the download endpoint.
        'supportsAllDrives': 'true',
      });

  // ------------------------------------------------------------- listing

  Future<Map<String, DriveFolder>> _folders() async {
    final folders = <String, DriveFolder>{};
    await for (final item in _list(
      query: "mimeType = 'application/vnd.google-apps.folder'",
      fields: 'nextPageToken,files(id,name,parents)',
    )) {
      final id = item['id'];
      if (id is! String) continue;
      folders[id] = DriveFolder(
        id: id,
        name: item['name'] as String? ?? '',
        parentId: _firstParent(item),
      );
    }
    return folders;
  }

  Future<List<DriveFile>> _audioFiles() async {
    final folder = driveFolderId(account);
    final files = <DriveFile>[];
    await for (final item in _list(
      // Drive's query language has no "in" for mime types, so this asks for
      // anything it calls audio and filters the stragglers by extension below.
      query: [
        "(mimeType contains 'audio/' or mimeType = 'application/octet-stream')",
        if (folder.isNotEmpty) "'$folder' in parents",
      ].join(' and '),
      fields: 'nextPageToken,files(id,name,mimeType,size,parents)',
    )) {
      final file = DriveFile.parse(item);
      if (file != null && _isAudio(file)) files.add(file);
    }
    return files;
  }

  bool _isAudio(DriveFile file) {
    if (file.mimeType.startsWith('audio/')) return true;
    final dot = file.name.lastIndexOf('.');
    if (dot < 0) return false;
    return _audioExtensions.contains(file.name.substring(dot + 1).toLowerCase());
  }

  /// Pages through a `files.list` query.
  Stream<Map<String, Object?>> _list({
    required String query,
    required String fields,
  }) async* {
    String? pageToken;
    // A guard rather than a limit: a Drive with more pages than this is being
    // used as something other than a music library.
    for (var page = 0; page < 200; page++) {
      final json = await getJson(
        Uri.parse('$_api/files').replace(
          queryParameters: {
            'q': '$query and trashed = false',
            'fields': fields,
            'pageSize': '1000',
            'spaces': 'drive',
            'supportsAllDrives': 'true',
            'includeItemsFromAllDrives': 'true',
            if (pageToken != null) 'pageToken': pageToken,
          },
        ),
      );
      for (final item in (json['files'] as List? ?? const [])) {
        if (item is Map<String, Object?>) yield item;
      }
      final next = json['nextPageToken'];
      if (next is! String || next.isEmpty) return;
      pageToken = next;
    }
  }

  static String? _firstParent(Map<String, Object?> item) {
    final parents = item['parents'];
    return (parents is List && parents.isNotEmpty)
        ? parents.first as String?
        : null;
  }

  // -------------------------------------------------------------- naming

  /// Builds a song from a file and the folder tree around it.
  ///
  /// Kept static and given its inputs so the whole naming scheme can be tested
  /// without a Drive.
  Song songFor(
    DriveFile file, {
    required Map<String, DriveFolder> folders,
    required Uri streamUrl,
  }) {
    final album = folders[file.parentId];
    final artistFolder = album?.parentId == null
        ? null
        : folders[album!.parentId!];

    final parsed = parseFileName(file.name);
    // A folder name beats a guess from the file name, and the file name is all
    // there is when the track sits loose in My Drive.
    final artist = artistFolder?.name.isNotEmpty == true
        ? artistFolder!.name
        : (parsed.artist ?? 'Unknown artist');
    final albumName = album?.name.isNotEmpty == true
        ? album!.name
        : 'Google Drive';

    return Song(
      id: remoteSongId(account, file.id),
      title: parsed.title,
      artist: artist,
      artistId: artist.hashCode.abs(),
      artists: [
        ArtistRef(id: artist.hashCode.abs(), name: artist, isPrimary: true),
      ],
      album: albumName,
      albumId: albumName.hashCode.abs(),
      albumArtist: artistFolder?.name,
      path: streamUrl.toString(),
      // Drive reports no duration. mpv fills it in on playback.
      duration: 0,
      trackNumber: parsed.trackNumber,
      mimeType: file.mimeType.isEmpty ? null : file.mimeType,
    );
  }

  /// Pulls a track number, artist and title out of a file name.
  ///
  /// Handles the shapes that actually turn up: `03 Title.mp3`,
  /// `03 - Title.flac`, `Artist - Title.mp3`, `03. Artist - Title.m4a`.
  static ParsedFileName parseFileName(String fileName) {
    var name = fileName;
    final dot = name.lastIndexOf('.');
    if (dot > 0) name = name.substring(0, dot);
    name = name.replaceAll('_', ' ').trim();

    var trackNumber = 0;
    // A leading number is a track number; a year in the name is not, so only
    // one or two digits count.
    final leading = RegExp(r'^(\d{1,2})\s*[-.\s]\s*').firstMatch(name);
    if (leading != null) {
      trackNumber = int.tryParse(leading.group(1)!) ?? 0;
      name = name.substring(leading.end).trim();
    }

    String? artist;
    final split = name.indexOf(' - ');
    if (split > 0) {
      artist = name.substring(0, split).trim();
      name = name.substring(split + 3).trim();
    }

    return ParsedFileName(
      title: name.isEmpty ? fileName : name,
      artist: (artist?.isEmpty ?? true) ? null : artist,
      trackNumber: trackNumber,
    );
  }
}

/// One folder, as far as the naming scheme cares.
class DriveFolder {
  const DriveFolder({required this.id, required this.name, this.parentId});

  final String id;
  final String name;
  final String? parentId;
}

/// One audio file in Drive.
class DriveFile {
  const DriveFile({
    required this.id,
    required this.name,
    required this.mimeType,
    this.parentId,
    this.size = 0,
  });

  final String id;
  final String name;
  final String mimeType;
  final String? parentId;
  final int size;

  static DriveFile? parse(Map<String, Object?> item) {
    final id = item['id'];
    final name = item['name'];
    if (id is! String || name is! String) return null;
    final parents = item['parents'];
    return DriveFile(
      id: id,
      name: name,
      mimeType: item['mimeType'] as String? ?? '',
      parentId: (parents is List && parents.isNotEmpty)
          ? parents.first as String?
          : null,
      // Drive returns size as a string, because it can exceed 2^53.
      size: int.tryParse('${item['size'] ?? ''}') ?? 0,
    );
  }
}

class ParsedFileName {
  const ParsedFileName({
    required this.title,
    this.artist,
    this.trackNumber = 0,
  });

  final String title;
  final String? artist;
  final int trackNumber;
}
