import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/remote/remote_account.dart';
import '../../data/remote/remote_source.dart';
import '../../state/providers.dart';
import '../components/common.dart';
import '../navigation.dart';

/// Port of `presentation/screens/AccountsScreen`.
///
/// Lists the configured servers, and adds or edits one. Signing in happens
/// here so the browse screen can assume a working account.
class AccountsScreen extends ConsumerWidget {
  const AccountsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accounts = ref.watch(remoteAccountsProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Accounts')),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        children: [
          Text(
            'Stream from a music server alongside your local files. Tracks stay '
            'on the server; nothing is copied into your library.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 20),
          if (accounts.isEmpty)
            const EmptyState(
              icon: Icons.cloud_off_rounded,
              title: 'No servers yet',
              message: 'Add a Jellyfin or Navidrome server to stream from it.',
            )
          else
            for (final account in accounts) _AccountTile(account: account),
          const SizedBox(height: 24),
          Text('Add a server', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          for (final kind in RemoteKind.values)
            Card(
              child: ListTile(
                leading: Icon(
                  kind == RemoteKind.jellyfin
                      ? Icons.movie_filter_rounded
                      : Icons.dns_rounded,
                ),
                title: Text(kind.label),
                subtitle: Text(kind.description),
                trailing: const Icon(Icons.add_rounded),
                onTap: () => showRemoteAccountSheet(context, kind: kind),
              ),
            ),
        ],
      ),
    );
  }
}

class _AccountTile extends ConsumerWidget {
  const _AccountTile({required this.account});

  final RemoteAccount account;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final songs = ref.watch(remoteSongsProvider(account.id));

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        leading: Icon(
          account.kind == RemoteKind.jellyfin
              ? Icons.movie_filter_rounded
              : Icons.dns_rounded,
          color: theme.colorScheme.primary,
        ),
        title: Text(account.title),
        subtitle: Text(
          songs.when(
            loading: () => 'Loading…',
            error: (error, _) => error is RemoteException
                ? error.message
                : 'Could not reach the server',
            data: (list) => '${account.username} · ${list.length} tracks',
          ),
          maxLines: 2,
          style: theme.textTheme.bodySmall?.copyWith(
            color: songs.hasError
                ? theme.colorScheme.error
                : theme.colorScheme.onSurfaceVariant,
          ),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: 'Reload',
              icon: const Icon(Icons.refresh_rounded),
              onPressed: () =>
                  ref.invalidate(remoteSongsProvider(account.id)),
            ),
            IconButton(
              tooltip: 'Edit',
              icon: const Icon(Icons.edit_rounded),
              onPressed: () => showRemoteAccountSheet(
                context,
                kind: account.kind,
                existing: account,
              ),
            ),
            IconButton(
              tooltip: 'Remove',
              icon: const Icon(Icons.delete_outline_rounded),
              onPressed: () async {
                // Removing a server drops its tracks from the app, so it is
                // worth a confirmation.
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: Text('Remove ${account.title}?'),
                    content: const Text(
                      'Its tracks disappear from PixelPlayer. Nothing on the '
                      'server is touched.',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(false),
                        child: const Text('Cancel'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.of(context).pop(true),
                        child: const Text('Remove'),
                      ),
                    ],
                  ),
                );
                if (confirmed ?? false) {
                  ref.read(settingsProvider).removeRemoteAccount(account.id);
                }
              },
            ),
          ],
        ),
        onTap: () => openRemoteBrowse(context, account.id),
      ),
    );
  }
}

/// Add or edit one server. Signs in before saving, so a typo is caught here
/// rather than showing up as an empty library later.
Future<void> showRemoteAccountSheet(
  BuildContext context, {
  required RemoteKind kind,
  RemoteAccount? existing,
}) => showDialog<void>(
  context: context,
  builder: (_) => Dialog(
    child: _AccountForm(kind: kind, existing: existing),
  ),
);

class _AccountForm extends ConsumerStatefulWidget {
  const _AccountForm({required this.kind, this.existing});

  final RemoteKind kind;
  final RemoteAccount? existing;

  @override
  ConsumerState<_AccountForm> createState() => _AccountFormState();
}

class _AccountFormState extends ConsumerState<_AccountForm> {
  late final _url = TextEditingController(
    text: widget.existing?.serverUrl ?? '',
  );
  late final _user = TextEditingController(
    text: widget.existing?.username ?? '',
  );
  late final _password = TextEditingController(
    text: widget.existing?.password ?? '',
  );

  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _url.dispose();
    _user.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final account = RemoteAccount(
      // A stable id per account, so editing keeps the same record and its
      // cached songs.
      id: widget.existing?.id ??
          '${widget.kind.storageKey}-${DateTime.now().millisecondsSinceEpoch}',
      kind: widget.kind,
      serverUrl: _url.text,
      username: _user.text,
      password: _password.text,
    );

    if (!account.isComplete) {
      setState(() {
        _busy = false;
        _error = 'Fill in the address, username and password.';
      });
      return;
    }

    try {
      await connectRemoteAccount(ref, account);
      if (mounted) Navigator.of(context).pop();
    } on RemoteException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: 460,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.existing == null
                  ? 'Add ${widget.kind.label}'
                  : 'Edit ${widget.kind.label}',
              style: theme.textTheme.titleLarge,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _url,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Server address',
                hintText: 'music.example.com or http://nas:4533',
                helperText: 'https:// is assumed when no scheme is given',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _user,
              decoration: const InputDecoration(
                labelText: 'Username',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _password,
              obscureText: true,
              onSubmitted: (_) => _save(),
              decoration: const InputDecoration(
                labelText: 'Password',
                helperText: 'Stored on this machine in plain text',
                border: OutlineInputBorder(),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              spacing: 8,
              children: [
                TextButton(
                  onPressed: _busy ? null : () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton.icon(
                  onPressed: _busy ? null : _save,
                  icon: _busy
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.login_rounded, size: 18),
                  label: Text(_busy ? 'Connecting…' : 'Sign in and save'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
