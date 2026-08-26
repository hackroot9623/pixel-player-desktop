import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/models.dart';
import '../../state/providers.dart';
import '../components/album_carousel.dart';
import '../components/common.dart';
import '../components/lyrics_panel.dart';
import '../components/playback_controls.dart';
import '../components/queue_panel.dart';
import '../components/sleep_timer_sheet.dart';
import '../components/song_info_sheet.dart';
import '../components/wavy_slider.dart';
import '../navigation.dart';
import '../theme/shapes.dart';

void openFullPlayer(BuildContext context) =>
    Navigator.of(context, rootNavigator: true).push(
      PageRouteBuilder<void>(
        transitionDuration: const Duration(milliseconds: 320),
        reverseTransitionDuration: const Duration(milliseconds: 240),
        pageBuilder: (context, animation, _) => FadeTransition(
          opacity: animation,
          child: SlideTransition(
            position: Tween(
              begin: const Offset(0, 0.06),
              end: Offset.zero,
            ).animate(
              CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
            ),
            child: const FullPlayerScreen(),
          ),
        ),
      ),
    );

/// Port of `presentation/components/player/FullPlayerContent`, laid out for a
/// wide window: artwork carousel and transport on the left, queue docked right.
class FullPlayerScreen extends ConsumerWidget {
  const FullPlayerScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(playerProvider);
    final song = player.current;
    final theme = Theme.of(context);
    if (song == null) {
      return const Scaffold(
        body: EmptyState(
          icon: Icons.music_note_rounded,
          title: 'Nothing playing',
        ),
      );
    }

    return Scaffold(
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              theme.colorScheme.primaryContainer.withValues(alpha: 0.55),
              theme.colorScheme.surface,
              theme.colorScheme.surface,
            ],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              _TopBar(song: song),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final wide = constraints.maxWidth > 1000;
                    final content = _NowPlayingPane(compact: !wide);
                    if (!wide) return content;
                    // On a wide window the side pane shows either the queue or
                    // the lyrics; the toolbar toggle picks which.
                    final showLyrics = ref.watch(
                      settingsProvider.select((s) => s.showLyricsPane),
                    );
                    return Row(
                      children: [
                        Expanded(child: content),
                        Padding(
                          padding: const EdgeInsets.only(right: 16, bottom: 16),
                          child: ClipRRect(
                            borderRadius: const BorderRadius.all(
                              Radius.circular(shapeLarge),
                            ),
                            child: SizedBox(
                              width: 420,
                              child: showLyrics
                                  ? LyricsPanel(song: song)
                                  : const QueuePanel(),
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TopBar extends ConsumerWidget {
  const _TopBar({required this.song});

  final Song song;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final player = ref.watch(playerProvider);
    final timerActive = player.sleepTimerActive;
    final remaining = player.sleepTimerRemaining;
    return Row(
      children: [
        IconButton(
          tooltip: 'Close',
          icon: const Icon(Icons.keyboard_arrow_down_rounded),
          onPressed: () => Navigator.of(context).pop(),
        ),
        Expanded(
          child: Center(
            child: Text(
              'Now playing',
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
        IconButton(
          tooltip: !timerActive
              ? 'Sleep timer'
              : 'Sleep timer: ${remaining == null ? 'on' : formatDuration(remaining)}',
          isSelected: timerActive,
          icon: Icon(
            timerActive ? Icons.bedtime_rounded : Icons.bedtime_outlined,
            color: timerActive ? theme.colorScheme.primary : null,
          ),
          onPressed: () => showSleepTimerSheet(context),
        ),
        _LyricsToggle(song: song),
        IconButton(
          tooltip: 'Song info',
          icon: const Icon(Icons.info_outline_rounded),
          onPressed: () => showSongInfoSheet(context, song),
        ),
        const SizedBox(width: 8),
      ],
    );
  }
}

class _NowPlayingPane extends ConsumerWidget {
  const _NowPlayingPane({required this.compact});

  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(playerProvider);
    final settings = ref.watch(settingsProvider);
    final song = player.current!;
    final theme = Theme.of(context);
    final fileInfo = _audioMetaLabel(song);

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620),
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          child: Column(
            children: [
              LayoutBuilder(
                builder: (context, constraints) => AlbumCarousel(
                  height:
                      constraints.maxWidth *
                      settings.carouselStyle.heightFactor *
                      (compact ? 0.78 : 1.0),
                  songs: player.queue,
                  index: player.index,
                  playing: player.playing,
                  style: settings.carouselStyle,
                  onTapCurrent: (song) => openAlbum(context, song.albumId),
                  onTapOther: player.jumpTo,
                ),
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          song.title,
                          maxLines: 2,
                          style: theme.textTheme.headlineSmall,
                        ),
                        const SizedBox(height: 4),
                        InkWell(
                          borderRadius: BorderRadius.circular(8),
                          onTap: () =>
                              openArtist(context, song.primaryArtist.id),
                          child: Text(
                            song.displayArtist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall?.copyWith(
                              color: theme.colorScheme.primary,
                            ),
                          ),
                        ),
                        InkWell(
                          borderRadius: BorderRadius.circular(8),
                          onTap: () => openAlbum(context, song.albumId),
                          child: Text(
                            song.album,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              // Only this subtree follows the position ticks.
              PositionBuilder(
                builder: (context, position) {
                  final total = player.duration.inMilliseconds;
                  return Column(
                    children: [
                      WavySlider(
                        value: total <= 0
                            ? 0
                            : (position.inMilliseconds / total).clamp(0.0, 1.0),
                        animate: player.playing,
                        onChangeEnd: player.seekFraction,
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Row(
                          children: [
                            Text(
                              formatDuration(position),
                              style: theme.textTheme.bodySmall,
                            ),
                            const Spacer(),
                            // `showPlayerFileInfo` — format / bitrate / rate.
                            if (settings.showPlayerFileInfo && fileInfo != null)
                              Text(
                                fileInfo,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            const Spacer(),
                            Text(
                              formatDuration(player.duration),
                              style: theme.textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 20),
              const TransportBar(),
              const SizedBox(height: 12),
              if (compact)
                TextButton.icon(
                  onPressed: () => showQueuePanel(context),
                  icon: const Icon(Icons.queue_music_rounded),
                  label: Text('Queue · ${player.queue.length}'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Port of `formatAudioMetaLabel`.
String? _audioMetaLabel(Song song) {
  final parts = <String>[
    if (song.mimeType != null)
      song.mimeType!.split('/').last.toUpperCase().replaceAll('MPEG', 'MP3'),
    if (song.bitrate != null && song.bitrate! > 0)
      '${(song.bitrate! / 1000).round()} kbps',
    if (song.sampleRate != null && song.sampleRate! > 0)
      '${(song.sampleRate! / 1000).toStringAsFixed(1)} kHz',
  ];
  return parts.isEmpty ? null : parts.join(' · ');
}

/// Toggles the side lyrics pane on a wide window, or opens the lyrics sheet on
/// a narrow one.
class _LyricsToggle extends ConsumerWidget {
  const _LyricsToggle({required this.song});

  final Song song;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final hasLyrics =
        ref.watch(currentLyricsProvider).valueOrNull?.isEmpty == false;
    final wide = MediaQuery.sizeOf(context).width > 1000;
    return IconButton(
      tooltip: hasLyrics ? 'Lyrics' : 'Lyrics (none found yet)',
      isSelected: wide && settings.showLyricsPane,
      icon: Icon(
        hasLyrics ? Icons.lyrics_rounded : Icons.lyrics_outlined,
        color: wide && settings.showLyricsPane
            ? Theme.of(context).colorScheme.primary
            : null,
      ),
      onPressed: () {
        if (wide) {
          settings.showLyricsPane = !settings.showLyricsPane;
        } else {
          showLyricsSheet(context, song);
        }
      },
    );
  }
}
