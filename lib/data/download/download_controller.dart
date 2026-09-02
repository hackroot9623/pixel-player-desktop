import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'spotdl_client.dart';

// The state of one download, for the screen to draw.
//
// Kept out of the UI so the counting and the finished/cancelled bookkeeping can
// be tested with a fake process, and kept out of Riverpod so it has no opinion
// about how the library gets rescanned afterwards — that arrives as a callback.

class DownloadController extends ChangeNotifier {
  DownloadController({SpotdlClient? client, this.onFinished})
    : _client = client ?? SpotdlClient();

  final SpotdlClient _client;

  /// Called once a run ends, so whoever owns the library can rescan the folder
  /// the files landed in.
  final Future<void> Function(String directory)? onFinished;

  StreamSubscription<SpotdlEvent>? _subscription;

  bool _botWall = false;
  bool _running = false;
  bool _cancelled = false;
  int _total = 0;
  String _playlistName = '';
  String? _error;

  final _downloaded = <String>[];
  final _skipped = <({String track, String reason})>[];
  final _failed = <({String track, String error})>[];
  final _log = <String>[];

  /// Null until probed, empty string when spotdl is missing.
  String? _version;

  bool get running => _running;
  bool get cancelled => _cancelled;
  int get total => _total;
  String get playlistName => _playlistName;
  String? get error => _error;

  List<String> get downloaded => List.unmodifiable(_downloaded);
  List<({String track, String reason})> get skipped =>
      List.unmodifiable(_skipped);
  List<({String track, String error})> get failed => List.unmodifiable(_failed);
  List<String> get log => List.unmodifiable(_log);

  /// Whether the failures look like YouTube demanding a sign-in.
  ///
  /// The single most common way this feature fails, and the one spotdl reports
  /// worst: search works anonymously, fetching the audio does not.
  bool get needsCookies => _botWall;

  String? get version => _version;
  bool get available => _version != null && _version!.isNotEmpty;
  bool get probed => _version != null;

  /// How far along, or null while the total is unknown.
  double? get progress {
    if (_total <= 0) return null;
    final done = _downloaded.length + _skipped.length + _failed.length;
    return (done / _total).clamp(0.0, 1.0);
  }

  int get handled => _downloaded.length + _skipped.length + _failed.length;

  /// Asks spotdl whether it is installed. Cheap, and the screen needs it before
  /// offering to start anything.
  Future<void> probe() async {
    _version = await _client.version() ?? '';
    notifyListeners();
  }

  /// Starts a download. Does nothing while one is already running.
  Future<void> start({
    required String url,
    required String outputDirectory,
    DownloadFormat format = DownloadFormat.mp3,
    String bitrate = 'auto',
    String? cookiesFile,
    bool overwriteExisting = false,
  }) async {
    if (_running) return;

    final trimmed = url.trim();
    if (trimmed.isEmpty) {
      _error = 'Paste a Spotify playlist, album or track link first.';
      notifyListeners();
      return;
    }
    if (!looksLikeSpotifyLink(trimmed)) {
      _error =
          'That does not look like a Spotify link. A playlist, album, artist '
          'or track URL — or a spotify: URI — is what spotdl expects.';
      notifyListeners();
      return;
    }

    // Created up front: spotdl writes into it, and a missing folder is a
    // confusing error from inside a subprocess.
    try {
      await Directory(outputDirectory).create(recursive: true);
    } on FileSystemException catch (failure) {
      _error = 'Cannot write to $outputDirectory: ${failure.message}';
      notifyListeners();
      return;
    }

    _running = true;
    _cancelled = false;
    _error = null;
    _total = 0;
    _playlistName = '';
    _downloaded.clear();
    _skipped.clear();
    _failed.clear();
    _log.clear();
    _botWall = false;
    notifyListeners();

    final events = _client.download(
      url: trimmed,
      outputDirectory: outputDirectory,
      format: format,
      bitrate: bitrate,
      cookiesFile: cookiesFile,
      overwriteExisting: overwriteExisting,
    );

    final done = Completer<void>();
    _subscription = events.listen(
      _apply,
      onError: (Object failure) {
        _error = '$failure';
        notifyListeners();
      },
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
      cancelOnError: false,
    );

    await done.future;
    await _subscription?.cancel();
    _subscription = null;
    _running = false;
    notifyListeners();

    // Only worth a rescan if something actually arrived.
    if (_downloaded.isNotEmpty) {
      await onFinished?.call(outputDirectory);
    }
  }

  void _apply(SpotdlEvent event) {
    switch (event) {
      case SpotdlTotal(:final count, :final name):
        _total = count;
        if (name.isNotEmpty) _playlistName = name;
      case SpotdlDownloaded(:final track):
        _downloaded.add(track);
      case SpotdlSkipped(:final track, :final reason):
        _skipped.add((track: track, reason: reason));
      case SpotdlFailed(:final track, :final error):
        _failed.add((track: track, error: error));
        if (looksLikeBotWall(error)) _botWall = true;
      case SpotdlLog(:final line):
        if (line.isEmpty) return;
        if (looksLikeBotWall(line)) _botWall = true;
        _log.add(line);
        // A long playlist produces thousands of lines and nobody reads past the
        // last few hundred.
        if (_log.length > 500) _log.removeRange(0, _log.length - 500);
    }
    notifyListeners();
  }

  /// Stops the run. What already downloaded stays on disk.
  void cancel() {
    if (!_running) return;
    _cancelled = true;
    _client.cancel();
    notifyListeners();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _client.cancel();
    super.dispose();
  }
}

/// Whether this is a link spotdl can take.
///
/// Checked here rather than left to spotdl so a mistyped URL fails immediately
/// with something readable instead of after a subprocess starts.
bool looksLikeSpotifyLink(String value) {
  final text = value.trim();
  if (text.startsWith('spotify:')) return true;
  final uri = Uri.tryParse(text);
  if (uri == null || !uri.hasScheme) return false;
  // A dot before the domain, or an exact match. `endsWith('spotify.com')` alone
  // would happily accept `notspotify.com` — the classic host-suffix mistake, and
  // a test caught it here.
  final host = uri.host.toLowerCase();
  if (host != 'spotify.com' && !host.endsWith('.spotify.com')) return false;
  // /playlist/, /album/, /track/, /artist/, and the /intl-xx/ prefixed forms
  // that the mobile app produces.
  return RegExp(
    r'/(playlist|album|track|artist)/',
  ).hasMatch(uri.path);
}
