import 'dart:async';
import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:flutter/foundation.dart';

import '../data/models/models.dart';
import '../player/player_service.dart';

// MPRIS2, the desktop equivalent of Android's MediaSession.
//
// On Android `MusicService` published a MediaSession and the system did the
// rest: lockscreen controls, the notification, headset buttons. On Linux the
// same job is one D-Bus name — org.mpris.MediaPlayer2.pixelplayer — and the
// desktop picks it up: GNOME's media widget, KDE's panel, the media keys, and
// anything else that speaks MPRIS such as playerctl.
//
// This is Linux only. macOS wants MPNowPlayingInfoCenter and Windows wants
// SystemMediaTransportControls, and neither speaks D-Bus, so on those platforms
// [MprisService.attach] does nothing rather than pretending.
//
// The mapping from a Song to MPRIS metadata is a pure function, so the part that
// is easy to get subtly wrong — microseconds, artist arrays, the track id being
// an object path — is tested without a bus.

const mprisBusName = 'org.mpris.MediaPlayer2.pixelplayer';
const mprisObjectPath = '/org/mpris/MediaPlayer2';
const mprisRootInterface = 'org.mpris.MediaPlayer2';
const mprisPlayerInterface = 'org.mpris.MediaPlayer2.Player';

/// MPRIS calls this the PlaybackStatus, and only these three values are legal.
String mprisPlaybackStatus({required bool playing, required bool hasTrack}) {
  if (!hasTrack) return 'Stopped';
  return playing ? 'Playing' : 'Paused';
}

/// The D-Bus object path MPRIS wants as a track id.
///
/// It has to be a valid object path, so a song id — which can be a file path or
/// `drive:account:fileId` — cannot be used directly. The queue position is
/// enough: MPRIS only needs it to tell one entry from another.
DBusObjectPath mprisTrackId(int index) =>
    DBusObjectPath('/org/mpris/MediaPlayer2/pixelplayer/track/$index');

/// A song as MPRIS metadata.
///
/// Lengths are microseconds, not milliseconds — the commonest mistake here, and
/// it shows up as a progress bar that is a thousand times too short.
Map<String, DBusValue> mprisMetadata(
  Song? song, {
  int index = 0,
}) {
  if (song == null) {
    // A valid but empty map. Omitting trackid confuses clients that key on it.
    return {'mpris:trackid': mprisTrackId(0)};
  }

  final artists = song.artists.isEmpty
      ? [song.artist]
      : [for (final artist in song.artists) artist.name];

  return {
    'mpris:trackid': mprisTrackId(index),
    if (song.duration > 0)
      'mpris:length': DBusUint64(song.duration * 1000),
    'xesam:title': DBusString(song.title),
    'xesam:artist': DBusArray.string(artists.where((a) => a.isNotEmpty)),
    'xesam:album': DBusString(song.album),
    if (song.albumArtist?.isNotEmpty ?? false)
      'xesam:albumArtist': DBusArray.string([song.albumArtist!]),
    if (song.trackNumber > 0)
      'xesam:trackNumber': DBusInt32(song.trackNumber),
    if (song.genre?.isNotEmpty ?? false)
      'xesam:genre': DBusArray.string([song.genre!]),
    if (mprisArtUrl(song.albumArtPath) case final art?)
      'mpris:artUrl': DBusString(art),
    // Clients show this next to the title; a remote track has a URL already.
    'xesam:url': DBusString(mprisTrackUrl(song.path)),
  };
}

/// Cover art as a URI. A path on disk has to become `file://`, and a URL is
/// already one.
String? mprisArtUrl(String? artPath) {
  if (artPath == null || artPath.isEmpty) return null;
  if (artPath.startsWith('http://') || artPath.startsWith('https://')) {
    return artPath;
  }
  return Uri.file(artPath).toString();
}

/// The track's own location, as a URI for the same reason.
String mprisTrackUrl(String path) {
  if (path.isEmpty) return '';
  if (path.startsWith('http://') || path.startsWith('https://')) return path;
  return Uri.file(path).toString();
}

/// Where the current song sits in the queue, or 0 when there is none.
///
/// Compared by id rather than by identity: the queue is rebuilt on reorder, so
/// the same track can be a different object.
int _queueIndex(PlayerService player, Song? song) {
  if (song == null) return 0;
  final index = player.queue.indexWhere((entry) => entry.id == song.id);
  return index < 0 ? 0 : index;
}

/// Publishes the player on D-Bus and takes commands back from the desktop.
class MprisService {
  MprisService._(this._player, this._client, this._object);

  final PlayerService _player;
  final DBusClient _client;
  final _MprisObject _object;

  /// What was last published, so a change can be detected without spamming
  /// PropertiesChanged on every position tick.
  String _lastStatus = '';
  String? _lastTrackKey;
  bool _lastShuffle = false;
  double _lastVolume = -1;

  /// Publishes [player] on the session bus, or returns null when this platform
  /// or this session has no bus to publish on.
  ///
  /// Never throws: a missing D-Bus is a normal state — a bare X session, a
  /// container, a machine without a session bus — and it must not stop the app
  /// from playing music.
  static Future<MprisService?> attach(PlayerService player) async {
    if (!Platform.isLinux) return null;

    try {
      final client = DBusClient.session();
      final object = _MprisObject(player);
      await client.registerObject(object);
      // MPRIS requires this exact name shape, and two copies of the app would
      // otherwise fight over it — a second instance simply does not publish.
      final reply = await client.requestName(
        mprisBusName,
        flags: {DBusRequestNameFlag.doNotQueue},
      );
      if (reply == DBusRequestNameReply.exists) {
        await client.close();
        return null;
      }

      final service = MprisService._(player, client, object);
      service._start();
      return service;
    } catch (error, stack) {
      // No session bus, or a bus that refused us. Nothing to show the user —
      // they did not ask for this, they wanted their music — but it is logged,
      // because a silently absent MPRIS is impossible to diagnose otherwise.
      debugPrint('MPRIS unavailable: $error');
      assert(() {
        debugPrintStack(stackTrace: stack, label: 'MPRIS');
        return true;
      }());
      return null;
    }
  }

  void _start() {
    _publish();
    _player.addListener(_publish);
    _player.onSeeked = notifySeeked;
  }

  /// Pushes whatever changed since last time.
  ///
  /// Position is deliberately not published: MPRIS treats it as a value clients
  /// poll, and emitting it several times a second would wake every listener on
  /// the bus for nothing.
  void _publish() {
    final song = _player.current;
    final index = _queueIndex(_player, song);
    final changed = <String, DBusValue>{};

    final status = mprisPlaybackStatus(
      playing: _player.playing,
      hasTrack: song != null,
    );
    if (status != _lastStatus) {
      _lastStatus = status;
      changed['PlaybackStatus'] = DBusString(status);
    }

    // The queue position is part of the key: the same song twice in a row is
    // still a track change as far as a client is concerned.
    final trackKey = song == null ? null : '${song.id}#$index';
    if (trackKey != _lastTrackKey) {
      _lastTrackKey = trackKey;
      changed['Metadata'] = DBusDict.stringVariant(
        mprisMetadata(song, index: index),
      );
    }

    if (_player.shuffle != _lastShuffle) {
      _lastShuffle = _player.shuffle;
      changed['Shuffle'] = DBusBoolean(_lastShuffle);
    }

    // MPRIS wants 0..1 where the player keeps 0..100.
    final volume = _player.volume / 100;
    if (volume != _lastVolume) {
      _lastVolume = volume;
      changed['Volume'] = DBusDouble(volume);
    }

    if (changed.isEmpty) return;
    _object.emitPropertiesChanged(mprisPlayerInterface,
        changedProperties: changed);
  }

  /// Tells clients the position jumped, which they cannot infer.
  Future<void> notifySeeked(Duration position) => _object.emitSignal(
    mprisPlayerInterface,
    'Seeked',
    [DBusInt64(position.inMicroseconds)],
  );

  Future<void> dispose() async {
    _player.removeListener(_publish);
    _player.onSeeked = null;
    try {
      await _client.releaseName(mprisBusName);
    } catch (_) {
      // Shutting down anyway.
    }
    await _client.close();
  }
}

class _MprisObject extends DBusObject {
  _MprisObject(this._player) : super(DBusObjectPath(mprisObjectPath));

  final PlayerService _player;

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall call) async {
    if (call.interface == mprisRootInterface) {
      switch (call.name) {
        case 'Raise':
          // Nothing to raise: the window manager owns the window, and there is
          // no cross-desktop way to ask for focus that is not ignored anyway.
          return DBusMethodSuccessResponse();
        case 'Quit':
          return DBusMethodSuccessResponse();
        default:
          return DBusMethodErrorResponse.unknownMethod();
      }
    }

    if (call.interface != mprisPlayerInterface) {
      return DBusMethodErrorResponse.unknownInterface();
    }

    switch (call.name) {
      case 'Play':
        if (!_player.playing) await _player.toggle();
      case 'Pause':
        if (_player.playing) await _player.toggle();
      case 'PlayPause':
        await _player.toggle();
      case 'Stop':
        // MPRIS Stop means "stop and forget the position". Pausing and rewinding
        // is the closest honest equivalent; there is no stopped state here.
        if (_player.playing) await _player.toggle();
        await _player.seek(Duration.zero);
      case 'Next':
        await _player.next();
      case 'Previous':
        await _player.previous();
      case 'Seek':
        // An offset in microseconds, which may be negative.
        final offset = call.values.first.asInt64();
        final target = _player.position + Duration(microseconds: offset);
        await _player.seek(target < Duration.zero ? Duration.zero : target);
      case 'SetPosition':
        // The track id guards against a stale client seeking the wrong track.
        final trackId = call.values.first.asObjectPath();
        final index = _queueIndex(_player, _player.current);
        if (trackId != mprisTrackId(index)) {
          return DBusMethodSuccessResponse();
        }
        await _player.seek(Duration(microseconds: call.values[1].asInt64()));
      case 'OpenUri':
        // Handing us an arbitrary URI would mean playing something that is not
        // in the library, which nothing else in the app can do either.
        return DBusMethodErrorResponse.failed('OpenUri is not supported');
      default:
        return DBusMethodErrorResponse.unknownMethod();
    }
    return DBusMethodSuccessResponse();
  }

  @override
  Future<DBusMethodResponse> getProperty(String interface, String name) async {
    final value = _properties(interface)[name];
    return value == null
        ? DBusMethodErrorResponse.unknownProperty()
        : DBusGetPropertyResponse(value);
  }

  @override
  Future<DBusMethodResponse> getAllProperties(String interface) async =>
      DBusGetAllPropertiesResponse(_properties(interface));

  @override
  Future<DBusMethodResponse> setProperty(
    String interface,
    String name,
    DBusValue value,
  ) async {
    if (interface != mprisPlayerInterface) {
      return DBusMethodErrorResponse.unknownProperty();
    }
    switch (name) {
      case 'Volume':
        // MPRIS speaks 0..1; the player keeps 0..100.
        await _player.setVolume(value.asDouble().clamp(0.0, 1.0) * 100);
      case 'Shuffle':
        if (value.asBoolean() != _player.shuffle) {
          await _player.toggleShuffle();
        }
      case 'Rate':
        // One rate only. Refusing is more honest than accepting and ignoring.
        return DBusMethodErrorResponse.propertyReadOnly();
      default:
        return DBusMethodErrorResponse.unknownProperty();
    }
    return DBusMethodSuccessResponse();
  }

  Map<String, DBusValue> _properties(String interface) {
    if (interface == mprisRootInterface) {
      return {
        'Identity': const DBusString('PixelPlayer'),
        // Must match the installed .desktop basename, or the desktop cannot
        // find our icon and name for the media widget.
        'DesktopEntry': const DBusString('com.theveloper.pixelplay_desktop'),
        'CanQuit': const DBusBoolean(false),
        'CanRaise': const DBusBoolean(false),
        'HasTrackList': const DBusBoolean(false),
        'SupportedUriSchemes': DBusArray.string(const []),
        'SupportedMimeTypes': DBusArray.string(const []),
      };
    }
    if (interface != mprisPlayerInterface) return const {};

    final song = _player.current;
    final index = _queueIndex(_player, song);

    return {
      'PlaybackStatus': DBusString(
        mprisPlaybackStatus(playing: _player.playing, hasTrack: song != null),
      ),
      'Metadata': DBusDict.stringVariant(mprisMetadata(song, index: index)),
      'Position': DBusInt64(_player.position.inMicroseconds),
      'Volume': DBusDouble(_player.volume / 100),
      'Shuffle': DBusBoolean(_player.shuffle),
      'Rate': const DBusDouble(1),
      'MinimumRate': const DBusDouble(1),
      'MaximumRate': const DBusDouble(1),
      'LoopStatus': DBusString(_loopStatus),
      'CanGoNext': DBusBoolean(_player.hasQueue),
      'CanGoPrevious': DBusBoolean(_player.hasQueue),
      'CanPlay': DBusBoolean(_player.hasQueue),
      'CanPause': DBusBoolean(_player.hasQueue),
      'CanSeek': DBusBoolean(song != null && song.duration > 0),
      'CanControl': const DBusBoolean(true),
    };
  }

  String get _loopStatus => switch (_player.repeatMode) {
    RepeatMode.one => 'Track',
    RepeatMode.all => 'Playlist',
    RepeatMode.off => 'None',
  };

  @override
  List<DBusIntrospectInterface> introspect() => [
    DBusIntrospectInterface(
      mprisRootInterface,
      methods: [
        DBusIntrospectMethod('Raise'),
        DBusIntrospectMethod('Quit'),
      ],
      properties: [
        _property('Identity', 's'),
        _property('DesktopEntry', 's'),
        _property('CanQuit', 'b'),
        _property('CanRaise', 'b'),
        _property('HasTrackList', 'b'),
        _property('SupportedUriSchemes', 'as'),
        _property('SupportedMimeTypes', 'as'),
      ],
    ),
    DBusIntrospectInterface(
      mprisPlayerInterface,
      methods: [
        DBusIntrospectMethod('Play'),
        DBusIntrospectMethod('Pause'),
        DBusIntrospectMethod('PlayPause'),
        DBusIntrospectMethod('Stop'),
        DBusIntrospectMethod('Next'),
        DBusIntrospectMethod('Previous'),
        DBusIntrospectMethod(
          'Seek',
          args: [
            DBusIntrospectArgument(
              DBusSignature('x'),
              DBusArgumentDirection.in_,
              name: 'Offset',
            ),
          ],
        ),
        DBusIntrospectMethod(
          'SetPosition',
          args: [
            DBusIntrospectArgument(
              DBusSignature('o'),
              DBusArgumentDirection.in_,
              name: 'TrackId',
            ),
            DBusIntrospectArgument(
              DBusSignature('x'),
              DBusArgumentDirection.in_,
              name: 'Position',
            ),
          ],
        ),
      ],
      signals: [
        DBusIntrospectSignal(
          'Seeked',
          args: [
            DBusIntrospectArgument(
              DBusSignature('x'),
              DBusArgumentDirection.out,
              name: 'Position',
            ),
          ],
        ),
      ],
      properties: [
        _property('PlaybackStatus', 's'),
        _property('LoopStatus', 's'),
        _property('Metadata', 'a{sv}'),
        _property('Position', 'x'),
        _property('Volume', 'd', write: true),
        _property('Shuffle', 'b', write: true),
        _property('Rate', 'd'),
        _property('MinimumRate', 'd'),
        _property('MaximumRate', 'd'),
        _property('CanGoNext', 'b'),
        _property('CanGoPrevious', 'b'),
        _property('CanPlay', 'b'),
        _property('CanPause', 'b'),
        _property('CanSeek', 'b'),
        _property('CanControl', 'b'),
      ],
    ),
  ];

  static DBusIntrospectProperty _property(
    String name,
    String signature, {
    bool write = false,
  }) => DBusIntrospectProperty(
    name,
    DBusSignature(signature),
    access: write ? DBusPropertyAccess.readwrite : DBusPropertyAccess.read,
  );
}
