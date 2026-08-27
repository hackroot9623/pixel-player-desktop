import 'package:flutter/material.dart';

import '../data/models/models.dart';
import '../data/smart/smart_playlists.dart';
import 'screens/album_detail_screen.dart';
import 'screens/artist_detail_screen.dart';
import 'screens/folder_screen.dart';
import 'screens/genre_detail_screen.dart';
import 'screens/accounts_screen.dart';
import 'screens/ai_settings_screen.dart';
import 'screens/mashup_screen.dart';
import 'screens/playlist_detail_screen.dart';
import 'screens/remote_browse_screen.dart';
import 'screens/telegram_setup_screen.dart';
import 'screens/drive_setup_screen.dart';
import 'screens/equalizer_screen.dart';
import 'screens/youtube_setup_screen.dart';
import 'screens/smart_playlist_screen.dart';
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

void openMashup(BuildContext context) =>
    _push(context, const MashupScreen());

void openAiSettings(BuildContext context) =>
    _push(context, const AiSettingsScreen());

void openAccounts(BuildContext context) =>
    _push(context, const AccountsScreen());

void openRemoteBrowse(BuildContext context, String accountId) =>
    _push(context, RemoteBrowseScreen(accountId: accountId));

void openTelegramSetup(BuildContext context, {String? accountId}) =>
    _push(context, TelegramSetupScreen(accountId: accountId));

void openYoutubeSetup(BuildContext context, {String? accountId}) =>
    _push(context, YoutubeSetupScreen(accountId: accountId));

void openDriveSetup(BuildContext context, {String? accountId}) =>
    _push(context, DriveSetupScreen(accountId: accountId));

void openEqualizer(BuildContext context) =>
    _push(context, const EqualizerScreen());

void openPaletteStyle(BuildContext context) =>
    _push(context, const PaletteStyleScreen());

void openNavCornerRadius(BuildContext context) =>
    _push(context, const NavCornerRadiusScreen());

void openTransitionEditor(BuildContext context) =>
    _push(context, const TransitionEditorScreen());

void openPlayerLook(BuildContext context) =>
    _push(context, const PlayerLookScreen());

void openWindowSettings(BuildContext context) =>
    _push(context, const WindowScreen());

void openSmartPlaylist(BuildContext context, SmartPlaylistRule rule) =>
    _push(context, SmartPlaylistScreen(rule: rule));
