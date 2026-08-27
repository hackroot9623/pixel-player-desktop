import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:window_manager/window_manager.dart';

import 'data/db/database.dart';
import 'data/prefs/settings.dart';
import 'platform/single_instance.dart';
import 'state/providers.dart';
import 'ui/components/window_controls.dart';
import 'ui/screens/setup_screen.dart';
import 'ui/shell/app_shell.dart';
import 'ui/theme/app_theme.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  // Before anything visible: a second copy hands its files to the first and
  // leaves, rather than opening a window and fighting for the audio device.
  final supportDir = await getApplicationSupportDirectory();
  final instance = await SingleInstance.claim(
    args,
    stateDirectory: supportDir.path,
  );
  if (instance == null) {
    exit(0);
  }

  MediaKit.ensureInitialized();
  await windowManager.ensureInitialized();
  await windowManager.waitUntilReadyToShow(
    const WindowOptions(
      size: Size(1360, 860),
      // Small enough to be a desk-corner player. Below the compact breakpoint
      // the shell drops the library and becomes just the player.
      minimumSize: Size(320, 180),
      title: 'PixelPlayer',
    ),
    () async {
      await windowManager.show();
      await windowManager.focus();
    },
  );

  final settings = await Settings.load();
  // Before the first frame, so the window never flashes the wrong decorations.
  await applyWindowDecorations(
    useCustomTitleBar: settings.useCustomTitleBar,
  );
  final db = await MusicDatabase.open(supportDir.path);
  final artworkDir = p.join(supportDir.path, 'artwork');

  // Folders configured in prefs are mirrored into the table so the two stay in
  // step across upgrades.
  for (final folder in settings.musicFolders) {
    db.addFolder(folder);
  }

  runApp(
    ProviderScope(
      overrides: [
        settingsProvider.overrideWith((ref) => settings),
        databaseProvider.overrideWithValue(db),
        artworkDirProvider.overrideWithValue(artworkDir),
        singleInstanceProvider.overrideWithValue(instance),
        initialFilesProvider.overrideWithValue(openableFiles(args)),
      ],
      child: const PixelPlayApp(),
    ),
  );
}

class PixelPlayApp extends ConsumerStatefulWidget {
  const PixelPlayApp({super.key});

  @override
  ConsumerState<PixelPlayApp> createState() => _PixelPlayAppState();
}

class _PixelPlayAppState extends ConsumerState<PixelPlayApp> {
  bool _setupDone = false;
  StreamSubscription<List<String>>? _opened;

  @override
  void initState() {
    super.initState();
    _setupDone = ref.read(settingsProvider).setupComplete;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final opened = ref.read(initialFilesProvider);
      // Files given on the command line win over the saved queue: the user
      // double-clicked something and expects to hear it, not what they were
      // listening to yesterday.
      if (opened.isEmpty) {
        await ref.read(playerProvider).restoreQueue();
      } else {
        await openFiles(ref, opened);
      }
      // Publishes the player on MPRIS2 where there is a session bus, which is
      // what makes the media keys and the desktop's own media widget work.
      ref.read(mprisProvider);
      ref.read(notificationsProvider);
      // Installs the tray icon if the user has asked for one; harmless if not.
      await applyTraySettings(ref);
      _listenForOpenedFiles();
    });
  }

  /// Files handed over by a later launch: play them and come to the front, the
  /// way opening a file in any other player does.
  void _listenForOpenedFiles() {
    final instance = ref.read(singleInstanceProvider);
    if (instance == null) return;
    _opened = instance.opened.listen((files) async {
      await openFiles(ref, files);
      await windowManager.show();
      await windowManager.focus();
    });
  }

  @override
  void dispose() {
    _opened?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final scheme = ref.watch(albumArtSchemeProvider).valueOrNull;

    return MaterialApp(
      title: 'PixelPlayer',
      debugShowCheckedModeBanner: false,
      themeMode: settings.themeMode,
      // Default is 200 ms of linear cross-fade; a shorter ease reads as the
      // colours snapping to the new track rather than drifting into it.
      themeAnimationDuration: const Duration(milliseconds: 240),
      themeAnimationCurve: Curves.easeOutCubic,
      // Above the root navigator, so the title bar and resize handles are on
      // every screen — including routes pushed over the shell.
      builder: (context, child) =>
          WindowChrome(child: child ?? const SizedBox.shrink()),
      theme: buildTheme(
        brightness: Brightness.light,
        schemeOverride: scheme?.$1,
        seed: settings.seedColor,
        variant: settings.paletteStyle,
      ),
      darkTheme: buildTheme(
        brightness: Brightness.dark,
        schemeOverride: scheme?.$2,
        seed: settings.seedColor,
        variant: settings.paletteStyle,
      ),
      home: _setupDone
          ? const AppShell()
          : SetupScreen(
              onDone: () {
                ref.read(settingsProvider).setupComplete = true;
                setState(() => _setupDone = true);
              },
            ),
    );
  }
}
