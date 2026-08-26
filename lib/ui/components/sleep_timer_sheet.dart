import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/providers.dart';
import '../theme/shapes.dart';
import 'common.dart';

/// Port of `presentation/components/TimerOptionsBottomSheet`.
///
/// Three ways to stop: a duration picked off the predefined ladder, a number of
/// songs, or the end of the current track. Whichever is active is echoed back at
/// the top with a live countdown.
const _predefinedMinutes = [0, 5, 10, 15, 20, 30, 45, 60];

Future<void> showSleepTimerSheet(BuildContext context) =>
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => const SleepTimerSheet(),
    );

class SleepTimerSheet extends ConsumerStatefulWidget {
  const SleepTimerSheet({super.key});

  @override
  ConsumerState<SleepTimerSheet> createState() => _SleepTimerSheetState();
}

class _SleepTimerSheetState extends ConsumerState<SleepTimerSheet> {
  double _minutesIndex = 3; // 15 minutes
  double _songCount = 1;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // The countdown is derived from a wall-clock deadline, so it needs a
    // heartbeat to repaint.
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && ref.read(playerProvider).sleepTimerRemaining != null) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final player = ref.watch(playerProvider);
    final theme = Theme.of(context);
    final minutes = _predefinedMinutes[_minutesIndex.round()];
    final remaining = player.sleepTimerRemaining;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.bedtime_rounded, color: theme.colorScheme.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Sleep timer',
                    style: theme.textTheme.headlineSmall,
                  ),
                ),
                if (player.sleepTimerActive)
                  TextButton.icon(
                    onPressed: () {
                      player.cancelSleepTimer();
                      Navigator.of(context).pop();
                    },
                    icon: const Icon(Icons.timer_off_rounded),
                    label: const Text('Turn off'),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            AnimatedContainer(
              duration: const Duration(milliseconds: 260),
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: ShapeDecoration(
                color: player.sleepTimerActive
                    ? theme.colorScheme.primaryContainer
                    : theme.colorScheme.surfaceContainerHighest,
                shape: smoothCorner(player.sleepTimerActive ? 28 : 16),
              ),
              child: Text(
                switch (player) {
                  _ when remaining != null =>
                    'Stopping in ${formatDuration(remaining)}',
                  _ when player.sleepAtEndOfTrack =>
                    'Stopping at the end of this track',
                  _ when player.sleepAfterTracks > 0 =>
                    'Stopping after ${plural(player.sleepAfterTracks, 'more song')}',
                  _ => 'No timer set',
                },
                style: theme.textTheme.titleMedium?.copyWith(
                  color: player.sleepTimerActive
                      ? theme.colorScheme.onPrimaryContainer
                      : theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(height: 24),

            Text('After a while', style: theme.textTheme.titleSmall),
            Slider(
              value: _minutesIndex,
              max: (_predefinedMinutes.length - 1).toDouble(),
              divisions: _predefinedMinutes.length - 1,
              label: minutes == 0 ? 'Off' : '$minutes min',
              onChanged: (value) => setState(() => _minutesIndex = value),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.tonalIcon(
                onPressed: minutes == 0
                    ? null
                    : () {
                        player.setSleepTimer(Duration(minutes: minutes));
                        Navigator.of(context).pop();
                      },
                icon: const Icon(Icons.timer_rounded),
                label: Text(minutes == 0 ? 'Off' : 'Stop in $minutes min'),
              ),
            ),
            const Divider(height: 32),

            Text('After some songs', style: theme.textTheme.titleSmall),
            Slider(
              value: _songCount,
              min: 1,
              max: 20,
              divisions: 19,
              label: plural(_songCount.round(), 'song'),
              onChanged: (value) => setState(() => _songCount = value),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.tonalIcon(
                onPressed: () {
                  player.setSleepTimerAfterTracks(_songCount.round());
                  Navigator.of(context).pop();
                },
                icon: const Icon(Icons.music_note_rounded),
                label: Text(
                  'Stop after ${plural(_songCount.round(), 'song')}',
                ),
              ),
            ),
            const Divider(height: 32),

            SizedBox(
              width: double.infinity,
              child: FilledButton.tonalIcon(
                onPressed: () {
                  player.setSleepTimerAtEndOfTrack();
                  Navigator.of(context).pop();
                },
                icon: const Icon(Icons.skip_next_rounded),
                label: const Text('Stop at the end of this track'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
