import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:xml/xml.dart';

import '../../data/models/models.dart';

// DLNA / UPnP AV: the open way to push audio at a speaker.
//
// Three steps, none of them hard on their own. SSDP is a UDP multicast question
// ("who here is a MediaRenderer?"); the answers point at an XML description; the
// description names a control URL that takes SOAP. After that, playing something
// is SetAVTransportURI followed by Play.
//
// The awkward part is that renderers are inconsistent about what they accept, so
// the metadata is sent in the DIDL-Lite form the widest range of them
// understands, and every reply is parsed defensively rather than assumed.

const _ssdpAddress = '239.255.255.250';
const _ssdpPort = 1900;

const _avTransport = 'urn:schemas-upnp-org:service:AVTransport:1';
const _renderingControl = 'urn:schemas-upnp-org:service:RenderingControl:1';

/// A renderer found on the network.
class DlnaDevice {
  const DlnaDevice({
    required this.name,
    required this.address,
    required this.controlUrl,
    this.volumeControlUrl,
  });

  final String name;

  /// The device's IP, used to choose which of our own addresses to advertise.
  final String address;

  /// Where AVTransport actions are sent.
  final Uri controlUrl;

  /// Where volume actions are sent, when the device offers RenderingControl.
  final Uri? volumeControlUrl;

  bool get canSetVolume => volumeControlUrl != null;
}

/// What a renderer says it is doing.
enum DlnaState {
  playing,
  paused,
  stopped,
  transitioning,
  unknown;

  static DlnaState fromWire(String? value) => switch (value?.toUpperCase()) {
    'PLAYING' => playing,
    'PAUSED_PLAYBACK' || 'PAUSED_RECORDING' => paused,
    'STOPPED' || 'NO_MEDIA_PRESENT' => stopped,
    'TRANSITIONING' => transitioning,
    _ => unknown,
  };
}

/// The `LOCATION` of one SSDP reply, or null when it is not a usable answer.
///
/// Pure: SSDP replies are plain text, and every real-world oddity — lowercase
/// headers, missing fields, other people's announcements — shows up here.
String? ssdpLocation(String response) {
  String? location;
  var isRenderer = false;
  for (final line in const LineSplitter().convert(response)) {
    final colon = line.indexOf(':');
    if (colon <= 0) continue;
    final key = line.substring(0, colon).trim().toLowerCase();
    final value = line.substring(colon + 1).trim();
    switch (key) {
      case 'location':
        location = value;
      case 'st' || 'nt':
        // Accept both the renderer type and the root device: some devices only
        // answer to the latter and still expose AVTransport.
        isRenderer =
            value.contains('MediaRenderer') || value.contains('device:');
    }
  }
  return isRenderer ? location : null;
}

/// Reads a device description into a [DlnaDevice].
///
/// Control URLs are relative in most descriptions, so [base] is where they are
/// resolved from. Returns null when there is no AVTransport service, which is
/// how a NAS or a router announcing itself gets filtered out.
DlnaDevice? parseDeviceDescription(String xml, Uri base) {
  final XmlDocument document;
  try {
    document = XmlDocument.parse(xml);
  } on XmlException {
    return null;
  }

  Uri? controlFor(String serviceType) {
    for (final service in document.findAllElements('service')) {
      final type = service.getElement('serviceType')?.innerText.trim();
      if (type != serviceType) continue;
      final control = service.getElement('controlURL')?.innerText.trim();
      if (control == null || control.isEmpty) continue;
      return base.resolve(control);
    }
    return null;
  }

  final transport = controlFor(_avTransport);
  if (transport == null) return null;

  return DlnaDevice(
    name:
        document.findAllElements('friendlyName').firstOrNull?.innerText.trim() ??
        base.host,
    address: base.host,
    controlUrl: transport,
    volumeControlUrl: controlFor(_renderingControl),
  );
}

/// The DIDL-Lite blob that describes one track.
///
/// Several renderers will play nothing without it, and several others will
/// refuse it if the XML is not escaped — it travels inside another XML document,
/// so it is escaped twice by the time it is on the wire.
String didlMetadata({
  required String url,
  required String title,
  required String artist,
  required String album,
  required String mimeType,
  int durationMs = 0,
}) {
  final duration = _upnpDuration(durationMs);
  final didl =
      '<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" '
      'xmlns:dc="http://purl.org/dc/elements/1.1/" '
      'xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">'
      '<item id="0" parentID="-1" restricted="1">'
      '<dc:title>${_escape(title)}</dc:title>'
      '<upnp:artist>${_escape(artist)}</upnp:artist>'
      '<upnp:album>${_escape(album)}</upnp:album>'
      '<upnp:class>object.item.audioItem.musicTrack</upnp:class>'
      '<res protocolInfo="http-get:*:$mimeType:'
      'DLNA.ORG_OP=01;DLNA.ORG_CI=0"'
      '${duration == null ? '' : ' duration="$duration"'}>'
      '${_escape(url)}</res>'
      '</item>'
      '</DIDL-Lite>';
  return didl;
}

/// `H:MM:SS` as UPnP wants it, or null when the length is unknown.
String? _upnpDuration(int milliseconds) {
  if (milliseconds <= 0) return null;
  final total = Duration(milliseconds: milliseconds);
  final minutes = total.inMinutes % 60;
  final seconds = total.inSeconds % 60;
  return '${total.inHours}:${_two(minutes)}:${_two(seconds)}';
}

String _two(int value) => value.toString().padLeft(2, '0');

String _escape(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

/// Wraps one action in a SOAP envelope.
String soapEnvelope(
  String service,
  String action,
  Map<String, String> arguments,
) {
  final body = arguments.entries
      .map((e) => '<${e.key}>${_escape(e.value)}</${e.key}>')
      .join();
  return '<?xml version="1.0" encoding="utf-8"?>'
      '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
      's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
      '<s:Body><u:$action xmlns:u="$service">$body</u:$action></s:Body>'
      '</s:Envelope>';
}

/// Pulls one element's text out of a SOAP reply.
String? soapValue(String xml, String element) {
  try {
    return XmlDocument.parse(xml)
        .findAllElements(element)
        .firstOrNull
        ?.innerText
        .trim();
  } on XmlException {
    return null;
  }
}

/// `H:MM:SS` back into a Duration. Renderers also send `0:00:00.000`.
Duration parseUpnpTime(String? value) {
  if (value == null) return Duration.zero;
  final parts = value.split(':');
  if (parts.length != 3) return Duration.zero;
  final seconds = double.tryParse(parts[2]) ?? 0;
  return Duration(
    hours: int.tryParse(parts[0]) ?? 0,
    minutes: int.tryParse(parts[1]) ?? 0,
    milliseconds: (seconds * 1000).round(),
  );
}

/// Asks the network which renderers are listening.
///
/// Sends the M-SEARCH more than once: SSDP is UDP, and a single datagram going
/// missing is normal rather than exceptional.
Future<List<DlnaDevice>> discoverDlnaRenderers({
  Duration timeout = const Duration(seconds: 4),
  HttpClient? httpClient,
}) async {
  final found = <String, DlnaDevice>{};
  final locations = <String>{};
  RawDatagramSocket? socket;

  try {
    socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    socket.broadcastEnabled = true;

    final search =
        'M-SEARCH * HTTP/1.1\r\n'
        'HOST: $_ssdpAddress:$_ssdpPort\r\n'
        'MAN: "ssdp:discover"\r\n'
        'MX: 2\r\n'
        'ST: $_avTransport\r\n\r\n';
    final rootSearch = search.replaceFirst(
      'ST: $_avTransport',
      'ST: urn:schemas-upnp-org:device:MediaRenderer:1',
    );

    final target = InternetAddress(_ssdpAddress);
    for (final message in [search, rootSearch]) {
      socket.send(utf8.encode(message), target, _ssdpPort);
    }

    final done = Completer<void>();
    socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final datagram = socket!.receive();
      if (datagram == null) return;
      final location = ssdpLocation(utf8.decode(datagram.data, allowMalformed: true));
      if (location != null) locations.add(location);
    }, onDone: () => done.complete());

    await Future<void>.delayed(timeout);
  } on SocketException {
    // No network, or multicast is blocked. An empty list is the honest answer.
    return const [];
  } finally {
    socket?.close();
  }

  // Descriptions are fetched after listening rather than during, so a slow
  // device cannot eat the discovery window.
  final http = httpClient ?? HttpClient();
  try {
    for (final location in locations) {
      final uri = Uri.tryParse(location);
      if (uri == null) continue;
      try {
        final request = await http.getUrl(uri);
        final response = await request.close().timeout(
          const Duration(seconds: 4),
        );
        final xml = await response.transform(utf8.decoder).join();
        final device = parseDeviceDescription(xml, uri);
        if (device != null) found[device.controlUrl.toString()] = device;
      } catch (_) {
        // A device that announced itself and then would not describe itself is
        // no use, and there is nothing to tell the user about it.
      }
    }
  } finally {
    if (httpClient == null) http.close(force: true);
  }

  return found.values.toList();
}

/// Drives one renderer.
class DlnaSession {
  DlnaSession(this.device, {HttpClient? httpClient})
    : _http = httpClient ?? HttpClient();

  final DlnaDevice device;
  final HttpClient _http;

  /// Hands the renderer a URL and starts it.
  Future<void> play(
    String url, {
    required Song song,
    required String mimeType,
  }) async {
    await _action(device.controlUrl, _avTransport, 'SetAVTransportURI', {
      'InstanceID': '0',
      'CurrentURI': url,
      'CurrentURIMetaData': didlMetadata(
        url: url,
        title: song.title,
        artist: song.displayArtist,
        album: song.album,
        mimeType: mimeType,
        durationMs: song.duration,
      ),
    });
    await resume();
  }

  Future<void> resume() =>
      _action(device.controlUrl, _avTransport, 'Play', {
        'InstanceID': '0',
        'Speed': '1',
      });

  Future<void> pause() =>
      _action(device.controlUrl, _avTransport, 'Pause', {'InstanceID': '0'});

  Future<void> stop() =>
      _action(device.controlUrl, _avTransport, 'Stop', {'InstanceID': '0'});

  Future<void> seek(Duration position) =>
      _action(device.controlUrl, _avTransport, 'Seek', {
        'InstanceID': '0',
        'Unit': 'REL_TIME',
        'Target': _upnpDuration(position.inMilliseconds) ?? '0:00:00',
      });

  /// 0..100. Silently does nothing on a renderer without RenderingControl.
  Future<void> setVolume(int percent) async {
    final url = device.volumeControlUrl;
    if (url == null) return;
    await _action(url, _renderingControl, 'SetVolume', {
      'InstanceID': '0',
      'Channel': 'Master',
      'DesiredVolume': '${percent.clamp(0, 100)}',
    });
  }

  /// What the renderer is doing, for noticing that a track ended.
  Future<DlnaState> state() async {
    final reply = await _action(
      device.controlUrl,
      _avTransport,
      'GetTransportInfo',
      {'InstanceID': '0'},
    );
    return DlnaState.fromWire(soapValue(reply, 'CurrentTransportState'));
  }

  /// How far into the track the renderer is.
  Future<Duration> position() async {
    final reply = await _action(
      device.controlUrl,
      _avTransport,
      'GetPositionInfo',
      {'InstanceID': '0'},
    );
    return parseUpnpTime(soapValue(reply, 'RelTime'));
  }

  Future<String> _action(
    Uri url,
    String service,
    String action,
    Map<String, String> arguments,
  ) async {
    final request = await _http.postUrl(url);
    request.headers.set(
      HttpHeaders.contentTypeHeader,
      'text/xml; charset="utf-8"',
    );
    // The quotes are not optional: renderers reject an unquoted SOAPAction.
    request.headers.set('SOAPACTION', '"$service#$action"');
    request.headers.set(HttpHeaders.connectionHeader, 'close');
    request.write(soapEnvelope(service, action, arguments));

    final response = await request.close().timeout(
      const Duration(seconds: 10),
    );
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw CastException(
        _describeSoapFault(body, response.statusCode, device.name),
      );
    }
    return body;
  }

  void close() => _http.close(force: true);
}

/// Turns a UPnP fault into something worth reading.
String _describeSoapFault(String body, int status, String deviceName) {
  final code = soapValue(body, 'errorCode');
  final description = soapValue(body, 'errorDescription');
  return switch (code) {
    '701' => '$deviceName is not in a state where that works.',
    '714' => '$deviceName cannot play this file.',
    '716' => '$deviceName could not fetch the file from this computer.',
    '718' => '$deviceName rejected the track description.',
    _ =>
      description == null
          ? '$deviceName returned an error ($status).'
          : '$deviceName: $description',
  };
}

/// A failure worth showing the user.
class CastException implements Exception {
  const CastException(this.message);

  final String message;

  @override
  String toString() => message;
}
