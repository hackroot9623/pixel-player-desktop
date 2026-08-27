import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../player/equalizer.dart';
import '../../state/providers.dart';

/// Ten bands, the presets from the phone, and the three effects that stood in
/// for Android's BassBoost, Virtualizer and LoudnessEnhancer.
///
/// Everything applies live: mpv takes a new filter chain without restarting the
/// track, so a slider is heard while it is being dragged.
class EqualizerScreen extends ConsumerWidget {
  const EqualizerScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final state = ref.watch(equalizerProvider);
    final controller = ref.read(equalizerProvider.notifier);
    final active = state.preset;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Equalizer'),
        actions: [
          IconButton(
            tooltip: 'Reset to flat',
            icon: const Icon(Icons.restart_alt_rounded),
            onPressed: controller.reset,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        children: [
          Card(
            child: SwitchListTile(
              title: const Text('Equalizer'),
              subtitle: Text(
                state.enabled
                    ? (state.isNeutral
                          ? 'On, but flat — nothing is being changed'
                          : 'On · ${active?.label ?? 'Custom'}')
                    : 'Off — the signal is untouched',
              ),
              value: state.enabled,
              onChanged: controller.setEnabled,
            ),
          ),
          const SizedBox(height: 16),

          Text('Presets', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final preset in EqualizerPreset.all)
                ChoiceChip(
                  label: Text(preset.label),
                  selected: state.enabled && active?.name == preset.name,
                  onSelected: (_) => controller.selectPreset(preset),
                ),
            ],
          ),
          const SizedBox(height: 20),

          Text('Bands', style: theme.textTheme.titleSmall),
          Text(
            'Gain in decibels, $equalizerMinGain to +$equalizerMaxGain.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(
                children: [
                  for (var band = 0; band < equalizerBandCount; band++)
                    _BandRow(
                      label: '${equalizerBandLabel(band)}Hz',
                      gain: state.gains[band],
                      enabled: state.enabled,
                      onChanged: (value) => controller.setGain(band, value),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),

          Text('Effects', style: theme.textTheme.titleSmall),
          Text(
            'Bass boost lifts everything below 100 Hz; width pushes the stereo '
            'image outwards; levelling evens out quiet and loud passages.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(
                children: [
                  _EffectRow(
                    label: 'Bass boost',
                    icon: Icons.graphic_eq_rounded,
                    value: state.bassBoost,
                    enabled: state.enabled,
                    onChanged: controller.setBassBoost,
                  ),
                  _EffectRow(
                    label: 'Stereo width',
                    icon: Icons.surround_sound_rounded,
                    value: state.virtualizer,
                    enabled: state.enabled,
                    onChanged: controller.setVirtualizer,
                  ),
                  _EffectRow(
                    label: 'Levelling',
                    icon: Icons.compress_rounded,
                    value: state.loudness,
                    enabled: state.enabled,
                    onChanged: controller.setLoudness,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),

          // Worth showing: it explains why a setting did or did not take, and
          // it is the thing mpv is actually given.
          ExpansionTile(
            title: Text('Filter chain', style: theme.textTheme.titleSmall),
            subtitle: Text(
              'What mpv is being asked to do',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: SelectableText(
                  state.filter.isEmpty ? '(none)' : state.filter,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _BandRow extends StatelessWidget {
  const _BandRow({
    required this.label,
    required this.gain,
    required this.enabled,
    required this.onChanged,
  });

  final String label;
  final int gain;
  final bool enabled;
  final void Function(int value) onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          SizedBox(
            width: 56,
            child: Text(label, style: theme.textTheme.bodySmall),
          ),
          Expanded(
            child: Slider(
              value: gain.toDouble(),
              min: equalizerMinGain.toDouble(),
              max: equalizerMaxGain.toDouble(),
              // One stop per decibel, so a value can be hit exactly.
              divisions: equalizerMaxGain - equalizerMinGain,
              onChanged: enabled
                  ? (value) => onChanged(value.round())
                  : null,
            ),
          ),
          SizedBox(
            width: 44,
            child: Text(
              '${gain > 0 ? '+' : ''}$gain',
              textAlign: TextAlign.end,
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

class _EffectRow extends StatelessWidget {
  const _EffectRow({
    required this.label,
    required this.icon,
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  final String label;
  final IconData icon;
  final int value;
  final bool enabled;
  final void Function(int value) onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          Icon(icon, size: 18),
          const SizedBox(width: 8),
          SizedBox(
            width: 96,
            child: Text(label, style: theme.textTheme.bodySmall),
          ),
          Expanded(
            child: Slider(
              value: value.clamp(0, 100).toDouble(),
              max: 100,
              onChanged: enabled
                  ? (dragged) => onChanged(dragged.round())
                  : null,
            ),
          ),
          SizedBox(
            width: 44,
            child: Text(
              '$value%',
              textAlign: TextAlign.end,
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}
