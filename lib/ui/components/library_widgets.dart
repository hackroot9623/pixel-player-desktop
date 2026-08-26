import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/models.dart';
import '../../data/models/sort_option.dart';
import '../../state/providers.dart';
import '../navigation.dart';
import '../theme/shapes.dart';
import 'album_art.dart';
import 'common.dart';
import 'multi_select.dart';
import 'song_info_sheet.dart';

/// Port of `subcomps/EnhancedSongListItem` + `LibraryPlaybackAwareSongItem`.
class SongTile extends ConsumerWidget {
  const SongTile({
    super.key,
    required this.song,
    this.onTap,
    this.trailing,
    this.showArtwork = true,
    this.dense = false,
    this.leadingIndex,
    this.selectable = true,
  });

  final Song song;
  final VoidCallback? onTap;
  final Widget? trailing;
  final bool showArtwork;
  final bool dense;
  final int? leadingIndex;

  /// Long-press / right-click enters multi-select. Off for the queue and other
  /// lists where selection makes no sense.
  final bool selectable;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    // Narrow subscriptions: a whole-service watch rebuilt every visible row on
    // every position tick.
    final isCurrent = ref.watch(
      playerProvider.select((player) => player.current?.id == song.id),
    );
    final isPlaying = ref.watch(
      playerProvider.select((player) => player.playing),
    );
    final selection = selectable
        ? ref.watch(selectionProvider)
        : const SelectionState();
    final isSelected = selection.ids.contains(song.id);
    final selectionNotifier = ref.read(selectionProvider.notifier);
    return ListTile(
      dense: dense,
      shape: mediumShape,
      selected: isCurrent || isSelected,
      selectedTileColor: (isSelected
              ? theme.colorScheme.primaryContainer
              : theme.colorScheme.secondaryContainer)
          .withValues(alpha: 0.45),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      // Selection mode swaps the artwork for a checkbox, the way the Android
      // list does while `MultiSelectionBottomSheet` is up.
      leading: selection.active
          ? Checkbox(
              value: isSelected,
              onChanged: (_) => selectionNotifier.toggle(song.id),
            )
          : showArtwork
          ? AlbumArt(path: song.albumArtPath, size: dense ? 40 : 48)
          : (leadingIndex == null
                ? null
                : SizedBox(
                    width: 28,
                    child: Center(
                      child: isCurrent
                          ? PlayingEqIcon(animate: isPlaying)
                          : Text(
                              '${leadingIndex! + 1}',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                    ),
                  )),
      title: Text(
        song.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodyLarge?.copyWith(
          fontWeight: isCurrent ? FontWeight.w600 : null,
          color: isCurrent ? theme.colorScheme.primary : null,
        ),
      ),
      subtitle: Text(
        '${song.displayArtist} · ${song.album}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      trailing:
          trailing ??
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (song.isFavorite)
                Icon(
                  Icons.favorite_rounded,
                  size: 16,
                  color: theme.colorScheme.primary,
                ),
              const SizedBox(width: 8),
              Text(
                formatDuration(song.durationValue),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              SongMenuButton(song: song),
            ],
          ),
      onTap: selection.active
          ? () => selectionNotifier.toggle(song.id)
          : (onTap ?? () => ref.read(playerProvider).playSong(song)),
      onLongPress: selectable ? () => selectionNotifier.toggle(song.id) : null,
    );
  }
}

/// Port of the overflow actions in `SongInfoBottomSheet`.
class SongMenuButton extends ConsumerWidget {
  const SongMenuButton({super.key, required this.song});

  final Song song;

  @override
  Widget build(BuildContext context, WidgetRef ref) => MenuAnchor(
    builder: (context, controller, _) => IconButton(
      icon: const Icon(Icons.more_vert_rounded),
      tooltip: 'More',
      onPressed: () =>
          controller.isOpen ? controller.close() : controller.open(),
    ),
    menuChildren: [
      MenuItemButton(
        leadingIcon: const Icon(Icons.play_arrow_rounded),
        onPressed: () => ref.read(playerProvider).playSong(song),
        child: const Text('Play'),
      ),
      MenuItemButton(
        leadingIcon: const Icon(Icons.queue_play_next_rounded),
        onPressed: () => ref.read(playerProvider).playNext([song]),
        child: const Text('Play next'),
      ),
      MenuItemButton(
        leadingIcon: const Icon(Icons.playlist_add_rounded),
        onPressed: () => ref.read(playerProvider).addToQueue([song]),
        child: const Text('Add to queue'),
      ),
      MenuItemButton(
        leadingIcon: Icon(
          song.isFavorite
              ? Icons.favorite_rounded
              : Icons.favorite_border_rounded,
        ),
        onPressed: () => ref.read(libraryProvider.notifier).toggleFavorite(song),
        child: Text(song.isFavorite ? 'Remove from liked' : 'Add to liked'),
      ),
      MenuItemButton(
        leadingIcon: const Icon(Icons.library_add_rounded),
        onPressed: () => showAddToPlaylistSheet(context, [song.id]),
        child: const Text('Add to playlist…'),
      ),
      const Divider(height: 8),
      MenuItemButton(
        leadingIcon: const Icon(Icons.album_rounded),
        onPressed: () => openAlbum(context, song.albumId),
        child: const Text('Go to album'),
      ),
      MenuItemButton(
        leadingIcon: const Icon(Icons.person_rounded),
        onPressed: () => openArtist(context, song.primaryArtist.id),
        child: const Text('Go to artist'),
      ),
      MenuItemButton(
        leadingIcon: const Icon(Icons.info_outline_rounded),
        onPressed: () => showSongInfoSheet(context, song),
        child: const Text('Song info'),
      ),
    ],
  );
}

/// Port of `PlaylistMultiSelectionBottomSheet`.
Future<void> showAddToPlaylistSheet(
  BuildContext context,
  List<String> songIds,
) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  builder: (context) => Consumer(
    builder: (context, ref, _) {
      final playlists = ref.watch(libraryProvider).playlists;
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.add_rounded),
              title: const Text('New playlist'),
              onTap: () async {
                final name = await promptForText(
                  context,
                  title: 'New playlist',
                  hint: 'Playlist name',
                );
                if (name == null || name.isEmpty) return;
                ref
                    .read(libraryProvider.notifier)
                    .createPlaylist(name, songIds: songIds);
                if (context.mounted) Navigator.of(context).pop();
              },
            ),
            const Divider(height: 1),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: playlists.length,
                itemBuilder: (context, i) {
                  final playlist = playlists[i];
                  return ListTile(
                    leading: AlbumArt(
                      path: playlist.coverImagePath,
                      size: 40,
                      icon: Icons.queue_music_rounded,
                    ),
                    title: Text(playlist.name),
                    subtitle: Text(plural(playlist.songCount, 'song')),
                    onTap: () {
                      ref
                          .read(libraryProvider.notifier)
                          .addToPlaylist(playlist, songIds);
                      Navigator.of(context).pop();
                    },
                  );
                },
              ),
            ),
          ],
        ),
      );
    },
  ),
);

Future<String?> promptForText(
  BuildContext context, {
  required String title,
  required String hint,
  String initial = '',
}) {
  final controller = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: InputDecoration(hintText: hint),
        onSubmitted: (value) => Navigator.of(context).pop(value.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(controller.text.trim()),
          child: const Text('Save'),
        ),
      ],
    ),
  );
}

/// Port of `LibrarySortBottomSheet`.
Future<void> showSortSheet(
  BuildContext context,
  WidgetRef ref,
  LibraryTabId tab,
) {
  final settings = ref.read(settingsProvider);
  final current = settings.sortFor(tab);
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Sort ${tab.title.toLowerCase()} by',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
          ),
          for (final option in tab.sortOptions)
            RadioListTile<SortOption>(
              value: option,
              groupValue: current,
              title: Text(option.label),
              onChanged: (value) {
                if (value != null) settings.setSortFor(tab, value);
                Navigator.of(context).pop();
              },
            ),
        ],
      ),
    ),
  );
}

class AlbumCard extends StatelessWidget {
  const AlbumCard({super.key, required this.album, this.size = 168});

  final Album album;
  final double size;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: size,
      child: InkWell(
        borderRadius: BorderRadius.circular(shapeLarge),
        onTap: () => openAlbum(context, album.id),
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AlbumArt(
                path: album.albumArtPath,
                size: size - 12,
                radius: shapeLarge,
                heroTag: 'album-${album.id}',
              ),
              const SizedBox(height: 10),
              Text(
                album.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall,
              ),
              Text(
                album.artist,
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
    );
  }
}

class ArtistCard extends StatelessWidget {
  const ArtistCard({super.key, required this.artist, this.size = 148});

  final Artist artist;
  final double size;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: size,
      child: InkWell(
        borderRadius: BorderRadius.circular(size),
        onTap: () => openArtist(context, artist.id),
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Column(
            children: [
              ClipOval(
                child: AlbumArt(
                  path: artist.effectiveImageUrl,
                  size: size - 12,
                  radius: size,
                  icon: Icons.person_rounded,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                artist.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: theme.textTheme.titleSmall,
              ),
              Text(
                plural(artist.songCount, 'song'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Port of `GenreCategoriesGrid` — a colour-blocked tile per genre.
class GenreCard extends StatelessWidget {
  const GenreCard({super.key, required this.genre});

  final Genre genre;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Deterministic hue per genre name, so a genre keeps its colour.
    final hue = (genre.name.hashCode.abs() % 360).toDouble();
    final base = HSLColor.fromAHSL(
      1,
      hue,
      0.42,
      scheme.brightness == Brightness.dark ? 0.28 : 0.82,
    ).toColor();
    final onBase = scheme.brightness == Brightness.dark
        ? Colors.white
        : const Color(0xFF1E1237);
    return Material(
      color: base,
      borderRadius: BorderRadius.circular(shapeLarge),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => openGenre(context, genre),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Icon(Icons.graphic_eq_rounded, color: onBase.withValues(alpha: 0.7)),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    genre.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(
                      context,
                    ).textTheme.titleMedium?.copyWith(color: onBase),
                  ),
                  Text(
                    plural(genre.songCount, 'song'),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: onBase.withValues(alpha: 0.75),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class PlaylistCard extends ConsumerWidget {
  const PlaylistCard({super.key, required this.playlist, this.size = 168});

  final Playlist playlist;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final songs = ref
        .watch(databaseProvider)
        .songsByIds(playlist.songIds.take(4).toList());
    return SizedBox(
      width: size,
      child: InkWell(
        borderRadius: BorderRadius.circular(shapeLarge),
        onTap: () => openPlaylist(context, playlist.id),
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (playlist.coverImagePath != null)
                AlbumArt(
                  path: playlist.coverImagePath,
                  size: size - 12,
                  radius: shapeLarge,
                )
              else
                AlbumArtCollage(
                  paths: [for (final s in songs) s.albumArtPath],
                  size: size - 12,
                  radius: shapeLarge,
                ),
              const SizedBox(height: 10),
              Text(
                playlist.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall,
              ),
              Text(
                plural(playlist.songCount, 'song'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Port of `FolderExplorerScreen`'s row.
class FolderTile extends ConsumerWidget {
  const FolderTile({super.key, required this.folder});

  final MusicFolder folder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return ListTile(
      shape: mediumShape,
      leading: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: theme.colorScheme.secondaryContainer,
          borderRadius: BorderRadius.circular(shapeMedium),
        ),
        child: Icon(
          Icons.folder_rounded,
          color: theme.colorScheme.onSecondaryContainer,
        ),
      ),
      title: Text(folder.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        [
          plural(folder.songCount, 'song'),
          if (folder.subdirCount > 0) plural(folder.subdirCount, 'folder'),
        ].join(' · '),
      ),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: () => openFolder(context, folder),
    );
  }
}
