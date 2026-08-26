import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/lyrics/lrc_parser.dart';
import '../../data/models/lyrics.dart';
import '../../data/models/models.dart';
import '../../state/providers.dart';
import '../theme/shapes.dart';
import 'common.dart';
import 'lyrics_view.dart';

/// Port of `presentation/components/LyricsSheet` plus its toolbar
/// (`LyricsFloatingToolbar`, `LyricsMoreBottomSheet`, `LyricsSyncControls`).
///
/// Docks as a pane beside the player on a wide window; the same widget backs
/// the modal sheet on a narrow one.
class LyricsPanel extends ConsumerWidget {
  const LyricsPanel({super.key, required this.song, this.onClose});

  final Song song;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final async = ref.watch(currentLyricsProvider);

    return Material(
      color: theme.colorScheme.surfaceContainerLow,
      child: Column(
        children: [
          _Header(song: song, onClose: onClose),
          const Divider(height: 1),
          Expanded(
            child: switch (async) {
              AsyncValue(hasError: true, :final error) => EmptyState(
                icon: Icons.cloud_off_rounded,
                title: 'Could not load lyrics',
                message: '$error',
              ),
              AsyncValue(isLoading: true, value: null) => const Center(
                child: CircularProgressIndicator(),
              ),
              AsyncValue(:final value) when value == null || value.isEmpty =>
                EmptyState(
                  icon: Icons.lyrics_outlined,
                  title: 'No lyrics found',
                  message:
                      'Search LRCLIB, or paste your own — an .lrc file next to '
                      'the track works too.',
                  action: FilledButton.icon(
                    onPressed: () => showLyricsSearchDialog(context, song),
                    icon: const Icon(Icons.search_rounded),
                    label: const Text('Search lyrics'),
                  ),
                ),
              AsyncValue(:final value) => LyricsView(lyrics: value!),
            },
          ),
        ],
      ),
    );
  }
}

class _Header extends ConsumerWidget {
  const _Header({required this.song, this.onClose});

  final Song song;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final lyrics = ref.watch(currentLyricsProvider).valueOrNull;
    final repository = ref.read(lyricsRepositoryProvider);

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 8, 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Lyrics', style: theme.textTheme.titleMedium),
                Text(
                  lyrics == null
                      ? song.title
                      : [
                          lyrics.source.label,
                          if (lyrics.isSynced) 'synced' else 'plain text',
                          if (lyrics.offsetMs != 0)
                            '${lyrics.offsetMs > 0 ? '+' : ''}'
                                '${(lyrics.offsetMs / 1000).toStringAsFixed(1)}s',
                        ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          if (lyrics?.isSynced ?? false) ...[
            // Sync nudge, from `LyricsSyncControls`.
            IconButton(
              tooltip: 'Lyrics 0.5s earlier',
              icon: const Icon(Icons.fast_rewind_rounded),
              onPressed: () {
                repository.setOffset(song, (lyrics!.offsetMs) - 500);
                ref.invalidate(currentLyricsProvider);
              },
            ),
            IconButton(
              tooltip: 'Lyrics 0.5s later',
              icon: const Icon(Icons.fast_forward_rounded),
              onPressed: () {
                repository.setOffset(song, (lyrics!.offsetMs) + 500);
                ref.invalidate(currentLyricsProvider);
              },
            ),
          ],
          MenuAnchor(
            builder: (context, controller, _) => IconButton(
              tooltip: 'Lyrics options',
              icon: const Icon(Icons.more_vert_rounded),
              onPressed: () =>
                  controller.isOpen ? controller.close() : controller.open(),
            ),
            menuChildren: [
              MenuItemButton(
                leadingIcon: const Icon(Icons.search_rounded),
                onPressed: () => showLyricsSearchDialog(context, song),
                child: const Text('Search LRCLIB…'),
              ),
              MenuItemButton(
                leadingIcon: const Icon(Icons.refresh_rounded),
                onPressed: () async {
                  await repository.resolve(
                    song,
                    preference: ref.read(settingsProvider).lyricsSource,
                    forceRefresh: true,
                  );
                  ref.invalidate(currentLyricsProvider);
                },
                child: const Text('Re-fetch'),
              ),
              MenuItemButton(
                leadingIcon: const Icon(Icons.edit_rounded),
                onPressed: () => showLyricsEditor(context, song, lyrics),
                child: const Text('Edit lyrics…'),
              ),
              if (lyrics != null && lyrics.offsetMs != 0)
                MenuItemButton(
                  leadingIcon: const Icon(Icons.restart_alt_rounded),
                  onPressed: () {
                    repository.setOffset(song, 0);
                    ref.invalidate(currentLyricsProvider);
                  },
                  child: const Text('Reset timing offset'),
                ),
              MenuItemButton(
                leadingIcon: const Icon(Icons.delete_outline_rounded),
                onPressed: () {
                  repository.clear(song);
                  ref.invalidate(currentLyricsProvider);
                },
                child: const Text('Clear cached lyrics'),
              ),
            ],
          ),
          if (onClose != null)
            IconButton(
              tooltip: 'Close',
              icon: const Icon(Icons.close_rounded),
              onPressed: onClose,
            ),
        ],
      ),
    );
  }
}

Future<void> showLyricsSheet(BuildContext context, Song song) =>
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 720),
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.85,
        maxChildSize: 0.95,
        builder: (context, _) => LyricsPanel(song: song),
      ),
    );

/// Port of `subcomps/FetchLyricsDialog`.
Future<void> showLyricsSearchDialog(BuildContext context, Song song) {
  final controller = TextEditingController(
    text: '${song.title} ${song.primaryArtist.name}'.trim(),
  );
  return showDialog<void>(
    context: context,
    builder: (context) => Consumer(
      builder: (context, ref, _) => _SearchDialog(
        song: song,
        controller: controller,
      ),
    ),
  );
}

class _SearchDialog extends ConsumerStatefulWidget {
  const _SearchDialog({required this.song, required this.controller});

  final Song song;
  final TextEditingController controller;

  @override
  ConsumerState<_SearchDialog> createState() => _SearchDialogState();
}

class _SearchDialogState extends ConsumerState<_SearchDialog> {
  String _query = '';

  @override
  void initState() {
    super.initState();
    _query = widget.controller.text;
  }

  @override
  Widget build(BuildContext context) {
    final results = ref.watch(lyricsSearchProvider(_query));
    final theme = Theme.of(context);

    return AlertDialog(
      title: const Text('Search lyrics'),
      content: SizedBox(
        width: 560,
        height: 460,
        child: Column(
          children: [
            TextField(
              controller: widget.controller,
              autofocus: true,
              decoration: const InputDecoration(
                hintText: 'Title, artist, or a line of the lyrics',
                prefixIcon: Icon(Icons.search_rounded),
              ),
              onSubmitted: (value) => setState(() => _query = value),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: switch (results) {
                AsyncValue(isLoading: true, value: null) => const Center(
                  child: CircularProgressIndicator(),
                ),
                AsyncValue(hasError: true, :final error) => EmptyState(
                  icon: Icons.cloud_off_rounded,
                  title: 'Search failed',
                  message: '$error',
                ),
                AsyncValue(:final value) when (value ?? const []).isEmpty =>
                  const EmptyState(
                    icon: Icons.search_off_rounded,
                    title: 'Nothing found',
                    message: 'Try just the title, or a distinctive line.',
                  ),
                AsyncValue(:final value) => ListView.builder(
                  itemCount: value!.length,
                  itemBuilder: (context, i) {
                    final result = value[i];
                    return ListTile(
                      shape: mediumShape,
                      leading: Icon(
                        result.hasSynced
                            ? Icons.lyrics_rounded
                            : Icons.text_snippet_outlined,
                        color: result.hasSynced
                            ? theme.colorScheme.primary
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                      title: Text(
                        result.trackName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        [
                          result.artistName,
                          if (result.albumName.isNotEmpty) result.albumName,
                          formatDuration(
                            Duration(seconds: result.durationSeconds.round()),
                          ),
                          if (result.hasSynced) 'synced' else 'plain',
                        ].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () {
                        ref
                            .read(lyricsRepositoryProvider)
                            .applyResult(widget.song, result);
                        ref.invalidate(currentLyricsProvider);
                        Navigator.of(context).pop();
                      },
                    );
                  },
                ),
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
        FilledButton(
          onPressed: () => setState(() => _query = widget.controller.text),
          child: const Text('Search'),
        ),
      ],
    );
  }
}

/// Port of the lyrics field in `EditSongSheet` — paste or hand-write LRC.
Future<void> showLyricsEditor(
  BuildContext context,
  Song song,
  Lyrics? existing,
) {
  final controller = TextEditingController(
    text: existing == null ? '' : toLrc(existing),
  );
  return showDialog<void>(
    context: context,
    builder: (context) => Consumer(
      builder: (context, ref, _) => AlertDialog(
        title: const Text('Edit lyrics'),
        content: SizedBox(
          width: 620,
          height: 520,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Plain text, or LRC with [mm:ss.xx] timestamps for a synced '
                'display.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: TextField(
                  controller: controller,
                  autofocus: true,
                  expands: true,
                  maxLines: null,
                  minLines: null,
                  textAlignVertical: TextAlignVertical.top,
                  style: const TextStyle(fontFamily: 'monospace'),
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    alignLabelWithHint: true,
                    hintText: '[00:12.34]First line…',
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              ref
                  .read(lyricsRepositoryProvider)
                  .saveManual(song, controller.text);
              ref.invalidate(currentLyricsProvider);
              Navigator.of(context).pop();
            },
            child: const Text('Save'),
          ),
        ],
      ),
    ),
  );
}
