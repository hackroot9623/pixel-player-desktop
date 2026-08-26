import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/providers.dart';
import '../components/common.dart';
import '../theme/typography.dart';

/// Port of `presentation/screens/SetupScreen` — first-run folder picking.
class SetupScreen extends ConsumerStatefulWidget {
  const SetupScreen({super.key, required this.onDone});

  final VoidCallback onDone;

  @override
  ConsumerState<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends ConsumerState<SetupScreen> {
  String? _suggested;

  @override
  void initState() {
    super.initState();
    defaultMusicDirectory().then((dir) {
      if (mounted) setState(() => _suggested = dir);
    });
  }

  @override
  Widget build(BuildContext context) {
    final notifier = ref.read(libraryProvider.notifier);
    final library = ref.watch(libraryProvider);
    final folders = notifier.folders;
    final theme = Theme.of(context);

    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ExpressiveTitle('PIXELPLAYER', style: expDisplayLarge,
                    scaleX: expDisplayLargeScaleX),
                const SizedBox(height: 16),
                Text(
                  'Point PixelPlayer at the folders that hold your music and '
                  'it will build your library.',
                  style: theme.textTheme.bodyLarge?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 32),
                if (_suggested != null && folders.isEmpty)
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.lightbulb_outline_rounded),
                      title: Text(_suggested!),
                      subtitle: const Text('Suggested music folder'),
                      trailing: FilledButton(
                        onPressed: () => notifier.addFolder(_suggested!),
                        child: const Text('Use this'),
                      ),
                    ),
                  ),
                for (final folder in folders)
                  ListTile(
                    leading: const Icon(Icons.folder_rounded),
                    title: Text(folder),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline_rounded),
                      onPressed: () => notifier.removeFolder(folder),
                    ),
                  ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    FilledButton.tonalIcon(
                      onPressed: () async {
                        final dir = await getDirectoryPath(
                          confirmButtonText: 'Add folder',
                        );
                        if (dir != null) await notifier.addFolder(dir);
                      },
                      icon: const Icon(Icons.folder_open_rounded),
                      label: const Text('Add folder'),
                    ),
                    const Spacer(),
                    FilledButton.icon(
                      onPressed: folders.isEmpty || library.scanning
                          ? null
                          : widget.onDone,
                      icon: const Icon(Icons.arrow_forward_rounded),
                      label: Text(
                        library.scanning ? 'Scanning…' : 'Start listening',
                      ),
                    ),
                  ],
                ),
                if (library.scanning) ...[
                  const SizedBox(height: 24),
                  LinearProgressIndicator(
                    value: library.scanProgress?.fraction,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    library.scanProgress == null
                        ? 'Looking for audio files…'
                        : '${library.scanProgress!.scanned} of '
                              '${library.scanProgress!.total} files',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
                if (library.error != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    'Scan failed: ${library.error}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ],
                if (!library.scanning && library.songs.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text(
                    'Found ${plural(library.songs.length, 'song')} in '
                    '${plural(library.albums.length, 'album')}.',
                    style: theme.textTheme.bodyMedium,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
