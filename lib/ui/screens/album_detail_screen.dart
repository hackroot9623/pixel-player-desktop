import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/providers.dart';
import '../components/common.dart';
import '../components/detail_header.dart';

/// Port of `presentation/screens/AlbumDetailScreen`.
class AlbumDetailScreen extends ConsumerWidget {
  const AlbumDetailScreen({super.key, required this.albumId});

  final int albumId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final album = ref
        .watch(libraryProvider)
        .albums
        .where((a) => a.id == albumId)
        .firstOrNull;
    final songs = ref.watch(songsForAlbumProvider(albumId));
    if (album == null) {
      return const Scaffold(
        body: EmptyState(icon: Icons.album_rounded, title: 'Album not found'),
      );
    }
    return DetailScaffold(
      title: album.title,
      subtitle: [
        album.albumArtist ?? album.artist,
        if (album.year > 0) '${album.year}',
      ].join(' · '),
      artPath: album.albumArtPath,
      heroTag: 'album-${album.id}',
      songs: songs,
    );
  }
}
