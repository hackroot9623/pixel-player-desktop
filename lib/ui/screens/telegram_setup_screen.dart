import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/remote/remote_account.dart';
import '../../data/remote/telegram/tdlib_client.dart';
import '../../data/remote/telegram/telegram_source.dart';
import '../../state/providers.dart';

/// Port of the Telegram login flow from `TelegramRepository` + its dialogs.
///
/// Telegram authenticates against Telegram, not against a server address, so
/// this is a wizard rather than a form: credentials, then phone, then the code
/// it sends, then two-step if the account has it, then which chats to read.
class TelegramSetupScreen extends ConsumerStatefulWidget {
  const TelegramSetupScreen({super.key, this.accountId});

  /// Null when adding a new account.
  final String? accountId;

  @override
  ConsumerState<TelegramSetupScreen> createState() =>
      _TelegramSetupScreenState();
}

class _TelegramSetupScreenState extends ConsumerState<TelegramSetupScreen> {
  final _apiId = TextEditingController();
  final _apiHash = TextEditingController();
  final _libraryPath = TextEditingController();
  final _phone = TextEditingController();
  final _code = TextEditingController();
  final _password = TextEditingController();

  String? _accountId;
  bool _busy = false;
  String? _error;
  TdAuthState _state = TdAuthState.initial;
  List<({int id, String title})> _chats = const [];
  final _selectedChats = <int>{};

  @override
  void initState() {
    super.initState();
    _accountId = widget.accountId;
    final existing = _account;
    if (existing != null) {
      _apiId.text = existing.extra['apiId'] ?? '';
      _apiHash.text = existing.extra['apiHash'] ?? '';
      _libraryPath.text = existing.extra['libraryPath'] ?? '';
      _selectedChats.addAll(telegramChatIds(existing));
    }
  }

  @override
  void dispose() {
    _apiId.dispose();
    _apiHash.dispose();
    _libraryPath.dispose();
    _phone.dispose();
    _code.dispose();
    _password.dispose();
    super.dispose();
  }

  RemoteAccount? get _account => _accountId == null
      ? null
      : ref
            .read(remoteAccountsProvider)
            .where((entry) => entry.id == _accountId)
            .firstOrNull;

  /// Saves the credentials, then starts TDLib and follows its state.
  Future<void> _begin() async {
    final id = int.tryParse(_apiId.text.trim());
    if (id == null || _apiHash.text.trim().isEmpty) {
      setState(() => _error = 'Enter the api_id and api_hash from my.telegram.org.');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    final settings = ref.read(settingsProvider);
    final account = (_account ??
            RemoteAccount(
              id: 'telegram-${DateTime.now().millisecondsSinceEpoch}',
              kind: RemoteKind.telegram,
              serverUrl: '',
              username: '',
              password: '',
            ))
        .copyWith(
          extra: {
            'apiId': '$id',
            'apiHash': _apiHash.text.trim(),
            if (_libraryPath.text.trim().isNotEmpty)
              'libraryPath': _libraryPath.text.trim(),
          },
        );
    settings.upsertRemoteAccount(account);
    _accountId = account.id;

    try {
      // Creating the client dials Telegram, so it is only done once the
      // credentials are in place.
      final client = ref.read(telegramClientProvider(account.id));
      client.authStates.listen((state) {
        if (!mounted) return;
        setState(() => _state = state);
        if (state == TdAuthState.ready) _onReady();
      });
      setState(() => _state = client.authState);
    } on TdlibException catch (error) {
      setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } on TdlibException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _onReady() async {
    final id = _accountId;
    if (id == null) return;
    // Remember that the session is live, so the next launch does not ask again.
    final account = _account;
    if (account != null) {
      ref.read(settingsProvider).upsertRemoteAccount(
        account.copyWith(extra: {...account.extra, 'session': 'ready'}),
      );
    }
    await _run(() async {
      final chats = await ref.read(telegramSourceProvider(id)).chats();
      if (mounted) setState(() => _chats = chats);
    });
  }

  void _saveChats() {
    final account = _account;
    if (account == null) return;
    ref.read(settingsProvider).upsertRemoteAccount(
      account.copyWith(
        extra: {...account.extra, 'chats': _selectedChats.join(',')},
      ),
    );
    ref.invalidate(remoteSongsProvider(account.id));
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Telegram')),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Before you start', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 8),
                  Text(
                    'Telegram needs TDLib, the official client library, which '
                    'most distributions do not package — build it from '
                    'github.com/tdlib/td if the step below cannot find it. You '
                    'also need your own api_id and api_hash from '
                    'my.telegram.org: Telegram issues those per application, '
                    'and PixelPlayer cannot ship one for you.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text('1 · Credentials', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          Row(
            spacing: 12,
            children: [
              Expanded(
                child: TextField(
                  controller: _apiId,
                  decoration: const InputDecoration(
                    labelText: 'api_id',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              Expanded(
                flex: 2,
                child: TextField(
                  controller: _apiHash,
                  decoration: const InputDecoration(
                    labelText: 'api_hash',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _libraryPath,
            decoration: const InputDecoration(
              labelText: 'Path to libtdjson (optional)',
              hintText: '/usr/local/lib/libtdjson.so',
              helperText: 'Leave empty to search the usual library paths',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _busy ? null : _begin,
            icon: const Icon(Icons.link_rounded, size: 18),
            label: const Text('Connect to Telegram'),
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

          const SizedBox(height: 24),
          Text('2 · Sign in', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          switch (_state) {
            TdAuthState.waitPhoneNumber => _Step(
              label: 'Phone number, with country code',
              controller: _phone,
              hint: '+53 5 123 4567',
              action: 'Send code',
              busy: _busy,
              onSubmit: () => _run(
                () => ref
                    .read(telegramClientProvider(_accountId!))
                    .sendPhoneNumber(_phone.text),
              ),
            ),
            TdAuthState.waitCode => _Step(
              label: 'The code Telegram just sent you',
              controller: _code,
              hint: '12345',
              action: 'Confirm',
              busy: _busy,
              onSubmit: () => _run(
                () => ref
                    .read(telegramClientProvider(_accountId!))
                    .sendCode(_code.text),
              ),
            ),
            TdAuthState.waitPassword => _Step(
              label: 'Two-step verification password',
              controller: _password,
              obscure: true,
              action: 'Confirm',
              busy: _busy,
              onSubmit: () => _run(
                () => ref
                    .read(telegramClientProvider(_accountId!))
                    .sendPassword(_password.text),
              ),
            ),
            TdAuthState.waitRegistration => Text(
              'This number has no Telegram account yet. Sign up in the '
              'Telegram app first.',
              style: theme.textTheme.bodyMedium,
            ),
            TdAuthState.ready => Row(
              children: [
                Icon(
                  Icons.check_circle_outline_rounded,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                const Text('Signed in.'),
              ],
            ),
            TdAuthState.loggedOut || TdAuthState.closed => const Text(
              'The session ended. Connect again.',
            ),
            TdAuthState.initial => Text(
              'Connect above to begin.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          },

          if (_state == TdAuthState.ready) ...[
            const SizedBox(height: 24),
            Text('3 · Chats to read', style: theme.textTheme.titleSmall),
            Text(
              'Only the chats you pick are searched for audio.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            if (_chats.isEmpty)
              const Text('Loading chats…')
            else
              for (final chat in _chats)
                CheckboxListTile(
                  dense: true,
                  value: _selectedChats.contains(chat.id),
                  title: Text(chat.title),
                  onChanged: (checked) => setState(() {
                    if (checked ?? false) {
                      _selectedChats.add(chat.id);
                    } else {
                      _selectedChats.remove(chat.id);
                    }
                  }),
                ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                FilledButton(
                  onPressed: _selectedChats.isEmpty ? null : _saveChats,
                  child: Text('Use ${_selectedChats.length} chats'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({
    required this.label,
    required this.controller,
    required this.action,
    required this.onSubmit,
    required this.busy,
    this.hint,
    this.obscure = false,
  });

  final String label;
  final TextEditingController controller;
  final String action;
  final VoidCallback onSubmit;
  final bool busy;
  final String? hint;
  final bool obscure;

  @override
  Widget build(BuildContext context) => Row(
    spacing: 12,
    children: [
      Expanded(
        child: TextField(
          controller: controller,
          obscureText: obscure,
          autofocus: true,
          onSubmitted: (_) => onSubmit(),
          decoration: InputDecoration(
            labelText: label,
            hintText: hint,
            border: const OutlineInputBorder(),
          ),
        ),
      ),
      FilledButton(onPressed: busy ? null : onSubmit, child: Text(action)),
    ],
  );
}
