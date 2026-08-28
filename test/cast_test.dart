import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pixelplay_desktop/data/models/models.dart';
import 'package:pixelplay_desktop/platform/cast/cast_controller.dart';
import 'package:pixelplay_desktop/platform/cast/chromecast.dart';
import 'package:pixelplay_desktop/platform/cast/dlna.dart';
import 'package:pixelplay_desktop/platform/cast/media_server.dart';

/// No speaker on the other end here, so what is tested is everything up to the
/// wire: the bytes a Chromecast would receive, the XML a renderer would receive,
/// and the HTTP a device would fetch — that last one for real, against the actual
/// server, because Range handling is where renderers silently give up.

Song _song({
  String title = 'Al Sudeste',
  String artist = 'Moneda Dura',
  String album = 'Sin Blasfemias',
  int duration = 249000,
  String path = '/music/a.mp3',
}) => Song(
  id: path,
  title: title,
  artist: artist,
  artistId: 1,
  album: album,
  albumId: 1,
  path: path,
  duration: duration,
);

void main() {
  group('byte ranges', () {
    test('an open-ended range runs to the end', () {
      final range = parseRange('bytes=100-', 1000)!;
      expect(range.start, 100);
      expect(range.end, 999);
      expect(range.length, 900);
    });

    test('a closed range is inclusive, as HTTP defines it', () {
      final range = parseRange('bytes=0-99', 1000)!;
      expect(range.length, 100);
    });

    test('a range past the end is clamped', () {
      expect(parseRange('bytes=900-5000', 1000)!.end, 999);
    });

    test('a suffix range asks for the last bytes', () {
      final range = parseRange('bytes=-200', 1000)!;
      expect(range.start, 800);
      expect(range.end, 999);
    });

    test('a suffix longer than the file is the whole file', () {
      expect(parseRange('bytes=-5000', 1000)!.start, 0);
    });

    test('an unsatisfiable or malformed range is refused', () {
      // Refused rather than silently treated as the whole file: a seeking
      // renderer that gets byte zero back tends to stop.
      expect(parseRange('bytes=1000-', 1000), isNull);
      expect(parseRange('bytes=500-100', 1000), isNull);
      expect(parseRange('bytes=-', 1000), isNull);
      expect(parseRange('items=0-10', 1000), isNull);
      expect(parseRange(null, 1000), isNull);
      expect(parseRange('bytes=0-10', 0), isNull);
    });
  });

  group('content types', () {
    test('the common formats get their real type', () {
      // Renderers refuse octet-stream even when they can decode the file.
      expect(contentTypeFor('/a.mp3'), 'audio/mpeg');
      expect(contentTypeFor('/a.flac'), 'audio/flac');
      expect(contentTypeFor('/a.m4a'), 'audio/mp4');
      expect(contentTypeFor('/a.OGG'), 'audio/ogg');
      expect(contentTypeFor('/a.opus'), 'audio/opus');
    });

    test('an unknown extension falls back to something playable', () {
      expect(contentTypeFor('/a.weird'), 'audio/mpeg');
    });
  });

  group('choosing an address to advertise', () {
    test('an address on the device\'s subnet wins', () {
      // The machine may also be on a VPN or a docker bridge, and only the
      // matching subnet is reachable from the speaker.
      expect(
        pickLocalAddress(
          ['172.17.0.1', '10.8.0.6', '192.168.1.40'],
          '192.168.1.77',
        ),
        '192.168.1.40',
      );
    });

    test('with no match, the first real address is offered', () {
      expect(
        pickLocalAddress(['10.8.0.6', '192.168.1.40'], '172.20.5.5'),
        '10.8.0.6',
      );
    });

    test('loopback is never advertised', () {
      // A speaker told 127.0.0.1 fetches from itself and plays nothing.
      expect(pickLocalAddress(['127.0.0.1'], '192.168.1.5'), isNull);
      expect(
        pickLocalAddress(['127.0.0.1', '192.168.1.40'], '192.168.1.5'),
        '192.168.1.40',
      );
    });

    test('no addresses at all yields nothing rather than a guess', () {
      expect(pickLocalAddress(const [], '192.168.1.5'), isNull);
    });
  });

  group('the media server', () {
    late Directory dir;
    late File file;
    late LocalMediaServer server;
    late HttpClient client;

    setUp(() async {
      dir = Directory.systemTemp.createTempSync('pixelplay-cast');
      file = File('${dir.path}/track.mp3')
        ..writeAsBytesSync(List.generate(1000, (i) => i % 256));
      server = (await LocalMediaServer.start())!;
      // One client for the group: closing it before the body has been read
      // aborts the response, which is a test bug rather than a server one.
      client = HttpClient();
    });

    tearDown(() async {
      client.close(force: true);
      await server.dispose();
      dir.deleteSync(recursive: true);
    });

    Future<HttpClientResponse> get(String path, {String? range}) async {
      final request = await client.getUrl(
        Uri.parse('http://127.0.0.1:${server.port}$path'),
      );
      if (range != null) request.headers.set('range', range);
      return request.close();
    }

    test('a published file is served whole', () async {
      final path = server.publish(file);
      final response = await get(path);

      expect(response.statusCode, HttpStatus.ok);
      expect(response.contentLength, 1000);
      expect(response.headers.value('accept-ranges'), 'bytes');
      expect(response.headers.contentType?.mimeType, 'audio/mpeg');
      expect(await response.fold<int>(0, (n, chunk) => n + chunk.length), 1000);
    });

    test('the DLNA headers renderers look for are present', () async {
      final response = await get(server.publish(file));
      expect(response.headers.value('transferMode.dlna.org'), 'Streaming');
      expect(
        response.headers.value('contentFeatures.dlna.org'),
        contains('DLNA.ORG_OP=01'),
      );
      await response.drain<void>();
    });

    test('a ranged request gets exactly that range', () async {
      final response = await get(server.publish(file), range: 'bytes=100-199');

      expect(response.statusCode, HttpStatus.partialContent);
      expect(response.headers.value('content-range'), 'bytes 100-199/1000');
      expect(response.contentLength, 100);

      final bytes = await response.fold<List<int>>(
        [],
        (all, chunk) => all..addAll(chunk),
      );
      expect(bytes, hasLength(100));
      // The right bytes, not just the right number of them.
      expect(bytes.first, 100 % 256);
    });

    test('an unsatisfiable range is answered 416', () async {
      final response = await get(server.publish(file), range: 'bytes=5000-');
      expect(response.statusCode, HttpStatus.requestedRangeNotSatisfiable);
      expect(response.headers.value('content-range'), 'bytes */1000');
      await response.drain<void>();
    });

    test('HEAD gets the headers and no body', () async {
      // Some renderers probe with HEAD before committing to the stream.
      final request = await client.headUrl(
        Uri.parse('http://127.0.0.1:${server.port}${server.publish(file)}'),
      );
      final response = await request.close();
      expect(response.statusCode, HttpStatus.ok);
      expect(response.contentLength, 1000);
      await response.drain<void>();
    });

    test('nothing unpublished is reachable', () async {
      // The URL carries no path, so there is nothing to traverse — the only way
      // in is an id that was handed out.
      for (final path in [
        '/media/${'a' * 32}.mp3',
        '/etc/passwd',
        '/media/../../etc/passwd',
      ]) {
        final response = await get(path);
        expect(response.statusCode, 404, reason: path);
        await response.drain<void>();
      }
    });

    test('stopping a session takes the files with it', () async {
      final path = server.publish(file);
      final before = await get(path);
      expect(before.statusCode, HttpStatus.ok);
      await before.drain<void>();

      server.unpublishAll();
      final after = await get(path);
      expect(after.statusCode, HttpStatus.notFound);
      await after.drain<void>();
    });

    test('two publishes of the same file get different URLs', () {
      // Predictable URLs would let anything on the network guess what else is
      // being served.
      expect(server.publish(file), isNot(server.publish(file)));
    });

    test('the URL keeps the extension, which some renderers rely on', () {
      expect(server.publish(file), endsWith('.mp3'));
    });
  });

  group('SSDP', () {
    String reply(String st, String location) =>
        'HTTP/1.1 200 OK\r\n'
        'CACHE-CONTROL: max-age=1800\r\n'
        'ST: $st\r\n'
        'LOCATION: $location\r\n\r\n';

    test('a renderer\'s location is taken', () {
      expect(
        ssdpLocation(
          reply(
            'urn:schemas-upnp-org:device:MediaRenderer:1',
            'http://192.168.1.5:8080/desc.xml',
          ),
        ),
        'http://192.168.1.5:8080/desc.xml',
      );
    });

    test('header case does not matter', () {
      // Real devices send every combination of these.
      expect(
        ssdpLocation(
          'HTTP/1.1 200 OK\r\n'
          'st: urn:schemas-upnp-org:device:MediaRenderer:1\r\n'
          'location: http://192.168.1.5/d.xml\r\n\r\n',
        ),
        'http://192.168.1.5/d.xml',
      );
    });

    test('something that is not a device is ignored', () {
      expect(
        ssdpLocation(reply('upnp:rootdevice-ish', 'http://192.168.1.5/d.xml')),
        isNull,
      );
    });

    test('a reply with no location yields nothing', () {
      expect(
        ssdpLocation(
          'HTTP/1.1 200 OK\r\nST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n\r\n',
        ),
        isNull,
      );
    });

    test('junk does not throw', () {
      expect(ssdpLocation(''), isNull);
      expect(ssdpLocation('nonsense'), isNull);
    });
  });

  group('device descriptions', () {
    const description = '''
<?xml version="1.0"?>
<root xmlns="urn:schemas-upnp-org:device-1-0">
  <device>
    <friendlyName>Kitchen Speaker</friendlyName>
    <serviceList>
      <service>
        <serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
        <controlURL>/AVTransport/control</controlURL>
      </service>
      <service>
        <serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType>
        <controlURL>/Rendering/control</controlURL>
      </service>
    </serviceList>
  </device>
</root>''';

    test('the name and both control URLs are read', () {
      final device = parseDeviceDescription(
        description,
        Uri.parse('http://192.168.1.5:8080/desc.xml'),
      )!;

      expect(device.name, 'Kitchen Speaker');
      expect(device.address, '192.168.1.5');
      // Relative in the XML, absolute by the time it is used.
      expect(
        device.controlUrl.toString(),
        'http://192.168.1.5:8080/AVTransport/control',
      );
      expect(device.canSetVolume, isTrue);
    });

    test('a device without AVTransport is not a renderer', () {
      // This is what filters out a NAS or a router announcing itself.
      const server = '''
<root><device><friendlyName>NAS</friendlyName><serviceList>
<service><serviceType>urn:schemas-upnp-org:service:ContentDirectory:1</serviceType>
<controlURL>/cd</controlURL></service></serviceList></device></root>''';
      expect(
        parseDeviceDescription(server, Uri.parse('http://192.168.1.9/d.xml')),
        isNull,
      );
    });

    test('a renderer with no volume service is still usable', () {
      const minimal = '''
<root><device><serviceList>
<service><serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
<controlURL>/ctl</controlURL></service></serviceList></device></root>''';
      final device = parseDeviceDescription(
        minimal,
        Uri.parse('http://192.168.1.9/d.xml'),
      )!;
      expect(device.canSetVolume, isFalse);
      // No friendlyName: the host is better than an empty row.
      expect(device.name, '192.168.1.9');
    });

    test('malformed XML is refused rather than thrown', () {
      expect(
        parseDeviceDescription('<root', Uri.parse('http://192.168.1.9/')),
        isNull,
      );
    });
  });

  group('SOAP and DIDL', () {
    test('an action is wrapped with its arguments in order', () {
      final envelope = soapEnvelope(
        'urn:schemas-upnp-org:service:AVTransport:1',
        'Play',
        {'InstanceID': '0', 'Speed': '1'},
      );
      expect(envelope, contains('<u:Play'));
      expect(envelope, contains('<InstanceID>0</InstanceID>'));
      expect(envelope, contains('<Speed>1</Speed>'));
      expect(envelope, contains('s:Envelope'));
    });

    test('arguments are escaped, so a URL with & survives', () {
      // A signed stream URL is full of ampersands, and an unescaped one makes
      // the whole envelope invalid XML.
      final envelope = soapEnvelope('svc', 'SetAVTransportURI', {
        'CurrentURI': 'http://h/s?a=1&b=2',
      });
      expect(envelope, contains('a=1&amp;b=2'));
      expect(envelope, isNot(contains('a=1&b=2')));
    });

    test('DIDL carries the track, escaped for its second trip', () {
      final didl = didlMetadata(
        url: 'http://192.168.1.40:5000/media/abc.mp3',
        title: 'Al Sudeste',
        artist: 'Moneda Dura',
        album: 'Sin Blasfemias',
        mimeType: 'audio/mpeg',
        durationMs: 249000,
      );

      expect(didl, contains('<dc:title>Al Sudeste</dc:title>'));
      expect(didl, contains('object.item.audioItem.musicTrack'));
      expect(didl, contains('http-get:*:audio/mpeg'));
      expect(didl, contains('duration="0:04:09"'));
    });

    test('an unknown length simply has no duration', () {
      // Drive tracks arrive with no duration until they play.
      expect(
        didlMetadata(
          url: 'http://h/a.mp3',
          title: 'T',
          artist: 'A',
          album: 'B',
          mimeType: 'audio/mpeg',
        ),
        isNot(contains('duration=')),
      );
    });

    test('a title with markup cannot break the document', () {
      final didl = didlMetadata(
        url: 'http://h/a.mp3',
        title: 'Rock & <Roll>',
        artist: 'A',
        album: 'B',
        mimeType: 'audio/mpeg',
      );
      expect(didl, contains('Rock &amp; &lt;Roll&gt;'));
    });

    test('a value is pulled out of a reply', () {
      const reply = '''
<s:Envelope><s:Body><u:GetTransportInfoResponse>
<CurrentTransportState>PLAYING</CurrentTransportState>
</u:GetTransportInfoResponse></s:Body></s:Envelope>''';
      expect(soapValue(reply, 'CurrentTransportState'), 'PLAYING');
      expect(soapValue(reply, 'Nonexistent'), isNull);
      expect(soapValue('not xml', 'Anything'), isNull);
    });

    test('transport states map to something usable', () {
      expect(DlnaState.fromWire('PLAYING'), DlnaState.playing);
      expect(DlnaState.fromWire('PAUSED_PLAYBACK'), DlnaState.paused);
      expect(DlnaState.fromWire('NO_MEDIA_PRESENT'), DlnaState.stopped);
      expect(DlnaState.fromWire('TRANSITIONING'), DlnaState.transitioning);
      expect(DlnaState.fromWire('something new'), DlnaState.unknown);
      expect(DlnaState.fromWire(null), DlnaState.unknown);
    });

    test('UPnP times are read, fractional seconds included', () {
      expect(parseUpnpTime('0:01:30'), const Duration(seconds: 90));
      expect(parseUpnpTime('1:00:00'), const Duration(hours: 1));
      expect(parseUpnpTime('0:00:05.500'), const Duration(milliseconds: 5500));
      expect(parseUpnpTime('nonsense'), Duration.zero);
      expect(parseUpnpTime(null), Duration.zero);
    });
  });

  group('CASTV2 framing', () {
    test('a message round-trips through the wire format', () {
      final frame = encodeCastFrame(
        const CastMessage(
          namespace: 'urn:x-cast:com.google.cast.media',
          payload: '{"type":"PLAY"}',
          destinationId: 'transport-1',
        ),
      );

      // Four-byte big-endian length, then the body.
      final length =
          (frame[0] << 24) | (frame[1] << 16) | (frame[2] << 8) | frame[3];
      expect(frame.length, 4 + length);

      final decoded = decodeCastMessage(frame.sublist(4))!;
      expect(decoded.namespace, 'urn:x-cast:com.google.cast.media');
      expect(decoded.payload, '{"type":"PLAY"}');
      expect(decoded.destinationId, 'transport-1');
      expect(decoded.json['type'], 'PLAY');
    });

    test('a long payload keeps its multi-byte length', () {
      // Past 127 bytes the protobuf length needs a second varint byte, which is
      // the easiest thing to get wrong by hand.
      final payload = jsonEncode({'type': 'LOAD', 'pad': 'x' * 500});
      final frame = encodeCastFrame(
        CastMessage(namespace: 'ns', payload: payload),
      );
      expect(decodeCastMessage(frame.sublist(4))!.payload, payload);
    });

    test('unknown fields are skipped, not treated as an error', () {
      // The device sends fields this app does not read, and a stricter parser
      // would break on a firmware update.
      final frame = encodeCastFrame(
        const CastMessage(namespace: 'ns', payload: '{}'),
      );
      final body = [...frame.sublist(4), 0x78, 0x01]; // field 15, varint
      expect(decodeCastMessage(body), isNotNull);
    });

    test('a truncated body is refused rather than throwing', () {
      final frame = encodeCastFrame(
        const CastMessage(namespace: 'ns', payload: '{"a":1}'),
      );
      expect(decodeCastMessage(frame.sublist(4, frame.length - 3)), isNull);
      expect(decodeCastMessage(const []), isNull);
    });

    test('frames split across chunks are reassembled', () {
      // TCP does not preserve message boundaries; this is the case that shows
      // up only on a real device.
      final first = encodeCastFrame(
        const CastMessage(namespace: 'a', payload: '{"n":1}'),
      );
      final second = encodeCastFrame(
        const CastMessage(namespace: 'b', payload: '{"n":2}'),
      );
      final reader = CastFrameReader();

      expect(reader.add(first.sublist(0, 3)), isEmpty);
      expect(reader.add(first.sublist(3, first.length - 2)), isEmpty);

      final rest = [...first.sublist(first.length - 2), ...second];
      final messages = reader.add(rest);
      expect(messages.map((m) => m.namespace), ['a', 'b']);
    });

    test('two frames in one chunk both come out', () {
      final chunk = [
        ...encodeCastFrame(const CastMessage(namespace: 'a', payload: '{}')),
        ...encodeCastFrame(const CastMessage(namespace: 'b', payload: '{}')),
      ];
      expect(CastFrameReader().add(chunk), hasLength(2));
    });

    test('a nonsense length resynchronises instead of hanging', () {
      final reader = CastFrameReader();
      expect(reader.add([0x7f, 0xff, 0xff, 0xff, 1, 2, 3]), isEmpty);
      // The buffer was dropped, so a good frame afterwards still parses.
      expect(
        reader.add(
          encodeCastFrame(const CastMessage(namespace: 'a', payload: '{}')),
        ),
        hasLength(1),
      );
    });
  });

  group('Cast payloads', () {
    test('LOAD describes the track the way a device expects', () {
      final payload = loadPayload(
        url: 'http://192.168.1.40:5000/media/abc.mp3',
        song: _song(),
        mimeType: 'audio/mpeg',
      );

      expect(payload['type'], 'LOAD');
      expect(payload['autoplay'], isTrue);

      final media = payload['media']! as Map<String, Object?>;
      expect(media['contentId'], 'http://192.168.1.40:5000/media/abc.mp3');
      // Without contentType many devices refuse the stream outright.
      expect(media['contentType'], 'audio/mpeg');
      expect(media['streamType'], 'BUFFERED');
      // Seconds, not milliseconds.
      expect(media['duration'], 249.0);

      final metadata = media['metadata']! as Map<String, Object?>;
      expect(metadata['metadataType'], 3);
      expect(metadata['title'], 'Al Sudeste');
      expect(metadata['albumName'], 'Sin Blasfemias');
    });

    test('a track of unknown length omits the duration', () {
      final media =
          loadPayload(
                url: 'http://h/a.mp3',
                song: _song(duration: 0),
                mimeType: 'audio/mpeg',
              )['media']!
              as Map<String, Object?>;
      expect(media.containsKey('duration'), isFalse);
    });

    test('only a finished track advances the queue', () {
      // A device reports IDLE for a dozen reasons; skipping on any of them would
      // run through the queue.
      expect(
        castTrackFinished({'playerState': 'IDLE', 'idleReason': 'FINISHED'}),
        isTrue,
      );
      expect(
        castTrackFinished({'playerState': 'IDLE', 'idleReason': 'INTERRUPTED'}),
        isFalse,
      );
      expect(
        castTrackFinished({'playerState': 'IDLE', 'idleReason': 'ERROR'}),
        isFalse,
      );
      expect(castTrackFinished({'playerState': 'PLAYING'}), isFalse);
      expect(castTrackFinished(const {}), isFalse);
    });

    test('device names lose their mDNS noise', () {
      expect(castNameFrom('Living Room-1a2b3c4d._googlecast._tcp.local'),
          'Living Room');
      expect(castNameFrom('Kitchen._googlecast._tcp.local'), 'Kitchen');
      // A dash that is part of the name is kept.
      expect(castNameFrom('Hi-Fi._googlecast._tcp.local'), 'Hi-Fi');
    });
  });

  group('what can be cast', () {
    test('a local file that exists can be', () {
      final dir = Directory.systemTemp.createTempSync('pixelplay-refusal');
      final file = File('${dir.path}/a.mp3')..writeAsStringSync('x');
      addTearDown(() => dir.deleteSync(recursive: true));

      expect(
        castRefusalFor(_song(path: file.path), needsAuthHeader: false),
        isNull,
      );
    });

    test('a missing file is refused with a reason', () {
      expect(
        castRefusalFor(_song(path: '/gone/a.mp3'), needsAuthHeader: false),
        contains('no longer there'),
      );
    });

    test('a signed remote URL is fine — the speaker fetches it', () {
      // Jellyfin and Navidrome sign their stream URLs, so nothing local is
      // needed at all.
      expect(
        castRefusalFor(
          _song(path: 'https://music.example.com/rest/stream?t=abc'),
          needsAuthHeader: false,
        ),
        isNull,
      );
    });

    test('a URL needing a private header is refused, and says why', () {
      // Google Drive: the token cannot be handed to a speaker.
      expect(
        castRefusalFor(
          _song(path: 'https://www.googleapis.com/drive/v3/files/x?alt=media'),
          needsAuthHeader: true,
        ),
        contains('private key'),
      );
    });

    test('a track with no file at all is refused', () {
      expect(
        castRefusalFor(_song(path: ''), needsAuthHeader: false),
        isNotNull,
      );
    });
  });
}
