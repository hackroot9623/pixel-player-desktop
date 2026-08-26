import 'dart:io';
import 'dart:math' show max;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;
import 'package:pixelplay_desktop/data/db/database.dart';
import 'package:pixelplay_desktop/data/models/models.dart';
import 'package:pixelplay_desktop/data/models/transition.dart';
import 'package:pixelplay_desktop/data/prefs/settings.dart';
import 'package:pixelplay_desktop/state/providers.dart';
import 'package:pixelplay_desktop/data/lyrics/lrc_parser.dart';
import 'package:pixelplay_desktop/data/models/lyrics.dart';
import 'package:pixelplay_desktop/data/prefs/settings.dart' show CarouselStyle;
import 'package:pixelplay_desktop/ui/components/album_carousel.dart';
import 'package:pixelplay_desktop/ui/components/lyrics_view.dart';
import 'package:pixelplay_desktop/ui/components/playback_controls.dart';
import 'package:pixelplay_desktop/ui/components/sleep_timer_sheet.dart';
import 'package:pixelplay_desktop/ui/components/song_info_sheet.dart';
import 'package:pixelplay_desktop/ui/components/wavy_slider.dart';
import 'package:pixelplay_desktop/ui/screens/full_player_screen.dart';
import 'package:pixelplay_desktop/ui/screens/settings_screens.dart';
import 'package:pixelplay_desktop/ui/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Renders the phase-2 screens and widgets for real: they pull on the theme, the
/// squircle shapes, the carousel and the player, so a break here is exactly what
/// a user would hit on launch.
///
/// Note: several of these widgets run *indefinite* animations (the travelling
/// wave, the playing-equaliser bars), so `pumpAndSettle` would never settle and
/// would burn its ten-minute timeout. [_settle] pumps a fixed number of frames
/// instead.
Future<void> _settle(WidgetTester tester, {int frames = 8}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

/// A real, playable 0.2 s silent WAV. The full-player test drives the actual
/// player, and mpv never completes `open()` for a path that does not exist, so
/// the fixtures have to be genuine audio files.
File _writeSilentWav(String path) {
  const sampleRate = 8000;
  const samples = sampleRate ~/ 5;
  const dataBytes = samples * 2;
  final bytes = BytesBuilder();
  void ascii(String s) => bytes.add(s.codeUnits);
  void u32(int v) => bytes.add(Uint8List(4)..buffer.asByteData().setUint32(0, v, Endian.little));
  void u16(int v) => bytes.add(Uint8List(2)..buffer.asByteData().setUint16(0, v, Endian.little));

  ascii('RIFF');
  u32(36 + dataBytes);
  ascii('WAVE');
  ascii('fmt ');
  u32(16);
  u16(1); // PCM
  u16(1); // mono
  u32(sampleRate);
  u32(sampleRate * 2); // byte rate
  u16(2); // block align
  u16(16); // bits per sample
  ascii('data');
  u32(dataBytes);
  bytes.add(Uint8List(dataBytes));

  return File(path)..writeAsBytesSync(bytes.toBytes());
}

void main() {
  late Directory tmp;
  late MusicDatabase db;
  late Settings settings;

  Song song(String id, String title) => Song(
    id: id,
    title: title,
    artist: 'Artist $id',
    artistId: id.hashCode.abs(),
    album: 'Album',
    albumId: 1,
    path: _writeSilentWav(p.join(tmp.path, '$id.wav')).path,
    duration: 210000,
    mimeType: 'audio/mpeg',
    bitrate: 320000,
    sampleRate: 44100,
    genre: 'Electronic',
    year: 2021,
    trackNumber: 1,
  );

  setUp(() async {
    MediaKit.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('pixelplay_ui');
    db = await MusicDatabase.open(tmp.path);
    settings = await Settings.load();
    db.replaceLibrary([for (var i = 0; i < 5; i++) song('s$i', 'Song $i')]);
  });

  tearDown(() async {
    db.close();
    await tmp.delete(recursive: true);
  });

  ProviderContainer? container;

  Widget host(Widget child) => ProviderScope(
    overrides: [
      settingsProvider.overrideWith((ref) => settings),
      databaseProvider.overrideWithValue(db),
      artworkDirProvider.overrideWithValue(p.join(tmp.path, 'artwork')),
    ],
    child: MaterialApp(
      theme: buildTheme(brightness: Brightness.dark),
      home: Consumer(
        builder: (context, ref, _) {
          container = ProviderScope.containerOf(context);
          return child;
        },
      ),
    ),
  );

  void resize(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  testWidgets('full player shows its empty state without a queue', (
    tester,
  ) async {
    resize(tester, const Size(1400, 1000));
    await tester.pumpWidget(host(const FullPlayerScreen()));
    expect(find.text('Nothing playing'), findsOneWidget);
    // A queue-loaded render is deliberately not exercised here: `playQueue`
    // awaits mpv, and a real decoder future never completes inside the
    // fake-async zone `testWidgets` runs in, which hangs the suite rather than
    // failing it. Real playback is covered by `playback_test.dart`; the
    // populated player's parts are covered by the widget tests below.
  });

  testWidgets('pressing a transport button scales it up', (tester) async {
    await tester.pumpWidget(
      host(
        const Scaffold(
          body: Center(child: SizedBox(width: 520, child: TransportBar())),
        ),
      ),
    );
    await _settle(tester, frames: 3);

    List<double> scales() => tester
        .widgetList<Transform>(find.byType(Transform))
        .map((t) => t.transform.getMaxScaleOnAxis())
        .toList();

    // Icons and the animated glyph contribute Transforms of their own, so this
    // asserts on the range rather than a fixed count.
    for (final scale in scales()) {
      expect(scale, closeTo(1, 0.001), reason: 'unscaled at rest');
    }

    await tester.tap(find.byIcon(Icons.skip_next_rounded));
    // First pump applies the press state; the second advances the animation.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 160));
    expect(
      scales().reduce(max),
      greaterThan(1),
      reason: 'the pressed button grows',
    );
    // The neighbours' compression is driven by the same animated value, so it
    // is not asserted separately: the icons contribute their own identity
    // Transforms, and picking the right one out of the list would be testing
    // widget-tree shape rather than behaviour.
  });

  testWidgets('transport toggles flip shuffle and cycle repeat', (tester) async {
    await tester.pumpWidget(
      host(
        const Scaffold(
          body: Center(child: SizedBox(width: 520, child: TransportBar())),
        ),
      ),
    );
    await _settle(tester, frames: 3);
    final player = container!.read(playerProvider);

    expect(player.shuffle, isFalse);
    await tester.tap(find.byIcon(Icons.shuffle_rounded));
    await _settle(tester, frames: 3);
    expect(player.shuffle, isTrue);

    expect(player.repeatMode.index, 0);
    await tester.tap(find.byIcon(Icons.repeat_rounded));
    await _settle(tester, frames: 3);
    expect(player.repeatMode.index, 1);
  });

  testWidgets('wavy slider commits a seek fraction on drag', (tester) async {
    double? committed;
    await tester.pumpWidget(
      host(
        Scaffold(
          body: Center(
            child: SizedBox(
              width: 300,
              child: WavySlider(
                value: 0,
                onChangeEnd: (value) => committed = value,
              ),
            ),
          ),
        ),
      ),
    );
    await _settle(tester, frames: 2);

    await tester.drag(find.byType(WavySlider), const Offset(120, 0));
    await _settle(tester, frames: 3);
    expect(committed, isNotNull);
    expect(committed, greaterThan(0.3));
    expect(committed, lessThan(0.95));
  });

  testWidgets('sleep timer sheet arms and clears a timer', (tester) async {
    resize(tester, const Size(900, 1200));
    await tester.pumpWidget(
      host(
        Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showSleepTimerSheet(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await _settle(tester);
    expect(find.text('No timer set'), findsOneWidget);

    await tester.tap(find.textContaining('Stop after'));
    await _settle(tester);
    final player = container!.read(playerProvider);
    expect(player.sleepAfterTracks, 1);
    expect(player.sleepTimerActive, isTrue);

    player.cancelSleepTimer();
    expect(player.sleepTimerActive, isFalse);
  });

  testWidgets('palette style screen switches the scheme variant', (
    tester,
  ) async {
    resize(tester, const Size(1000, 1400));
    await tester.pumpWidget(host(const PaletteStyleScreen()));
    await _settle(tester, frames: 3);
    expect(settings.paletteStyle, DynamicSchemeVariant.tonalSpot);

    await tester.tap(find.text('Vibrant'));
    await _settle(tester, frames: 3);
    expect(settings.paletteStyle, DynamicSchemeVariant.vibrant);
  });

  testWidgets('transition editor writes mode, duration and curves', (
    tester,
  ) async {
    resize(tester, const Size(1200, 1600));
    await tester.pumpWidget(host(const TransitionEditorScreen()));
    await _settle(tester, frames: 3);
    expect(settings.transition.enabled, isFalse);

    await tester.tap(find.text(TransitionMode.overlap.label));
    await _settle(tester, frames: 3);
    expect(settings.transition.mode, TransitionMode.overlap);
    expect(settings.transition.enabled, isTrue);

    final linear = find.text(TransitionCurve.linear.label).first;
    await tester.ensureVisible(linear);
    await _settle(tester, frames: 2);
    await tester.tap(linear);
    await _settle(tester, frames: 3);
    expect(settings.transition.curveIn, TransitionCurve.linear);
  });

  testWidgets('player look screen switches the carousel style', (tester) async {
    resize(tester, const Size(1000, 1200));
    await tester.pumpWidget(host(const PlayerLookScreen()));
    await _settle(tester, frames: 3);
    expect(settings.carouselStyle, CarouselStyle.onePeek);

    await tester.tap(find.text(CarouselStyle.twoPeek.label));
    await _settle(tester, frames: 3);
    expect(settings.carouselStyle, CarouselStyle.twoPeek);
  });

  testWidgets('song info sheet lists the tags and actions', (tester) async {
    resize(tester, const Size(900, 1300));
    await tester.pumpWidget(
      host(
        Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showSongInfoSheet(context, db.allSongs().first),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await _settle(tester);
    expect(find.text('Electronic'), findsOneWidget);
    expect(find.text('44100 Hz'), findsOneWidget);
    expect(find.text('Play next'), findsOneWidget);
  });

  testWidgets('lyrics view renders synced lines and seeks on click', (
    tester,
  ) async {
    resize(tester, const Size(900, 1000));
    final lyrics = parseLyrics(
      '[00:01.00]First line\n[00:05.00]Second line',
      source: LyricsSource.local,
    )!;
    await tester.pumpWidget(host(Scaffold(body: LyricsView(lyrics: lyrics))));
    await _settle(tester, frames: 3);

    expect(find.text('First line'), findsOneWidget);
    expect(find.text('Second line'), findsOneWidget);

    // `find.ancestor` walks outwards, so the first match is the line's own
    // style wrapper rather than one of the inherited ones above it.
    TextStyle styleOf(String text) => tester
        .firstWidget<AnimatedDefaultTextStyle>(
          find.ancestor(
            of: find.text(text),
            matching: find.byType(AnimatedDefaultTextStyle),
          ),
        )
        .style;

    // Position 0 sits before the first line, so nothing is emphasised yet.
    expect(styleOf('First line').fontWeight, FontWeight.w500);

    // Clicking a line asks the player to seek. With no queue loaded that is a
    // no-op, but it must not throw.
    await tester.tap(find.text('Second line'));
    await _settle(tester, frames: 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('album carousel survives index changes and rebuilds', (
    tester,
  ) async {
    resize(tester, const Size(900, 900));
    final songs = db.allSongs();

    Widget carouselAt(int index) => host(
      Scaffold(
        body: AlbumCarousel(
          height: 300,
          songs: songs,
          index: index,
          playing: true,
          style: CarouselStyle.onePeek,
          onTapCurrent: (_) {},
          onTapOther: (_) {},
        ),
      ),
    );

    await tester.pumpWidget(carouselAt(0));
    await _settle(tester, frames: 3);
    expect(find.byType(CarouselView), findsOneWidget);

    // The crash this guards: the controller used to be created and disposed
    // inside `build`, so CarouselView.didUpdateWidget read `position` off a
    // detached controller and tore down the engine. Walking the index forces
    // exactly that update path.
    for (var index = 1; index < songs.length; index++) {
      await tester.pumpWidget(carouselAt(index));
      await _settle(tester, frames: 3);
      expect(tester.takeException(), isNull, reason: 'at index $index');
    }
  });

  test('carousel weights are identity-stable', () {
    // CarouselView compares flexWeights with `!=` in didUpdateWidget, so a
    // freshly allocated list each frame made it reach into the scroll position
    // on every rebuild.
    for (final style in CarouselStyle.values) {
      expect(identical(style.flexWeights, style.flexWeights), isTrue);
    }
  });

  test('transition curves are monotonic and normalised', () {
    for (final curve in TransitionCurve.values) {
      expect(curve.apply(0), closeTo(0, 0.001), reason: curve.name);
      expect(curve.apply(1), closeTo(1, 0.001), reason: curve.name);
      var previous = -1.0;
      for (var i = 0; i <= 20; i++) {
        final value = curve.apply(i / 20);
        expect(value, greaterThanOrEqualTo(previous), reason: curve.name);
        previous = value;
      }
    }
  });
}
