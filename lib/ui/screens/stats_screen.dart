import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/providers.dart';
import '../components/common.dart';
import '../components/library_widgets.dart';
import '../theme/shapes.dart';

/// Port of `presentation/screens/StatsScreen`.
///
/// Everything here is ranked by *time listened* rather than play count: a track
/// started and skipped twenty times is not a favourite, which is exactly what a
/// count-based list would claim.
class StatsScreen extends ConsumerWidget {
  const StatsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stats = ref.watch(statsSummaryProvider);
    final period = ref.watch(statsPeriodProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Statistics'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: DropdownButton<StatsPeriod>(
              value: period,
              underline: const SizedBox.shrink(),
              items: [
                for (final option in StatsPeriod.values)
                  DropdownMenuItem(value: option, child: Text(option.label)),
              ],
              onChanged: (value) {
                if (value != null) {
                  ref.read(statsPeriodProvider.notifier).state = value;
                }
              },
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          _Tiles(stats: stats),
          const SizedBox(height: 24),
          if (!stats.hasHistory)
            const EmptyState(
              icon: Icons.bar_chart_rounded,
              title: 'Nothing listened yet',
              message:
                  'Play some music and this fills in — time listened, when you '
                  'listen, and what you come back to.',
            )
          else ...[
            _Card(
              title: 'Listening',
              subtitle: period.label,
              child: _DayChart(days: stats.byDay),
            ),
            const SizedBox(height: 16),
            _Card(
              title: 'When you listen',
              subtitle: 'By hour of the day',
              child: _HourChart(byHour: stats.byHour),
            ),
            const SizedBox(height: 24),
            if (stats.topArtists.isNotEmpty) ...[
              const SectionHeader(title: 'Top artists'),
              _RankedBars(entries: stats.topArtists.take(8).toList()),
              const SizedBox(height: 16),
            ],
            if (stats.topAlbums.isNotEmpty) ...[
              const SectionHeader(title: 'Top albums'),
              _RankedBars(entries: stats.topAlbums.take(8).toList()),
              const SizedBox(height: 16),
            ],
            const SectionHeader(
              title: 'Most listened',
              subtitle: 'By time, not play count',
            ),
            for (var i = 0; i < stats.topSongs.length; i++)
              SongTile(
                song: stats.topSongs[i].$1,
                leadingIndex: i,
                showArtwork: false,
                trailing: Text(
                  formatLongDuration(stats.topSongs[i].$2),
                  style: theme.textTheme.bodySmall,
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _Tiles extends StatelessWidget {
  const _Tiles({required this.stats});

  final StatsSummary stats;

  @override
  Widget build(BuildContext context) => GridView.count(
    shrinkWrap: true,
    physics: const NeverScrollableScrollPhysics(),
    crossAxisCount: 3,
    childAspectRatio: 1.7,
    crossAxisSpacing: 12,
    mainAxisSpacing: 12,
    children: [
      _Tile(
        label: 'Listened',
        value: formatLongDuration(stats.listened),
        icon: Icons.headphones_rounded,
      ),
      _Tile(
        label: 'Day streak',
        value: '${stats.streakDays}',
        icon: Icons.local_fire_department_rounded,
      ),
      _Tile(
        label: 'Plays',
        value: '${stats.plays}',
        icon: Icons.play_circle_outline_rounded,
      ),
      _Tile(
        label: 'Songs',
        value: '${stats.songCount}',
        icon: Icons.music_note_rounded,
      ),
      _Tile(
        label: 'Albums',
        value: '${stats.albumCount}',
        icon: Icons.album_rounded,
      ),
      _Tile(
        label: 'Library length',
        value: formatLongDuration(stats.libraryDuration),
        icon: Icons.timelapse_rounded,
      ),
    ],
  );
}

class _Tile extends StatelessWidget {
  const _Tile({required this.label, required this.value, required this.icon});

  final String label;
  final String value;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Icon(icon, color: theme.colorScheme.primary, size: 20),
            Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleLarge,
            ),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.title, this.subtitle, required this.child});

  final String title;
  final String? subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: ShapeDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        shape: smoothCorner(24),
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: theme.textTheme.titleSmall),
          if (subtitle != null)
            Text(
              subtitle!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          const SizedBox(height: 16),
          child,
        ],
      ),
    );
  }
}

/// Time listened per day. Drawn by hand rather than pulling in a chart package
/// — it is a row of bars.
class _DayChart extends StatelessWidget {
  const _DayChart({required this.days});

  final List<(DateTime day, int ms)> days;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (days.isEmpty) return const SizedBox(height: 120);
    final peak = days.map((d) => d.$2).reduce((a, b) => a > b ? a : b);

    return SizedBox(
      height: 132,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        spacing: 2,
        children: [
          for (final (day, ms) in days)
            Expanded(
              child: Tooltip(
                message:
                    '${day.day}/${day.month} · '
                    '${formatLongDuration(Duration(milliseconds: ms))}',
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    // A zero day still shows a sliver, so the axis reads as a
                    // timeline rather than a gap.
                    Container(
                      height: peak == 0 ? 2 : (ms / peak * 104).clamp(2, 104),
                      decoration: BoxDecoration(
                        color: ms == 0
                            ? theme.colorScheme.surfaceContainerHighest
                            : theme.colorScheme.primary,
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                    const SizedBox(height: 4),
                    SizedBox(
                      height: 12,
                      child: days.length <= 14 || day.day == 1
                          ? Text(
                              '${day.day}',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            )
                          : null,
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _HourChart extends StatelessWidget {
  const _HourChart({required this.byHour});

  final Map<int, int> byHour;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final peak = byHour.values.isEmpty
        ? 0
        : byHour.values.reduce((a, b) => a > b ? a : b);

    return SizedBox(
      height: 110,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        spacing: 2,
        children: [
          for (var hour = 0; hour < 24; hour++)
            Expanded(
              child: Tooltip(
                message:
                    '${hour.toString().padLeft(2, '0')}:00 · '
                    '${formatLongDuration(Duration(milliseconds: byHour[hour] ?? 0))}',
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Container(
                      height: peak == 0
                          ? 2
                          : ((byHour[hour] ?? 0) / peak * 84).clamp(2, 84),
                      decoration: BoxDecoration(
                        color: (byHour[hour] ?? 0) == 0
                            ? theme.colorScheme.surfaceContainerHighest
                            : theme.colorScheme.tertiary,
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                    const SizedBox(height: 4),
                    SizedBox(
                      height: 12,
                      child: hour % 6 == 0
                          ? Text(
                              '$hour',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            )
                          : null,
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Horizontal bars, for ranked name/duration pairs.
class _RankedBars extends StatelessWidget {
  const _RankedBars({required this.entries});

  final List<(String, Duration)> entries;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (entries.isEmpty) return const SizedBox.shrink();
    final peak = entries.first.$2.inMilliseconds;

    return Column(
      children: [
        for (final (name, listened) in entries)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                SizedBox(
                  width: 160,
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: peak == 0
                          ? 0
                          : (listened.inMilliseconds / peak).clamp(0.0, 1.0),
                      minHeight: 12,
                      backgroundColor:
                          theme.colorScheme.surfaceContainerHighest,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                SizedBox(
                  width: 70,
                  child: Text(
                    formatLongDuration(listened),
                    textAlign: TextAlign.right,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
