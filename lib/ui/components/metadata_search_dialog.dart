import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../data/metadata/metadata_lookup.dart';

/// What the user picked: the match, and its cover if one was found.
typedef MetadataChoice = ({MetadataMatch match, Uint8List? artwork});

/// Searches MusicBrainz and lets the user pick a match.
///
/// Returns null when they close it. Nothing is written here — the choice goes
/// back to the edit sheet, which fills the fields and waits for Save, so a wrong
/// pick costs a glance rather than a rewritten file.
Future<MetadataChoice?> showMetadataSearch(
  BuildContext context, {
  required MetadataLookup lookup,
  required String title,
  String artist = '',
  String album = '',
}) => showDialog<MetadataChoice>(
  context: context,
  builder: (context) => _MetadataSearchDialog(
    lookup: lookup,
    title: title,
    artist: artist,
    album: album,
  ),
);

class _MetadataSearchDialog extends StatefulWidget {
  const _MetadataSearchDialog({
    required this.lookup,
    required this.title,
    required this.artist,
    required this.album,
  });

  final MetadataLookup lookup;
  final String title;
  final String artist;
  final String album;

  @override
  State<_MetadataSearchDialog> createState() => _MetadataSearchDialogState();
}

class _MetadataSearchDialogState extends State<_MetadataSearchDialog> {
  late final _title = TextEditingController(text: widget.title);
  late final _artist = TextEditingController(text: widget.artist);
  late final _album = TextEditingController(text: widget.album);

  List<MetadataMatch>? _results;
  bool _searching = false;

  /// The row whose cover is being downloaded, so only that one shows a spinner.
  MetadataMatch? _fetching;
  String? _error;

  @override
  void initState() {
    super.initState();
    // The tags are usually right enough to search with, so save the click.
    if (widget.title.trim().isNotEmpty) _search();
  }

  @override
  void dispose() {
    for (final controller in [_title, _artist, _album]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _search() async {
    if (_searching) return;
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      final results = await widget.lookup.searchSongs(
        title: _title.text,
        artist: _artist.text,
        album: _album.text,
      );
      if (!mounted) return;
      setState(() {
        _results = results;
        _searching = false;
      });
    } on MetadataLookupException catch (failure) {
      if (!mounted) return;
      setState(() {
        _error = failure.message;
        _searching = false;
      });
    }
  }

  /// Takes the match, with its cover if the archive or Deezer has one.
  Future<void> _use(MetadataMatch match) async {
    setState(() => _fetching = match);
    final artwork = await widget.lookup.cover(match);
    if (!mounted) return;
    Navigator.of(context).pop((match: match, artwork: artwork));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final results = _results;

    return AlertDialog(
      title: const Text('Find metadata'),
      content: SizedBox(
        width: 640,
        height: 520,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              spacing: 12,
              children: [
                Expanded(child: _field('Title', _title)),
                Expanded(child: _field('Artist', _artist)),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              spacing: 12,
              children: [
                Expanded(child: _field('Album (optional)', _album)),
                FilledButton.icon(
                  onPressed: _searching ? null : _search,
                  icon: const Icon(Icons.search_rounded, size: 18),
                  label: const Text('Search'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'MusicBrainz for the words, the Cover Art Archive for the '
              'picture, Deezer when the archive has none. Nothing is written '
              'until you press Save.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const Divider(height: 24),
            Expanded(
              child: switch ((_searching, _error, results)) {
                (true, _, _) => const Center(child: CircularProgressIndicator()),
                (_, final String error, _) => Center(
                  child: Text(
                    error,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ),
                (_, _, null) => Center(
                  child: Text(
                    'Search to see what MusicBrainz knows.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                (_, _, final List<MetadataMatch> found) when found.isEmpty =>
                  Center(
                    child: Text(
                      'Nothing matched. Try fewer words, or drop the album.',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                (_, _, final List<MetadataMatch> found) => ListView.separated(
                  itemCount: found.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final match = found[index];
                    final busy = _fetching == match;
                    return ListTile(
                      title: Text('${match.title} — ${match.artist}'),
                      subtitle: Text(
                        match.summary.isEmpty
                            ? 'No release information'
                            : match.summary,
                      ),
                      trailing: busy
                          ? const SizedBox.square(
                              dimension: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : TextButton(
                              onPressed: _fetching == null
                                  ? () => _use(match)
                                  : null,
                              child: const Text('Use'),
                            ),
                      // MusicBrainz's confidence, shown because a low one is
                      // usually a sign the search terms need work.
                      leading: _Score(match.score),
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
          child: const Text('Cancel'),
        ),
      ],
    );
  }

  Widget _field(String label, TextEditingController controller) => TextField(
    controller: controller,
    decoration: InputDecoration(labelText: label, isDense: true),
    onSubmitted: (_) => _search(),
  );
}

class _Score extends StatelessWidget {
  const _Score(this.score);

  final int score;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: 40,
      child: Text(
        '$score',
        textAlign: TextAlign.center,
        style: theme.textTheme.labelLarge?.copyWith(
          color: score >= 90
              ? theme.colorScheme.primary
              : theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
