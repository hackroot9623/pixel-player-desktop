import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/models.dart';
import '../../data/models/sort_option.dart';
import '../../state/providers.dart';
import '../components/common.dart';
import '../components/expressive_scrollbar.dart';
import '../components/library_widgets.dart';
import '../components/multi_select.dart';
import '../navigation.dart';

/// Port of `presentation/screens/LibraryScreen` and its per-tab files
/// (`LibraryMediaTabs`, `LibrarySongsTab`, `LibrarySongsAndFavoritesTabs`).
class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({super.key});

  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(
    length: LibraryTabId.values.length,
    vsync: this,
    initialIndex: LibraryTabId.values.indexOf(ref.read(libraryTabProvider)),
  )..addListener(() {
    if (!_tabs.indexIsChanging) {
      ref.read(libraryTabProvider.notifier).state =
          LibraryTabId.values[_tabs.index];
    }
  });

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tab = LibraryTabId.values[_tabs.index];
    final settings = ref.watch(settingsProvider);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 20, 4),
          child: Row(
            children: [
              const Expanded(child: ExpressiveTitle('LIBRARY')),
              TextButton.icon(
                onPressed: () => showSortSheet(context, ref, tab),
                icon: const Icon(Icons.sort_rounded),
                label: Text(settings.sortFor(tab).label),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: 'New playlist',
                icon: const Icon(Icons.playlist_add_rounded),
                onPressed: () async {
                  final name = await promptForText(
                    context,
                    title: 'New playlist',
                    hint: 'Playlist name',
                  );
                  if (name != null && name.isNotEmpty) {
                    ref.read(libraryProvider.notifier).createPlaylist(name);
                  }
                },
              ),
              IconButton(
                tooltip: 'Settings',
                icon: const Icon(Icons.settings_rounded),
                onPressed: () => openSettings(context),
              ),
            ],
          ),
        ),
        TabBar(
          controller: _tabs,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: [
            for (final t in LibraryTabId.values) Tab(text: t.title),
          ],
        ),
        Expanded(
          child: TabBarView(
            controller: _tabs,
            children: [
              for (final t in LibraryTabId.values) _TabContent(tab: t),
            ],
          ),
        ),
      ],
    );
  }
}

class _TabContent extends ConsumerWidget {
  const _TabContent({required this.tab});

  final LibraryTabId tab;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final library = ref.watch(libraryProvider);
    final sort = ref.watch(settingsProvider).sortFor(tab);

    switch (tab) {
      case LibraryTabId.songs:
      case LibraryTabId.liked:
        final source = tab == LibraryTabId.songs
            ? library.songs
            : library.favorites;
        final songs = sortSongs(source, sort);
        if (songs.isEmpty) {
          return EmptyState(
            icon: tab == LibraryTabId.liked
                ? Icons.favorite_border_rounded
                : Icons.music_note_rounded,
            title: tab == LibraryTabId.liked
                ? 'No liked songs yet'
                : 'No songs found',
            message: tab == LibraryTabId.liked
                ? 'Tap the heart on a song to add it here.'
                : 'Add a music folder in settings.',
          );
        }
        return _SongList(songs: songs);

      case LibraryTabId.albums:
        final albums = sortAlbums(library.albums, sort);
        return _grid(
          count: albums.length,
          extent: 200,
          aspect: 0.78,
          builder: (i) => AlbumCard(album: albums[i]),
          emptyIcon: Icons.album_rounded,
          emptyTitle: 'No albums',
        );

      case LibraryTabId.artists:
        final artists = sortArtists(library.artists, sort);
        return _grid(
          count: artists.length,
          extent: 170,
          aspect: 0.82,
          builder: (i) => ArtistCard(artist: artists[i]),
          emptyIcon: Icons.person_rounded,
          emptyTitle: 'No artists',
        );

      case LibraryTabId.genres:
        final genres = library.genres;
        return _grid(
          count: genres.length,
          extent: 220,
          aspect: 1.4,
          builder: (i) => GenreCard(genre: genres[i]),
          emptyIcon: Icons.graphic_eq_rounded,
          emptyTitle: 'No genre tags found',
        );

      case LibraryTabId.playlists:
        final playlists = sortPlaylists(library.playlists, sort);
        return _grid(
          count: playlists.length,
          extent: 200,
          aspect: 0.78,
          builder: (i) => PlaylistCard(playlist: playlists[i]),
          emptyIcon: Icons.queue_music_rounded,
          emptyTitle: 'No playlists yet',
        );

      case LibraryTabId.folders:
        final folders = sortFolders(ref.watch(foldersProvider(null)), sort);
        if (folders.isEmpty) {
          return const EmptyState(
            icon: Icons.folder_rounded,
            title: 'No folders',
          );
        }
        return ListView.builder(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
          itemCount: folders.length,
          itemBuilder: (context, i) => FolderTile(folder: folders[i]),
        );
    }
  }

  Widget _grid({
    required int count,
    required double extent,
    required double aspect,
    required Widget Function(int index) builder,
    required IconData emptyIcon,
    required String emptyTitle,
  }) {
    if (count == 0) return EmptyState(icon: emptyIcon, title: emptyTitle);
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: extent,
        childAspectRatio: aspect,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
      ),
      itemCount: count,
      itemBuilder: (context, i) => builder(i),
    );
  }
}


/// Songs and Liked share this list: an A-Z jump scrollbar over the rows and the
/// multi-select action bar floating on top of it.
class _SongList extends ConsumerStatefulWidget {
  const _SongList({required this.songs});

  final List<Song> songs;

  @override
  ConsumerState<_SongList> createState() => _SongListState();
}

class _SongListState extends ConsumerState<_SongList> {
  final _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final player = ref.read(playerProvider);
    final songs = widget.songs;
    return Stack(
      children: [
        ExpressiveScrollbar(
          controller: _controller,
          enabled: ref.watch(settingsProvider).showScrollbar,
          // The bubble shows the initial of whatever row the drag is over,
          // which is what makes the bar useful on a long library.
          labelForOffset: (fraction) {
            if (songs.isEmpty) return null;
            final index = (fraction * (songs.length - 1)).round();
            final title = songs[index].title.trim();
            return title.isEmpty ? null : title[0].toUpperCase();
          },
          child: ListView.builder(
            controller: _controller,
            padding: const EdgeInsets.fromLTRB(12, 8, 40, 96),
            itemCount: songs.length,
            itemBuilder: (context, i) => SongTile(
              song: songs[i],
              onTap: () => player.playQueue(songs, startIndex: i),
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: SelectionActionBar(allSongs: songs),
        ),
      ],
    );
  }
}
