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

### Phase 1 — Foundation + local library + playback  ✅
- Window setup, M3 theme port (colors, typography, shapes, dynamic color from album art)
- SQLite schema: songs, artists, song_artists, albums, genres, playlists, playlist_songs,
  favorites, playback_history, search_history, music_folders
- Recursive folder scanner with metadata + embedded artwork extraction, artist delimiter parsing
- `media_kit` playback: queue, shuffle, repeat modes, seek, volume, gapless
- Desktop shell: navigation rail + Home / Search / Library / Settings
- Screens: Setup (folder pick), Home, Library (Songs/Albums/Artists/Genres/Folders/Playlists/
  Favorites + sort options), Search, Album/Artist/Genre/Playlist detail
- Mini player + full player + queue panel

### Phase 2 — Expressive player & UI polish  ✅
`WavySliderExpressive`, album carousel (via `CarouselView.weighted`), `ExpressiveScrollBar`,
smooth-corner/polygon/star shapes, nav corner radius + palette style + player look settings,
`SongInfoBottomSheet`, multi-select action bar, sleep timer, `Transition` editor.

Deviations from the Android original, deliberately:
- The two stacked rows of 80 dp full-width transport pills became one dense
  `TransportBar` with hover, tooltips and keyboard shortcuts — phone ergonomics
  do not transfer to a desktop window.
- `TransitionMode.overlap`/`smooth` need two decoders running at once. mpv owns
  a single playlist here, so they currently render as a fade-out/fade-in pair;
  true overlap is folded into phase 7 alongside the equalizer.

### Phase 3 — Lyrics  ✅
LRCLIB client (`dart:io`, no new dependency), LRC parser handling multi-timestamp lines,
enhanced word timings and `[offset:]`, synced scrolling display with tap-to-seek and
auto-follow, `LyricsSheet` as a docked pane or modal, search dialog (`FetchLyricsDialog`),
hand editing, ±0.5 s sync nudge, source priority + auto-fetch prefs, `.lrc`/`.txt` sidecar
pickup, and a `lyrics` cache table (schema v2).

Not ported: TTML parsing (`TtmlLyricsParser`), romanization/translation tracks
(`MultiLangRomanizer`) and the per-word bubble animation (`BubblesLine`) — the
model carries the fields, so they slot in without a schema change.

### Phase 4 — Tag editor  ✅
Tag writing, `EditSongSheet`, `EditMultipleSongsSheet`, artwork embedding, artist
artwork via Deezer with a file cache, custom artist images.

No TagLib FFI needed: `audio_metadata_reader` ships writers for ID3v2/v1, MP4,
FLAC, RIFF and APEv2. Two consequences to know about:
- Ogg and Opus can be read but not written; the editor says so instead of
  failing at save time.
- Those writers only rewrite a tag block that already exists — the RIFF writer
  replaces a LIST/INFO chunk but will not create one, and the ID3 writer needs
  an existing ID3v2 tag. Writes are therefore verified by re-reading, and a
  silent no-op is reported as an error.
- Album artist has no setter in the package, so it stays derived from the
  artist tag. That also keeps the compilation-splitting caveat from phase 1.

Writes go to a copy, which is re-read to prove it parses and that the values
landed, and only then renamed over the original — these are the user's only
copies of their music.

### Phase 5 — Intelligence  🟡 in progress
Done: real listening-time recording, `StatsScreen` with per-period charts, the four
`SmartPlaylistRule` playlists, a seeded Daily Mix, QuickFill, recently played.

Everything is ranked by **time listened** rather than play count — a track started and
skipped twenty times is not a favourite. That needed a fix underneath: playback was
recorded with `msPlayed: 0` always, so "listened" could only ever read zero. Listening
time is now accumulated from forward position movement (seeks and pauses excluded) and
written when the track ends.

Mashup turned out to be a two-deck DJ mixer: `MashupViewModel` runs two ExoPlayers side
by side, each with its own volume, tempo (0.5x-2x) and millisecond nudge for beat
matching, with a crossfader blending between them. Ported as `DeckController` /
`MashupController` over two extra media_kit players, created with the screen and released
with it — two idle decoders are not worth keeping alive. The crossfader curve is extracted
as a pure function so it is testable without an audio device; it reproduces the Android
app's *linear* fade, which dips ~3 dB mid-blend (documented in the test, not "fixed",
since changing it would make it a different mixer).

AI playlists are in: all 11 providers from `AiProvider`, a key/model/endpoint stored per
provider, model listing and a connection test, request-size and generation settings, and a
sheet that describes a mood in words and gets back a playlist of real library tracks.

`GeminiAiClient` and `GenericOpenAiClient` collapse into one client, since only the request
and response shapes differ. Two deliberate changes: the model is handed pool *indices*
rather than song IDs, because a song ID here is its absolute path and sending it would give
a third-party API the user's home directory for nothing; and the key travels in a header,
never the query string. Model auto-recovery is kept (providers retire model names, and a
stored dead model should not read as "AI is broken"); the Android response cache, provider
fallback chains and per-provider cooldowns are not ported yet.

Not verifiable here: no API keys, so nothing has run against a live endpoint. The tests fake
the HTTP layer, which does cover the parts most likely to break — response cleaning, error
mapping, model recovery, and exactly what leaves the machine.

Phase 5 is complete.

### Phase 6 — Remote sources
Jellyfin, Navidrome, Google Drive, Telegram, NetEase, QQMusic — dashboards + streaming
(`data/stream`, `data/{jellyfin,navidrome,gdrive,telegram,netease,qqmusic}`), Accounts screen.

### Desktop-only surface (no Android counterpart)
Compact mode: below 620x440 the shell drops the navigation rail and the library
and becomes a player — artwork, track, seek bar and transport — reverting when
the window grows. The window minimum is 320x180 so it can be shrunk to a
desk-corner player.

Client-side window decorations: a setting to hide the system title bar and draw
our own close / minimise / maximise controls, with the button cluster on either
side and in either convention (glyphs or traffic lights). Includes the drag
region, double-click-to-maximise, and our own edge/corner resize handles —
hiding the decorations also removes the compositor's resize borders.

### Phase 7 — Desktop platform integration
MPRIS2 + media keys, system tray, notifications, single-instance + file-association
(`ExternalPlayerActivity` equivalent), equalizer via mpv audio filters, Chromecast/DLNA.

### Phase 8 — Long tail
Backup/restore, GitHub update check, About/OSS licenses, easter egg (BrickBreaker),
diagnostics + device capabilities, changelog/beta sheets.
