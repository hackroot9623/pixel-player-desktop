import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/smart/smart_playlists.dart';
import '../../state/providers.dart';
import '../components/detail_header.dart';
import '../components/library_widgets.dart';

/// A computed playlist. There is nothing to edit — the rule is the playlist —
/// so the only extra action is saving the current output as a real one.
class SmartPlaylistScreen extends ConsumerWidget {
  const SmartPlaylistScreen({super.key, required this.rule});

  final SmartPlaylistRule rule;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final songs = ref.watch(smartPlaylistProvider(rule));
    return DetailScaffold(
      title: rule.title,
      subtitle: rule.subtitle,
      artPath: songs.firstOrNull?.albumArtPath,
      artIcon: Icons.auto_awesome_rounded,
      songs: songs,
      numbered: true,
      actions: [
        IconButton(
          tooltip: 'Save as a playlist',
          icon: const Icon(Icons.bookmark_add_outlined),
          onPressed: songs.isEmpty
              ? null
              : () async {
                  final name = await promptForText(
                    context,
                    title: 'Save as a playlist',
                    hint: 'Playlist name',
                    initial: rule.title,
                  );
                  if (name == null || name.isEmpty) return;
                  ref.read(libraryProvider.notifier).createPlaylist(
                    name,
                    songIds: [for (final song in songs) song.id],
                  );
                },
        ),
      ],
    );
  }
}
