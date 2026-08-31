import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/remote/drive/google_oauth.dart' show SystemBrowserLauncher;
import '../../data/update/update_check.dart';
import '../../data/update/update_installer.dart';
import '../../state/providers.dart';
import '../navigation.dart';

/// Version, licences, and whether there is a newer build.
///
/// Nothing is downloaded until the button is pressed. When this copy was
/// installed by install.sh the update is applied in place; anything else — a
/// package, a build directory, Windows, macOS — says why not and offers the
/// release page instead.
class AboutScreen extends ConsumerStatefulWidget {
  const AboutScreen({super.key});

  @override
  ConsumerState<AboutScreen> createState() => _AboutScreenState();
}

class _AboutScreenState extends ConsumerState<AboutScreen> {
  UpdateStatus? _status;
  bool _checking = false;

  /// Created here rather than in a provider: it belongs to this screen, and its
  /// progress is nobody else's business.
  late final UpdateInstaller _installer = UpdateInstaller()
    ..addListener(_onInstallerChanged);

  void _onInstallerChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _installer.removeListener(_onInstallerChanged);
    _installer.dispose();
    super.dispose();
  }

  /// Taps on the version. The old trick, and the same count as the phone.
  int _taps = 0;

  Future<void> _check() async {
    setState(() => _checking = true);
    final status = await ref
        .read(updateCheckerProvider)
        .check(currentVersion: ref.read(appVersionProvider));
    if (!mounted) return;
    // Remembered so the settings row can show a badge without asking GitHub
    // again every time it is drawn.
    if (status.latest != null) {
      ref.read(settingsProvider).lastKnownRelease = status.latest!.version;
    }
    setState(() {
      _status = status;
      _checking = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final version = ref.watch(appVersionProvider);
    final settings = ref.watch(settingsProvider);
    final status = _status;

    return Scaffold(
      appBar: AppBar(title: const Text('About')),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: Image.asset(
                      'assets/images/icon.png',
                      width: 72,
                      height: 72,
                    ),
                  ),
                  const SizedBox(width: 20),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('PixelPlayer', style: theme.textTheme.titleLarge),
                        GestureDetector(
                          onTap: () {
                            _taps++;
                            if (_taps < 7) return;
                            _taps = 0;
                            openBrickBreaker(context);
                          },
                          child: Text(
                            'Version $version',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'A desktop port of the PixelPlayer music player.',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          Text('Updates', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: Icon(
                    switch (status) {
                      null => Icons.system_update_rounded,
                      final s when s.error != null => Icons.error_outline_rounded,
                      final s when s.hasUpdate => Icons.new_releases_rounded,
                      final s when s.noReleases => Icons.help_outline_rounded,
                      _ => Icons.check_circle_outline_rounded,
                    },
                    color: status?.hasUpdate == true
                        ? theme.colorScheme.primary
                        : null,
                  ),
                  title: Text(switch (status) {
                    null => 'Check for a newer version',
                    final s when s.error != null => 'Could not check',
                    final s when s.hasUpdate =>
                      'Version ${s.latest!.version} is available',
                    final s when s.noReleases => 'No numbered release yet',
                    _ => 'You are up to date',
                  }),
                  subtitle: Text(switch (status) {
                    null => 'Asks GitHub for the newest release.',
                    final s when s.error != null => s.error!,
                    final s when s.hasUpdate =>
                      'You have $version. Nothing has been downloaded yet.',
                    // The releases page currently carries only the rolling
                    // build from CI, which is not a version to compare against.
                    final s when s.noReleases =>
                      'The releases page has only the rolling build, so there '
                          'is nothing to compare $version against.',
                    _ => 'Version $version is the newest release.',
                  }),
                  trailing: _checking
                      ? const SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : TextButton(
                          onPressed: _check,
                          child: const Text('Check'),
                        ),
                ),
                if (status?.hasUpdate == true)
                  _UpdateActions(
                    release: status!.latest!,
                    installer: _installer,
                    onInstall: () => _installer.install(status.latest!),
                  ),
                SwitchListTile(
                  secondary: const Icon(Icons.update_rounded),
                  title: const Text('Check at startup'),
                  subtitle: const Text(
                    'Off by default — this is the only thing in the app that '
                    'contacts a server you did not configure',
                  ),
                  value: settings.checkForUpdates,
                  onChanged: (value) => settings.checkForUpdates = value,
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          Text('More', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.article_outlined),
                  title: const Text('Open source licences'),
                  subtitle: const Text(
                    'Every package this app is built from, and its licence',
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => showLicensePage(
                    context: context,
                    applicationName: 'PixelPlayer',
                    applicationVersion: version,
                    applicationLegalese:
                        'Licensed under the MIT licence. Plays audio through '
                        'mpv, which is GPL/LGPL — see its own licence.',
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.medical_information_outlined),
                  title: const Text('Diagnostics'),
                  subtitle: const Text(
                    'What this machine has installed, and what the app found',
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => openDiagnostics(context),
                ),
                ListTile(
                  leading: const Icon(Icons.code_rounded),
                  title: const Text('Source'),
                  subtitle: const Text(
                    'github.com/$updateRepository',
                  ),
                  trailing: IconButton(
                    tooltip: 'Copy',
                    icon: const Icon(Icons.copy_rounded),
                    onPressed: () => _copy(
                      context,
                      'https://github.com/$updateRepository',
                      'Link copied',
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The buttons under an available update.
class _UpdateActions extends StatelessWidget {
  const _UpdateActions({
    required this.release,
    required this.installer,
    required this.onInstall,
  });

  final Release release;
  final UpdateInstaller installer;
  final VoidCallback onInstall;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final refusal = installer.refusal;
    final size = assetForPlatform(release, installer.operatingSystem)?.size ?? 0;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (installer.busy) ...[
            LinearProgressIndicator(value: installer.progress),
            const SizedBox(height: 8),
            Text(
              switch (installer.stage) {
                InstallStage.downloading =>
                  'Downloading ${_megabytes(installer.received)}'
                      '${size > 0 ? ' of ${_megabytes(size)}' : ''}…',
                InstallStage.extracting => 'Unpacking…',
                _ => 'Putting it in place…',
              },
              style: theme.textTheme.bodySmall,
            ),
          ] else if (installer.finished) ...[
            Text(
              'Version ${release.version} is installed. Restart to use it.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: installer.restart,
              icon: const Icon(Icons.restart_alt_rounded, size: 18),
              label: const Text('Restart now'),
            ),
          ] else ...[
            if (installer.error case final failure?) ...[
              Text(
                failure,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
              const SizedBox(height: 8),
            ] else if (refusal != null) ...[
              Text(
                refusal,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 8),
            ],
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (refusal == null)
                  FilledButton.icon(
                    onPressed: onInstall,
                    icon: const Icon(Icons.download_rounded, size: 18),
                    label: Text(
                      size > 0
                          ? 'Download and install (${_megabytes(size)})'
                          : 'Download and install',
                    ),
                  ),
                FilledButton.tonalIcon(
                  onPressed: () => _open(context, release.url),
                  icon: const Icon(Icons.open_in_new_rounded, size: 18),
                  label: const Text('Open the release page'),
                ),
                TextButton.icon(
                  onPressed: () =>
                      _copy(context, release.url, 'Release link copied'),
                  icon: const Icon(Icons.link_rounded, size: 18),
                  label: const Text('Copy the link'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

String _megabytes(int bytes) =>
    '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';

Future<void> _open(BuildContext context, String url) async {
  try {
    await const SystemBrowserLauncher().open(url);
  } catch (_) {
    if (context.mounted) {
      await _copy(context, url, 'Could not open a browser — link copied');
    }
  }
}

Future<void> _copy(BuildContext context, String text, String message) async {
  await Clipboard.setData(ClipboardData(text: text));
  if (context.mounted) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}
