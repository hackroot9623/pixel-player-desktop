import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/models.dart';
import '../../state/providers.dart';
import 'album_art.dart';
import 'common.dart';
import 'library_widgets.dart';

/// Shared shell for album / artist / genre / playlist / folder detail screens —
/// the layout `AlbumDetailScreen` and friends each hand-roll on Android.
class DetailScaffold extends ConsumerWidget {
  const DetailScaffold({
    super.key,
    required this.title,
    required this.songs,
    this.subtitle,
    this.artPath,
    this.artIcon = Icons.album_rounded,
    this.circularArt = false,
    this.heroTag,
    this.actions = const [],
    this.extraSlivers = const [],
    this.numbered = true,
  });

  final String title;
  final String? subtitle;
  final List<Song> songs;
  final String? artPath;
  final IconData artIcon;
  final bool circularArt;
  final Object? heroTag;
  final List<Widget> actions;

  /// Extra content between the header and the track list (e.g. an artist's
  /// albums row).
  final List<Widget> extraSlivers;
  final bool numbered;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final player = ref.read(playerProvider);
    final total = Duration(
      milliseconds: songs.fold(0, (sum, s) => sum + s.duration),
    );

    final art = AlbumArt(
      path: artPath,
      size: 200,
      radius: circularArt ? 100 : 24,
      icon: artIcon,
      heroTag: heroTag,
    );

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            pinned: true,
            title: Text(title),
            actions: actions,
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  circularArt ? ClipOval(child: art) : art,
                  const SizedBox(width: 24),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ExpressiveTitle(title),
                        const SizedBox(height: 8),
                        Text(
                          [
                            if (subtitle != null) subtitle!,
                            plural(songs.length, 'song'),
                            formatLongDuration(total),
                          ].join(' · '),
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 20),
                        Row(
                          children: [
                            FilledButton.icon(
                              onPressed: songs.isEmpty
                                  ? null
                                  : () => player.playQueue(songs),
                              icon: const Icon(Icons.play_arrow_rounded),
                              label: const Text('Play'),
                            ),
                            const SizedBox(width: 12),
                            FilledButton.tonalIcon(
                              onPressed: songs.isEmpty
                                  ? null
                                  : () {
                                      final shuffled = [...songs]..shuffle();
                                      player.playQueue(shuffled);
                                    },
                              icon: const Icon(Icons.shuffle_rounded),
                              label: const Text('Shuffle'),
                            ),
                            const SizedBox(width: 12),
                            IconButton(
                              tooltip: 'Add to queue',
                              icon: const Icon(Icons.playlist_add_rounded),
                              onPressed: songs.isEmpty
                                  ? null
                                  : () => player.addToQueue(songs),
                            ),
                            IconButton(
                              tooltip: 'Add to playlist',
                              icon: const Icon(Icons.library_add_rounded),
                              onPressed: songs.isEmpty
                                  ? null
                                  : () => showAddToPlaylistSheet(context, [
                                      for (final s in songs) s.id,
                                    ]),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          ...extraSlivers,
          if (songs.isEmpty)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: EmptyState(
                icon: Icons.music_off_rounded,
                title: 'No songs here',
              ),
            )
          else
            SliverList.builder(
              itemCount: songs.length,
              itemBuilder: (context, i) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: SongTile(
                  song: songs[i],
                  showArtwork: !numbered,
                  leadingIndex: numbered ? i : null,
                  onTap: () => player.playQueue(songs, startIndex: i),
                ),
              ),
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ],
      ),
    );
  }
}
