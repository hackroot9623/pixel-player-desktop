import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/providers.dart';
import '../theme/shapes.dart';
import 'album_art.dart';
import 'common.dart';

/// Port of `QueueBottomSheet` — reorderable now-playing queue. On desktop it
/// docks as an end drawer instead of a bottom sheet.
Future<void> showQueuePanel(BuildContext context) => showGeneralDialog<void>(
  context: context,
  barrierDismissible: true,
  barrierLabel: 'Queue',
  barrierColor: Colors.black26,
  transitionDuration: const Duration(milliseconds: 220),
  pageBuilder: (context, animation, _) => Align(
    alignment: Alignment.centerRight,
    child: SlideTransition(
      position: Tween(
        begin: const Offset(1, 0),
        end: Offset.zero,
      ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
      child: const QueuePanel(),
    ),
  ),
);

class QueuePanel extends ConsumerWidget {
  const QueuePanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(playerProvider);
    final theme = Theme.of(context);
    final total = Duration(
      milliseconds: player.queue.fold(0, (sum, s) => sum + s.duration),
    );
    return Material(
      color: theme.colorScheme.surfaceContainerLow,
      child: SizedBox(
        width: 420,
        height: double.infinity,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 12, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Queue', style: theme.textTheme.headlineSmall),
                        Text(
                          '${plural(player.queue.length, 'song')} · '
                          '${formatLongDuration(total)}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Clear queue',
                    icon: const Icon(Icons.playlist_remove_rounded),
                    onPressed: player.clear,
                  ),
                  IconButton(
                    tooltip: 'Close',
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: player.queue.isEmpty
                  ? const EmptyState(
                      icon: Icons.queue_music_rounded,
                      title: 'Queue is empty',
                      message: 'Play something to fill it up.',
                    )
                  : ReorderableListView.builder(
                      padding: const EdgeInsets.all(8),
                      buildDefaultDragHandles: false,
                      itemCount: player.queue.length,
                      onReorder: (from, to) =>
                          player.move(from, to > from ? to - 1 : to),
                      itemBuilder: (context, i) {
                        final song = player.queue[i];
                        final isCurrent = i == player.index;
                        return ListTile(
                          key: ValueKey('${song.id}-$i'),
                          shape: mediumShape,
                          selected: isCurrent,
                          selectedTileColor: theme
                              .colorScheme
                              .secondaryContainer
                              .withValues(alpha: 0.45),
                          leading: AlbumArt(path: song.albumArtPath, size: 40),
                          title: Text(
                            song.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: isCurrent
                                ? theme.textTheme.bodyLarge?.copyWith(
                                    color: theme.colorScheme.primary,
                                    fontWeight: FontWeight.w600,
                                  )
                                : null,
                          ),
                          subtitle: Text(
                            song.displayArtist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                tooltip: 'Remove',
                                icon: const Icon(Icons.close_rounded, size: 18),
                                onPressed: () => player.removeAt(i),
                              ),
                              ReorderableDragStartListener(
                                index: i,
                                child: const Padding(
                                  padding: EdgeInsets.all(8),
                                  child: Icon(Icons.drag_handle_rounded),
                                ),
                              ),
                            ],
                          ),
                          onTap: () => player.jumpTo(i),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
