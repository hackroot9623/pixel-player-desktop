import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/models.dart';
import '../../state/providers.dart';
import '../navigation.dart';
import '../theme/shapes.dart';
import 'album_art.dart';
import 'common.dart';
import 'library_widgets.dart';

/// Port of `presentation/components/SongInfoBottomSheet`: artwork and title on
/// top, a row of round action buttons, then the full tag dump.
Future<void> showSongInfoSheet(BuildContext context, Song song) =>
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 620),
      builder: (context) => SongInfoSheet(song: song),
    );

class SongInfoSheet extends ConsumerWidget {
  const SongInfoSheet({super.key, required this.song});

  final Song song;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final player = ref.read(playerProvider);
    // Re-read so the favourite state stays live while the sheet is open.
    final current = ref
        .watch(libraryProvider)
        .songs
        .where((s) => s.id == song.id)
        .firstOrNull ??
        song;

    final rows = <(String, String)>[
      ('Artists', current.displayArtist),
      ('Album', current.album),
      if (current.albumArtist != null) ('Album artist', current.albumArtist!),
      if (current.genre != null) ('Genre', current.genre!),
      if (current.year > 0) ('Year', '${current.year}'),
      if (current.trackNumber > 0) ('Track', '${current.trackNumber}'),
      if (current.discNumber != null) ('Disc', '${current.discNumber}'),
      ('Duration', formatDuration(current.durationValue)),
      if (current.mimeType != null) ('Format', current.mimeType!),
      if (current.bitrate != null)
        ('Bitrate', '${(current.bitrate! / 1000).round()} kbps'),
      if (current.sampleRate != null)
        ('Sample rate', '${current.sampleRate} Hz'),
      ('File', current.path),
    ];

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.8,
      maxChildSize: 0.95,
      builder: (context, scrollController) => ListView(
        controller: scrollController,
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              AlbumArt(path: current.albumArtPath, size: 132, radius: 24),
              const SizedBox(width: 20),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(current.title, style: theme.textTheme.headlineSmall),
                    const SizedBox(height: 6),
                    Text(
                      current.displayArtist,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: theme.colorScheme.primary,
                      ),
                    ),
                    Text(
                      current.album,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              _Action(
                icon: Icons.play_arrow_rounded,
                label: 'Play',
                onTap: () => player.playSong(current),
              ),
              _Action(
                icon: Icons.queue_play_next_rounded,
                label: 'Play next',
                onTap: () => player.playNext([current]),
              ),
              _Action(
                icon: Icons.playlist_add_rounded,
                label: 'Queue',
                onTap: () => player.addToQueue([current]),
              ),
              _Action(
                icon: current.isFavorite
                    ? Icons.favorite_rounded
                    : Icons.favorite_border_rounded,
                label: current.isFavorite ? 'Liked' : 'Like',
                selected: current.isFavorite,
                onTap: () =>
                    ref.read(libraryProvider.notifier).toggleFavorite(current),
                keepOpen: true,
              ),
              _Action(
                icon: Icons.library_add_rounded,
                label: 'Playlist',
                onTap: () => showAddToPlaylistSheet(context, [current.id]),
              ),
              _Action(
                icon: Icons.album_rounded,
                label: 'Album',
                onTap: () => openAlbum(context, current.albumId),
              ),
              _Action(
                icon: Icons.person_rounded,
                label: 'Artist',
                onTap: () => openArtist(context, current.primaryArtist.id),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Divider(height: 32),
          for (final (label, value) in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 120,
                    child: Text(
                      label,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  Expanded(
                    child: SelectableText(
                      value,
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _Action extends StatelessWidget {
  const _Action({
    required this.icon,
    required this.label,
    required this.onTap,
    this.selected = false,
    this.keepOpen = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool selected;

  /// Toggles stay open so the user can see the state flip.
  final bool keepOpen;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: 84,
      child: Column(
        children: [
          Material(
            color: selected ? scheme.primary : scheme.secondaryContainer,
            shape: smoothCorner(22),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () {
                onTap();
                if (!keepOpen) Navigator.of(context).pop();
              },
              child: SizedBox(
                height: 58,
                width: 84,
                child: Icon(
                  icon,
                  color: selected
                      ? scheme.onPrimary
                      : scheme.onSecondaryContainer,
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            style: Theme.of(context).textTheme.labelSmall,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}
