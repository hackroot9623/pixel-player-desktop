import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../data/download/download_controller.dart';
import '../../data/download/spotdl_client.dart';
import '../../data/remote/remote_account.dart';
import '../../data/remote/youtube/youtube_source.dart';
import '../../state/providers.dart';

/// Downloads a Spotify playlist as files, by driving spotdl.
///
/// Honest about what it is: the tags come from Spotify, the audio comes from
/// YouTube. The screen says so, because a track that turns out to be a live
/// version is a matching artefact, not a bug in the file.
class DownloadScreen extends ConsumerStatefulWidget {
  const DownloadScreen({super.key});

  @override
  ConsumerState<DownloadScreen> createState() => _DownloadScreenState();
}

class _DownloadScreenState extends ConsumerState<DownloadScreen> {
  final _url = TextEditingController();
  final _folder = TextEditingController();
  final _cookies = TextEditingController();

  DownloadFormat _format = DownloadFormat.mp3;
  String _bitrate = 'auto';
  bool _overwrite = false;

  @override
  void initState() {
    super.initState();
    final controller = ref.read(downloadControllerProvider);
    if (!controller.probed) controller.probe();

    // Default inside a scanned folder, so what lands there joins the library on
    // the rescan that follows.
    final roots = ref.read(settingsProvider).musicFolders;
    _folder.text = roots.isEmpty
        ? p.join(_home, 'Music', 'PixelPlayer Downloads')
        : p.join(roots.first, 'PixelPlayer Downloads');

    // Downloads hit the same bot wall as playback, so reuse whatever cookies
    // the YouTube source was already given.
    for (final account in ref.read(settingsProvider).remoteAccounts) {
      if (account.kind != RemoteKind.youtube) continue;
      final file = youtubeCookiesFile(account);
      if (file != null && file.isNotEmpty) {
        _cookies.text = file;
        break;
      }
    }
  }

  /// The user's home, for the default download folder when no music folder has
  /// been configured yet.
  static String get _home =>
      Platform.environment['HOME'] ??
      Platform.environment['USERPROFILE'] ??
      '.';

  @override
  void dispose() {
    _url.dispose();
    _folder.dispose();
    _cookies.dispose();
    super.dispose();
  }

  Future<void> _pickFolder() async {
    final picked = await getDirectoryPath(
      initialDirectory: _folder.text,
      confirmButtonText: 'Download here',
    );
    if (picked != null) setState(() => _folder.text = picked);
  }

  Future<void> _start() async {
    await ref.read(downloadControllerProvider).start(
      url: _url.text,
      outputDirectory: _folder.text.trim(),
      format: _format,
      bitrate: _bitrate,
      cookiesFile: _cookies.text.trim().isEmpty ? null : _cookies.text.trim(),
      overwriteExisting: _overwrite,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final download = ref.watch(downloadControllerProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Download from Spotify')),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('What this does', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 8),
                  Text(
                    'Nothing decrypts Spotify — its audio is protected and is '
                    'not touched. What happens is that the playlist\'s '
                    'metadata is read from Spotify, each track is found on '
                    'YouTube, downloaded and tagged with the Spotify details '
                    'and cover art.\n\n'
                    'So the tags are exact and the audio is a match, not the '
                    'original master. Expect the occasional live take or remix '
                    'where the match went wrong, and quality below Spotify\'s '
                    '320 kbps — YouTube music audio is usually around 128 to '
                    '160.\n\n'
                    'Downloading copyrighted tracks is likely infringement '
                    'where you live, and it is against YouTube\'s terms. Your '
                    'machine, your call.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          if (!download.probed)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (!download.available)
            _MissingSpotdl(onRecheck: () => download.probe())
          else ...[
            Card(
              child: ListTile(
                leading: Icon(
                  Icons.check_circle_outline_rounded,
                  color: theme.colorScheme.primary,
                ),
                title: Text('spotdl ${download.version}'),
                subtitle: const Text('Installed and ready'),
                trailing: TextButton(
                  onPressed: download.running ? null : download.probe,
                  child: const Text('Re-check'),
                ),
              ),
            ),
            const SizedBox(height: 16),

            TextField(
              controller: _url,
              enabled: !download.running,
              decoration: const InputDecoration(
                labelText: 'Spotify link',
                hintText: 'https://open.spotify.com/playlist/…',
                helperText:
                    'A playlist, album, artist or track. Public links only — '
                    'this never signs in to your account.',
                helperMaxLines: 2,
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => download.running ? null : _start(),
            ),
            const SizedBox(height: 12),

            TextField(
              controller: _folder,
              enabled: !download.running,
              decoration: InputDecoration(
                labelText: 'Save to',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  tooltip: 'Choose a folder',
                  icon: const Icon(Icons.folder_open_rounded),
                  onPressed: download.running ? null : _pickFolder,
                ),
                helperText:
                    'Inside one of your music folders, so the library picks it '
                    'up automatically.',
                helperMaxLines: 2,
              ),
            ),
            const SizedBox(height: 12),

            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<DownloadFormat>(
                    initialValue: _format,
                    decoration: const InputDecoration(
                      labelText: 'Format',
                      border: OutlineInputBorder(),
                    ),
                    items: [
                      for (final format in DownloadFormat.values)
                        DropdownMenuItem(
                          value: format,
                          child: Text(format.label),
                        ),
                    ],
                    onChanged: download.running
                        ? null
                        : (value) => setState(
                            () => _format = value ?? DownloadFormat.mp3,
                          ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _bitrate,
                    decoration: const InputDecoration(
                      labelText: 'Bitrate',
                      border: OutlineInputBorder(),
                    ),
                    items: const [
                      DropdownMenuItem(value: 'auto', child: Text('Auto')),
                      DropdownMenuItem(value: '128k', child: Text('128 kbps')),
                      DropdownMenuItem(value: '192k', child: Text('192 kbps')),
                      DropdownMenuItem(value: '320k', child: Text('320 kbps')),
                    ],
                    onChanged: download.running
                        ? null
                        : (value) => setState(() => _bitrate = value ?? 'auto'),
                  ),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                _format.note,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(height: 12),

            TextField(
              controller: _cookies,
              enabled: !download.running,
              decoration: const InputDecoration(
                labelText: 'Cookies file (usually required)',
                border: OutlineInputBorder(),
                helperText:
                    'YouTube refuses most downloads without one — the same '
                    'cookies.txt the YouTube Music source uses.',
                helperMaxLines: 2,
              ),
            ),
            const SizedBox(height: 8),

            CheckboxListTile(
              value: _overwrite,
              onChanged: download.running
                  ? null
                  : (value) => setState(() => _overwrite = value ?? false),
              title: const Text('Re-download files that already exist'),
              subtitle: const Text(
                'Off means a second run only fetches what the playlist gained',
              ),
            ),
            const SizedBox(height: 8),

            Row(
              children: [
                FilledButton.icon(
                  onPressed: download.running ? null : _start,
                  icon: const Icon(Icons.download_rounded, size: 18),
                  label: const Text('Download'),
                ),
                const SizedBox(width: 12),
                if (download.running)
                  FilledButton.tonalIcon(
                    onPressed: download.cancel,
                    icon: const Icon(Icons.stop_rounded, size: 18),
                    label: const Text('Stop'),
                  ),
              ],
            ),

            if (download.error != null)
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Card(
                  color: theme.colorScheme.errorContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      download.error!,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onErrorContainer,
                      ),
                    ),
                  ),
                ),
              ),

            if (download.running || download.handled > 0)
              _Progress(download: download),
          ],
        ],
      ),
    );
  }
}

class _MissingSpotdl extends StatelessWidget {
  const _MissingSpotdl({required this.onRecheck});

  final VoidCallback onRecheck;

  static const _install = 'pipx install spotdl';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      color: theme.colorScheme.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.extension_off_rounded,
                  color: theme.colorScheme.error,
                ),
                const SizedBox(width: 12),
                Text('spotdl is not installed', style: theme.textTheme.titleSmall),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'PixelPlayer does not bundle it, the same way it does not bundle '
              'yt-dlp: it changes often, and keeping it current is your package '
              'manager\'s job rather than a PixelPlayer release.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            Card(
              margin: EdgeInsets.zero,
              color: theme.colorScheme.surfaceContainerHighest,
              child: ListTile(
                dense: true,
                title: Text(_install, style: theme.textTheme.bodyMedium),
                subtitle: const Text('Also needs ffmpeg, which you have'),
                trailing: IconButton(
                  tooltip: 'Copy',
                  icon: const Icon(Icons.copy_rounded),
                  onPressed: () async {
                    await Clipboard.setData(
                      const ClipboardData(text: _install),
                    );
                  },
                ),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.tonal(
              onPressed: onRecheck,
              child: const Text('Check again'),
            ),
          ],
        ),
      ),
    );
  }
}

class _Progress extends StatelessWidget {
  const _Progress({required this.download});

  final DownloadController download;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                switch ((download.running, download.cancelled)) {
                  (true, _) when download.total > 0 =>
                    'Downloading ${download.handled} of ${download.total}'
                        '${download.playlistName.isEmpty ? '' : ' · '
                              '${download.playlistName}'}',
                  (true, _) => 'Reading the playlist…',
                  (false, true) => 'Stopped',
                  (false, false) => 'Finished',
                },
                style: theme.textTheme.titleSmall,
              ),
              const SizedBox(height: 12),
              LinearProgressIndicator(value: download.progress),
              const SizedBox(height: 12),
              Wrap(
                spacing: 16,
                children: [
                  Text('${download.downloaded.length} downloaded'),
                  if (download.skipped.isNotEmpty)
                    Text('${download.skipped.length} already there'),
                  if (download.failed.isNotEmpty)
                    Text(
                      '${download.failed.length} failed',
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                ],
              ),

              if (download.failed.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text('Could not download', style: theme.textTheme.titleSmall),
                const SizedBox(height: 4),
                for (final failure in download.failed.take(20))
                  Text(
                    failure.track.isEmpty
                        ? failure.error
                        : '${failure.track} — ${failure.error}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
              ],

              if (download.log.isNotEmpty)
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: Text(
                    'spotdl output',
                    style: theme.textTheme.bodyMedium,
                  ),
                  subtitle: Text(
                    'Everything it said, in case a flag or a message changed',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  children: [
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 220),
                      child: ListView(
                        reverse: true,
                        children: [
                          for (final line in download.log.reversed)
                            SelectableText(
                              line,
                              style: theme.textTheme.bodySmall?.copyWith(
                                fontFamily: 'monospace',
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}
