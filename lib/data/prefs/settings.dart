import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/sort_option.dart';
import '../scanner/library_scanner.dart';

/// Replaces the 17 DataStore files under `data/preferences/`. One flat store
/// with typed accessors; every setter notifies so Riverpod can rebuild.
class Settings extends ChangeNotifier {
  Settings(this._prefs);

  final SharedPreferences _prefs;

  static Future<Settings> load() async =>
      Settings(await SharedPreferences.getInstance());

  // ------------------------------------------------------------------ setup

  bool get setupComplete => _prefs.getBool('setup_complete') ?? false;
  set setupComplete(bool value) => _set('setup_complete', value);

  // ------------------------------------------------------------------ theme

  ThemeMode get themeMode =>
      ThemeMode.values[_prefs.getInt('theme_mode') ?? ThemeMode.system.index];
  set themeMode(ThemeMode value) => _set('theme_mode', value.index);

  /// `PaletteStyleSettingsScreen` — derive the whole scheme from the playing
  /// track's artwork instead of the fixed seed.
  bool get useAlbumArtColors => _prefs.getBool('album_art_colors') ?? true;
  set useAlbumArtColors(bool value) => _set('album_art_colors', value);

  Color get seedColor => Color(_prefs.getInt('seed_color') ?? 0xFF6C4FF5);
  set seedColor(Color value) => _set('seed_color', value.toARGB32());

  /// `NavBarCornerRadiusScreen`.
  double get navBarCornerRadius =>
      _prefs.getDouble('nav_bar_corner_radius') ?? 28;
  set navBarCornerRadius(double value) =>
      _set('nav_bar_corner_radius', value.clamp(0, 48));

  bool get showScrollbar => _prefs.getBool('show_scrollbar') ?? true;
  set showScrollbar(bool value) => _set('show_scrollbar', value);

  // ---------------------------------------------------------------- library

  List<String> get musicFolders =>
      _prefs.getStringList('music_folders') ?? const [];
  set musicFolders(List<String> value) => _set('music_folders', value);

  bool get multiArtistEnabled => _prefs.getBool('multi_artist') ?? true;
  set multiArtistEnabled(bool value) => _set('multi_artist', value);

  List<String> get artistDelimiters =>
      _prefs.getStringList('artist_delimiters') ?? defaultArtistDelimiters;
  set artistDelimiters(List<String> value) => _set('artist_delimiters', value);

  SortOption sortFor(LibraryTabId tab) => SortOption.fromKey(
    _prefs.getString('sort_${tab.storageKey}') ?? tab.defaultSort.storageKey,
    tab.defaultSort,
  );

  void setSortFor(LibraryTabId tab, SortOption option) =>
      _set('sort_${tab.storageKey}', option.storageKey);

  // --------------------------------------------------------------- playback

  double get volume => _prefs.getDouble('volume') ?? 100;
  set volume(double value) => _set('volume', value.clamp(0, 100));

  bool get shuffle => _prefs.getBool('shuffle') ?? false;
  set shuffle(bool value) => _set('shuffle', value);

  /// 0 = off, 1 = repeat all, 2 = repeat one. Matches the cycle order of the
  /// repeat button in `FullPlayerContent`.
  int get repeatMode => _prefs.getInt('repeat_mode') ?? 0;
  set repeatMode(int value) => _set('repeat_mode', value % 3);

  /// `EditTransitionScreen` — crossfade duration between tracks, in ms.
  int get crossfadeMs => _prefs.getInt('crossfade_ms') ?? 0;
  set crossfadeMs(int value) => _set('crossfade_ms', value.clamp(0, 12000));

  /// Restored on launch, the desktop equivalent of `PlaybackQueueSnapshot`.
  List<String> get lastQueue => _prefs.getStringList('last_queue') ?? const [];
  int get lastQueueIndex => _prefs.getInt('last_queue_index') ?? 0;
  int get lastPositionMs => _prefs.getInt('last_position_ms') ?? 0;

  void saveQueueSnapshot(List<String> songIds, int index, int positionMs) {
    _prefs.setStringList('last_queue', songIds);
    _prefs.setInt('last_queue_index', index);
    _prefs.setInt('last_position_ms', positionMs);
    // Snapshots are written on every track change; no listener needs them.
  }

  // ------------------------------------------------------------------- misc

  /// Arbitrary JSON blob storage for features that land in later phases
  /// (AI provider config, remote source credentials, equalizer presets).
  Map<String, dynamic> jsonMap(String key) {
    final raw = _prefs.getString(key);
    if (raw == null || raw.isEmpty) return {};
    return jsonDecode(raw) as Map<String, dynamic>;
  }

  void setJsonMap(String key, Map<String, dynamic> value) =>
      _set(key, jsonEncode(value));

  void _set(String key, Object value) {
    switch (value) {
      case bool v:
        _prefs.setBool(key, v);
      case int v:
        _prefs.setInt(key, v);
      case double v:
        _prefs.setDouble(key, v);
      case String v:
        _prefs.setString(key, v);
      case List<String> v:
        _prefs.setStringList(key, v);
      default:
        throw ArgumentError('Unsupported preference type: $value');
    }
    notifyListeners();
  }
}
