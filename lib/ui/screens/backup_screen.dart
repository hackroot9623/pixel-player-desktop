import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/backup/backup_format.dart';
import '../../state/providers.dart';

/// Writes a backup file and reads one back.
///
/// Section by section, in both directions: the usual reason to open a backup is
/// to get one thing out of it — a playlist, the favourites — not to roll the
/// whole app back to an old state.
class BackupScreen extends ConsumerStatefulWidget {
  const BackupScreen({super.key});

  @override
  ConsumerState<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends ConsumerState<BackupScreen> {
  final _selected = {...BackupSection.values};
  bool _busy = false;
  String? _message;
  String? _error;

  Future<void> _export() async {
    final location = await getSaveLocation(
      suggestedName: 'pixelplayer-backup-'
          '${DateTime.now().toIso8601String().split('T').first}.json',
      acceptedTypeGroups: const [
        XTypeGroup(label: 'PixelPlayer backup', extensions: ['json']),
      ],
    );
    if (location == null) return;

    setState(() {
      _busy = true;
      _error = null;
      _message = null;
    });
    try {
      final file = ref
          .read(backupServiceProvider)
          .build(sections: _selected, appVersion: ref.read(appVersionProvider));
      await File(location.path).writeAsString(file.encode());
      if (!mounted) return;
      setState(
        () => _message =
            'Saved ${file.sections.length} sections to ${location.path}',
      );
    } catch (error) {
      if (mounted) setState(() => _error = 'Could not write the backup: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _import() async {
    final picked = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: 'PixelPlayer backup', extensions: ['json']),
      ],
    );
    if (picked == null) return;

    setState(() {
      _busy = true;
      _error = null;
      _message = null;
    });
    try {
      final file = BackupFile.decode(await File(picked.path).readAsString());
      if (!mounted) return;

      // Only the sections the file actually has, intersected with what the user
      // ticked — offering to restore something that is not in there is a lie.
      final available = file.sections.toSet();
      final wanted = _selected.intersection(available);
      if (wanted.isEmpty) {
        setState(() {
          _error = available.isEmpty
              ? 'That backup has nothing this version can read.'
              : 'That backup holds: '
                    '${available.map((s) => s.label).join(', ')}. '
                    'None of those are ticked above.';
        });
        return;
      }

      final confirmed = await _confirm(file, wanted);
      if (confirmed != true || !mounted) return;

      final report = await ref
          .read(backupServiceProvider)
          .apply(file, sections: wanted);
      // The library screens hold their own copy, so they have to be told the
      // database changed underneath them.
      ref.read(libraryProvider.notifier).reload();
      if (mounted) await _showReport(report);
    } on BackupException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (error) {
      if (mounted) setState(() => _error = 'Could not read that file: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool?> _confirm(BackupFile file, Set<BackupSection> sections) =>
      showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Restore from this backup?'),
          content: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Written ${_when(file.createdAt)} by PixelPlayer '
                '${file.appVersion} on ${file.platform}.',
              ),
              const SizedBox(height: 12),
              Text('Restoring: ${sections.map((s) => s.label).join(', ')}.'),
              const SizedBox(height: 12),
              const Text(
                'Nothing is deleted. Playlists you already have keep their '
                'songs and gain the backup\'s; anything the backup mentions '
                'that is not in your library is reported and skipped.',
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Restore'),
            ),
          ],
        ),
      );

  Future<void> _showReport(RestoreReport report) => showDialog<void>(
    context: context,
    builder: (context) {
      final theme = Theme.of(context);
      return AlertDialog(
        title: Text(
          report.anythingRestored ? 'Restored' : 'Nothing was restored',
        ),
        content: SizedBox(
          width: 420,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final entry in report.restored.entries)
                if (entry.value > 0)
                  Text(
                    '${entry.key.label}: ${entry.value}'
                    '${report.skipped[entry.key] != null ? ', '
                          '${report.skipped[entry.key]} skipped' : ''}',
                  ),
              if (report.totalSkipped > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    '${report.totalSkipped} entries were skipped — usually '
                    'tracks the backup mentions that are not in this library, '
                    'or history already present.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              for (final failure in report.failures)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    failure,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Done'),
          ),
        ],
      );
    },
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Backup')),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('What a backup holds', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 8),
                  Text(
                    'A single JSON file with the parts of the app that are '
                    'yours: playlists, favourites, lyrics, listening history, '
                    'settings. Not the music itself, and never a password, an '
                    'API key or a sign-in token — a backup is a file people '
                    'email to themselves.\n\n'
                    'Songs are recorded by path and by their tags, so a backup '
                    'restored on another machine still finds most of your '
                    'library even if the music lives somewhere else.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Sections', style: theme.textTheme.titleSmall),
              TextButton(
                onPressed: () => setState(() {
                  if (_selected.length == BackupSection.values.length) {
                    _selected.clear();
                  } else {
                    _selected.addAll(BackupSection.values);
                  }
                }),
                child: Text(
                  _selected.length == BackupSection.values.length
                      ? 'Select none'
                      : 'Select all',
                ),
              ),
            ],
          ),
          Card(
            child: Column(
              children: [
                for (final section in BackupSection.values)
                  CheckboxListTile(
                    title: Text(section.label),
                    subtitle: Text(section.description),
                    value: _selected.contains(section),
                    onChanged: _busy
                        ? null
                        : (value) => setState(() {
                            if (value == true) {
                              _selected.add(section);
                            } else {
                              _selected.remove(section);
                            }
                          }),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          Row(
            children: [
              FilledButton.icon(
                onPressed: _busy || _selected.isEmpty ? null : _export,
                icon: const Icon(Icons.save_alt_rounded, size: 18),
                label: const Text('Save a backup'),
              ),
              const SizedBox(width: 12),
              FilledButton.tonalIcon(
                onPressed: _busy || _selected.isEmpty ? null : _import,
                icon: const Icon(Icons.restore_rounded, size: 18),
                label: const Text('Restore from a file'),
              ),
              if (_busy)
                const Padding(
                  padding: EdgeInsets.only(left: 16),
                  child: SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
            ],
          ),

          if (_message != null)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Card(
                color: theme.colorScheme.secondaryContainer,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    _message!,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSecondaryContainer,
                    ),
                  ),
                ),
              ),
            ),

          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Card(
                color: theme.colorScheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    _error!,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onErrorContainer,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

String _when(DateTime time) {
  if (time.millisecondsSinceEpoch == 0) return 'at an unknown time';
  return '${time.year}-${_two(time.month)}-${_two(time.day)} '
      '${_two(time.hour)}:${_two(time.minute)}';
}

String _two(int value) => value.toString().padLeft(2, '0');
