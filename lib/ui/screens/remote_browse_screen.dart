import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/models.dart';
import '../../data/remote/remote_source.dart';
import '../../state/providers.dart';
import '../components/common.dart';
import '../components/library_widgets.dart';

/// Port of the dashboards under `presentation/{jellyfin,navidrome}/dashboard`.
///
/// One screen serves both: the two backends differ in how they authenticate,
/// not in what a library looks like once fetched.
class RemoteBrowseScreen extends ConsumerStatefulWidget {
  const RemoteBrowseScreen({super.key, required this.accountId});

  final String accountId;

  @override
  ConsumerState<RemoteBrowseScreen> createState() =>
      _RemoteBrowseScreenState();
}

class _RemoteBrowseScreenState extends ConsumerState<RemoteBrowseScreen> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final account = ref
        .watch(remoteAccountsProvider)
        .where((entry) => entry.id == widget.accountId)
        .firstOrNull;
    if (account == null) {
      return const Scaffold(
        body: EmptyState(
          icon: Icons.cloud_off_rounded,
          title: 'Server removed',
        ),
      );
    }

    final songs = ref.watch(remoteSongsProvider(widget.accountId));
    final player = ref.read(playerProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(account.title),
        actions: [
          IconButton(
            tooltip: 'Reload from the server',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: () =>
                ref.invalidate(remoteSongsProvider(widget.accountId)),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: songs.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: EmptyState(
              icon: Icons.cloud_off_rounded,
              title: 'Could not load the library',
              message: error is RemoteException
                  ? error.message
                  : 'Something went wrong talking to the server.',
              action: FilledButton.tonal(
                onPressed: () =>
                    ref.invalidate(remoteSongsProvider(widget.accountId)),
                child: const Text('Try again'),
              ),
            ),
          ),
        ),
        data: (all) {
          if (all.isEmpty) {
            return const EmptyState(
              icon: Icons.library_music_outlined,
              title: 'Nothing here',
              message: 'This account can see no audio on the server.',
            );
          }

          final query = _query.trim().toLowerCase();
          final matches = query.isEmpty
              ? all
              : [
                  for (final song in all)
                    if (song.title.toLowerCase().contains(query) ||
                        song.displayArtist.toLowerCase().contains(query) ||
                        song.album.toLowerCase().contains(query))
                      song,
                ];
          // Grouping by album is how both dashboards present a server.
          final albums = <String, List<Song>>{};
          for (final song in matches) {
            albums.putIfAbsent(song.album, () => []).add(song);
          }

          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 12, 24, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: SearchBar(
                        hintText: 'Search this server',
                        leading: const Icon(Icons.search_rounded),
                        onChanged: (value) => setState(() => _query = value),
                      ),
                    ),
                    const SizedBox(width: 12),
                    FilledButton.tonalIcon(
                      onPressed: matches.isEmpty
                          ? null
                          : () => player.playQueue([...matches]..shuffle()),
                      icon: const Icon(Icons.shuffle_rounded),
                      label: const Text('Shuffle all'),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                  children: [
                    Text(
                      '${matches.length} tracks · ${albums.length} albums',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 8),
                    for (final entry in albums.entries) ...[
                      SectionHeader(
                        title: entry.key,
                        subtitle: entry.value.first.displayArtist,
                        trailing: IconButton(
                          tooltip: 'Play album',
                          icon: const Icon(Icons.play_arrow_rounded),
                          onPressed: () => player.playQueue(entry.value),
                        ),
                      ),
                      for (var i = 0; i < entry.value.length; i++)
                        SongTile(
                          song: entry.value[i],
                          // These are not in the local database, so the
                          // selection actions that operate on it do not apply.
                          selectable: false,
                          onTap: () =>
                              player.playQueue(entry.value, startIndex: i),
                        ),
                    ],
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
