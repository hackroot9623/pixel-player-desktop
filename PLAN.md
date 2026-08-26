# PixelPlayer Desktop — Flutter port plan

Port of the Android PixelPlayer (Kotlin/Jetpack Compose, ~206k LOC, 711 files) to a
Flutter desktop app with the same feature set and Material 3 design.

Reference source: `../PixelPlayer/app/src/main/java/com/theveloper/pixelplay/`

## Fixed decisions

| Topic | Choice |
|---|---|
| Audio engine | `media_kit` (libmpv) — replaces Media3 ExoPlayer + FFmpeg |
| Persistence | raw `sqlite3` (dart:ffi) + `shared_preferences` — replaces Room + DataStore |
| State | Riverpod — replaces Hilt + StateFlow ViewModels |
| Metadata read | `audio_metadata_reader` (pure Dart) |
| Design system | Material 3, original `gflex_variable.ttf` (Google Sans Flex, ROND=100) + Montserrat |
| Platform | Linux first; Windows/macOS configs later |

## Layer mapping

| Android | Flutter |
|---|---|
| `data/database` (Room, 48 files) | `lib/data/db/database.dart` (schema + DAO methods) |
| `data/model` | `lib/data/models/` |
| `data/preferences` (DataStore) | `lib/data/prefs/settings.dart` |
| `data/repository` | `lib/data/repository/` |
| `data/service/MusicService` | `lib/player/player_service.dart` |
| `data/worker` (WorkManager sync) | `lib/data/scanner/library_scanner.dart` (isolate) |
| `presentation/viewmodel` (49) | Riverpod notifiers in `lib/state/` |
| `presentation/screens` (38) | `lib/ui/screens/` |
| `presentation/components` (74) | `lib/ui/components/` |
| `ui/theme` | `lib/ui/theme/` |
| `ui/glancewidget` | n/a on desktop → tray + MPRIS (phase 7) |

## Phases

### Phase 1 — Foundation + local library + playback  ✅ (this pass)
- Window setup, M3 theme port (colors, typography, shapes, dynamic color from album art)
- SQLite schema: songs, artists, song_artists, albums, genres, playlists, playlist_songs,
  favorites, playback_history, search_history, music_folders
- Recursive folder scanner with metadata + embedded artwork extraction, artist delimiter parsing
- `media_kit` playback: queue, shuffle, repeat modes, seek, volume, gapless
- Desktop shell: navigation rail + Home / Search / Library / Settings
- Screens: Setup (folder pick), Home, Library (Songs/Albums/Artists/Genres/Folders/Playlists/
  Favorites + sort options), Search, Album/Artist/Genre/Playlist detail
- Mini player + full player + queue panel

### Phase 2 — Expressive player & UI polish
`UnifiedPlayerSheetV2`, `FullPlayerContent`, `WavySliderExpressive`, `RoundedParallaxCarousell`,
`ExpressiveScrollBar`, smooth-corner shapes (`utils/shapes`), nav corner radius + palette style
settings, `SongInfoBottomSheet`, multi-select sheets, sleep timer, crossfade/`Transition` editor.

### Phase 3 — Lyrics
LRCLIB client, LRC parse + synced scroll display, `LyricsSheet`, lyrics editing, source prefs.

### Phase 4 — Tag editor
Write-side metadata (`audiotags`/TagLib FFI), `EditSongSheet`, `EditMultipleSongsSheet`,
artwork embedding, artist artwork via Deezer + LRU/db cache, custom artist images.

### Phase 5 — Intelligence
Stats (`StatsScreen`, `StatsOverviewCard`), Daily Mix, smart playlists (`SmartPlaylistRule`),
AI playlists (Gemini / OpenAI / Deepseek), QuickFill, Mashup, recently played.

### Phase 6 — Remote sources
Jellyfin, Navidrome, Google Drive, Telegram, NetEase, QQMusic — dashboards + streaming
(`data/stream`, `data/{jellyfin,navidrome,gdrive,telegram,netease,qqmusic}`), Accounts screen.

### Phase 7 — Desktop platform integration
MPRIS2 + media keys, system tray, notifications, single-instance + file-association
(`ExternalPlayerActivity` equivalent), equalizer via mpv audio filters, Chromecast/DLNA.

### Phase 8 — Long tail
Backup/restore, GitHub update check, About/OSS licenses, easter egg (BrickBreaker),
diagnostics + device capabilities, changelog/beta sheets.
