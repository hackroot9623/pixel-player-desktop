import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/models.dart';
import '../../player/player_service.dart';
import '../../state/providers.dart';
import '../components/album_art.dart';
import '../components/common.dart';
import '../components/playback_controls.dart';
import '../components/window_controls.dart';
import '../components/window_size_presets.dart';
import '../screens/full_player_screen.dart';
import '../theme/shapes.dart';

/// Below this the shell drops the navigation rail and the library entirely and
/// becomes a player widget — the window is too small to browse in.
const compactWidthBreakpoint = 620.0;
const compactHeightBreakpoint = 440.0;

/// True when the window is too small for the browsing UI.
///
/// Pure so the breakpoint is testable without laying out a window.
bool isCompactSize(Size size) =>
    size.width < compactWidthBreakpoint ||
    size.height < compactHeightBreakpoint;

/// How the compact player arranges itself.
enum CompactLayout {
  /// Tall window: large centred artwork, text under it, transport at the
  /// bottom.
  portrait,

  /// Short window: artwork beside the text and transport, in one strip.
  strip,
}

/// Enough height to give the artwork a column of its own; below it, the strip
/// is the only arrangement that fits.
const _portraitMinHeight = 380.0;

/// Below this, even the track text and times are dropped.
const _tinyWidth = 420.0;

/// Chooses the arrangement from the available space.
///
/// Pure, so the rules are testable without rendering.
CompactLayout compactLayoutFor(Size size) => size.height >= _portraitMinHeight
    ? CompactLayout.portrait
    : CompactLayout.strip;

/// The preset whose shape the window currently matches, for highlighting.
WindowSizePreset? matchingPreset(Size size) {
  for (final preset in WindowSizePreset.values) {
    if ((size.width - preset.size.width).abs() < 80 &&
        (size.height - preset.size.height).abs() < 80) {
      return preset;
    }
  }
  return null;
}

/// The whole app, shrunk to a player. Shown automatically when the window is
/// resized small, and replaced by the full shell again when it grows.
class CompactPlayer extends ConsumerWidget {
  const CompactPlayer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(playerProvider);
    final song = player.current;

    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        final layout = compactLayoutFor(size);
        final presets = WindowSizePresetButtons(current: matchingPreset(size));

        if (song == null) return _Idle(presets: presets);

        return switch (layout) {
          CompactLayout.portrait => _PortraitPlayer(
            song: song,
            presets: presets,
            available: size,
          ),
          CompactLayout.strip => _StripPlayer(
            song: song,
            presets: presets,
            available: size,
          ),
        };
      },
    );
  }
}

class _Idle extends StatelessWidget {
  const _Idle({required this.presets});

  final Widget presets;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Stack(
      children: [
        Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.music_note_rounded,
                  size: 32,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(height: 12),
                Text(
                  'Nothing playing',
                  style: theme.textTheme.titleSmall,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 4),
                Text(
                  'Make the window bigger to browse your library',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
        Positioned(top: 4, right: 4, child: presets),
      ],
    );
  }
}

/// Tall window: the artwork gets the room it deserves.
class _PortraitPlayer extends ConsumerWidget {
  const _PortraitPlayer({
    required this.song,
    required this.presets,
    required this.available,
  });

  final Song song;
  final Widget presets;
  final Size available;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(playerProvider);
    final theme = Theme.of(context);
    // Leave room for the text, seek bar and transport; the artwork takes what
    // is left, square, and never wider than the window.
    final side = (available.height - 210).clamp(80.0, available.width - 40);

    return Column(
      children: [
        Align(alignment: Alignment.topRight, child: presets),
        Expanded(
          child: Center(
            child: GestureDetector(
              onTap: () => openFullPlayer(context),
              child: AlbumArt(path: song.albumArtPath, size: side, radius: 20),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Column(
            children: [
              Text(
                song.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium,
              ),
              Text(
                song.displayArtist,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 10),
              _SeekBar(player: player),
              const SizedBox(height: 6),
              const TransportBar(),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ],
    );
  }
}

/// Short window: one horizontal strip.
class _StripPlayer extends ConsumerWidget {
  const _StripPlayer({
    required this.song,
    required this.presets,
    required this.available,
  });

  final Song song;
  final Widget presets;
  final Size available;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(playerProvider);
    final theme = Theme.of(context);
    final tiny = available.width < _tinyWidth;
    final side = (available.height - 20).clamp(48.0, 132.0);

    return Padding(
      padding: const EdgeInsets.all(10),
      child: Row(
        spacing: 12,
        children: [
          GestureDetector(
            onTap: () => openFullPlayer(context),
            child: AlbumArt(
              path: song.albumArtPath,
              size: side,
              radius: shapeMedium,
            ),
          ),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!tiny)
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              song.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleSmall,
                            ),
                            Text(
                              song.displayArtist,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      presets,
                    ],
                  ),
                _SeekBar(player: player, showTimes: !tiny),
                const TransportBar(compact: true),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SeekBar extends StatelessWidget {
  const _SeekBar({required this.player, this.showTimes = true});

  final PlayerService player;
  final bool showTimes;

  @override
  Widget build(BuildContext context) => PositionBuilder(
    builder: (context, position) {
      final total = player.duration.inMilliseconds;
      final fraction = total <= 0
          ? 0.0
          : (position.inMilliseconds / total).clamp(0.0, 1.0);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 20,
            child: Slider(value: fraction, onChanged: player.seekFraction),
          ),
          if (showTimes)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    formatDuration(position),
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                  Text(
                    formatDuration(player.duration),
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ],
              ),
            ),
        ],
      );
    },
  );
}

/// The compact shell: the client-side title bar (when enabled) above the
/// compact player, and nothing else.
class CompactShell extends StatelessWidget {
  const CompactShell({super.key});

  @override
  Widget build(BuildContext context) => const Column(
    children: [
      // Still needed here: with system decorations off, this is the only way to
      // close or move the window.
      WindowTitleBar(),
      Expanded(child: CompactPlayer()),
    ],
  );
}
