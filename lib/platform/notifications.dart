import 'dart:async';
import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:flutter/foundation.dart';

import '../data/models/models.dart';
import '../player/player_service.dart';
import 'mpris.dart' show mprisArtUrl;

// Track-change notifications, through org.freedesktop.Notifications.
//
// Android showed a persistent notification with transport controls because that
// was the only way to control playback with the app in the background. Desktop
// does not need that — MPRIS already puts controls in the shell — so this is a
// popup announcing the track, off by default, with the transport buttons offered
// only when the notification server says it can draw them.
//
// Replacing rather than stacking is the whole trick: every notification reuses
// the previous id, so a long album leaves one popup that keeps changing rather
// than forty in the tray.

const notificationsBusName = 'org.freedesktop.Notifications';
const notificationsPath = '/org/freedesktop/Notifications';

/// The desktop-entry hint, so the popup carries our icon and name.
const notificationDesktopEntry = 'com.theveloper.pixelplay_desktop';

/// What a "now playing" popup says.
class NotificationContent {
  const NotificationContent({
    required this.summary,
    required this.body,
    this.iconPath,
  });

  /// The track title: the one line a popup is guaranteed to show.
  final String summary;

  /// Artist, and album when it adds something.
  final String body;

  /// Cover art as a URI, or null when there is none.
  final String? iconPath;
}

/// Builds the popup for a song.
///
/// Pure, so the awkward cases — no album, no artist, an album that repeats the
/// artist — are tested rather than eyeballed.
NotificationContent nowPlayingContent(Song song) {
  final artist = song.displayArtist.trim();
  final album = song.album.trim();

  final parts = <String>[
    if (artist.isNotEmpty) artist,
    // Skipping the album when it matches the artist avoids "Adele — Adele".
    if (album.isNotEmpty && album != artist) album,
  ];

  return NotificationContent(
    summary: song.title.trim().isEmpty ? 'Unknown track' : song.title.trim(),
    body: parts.join(' · '),
    iconPath: mprisArtUrl(song.albumArtPath),
  );
}

/// The action list for a notification server that can draw buttons.
///
/// Pairs of key and label, as the specification wants them. Empty when the
/// server has no `actions` capability — sending them anyway means a popup whose
/// buttons are silently missing.
List<String> notificationActions({
  required bool serverSupportsActions,
  required bool playing,
}) => serverSupportsActions
    ? [
        'previous',
        'Previous',
        playing ? 'pause' : 'play',
        playing ? 'Pause' : 'Play',
        'next',
        'Next',
      ]
    : const [];

/// Shows track-change popups and handles their buttons.
class NotificationService {
  NotificationService._(this._player, this._client, this._capabilities);

  final PlayerService _player;
  final DBusClient _client;
  final Set<String> _capabilities;

  /// The id the server gave us, reused so the popup is replaced rather than
  /// repeated.
  int _lastId = 0;

  /// The song last announced, so a pause or a seek does not re-announce it.
  String? _lastSongId;

  StreamSubscription<DBusSignal>? _actions;

  /// Whether to announce anything at all. Owned by the caller, because it is a
  /// user setting rather than a property of the bus.
  bool enabled = false;

  bool get supportsActions => _capabilities.contains('actions');

  /// Connects to the notification server, or returns null when there is none.
  ///
  /// Linux only, and never throws: a desktop without a notification daemon is
  /// perfectly normal.
  static Future<NotificationService?> attach(PlayerService player) async {
    if (!Platform.isLinux) return null;
    try {
      final client = DBusClient.session();
      final capabilities = await _getCapabilities(client);
      final service = NotificationService._(player, client, capabilities);
      await service._listenForActions();
      return service;
    } catch (error) {
      debugPrint('Notifications unavailable: $error');
      return null;
    }
  }

  static Future<Set<String>> _getCapabilities(DBusClient client) async {
    final reply = await _remote(client).callMethod(
      notificationsBusName,
      'GetCapabilities',
      const [],
      replySignature: DBusSignature('as'),
    );
    return {
      for (final value in reply.values.first.asStringArray()) value,
    };
  }

  static DBusRemoteObject _remote(DBusClient client) => DBusRemoteObject(
    client,
    name: notificationsBusName,
    path: DBusObjectPath(notificationsPath),
  );

  /// Announces [song] unless it is the one already announced.
  Future<void> announce(Song song) async {
    if (!enabled) return;
    if (song.id == _lastSongId) return;
    _lastSongId = song.id;

    final content = nowPlayingContent(song);
    try {
      final reply = await _remote(_client).callMethod(
        notificationsBusName,
        'Notify',
        [
          const DBusString('PixelPlayer'),
          // Reusing the id replaces the previous popup in place.
          DBusUint32(_lastId),
          const DBusString(''),
          DBusString(content.summary),
          DBusString(content.body),
          DBusArray.string(
            notificationActions(
              serverSupportsActions: supportsActions,
              playing: _player.playing,
            ),
          ),
          DBusDict.stringVariant({
            'desktop-entry': const DBusString(notificationDesktopEntry),
            // Music is not urgent, and this keeps it out of do-not-disturb.
            'urgency': const DBusByte(0),
            'category': const DBusString('x-gnome.music'),
            // Do not keep a history entry per track.
            'transient': const DBusBoolean(true),
            if (content.iconPath case final art?) 'image-path': DBusString(art),
          }),
          // Let the desktop decide how long a popup lives.
          const DBusInt32(-1),
        ],
        replySignature: DBusSignature('u'),
      );
      _lastId = reply.values.first.asUint32();
    } catch (_) {
      // A daemon that went away mid-song is not worth interrupting playback for.
    }
  }

  Future<void> _listenForActions() async {
    if (!supportsActions) return;
    _actions = DBusSignalStream(
      _client,
      sender: notificationsBusName,
      interface: notificationsBusName,
      name: 'ActionInvoked',
      path: DBusObjectPath(notificationsPath),
    ).listen(_onAction, onError: (_) {});
  }

  Future<void> _onAction(DBusSignal signal) async {
    if (signal.values.length < 2) return;
    // Another app's notification is none of our business.
    if (signal.values.first.asUint32() != _lastId) return;

    switch (signal.values[1].asString()) {
      case 'previous':
        await _player.previous();
      case 'next':
        await _player.next();
      case 'play' || 'pause':
        await _player.toggle();
    }
  }

  Future<void> dispose() async {
    await _actions?.cancel();
    await _client.close();
  }
}
