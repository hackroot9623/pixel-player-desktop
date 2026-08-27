import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

// One running copy, and files opened from the file manager.
//
// This is the desktop shape of Android's `ExternalPlayerActivity`: there, tapping
// an audio file launched an activity with a content URI and the system decided
// whether to reuse the task. Here the app has to arrange both halves itself —
// notice that a copy is already running, and hand it the files rather than
// starting a second player that fights the first one for the audio device.
//
// The rendezvous is a loopback TCP socket rather than a lock file, because a
// lock file can say "someone is running" but cannot carry the file list. Loopback
// works the same on all three platforms, where a unix socket does not.

/// Audio this app is willing to be handed.
const openableExtensions = {
  '.mp3',
  '.flac',
  '.m4a',
  '.aac',
  '.ogg',
  '.oga',
  '.opus',
  '.wav',
  '.wma',
  '.aiff',
  '.aif',
  '.alac',
  '.mp4',
  '.m4b',
};

/// The files worth opening out of a command line.
///
/// Everything else is dropped: the argument list also carries Flutter's own
/// switches, and a file manager can pass a `file://` URI rather than a path.
List<String> openableFiles(Iterable<String> arguments) {
  final files = <String>[];
  for (final argument in arguments) {
    final path = _asPath(argument);
    if (path == null) continue;
    if (!openableExtensions.contains(p.extension(path).toLowerCase())) continue;
    files.add(path);
  }
  return files;
}

String? _asPath(String argument) {
  if (argument.startsWith('--')) return null;
  if (argument.startsWith('file://')) {
    final uri = Uri.tryParse(argument);
    if (uri == null) return null;
    try {
      return uri.toFilePath();
    } on UnsupportedError {
      return null;
    }
  }
  // Any other URI scheme is somebody else's business.
  if (RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(argument)) return null;
  return argument;
}

/// Holds the "I am the running copy" claim, and receives files from later
/// launches.
class SingleInstance {
  SingleInstance._(this._server, this._tokenFile) {
    _server?.listen(_accept, onError: (_) {});
  }

  /// Null when the claim is degraded: the port is held by something that is not
  /// this app, so no files can be received, but the app still runs.
  final ServerSocket? _server;
  final File _tokenFile;

  final _opened = StreamController<List<String>>.broadcast();

  /// Files a later launch asked this instance to play.
  Stream<List<String>> get opened => _opened.stream;

  /// Loopback only, so nothing off the machine can reach it. Fixed, because the
  /// second copy has to find it without being told.
  static const port = 47821;

  /// More than this in one message is not a person opening files.
  static const _maxFiles = 512;

  /// Claims the single-instance slot.
  ///
  /// Returns the claim when this process is the one that should run. Returns
  /// null when another copy already holds it — in that case [arguments]' files
  /// have been handed over and this process should exit.
  ///
  /// Never throws: if any of this fails the app still has to start, and the
  /// worst case is two windows.
  static Future<SingleInstance?> claim(
    List<String> arguments, {
    required String stateDirectory,
  }) async {
    final tokenFile = File(p.join(stateDirectory, 'instance.token'));
    try {
      final server = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        port,
      );
      // We are first. Write the shared secret before anyone can connect.
      await _writeToken(tokenFile, _newToken());
      return SingleInstance._(server, tokenFile);
    } on SocketException {
      // Someone holds the port. Hand over the files and let them raise their
      // window.
      final handed = await _handOver(
        openableFiles(arguments),
        tokenFile: tokenFile,
      );
      if (handed) return null;

      // Nobody answered. Either the port belongs to some other program, or a
      // previous copy died without closing it. Starting a second player is the
      // lesser evil compared with an app that silently refuses to open, so this
      // process runs — it just cannot be handed files.
      return SingleInstance._(null, tokenFile);
    }
  }

  /// Whether this instance can receive files from later launches.
  bool get canReceive => _server != null;

  Future<void> _accept(Socket socket) async {
    try {
      final text = await socket
          .cast<List<int>>()
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 5));
      final files = _filesFrom(text, expected: await _readToken(_tokenFile));
      if (files.isNotEmpty) _opened.add(files);
    } catch (_) {
      // A malformed or truncated message is not worth reporting.
    } finally {
      socket.destroy();
    }
  }

  /// Reads one hand-over message.
  ///
  /// Public for testing, and separate from the socket so the parsing can be
  /// checked without one. The token is what stops another user on the machine
  /// from making this app open arbitrary paths.
  static List<String> filesFromMessage(String text, {required String expected}) =>
      _filesFrom(text, expected: expected);

  static List<String> _filesFrom(String text, {required String expected}) {
    if (expected.isEmpty) return const [];
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      return const [];
    }
    if (decoded is! Map) return const [];
    if (decoded['token'] != expected) return const [];

    final files = decoded['files'];
    if (files is! List) return const [];
    return [
      for (final file in files.take(_maxFiles))
        if (file is String &&
            openableExtensions.contains(p.extension(file).toLowerCase()))
          file,
    ];
  }

  static Future<bool> _handOver(
    List<String> files, {
    required File tokenFile,
  }) async {
    final token = await _readToken(tokenFile);
    if (token.isEmpty) return false;
    try {
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        port,
        timeout: const Duration(seconds: 3),
      );
      socket.write(jsonEncode({'token': token, 'files': files}));
      await socket.flush();
      await socket.close();
      socket.destroy();
      return true;
    } on SocketException {
      return false;
    } on TimeoutException {
      return false;
    }
  }

  static String _newToken() {
    final random = Random.secure();
    return List.generate(
      32,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  static Future<void> _writeToken(File file, String token) async {
    await file.parent.create(recursive: true);
    await file.writeAsString(token, flush: true);
    // Readable only by this user: it is what authorises handing us file paths.
    if (!Platform.isWindows) {
      await Process.run('chmod', ['600', file.path], runInShell: false);
    }
  }

  static Future<String> _readToken(File file) async {
    try {
      return (await file.readAsString()).trim();
    } on FileSystemException {
      return '';
    }
  }

  Future<void> dispose() async {
    await _opened.close();
    await _server?.close();
  }
}
