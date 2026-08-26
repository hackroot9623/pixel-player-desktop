import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/providers.dart';
import '../components/common.dart';
import '../components/detail_header.dart';
import '../components/library_widgets.dart';

/// Port of `presentation/screens/PlaylistDetailScreen`.
class PlaylistDetailScreen extends ConsumerWidget {
  const PlaylistDetailScreen({super.key, required this.playlistId});

  final String playlistId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playlist = ref
        .watch(libraryProvider)
        .playlists
        .where((pl) => pl.id == playlistId)
        .firstOrNull;
    if (playlist == null) {
      return const Scaffold(
        body: EmptyState(
          icon: Icons.queue_music_rounded,
          title: 'Playlist not found',
        ),
      );
    }
    final songs = ref.watch(databaseProvider).songsByIds(playlist.songIds);
    final notifier = ref.read(libraryProvider.notifier);
    return DetailScaffold(
      title: playlist.name,
      subtitle: playlist.isAiGenerated ? 'AI generated' : null,
      artPath: playlist.coverImagePath ?? songs.firstOrNull?.albumArtPath,
      artIcon: Icons.queue_music_rounded,
      songs: songs,
      actions: [
        IconButton(
          tooltip: 'Rename',
          icon: const Icon(Icons.edit_rounded),
          onPressed: () async {
            final name = await promptForText(
              context,
              title: 'Rename playlist',
              hint: 'Playlist name',
              initial: playlist.name,
            );
            if (name != null && name.isNotEmpty) {
              notifier.renamePlaylist(playlist, name);
            }
          },
        ),
        IconButton(
          tooltip: 'Delete',
          icon: const Icon(Icons.delete_outline_rounded),
          onPressed: () async {
            final confirmed = await showDialog<bool>(
              context: context,
              builder: (context) => AlertDialog(
                title: const Text('Delete playlist?'),
                content: Text('"${playlist.name}" will be removed.'),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    child: const Text('Cancel'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.of(context).pop(true),
                    child: const Text('Delete'),
                  ),
                ],
              ),
            );
            if (confirmed ?? false) {
              notifier.deletePlaylist(playlist.id);
              if (context.mounted) Navigator.of(context).pop();
            }
          },
        ),
      ],
    );
  }
}
