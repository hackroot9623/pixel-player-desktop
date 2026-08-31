import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/models.dart';
import '../../data/tags/tag_writer.dart';
import '../../state/providers.dart';
import '../theme/shapes.dart';
import 'album_art.dart';
import 'common.dart';
import 'metadata_search_dialog.dart';

/// Port of `presentation/components/EditSongSheet`.
Future<void> showEditSongSheet(BuildContext context, Song song) =>
    showDialog<void>(
      context: context,
      builder: (context) => EditSongDialog(song: song),
    );

/// Port of `presentation/components/EditMultipleSongsSheet`.
Future<void> showEditMultipleSongsSheet(
  BuildContext context,
  List<Song> songs,
) => showDialog<void>(
  context: context,
  builder: (context) => EditSongDialog(song: songs.first, songs: songs),
);

class EditSongDialog extends ConsumerStatefulWidget {
  const EditSongDialog({super.key, required this.song, this.songs});

  final Song song;

  /// When set, the edit applies to all of them and only the fields the user
  /// actually touches are written.
  final List<Song>? songs;

  @override
  ConsumerState<EditSongDialog> createState() => _EditSongDialogState();
}

class _EditSongDialogState extends ConsumerState<EditSongDialog> {
  late final _title = TextEditingController(text: widget.song.title);
  late final _artist = TextEditingController(text: widget.song.artist);
  late final _album = TextEditingController(text: widget.song.album);
  late final _genre = TextEditingController(text: widget.song.genre ?? '');
  late final _year = TextEditingController(
    text: widget.song.year == 0 ? '' : '${widget.song.year}',
  );
  late final _track = TextEditingController(
    text: widget.song.trackNumber == 0 ? '' : '${widget.song.trackNumber}',
  );
  late final _disc = TextEditingController(
    text: widget.song.discNumber == null ? '' : '${widget.song.discNumber}',
  );

  Uint8List? _newArtwork;
  bool _removeArtwork = false;
  bool _saving = false;
  String? _error;

  List<Song> get _targets => widget.songs ?? [widget.song];
  bool get _isBulk => (widget.songs?.length ?? 1) > 1;

  @override
  void dispose() {
    for (final controller in [
      _title,
      _artist,
      _album,
      _genre,
      _year,
      _track,
      _disc,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  /// Only fields the user changed are written, so a bulk edit does not stamp
  /// one song's title across the whole selection.
  String? _changed(TextEditingController controller, String original) {
    final value = controller.text.trim();
    if (value == original.trim()) return null;
    return value;
  }

  int? _changedInt(TextEditingController controller, int original) {
    final text = controller.text.trim();
    final value = text.isEmpty ? 0 : int.tryParse(text);
    if (value == null || value == original) return null;
    return value;
  }

  TagEdit _buildEdit() => TagEdit(
    // In a bulk edit the per-song fields are off the table entirely.
    title: _isBulk ? null : _changed(_title, widget.song.title),
    trackNumber: _isBulk
        ? null
        : _changedInt(_track, widget.song.trackNumber),
    artist: _changed(_artist, widget.song.artist),
    album: _changed(_album, widget.song.album),
    genre: _changed(_genre, widget.song.genre ?? ''),
    year: _changedInt(_year, widget.song.year),
    discNumber: _changedInt(_disc, widget.song.discNumber ?? 0),
    artwork: _newArtwork,
    removeArtwork: _removeArtwork,
  );

  Future<void> _pickArtwork() async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(
          label: 'Images',
          extensions: ['jpg', 'jpeg', 'png', 'webp'],
        ),
      ],
    );
    if (file == null) return;
    final bytes = await file.readAsBytes();
    setState(() {
      _newArtwork = bytes;
      _removeArtwork = false;
    });
  }

  /// Fills the form from a MusicBrainz match, cover included.
  ///
  /// Only the form: the write still goes through Save, so a wrong pick is undone
  /// by pressing Cancel. Offered for a single song only — in a bulk edit the
  /// title and track number belong to each file, and one song's match must not
  /// be stamped across a selection.
  Future<void> _fetchMetadata() async {
    final choice = await showMetadataSearch(
      context,
      lookup: ref.read(metadataLookupProvider),
      title: _title.text,
      artist: _artist.text,
      album: _album.text,
    );
    if (choice == null || !mounted) return;

    final match = choice.match;
    setState(() {
      _title.text = match.title;
      _artist.text = match.artist;
      if (match.album.isNotEmpty) _album.text = match.album;
      if (match.year != null) _year.text = '${match.year}';
      if (match.trackNumber != null) _track.text = '${match.trackNumber}';
      if (match.discNumber != null) _disc.text = '${match.discNumber}';
      if (choice.artwork != null) {
        _newArtwork = choice.artwork;
        _removeArtwork = false;
      }
    });

    if (choice.artwork == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Tags filled in. No cover was found for that release.'),
        ),
      );
    }
  }

  Future<void> _save() async {
    final edit = _buildEdit();
    if (edit.isEmpty) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });

    final failures = ref.read(tagEditorProvider).apply(_targets, edit);
    ref.read(libraryProvider.notifier).reload();

    if (!mounted) return;
    if (failures.isEmpty) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _saving = false;
      _error = failures.length == 1
          ? failures.values.first
          : '${failures.length} of ${_targets.length} files could not be '
                'written: ${failures.values.toSet().join(', ')}';
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final unwritable = _targets.where((s) => !canWriteTags(s.path)).toList();

    return AlertDialog(
      title: Text(
        _isBulk ? 'Edit ${plural(_targets.length, 'song')}' : 'Edit tags',
      ),
      content: SizedBox(
        width: 620,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (unwritable.isNotEmpty)
                _Warning(
                  // Ogg and Opus have no writer in the metadata package.
                  text: unwritable.length == _targets.length
                      ? 'Tags cannot be written to this format '
                            '(${unwritable.first.mimeType ?? 'unknown'}).'
                      : '${unwritable.length} of the selected files are in a '
                            'format tags cannot be written to; they will be '
                            'skipped.',
                ),
              if (!_isBulk) ...[
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.tonalIcon(
                    onPressed: _saving ? null : _fetchMetadata,
                    icon: const Icon(Icons.travel_explore_rounded, size: 18),
                    label: const Text('Find metadata online'),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _ArtworkPicker(
                      song: widget.song,
                      replacement: _newArtwork,
                      removed: _removeArtwork,
                      onPick: _pickArtwork,
                      onRemove: () => setState(() {
                        _removeArtwork = true;
                        _newArtwork = null;
                      }),
                    ),
                    const SizedBox(width: 20),
                    Expanded(
                      child: Column(
                        children: [
                          _Field(label: 'Title', controller: _title),
                          const SizedBox(height: 12),
                          _Field(label: 'Artist', controller: _artist),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
              ] else
                _Field(label: 'Artist', controller: _artist),
              if (_isBulk) const SizedBox(height: 12),
              _Field(label: 'Album', controller: _album),
              const SizedBox(height: 12),
              Row(
                spacing: 12,
                children: [
                  Expanded(child: _Field(label: 'Genre', controller: _genre)),
                  Expanded(
                    child: _Field(
                      label: 'Year',
                      controller: _year,
                      numeric: true,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                spacing: 12,
                children: [
                  if (!_isBulk)
                    Expanded(
                      child: _Field(
                        label: 'Track number',
                        controller: _track,
                        numeric: true,
                      ),
                    ),
                  Expanded(
                    child: _Field(
                      label: 'Disc number',
                      controller: _disc,
                      numeric: true,
                    ),
                  ),
                ],
              ),
              if (_isBulk) ...[
                const SizedBox(height: 12),
                Text(
                  'Only the fields you change are written. Title and track '
                  'number are per-song, so they are not offered here.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
              const SizedBox(height: 12),
              Text(
                // No setter for it in the metadata package.
                'Album artist is derived from the artist tag and is not '
                'editable yet.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                _Warning(text: _error!, error: true),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving || unwritable.length == _targets.length
              ? null
              : _save,
          child: _saving
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Save'),
        ),
      ],
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({
    required this.label,
    required this.controller,
    this.numeric = false,
  });

  final String label;
  final TextEditingController controller;
  final bool numeric;

  @override
  Widget build(BuildContext context) => TextField(
    controller: controller,
    decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
    keyboardType: numeric ? TextInputType.number : null,
    inputFormatters: numeric
        ? [FilteringTextInputFormatter.digitsOnly]
        : null,
  );
}

class _ArtworkPicker extends StatelessWidget {
  const _ArtworkPicker({
    required this.song,
    required this.replacement,
    required this.removed,
    required this.onPick,
    required this.onRemove,
  });

  final Song song;
  final Uint8List? replacement;
  final bool removed;
  final VoidCallback onPick;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget preview;
    if (removed) {
      preview = Container(
        width: 132,
        height: 132,
        color: scheme.surfaceContainerHighest,
        alignment: Alignment.center,
        child: Icon(Icons.hide_image_rounded, color: scheme.onSurfaceVariant),
      );
    } else if (replacement != null) {
      preview = Image.memory(
        replacement!,
        width: 132,
        height: 132,
        fit: BoxFit.cover,
      );
    } else {
      preview = AlbumArt(path: song.albumArtPath, size: 132, radius: 0);
    }

    return Column(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(shapeMedium),
          child: preview,
        ),
        const SizedBox(height: 6),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextButton(onPressed: onPick, child: const Text('Change')),
            if (!removed && (replacement != null || song.albumArtPath != null))
              TextButton(onPressed: onRemove, child: const Text('Remove')),
          ],
        ),
      ],
    );
  }
}

class _Warning extends StatelessWidget {
  const _Warning({required this.text, this.error = false});

  final String text;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: ShapeDecoration(
        color: error ? scheme.errorContainer : scheme.surfaceContainerHighest,
        shape: smoothCorner(14),
      ),
      child: Row(
        children: [
          Icon(
            error ? Icons.error_outline_rounded : Icons.info_outline_rounded,
            size: 18,
            color: error ? scheme.onErrorContainer : scheme.onSurfaceVariant,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: error ? scheme.onErrorContainer : scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

