import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/models.dart';
import '../../state/providers.dart';
import '../components/album_art.dart';
import '../components/collage.dart';
import '../components/common.dart';
import '../components/library_widgets.dart';
import '../navigation.dart';
import '../theme/shapes.dart';
import '../theme/typography.dart';

/// Port of `presentation/screens/HomeScreen`: gradient header, "Your Mix",
/// recently played, and the stats overview card.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final library = ref.watch(libraryProvider);
    final mix = ref.watch(dailyMixProvider);
    final recent = ref.watch(recentlyPlayedProvider);
    final player = ref.read(playerProvider);

    if (library.isEmpty) {
      return EmptyState(
        icon: Icons.library_music_rounded,
        title: library.scanning ? 'Scanning your library…' : 'No music yet',
        message: library.scanning
            ? library.scanProgress?.currentPath
            : 'Add a music folder to get started.',
        action: library.scanning
            ? null
            : FilledButton.icon(
                onPressed: () => openSettings(context),
                icon: const Icon(Icons.folder_open_rounded),
                label: const Text('Choose folders'),
              ),
      );
    }

    return CustomScrollView(
      slivers: [
        SliverAppBar.large(
          expandedHeight: 260,
          title: const Text('PixelPlayer'),
          flexibleSpace: _GradientHeader(
            songCount: library.songs.length,
            artworkPaths: [
              for (final song in (recent.isEmpty ? mix : recent).take(6))
                song.albumArtPath,
            ],
          ),
          actions: [
            IconButton(
              tooltip: 'Rescan library',
              icon: const Icon(Icons.refresh_rounded),
              onPressed: ref.read(libraryProvider.notifier).rescan,
            ),
            IconButton(
              tooltip: 'Mashup',
              icon: const Icon(Icons.multitrack_audio_rounded),
              onPressed: () => openMashup(context),
            ),
            IconButton(
              tooltip: 'Settings',
              icon: const Icon(Icons.settings_rounded),
              onPressed: () => openSettings(context),
            ),
            const SizedBox(width: 8),
          ],
        ),
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          sliver: SliverList(
            delegate: SliverChildListDelegate([
              if (library.scanning) const _ScanBanner(),
              SectionHeader(
                title: 'Your Mix',
                subtitle: 'Built from what you have been playing',
                trailing: FilledButton.tonalIcon(
                  onPressed: mix.isEmpty
                      ? null
                      : () => player.playQueue([...mix]..shuffle()),
                  icon: const Icon(Icons.shuffle_rounded),
                  label: const Text('Shuffle mix'),
                ),
              ),
              _MixRow(songs: mix),
              if (recent.isNotEmpty) ...[
                const SectionHeader(title: 'Recently played'),
                _RecentGrid(songs: recent.take(9).toList()),
              ],
              const SectionHeader(title: 'Albums'),
              SizedBox(
                height: 230,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  itemCount: library.albums.length.clamp(0, 20),
                  itemBuilder: (context, i) =>
                      AlbumCard(album: library.albums[i]),
                ),
              ),
              const SizedBox(height: 8),
              _StatsCard(),
              const SizedBox(height: 24),
            ]),
          ),
        ),
      ],
    );
  }
}

class _GradientHeader extends StatelessWidget {
  const _GradientHeader({
    required this.songCount,
    this.artworkPaths = const [],
  });

  final int songCount;

  /// Covers of the most recently played tracks, for the decorative scatter.
  final List<String?> artworkPaths;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return FlexibleSpaceBar(
      background: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              scheme.primaryContainer,
              scheme.secondaryContainer.withValues(alpha: 0.6),
              scheme.surface,
            ],
          ),
        ),
        child: Stack(
          children: [
            // Right-hand side only: on a wide banner the shapes would
            // otherwise sit behind the greeting and fight it for contrast.
            Positioned(
              top: 0,
              bottom: 0,
              right: 0,
              width: 520,
              child: AlbumArtScatter(
                artworkPaths: artworkPaths,
                opacity: 0.85,
              ),
            ),
            Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.end,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ExpressiveTitle(
                _greeting(),
                style: expDisplayMedium,
                scaleX: 1.0,
                color: scheme.onPrimaryContainer,
              ),
              const SizedBox(height: 6),
              Text(
                '${plural(songCount, 'song', 'songs')} in your library',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: scheme.onPrimaryContainer.withValues(alpha: 0.8),
                ),
              ),
            ],
          ),
            ),
          ],
        ),
      ),
    );
  }

  static String _greeting() {
    final hour = DateTime.now().hour;
    if (hour < 5) return 'Late night';
    if (hour < 12) return 'Good morning';
    if (hour < 18) return 'Good afternoon';
    return 'Good evening';
  }
}

class _ScanBanner extends ConsumerWidget {
  const _ScanBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final progress = ref.watch(libraryProvider).scanProgress;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    progress == null
                        ? 'Scanning…'
                        : 'Scanning ${progress.scanned} of ${progress.total}',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  if (progress != null)
                    Text(
                      progress.currentPath,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Port of `DailyMixSection` — oversized artwork cards with the title overlaid.
class _MixRow extends ConsumerWidget {
  const _MixRow({required this.songs});

  final List<Song> songs;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (songs.isEmpty) {
      return const SizedBox(
        height: 120,
        child: Center(child: Text('Play a few songs to build your mix.')),
      );
    }
    return SizedBox(
      height: 260,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: songs.length,
        separatorBuilder: (_, _) => const SizedBox(width: 12),
        itemBuilder: (context, i) {
          final song = songs[i];
          return SizedBox(
            width: 200,
            child: Material
                (
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(shapeLarge),
                onTap: () =>
                    ref.read(playerProvider).playQueue(songs, startIndex: i),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Stack(
                      children: [
                        AlbumArt(
                          path: song.albumArtPath,
                          size: 200,
                          radius: shapeLarge,
                        ),
                        Positioned(
                          right: 8,
                          bottom: 8,
                          child: Material(
                            color: Theme.of(context).colorScheme.primary,
                            shape: const CircleBorder(),
                            child: const Padding(
                              padding: EdgeInsets.all(8),
                              child: Icon(
                                Icons.play_arrow_rounded,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Text(
                      song.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    Text(
                      song.displayArtist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Port of `RecentlyPlayedSection` — a compact three-column grid of chips.
class _RecentGrid extends ConsumerWidget {
  const _RecentGrid({required this.songs});

  final List<Song> songs;

  @override
  Widget build(BuildContext context, WidgetRef ref) => GridView.builder(
    shrinkWrap: true,
    physics: const NeverScrollableScrollPhysics(),
    gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
      maxCrossAxisExtent: 420,
      mainAxisExtent: 68,
      crossAxisSpacing: 12,
      mainAxisSpacing: 12,
    ),
    itemCount: songs.length,
    itemBuilder: (context, i) {
      final song = songs[i];
      return Material(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(shapeMedium),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => ref.read(playerProvider).playQueue(songs, startIndex: i),
          child: Row(
            children: [
              AlbumArt(path: song.albumArtPath, size: 68, radius: 0),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      song.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    Text(
                      song.displayArtist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
            ],
          ),
        ),
      );
    },
  );
}

/// Port of `StatsOverviewCard`.
class _StatsCard extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stats = ref.watch(statsProvider);
    final theme = Theme.of(context);
    Widget tile(String label, String value, IconData icon) => Expanded(
      child: Column(
        children: [
          Icon(icon, color: theme.colorScheme.primary),
          const SizedBox(height: 8),
          Text(value, style: theme.textTheme.titleMedium),
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
    return Card(
      child: InkWell(
        onTap: () => openStats(context),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
          child: Row(
            children: [
              tile('Songs', '${stats.songCount}', Icons.music_note_rounded),
              tile('Albums', '${stats.albumCount}', Icons.album_rounded),
              tile('Artists', '${stats.artistCount}', Icons.person_rounded),
              tile(
                'Plays',
                '${stats.totalPlays}',
                Icons.play_circle_outline_rounded,
              ),
              tile(
                'Library',
                formatLongDuration(stats.totalDuration),
                Icons.timelapse_rounded,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
