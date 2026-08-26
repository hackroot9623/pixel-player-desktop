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
    return DetailScaffold(
      title: artist.name,
      subtitle: plural(albums.length, 'album'),
      artPath: artist.effectiveImageUrl,
      artIcon: Icons.person_rounded,
      circularArt: true,
      songs: songs,
      numbered: false,
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
