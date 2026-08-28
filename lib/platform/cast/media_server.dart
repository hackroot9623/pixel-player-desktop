import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

// A small HTTP server, so a speaker on the network can fetch the music.
//
// Neither Chromecast nor a DLNA renderer can read a local file: they are given a
// URL and fetch it themselves. So casting means serving the track from this
// machine for as long as it plays.
//
// Only files that have been explicitly published are reachable, each under an
// unguessable id. There is no path in the URL to traverse, which is the whole
// reason it is built this way rather than rooting a directory.

/// A byte range asked for by a client, resolved against a known length.
class ByteRange {
  const ByteRange(this.start, this.end);

  final int start;

  /// Inclusive, as HTTP defines it.
  final int end;

  int get length => end - start + 1;
}

/// Parses a `Range` header. Null when absent, malformed, or unsatisfiable.
///
/// Renderers rely on this: a DLNA device typically asks for `bytes=0-` first and
/// then seeks by asking for a later offset, and one that gets the whole file back
/// for a ranged request will often just stop.
ByteRange? parseRange(String? header, int fileLength) {
  if (header == null || fileLength <= 0) return null;
  final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(header.trim());
  if (match == null) return null;

  final startText = match.group(1)!;
  final endText = match.group(2)!;
  if (startText.isEmpty && endText.isEmpty) return null;

  if (startText.isEmpty) {
    // A suffix range: the last N bytes.
    final suffix = int.parse(endText);
    if (suffix <= 0) return null;
    final start = suffix >= fileLength ? 0 : fileLength - suffix;
    return ByteRange(start, fileLength - 1);
  }

  final start = int.parse(startText);
  if (start >= fileLength) return null;
  final end = endText.isEmpty
      ? fileLength - 1
      : min(int.parse(endText), fileLength - 1);
  if (end < start) return null;
  return ByteRange(start, end);
}

/// The MIME type for a file, from its extension.
///
/// Renderers are fussy: several will refuse a track served as
/// `application/octet-stream` even though they can decode it perfectly.
String contentTypeFor(String path) => switch (p.extension(path).toLowerCase()) {
  '.mp3' => 'audio/mpeg',
  '.flac' => 'audio/flac',
  '.m4a' || '.m4b' || '.mp4' => 'audio/mp4',
  '.aac' => 'audio/aac',
  '.ogg' || '.oga' => 'audio/ogg',
  '.opus' => 'audio/opus',
  '.wav' => 'audio/wav',
  '.wma' => 'audio/x-ms-wma',
  '.aiff' || '.aif' => 'audio/aiff',
  _ => 'audio/mpeg',
};

/// Chooses the address to advertise to a device.
///
/// The machine may be on several networks — a VPN, docker, a second NIC — and
/// only an address on the device's own subnet is reachable from it. Pure, so the
/// choice can be tested without a network.
String? pickLocalAddress(Iterable<String> candidates, String deviceAddress) {
  final wanted = _prefix(deviceAddress);
  String? fallback;
  for (final candidate in candidates) {
    if (candidate.startsWith('127.')) continue;
    fallback ??= candidate;
    if (wanted != null && _prefix(candidate) == wanted) return candidate;
  }
  return fallback;
}

String? _prefix(String address) {
  final parts = address.split('.');
  if (parts.length != 4) return null;
  return '${parts[0]}.${parts[1]}.${parts[2]}';
}

/// Serves published files to devices on the local network.
class LocalMediaServer {
  LocalMediaServer._(this._server) {
    _server.listen(_handle, onError: (_) {});
  }

  final HttpServer _server;

  /// id → file, for everything currently reachable.
  final _published = <String, File>{};

  int get port => _server.port;

  /// Binds on every interface, because the device fetching the file is not this
  /// machine. The port is whatever the system gives us.
  static Future<LocalMediaServer?> start() async {
    try {
      final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      // A renderer may take a moment between being told the URL and asking for
      // it; the default idle timeout would have closed by then.
      server.idleTimeout = const Duration(minutes: 5);
      return LocalMediaServer._(server);
    } on SocketException {
      return null;
    }
  }

  /// Makes [file] reachable and returns the path part of its URL.
  ///
  /// The id is random rather than derived from the path: a predictable URL would
  /// let anything on the network guess what else is being served.
  String publish(File file) {
    final id = _newId();
    _published[id] = file;
    // The extension is in the URL because some renderers decide what they can
    // play by looking at it rather than at the Content-Type.
    return '/media/$id${p.extension(file.path).toLowerCase()}';
  }

  /// The full URL for a published path, as [address] can reach it.
  String urlFor(String publishedPath, {required String address}) =>
      'http://$address:$port$publishedPath';

  /// Stops serving everything. Called when a cast session ends.
  void unpublishAll() => _published.clear();

  static final _random = Random.secure();

  static String _newId() => List.generate(
    16,
    (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    try {
      final id = _idFrom(request.uri.path);
      final file = id == null ? null : _published[id];

      if (file == null || !file.existsSync()) {
        response.statusCode = HttpStatus.notFound;
        await response.close();
        return;
      }
      if (request.method != 'GET' && request.method != 'HEAD') {
        response.statusCode = HttpStatus.methodNotAllowed;
        await response.close();
        return;
      }

      final length = file.lengthSync();
      final range = parseRange(request.headers.value('range'), length);

      response.headers.contentType = ContentType.parse(
        contentTypeFor(file.path),
      );
      response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      // DLNA renderers look for these two and some refuse to start without
      // them. Streaming mode, seekable by byte range.
      response.headers.set('transferMode.dlna.org', 'Streaming');
      response.headers.set(
        'contentFeatures.dlna.org',
        'DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS='
            '01700000000000000000000000000000',
      );

      if (request.headers.value('range') != null && range == null) {
        // Asked for something that is not there: say so properly rather than
        // sending the whole file, which confuses a seeking renderer.
        response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        response.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$length');
        await response.close();
        return;
      }

      if (range != null) {
        response.statusCode = HttpStatus.partialContent;
        response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes ${range.start}-${range.end}/$length',
        );
        response.contentLength = range.length;
      } else {
        response.contentLength = length;
      }

      if (request.method == 'HEAD') {
        await response.close();
        return;
      }

      await response.addStream(
        range == null
            ? file.openRead()
            : file.openRead(range.start, range.end + 1),
      );
      await response.close();
    } catch (_) {
      // A renderer that hangs up mid-track is normal — it happens on every
      // skip — and must not be reported as a failure.
      try {
        await response.close();
      } catch (_) {}
    }
  }

  /// The id out of `/media/<id>.<ext>`, or null for anything else.
  static String? _idFrom(String path) {
    final match = RegExp(r'^/media/([0-9a-f]{32})(\.[a-z0-9]+)?$')
        .firstMatch(path);
    return match?.group(1);
  }

  Future<void> dispose() async {
    _published.clear();
    await _server.close(force: true);
  }
}

/// Every IPv4 address this machine has, loopback last.
Future<List<String>> localAddresses() async {
  try {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    );
    return [
      for (final interface in interfaces)
        for (final address in interface.addresses) address.address,
    ];
  } on SocketException {
    return const [];
  }
}
