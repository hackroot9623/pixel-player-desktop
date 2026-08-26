import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/providers.dart';
import '../components/common.dart';
import '../components/detail_header.dart';
import '../components/library_widgets.dart';

/// Port of `presentation/screens/ArtistDetailScreen`.
class ArtistDetailScreen extends ConsumerWidget {
  const ArtistDetailScreen({super.key, required this.artistId});

  final int artistId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final artist = ref
        .watch(libraryProvider)
        .artists
        .where((a) => a.id == artistId)
        .firstOrNull;
    final songs = ref.watch(songsForArtistProvider(artistId));
    final albums = ref.watch(albumsForArtistProvider(artistId));
    if (artist == null) {
      return const Scaffold(
        body: EmptyState(icon: Icons.person_rounded, title: 'Artist not found'),
      );
    }
    final images = ref.read(artistImageRepositoryProvider);
    Future<void> refresh() async {
      ref.read(libraryProvider.notifier).reload();
    }

    return DetailScaffold(
      title: artist.name,
      subtitle: plural(albums.length, 'album'),
      artPath: artist.effectiveImageUrl,
      artIcon: Icons.person_rounded,
      circularArt: true,
      songs: songs,
      numbered: false,
      actions: [
        MenuAnchor(
          builder: (context, controller, _) => IconButton(
            tooltip: 'Artist image',
            icon: const Icon(Icons.image_rounded),
            onPressed: () =>
                controller.isOpen ? controller.close() : controller.open(),
          ),
          menuChildren: [
            MenuItemButton(
              leadingIcon: const Icon(Icons.cloud_download_rounded),
              onPressed: () async {
                // Explicit re-fetch bypasses the cached outcome.
                await images.fetch(artist, force: true);
                ref.invalidate(artistImageProvider(artist.id));
                await refresh();
              },
              child: const Text('Re-fetch from Deezer'),
            ),
            MenuItemButton(
              leadingIcon: const Icon(Icons.folder_open_rounded),
              onPressed: () async {
                final picked = await openFile(
                  acceptedTypeGroups: const [
                    XTypeGroup(
                      label: 'Images',
                      extensions: ['jpg', 'jpeg', 'png', 'webp'],
                    ),
                  ],
                );
                if (picked == null) return;
                await images.setCustomImage(artist, File(picked.path));
                ref.invalidate(artistImageProvider(artist.id));
                await refresh();
              },
              child: const Text('Choose a picture…'),
            ),
            if (artist.effectiveImageUrl != null)
              MenuItemButton(
                leadingIcon: const Icon(Icons.delete_outline_rounded),
                onPressed: () async {
                  images.clear(artist);
                  ref.invalidate(artistImageProvider(artist.id));
                  await refresh();
                },
                child: const Text('Remove image'),
              ),
          ],
        ),
      ],
      extraSlivers: [
        if (albums.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SectionHeader(title: 'Albums'),
                  SizedBox(
                    height: 220,
                    child: ListView.builder(
                      scrollDirection: Axis.horizontal,
                      itemCount: albums.length,
                      itemBuilder: (context, i) => AlbumCard(album: albums[i]),
                    ),
                  ),
                  const SectionHeader(title: 'Songs'),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
