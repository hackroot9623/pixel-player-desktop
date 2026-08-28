import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../data/models/models.dart';
import '../../player/player_service.dart';
import 'chromecast.dart';
import 'dlna.dart';
import 'media_server.dart';

// Casting: the local queue, mirrored onto a speaker.
//
// The design decision worth stating: PixelPlayer stays the brain. The queue,
// shuffle, repeat and the next track are all still decided here, and the device
// is handed one track at a time. The alternative — pushing a playlist and letting
// the device manage it — means two things that both think they are in charge, and
// they disagree the moment the user reorders the queue.
//
// So while casting, mpv is paused and the device plays. When the device reports
// the track finished, the queue advances here and the next track is pushed.
//
// Both protocols reduce to the same three verbs, which is why they sit behind one
// controller: hand over a URL, transport, volume.

/// Which protocol a target speaks.
enum CastProtocol { chromecast, dlna }

/// A device the user can pick.
class CastTarget {
  const CastTarget({
    required this.protocol,
    required this.name,
    required this.address,
    this.cast,
    this.dlna,
  });

  final CastProtocol protocol;
  final String name;
  final String address;
  final CastDevice? cast;
  final DlnaDevice? dlna;

  /// Stable enough to keep a selection across a rediscovery.
  String get id => '${protocol.name}:$address';
}

/// Why a track cannot be cast, or null when it can.
///
/// Remote sources are the interesting case: a signed Jellyfin or Navidrome URL
/// is fetchable by the speaker directly, but a Google Drive URL needs an
/// Authorization header that there is no way to give it.
String? castRefusalFor(Song song, {required bool needsAuthHeader}) {
  if (song.path.isEmpty) return 'That track has no file to send.';
  if (song.path.startsWith('http://') || song.path.startsWith('https://')) {
    return needsAuthHeader
        ? 'This track needs a private key to fetch, which a speaker cannot be '
              'given. Casting works for local files and for servers that sign '
              'their stream URLs.'
        : null;
  }
  if (!File(song.path).existsSync()) return 'That file is no longer there.';
  return null;
}

/// Runs a cast session and keeps it in step with the player.
class CastController extends ChangeNotifier {
  CastController(this._player, {this.headersFor = PlayerService.headersForUrl});

  final PlayerService _player;

  /// How to tell whether a URL needs headers we cannot hand to a speaker.
  /// Injectable so the refusal logic can be tested without the player.
  final Map<String, String>? Function(String url) headersFor;

  LocalMediaServer? _server;
  CastSession? _cast;
  DlnaSession? _dlna;
  StreamSubscription<Map<String, Object?>>? _castStatus;
  Timer? _poll;

  CastTarget? _target;
  String? _error;

  /// What the device was last told to play, so a rebuild does not re-push it.
  String? _pushedSongId;
  bool _pushedPlaying = false;

  CastTarget? get target => _target;
  bool get casting => _target != null;
  String? get error => _error;

  /// Devices on the network. Both protocols are searched at once, because a
  /// user does not think in protocols.
  Future<List<CastTarget>> discover() async {
    final results = await Future.wait([
      discoverCastDevices(),
      discoverDlnaRenderers(),
    ]);

    return [
      for (final device in results[0] as List<CastDevice>)
        CastTarget(
          protocol: CastProtocol.chromecast,
          name: device.name,
          address: device.address,
          cast: device,
        ),
      for (final device in results[1] as List<DlnaDevice>)
        CastTarget(
          protocol: CastProtocol.dlna,
          name: device.name,
          address: device.address,
          dlna: device,
        ),
    ];
  }

  /// Starts casting to [target], moving the current track over to it.
  Future<void> start(CastTarget target) async {
    await stop();
    _error = null;

    final song = _player.current;
    if (song == null) {
      _fail('Play something first, then send it to a speaker.');
      return;
    }
    final refusal = castRefusalFor(
      song,
      needsAuthHeader: headersFor(song.path) != null,
    );
    if (refusal != null) {
      _fail(refusal);
      return;
    }

    try {
      _server = await LocalMediaServer.start();
      if (_server == null) {
        _fail('Could not open a port to serve the music from.');
        return;
      }

      switch (target.protocol) {
        case CastProtocol.chromecast:
          _cast = await CastSession.connect(target.cast!);
          _castStatus = _cast!.statuses.listen(_onCastStatus);
        case CastProtocol.dlna:
          _dlna = DlnaSession(target.dlna!);
      }

      _target = target;
      // mpv goes quiet: the speaker is the output now, and two copies playing a
      // second apart is worse than either alone.
      if (_player.playing) await _player.toggle();

      await _push(song, play: true);
      _player.addListener(_onPlayerChanged);
      _player.addSeekListener(_onSeek);
      _startPolling();
      notifyListeners();
    } on CastException catch (error) {
      await _teardown();
      _fail(error.message);
    } catch (error) {
      await _teardown();
      _fail('Could not start casting: $error');
    }
  }

  /// Ends the session, leaving playback where it is so the user can carry on
  /// locally.
  Future<void> stop() async {
    if (_target == null && _server == null) return;
    try {
      _cast?.stop();
      await _dlna?.stop();
    } catch (_) {
      // A device that has already gone does not need telling.
    }
    await _teardown();
    notifyListeners();
  }

  Future<void> _teardown() async {
    _poll?.cancel();
    _poll = null;
    _player.removeListener(_onPlayerChanged);
    _player.removeSeekListener(_onSeek);
    await _castStatus?.cancel();
    _castStatus = null;
    await _cast?.dispose();
    _cast = null;
    _dlna?.close();
    _dlna = null;
    await _server?.dispose();
    _server = null;
    _target = null;
    _pushedSongId = null;
  }

  void _fail(String message) {
    _error = message;
    notifyListeners();
  }

  /// Hands one track to the device.
  Future<void> _push(Song song, {required bool play}) async {
    final server = _server;
    final target = _target;
    if (server == null || target == null) return;

    final String url;
    if (song.path.startsWith('http')) {
      // A signed remote URL: the speaker fetches it itself, and nothing needs
      // serving from here.
      url = song.path;
    } else {
      final address = pickLocalAddress(
        await localAddresses(),
        target.address,
      );
      if (address == null) {
        _fail('No network address this speaker could reach us on.');
        return;
      }
      server.unpublishAll();
      url = server.urlFor(server.publish(File(song.path)), address: address);
    }

    final mimeType = contentTypeFor(song.path);
    _pushedSongId = song.id;
    _pushedPlaying = play;

    if (_cast != null) {
      await _cast!.load(url, song: song, mimeType: mimeType);
    } else if (_dlna != null) {
      await _dlna!.play(url, song: song, mimeType: mimeType);
    }
  }

  void _onPlayerChanged() {
    final song = _player.current;
    if (song == null) return;

    // A new track: push it, and keep playing on the device.
    if (song.id != _pushedSongId) {
      _push(song, play: true);
      return;
    }

    // The user pressed play or pause locally; mirror it rather than fighting.
    if (_player.playing != _pushedPlaying) {
      _pushedPlaying = _player.playing;
      if (_player.playing) {
        _cast?.resume();
        _dlna?.resume();
      } else {
        _cast?.pause();
        _dlna?.pause();
      }
    }
  }

  void _onSeek(Duration position) {
    _cast?.seek(position);
    _dlna?.seek(position);
  }

  void _onCastStatus(Map<String, Object?> status) {
    if (castTrackFinished(status)) _advance();
  }

  /// Polls the device, which is the only way to notice a DLNA track ending.
  void _startPolling() {
    _poll = Timer.periodic(const Duration(seconds: 2), (_) async {
      final dlna = _dlna;
      if (dlna != null) {
        try {
          final state = await dlna.state();
          // Stopped while we believe it is playing means the track ran out.
          if (state == DlnaState.stopped && _pushedPlaying) _advance();
        } catch (_) {
          // A renderer that stops answering is handled by the user pressing
          // stop; guessing here would cut playback off mid-track.
        }
      }
      _cast?.requestStatus();
    });
  }

  /// The device finished a track, so the queue moves on here.
  void _advance() {
    // Guard against the several IDLE messages a device sends for one ending.
    _pushedPlaying = false;
    _player.next();
  }

  /// 0..100 on the device itself, which is separate from our own volume.
  Future<void> setDeviceVolume(int percent) async {
    _cast?.setVolume(percent);
    await _dlna?.setVolume(percent);
  }

  @override
  void dispose() {
    _teardown();
    super.dispose();
  }
}
