import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/models.dart';
import '../../state/providers.dart';
import '../screens/full_player_screen.dart';
import '../theme/shapes.dart';
import 'album_art.dart';
import 'common.dart';
import 'playback_controls.dart';
import 'queue_panel.dart';
import 'window_size_presets.dart';

const miniPlayerHeight = 84.0;

/// Port of `UnifiedPlayerSheetV2`'s collapsed state — always docked at the
/// bottom of the shell, expands into the full player.
class MiniPlayer extends ConsumerWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final song = ref.watch(playerProvider.select((p) => p.current));
    if (song == null) return const SizedBox.shrink();
    return MiniPlayerBar(song: song);
  }
}

/// The docked bar itself.
///
/// Takes the song rather than reading it from the player, so it can be rendered
/// at narrow widths in a test — which is what the overflowing row needed.
class MiniPlayerBar extends ConsumerWidget {
  const MiniPlayerBar({super.key, required this.song});

  final Song song;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(playerProvider);
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: Material(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(shapeLarge),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          height: miniPlayerHeight,
          child: Column(
            children: [
              // Thin progress line. Scoped to the position listenable so the
              // rest of the bar is not rebuilt many times a second.
              SizedBox(
                height: 4,
                child: PositionBuilder(
                  builder: (context, position) {
                    final total = player.duration.inMilliseconds;
                    return LinearProgressIndicator(
                      value: total <= 0
                          ? 0
                          : (position.inMilliseconds / total).clamp(0.0, 1.0),
                      minHeight: 4,
                      backgroundColor:
                          theme.colorScheme.surfaceContainerHighest,
                    );
                  },
                ),
              ),
              Expanded(
                // The row carries ~760px of fixed content when everything is
                // shown, but the shell is only ~515px wide at its narrowest, so
                // the optional pieces drop out as space runs out rather than
                // overflowing.
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final width = constraints.maxWidth;
                    final showTimes = width >= 560;
                    final showVolume = width >= 640;
                    final showQueue = width >= 720;
                    final showWindowActions = width >= 820;
                    final showToggles = width >= 470;

                    return Row(
                      children: [
                        InkWell(
                          onTap: () => openFullPlayer(context),
                          child: Padding(
                            padding: const EdgeInsets.all(8),
                            child: AlbumArt(
                              path: song.albumArtPath,
                              size: 60,
                              radius: shapeMedium,
                              heroTag: 'now-playing-art',
                            ),
                          ),
                        ),
                        Expanded(
                          child: InkWell(
                            onTap: () => openFullPlayer(context),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                              ),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
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
                          ),
                        ),
                        if (showTimes) ...[
                          PositionBuilder(
                            builder: (context, position) => Text(
                              '${formatDuration(position)} / '
                              '${formatDuration(player.duration)}',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                        ],
                        TransportBar(compact: true, showToggles: showToggles),
                        const SizedBox(width: 8),
                        if (showVolume) const _VolumeControl(),
                        if (showQueue)
                          IconButton(
                            tooltip: 'Queue',
                            icon: const Icon(Icons.queue_music_rounded),
                            onPressed: () => showQueuePanel(context),
                          ),
                        if (showWindowActions) ...[
                          IconButton(
                            tooltip: 'Shrink to the player',
                            icon: const Icon(Icons.compress_rounded),
                            onPressed: () =>
                                applyWindowSizePreset(WindowSizePreset.player),
                          ),
                          IconButton(
                            tooltip: 'Expand',
                            icon: const Icon(Icons.keyboard_arrow_up_rounded),
                            onPressed: () => openFullPlayer(context),
                          ),
                        ],
                        const SizedBox(width: 4),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _VolumeControl extends ConsumerWidget {
  const _VolumeControl();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(playerProvider);
    return MenuAnchor(
      builder: (context, controller, _) => IconButton(
        tooltip: 'Volume',
        icon: Icon(
          player.volume == 0
              ? Icons.volume_off_rounded
              : player.volume < 50
              ? Icons.volume_down_rounded
              : Icons.volume_up_rounded,
        ),
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
      ),
      menuChildren: [
        SizedBox(
          width: 200,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Slider(
              value: player.volume,
              max: 100,
              onChanged: ref.read(playerProvider).setVolume,
            ),
          ),
        ),
      ],
    );
  }
}
