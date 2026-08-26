import 'package:flutter/material.dart';

import '../data/models/models.dart';
import 'screens/album_detail_screen.dart';
import 'screens/artist_detail_screen.dart';
import 'screens/folder_screen.dart';
import 'screens/genre_detail_screen.dart';
import 'screens/playlist_detail_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/settings_screens.dart';
import 'screens/stats_screen.dart';

/// Replaces `presentation/navigation/AppNavigation.kt`. Detail screens are
/// pushed onto the shell's inner Navigator so the mini player stays docked,
/// which is why these are plain helpers rather than a route table.
void _push(BuildContext context, Widget page) => Navigator.of(
  context,
).push(MaterialPageRoute<void>(builder: (_) => page));

void openAlbum(BuildContext context, int albumId) =>
    _push(context, AlbumDetailScreen(albumId: albumId));

void openArtist(BuildContext context, int artistId) =>
    _push(context, ArtistDetailScreen(artistId: artistId));

void openGenre(BuildContext context, Genre genre) =>
    _push(context, GenreDetailScreen(genre: genre));

void openPlaylist(BuildContext context, String playlistId) =>
    _push(context, PlaylistDetailScreen(playlistId: playlistId));

void openFolder(BuildContext context, MusicFolder folder) =>
    _push(context, FolderScreen(folder: folder));

void openSettings(BuildContext context) =>
    _push(context, const SettingsScreen());

void openStats(BuildContext context) => _push(context, const StatsScreen());

void openPaletteStyle(BuildContext context) =>
    _push(context, const PaletteStyleScreen());

void openNavCornerRadius(BuildContext context) =>
    _push(context, const NavCornerRadiusScreen());

void openTransitionEditor(BuildContext context) =>
    _push(context, const TransitionEditorScreen());

void openPlayerLook(BuildContext context) =>
    _push(context, const PlayerLookScreen());
