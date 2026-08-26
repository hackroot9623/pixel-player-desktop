import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/lyrics.dart';
import '../models/sort_option.dart';
import '../models/transition.dart';
import '../scanner/library_scanner.dart';

/// How much of the neighbouring artwork peeks in beside the current track in
/// the full player's carousel. Ported from `CarouselStyle` in the Android
/// player settings.
enum CarouselStyle {
  noPeek('No peek', [1]),
  onePeek('One peek', [7, 1]),
  twoPeek('Two peek', [1, 7, 1]);

  const CarouselStyle(this.label, this.flexWeights);

  final String label;

  /// Weights handed to `CarouselView.weighted`, which is Flutter's
  /// implementation of the same M3 multi-browse layout the Kotlin
  /// `RoundedHorizontalMultiBrowseCarousel` reimplements.
  ///
  /// Const, and passed through by identity: `CarouselView` compares this list
  /// with `!=` in `didUpdateWidget`, so building a fresh list each frame made it
  /// reach into the scroll position on every rebuild.
  final List<int> flexWeights;

  /// Carousel height as a fraction of its width, matching
  /// `FullPlayerAlbumCoverSection`.
  double get heightFactor => switch (this) {
    CarouselStyle.noPeek => 1.0,
    CarouselStyle.onePeek => 0.8,
    CarouselStyle.twoPeek => 0.6,
  };
}

/// Which corner of the client-side title bar holds the window controls.
/// The two placements people actually expect: GNOME/Windows on the right,
/// macOS on the left.
enum WindowControlsPlacement {
  topRight('Right'),
  topLeft('Left');

  const WindowControlsPlacement(this.label);

  final String label;
}

/// How the window controls are drawn.
enum WindowControlsStyle {
  glyphs('Glyphs', 'Minimise, maximise and close icons'),
  dots('Traffic lights', 'Three coloured dots, macOS style');

  const WindowControlsStyle(this.label, this.description);

  final String label;
  final String description;
}

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

  /// `PaletteStyleSettingsScreen` — which Material tonal-palette algorithm the
  /// seed (or album art) colour is expanded through.
  DynamicSchemeVariant get paletteStyle =>
      DynamicSchemeVariant.values[_prefs.getInt('palette_style') ??
          DynamicSchemeVariant.tonalSpot.index];
  set paletteStyle(DynamicSchemeVariant value) =>
      _set('palette_style', value.index);

  /// `NavBarCornerRadiusScreen`.
  double get navBarCornerRadius =>
      _prefs.getDouble('nav_bar_corner_radius') ?? 28;
  set navBarCornerRadius(double value) =>
      _set('nav_bar_corner_radius', value.clamp(0, 48));

  bool get showScrollbar => _prefs.getBool('show_scrollbar') ?? true;
  set showScrollbar(bool value) => _set('show_scrollbar', value);

  // ----------------------------------------------------------------- window

  /// Hide the system title bar and draw our own, so the UI reaches the window
  /// edges. Off by default: the desktop's own decorations are the safe default,
  /// and on an unusual compositor they are the only ones that work.
  bool get useCustomTitleBar => _prefs.getBool('custom_title_bar') ?? false;
  set useCustomTitleBar(bool value) => _set('custom_title_bar', value);

  WindowControlsPlacement get windowControlsPlacement =>
      WindowControlsPlacement.values[_prefs.getInt('window_controls_side') ??
          WindowControlsPlacement.topRight.index];
  set windowControlsPlacement(WindowControlsPlacement value) =>
      _set('window_controls_side', value.index);

  WindowControlsStyle get windowControlsStyle =>
      WindowControlsStyle.values[_prefs.getInt('window_controls_style') ??
          WindowControlsStyle.glyphs.index];
  set windowControlsStyle(WindowControlsStyle value) =>
      _set('window_controls_style', value.index);

  /// `CarouselStyle` in the player settings: how much of the neighbouring
  /// artwork peeks in beside the current track.
  CarouselStyle get carouselStyle =>
      CarouselStyle.values[_prefs.getInt('carousel_style') ??
          CarouselStyle.onePeek.index];
  set carouselStyle(CarouselStyle value) => _set('carousel_style', value.index);

  /// `showPlayerFileInfo` — the format/bitrate/sample-rate line under the seek
  /// bar in the full player.
  bool get showPlayerFileInfo => _prefs.getBool('player_file_info') ?? true;
  set showPlayerFileInfo(bool value) => _set('player_file_info', value);

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

  // ----------------------------------------------------------------- lyrics

  /// `LyricsSourcePreference` — which lyrics source is consulted first.
  LyricsSourcePreference get lyricsSource =>
      LyricsSourcePreference.values[_prefs.getInt('lyrics_source') ??
          LyricsSourcePreference.embeddedFirst.index];
  set lyricsSource(LyricsSourcePreference value) =>
      _set('lyrics_source', value.index);

  /// Look lyrics up on LRCLIB automatically when a track has none locally.
  bool get autoFetchLyrics => _prefs.getBool('lyrics_auto_fetch') ?? true;
  set autoFetchLyrics(bool value) => _set('lyrics_auto_fetch', value);

  /// Whether the full player opens with the lyrics pane instead of the queue.
  bool get showLyricsPane => _prefs.getBool('lyrics_pane') ?? false;
  set showLyricsPane(bool value) => _set('lyrics_pane', value);

  /// `EditTransitionScreen` — the global transition between tracks.
  TransitionSettings get transition =>
      TransitionSettings.fromJson(jsonMap('transition'));
  set transition(TransitionSettings value) =>
      setJsonMap('transition', value.toJson());

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
