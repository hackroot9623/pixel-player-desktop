import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/providers.dart';
import '../components/mini_player.dart';
import 'compact_player.dart';
import 'typing_barrier.dart';
import '../navigation.dart';
import '../screens/home_screen.dart';
import '../screens/library_screen.dart';
import '../screens/search_screen.dart';

/// Replaces `MainActivity` + `AppNavigation`'s bottom bar. On desktop the three
/// root destinations live in a navigation rail; detail screens push into the
/// content area so the mini player stays docked.
class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  final _navigatorKey = GlobalKey<NavigatorState>();
  int _index = 0;

  static const _destinations = [
    (icon: Icons.home_outlined, selected: Icons.home_rounded, label: 'Home'),
    (
      icon: Icons.search_rounded,
      selected: Icons.search_rounded,
      label: 'Search',
    ),
    (
      icon: Icons.library_music_outlined,
      selected: Icons.library_music_rounded,
      label: 'Library',
    ),
  ];

  void _select(int index) {
    // Tapping a rail destination always returns to the root of that section,
    // matching `navigateSafelyReplacing` on Android.
    _navigatorKey.currentState?.popUntil((route) => route.isFirst);
    setState(() => _index = index);
  }

  /// Desktop keyboard control. Media keys themselves need MPRIS, which is
  /// phase 7; these are the in-window equivalents.
  Map<ShortcutActivator, VoidCallback> _shortcuts() {
    final player = ref.read(playerProvider);
    void nudge(int seconds) => player.seek(
      Duration(
        milliseconds: (player.position.inMilliseconds + seconds * 1000).clamp(
          0,
          player.duration.inMilliseconds,
        ),
      ),
    );
    return {
      const SingleActivator(LogicalKeyboardKey.space): player.toggle,
      const SingleActivator(LogicalKeyboardKey.mediaPlay): player.toggle,
      const SingleActivator(LogicalKeyboardKey.arrowRight): () => nudge(5),
      const SingleActivator(LogicalKeyboardKey.arrowLeft): () => nudge(-5),
      const SingleActivator(LogicalKeyboardKey.arrowRight, shift: true):
          player.next,
      const SingleActivator(LogicalKeyboardKey.arrowLeft, shift: true):
          player.previous,
      const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
          player.setVolume((player.volume + 5).clamp(0, 100)),
      const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
          player.setVolume((player.volume - 5).clamp(0, 100)),
      const SingleActivator(LogicalKeyboardKey.keyS): player.toggleShuffle,
      const SingleActivator(LogicalKeyboardKey.keyR): player.cycleRepeatMode,
      const SingleActivator(LogicalKeyboardKey.keyL): () {
        final song = player.current;
        if (song != null) {
          ref.read(libraryProvider.notifier).toggleFavorite(song);
        }
      },
    };
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final radius = settings.navBarCornerRadius;
    final bindings = _shortcuts();
    return CallbackShortcuts(
      bindings: bindings,
      // Below the shortcuts, so it can stop a key before it gets there: these
      // are single-key bindings, and a text field does not mark its characters
      // as handled.
      child: TypingShortcutBarrier(
        activators: bindings.keys,
        child: Focus(autofocus: true, child: _body(radius)),
      ),
    );
  }

  Widget _body(double radius) {
    return Scaffold(
      // The title bar and resize handles live in WindowChrome, above the root
      // navigator, so they survive every route.
      body: LayoutBuilder(
        builder: (context, constraints) {
          // Too small to browse in: become a player.
          if (isCompactSize(constraints.biggest)) return const CompactShell();
          return _content(radius);
        },
      ),
    );
  }

  Widget _content(double radius) {
    return Row(
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(radius),
            child: NavigationRail(
              selectedIndex: _index,
              onDestinationSelected: _select,
              groupAlignment: -0.85,
              leading: Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Image.asset(
                  'assets/images/icon.png',
                  width: 34,
                  height: 34,
                ),
              ),
              trailing: Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    IconButton(
                      tooltip: 'Statistics',
                      icon: const Icon(Icons.bar_chart_rounded),
                      onPressed: () => openStats(context),
                    ),
                    IconButton(
                      tooltip: 'Settings',
                      icon: const Icon(Icons.settings_rounded),
                      onPressed: () => openSettings(context),
                    ),
                    const SizedBox(height: 16),
                  ],
                ),
              ),
              destinations: [
                for (final d in _destinations)
                  NavigationRailDestination(
                    icon: Icon(d.icon),
                    selectedIcon: Icon(d.selected),
                    label: Text(d.label),
                  ),
              ],
            ),
          ),
        ),
        Expanded(
          child: Column(
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.only(
                    topLeft: Radius.circular(radius),
                    bottomLeft: Radius.circular(radius),
                  ),
                  child: Navigator(
                    key: _navigatorKey,
                    onGenerateRoute: (_) => MaterialPageRoute<void>(
                      builder: (_) => IndexedStack(
                        index: _index,
                        children: const [
                          HomeScreen(),
                          SearchScreen(),
                          LibraryScreen(),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              const MiniPlayer(),
            ],
          ),
        ),
      ],
    );
  }
}
