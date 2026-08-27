import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/remote/spotify/spotify_api.dart';
import '../../data/remote/spotify/spotify_auth.dart';
import '../../data/remote/spotify/spotify_match.dart';
import '../../state/providers.dart';
import '../components/common.dart';
import '../navigation.dart';

/// Imports Spotify playlists as local playlists.
///
/// Not a source in the selector, and deliberately so: Spotify never hands over
/// audio, so nothing here can be played from Spotify. What this does is read
/// what is *in* a playlist and pair each track with a file already in the
/// library.
class SpotifyImportScreen extends ConsumerStatefulWidget {
  const SpotifyImportScreen({super.key});

  @override
  ConsumerState<SpotifyImportScreen> createState() =>
      _SpotifyImportScreenState();
}

class _SpotifyImportScreenState extends ConsumerState<SpotifyImportScreen> {
  final _clientId = TextEditingController();

  bool _busy = false;
  String? _error;
  String? _importing;

  @override
  void initState() {
    super.initState();
    _clientId.text = ref.read(settingsProvider).spotifyClientId;
  }

  @override
  void dispose() {
    _clientId.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    ref.read(settingsProvider).spotifyClientId = _clientId.text;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await connectSpotify(ref);
    } on SpotifyAuthException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _import({
    required String id,
    required String name,
    bool saved = false,
  }) async {
    setState(() {
      _importing = id;
      _error = null;
    });
    try {
      final result = await importSpotifyPlaylist(
        ref,
        playlistId: id,
        playlistName: name,
        savedTracks: saved,
      );
      if (mounted) await _showResult(result);
    } on SpotifyAuthException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _importing = null);
    }
  }

  Future<void> _showResult(SpotifyImportResult result) => showDialog<void>(
    context: context,
    builder: (context) => _ResultDialog(result: result),
  );

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final theme = Theme.of(context);
    final connected = settings.spotifyConnected;
    final redirect = ref.watch(spotifyAuthProvider).redirectUri;

    return Scaffold(
      appBar: AppBar(title: const Text('Spotify')),
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
                    'Spotify does not let any app outside its own players get '
                    'at the audio, so this cannot play Spotify tracks. What it '
                    'can do is read your playlists and find each track in your '
                    'local library, saving the result as a playlist here.\n\n'
                    'Tracks you do not own are reported as missing rather than '
                    'added, so a playlist never contains rows that will not '
                    'play.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          if (!connected) ...[
            Text('1 · Your Spotify app', style: theme.textTheme.titleSmall),
            Text(
              'Spotify issues credentials per application, so PixelPlayer '
              'cannot ship one. Create an app at developer.spotify.com, add the '
              'redirect URI below to it, and paste its client ID here.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            // The redirect URI has to match byte for byte, so it is offered to
            // copy rather than typed out.
            Card(
              color: theme.colorScheme.surfaceContainerHigh,
              child: ListTile(
                dense: true,
                title: Text(redirect, style: theme.textTheme.bodyMedium),
                subtitle: const Text('Redirect URI — add exactly this'),
                trailing: IconButton(
                  tooltip: 'Copy',
                  icon: const Icon(Icons.copy_rounded),
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: redirect));
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Redirect URI copied')),
                      );
                    }
                  },
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _clientId,
              decoration: const InputDecoration(
                labelText: 'Client ID',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => _connect(),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _busy ? null : _connect,
              icon: _busy
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.open_in_browser_rounded, size: 18),
              label: Text(
                _busy ? 'Waiting for your browser…' : 'Connect with Spotify',
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Your browser opens for you to approve read-only access. '
                'PixelPlayer never sees your Spotify password.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ] else ...[
            Card(
              child: ListTile(
                leading: Icon(
                  Icons.check_circle_outline_rounded,
                  color: theme.colorScheme.primary,
                ),
                title: Text(
                  settings.spotifyAccount.isEmpty
                      ? 'Connected'
                      : 'Connected as ${settings.spotifyAccount}',
                ),
                subtitle: const Text('Read-only access to your library'),
                trailing: TextButton(
                  onPressed: () {
                    settings.disconnectSpotify();
                    ref.invalidate(spotifyPlaylistsProvider);
                  },
                  child: const Text('Disconnect'),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text('Your playlists', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            _PlaylistList(
              importingId: _importing,
              onImport: (id, name, saved) =>
                  _import(id: id, name: name, saved: saved),
            ),
          ],

          if (_error != null) ...[
            const SizedBox(height: 16),
            Card(
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
          ],
        ],
      ),
    );
  }
}

class _PlaylistList extends ConsumerWidget {
  const _PlaylistList({required this.onImport, this.importingId});

  final void Function(String id, String name, bool saved) onImport;
  final String? importingId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playlists = ref.watch(spotifyPlaylistsProvider);

    return playlists.when(
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (error, _) => EmptyState(
        icon: Icons.cloud_off_rounded,
        title: 'Could not read your playlists',
        message: error is SpotifyAuthException
            ? error.message
            : 'Something went wrong talking to Spotify.',
        action: FilledButton.tonal(
          onPressed: () => ref.invalidate(spotifyPlaylistsProvider),
          child: const Text('Try again'),
        ),
      ),
      data: (items) => Column(
        children: [
          // Liked Songs is not a playlist in the API, but it is the one every
          // account has, so it is offered alongside them.
          Card(
            margin: const EdgeInsets.only(bottom: 8),
            child: ListTile(
              leading: const Icon(Icons.favorite_rounded),
              title: const Text('Liked Songs'),
              subtitle: const Text('Everything you have saved'),
              trailing: importingId == 'saved'
                  ? const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : TextButton(
                      onPressed: () =>
                          onImport('saved', 'Spotify · Liked Songs', true),
                      child: const Text('Import'),
                    ),
            ),
          ),
          for (final playlist in items)
            Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                leading: const Icon(Icons.queue_music_rounded),
                title: Text(playlist.name),
                subtitle: Text(
                  [
                    '${playlist.trackCount} tracks',
                    if (playlist.owner != null) 'by ${playlist.owner}',
                  ].join(' · '),
                ),
                trailing: importingId == playlist.id
                    ? const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : TextButton(
                        onPressed: () => onImport(
                          playlist.id,
                          'Spotify · ${playlist.name}',
                          false,
                        ),
                        child: const Text('Import'),
                      ),
              ),
            ),
        ],
      ),
    );
  }
}

/// What was imported, what was guessed at, and what could not be found.
class _ResultDialog extends StatelessWidget {
  const _ResultDialog({required this.result});

  final SpotifyImportResult result;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final imported = result.imported.length;
    final uncertain = result.uncertain.length;
    final missing = result.missing.toList();

    return Dialog(
      child: SizedBox(
        width: 560,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(result.playlistName, style: theme.textTheme.titleLarge),
              const SizedBox(height: 12),
              Text(
                '$imported of ${result.matches.length} tracks matched your '
                'library.',
                style: theme.textTheme.bodyMedium,
              ),
              if (uncertain > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    '$uncertain of those were a close but imperfect match — '
                    'usually a different edit or pressing.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              if (imported == 0)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    'Nothing matched, so no playlist was created.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ),
              if (missing.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text(
                  '${missing.length} not in your library',
                  style: theme.textTheme.titleSmall,
                ),
                const SizedBox(height: 4),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 240),
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: missing.length,
                    itemBuilder: (context, index) {
                      final track = missing[index].track;
                      return ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          track.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          track.artists.join(', '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      );
                    },
                  ),
                ),
              ],
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                spacing: 8,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Close'),
                  ),
                  if (result.playlistId != null)
                    FilledButton(
                      onPressed: () {
                        Navigator.of(context).pop();
                        openPlaylist(context, result.playlistId!);
                      },
                      child: const Text('Open playlist'),
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
