import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/providers.dart';
import '../components/common.dart';
import '../components/library_widgets.dart';

/// Port of `presentation/screens/StatsScreen` (phase 1 subset: totals plus the
/// most played tracks; charts and listening streaks land in phase 5).
class StatsScreen extends ConsumerWidget {
  const StatsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stats = ref.watch(statsProvider);
    final db = ref.watch(databaseProvider);
    final counts = db.playCounts();
    final top = db.songsByIds(
      (counts.entries.toList()
            ..sort((a, b) => b.value.compareTo(a.value)))
          .take(25)
          .map((e) => e.key)
          .toList(),
    );
    final theme = Theme.of(context);

    Widget tile(String label, String value, IconData icon) => Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: theme.colorScheme.primary),
            const SizedBox(height: 12),
            Text(value, style: theme.textTheme.headlineSmall),
            Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );

    return Scaffold(
      appBar: AppBar(title: const Text('Statistics')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          GridView.count(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisCount: 3,
            childAspectRatio: 1.6,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            children: [
              tile('Songs', '${stats.songCount}', Icons.music_note_rounded),
              tile('Albums', '${stats.albumCount}', Icons.album_rounded),
              tile('Artists', '${stats.artistCount}', Icons.person_rounded),
              tile('Total plays', '${stats.totalPlays}',
                  Icons.play_circle_outline_rounded),
              tile('Library length', formatLongDuration(stats.totalDuration),
                  Icons.timelapse_rounded),
              tile('Listened', formatLongDuration(stats.listenedDuration),
                  Icons.headphones_rounded),
            ],
          ),
          const SizedBox(height: 8),
          const SectionHeader(title: 'Most played'),
          if (top.isEmpty)
            const EmptyState(
              icon: Icons.bar_chart_rounded,
              title: 'Nothing played yet',
              message: 'Your listening history will show up here.',
            )
          else
            for (var i = 0; i < top.length; i++)
              SongTile(
                song: top[i],
                leadingIndex: i,
                showArtwork: false,
                trailing: Text('${counts[top[i].id] ?? 0} plays'),
              ),
        ],
      ),
    );
  }
}
