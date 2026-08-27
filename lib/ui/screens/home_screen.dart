import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/models.dart';
import '../../state/providers.dart';
import '../components/album_art.dart';
import 'ai_playlist_sheet.dart';
import '../components/collage.dart';
import '../components/source_selector.dart';
import '../theme/contrast.dart';
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
    final library = ref.watch(activeLibraryProvider);
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
            const SourceSelector(),
            IconButton(
              tooltip: 'Rescan library',
              icon: const Icon(Icons.refresh_rounded),
              onPressed: ref.read(libraryProvider.notifier).rescan,
            ),
            IconButton(
              tooltip: 'Build a playlist with AI',
              icon: const Icon(Icons.auto_awesome_rounded),
              onPressed: () => showAiPlaylistSheet(context),
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
              const SourceStatusBanner(),
              if (library.scanning && ref.watch(activeSourceProvider) == null)
                const _ScanBanner(),
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

/// The home banner's gradient stops.
///
/// Tinted from the palette — which comes from the album art — but only as far as
/// the text on top can still be read. Both texts sit on these stops, so the
/// weaker of the two pairings sets the limit.
///
/// Full-strength container roles were the original bug here: a container role
/// is only guaranteed to contrast with its own `on` colour, and with some
/// palettes `primaryContainer` lands within a fraction of a percent of
/// `onSurface`, which made the greeting invisible.
List<Color> bannerGradient(ColorScheme scheme) => [
  legibleTint(
    scheme.surface,
    scheme.primaryContainer,
    text: scheme.onSurfaceVariant,
  ),
  legibleTint(
    scheme.surface,
    scheme.secondaryContainer,
    text: scheme.onSurfaceVariant,
    strength: 0.3,
  ),
  scheme.surface,
];

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
    final light = scheme.brightness == Brightness.light;
    return FlexibleSpaceBar(
      background: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: bannerGradient(scheme),
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
                // Album art is full-contrast imagery; against a pale banner it
                // has to sit further back to stay decoration.
                opacity: light ? 0.55 : 0.85,
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
                // onPrimaryContainer only reads on primaryContainer, and the
                // gradient has faded most of the way to the surface by the time
                // it reaches the text — which is what made the greeting
                // green-on-green.
                color: scheme.onSurface,
              ),
              const SizedBox(height: 6),
              Text(
                '${plural(songCount, 'song', 'songs')} in your library',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  // Was onPrimaryContainer at 80%: a low-contrast colour made
                  // fainter still.
                  color: scheme.onSurfaceVariant,
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
          final theme = Theme.of(context);
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
                    // Both lines take their colour from the scheme explicitly.
                    // The title previously relied on the colour baked into
                    // textTheme, which is the one place these labels could end
                    // up disagreeing with the rest of the theme.
                    Text(
                      song.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: theme.colorScheme.onSurface,
                      ),
                    ),
                    Text(
                      song.displayArtist,
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
      // Tinted from this track's own cover: the tile separates from the page by
      // colour, which works the same way in both themes, where an outline on
      // every tile only added noise.
      final base = Theme.of(context).colorScheme;
      final tint = ref
          .watch(artworkSchemesProvider(song.albumArtPath))
          .valueOrNull;
      final scheme = tint == null
          ? base
          : (base.brightness == Brightness.light ? tint.$1 : tint.$2);
      return Material(
        color: scheme.secondaryContainer,
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
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: scheme.onSecondaryContainer,
                      ),
                    ),
                    Text(
                      song.displayArtist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        // The on-colour of the container it sits in, so the
                        // pairing holds whatever the cover looks like.
                        color: scheme.onSecondaryContainer.withValues(
                          alpha: 0.85,
                        ),
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
