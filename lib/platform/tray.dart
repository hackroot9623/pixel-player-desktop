import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../data/prefs/settings.dart';
import '../player/player_service.dart';

// A tray icon, and the option of the window closing to it rather than quitting.
//
// This is the desktop half of what a phone gets for free: on Android the service
// kept playing with no window at all. Here, closing the window ends the process
// unless something else is holding the app up — so the tray icon and
// close-to-tray are one feature, and close-to-tray is refused without an icon
// because there would be no way back to the window.
//
// Both are off by default. A tray icon nobody asked for is clutter, and on some
// desktops (GNOME without an extension) there is no tray to put it in.

/// The installed icon, if any.
TrayController? _current;

/// Installs, removes or updates the tray icon to match [settings].
///
/// Idempotent, so it can be called on every settings change without the icon
/// flickering: the only work done is the difference.
Future<void> applyTray(PlayerService player, Settings settings) async {
  if (settings.showTrayIcon) {
    _current ??= await TrayController.attach(player, settings: settings);
    // The close behaviour can change without the icon changing.
    if (_current != null) {
      try {
        await windowManager.setPreventClose(settings.closeToTray);
      } catch (_) {
        // A window manager that will not take this is not worth a crash.
      }
    }
    return;
  }

  final installed = _current;
  _current = null;
  if (installed == null) return;
  await installed.dispose();
  try {
    // Without an icon there is nowhere to close to, so the window must quit
    // normally again.
    await windowManager.setPreventClose(false);
  } catch (_) {}
}

/// The keys the tray menu uses, so the click handler and the menu cannot drift
/// apart.
enum TrayAction {
  playPause('play_pause'),
  next('next'),
  previous('previous'),
  show('show'),
  quit('quit');

  const TrayAction(this.key);

  final String key;

  static TrayAction? fromKey(String? key) {
    for (final action in values) {
      if (action.key == key) return action;
    }
    return null;
  }
}

/// The tray menu for a given player state.
///
/// Pure and returned as data so the labels and the enabled/disabled logic can be
/// tested without a tray — which matters because there is no tray at all in a
/// test environment, and often none on the user's desktop either.
List<TrayEntry> trayEntries({
  required String? nowPlaying,
  required bool playing,
  required bool hasQueue,
}) => [
  if (nowPlaying != null)
    TrayEntry.label(_ellipsis(nowPlaying, 48)),
  if (nowPlaying != null) const TrayEntry.separator(),
  TrayEntry.action(
    TrayAction.playPause,
    playing ? 'Pause' : 'Play',
    enabled: hasQueue,
  ),
  TrayEntry.action(TrayAction.previous, 'Previous', enabled: hasQueue),
  TrayEntry.action(TrayAction.next, 'Next', enabled: hasQueue),
  const TrayEntry.separator(),
  TrayEntry.action(TrayAction.show, 'Show PixelPlayer'),
  TrayEntry.action(TrayAction.quit, 'Quit'),
];

/// One row of the tray menu.
class TrayEntry {
  const TrayEntry.action(this.action, this.label, {this.enabled = true})
    : isSeparator = false;

  const TrayEntry.label(this.label)
    : action = null,
      enabled = false,
      isSeparator = false;

  const TrayEntry.separator()
    : action = null,
      label = null,
      enabled = false,
      isSeparator = true;

  final TrayAction? action;
  final String? label;
  final bool enabled;
  final bool isSeparator;
}

String _ellipsis(String text, int max) =>
    text.length <= max ? text : '${text.substring(0, max - 1)}…';

/// What the tray tooltip and menu header say about the current track.
String? nowPlayingLabel(PlayerService player) {
  final song = player.current;
  if (song == null) return null;
  final artist = song.displayArtist.trim();
  return artist.isEmpty ? song.title : '${song.title} — $artist';
}

class TrayController with TrayListener, WindowListener {
  TrayController._(this._player, this._settings);

  final PlayerService _player;
  final Settings _settings;

  /// What the menu was last built from, so it is not rebuilt on every position
  /// tick — rebuilding a tray menu is a round trip to the desktop.
  String _lastState = '';

  /// Installs the tray icon, or returns null when there is nothing to install
  /// it into.
  ///
  /// Never throws. A desktop with no system tray is normal, and the app has to
  /// keep working with a dead tray rather than not starting.
  static Future<TrayController?> attach(
    PlayerService player, {
    required Settings settings,
  }) async {
    if (!settings.showTrayIcon) return null;
    // The tray plugins exist for all three desktops; only the icon lookup
    // differs, and tray_manager resolves an asset path itself.
    try {
      final controller = TrayController._(player, settings);
      await trayManager.setIcon(
        Platform.isWindows
            ? 'assets/images/icon.ico'
            : 'assets/images/icon.png',
      );
      trayManager.addListener(controller);
      windowManager.addListener(controller);
      await windowManager.setPreventClose(settings.closeToTray);
      await controller._refresh(force: true);
      player.addListener(controller._onPlayerChanged);
      return controller;
    } catch (error) {
      debugPrint('Tray unavailable: $error');
      return null;
    }
  }

  void _onPlayerChanged() => _refresh();

  Future<void> _refresh({bool force = false}) async {
    final label = nowPlayingLabel(_player);
    final state = '$label|${_player.playing}|${_player.hasQueue}';
    if (!force && state == _lastState) return;
    _lastState = state;

    final entries = trayEntries(
      nowPlaying: label,
      playing: _player.playing,
      hasQueue: _player.hasQueue,
    );

    // The menu goes first, and on its own: it is the entire point of the icon.
    // Anything after it that fails must not be able to take it down — which is
    // exactly what used to happen, see the tooltip below.
    try {
      await trayManager.setContextMenu(
        Menu(
          items: [
            for (final entry in entries)
              if (entry.isSeparator)
                MenuItem.separator()
              else
                MenuItem(
                  key: entry.action?.key,
                  label: entry.label,
                  disabled: !entry.enabled,
                ),
          ],
        ),
      );
    } catch (error) {
      // Reported rather than swallowed: a tray with no menu is invisible as a
      // failure, and this one hid behind a silent catch for a whole release.
      debugPrint('Tray menu could not be set: $error');
    }

    // Tooltips are a separate, optional nicety. tray_manager has no Linux
    // implementation of setToolTip, so this throws MissingPluginException there
    // — and when it shared a try block with the menu, the menu never got set at
    // all: the icon appeared with nothing behind it.
    try {
      await trayManager.setToolTip(label ?? 'PixelPlayer');
    } on MissingPluginException {
      // Expected on Linux; an appindicator has no tooltip.
    } catch (_) {
      // Any other platform grumble is not worth a word to the user.
    }
  }

  @override
  void onTrayIconMouseDown() {
    // Left click shows the window, which is what every other tray player does.
    windowManager.show();
    windowManager.focus();
  }

  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (TrayAction.fromKey(menuItem.key)) {
      case TrayAction.playPause:
        _player.toggle();
      case TrayAction.next:
        _player.next();
      case TrayAction.previous:
        _player.previous();
      case TrayAction.show:
        windowManager.show();
        windowManager.focus();
      case TrayAction.quit:
        // Past prevent-close: this is the deliberate exit.
        windowManager.destroy();
      case null:
        break;
    }
  }

  /// Closing the window hides it when the user asked for that.
  ///
  /// Only reached with `setPreventClose(true)`, so the setting is what decides
  /// whether this runs at all.
  @override
  void onWindowClose() {
    if (_settings.closeToTray) {
      windowManager.hide();
    } else {
      windowManager.destroy();
    }
  }

  Future<void> dispose() async {
    _player.removeListener(_onPlayerChanged);
    trayManager.removeListener(this);
    windowManager.removeListener(this);
    try {
      await trayManager.destroy();
    } catch (_) {
      // Going away anyway.
    }
  }
}
