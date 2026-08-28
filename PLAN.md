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

### Phase 6 — Remote sources ✅
Jellyfin and Navidrome are done: `data/remote/` holds one `RemoteSource` abstraction with
both backends behind it, accounts are stored per server (several of the same kind can
coexist), and there is an Accounts screen plus one browse screen serving both dashboards.

The Android app needs a local HTTP proxy per backend (`JellyfinStreamProxy` and friends,
~1000 lines) because ExoPlayer cannot carry the auth. mpv opens a signed URL directly, so
none of the proxies come across — a remote song's `path` is simply a playable URL, and
`PlayerService.mediaFor` decides between `file://` and passthrough.

Auth per protocol: Subsonic signs every request `t=md5(password+salt)` with a fresh salt,
so the password never crosses the wire; Jellyfin logs in once and sends its token in a
header, with `api_key` in the URL only for the stream, which mpv fetches itself.

Remote libraries are held in memory, not written to the local database: `replaceLibrary`
would drop them on the next rescan, and a server's catalogue is not ours to mirror.

**Telegram** is in, against TDLib's JSON interface rather than its generated bindings:
`libtdjson` exposes the whole API as four C functions taking JSON, which is a far smaller
FFI surface than the Java classes the Android app links. `TdlibTransport` is the seam — the
real one is `dart:ffi`, and the tests use a fake, so the login state machine, the
request/reply correlation and the audio mapping are all under test without the native
library present.

Playback differs from the phone. `TelegramStreamProxy` serves a partial download over
localhost so ExoPlayer has a URL; here the file is downloaded through TDLib first and then
played as an ordinary local file, with the next track fetched in the background. Honest
rather than seamless: a cold track waits for its download.

Two things the user has to supply, and neither can be shipped: TDLib itself (most
distributions do not package it; Manjaro has it in the AUR only) and an api_id/api_hash
pair from my.telegram.org, which Telegram issues per application. The setup screen says so
and takes a path to the `.so` if it is not on the default library path.

**Google Drive** is in, as an ordinary `RemoteSource` once a token is in hand. Google
issues OAuth credentials per project, so the user registers a Desktop app client and signs
in through the browser: authorization code with PKCE, a loopback redirect on port 8890,
and the read-only `drive.readonly` scope.

The interesting part is that Drive stores files, not music. There are no tags, no durations
and no cover art in its metadata, so the library is derived from the layout — album from the
containing folder, artist from the folder above it, title from the file name (with a leading
track number and an `Artist - Title` prefix understood). A folder name always beats a guess
from a file name.

Streaming needed one new seam. Drive's download endpoint takes a bearer header and nothing
else — no signed URL, no token in the query — so `PlayerService.remoteStreamHeaders` maps a
URL prefix to headers and `mediaFor` hands them to mpv. Known ceiling: headers are baked in
when a queue is opened, so a queue still playing an hour later hits expired tokens on its
later tracks.

**Spotify** was built and then removed. It cannot supply audio at all, so it could only
import playlist metadata and act as a remote for a Spotify player already sitting next to
the app — neither earned its place, and both needed credentials the user had to register.

**NetEase / QQMusic: dropped.** Unofficial reverse-engineered endpoints (~1800 lines)
whose catalogue is geo-locked to China, so neither the code nor the result could be
exercised from here. Everything that could be tested would be the request signing and the
parsing; whether the endpoints answer at all would stay unknown. Phase 6 is otherwise
complete.

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

### Phase 7 — Desktop platform integration ✅
**Equalizer is in.** Android drove four system effects from `android.media.audiofx`
(`Equalizer`, `BassBoost`, `Virtualizer`, `LoudnessEnhancer`); desktop has no such service,
but mpv carries ffmpeg's filters, so all four become one `af` string: an `equalizer` biquad
per band, a `bass` low shelf, `extrastereo`, and `dynaudnorm`. The ten band centres, the
±15 dB range and the ten presets are the phone's values, so a preset is the same curve.

Off means no filter at all rather than a flat one — ten no-op biquads are still ten biquads
in the path. mpv takes `af` live, so a slider is heard while it is being dragged, and the
screen shows the chain it generates.

The generated chain was checked against real mpv, not just the docs: it is accepted whole,
and `dynaudnorm`'s window turned out to need an odd frame count, which ffmpeg otherwise
rounds up while logging about it.

**MPRIS2 is in.** On Android `MusicService` published a MediaSession and the system supplied
the lockscreen controls and headset buttons. On Linux the same job is one D-Bus name,
`org.mpris.MediaPlayer2.pixelplayer`, and the desktop takes it from there: GNOME's media
widget, KDE's panel, the media keys, playerctl. Linux only — macOS wants
MPNowPlayingInfoCenter and Windows SystemMediaTransportControls, so `attach` returns null
elsewhere rather than pretending.

The metadata mapping is pure and tested (microseconds not milliseconds, artists as an
array, a track id that is a legal object path, `file://` URIs escaped). Two live bugs came
out of testing it against the real bus, neither of which a unit test could have shown:

- `ref.watch(playerProvider)` in the provider meant every `notifyListeners()` invalidated
  it, so the D-Bus client was torn down and the bus name released a moment after being
  claimed. `requestName` reported success and the name was simply gone. It has to be `read`.
- The pending attach has to be *returned* from the provider. Kept in a local it was the
  only reference to the running service, and the client was collected.

Verified over the session bus: properties readable, PlayPause and Next drive the player,
metadata follows the track.

**Single instance and file association are in.** Android had
`ExternalPlayerActivity` and let the system decide whether to reuse the task. Here the app
arranges both halves: a loopback socket on a fixed port is the rendezvous, and a second
launch hands its file list to the running copy and exits rather than starting a rival
player that fights for the audio device. A lock file could say "someone is running" but
could not carry the files, which is why it is a socket.

The message is authorised by a token in the app's state directory, mode 600, so another
user on the machine cannot make the app open arbitrary paths; paths are filtered to audio
extensions and capped. If the port turns out to be held by something that is not us, the
app runs anyway without the feature — refusing to start would be worse.

Files on the command line beat the restored queue, `file://` URIs are accepted because file
managers send them, and a file already in the library is played as its library row so
favourites and edited tags are the ones the user knows.

**Notifications are in**, through `org.freedesktop.Notifications`, and off by default:
Android needed a notification to be controllable at all, while here MPRIS already puts
controls in the shell. Each popup reuses the previous id so an album leaves one popup that
changes rather than forty in the tray, and transport buttons are only offered when the
server advertises the `actions` capability.

**Tray is in**, via tray_manager, with close-to-tray — refused without an icon, since there
would be no way back to the window. Both off by default. Building it needed
`-Wno-deprecated-declarations`: libayatana-appindicator is deprecated upstream in its
entirety while remaining the only way to put an icon in a tray, and the project compiles
with `-Werror`.

Verified live: a second launch with a file argument exits 0 and the running copy switches to
that track, which MPRIS then reports.

**Chromecast and DLNA are in**, and phase 7 is complete.

Both reduce to the same three verbs — hand over a URL, transport, volume — so they sit
behind one controller. Neither protocol can read a local file, so casting also means running
a small HTTP server here for as long as a track plays. Only explicitly published files are
reachable, each under a random 32-hex id, and there is no path in the URL to traverse.

The design decision worth recording: **PixelPlayer stays the brain.** The queue, shuffle,
repeat and what comes next are still decided locally and the device is handed one track at a
time. Pushing a whole playlist and letting the device manage it means two things that both
believe they are in charge, and they disagree the moment the queue is reordered. So while
casting, mpv is paused, and when the device reports the track finished the queue advances
here and the next track is pushed.

DLNA is SSDP (a UDP multicast question) → device description XML → SOAP against the
AVTransport control URL, with DIDL-Lite metadata because a good number of renderers play
nothing without it. Chromecast is CASTV2: length-prefixed protobuf carrying JSON. The one
message type has six fields, so it is encoded by hand rather than adding a protobuf compiler
and a generated file for forty bytes of wire format. Heartbeats every five seconds or the
device hangs up; the TLS certificate is self-signed and device-specific so it cannot be
verified, which is also the reason nothing but "play this URL on my LAN" ever crosses that
socket.

Two things the tests pin down that a device would only fail at silently: Range handling
(a renderer that asks for a byte offset and gets the whole file back tends to stop, so an
unsatisfiable range is answered 416), and which local address to advertise — this machine is
on a LAN *and* a VPN, and only the address on the device's own subnet is reachable from it.

A Drive track cannot be cast: its URL needs an Authorization header, and there is no way to
give a speaker one. That is refused with an explanation rather than failing at the device.
A Jellyfin or Navidrome URL signs itself and is passed through untouched.

Verified live as far as this network allows: discovery runs clean on both protocols (nothing
answered — there is no Cast or DLNA device here), the server binds, and a ranged fetch over
the LAN address returns 206 with the right content-range. Nothing has been played on a real
speaker.

### Phase 8 — Long tail ✅

**Backup/restore.** Same module-per-section shape as the Android app, and the same section
keys, so a file from either is at least legible to the other. Restore is per section, because
the usual reason to open a backup is to get one thing out of it.

Two decisions worth recording. First, restore **adds**: a playlist that already exists keeps
its songs and gains the backup's, since the library has usually moved on and losing tracks
to a restore is worse than a longer playlist. Second, the desktop problem Android does not
have — a backup is often restored on a different machine, where the music lives elsewhere —
so every song reference carries its tags as well as its path and matching falls back to a
normalised title/artist/album key. What matches neither is counted and reported, never
silently dropped, and history rows already present are skipped so restoring twice does not
double every play count.

Nothing secret is written, and that is enforced in one place rather than at each call site:
`isSecretPreference` filters keys, and remote accounts travel as server and username with
the password stripped, so a restore recreates the server and asks for the password again.

**Update check.** Asks GitHub and stops there — no download, no self-replacing binary; the
app is installed from a tarball or a package. Off by default, since it is the only thing in
the app that contacts a server the user did not configure. The awkward part is this repo's
own release shape: CI publishes a rolling `latest` prerelease on every push, so
`/releases/latest` is the wrong endpoint (it skips prereleases, and the rolling tag is not a
version). The check reads the list and takes the newest tag that parses as a version.

Run live against the real repository, which caught a defect no unit test would have: there is
no `v*` tag yet, so `latest` comes back null and the screen claimed "you are up to date" —
asserting something it does not know. There is now a distinct `noReleases` state saying the
releases page has only the rolling build.

**About and licences.** Version, `showLicensePage` for every package, a link to the source,
and the way into diagnostics. Tapping the version seven times opens the easter egg, same
count as the phone.

**Diagnostics.** Every remote source here depends on something the user supplies — yt-dlp,
TDLib, a session bus — so "why does this not work" is nearly always answered by one list:
libmpv in use, yt-dlp and TDLib presence, whether MPRIS is actually published (asked of the
bus from outside, since the app believing it published is exactly what went wrong when MPRIS
was built), session type, paths, library counts. Copyable as text, because the point is
pasting it into a bug report.

**BrickBreaker.** The board is a unit square and the rules are a pure `step(dt)`, so corner
bounces, two-hit bricks, one-brick-per-frame and the dt clamp that stops a stalled frame
tunnelling the ball are all tested without a frame being drawn.
