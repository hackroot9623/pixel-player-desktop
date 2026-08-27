import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/remote/remote_account.dart';
import '../../data/remote/youtube/youtube_source.dart';
import '../../data/remote/youtube/ytdlp_client.dart';
import '../../state/providers.dart';

/// Sets up the YouTube Music source: where yt-dlp is, which playlists to read,
/// and whether to borrow the browser's cookies for the user's own library.
class YoutubeSetupScreen extends ConsumerStatefulWidget {
  const YoutubeSetupScreen({super.key, this.accountId});

  final String? accountId;

  @override
  ConsumerState<YoutubeSetupScreen> createState() =>
      _YoutubeSetupScreenState();
}

class _YoutubeSetupScreenState extends ConsumerState<YoutubeSetupScreen> {
  final _executable = TextEditingController();
  final _newUrl = TextEditingController();
  final _cookiesFile = TextEditingController();

  String? _accountId;
  List<String> _urls = const [];
  String? _cookiesBrowser;
  bool _liked = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _accountId = widget.accountId;
    final existing = _account;
    if (existing != null) {
      _executable.text = existing.extra['executable'] ?? '';
      _urls = youtubeSourceUrls(existing);
      _cookiesBrowser = youtubeCookiesBrowser(existing);
      _cookiesFile.text = youtubeCookiesFile(existing) ?? '';
      _liked = existing.extra['liked'] == 'true';
    }
  }

  @override
  void dispose() {
    _executable.dispose();
    _newUrl.dispose();
    _cookiesFile.dispose();
    super.dispose();
  }

  bool get _hasCookies =>
      _cookiesBrowser != null || _cookiesFile.text.trim().isNotEmpty;

  RemoteAccount? get _account => _accountId == null
      ? null
      : ref
            .read(remoteAccountsProvider)
            .where((entry) => entry.id == _accountId)
            .firstOrNull;

  /// Creates the account on first save, then keeps updating the same record.
  void _save() {
    final settings = ref.read(settingsProvider);
    final account = (_account ??
            RemoteAccount(
              id: 'youtube-${DateTime.now().millisecondsSinceEpoch}',
              kind: RemoteKind.youtube,
              serverUrl: '',
              username: '',
              password: '',
            ))
        .copyWith(
          extra: {
            if (_executable.text.trim().isNotEmpty)
              'executable': _executable.text.trim(),
            if (_urls.isNotEmpty) 'urls': _urls.join('\n'),
            if (_cookiesBrowser != null) 'cookiesBrowser': _cookiesBrowser!,
            if (_cookiesFile.text.trim().isNotEmpty)
              'cookiesFile': _cookiesFile.text.trim(),
            if (_liked) 'liked': 'true',
          },
        );
    settings.upsertRemoteAccount(account);
    _accountId = account.id;
    ref.invalidate(remoteSongsProvider(account.id));
    setState(() {});
  }

  void _addUrl() {
    final url = _newUrl.text.trim();
    if (url.isEmpty) return;
    final uri = Uri.tryParse(url);
    const hosts = {
      'youtube.com',
      'www.youtube.com',
      'm.youtube.com',
      'music.youtube.com',
      'youtu.be',
    };
    if (uri == null || !hosts.contains(uri.host)) {
      setState(
        () => _error = 'That is not a YouTube or YouTube Music link.',
      );
      return;
    }
    setState(() {
      _error = null;
      _urls = [..._urls, url];
      _newUrl.clear();
    });
    _save();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final version = _accountId == null
        ? const AsyncValue<String?>.data(null)
        : ref.watch(ytDlpVersionProvider(_accountId!));

    return Scaffold(
      appBar: AppBar(title: const Text('YouTube Music')),
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
                    'YouTube has no API that hands out audio, so playback goes '
                    'through yt-dlp, which you install yourself. Extracting '
                    'audio is against YouTube’s terms of service; whether to do '
                    'it is your call. Keeping yt-dlp up to date is what fixes '
                    'playback when YouTube changes something.\n\n'
                    'Searching usually works as-is, but YouTube often refuses '
                    'to hand over the audio itself unless a request looks like '
                    'a signed-in browser — so playback normally needs the '
                    'cookies option below.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          Text('yt-dlp', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          TextField(
            controller: _executable,
            decoration: const InputDecoration(
              labelText: 'Path to yt-dlp (optional)',
              hintText: '/usr/bin/yt-dlp',
              helperText: 'Leave empty to use whatever is on PATH',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (_) => _save(),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              FilledButton.tonalIcon(
                onPressed: () {
                  _save();
                  if (_accountId != null) {
                    ref.invalidate(ytDlpVersionProvider(_accountId!));
                  }
                },
                icon: const Icon(Icons.search_rounded, size: 18),
                label: const Text('Check'),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: version.when(
                  loading: () => const Text('Looking…'),
                  error: (_, _) => Text(
                    'Could not run it.',
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                  data: (value) => value == null
                      ? Text(
                          _accountId == null
                              ? 'Save to check.'
                              : 'Not found — install the yt-dlp package.',
                          style: TextStyle(
                            color: _accountId == null
                                ? theme.colorScheme.onSurfaceVariant
                                : theme.colorScheme.error,
                          ),
                        )
                      : Text('Found version $value'),
                ),
              ),
            ],
          ),

          const Divider(height: 40),
          Text('Playlists and albums', style: theme.textTheme.titleSmall),
          Text(
            'Paste a YouTube Music playlist, album or track link. These become '
            'the library for this source; search works without any of them.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _newUrl,
                  decoration: const InputDecoration(
                    labelText: 'Link',
                    hintText: 'https://music.youtube.com/playlist?list=…',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _addUrl(),
                ),
              ),
              const SizedBox(width: 12),
              FilledButton(onPressed: _addUrl, child: const Text('Add')),
            ],
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(
              _error!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ],
          const SizedBox(height: 8),
          for (final url in _urls)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.queue_music_rounded),
              title: Text(url, maxLines: 1, overflow: TextOverflow.ellipsis),
              trailing: IconButton(
                tooltip: 'Remove',
                icon: const Icon(Icons.close_rounded),
                onPressed: () {
                  setState(
                    () => _urls = [
                      for (final entry in _urls)
                        if (entry != url) entry,
                    ],
                  );
                  _save();
                },
              ),
            ),

          const Divider(height: 40),
          Text('Cookies', style: theme.textTheme.titleSmall),
          Text(
            'yt-dlp can read the cookies of a browser you are signed into. Two '
            'things need this: your own playlists and Liked Music, and — more '
            'often than not — playback at all, since YouTube tends to refuse '
            'audio to requests that do not look signed in. It reads that '
            'browser’s cookie store directly, so it stays off until you choose '
            'a browser.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String?>(
            initialValue: _cookiesBrowser,
            decoration: const InputDecoration(
              labelText: 'Take cookies from',
              border: OutlineInputBorder(),
            ),
            items: [
              const DropdownMenuItem(value: null, child: Text('No cookies')),
              for (final browser in YtDlpClient.supportedBrowsers)
                DropdownMenuItem(value: browser, child: Text(browser)),
            ],
            onChanged: (value) {
              setState(() {
                _cookiesBrowser = value;
                // Liked Music is unreachable without a signed-in session.
                if (value == null && _cookiesFile.text.trim().isEmpty) {
                  _liked = false;
                }
              });
              _save();
            },
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _cookiesFile,
            decoration: const InputDecoration(
              labelText: 'Or a cookies.txt file',
              hintText: '/home/you/cookies.txt',
              helperText: 'Used in preference to the browser above. Export it '
                  'with a "Get cookies.txt" extension while signed in to '
                  'YouTube Music — this works even while the browser is open.',
              helperMaxLines: 3,
              border: OutlineInputBorder(),
            ),
            onSubmitted: (_) => _save(),
            onTapOutside: (_) => _save(),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Include Liked Music'),
            subtitle: Text(
              _hasCookies
                  ? 'Adds the tracks you have liked on YouTube Music'
                  : 'Needs cookies, from a browser or a file',
            ),
            value: _liked,
            onChanged: !_hasCookies
                ? null
                : (value) {
                    setState(() => _liked = value);
                    _save();
                  },
          ),

          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              FilledButton(
                onPressed: () {
                  _save();
                  Navigator.of(context).pop();
                },
                child: const Text('Done'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
