import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/metadata/cover_fixer.dart';
import '../../data/tags/tag_writer.dart';
import '../../state/providers.dart';
import '../components/common.dart';

/// Finds and writes the covers a library is missing.
///
/// Two steps, deliberately: Find downloads and shows what it found, Apply writes
/// it into the files. A cover the user can see as a thumbnail before it is
/// written is the difference between a batch tool they trust and one they run
/// once.
class CoverArtScreen extends ConsumerStatefulWidget {
  const CoverArtScreen({super.key});

  @override
  ConsumerState<CoverArtScreen> createState() => _CoverArtScreenState();
}

class _CoverArtScreenState extends ConsumerState<CoverArtScreen> {
  @override
  void initState() {
    super.initState();
    // After the frame, because scanning notifies listeners and this is build's
    // own turn.
    WidgetsBinding.instance.addPostFrameCallback((_) => _scan());
  }

  void _scan() {
    final songs = ref.read(libraryProvider).songs;
    ref.read(coverFixerProvider).scan(songs);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fixer = ref.watch(coverFixerProvider);
    final candidates = fixer.candidates;
    final tracks = candidates.fold(0, (sum, c) => sum + c.album.songs.length);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Missing covers'),
        actions: [
          IconButton(
            tooltip: 'Rescan the library',
            onPressed: fixer.busy ? null : _scan,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    candidates.isEmpty
                        ? 'Every album has a cover'
                        : '${plural(candidates.length, 'album')} without a '
                              'cover, ${plural(tracks, 'file')} in total',
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Covers come from the Cover Art Archive, and from Deezer '
                    'when the archive has none. One album is looked up a '
                    'second — MusicBrainz asks for that, and a batch that '
                    'ignored it would be blocked.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  if (fixer.busy) ...[
                    const SizedBox(height: 16),
                    LinearProgressIndicator(value: fixer.progress),
                    const SizedBox(height: 8),
                    Text(
                      fixer.applying
                          ? 'Writing…'
                          : 'Looked up ${fixer.searched} of '
                                '${candidates.length}, found ${fixer.found}',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                  if (!fixer.busy && fixer.written > 0) ...[
                    const SizedBox(height: 12),
                    Text(
                      'Wrote the cover into ${plural(fixer.written, 'file')}'
                      '${fixer.failures.isEmpty ? '.' : ', '
                            '${plural(fixer.failures.length, 'file')} could '
                            'not be written.'}',
                      style: theme.textTheme.bodyMedium,
                    ),
                  ],
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton.icon(
                        onPressed: fixer.busy || candidates.isEmpty
                            ? null
                            : fixer.find,
                        icon: const Icon(Icons.search_rounded, size: 18),
                        label: const Text('Find covers'),
                      ),
                      FilledButton.tonalIcon(
                        onPressed: fixer.busy || fixer.selectedCount == 0
                            ? null
                            : fixer.apply,
                        icon: const Icon(Icons.save_rounded, size: 18),
                        label: Text(
                          'Write ${plural(fixer.selectedCount, 'cover')}',
                        ),
                      ),
                      if (fixer.busy)
                        TextButton.icon(
                          onPressed: fixer.cancel,
                          icon: const Icon(Icons.stop_rounded, size: 18),
                          label: const Text('Stop'),
                        ),
                      if (!fixer.busy && fixer.found > 0) ...[
                        TextButton(
                          onPressed: () => fixer.selectAll(true),
                          child: const Text('Select all'),
                        ),
                        TextButton(
                          onPressed: () => fixer.selectAll(false),
                          child: const Text('Select none'),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          for (final candidate in candidates)
            _CandidateTile(
              candidate: candidate,
              onToggle: (value) => fixer.toggle(candidate, value),
            ),
        ],
      ),
    );
  }
}

class _CandidateTile extends StatelessWidget {
  const _CandidateTile({required this.candidate, required this.onToggle});

  final CoverCandidate candidate;
  final ValueChanged<bool> onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final album = candidate.album;
    final unwritable = album.songs.where((s) => !canWriteTags(s.path)).length;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: SizedBox.square(
          dimension: 56,
          child: switch (candidate.state) {
            CoverState.searching => const Center(
              child: SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
            _ when candidate.hasArtwork => ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Image.memory(
                candidate.artwork!,
                fit: BoxFit.cover,
                // A cover the archive serves broken should not take the screen
                // down with it.
                errorBuilder: (context, error, stack) =>
                    const Icon(Icons.broken_image_outlined),
              ),
            ),
            _ => Icon(
              Icons.album_outlined,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          },
        ),
        title: Text(album.album.isEmpty ? 'Unknown album' : album.album),
        subtitle: Text([
          album.artist,
          plural(album.songs.length, 'track'),
          if (unwritable > 0) '$unwritable in a format tags cannot be written to',
          switch (candidate.state) {
            CoverState.notFound => 'No cover found',
            CoverState.skipped => candidate.error ?? 'Skipped',
            CoverState.failed => candidate.error ?? 'Failed',
            CoverState.written => 'Written',
            CoverState.found => candidate.match?.summary ?? 'Found',
            _ => '',
          },
        ].where((part) => part.isNotEmpty).join(' · ')),
        trailing: candidate.state == CoverState.written
            ? Icon(Icons.check_circle_rounded, color: theme.colorScheme.primary)
            : Checkbox(
                value: candidate.selected,
                onChanged: candidate.hasArtwork
                    ? (value) => onToggle(value ?? false)
                    : null,
              ),
      ),
    );
  }
}
