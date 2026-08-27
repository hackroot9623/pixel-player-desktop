import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/remote/drive/drive_source.dart';
import '../../data/remote/drive/google_oauth.dart';
import '../../data/remote/remote_account.dart';
import '../../state/providers.dart';

/// Sets up Google Drive as a source: the OAuth client the user registered, the
/// browser sign-in, and optionally one folder to look in.
class DriveSetupScreen extends ConsumerStatefulWidget {
  const DriveSetupScreen({super.key, this.accountId});

  final String? accountId;

  @override
  ConsumerState<DriveSetupScreen> createState() => _DriveSetupScreenState();
}

class _DriveSetupScreenState extends ConsumerState<DriveSetupScreen> {
  final _clientId = TextEditingController();
  final _clientSecret = TextEditingController();
  final _folderId = TextEditingController();

  String? _accountId;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _accountId = widget.accountId;
    final existing = _account;
    if (existing != null) {
      _clientId.text = driveClientId(existing);
      _clientSecret.text = driveClientSecret(existing);
      _folderId.text = driveFolderId(existing);
    }
  }

  @override
  void dispose() {
    _clientId.dispose();
    _clientSecret.dispose();
    _folderId.dispose();
    super.dispose();
  }

  RemoteAccount? get _account => _accountId == null
      ? null
      : ref
            .read(remoteAccountsProvider)
            .where((entry) => entry.id == _accountId)
            .firstOrNull;

  /// Creates the account on first save, then keeps updating the same record.
  ///
  /// The tokens already in `extra` are carried through: saving the client ID
  /// again must not sign the user out.
  RemoteAccount _save() {
    final settings = ref.read(settingsProvider);
    final existing = _account;
    final account =
        (existing ??
                RemoteAccount(
                  id: 'drive-${DateTime.now().millisecondsSinceEpoch}',
                  kind: RemoteKind.drive,
                  serverUrl: '',
                  username: '',
                  password: '',
                ))
            .copyWith(
              extra: {
                ...?existing?.extra,
                driveClientIdKey: _clientId.text.trim(),
                driveClientSecretKey: _clientSecret.text.trim(),
                if (_folderId.text.trim().isNotEmpty)
                  driveFolderKey: _folderId.text.trim(),
              },
            );
    settings.upsertRemoteAccount(account);
    _accountId = account.id;
    ref.invalidate(remoteSongsProvider(account.id));
    setState(() {});
    return account;
  }

  Future<void> _signIn() async {
    final account = _save();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await connectDriveAccount(ref, account);
    } on GoogleAuthException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _signOut() {
    final account = _account;
    if (account == null) return;
    // Drops the session but keeps the client credentials, so signing back in is
    // one button rather than a retyped client ID.
    ref.read(settingsProvider).upsertRemoteAccount(
      account.copyWith(
        extra: {
          for (final MapEntry(:key, :value) in account.extra.entries)
            if (key != 'refresh_token' &&
                key != 'access_token' &&
                key != 'expires_at')
              key: value,
        },
      ),
    );
    ref.invalidate(remoteSongsProvider(account.id));
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Watched rather than read: signing in rewrites the account, and this
    // screen has to notice.
    ref.watch(remoteAccountsProvider);
    final account = _account;
    final signedIn = account?.isAuthenticated ?? false;
    final redirect = const GoogleOAuth(clientId: '').redirectUri;
    final tracks = account == null
        ? const AsyncValue<List<dynamic>>.data([])
        : ref.watch(remoteSongsProvider(account.id));

    return Scaffold(
      appBar: AppBar(title: const Text('Google Drive')),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('How this works', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 8),
                  Text(
                    'Drive stores files, not music: it knows a name and a '
                    'folder and nothing about what is inside. So the folder a '
                    'track sits in becomes its album, the folder above that '
                    'becomes the artist, and the file name becomes the title. '
                    'Track length shows up once a track plays, and there are '
                    'no covers — those live inside the files.\n\n'
                    'Playback streams straight from Drive. Nothing is '
                    'downloaded and nothing is written: the permission asked '
                    'for is read-only.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          Text('1 · Your Google client', style: theme.textTheme.titleSmall),
          Text(
            'Google issues OAuth credentials per project, so PixelPlayer '
            'cannot ship one. In the Google Cloud console: enable the Drive '
            'API, then create an OAuth client of type "Desktop app" and add '
            'the redirect URI below to it.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          // Has to match byte for byte, so it is offered to copy.
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
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _clientSecret,
            decoration: const InputDecoration(
              labelText: 'Client secret',
              border: OutlineInputBorder(),
              helperText:
                  'Google shows one next to the client ID. It is not really a '
                  'secret for a desktop app, but Google asks for it anyway.',
              helperMaxLines: 3,
            ),
          ),
          const SizedBox(height: 20),

          Text('2 · Sign in', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          if (signedIn)
            Card(
              child: ListTile(
                leading: Icon(
                  Icons.check_circle_outline_rounded,
                  color: theme.colorScheme.primary,
                ),
                title: const Text('Signed in to Google Drive'),
                subtitle: Text(
                  tracks.when(
                    loading: () => 'Reading your Drive…',
                    error: (error, _) => '$error',
                    data: (list) => '${list.length} tracks found',
                  ),
                ),
                trailing: TextButton(
                  onPressed: _signOut,
                  child: const Text('Sign out'),
                ),
              ),
            )
          else
            FilledButton.icon(
              onPressed: _busy || _clientId.text.trim().isEmpty
                  ? null
                  : _signIn,
              icon: _busy
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.open_in_browser_rounded, size: 18),
              label: Text(
                _busy ? 'Waiting for your browser…' : 'Sign in with Google',
              ),
            ),
          const SizedBox(height: 20),

          Text('3 · Where to look', style: theme.textTheme.titleSmall),
          Text(
            'Leave this empty to scan the whole Drive. To limit it, open the '
            'folder in Drive and copy the id from the end of its URL — only '
            'files directly inside it are listed.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _folderId,
            decoration: const InputDecoration(
              labelText: 'Folder id (optional)',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              FilledButton.tonal(
                onPressed: () {
                  _save();
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Saved')),
                  );
                },
                child: const Text('Save'),
              ),
              const SizedBox(width: 12),
              if (_accountId != null)
                TextButton.icon(
                  onPressed: () =>
                      ref.invalidate(remoteSongsProvider(_accountId!)),
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  label: const Text('Reload library'),
                ),
            ],
          ),

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
