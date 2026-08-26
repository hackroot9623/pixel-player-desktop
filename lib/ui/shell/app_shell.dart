import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/providers.dart';
import '../components/mini_player.dart';
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
    (icon: Icons.search_rounded, selected: Icons.search_rounded, label: 'Search'),
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

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final radius = settings.navBarCornerRadius;
    return Scaffold(
      body: Row(
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
      ),
    );
  }
}
