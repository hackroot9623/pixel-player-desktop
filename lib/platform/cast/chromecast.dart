import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:multicast_dns/multicast_dns.dart';

import '../../data/models/models.dart';
import 'dlna.dart' show CastException;

// Chromecast, over CASTV2.
//
// The protocol is length-prefixed protobuf carrying JSON. That sounds worse than
// it is: the one message type has six fields, four of them strings, so it is
// encoded by hand here rather than pulling in a protobuf compiler and a
// generated file for 40 bytes of wire format.
//
// The conversation is fixed: connect, launch the default media receiver, connect
// again to the session it gives back, then LOAD a URL. Heartbeats have to keep
// flowing or the device hangs up after about eight seconds.
//
// The TLS certificate is self-signed and device-specific, so it cannot be
// verified — which is also why nothing secret is ever sent over this socket. The
// only thing on it is "play this URL on my LAN".

/// The Default Media Receiver: Google's own, no developer registration needed.
const defaultReceiverAppId = 'CC1AD845';

const _namespaceConnection = 'urn:x-cast:com.google.cast.tp.connection';
const _namespaceHeartbeat = 'urn:x-cast:com.google.cast.tp.heartbeat';
const _namespaceReceiver = 'urn:x-cast:com.google.cast.receiver';
const _namespaceMedia = 'urn:x-cast:com.google.cast.media';

const _sourceId = 'sender-pixelplayer';
const _platformReceiver = 'receiver-0';

/// One Cast device on the network.
class CastDevice {
  const CastDevice({
    required this.name,
    required this.address,
    this.port = 8009,
  });

  final String name;
  final String address;
  final int port;
}

/// One CASTV2 message.
class CastMessage {
  const CastMessage({
    required this.namespace,
    required this.payload,
    this.sourceId = _sourceId,
    this.destinationId = _platformReceiver,
  });

  final String namespace;
  final String payload;
  final String sourceId;
  final String destinationId;

  Map<String, Object?> get json {
    final decoded = jsonDecode(payload);
    return decoded is Map<String, Object?> ? decoded : const {};
  }
}

// ---------------------------------------------------------------- protobuf
//
// CastMessage, from Google's cast_channel.proto:
//   1 protocol_version (enum), 2 source_id, 3 destination_id, 4 namespace,
//   5 payload_type (enum), 6 payload_utf8.
// Hand-encoded: six fields, and a code generator would be more moving parts than
// the format it generates.

void _writeVarint(BytesBuilder out, int value) {
  var remaining = value;
  while (remaining >= 0x80) {
    out.addByte((remaining & 0x7f) | 0x80);
    remaining >>= 7;
  }
  out.addByte(remaining);
}

void _writeString(BytesBuilder out, int field, String value) {
  final bytes = utf8.encode(value);
  _writeVarint(out, (field << 3) | 2);
  _writeVarint(out, bytes.length);
  out.add(bytes);
}

void _writeEnum(BytesBuilder out, int field, int value) {
  _writeVarint(out, field << 3);
  _writeVarint(out, value);
}

/// Encodes a message, with the four-byte big-endian length CASTV2 frames with.
Uint8List encodeCastFrame(CastMessage message) {
  final body = BytesBuilder();
  _writeEnum(body, 1, 0); // CASTV2_1_0
  _writeString(body, 2, message.sourceId);
  _writeString(body, 3, message.destinationId);
  _writeString(body, 4, message.namespace);
  _writeEnum(body, 5, 0); // payload_type STRING
  _writeString(body, 6, message.payload);

  final payload = body.toBytes();
  final frame = BytesBuilder();
  frame.add([
    (payload.length >> 24) & 0xff,
    (payload.length >> 16) & 0xff,
    (payload.length >> 8) & 0xff,
    payload.length & 0xff,
  ]);
  frame.add(payload);
  return frame.toBytes();
}

/// Decodes one message body — the frame's length prefix already removed.
///
/// Unknown fields are skipped rather than treated as an error: the device sends
/// fields this app does not care about, and a stricter parser would break on the
/// next firmware update.
CastMessage? decodeCastMessage(List<int> body) {
  var offset = 0;

  int readVarint() {
    var result = 0;
    var shift = 0;
    while (offset < body.length) {
      final byte = body[offset++];
      result |= (byte & 0x7f) << shift;
      if (byte & 0x80 == 0) return result;
      shift += 7;
    }
    throw const FormatException('truncated varint');
  }

  var source = '';
  var destination = '';
  var namespace = '';
  var payload = '';

  try {
    while (offset < body.length) {
      final tag = readVarint();
      final field = tag >> 3;
      final wireType = tag & 0x7;

      if (wireType == 0) {
        readVarint();
        continue;
      }
      if (wireType != 2) return null; // Nothing else appears in this message.

      final length = readVarint();
      if (offset + length > body.length) return null;
      final value = utf8.decode(
        body.sublist(offset, offset + length),
        allowMalformed: true,
      );
      offset += length;

      switch (field) {
        case 2:
          source = value;
        case 3:
          destination = value;
        case 4:
          namespace = value;
        case 6:
          payload = value;
      }
    }
  } on FormatException {
    return null;
  }

  if (namespace.isEmpty) return null;
  return CastMessage(
    namespace: namespace,
    payload: payload.isEmpty ? '{}' : payload,
    sourceId: source,
    destinationId: destination,
  );
}

/// Splits a byte stream into frames, keeping whatever is left over.
///
/// TCP does not preserve message boundaries, so a frame can arrive in pieces or
/// two can arrive together. Pure and stateful-by-return so it can be tested with
/// deliberately awkward splits.
class CastFrameReader {
  final _buffer = BytesBuilder();

  List<CastMessage> add(List<int> chunk) {
    _buffer.add(chunk);
    var bytes = _buffer.toBytes();
    final messages = <CastMessage>[];

    while (bytes.length >= 4) {
      final length =
          (bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3];
      // A length this large is a desynchronised stream, not a real frame.
      if (length < 0 || length > 1 << 22) {
        _buffer.clear();
        return messages;
      }
      if (bytes.length < 4 + length) break;

      final message = decodeCastMessage(bytes.sublist(4, 4 + length));
      if (message != null) messages.add(message);
      bytes = Uint8List.sublistView(bytes, 4 + length);
    }

    _buffer.clear();
    _buffer.add(bytes);
    return messages;
  }
}

// ----------------------------------------------------------------- payloads

/// The LOAD payload for one track.
///
/// Kept separate and pure because the metadata shape is the part devices are
/// picky about: metadataType 3 is music, and without contentType many will
/// refuse the stream outright.
Map<String, Object?> loadPayload({
  required String url,
  required Song song,
  required String mimeType,
  int requestId = 1,
}) => {
  'requestId': requestId,
  'type': 'LOAD',
  'autoplay': true,
  'currentTime': 0,
  'media': {
    'contentId': url,
    'contentType': mimeType,
    // BUFFERED, not LIVE: the device may seek within it.
    'streamType': 'BUFFERED',
    if (song.duration > 0) 'duration': song.duration / 1000,
    'metadata': {
      'metadataType': 3,
      'title': song.title,
      'artist': song.displayArtist,
      'albumName': song.album,
    },
  },
};

/// Finds Cast devices with mDNS.
Future<List<CastDevice>> discoverCastDevices({
  Duration timeout = const Duration(seconds: 4),
}) async {
  final client = MDnsClient();
  final devices = <String, CastDevice>{};
  try {
    await client.start();
    const service = '_googlecast._tcp.local';

    await for (final ptr
        in client
            .lookup<PtrResourceRecord>(
              ResourceRecordQuery.serverPointer(service),
            )
            .timeout(timeout, onTimeout: (sink) => sink.close())) {
      await for (final srv
          in client
              .lookup<SrvResourceRecord>(
                ResourceRecordQuery.service(ptr.domainName),
              )
              .timeout(
                const Duration(seconds: 2),
                onTimeout: (sink) => sink.close(),
              )) {
        await for (final ip
            in client
                .lookup<IPAddressResourceRecord>(
                  ResourceRecordQuery.addressIPv4(srv.target),
                )
                .timeout(
                  const Duration(seconds: 2),
                  onTimeout: (sink) => sink.close(),
                )) {
          devices[ip.address.address] = CastDevice(
            name: castNameFrom(ptr.domainName),
            address: ip.address.address,
            port: srv.port,
          );
        }
      }
    }
  } catch (_) {
    // mDNS blocked, or no network. Nothing to report.
  } finally {
    client.stop();
  }
  return devices.values.toList();
}

/// A readable name out of an mDNS instance name.
///
/// They look like `Living Room-1a2b3c._googlecast._tcp.local`, and the hex suffix
/// is noise to a person.
String castNameFrom(String domainName) {
  var name = domainName.split('.').first;
  final dash = name.lastIndexOf('-');
  if (dash > 0 && RegExp(r'^[0-9a-f]{6,}$').hasMatch(name.substring(dash + 1))) {
    name = name.substring(0, dash);
  }
  return name.replaceAll('\\032', ' ').trim();
}

/// A live connection to one Cast device.
class CastSession {
  CastSession._(this.device, this._socket) {
    _socket.listen(_onData, onError: (_) => _closed(), onDone: _closed);
  }

  final CastDevice device;
  final SecureSocket _socket;
  final _reader = CastFrameReader();

  Timer? _heartbeat;
  String? _transportId;
  int? _mediaSessionId;
  int _requestId = 1;

  final _statuses = StreamController<Map<String, Object?>>.broadcast();

  /// Media status messages as they arrive, for noticing a finished track.
  Stream<Map<String, Object?>> get statuses => _statuses.stream;

  bool get connected => _transportId != null;

  /// Connects and launches the media receiver.
  static Future<CastSession> connect(CastDevice device) async {
    final SecureSocket socket;
    try {
      socket = await SecureSocket.connect(
        device.address,
        device.port,
        // Self-signed and device-specific: there is no chain to check it
        // against. Nothing confidential goes over this socket for that reason.
        onBadCertificate: (_) => true,
        timeout: const Duration(seconds: 8),
      );
    } on SocketException catch (error) {
      throw CastException(
        'Could not reach ${device.name}. ${error.osError?.message ?? ''}'.trim(),
      );
    } on HandshakeException {
      throw CastException('${device.name} refused the connection.');
    } on TimeoutException {
      throw CastException('${device.name} did not answer.');
    }

    final session = CastSession._(device, socket);
    await session._handshake();
    return session;
  }

  Future<void> _handshake() async {
    _send(_namespaceConnection, {'type': 'CONNECT'});
    // Every five seconds: the device hangs up after roughly eight without one.
    _heartbeat = Timer.periodic(const Duration(seconds: 5), (_) {
      _send(_namespaceHeartbeat, {'type': 'PING'});
    });
    _send(_namespaceHeartbeat, {'type': 'PING'});

    _send(_namespaceReceiver, {
      'requestId': _nextRequestId(),
      'type': 'LAUNCH',
      'appId': defaultReceiverAppId,
    });

    // Wait for the receiver to report the session it launched.
    final deadline = DateTime.now().add(const Duration(seconds: 12));
    while (_transportId == null && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (_transportId == null) {
      await dispose();
      throw CastException(
        '${device.name} did not start its media receiver. Another app may be '
        'casting to it.',
      );
    }
  }

  int _nextRequestId() => ++_requestId;

  void _send(
    String namespace,
    Map<String, Object?> payload, {
    String? destination,
  }) {
    if (_socket.remoteAddress.address.isEmpty) return;
    try {
      _socket.add(
        encodeCastFrame(
          CastMessage(
            namespace: namespace,
            payload: jsonEncode(payload),
            destinationId: destination ?? _platformReceiver,
          ),
        ),
      );
    } catch (_) {
      // A closed socket surfaces through onDone; nothing useful to do here.
    }
  }

  void _onData(List<int> chunk) {
    for (final message in _reader.add(chunk)) {
      switch (message.namespace) {
        case _namespaceHeartbeat:
          // PING from the device wants a PONG, or it assumes we died.
          if (message.json['type'] == 'PING') {
            _send(_namespaceHeartbeat, {'type': 'PONG'});
          }
        case _namespaceReceiver:
          _onReceiverStatus(message.json);
        case _namespaceMedia:
          _onMediaStatus(message.json);
      }
    }
  }

  void _onReceiverStatus(Map<String, Object?> payload) {
    if (payload['type'] != 'RECEIVER_STATUS') return;
    final applications =
        ((payload['status'] as Map?)?['applications'] as List?) ?? const [];
    for (final application in applications) {
      if (application is! Map) continue;
      if (application['appId'] != defaultReceiverAppId) continue;
      final transport = application['transportId'];
      if (transport is! String || transport == _transportId) continue;
      _transportId = transport;
      // A second CONNECT, this time to the app rather than the platform.
      _send(_namespaceConnection, {'type': 'CONNECT'}, destination: transport);
    }
  }

  void _onMediaStatus(Map<String, Object?> payload) {
    final statuses = payload['status'];
    if (statuses is! List) return;
    for (final status in statuses) {
      if (status is! Map<String, Object?>) continue;
      final id = status['mediaSessionId'];
      if (id is int) _mediaSessionId = id;
      _statuses.add(status);
    }
  }

  /// Plays a URL.
  Future<void> load(
    String url, {
    required Song song,
    required String mimeType,
  }) async {
    final transport = _transportId;
    if (transport == null) {
      throw CastException('Not connected to ${device.name}.');
    }
    _send(
      _namespaceMedia,
      loadPayload(
        url: url,
        song: song,
        mimeType: mimeType,
        requestId: _nextRequestId(),
      ),
      destination: transport,
    );
  }

  void _mediaCommand(String type, [Map<String, Object?> extra = const {}]) {
    final transport = _transportId;
    final session = _mediaSessionId;
    if (transport == null || session == null) return;
    _send(_namespaceMedia, {
      'requestId': _nextRequestId(),
      'type': type,
      'mediaSessionId': session,
      ...extra,
    }, destination: transport);
  }

  void resume() => _mediaCommand('PLAY');

  void pause() => _mediaCommand('PAUSE');

  void stop() => _mediaCommand('STOP');

  void seek(Duration position) =>
      _mediaCommand('SEEK', {'currentTime': position.inMilliseconds / 1000});

  void requestStatus() => _mediaCommand('GET_STATUS');

  /// 0..100, sent to the device rather than the media session.
  void setVolume(int percent) => _send(_namespaceReceiver, {
    'requestId': _nextRequestId(),
    'type': 'SET_VOLUME',
    'volume': {'level': percent.clamp(0, 100) / 100},
  });

  void _closed() {
    _heartbeat?.cancel();
    _heartbeat = null;
    _transportId = null;
    if (!_statuses.isClosed) _statuses.close();
  }

  Future<void> dispose() async {
    _heartbeat?.cancel();
    _heartbeat = null;
    try {
      _send(_namespaceConnection, {'type': 'CLOSE'});
      await _socket.flush();
    } catch (_) {
      // Already gone.
    }
    _transportId = null;
    if (!_statuses.isClosed) await _statuses.close();
    await _socket.close();
  }
}

/// Whether a media status means the track played to its end.
///
/// The device reports IDLE for a dozen reasons; only FINISHED means "play the
/// next one".
bool castTrackFinished(Map<String, Object?> status) =>
    status['playerState'] == 'IDLE' && status['idleReason'] == 'FINISHED';
