import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../data/diagnostics/diagnostics.dart';
import '../../state/providers.dart';

/// What is installed, what the app found, and what the library holds.
///
/// Every remote source here depends on something the user supplies — yt-dlp,
/// TDLib, a session bus — so "why does this not work" is usually answered by this
/// one list. Copyable, because the point is pasting it into a bug report.
class DiagnosticsScreen extends ConsumerStatefulWidget {
  const DiagnosticsScreen({super.key});

  @override
  ConsumerState<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends ConsumerState<DiagnosticsScreen> {
  List<DiagnosticsSection>? _sections;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _collect());
  }

  Future<void> _collect() async {
    final artworkDir = ref.read(artworkDirProvider);
    final supportDir = p.dirname(artworkDir);
    final db = ref.read(databaseProvider);
    final settings = ref.read(settingsProvider);

    final environment = await collectEnvironment(
      appVersion: ref.read(appVersionProvider),
      mpvVersion: await ref.read(playerProvider).mpvVersion(),
      equalizerFilter: settings.equalizer.filter,
      paths: {
        'App data': supportDir,
        'Artwork cache': artworkDir,
        'Database': p.join(supportDir, 'pixelplay.db'),
      },
    );

    if (!mounted) return;
    setState(() {
      _sections = [
        ...environment,
        DiagnosticsSection('Library', [
          Diagnostic('Songs', '${db.songCount()}'),
          Diagnostic('Albums', '${db.allAlbums().length}'),
          Diagnostic('Artists', '${db.allArtists().length}'),
          Diagnostic('Playlists', '${db.allPlaylists().length}'),
          Diagnostic('Favourites', '${db.favoriteSongs().length}'),
          Diagnostic(
            'Music folders',
            db.allFolders().isEmpty
                ? 'none — the library will be empty'
                : db.allFolders().join(', '),
            ok: db.allFolders().isNotEmpty,
          ),
          Diagnostic('Total plays', '${db.totalPlays()}'),
          Diagnostic(
            'Listened',
            '${Duration(milliseconds: db.totalListenedMs()).inHours} hours',
          ),
        ]),
        DiagnosticsSection('Remote sources', [
          Diagnostic(
            'Accounts',
            settings.remoteAccounts.isEmpty
                ? 'none'
                : settings.remoteAccounts
                      .map((a) => '${a.kind.label}${a.host.isEmpty ? '' : ' '
                            '(${a.host})'}')
                      .join(', '),
          ),
          Diagnostic(
            'Active source',
            ref.read(activeAccountProvider)?.title ?? 'local library',
          ),
        ]),
      ];
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sections = _sections;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Diagnostics'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: () {
              setState(() => _sections = null);
              _collect();
            },
          ),
          IconButton(
            tooltip: 'Copy the whole report',
            icon: const Icon(Icons.copy_all_rounded),
            onPressed: sections == null
                ? null
                : () async {
                    await Clipboard.setData(
                      ClipboardData(text: formatDiagnostics(sections)),
                    );
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Report copied')),
                      );
                    }
                  },
          ),
        ],
      ),
      body: sections == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              children: [
                for (final section in sections) ...[
                  Text(section.title, style: theme.textTheme.titleSmall),
                  const SizedBox(height: 8),
                  Card(
                    child: Column(
                      children: [
                        for (final entry in section.entries)
                          ListTile(
                            dense: true,
                            leading: Icon(
                              switch (entry.ok) {
                                true => Icons.check_circle_outline_rounded,
                                false => Icons.error_outline_rounded,
                                null => Icons.info_outline_rounded,
                              },
                              size: 18,
                              color: switch (entry.ok) {
                                true => theme.colorScheme.primary,
                                false => theme.colorScheme.error,
                                null => theme.colorScheme.onSurfaceVariant,
                              },
                            ),
                            title: Text(
                              entry.label,
                              style: theme.textTheme.bodyMedium,
                            ),
                            subtitle: SelectableText(
                              entry.value,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
              ],
            ),
    );
  }
}
