import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/providers.dart';
import '../components/common.dart';
import '../components/library_widgets.dart';

/// Port of `presentation/screens/SearchScreen` — one search field over songs,
/// albums, artists and playlists, plus the genre grid as the idle state.
class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _controller = TextEditingController();
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _controller.text = ref.read(searchQueryProvider);
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final results = ref.watch(searchResultsProvider);
    final query = ref.watch(searchQueryProvider);
    final library = ref.watch(activeLibraryProvider);
    final db = ref.watch(databaseProvider);
    final theme = Theme.of(context);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
          child: SearchBar(
            controller: _controller,
            focusNode: _focus,
            autoFocus: true,
            hintText: 'Songs, albums, artists, genres…',
            leading: const Padding(
              padding: EdgeInsets.only(left: 8),
              child: Icon(Icons.search_rounded),
            ),
            trailing: [
              if (query.isNotEmpty)
                IconButton(
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () {
                    _controller.clear();
                    ref.read(searchQueryProvider.notifier).state = '';
                  },
                ),
            ],
            onChanged: (value) =>
                ref.read(searchQueryProvider.notifier).state = value,
            onSubmitted: (value) {
              db.recordSearch(value);
              ref.read(searchQueryProvider.notifier).state = value;
            },
          ),
        ),
        Expanded(
          child: query.trim().isEmpty
              ? _IdleState(history: db.searchHistory())
              : results.isEmpty
              ? EmptyState(
                  icon: Icons.search_off_rounded,
                  title: 'No results for "$query"',
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                  children: [
                    if (results.artists.isNotEmpty) ...[
                      const SectionHeader(title: 'Artists'),
                      SizedBox(
                        height: 190,
                        child: ListView.builder(
                          scrollDirection: Axis.horizontal,
                          itemCount: results.artists.length,
                          itemBuilder: (context, i) =>
                              ArtistCard(artist: results.artists[i]),
                        ),
                      ),
                    ],
                    if (results.albums.isNotEmpty) ...[
                      const SectionHeader(title: 'Albums'),
                      SizedBox(
                        height: 230,
                        child: ListView.builder(
                          scrollDirection: Axis.horizontal,
                          itemCount: results.albums.length,
                          itemBuilder: (context, i) =>
                              AlbumCard(album: results.albums[i]),
                        ),
                      ),
                    ],
                    if (results.playlists.isNotEmpty) ...[
                      const SectionHeader(title: 'Playlists'),
                      SizedBox(
                        height: 230,
                        child: ListView.builder(
                          scrollDirection: Axis.horizontal,
                          itemCount: results.playlists.length,
                          itemBuilder: (context, i) =>
                              PlaylistCard(playlist: results.playlists[i]),
                        ),
                      ),
                    ],
                    if (results.songs.isNotEmpty) ...[
                      SectionHeader(
                        title: 'Songs',
                        subtitle: plural(results.songs.length, 'result'),
                        trailing: FilledButton.tonalIcon(
                          onPressed: () => playSongs(ref, results.songs),
                          icon: const Icon(Icons.play_arrow_rounded),
                          label: const Text('Play all'),
                        ),
                      ),
                      for (var i = 0; i < results.songs.length; i++)
                        SongTile(
                          song: results.songs[i],
                          onTap: () =>
                              playSongs(ref, results.songs, startIndex: i),
                        ),
                    ],
                    if (library.genres.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 24),
                        child: Text(
                          '${library.songs.length} songs indexed',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}

/// Port of `search/components/GenreCategoriesGrid` — the browse-by-genre state
/// shown before anything is typed.
class _IdleState extends ConsumerWidget {
  const _IdleState({required this.history});

  final List<String> history;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final genres = ref.watch(activeLibraryProvider).genres;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      children: [
        if (history.isNotEmpty) ...[
          SectionHeader(
            title: 'Recent searches',
            trailing: TextButton(
              onPressed: () {
                ref.read(databaseProvider).clearSearchHistory();
                ref.invalidate(libraryProvider);
              },
              child: const Text('Clear'),
            ),
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final query in history)
                ActionChip(
                  label: Text(query),
                  avatar: const Icon(Icons.history_rounded, size: 18),
                  onPressed: () =>
                      ref.read(searchQueryProvider.notifier).state = query,
                ),
            ],
          ),
          const SizedBox(height: 16),
        ],
        const SectionHeader(title: 'Browse genres'),
        if (genres.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Text('No genre tags in your library yet.'),
          )
        else
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 220,
              childAspectRatio: 1.4,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
            ),
            itemCount: genres.length,
            itemBuilder: (context, i) => GenreCard(genre: genres[i]),
          ),
      ],
    );
  }
}
