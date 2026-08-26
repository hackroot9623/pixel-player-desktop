import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/models.dart';
import '../../state/providers.dart';
import '../components/detail_header.dart';
import '../components/library_widgets.dart';

/// Port of `presentation/screens/FolderExplorerScreen` — one level of the
/// directory tree with its direct songs below.
class FolderScreen extends ConsumerWidget {
  const FolderScreen({super.key, required this.folder});

  final MusicFolder folder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final subfolders = ref.watch(foldersProvider(folder.path));
    final songs = ref.watch(songsInFolderProvider(folder.path));
    return DetailScaffold(
      title: folder.name,
      subtitle: folder.path,
      artIcon: Icons.folder_rounded,
      songs: songs,
      numbered: false,
      extraSlivers: [
        if (subfolders.isNotEmpty)
          SliverList.builder(
            itemCount: subfolders.length,
            itemBuilder: (context, i) => Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: FolderTile(folder: subfolders[i]),
            ),
          ),
      ],
    );
  }
}
