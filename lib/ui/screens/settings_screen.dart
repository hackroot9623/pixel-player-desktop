import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/lyrics.dart';
import '../../data/scanner/library_scanner.dart';
import '../../state/providers.dart';
import '../components/common.dart';
import '../components/library_widgets.dart';
import '../navigation.dart';

/// Port of `presentation/screens/SettingsScreen` + `SettingsComponents` +
/// `PaletteStyleSettingsScreen` + `DelimiterConfigScreen`. Phase-2..8 settings
/// screens plug in as further sections here.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final library = ref.watch(libraryProvider);
    final notifier = ref.read(libraryProvider.notifier);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        children: [
          _sectionTitle(context, 'Library'),
          Card(
            child: Column(
              children: [
                for (final folder in notifier.folders)
                  ListTile(
                    leading: const Icon(Icons.folder_rounded),
                    title: Text(folder),
                    trailing: IconButton(
                      tooltip: 'Remove folder',
                      icon: const Icon(Icons.delete_outline_rounded),
                      onPressed: () => notifier.removeFolder(folder),
                    ),
                  ),
                if (notifier.folders.isEmpty)
                  const ListTile(
                    leading: Icon(Icons.info_outline_rounded),
                    title: Text('No music folders added yet'),
                  ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.add_rounded),
                  title: const Text('Add music folder'),
                  onTap: () async {
                    final dir = await getDirectoryPath(
                      confirmButtonText: 'Add folder',
                    );
                    if (dir != null) await notifier.addFolder(dir);
                  },
                ),
                ListTile(
                  leading: library.scanning
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh_rounded),
                  title: Text(
                    library.scanning ? 'Scanning…' : 'Rescan library',
                  ),
                  subtitle: library.scanning
                      ? Text(
                          library.scanProgress == null
                              ? ''
                              : '${library.scanProgress!.scanned} / '
                                    '${library.scanProgress!.total}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        )
                      : Text(plural(library.songs.length, 'song')),
                  onTap: library.scanning ? null : notifier.rescan,
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          _sectionTitle(context, 'Appearance'),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.brightness_6_rounded),
                  title: const Text('Theme'),
                  trailing: SegmentedButton<ThemeMode>(
                    segments: const [
                      ButtonSegment(
                        value: ThemeMode.system,
                        label: Text('System'),
                      ),
                      ButtonSegment(
                        value: ThemeMode.light,
                        label: Text('Light'),
                      ),
                      ButtonSegment(value: ThemeMode.dark, label: Text('Dark')),
                    ],
                    selected: {settings.themeMode},
                    onSelectionChanged: (value) =>
                        settings.themeMode = value.first,
                  ),
                ),
                SwitchListTile(
                  secondary: const Icon(Icons.palette_rounded),
                  title: const Text('Colors from album art'),
                  subtitle: const Text(
                    'Recolor the app from the artwork of the playing track',
                  ),
                  value: settings.useAlbumArtColors,
                  onChanged: (value) => settings.useAlbumArtColors = value,
                ),
                ListTile(
                  leading: const Icon(Icons.colorize_rounded),
                  title: const Text('Accent color'),
                  subtitle: const Text('Used when album art colors are off'),
                  trailing: Wrap(
                    spacing: 8,
                    children: [
                      for (final color in const [
                        Color(0xFF6C4FF5),
                        Color(0xFFAB47BC),
                        Color(0xFFF06292),
                        Color(0xFFFF8A65),
                        Color(0xFF43A047),
                        Color(0xFF1E88E5),
                      ])
                        InkWell(
                          onTap: () => settings.seedColor = color,
                          customBorder: const CircleBorder(),
                          child: Container(
                            width: 28,
                            height: 28,
                            decoration: BoxDecoration(
                              color: color,
                              shape: BoxShape.circle,
                              border: Border.all(
                                width: 3,
                                color:
                                    settings.seedColor.toARGB32() ==
                                        color.toARGB32()
                                    ? theme.colorScheme.onSurface
                                    : Colors.transparent,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.gradient_rounded),
                  title: const Text('Palette style'),
                  subtitle: Text(
                    'How one colour becomes the whole palette · '
                    '${settings.paletteStyle.name}',
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => openPaletteStyle(context),
                ),
                ListTile(
                  leading: const Icon(Icons.rounded_corner_rounded),
                  title: const Text('Navigation corner radius'),
                  subtitle: Text('${settings.navBarCornerRadius.round()} px'),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => openNavCornerRadius(context),
                ),
                ListTile(
                  leading: const Icon(Icons.web_asset_rounded),
                  title: const Text('Window'),
                  subtitle: Text(
                    settings.useCustomTitleBar
                        ? 'Own title bar · buttons on the '
                              '${settings.windowControlsPlacement.label.toLowerCase()}'
                        : 'System title bar',
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => openWindowSettings(context),
                ),
                ListTile(
                  leading: const Icon(Icons.cloud_outlined),
                  title: const Text('Accounts'),
                  subtitle: Text(
                    switch (ref.watch(remoteAccountsProvider).length) {
                      0 => 'Stream from Jellyfin or Navidrome',
                      1 => '1 server',
                      final count => '$count servers',
                    },
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => openAccounts(context),
                ),
                ListTile(
                  leading: const Icon(Icons.tune_rounded),
                  title: const Text('Equalizer'),
                  subtitle: Text(
                    switch (ref.watch(equalizerProvider)) {
                      final eq when !eq.enabled => 'Off',
                      final eq when eq.isNeutral => 'On · flat',
                      final eq => 'On · ${eq.preset?.label ?? 'Custom'}',
                    },
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => openEqualizer(context),
                ),
                ListTile(
                  leading: const Icon(Icons.auto_awesome_rounded),
                  title: const Text('AI'),
                  subtitle: Text(
                    ref.watch(aiConfiguredProvider)
                        ? '${settings.aiProvider.displayName} · ready'
                        : 'Not set up',
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => openAiSettings(context),
                ),
                ListTile(
                  leading: const Icon(Icons.play_circle_outline_rounded),
                  title: const Text('Player look'),
                  subtitle: Text(
                    'Artwork carousel · ${settings.carouselStyle.label}',
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => openPlayerLook(context),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          _sectionTitle(context, 'Metadata'),
          Card(
            child: Column(
              children: [
                SwitchListTile(
                  secondary: const Icon(Icons.people_rounded),
                  title: const Text('Split multiple artists'),
                  subtitle: const Text(
                    'Treat "A feat. B" as two artists when scanning',
                  ),
                  value: settings.multiArtistEnabled,
                  onChanged: (value) {
                    settings.multiArtistEnabled = value;
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.text_fields_rounded),
                  title: const Text('Artist delimiters'),
                  subtitle: Text(
                    settings.artistDelimiters
                        .map((d) => '"$d"')
                        .join(', '),
                  ),
                  trailing: Wrap(
                    spacing: 4,
                    children: [
                      IconButton(
                        tooltip: 'Add delimiter',
                        icon: const Icon(Icons.add_rounded),
                        onPressed: () async {
                          final value = await promptForText(
                            context,
                            title: 'Add delimiter',
                            hint: 'e.g. " & "',
                          );
                          if (value == null || value.isEmpty) return;
                          settings.artistDelimiters = [
                            ...settings.artistDelimiters,
                            value,
                          ];
                        },
                      ),
                      IconButton(
                        tooltip: 'Reset to defaults',
                        icon: const Icon(Icons.restart_alt_rounded),
                        onPressed: () =>
                            settings.artistDelimiters = defaultArtistDelimiters,
                      ),
                    ],
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.info_outline_rounded),
                  title: const Text('Rescan needed'),
                  subtitle: const Text(
                    'Metadata changes apply on the next library scan',
                  ),
                  trailing: FilledButton.tonal(
                    onPressed: library.scanning ? null : notifier.rescan,
                    child: const Text('Rescan now'),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          _sectionTitle(context, 'Playback'),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.blur_on_rounded),
                  title: const Text('Transitions'),
                  subtitle: Text(
                    settings.transition.enabled
                        ? '${settings.transition.mode.label} · '
                              '${(settings.transition.durationMs / 1000).toStringAsFixed(1)} s'
                        : 'Off (gapless)',
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => openTransitionEditor(context),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          _sectionTitle(context, 'Lyrics'),
          Card(
            child: Column(
              children: [
                SwitchListTile(
                  secondary: const Icon(Icons.cloud_download_rounded),
                  title: const Text('Fetch lyrics automatically'),
                  subtitle: const Text(
                    'Look tracks up on LRCLIB when nothing local is found',
                  ),
                  value: settings.autoFetchLyrics,
                  onChanged: (value) => settings.autoFetchLyrics = value,
                ),
                ListTile(
                  leading: const Icon(Icons.low_priority_rounded),
                  title: const Text('Source priority'),
                  subtitle: Text(settings.lyricsSource.label),
                  trailing: DropdownButton<LyricsSourcePreference>(
                    value: settings.lyricsSource,
                    underline: const SizedBox.shrink(),
                    items: [
                      for (final option in LyricsSourcePreference.values)
                        DropdownMenuItem(
                          value: option,
                          child: Text(option.label),
                        ),
                    ],
                    onChanged: (value) {
                      if (value != null) settings.lyricsSource = value;
                    },
                  ),
                ),
                const ListTile(
                  leading: Icon(Icons.info_outline_rounded),
                  title: Text('Local .lrc files'),
                  subtitle: Text(
                    'A .lrc or .txt file named like the track, in the same '
                    'folder, is picked up automatically',
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          _sectionTitle(context, 'About'),
          Card(
            child: Column(
              children: [
                const ListTile(
                  leading: Icon(Icons.info_rounded),
                  title: Text('PixelPlayer Desktop'),
                  subtitle: Text(
                    'Flutter port of PixelPlayer for Linux, Windows and macOS',
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.speaker_rounded),
                  title: const Text('Audio engine'),
                  subtitle: const Text('media_kit / libmpv'),
                  trailing: Text(
                    'sqlite + Material 3',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _sectionTitle(BuildContext context, String title) => Padding(
    padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
    child: Text(
      title,
      style: Theme.of(context).textTheme.titleSmall?.copyWith(
        color: Theme.of(context).colorScheme.primary,
      ),
    ),
  );
}
