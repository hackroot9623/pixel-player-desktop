import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/providers.dart';
import '../components/album_art.dart';
import '../components/common.dart';
import '../components/playback_controls.dart';
import '../components/window_controls.dart';
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

/// Below this, even the track text is dropped: artwork plus transport only.
const _tinyWidthBreakpoint = 420.0;

/// The whole app, shrunk to a player: artwork, what is playing, a seek bar and
/// the transport. Shown automatically when the window is resized small, and
/// replaced by the full shell again when it grows.
class CompactPlayer extends ConsumerWidget {
  const CompactPlayer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(playerProvider);
    final song = player.current;
    final theme = Theme.of(context);

    if (song == null) {
      return Center(
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
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final tiny = constraints.maxWidth < _tinyWidthBreakpoint;
        final artSide = constraints.maxHeight.clamp(0.0, 132.0);

        return Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            spacing: 12,
            children: [
              // Tapping the artwork opens the full player, which stays usable
              // at this size as an overlay.
              GestureDetector(
                onTap: () => openFullPlayer(context),
                child: AlbumArt(
                  path: song.albumArtPath,
                  size: artSide,
                  radius: shapeMedium,
                ),
              ),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (!tiny) ...[
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
                      const SizedBox(height: 6),
                    ],
                    // Thin seek bar plus times, scoped to the position
                    // listenable like everywhere else.
                    PositionBuilder(
                      builder: (context, position) {
                        final total = player.duration.inMilliseconds;
                        final fraction = total <= 0
                            ? 0.0
                            : (position.inMilliseconds / total).clamp(0.0, 1.0);
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            SizedBox(
                              height: 18,
                              child: Slider(
                                value: fraction,
                                onChanged: player.seekFraction,
                              ),
                            ),
                            if (!tiny)
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 2,
                                ),
                                child: Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(
                                      formatDuration(position),
                                      style: theme.textTheme.labelSmall,
                                    ),
                                    Text(
                                      formatDuration(player.duration),
                                      style: theme.textTheme.labelSmall,
                                    ),
                                  ],
                                ),
                              ),
                          ],
                        );
                      },
                    ),
                    const SizedBox(height: 4),
                    const TransportBar(compact: true),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
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
