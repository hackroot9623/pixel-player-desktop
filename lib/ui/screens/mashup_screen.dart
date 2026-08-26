import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/models.dart';
import '../../player/deck_controller.dart';
import '../../state/providers.dart';
import '../components/album_art.dart';
import '../components/common.dart';
import '../components/library_widgets.dart';
import '../theme/shapes.dart';

/// Port of `presentation/screens/MashupScreen` + `MashupViewModel`.
///
/// Two decks, each an independent decoder, with a crossfader between them. The
/// main queue is untouched — this is a mixer sitting beside the player, not a
/// mode it goes into.
class MashupScreen extends ConsumerStatefulWidget {
  const MashupScreen({super.key});

  @override
  ConsumerState<MashupScreen> createState() => _MashupScreenState();
}

class _MashupScreenState extends ConsumerState<MashupScreen> {
  /// Owned by the route rather than a provider: leaving the screen must take
  /// both decoders with it.
  final _mixer = MashupController();

  @override
  void dispose() {
    _mixer.dispose();
    super.dispose();
  }

  DeckCard _card(String label, DeckController deck, double gain) => DeckCard(
    label: label,
    song: deck.song,
    playing: deck.playing,
    position: deck.position,
    duration: deck.duration,
    progress: deck.progress,
    volume: deck.volume,
    speed: deck.speed,
    gain: gain,
    onPick: () => _pick(deck),
    onVolume: (value) => _mixer.setDeckVolume(deck, value),
    onPlayPause: deck.playPause,
    onSeek: deck.seekToFraction,
    onNudge: deck.nudge,
    onSpeed: deck.setSpeed,
  );

  Future<void> _pick(DeckController deck) async {
    final song = await showDialog<Song>(
      context: context,
      builder: (_) => const _SongPickerDialog(),
    );
    if (song != null) await deck.load(song);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Mashup'),
      ),
      // One listenable drives the whole screen: the mixer forwards its decks'
      // changes, and the decks tick on every position update.
      body: ListenableBuilder(
        listenable: _mixer,
        builder: (context, _) {
          final gains = _mixer.gains;
          return LayoutBuilder(
            builder: (context, constraints) {
              // Side by side is the mixer layout everyone expects, but two
              // decks need real width before that beats stacking them.
              final sideBySide = constraints.maxWidth >= 900;
              final decks = [
                _card('A', _mixer.deckA, gains.a),
                _card('B', _mixer.deckB, gains.b),
              ];

              return ListView(
                padding: const EdgeInsets.all(24),
                children: [
                  if (sideBySide)
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      spacing: 16,
                      children: [for (final deck in decks) Expanded(child: deck)],
                    )
                  else
                    Column(spacing: 16, children: decks),
                  const SizedBox(height: 24),
                  _Crossfader(
                    value: _mixer.crossfader,
                    onChanged: _mixer.setCrossfader,
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}

/// Presentational on purpose: a [DeckController] owns a real decoder, which a
/// widget test cannot drive. Taking plain values means the layout — the part
/// that overflows — is testable.
@visibleForTesting
class DeckCard extends StatelessWidget {
  const DeckCard({
    super.key,
    required this.label,
    required this.song,
    required this.playing,
    required this.position,
    required this.duration,
    required this.progress,
    required this.volume,
    required this.speed,
    required this.gain,
    required this.onPick,
    required this.onVolume,
    this.onPlayPause,
    this.onSeek,
    this.onNudge,
    this.onSpeed,
  });

  final String label;
  final Song? song;
  final bool playing;
  final Duration position;
  final Duration duration;
  final double progress;
  final double volume;
  final double speed;

  /// Deck fader and crossfader combined — what is actually audible.
  final double gain;
  final VoidCallback onPick;
  final ValueChanged<double> onVolume;
  final VoidCallback? onPlayPause;
  final ValueChanged<double>? onSeek;
  final ValueChanged<Duration>? onNudge;
  final ValueChanged<double>? onSpeed;

  bool get _loaded => song != null;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final song = this.song;

    return Container(
      decoration: ShapeDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        shape: smoothCorner(28),
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('Deck $label', style: theme.textTheme.titleMedium),
              const Spacer(),
              // Reads at a glance which deck the crossfader is favouring.
              _GainMeter(gain: gain),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              AlbumArt(path: song?.albumArtPath, size: 72, radius: 16),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      song?.title ?? 'No track loaded',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall,
                    ),
                    Text(
                      song?.displayArtist ?? 'Pick something to mix',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: onPick,
                      icon: const Icon(Icons.library_music_rounded, size: 18),
                      label: Text(song == null ? 'Load track' : 'Change'),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Slider(
            value: progress,
            onChanged: _loaded ? onSeek : null,
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  formatDuration(position),
                  style: theme.textTheme.labelSmall,
                ),
                Text(
                  formatDuration(duration),
                  style: theme.textTheme.labelSmall,
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              IconButton(
                tooltip: 'Nudge back',
                onPressed: _loaded ? () => onNudge?.call(-deckNudge) : null,
                icon: const Icon(Icons.keyboard_double_arrow_left_rounded),
              ),
              IconButton.filled(
                tooltip: playing ? 'Pause' : 'Play',
                onPressed: _loaded ? onPlayPause : null,
                icon: Icon(
                  playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                ),
              ),
              IconButton(
                tooltip: 'Nudge forward',
                onPressed: _loaded ? () => onNudge?.call(deckNudge) : null,
                icon: const Icon(Icons.keyboard_double_arrow_right_rounded),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _LabelledSlider(
                  icon: Icons.volume_up_rounded,
                  label: '${(volume * 100).round()}%',
                  value: volume,
                  onChanged: onVolume,
                ),
              ),
            ],
          ),
          _LabelledSlider(
            icon: Icons.speed_rounded,
            label: '${speed.toStringAsFixed(2)}×',
            value: speed,
            min: minDeckSpeed,
            max: maxDeckSpeed,
            // Enough steps to beat-match by ear without hunting for a value.
            divisions: 30,
            onChanged: _loaded ? onSpeed : null,
            onReset: speed == 1 ? null : () => onSpeed?.call(1),
          ),
        ],
      ),
    );
  }
}

/// Small bar showing the deck's audible level.
class _GainMeter extends StatelessWidget {
  const _GainMeter({required this.gain});

  final double gain;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Tooltip(
      message: 'Audible level: ${(gain * 100).round()}%',
      child: SizedBox(
        width: 72,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: gain,
            minHeight: 8,
            backgroundColor: theme.colorScheme.surfaceContainerHighest,
          ),
        ),
      ),
    );
  }
}

class _LabelledSlider extends StatelessWidget {
  const _LabelledSlider({
    required this.icon,
    required this.label,
    required this.value,
    required this.onChanged,
    this.min = 0,
    this.max = 1,
    this.divisions,
    this.onReset,
  });

  final IconData icon;
  final String label;
  final double value;
  final ValueChanged<double>? onChanged;
  final double min;
  final double max;
  final int? divisions;
  final VoidCallback? onReset;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(icon, size: 18, color: theme.colorScheme.onSurfaceVariant),
        Expanded(
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 48,
          child: Text(
            label,
            textAlign: TextAlign.right,
            style: theme.textTheme.labelSmall,
          ),
        ),
        // Getting back to exactly 1.00x by dragging is fiddly.
        SizedBox(
          width: 32,
          child: onReset == null
              ? null
              : IconButton(
                  tooltip: 'Reset',
                  visualDensity: VisualDensity.compact,
                  onPressed: onReset,
                  icon: const Icon(Icons.restart_alt_rounded, size: 16),
                ),
        ),
      ],
    );
  }
}

/// The crossfader, -1 (deck A) to +1 (deck B).
class _Crossfader extends StatelessWidget {
  const _Crossfader({required this.value, required this.onChanged});

  final double value;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: ShapeDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        shape: smoothCorner(28),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('A', style: theme.textTheme.titleMedium),
              Text('Crossfader', style: theme.textTheme.labelMedium),
              Text('B', style: theme.textTheme.titleMedium),
            ],
          ),
          Slider(
            value: value,
            min: -1,
            max: 1,
            // Double-tap-to-centre does not exist on a Slider, so a detent at
            // the middle is how you get an even blend back.
            divisions: 40,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}

/// Picks a track for a deck. Searching matters here — you are looking for one
/// specific song to mix, not browsing.
class _SongPickerDialog extends ConsumerStatefulWidget {
  const _SongPickerDialog();

  @override
  ConsumerState<_SongPickerDialog> createState() => _SongPickerDialogState();
}

class _SongPickerDialogState extends ConsumerState<_SongPickerDialog> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final songs = ref.watch(libraryProvider).songs;
    final query = _query.trim().toLowerCase();
    final matches = query.isEmpty
        ? songs
        : [
            for (final song in songs)
              if (song.title.toLowerCase().contains(query) ||
                  song.displayArtist.toLowerCase().contains(query) ||
                  song.album.toLowerCase().contains(query))
                song,
          ];

    return Dialog(
      child: SizedBox(
        width: 520,
        height: 560,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: SearchBar(
                autoFocus: true,
                hintText: 'Search tracks',
                leading: const Icon(Icons.search_rounded),
                onChanged: (value) => setState(() => _query = value),
              ),
            ),
            Expanded(
              child: matches.isEmpty
                  ? const EmptyState(
                      icon: Icons.search_off_rounded,
                      title: 'No matches',
                      message: 'Nothing in the library matches that.',
                    )
                  : ListView.builder(
                      itemCount: matches.length,
                      itemBuilder: (context, index) => SongTile(
                        song: matches[index],
                        selectable: false,
                        onTap: () => Navigator.of(context).pop(matches[index]),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
