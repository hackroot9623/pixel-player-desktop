import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/models.dart';
import '../../player/player_service.dart';
import '../../state/providers.dart';
import '../components/album_art.dart';
import '../components/common.dart';
import '../components/lyrics_panel.dart';
import '../components/lyrics_view.dart';
import '../components/playback_controls.dart';
import '../components/wavy_slider.dart';
import '../components/window_size_presets.dart';
import '../screens/full_player_screen.dart';
import '../theme/shapes.dart';

/// Below this the shell drops the navigation rail and the library entirely and
/// becomes a player widget — the window is too small to browse in.
const compactWidthBreakpoint = 620.0;
const compactHeightBreakpoint = 440.0;

/// True when the window is too small for the browsing UI.
///
/// Pure so the breakpoint is testable without laying out a window.
bool isCompactSize(Size size) =>
    size.width < compactWidthBreakpoint ||
    size.height < compactHeightBreakpoint;

/// How the compact player arranges itself.
enum CompactLayout {
  /// Tall window: large centred artwork, text under it, transport at the
  /// bottom.
  portrait,

  /// Short window: artwork beside the text and transport, in one strip.
  strip,
}

/// Enough height to give the artwork a column of its own; below it, the strip
/// is the only arrangement that fits.
const _portraitMinHeight = 380.0;

/// Below this, even the track text and times are dropped.
const _tinyWidth = 420.0;

/// Chooses the arrangement from the available space.
///
/// Pure, so the rules are testable without rendering.
CompactLayout compactLayoutFor(Size size) => size.height >= _portraitMinHeight
    ? CompactLayout.portrait
    : CompactLayout.strip;

/// The preset whose shape the window currently matches, for highlighting.
WindowSizePreset? matchingPreset(Size size) {
  for (final preset in WindowSizePreset.values) {
    if ((size.width - preset.size.width).abs() < 80 &&
        (size.height - preset.size.height).abs() < 80) {
      return preset;
    }
  }
  return null;
}

/// The whole app, shrunk to a player. Shown automatically when the window is
/// resized small, and replaced by the full shell again when it grows.
class CompactPlayer extends ConsumerWidget {
  const CompactPlayer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(playerProvider);
    final song = player.current;

    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        final layout = compactLayoutFor(size);
        final presets = WindowSizePresetButtons(current: matchingPreset(size));

        if (song == null) return _Idle(presets: presets);

        return switch (layout) {
          CompactLayout.portrait => CompactPortraitPlayer(
            song: song,
            presets: presets,
            available: size,
          ),
          CompactLayout.strip => CompactStripPlayer(
            song: song,
            presets: presets,
            available: size,
          ),
        };
      },
    );
  }
}

class _Idle extends StatelessWidget {
  const _Idle({required this.presets});

  final Widget presets;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Stack(
      children: [
        Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.music_note_rounded,
                  size: 32,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(height: 12),
                Text(
                  'Nothing playing',
                  style: theme.textTheme.titleSmall,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 4),
                Text(
                  'Make the window bigger to browse your library',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
        Positioned(top: 4, right: 4, child: presets),
      ],
    );
  }
}

/// Tall window: the artwork gets the room it deserves.
///
/// Takes the song rather than reading the player, so it can be rendered — and
/// checked for overflow at the smallest window sizes — without an audio device.
class CompactPortraitPlayer extends ConsumerStatefulWidget {
  const CompactPortraitPlayer({
    super.key,
    required this.song,
    required this.presets,
    required this.available,
  });

  final Song song;
  final Widget presets;
  final Size available;

  @override
  ConsumerState<CompactPortraitPlayer> createState() =>
      _CompactPortraitPlayerState();
}

class _CompactPortraitPlayerState
    extends ConsumerState<CompactPortraitPlayer> {
  /// Lyrics instead of the artwork. Only in this layout: the strip has no room
  /// for a line of text, let alone a scrolling column of them.
  bool _lyrics = false;

  @override
  Widget build(BuildContext context) {
    final song = widget.song;
    final available = widget.available;
    final player = ref.watch(playerProvider);
    final theme = Theme.of(context);
    // Leave room for the text, seek bar and transport; the artwork takes what
    // is left, square, and never wider than the window.
    final side = (available.height - 210).clamp(80.0, available.width - 40);

    return Column(
      children: [
        Align(
          alignment: Alignment.topRight,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: _lyrics ? 'Show the artwork' : 'Show the lyrics',
                visualDensity: VisualDensity.compact,
                isSelected: _lyrics,
                icon: const Icon(Icons.lyrics_outlined, size: 18),
                selectedIcon: const Icon(Icons.lyrics_rounded, size: 18),
                onPressed: () => setState(() => _lyrics = !_lyrics),
              ),
              widget.presets,
            ],
          ),
        ),
        Expanded(
          child: _lyrics
              ? _CompactLyrics(song: song)
              : Center(
                  child: GestureDetector(
                    onTap: () => openFullPlayer(context),
                    child: AlbumArt(
                      path: song.albumArtPath,
                      size: side,
                      radius: 20,
                    ),
                  ),
                ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Column(
            children: [
              Text(
                song.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium,
              ),
              Text(
                song.displayArtist,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 10),
              _SeekBar(player: player),
              const SizedBox(height: 6),
              const TransportBar(),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ],
    );
  }
}

/// Short window: one horizontal strip.
class CompactStripPlayer extends ConsumerWidget {
  const CompactStripPlayer({
    super.key,
    required this.song,
    required this.presets,
    required this.available,
  });

  final Song song;
  final Widget presets;
  final Size available;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(playerProvider);
    final theme = Theme.of(context);
    final tiny = available.width < _tinyWidth;
    // Bounded by width as well as height: a short, narrow window would
    // otherwise give the artwork room the transport needs.
    final side = (available.height - 20).clamp(
      48.0,
      (available.width * 0.34).clamp(48.0, 132.0),
    );

    return Padding(
      padding: const EdgeInsets.all(10),
      child: Row(
        spacing: 12,
        children: [
          GestureDetector(
            onTap: () => openFullPlayer(context),
            child: AlbumArt(
              path: song.albumArtPath,
              size: side,
              radius: shapeMedium,
            ),
          ),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!tiny)
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              song.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleSmall,
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
                      presets,
                    ],
                  ),
                _SeekBar(player: player, showTimes: !tiny),
                // The full compact bar needs ~235px; at the smallest window
                // sizes only the three transport buttons fit.
                TransportBar(compact: true, showToggles: !tiny),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SeekBar extends StatelessWidget {
  const _SeekBar({required this.player, this.showTimes = true});

  final PlayerService player;
  final bool showTimes;

  @override
  Widget build(BuildContext context) => PositionBuilder(
    builder: (context, position) {
      final total = player.duration.inMilliseconds;
      final fraction = total <= 0
          ? 0.0
          : (position.inMilliseconds / total).clamp(0.0, 1.0);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // The same travelling wave the full player draws, scaled down: the
          // wave is what says something is playing, and a straight line in a
          // window this small looked like a different app.
          WavySlider(
            value: fraction,
            animate: player.playing,
            onChangeEnd: player.seekFraction,
            height: 24,
            waveAmplitude: 3,
            wavelength: 28,
            strokeWidth: 4,
            thumbRadius: 6,
            thumbLineHeight: 18,
          ),
          if (showTimes)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    formatDuration(position),
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                  Text(
                    formatDuration(player.duration),
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ],
              ),
            ),
        ],
      );
    },
  );
}

/// Lyrics in the space the artwork had.
///
/// The scrolling view is the full player's, with tighter padding and centred
/// lines — a 500px window has room for the words but not for the panel's
/// toolbar, so the toggle in the corner is the whole interface.
class _CompactLyrics extends ConsumerWidget {
  const _CompactLyrics({required this.song});

  final Song song;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final async = ref.watch(currentLyricsProvider);

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: ClipRRect(
        borderRadius: const BorderRadius.all(Radius.circular(shapeLarge)),
        child: ColoredBox(
          color: theme.colorScheme.surfaceContainerLow,
          child: switch (async) {
            AsyncValue(hasError: true) => _LyricsMessage(
              icon: Icons.cloud_off_rounded,
              text: 'Could not load the lyrics.',
            ),
            AsyncValue(isLoading: true, value: null) => const Center(
              child: SizedBox.square(
                dimension: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
            AsyncValue(:final value) when value == null || value.isEmpty =>
              _LyricsMessage(
                icon: Icons.lyrics_outlined,
                text: 'No lyrics for this track yet.',
                action: TextButton(
                  onPressed: () => showLyricsSearchDialog(context, song),
                  child: const Text('Search'),
                ),
              ),
            AsyncValue(:final value) => LyricsView(
              lyrics: value!,
              centerAlign: true,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
            ),
          },
        ),
      ),
    );
  }
}

class _LyricsMessage extends StatelessWidget {
  const _LyricsMessage({required this.icon, required this.text, this.action});

  final IconData icon;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 24, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 8),
            Text(
              text,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            ?action,
          ],
        ),
      ),
    );
  }
}

/// The compact shell. The title bar comes from WindowChrome, app-wide.
class CompactShell extends StatelessWidget {
  const CompactShell({super.key});

  @override
  Widget build(BuildContext context) => const CompactPlayer();
}
