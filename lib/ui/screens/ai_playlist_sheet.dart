import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/ai/ai_client.dart';
import '../../data/models/models.dart';
import '../../state/providers.dart';
import '../components/common.dart';
import '../components/library_widgets.dart';
import '../navigation.dart';

/// Port of `presentation/components/AiPlaylistSheet`.
///
/// Ask in words, get a playlist. The result is shown before anything is saved:
/// a model asked for "rainy Sunday" can come back with something odd, and
/// silently writing that into the library would be worse than showing it.
Future<void> showAiPlaylistSheet(BuildContext context) => showDialog<void>(
  context: context,
  builder: (_) => const Dialog(child: _AiPlaylistSheet()),
);

/// Starting points, so an empty prompt box is not the first thing you meet.
const _suggestions = [
  'Something upbeat for cleaning the flat',
  'Late-night headphone listening',
  'Songs I have not played in a while',
  'A warm-up set that builds slowly',
  'Rainy Sunday afternoon',
];

class _AiPlaylistSheet extends ConsumerStatefulWidget {
  const _AiPlaylistSheet();

  @override
  ConsumerState<_AiPlaylistSheet> createState() => _AiPlaylistSheetState();
}

class _AiPlaylistSheetState extends ConsumerState<_AiPlaylistSheet> {
  final _controller = TextEditingController();
  final _nameController = TextEditingController();

  bool _generating = false;
  List<Song>? _result;
  AiException? _error;

  /// Target length, as the Android sheet has it.
  int _minLength = 15;
  int _maxLength = 25;

  @override
  void dispose() {
    _controller.dispose();
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _generate() async {
    final request = _controller.text.trim();
    if (request.isEmpty) return;

    setState(() {
      _generating = true;
      _error = null;
      _result = null;
    });
    try {
      final songs = await generateAiPlaylist(
        ref,
        request: request,
        minLength: _minLength,
        maxLength: _maxLength,
      );
      if (!mounted) return;
      setState(() {
        _result = songs;
        // A name the user can accept or replace beats making them invent one.
        if (_nameController.text.trim().isEmpty) {
          _nameController.text = request.length > 40
              ? '${request.substring(0, 40)}…'
              : request;
        }
      });
    } on AiException catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  void _save({required bool play}) {
    final songs = _result;
    if (songs == null || songs.isEmpty) return;
    final name = _nameController.text.trim().isEmpty
        ? 'AI playlist'
        : _nameController.text.trim();

    final playlist = ref
        .read(libraryProvider.notifier)
        .createPlaylist(
          name,
          songIds: [for (final song in songs) song.id],
          aiGenerated: true,
        );
    if (play) ref.read(playerProvider).playQueue(songs);

    Navigator.of(context).pop();
    openPlaylist(context, playlist.id);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final configured = ref.watch(aiConfiguredProvider);
    final provider = ref.watch(settingsProvider).aiProvider;

    return SizedBox(
      width: 620,
      height: 680,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.auto_awesome_rounded, color: theme.colorScheme.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Build a playlist',
                    style: theme.textTheme.titleLarge,
                  ),
                ),
                IconButton(
                  tooltip: 'Close',
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Using ${provider.displayName}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),

            if (!configured)
              Expanded(
                child: EmptyState(
                  icon: Icons.key_off_rounded,
                  title: 'No AI provider set up',
                  message:
                      'Add an API key for ${provider.displayName} in settings, '
                      'and this can build playlists from a description.',
                  action: FilledButton.tonal(
                    onPressed: () {
                      Navigator.of(context).pop();
                      openAiSettings(context);
                    },
                    child: const Text('Open AI settings'),
                  ),
                ),
              )
            else ...[
              TextField(
                controller: _controller,
                autofocus: true,
                maxLines: 3,
                minLines: 2,
                decoration: const InputDecoration(
                  labelText: 'What should it sound like?',
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) => _generate(),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final suggestion in _suggestions)
                    ActionChip(
                      label: Text(suggestion),
                      onPressed: _generating
                          ? null
                          : () => setState(() {
                              _controller.text = suggestion;
                            }),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Text('Length', style: theme.textTheme.labelLarge),
                  Expanded(
                    child: RangeSlider(
                      values: RangeValues(
                        _minLength.toDouble(),
                        _maxLength.toDouble(),
                      ),
                      min: 5,
                      max: 60,
                      divisions: 11,
                      labels: RangeLabels('$_minLength', '$_maxLength'),
                      onChanged: _generating
                          ? null
                          : (values) => setState(() {
                              _minLength = values.start.round();
                              _maxLength = values.end.round();
                            }),
                    ),
                  ),
                  Text(
                    '$_minLength–$_maxLength',
                    style: theme.textTheme.labelMedium,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: _generating ? null : _generate,
                icon: _generating
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.auto_awesome_rounded, size: 18),
                label: Text(_generating ? 'Thinking…' : 'Generate'),
              ),
              const SizedBox(height: 16),
              Expanded(child: _body(theme)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _body(ThemeData theme) {
    if (_error != null) return _ErrorCard(error: _error!);

    final result = _result;
    if (result == null) {
      return Center(
        child: Text(
          _generating
              ? 'Picking tracks from your library…'
              : 'Describe a mood, an activity, or a time of day.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _nameController,
                decoration: const InputDecoration(
                  labelText: 'Playlist name',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Text(
              '${result.length} tracks',
              style: theme.textTheme.labelMedium,
            ),
          ],
        ),
        const SizedBox(height: 8),
        Expanded(
          child: ListView.builder(
            itemCount: result.length,
            itemBuilder: (context, index) => SongTile(
              song: result[index],
              leadingIndex: index,
              selectable: false,
              showArtwork: false,
              dense: true,
            ),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          spacing: 8,
          children: [
            TextButton(
              onPressed: _generating ? null : _generate,
              child: const Text('Try again'),
            ),
            OutlinedButton(
              onPressed: () => _save(play: false),
              child: const Text('Save'),
            ),
            FilledButton.icon(
              onPressed: () => _save(play: true),
              icon: const Icon(Icons.play_arrow_rounded, size: 18),
              label: const Text('Save and play'),
            ),
          ],
        ),
      ],
    );
  }
}

/// The provider's own words matter when a key or a model is wrong, so they are
/// kept behind a disclosure rather than thrown away.
class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.error});

  final AiException error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: theme.colorScheme.errorContainer,
          borderRadius: BorderRadius.circular(16),
        ),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.error_outline_rounded,
                  color: theme.colorScheme.onErrorContainer,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    error.message,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onErrorContainer,
                    ),
                  ),
                ),
              ],
            ),
            if (error.detail != null)
              Theme(
                data: theme.copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: Text(
                    'Details',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.onErrorContainer,
                    ),
                  ),
                  children: [
                    SelectableText(
                      error.detail!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onErrorContainer,
                        fontFamily: 'monospace',
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
}
