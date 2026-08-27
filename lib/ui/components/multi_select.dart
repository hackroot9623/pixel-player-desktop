import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/models.dart';
import '../../state/providers.dart';
import '../theme/shapes.dart';
import 'album_art.dart';
import 'common.dart';
import 'edit_song_sheet.dart';
import 'library_widgets.dart';

/// Selection state for the library lists. Port of the state the Android
/// `MultiSelectionBottomSheet` drives.
class SelectionState {
  const SelectionState({this.active = false, this.ids = const {}});

  final bool active;
  final Set<String> ids;

  bool get isEmpty => ids.isEmpty;

  SelectionState toggle(String id) {
    final next = {...ids};
    next.contains(id) ? next.remove(id) : next.add(id);
    return SelectionState(active: next.isNotEmpty, ids: next);
  }
}

class SelectionNotifier extends StateNotifier<SelectionState> {
  SelectionNotifier() : super(const SelectionState());

  void toggle(String id) => state = state.toggle(id);

  void selectAll(Iterable<String> ids) =>
      state = SelectionState(active: true, ids: ids.toSet());

  void clear() => state = const SelectionState();
}

final selectionProvider =
    StateNotifierProvider<SelectionNotifier, SelectionState>(
      (ref) => SelectionNotifier(),
    );

/// Port of `presentation/components/MultiSelectionBottomSheet` — the action bar
/// that slides in over a list while items are selected, including the stacked
/// album-art preview from `StackedAlbumArts`.
class SelectionActionBar extends ConsumerWidget {
  const SelectionActionBar({super.key, required this.allSongs});

  /// The list the bar is anchored to, so "select all" knows its scope.
  final List<Song> allSongs;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selection = ref.watch(selectionProvider);
    final theme = Theme.of(context);
    final notifier = ref.read(selectionProvider.notifier);
    final player = ref.read(playerProvider);
    final library = ref.read(libraryProvider.notifier);

    final selected = [
      for (final song in allSongs)
        if (selection.ids.contains(song.id)) song,
    ];

    return AnimatedSlide(
      offset: selection.active ? Offset.zero : const Offset(0, 1.4),
      duration: const Duration(milliseconds: 260),
      curve: Curves.fastOutSlowIn,
      child: AnimatedOpacity(
        opacity: selection.active ? 1 : 0,
        duration: const Duration(milliseconds: 180),
        child: IgnorePointer(
          ignoring: !selection.active,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Container(
              decoration: ShapeDecoration(
                color: theme.colorScheme.surfaceContainerHigh,
                shape: smoothCorner(28),
                shadows: kElevationToShadow[4],
              ),
              padding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 10,
              ),
              child: Row(
                children: [
                  StackedAlbumArts(songs: selected),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Text(
                      plural(selected.length, 'song selected', 'songs selected'),
                      style: theme.textTheme.titleSmall,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Play',
                    icon: const Icon(Icons.play_arrow_rounded),
                    onPressed: selected.isEmpty
                        ? null
                        : () {
                            playSongs(ref, selected);
                            notifier.clear();
                          },
                  ),
                  IconButton(
                    tooltip: 'Play next',
                    icon: const Icon(Icons.queue_play_next_rounded),
                    onPressed: selected.isEmpty
                        ? null
                        : () {
                            player.playNext(selected);
                            notifier.clear();
                          },
                  ),
                  IconButton(
                    tooltip: 'Add to queue',
                    icon: const Icon(Icons.playlist_add_rounded),
                    onPressed: selected.isEmpty
                        ? null
                        : () {
                            player.addToQueue(selected);
                            notifier.clear();
                          },
                  ),
                  IconButton(
                    tooltip: 'Add to playlist',
                    icon: const Icon(Icons.library_add_rounded),
                    onPressed: selected.isEmpty
                        ? null
                        : () => showAddToPlaylistSheet(context, [
                            for (final s in selected) s.id,
                          ]),
                  ),
                  IconButton(
                    tooltip: 'Edit tags',
                    icon: const Icon(Icons.edit_rounded),
                    onPressed: selected.isEmpty
                        ? null
                        : () => showEditMultipleSongsSheet(context, selected),
                  ),
                  IconButton(
                    tooltip: 'Like',
                    icon: const Icon(Icons.favorite_rounded),
                    onPressed: selected.isEmpty
                        ? null
                        : () {
                            for (final song in selected) {
                              if (!song.isFavorite) library.toggleFavorite(song);
                            }
                            notifier.clear();
                          },
                  ),
                  const SizedBox(width: 4),
                  TextButton(
                    onPressed: () => notifier.selectAll([
                      for (final s in allSongs) s.id,
                    ]),
                    child: const Text('All'),
                  ),
                  IconButton(
                    tooltip: 'Cancel',
                    icon: const Icon(Icons.close_rounded),
                    onPressed: notifier.clear,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Port of `StackedAlbumArts` — up to three covers fanned out behind each other.
class StackedAlbumArts extends StatelessWidget {
  const StackedAlbumArts({super.key, required this.songs, this.size = 44});

  final List<Song> songs;
  final double size;

  @override
  Widget build(BuildContext context) {
    final visible = songs.take(3).toList();
    if (visible.isEmpty) {
      return AlbumArt(path: null, size: size, radius: 12);
    }
    return SizedBox(
      width: size + (visible.length - 1) * 12,
      height: size,
      child: Stack(
        children: [
          for (var i = visible.length - 1; i >= 0; i--)
            Positioned(
              left: i * 12,
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: Theme.of(context).colorScheme.surfaceContainerHigh,
                    width: 2,
                  ),
                ),
                child: AlbumArt(
                  path: visible[i].albumArtPath,
                  size: size - 4,
                  radius: 10,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
