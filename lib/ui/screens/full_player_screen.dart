import 'package:flutter/material.dart' hide RepeatMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../player/player_service.dart';
import '../../state/providers.dart';
import '../components/album_art.dart';
import '../components/common.dart';
import '../components/library_widgets.dart';
import '../components/queue_panel.dart';
import '../components/wavy_slider.dart';
import '../navigation.dart';
import '../theme/shapes.dart';

void openFullPlayer(BuildContext context) =>
    Navigator.of(context, rootNavigator: true).push(
  PageRouteBuilder<void>(
    transitionDuration: const Duration(milliseconds: 320),
    reverseTransitionDuration: const Duration(milliseconds: 240),
    pageBuilder: (context, animation, _) => FadeTransition(
      opacity: animation,
      child: SlideTransition(
        position: Tween(
          begin: const Offset(0, 0.06),
          end: Offset.zero,
        ).animate(
          CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
        ),
        child: const FullPlayerScreen(),
      ),
    ),
  ),
);

/// Port of `presentation/components/player/FullPlayerContent`, laid out for a
/// wide window: artwork and transport on the left, queue docked on the right.
class FullPlayerScreen extends ConsumerWidget {
  const FullPlayerScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(playerProvider);
    final song = player.current;
    final theme = Theme.of(context);
    if (song == null) {
      return const Scaffold(
        body: EmptyState(
          icon: Icons.music_note_rounded,
          title: 'Nothing playing',
        ),
      );
    }

    return Scaffold(
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              theme.colorScheme.primaryContainer.withValues(alpha: 0.55),
              theme.colorScheme.surface,
              theme.colorScheme.surface,
            ],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              Row(
                children: [
                  IconButton(
                    tooltip: 'Close',
                    icon: const Icon(Icons.keyboard_arrow_down_rounded),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  Expanded(
                    child: Center(
                      child: Text(
                        'Now playing',
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                  SongMenuButton(song: song),
                  const SizedBox(width: 8),
                ],
              ),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final wide = constraints.maxWidth > 1000;
                    final content = _NowPlayingPane(compact: !wide);
                    if (!wide) return content;
                    return Row(
                      children: [
                        Expanded(child: content),
                        const Padding(
                          padding: EdgeInsets.only(right: 16, bottom: 16),
                          child: ClipRRect(
                            borderRadius: BorderRadius.all(
                              Radius.circular(shapeLarge),
                            ),
                            child: QueuePanel(),
                          ),
                        ),
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

class _NowPlayingPane extends ConsumerWidget {
  const _NowPlayingPane({required this.compact});

  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(playerProvider);
    final song = player.current!;
    final theme = Theme.of(context);

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              LayoutBuilder(
                builder: (context, constraints) {
                  final side = (compact ? 320.0 : 420.0).clamp(
                    180.0,
                    constraints.maxWidth,
                  );
                  return AlbumArt(
                    path: song.albumArtPath,
                    size: side,
                    radius: 32,
                    heroTag: 'now-playing-art',
                  );
                },
              ),
              const SizedBox(height: 32),
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          song.title,
                          maxLines: 2,
                          style: theme.textTheme.headlineSmall,
                        ),
                        const SizedBox(height: 4),
                        InkWell(
                          borderRadius: BorderRadius.circular(8),
                          onTap: () =>
                              openArtist(context, song.primaryArtist.id),
                          child: Text(
                            song.displayArtist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall?.copyWith(
                              color: theme.colorScheme.primary,
                            ),
                          ),
                        ),
                        InkWell(
                          borderRadius: BorderRadius.circular(8),
                          onTap: () => openAlbum(context, song.albumId),
                          child: Text(
                            song.album,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton.filledTonal(
                    tooltip: song.isFavorite ? 'Unlike' : 'Like',
                    icon: Icon(
                      song.isFavorite
                          ? Icons.favorite_rounded
                          : Icons.favorite_border_rounded,
                    ),
                    onPressed: () =>
                        ref.read(libraryProvider.notifier).toggleFavorite(song),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              WavySlider(
                value: player.progress,
                animate: player.playing,
                onChanged: (_) {},
                onChangeEnd: player.seekFraction,
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      formatDuration(player.position),
                      style: theme.textTheme.bodySmall,
                    ),
                    Text(
                      formatDuration(player.duration),
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    tooltip: 'Shuffle',
                    isSelected: player.shuffle,
                    icon: const Icon(Icons.shuffle_rounded),
                    selectedIcon: Icon(
                      Icons.shuffle_rounded,
                      color: theme.colorScheme.primary,
                    ),
                    onPressed: player.toggleShuffle,
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: 'Previous',
                    iconSize: 34,
                    icon: const Icon(Icons.skip_previous_rounded),
                    onPressed: player.previous,
                  ),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 76,
                    height: 76,
                    child: FloatingActionButton.large(
                      elevation: 0,
                      shape: const CircleBorder(),
                      onPressed: player.toggle,
                      child: Icon(
                        player.playing
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                        size: 38,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  IconButton(
                    tooltip: 'Next',
                    iconSize: 34,
                    icon: const Icon(Icons.skip_next_rounded),
                    onPressed: player.next,
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: switch (player.repeatMode) {
                      RepeatMode.off => 'Repeat off',
                      RepeatMode.all => 'Repeat all',
                      RepeatMode.one => 'Repeat one',
                    },
                    isSelected: player.repeatMode != RepeatMode.off,
                    icon: Icon(
                      player.repeatMode == RepeatMode.one
                          ? Icons.repeat_one_rounded
                          : Icons.repeat_rounded,
                      color: player.repeatMode == RepeatMode.off
                          ? null
                          : theme.colorScheme.primary,
                    ),
                    onPressed: player.cycleRepeatMode,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (compact)
                TextButton.icon(
                  onPressed: () => showQueuePanel(context),
                  icon: const Icon(Icons.queue_music_rounded),
                  label: Text('Queue · ${player.queue.length}'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
