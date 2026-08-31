# PixelPlayer Desktop

Flutter desktop port of [PixelPlayer](https://github.com/PixelPlayerHQ/PixelPlayer),
the Jetpack Compose / Material 3 music player for Android. Same feature set and
design language, rebuilt for Linux (Windows and macOS to follow).

See [PLAN.md](PLAN.md) for the phased port plan and the Android → Flutter layer
mapping. Phase 1 (local library + playback + core UI) is implemented.

## Requirements

- Flutter 3.44+
- `libmpv` (Arch/Manjaro: `pacman -S mpv`, Debian/Ubuntu: `apt install libmpv2`)
- GTK 3 development headers for the Linux embedder

## Run

```sh
flutter run -d linux
```

## Test

The library and playback tests take real audio files via environment variables
so they exercise the actual tag reader and decoder:

```sh
MUSIC_DIR=~/Music MUSIC_FILE=~/Music/some-track.mp3 flutter test
```

Without those the pure-logic cases still run and the rest skip.

## Layout

| Path | Contents |
|---|---|
| `lib/data/db` | SQLite schema and queries (replaces Room) |
| `lib/data/models` | Domain models and sort options |
| `lib/data/scanner` | Folder scanner, tag reading, artwork extraction |
| `lib/data/prefs` | Preferences (replaces DataStore) |
| `lib/player` | `media_kit` playback service (replaces Media3 MusicService) |
| `lib/state` | Riverpod providers (replaces Hilt + ViewModels) |
| `lib/ui/theme` | Ported colors, typography and shapes |
| `lib/ui/components` | Reusable widgets — player bar, queue, tiles, wavy slider |
| `lib/ui/screens` | Screens |

The original `gflex_variable.ttf` (Google Sans Flex, `ROND` axis at 100) ships in
`assets/fonts/`, so typography matches the Android app rather than approximating
it.

## Telegram credentials

Telegram's `api_id`/`api_hash` identify the *application*, not the user: MTProto
requires them before a phone number can be offered, so signing in cannot produce
them. The Android build reads a pair out of `local.properties` into
`BuildConfig`; the desktop build does the same, and then a user only sees the
phone-and-code steps.

Register PixelPlayer once at https://my.telegram.org, then either build with the
pair:

```bash
flutter build linux --dart-define=TELEGRAM_API_ID=1234567 \
  --dart-define=TELEGRAM_API_HASH=0123456789abcdef0123456789abcdef
```

or drop a `telegram_app.json` next to the app's data — no rebuild needed:

```json
{ "api_id": 1234567, "api_hash": "0123456789abcdef0123456789abcdef" }
```

Either way the file and the defines stay out of git. With neither present, the
setup screen asks for a pair so a user can bring their own.

Telegram also needs TDLib (`libtdjson`), which most distributions do not
package — build it from https://github.com/tdlib/td, or install a distribution
package where one exists. If it is not on the default library path, the setup
screen takes the path to the `.so`.

## Building and releases

CI builds all three desktop bundles on every push and publishes them to the
[releases page](https://github.com/hackroot9623/pixel-player-desktop/releases):
pushes to `master` refresh a rolling `latest` prerelease, and a `v*` tag cuts a
versioned release.

| Platform | Artifact | Install |
| --- | --- | --- |
| Linux | `pixelplayer-linux-x64.tar.gz` | Extract, run `./install.sh` (into `~/.local`, no root) |
| Windows | `pixelplayer-windows-x64.zip` | Extract, run `pixelplay_desktop.exe` |
| macOS | `pixelplayer-macos-arm64.zip` | Unzip, move to Applications, right-click → Open |

Building locally needs the Flutter version pinned in the workflow, plus libmpv
and sqlite3 development packages on Linux:

```bash
flutter build linux --release
```

Two caveats on the bundles. The macOS build is unsigned and un-notarised, so
Gatekeeper needs the right-click → Open dance on first launch; signing needs an
Apple Developer certificate. And macOS runners are Apple silicon, so that bundle
is arm64 only — an Intel build would need a separate `macos-13` matrix entry.

## YouTube Music

Playback goes through [yt-dlp](https://github.com/yt-dlp/yt-dlp), which you
install yourself — there is no official API that hands out audio, and the
YouTube Data API requires playback through its own embedded player. Extracting
audio is against YouTube's terms of service; whether to do it is your call.

**Google sign-in does not help here.** OAuth works for the Data API's metadata,
but the servers that actually serve audio do not accept an OAuth token — they
check session cookies. So:

- **Search** works anonymously.
- **Playback** almost always needs cookies. Either pick a browser you are signed
  into, or — more reliably — export a `cookies.txt` and point at it. Chromium
  browsers lock their cookie database while running, so the file route works
  where the browser route often does not.
- **Your own playlists and Liked Music** need cookies for the same reason.

Keeping yt-dlp current is what fixes playback when YouTube changes something;
that is a job for your package manager, not a PixelPlayer release.

## Google Drive

Drive is a filing cabinet, not a music server. It knows a file's name, size and
folder and nothing about what is inside, so the library is derived from the
layout:

- the folder a track sits in becomes its **album**
- the folder above that becomes the **artist**
- the file name becomes the **title**, with a leading track number and an
  `Artist - Title` prefix understood

Track length appears once a track plays, because Drive does not report one, and
there are no covers — those live inside the files. Playback streams straight
from Drive with a bearer header that mpv carries; nothing is downloaded first.

Set up a client once, because Google issues OAuth credentials per project:

1. In the Google Cloud console, create a project and enable the **Drive API**.
2. Create an OAuth client of type **Desktop app**.
3. Add exactly this redirect URI: `http://127.0.0.1:8890`
4. Paste the client ID and secret into Accounts → Google Drive, then sign in.

The permission requested is `drive.readonly` — nothing here can modify a file.
The secret Google issues alongside the client ID is not really secret for a
desktop app, which is why the flow also uses PKCE; Google's token endpoint just
insists on having it.

Optionally give a folder id to scan only that folder. Note the ceiling on a
long session: stream headers are set when a queue is opened, so a Drive queue
still playing an hour later hits expired tokens on its later tracks — reopening
the queue fixes it.

## Equalizer

Ten bands at the ISO centres (31 Hz … 16 kHz), ±15 dB, with the same ten presets as the
Android app so a preset is the same curve. Alongside them: bass boost, stereo width and
levelling, which stand in for Android's BassBoost, Virtualizer and LoudnessEnhancer.

There is no system audio-effects service on desktop, so all of it becomes one mpv audio
filter chain — a biquad per band, then `bass`, `extrastereo` and `dynaudnorm`. mpv applies
it live, so a slider is heard while it is being dragged, and the screen will show you the
exact chain it is generating.

Switching the equalizer off removes the filter rather than flattening it: ten no-op biquads
are still ten biquads in the signal path.

## Desktop media controls (Linux)

PixelPlayer publishes itself over MPRIS2, so the media keys work, and the player shows up
wherever your desktop shows media: GNOME's media widget, KDE's panel, `playerctl`, and the
lockscreen. Play, pause, next, previous, seek, volume and shuffle all come back the other
way.

Nothing to configure — it appears on the session bus as
`org.mpris.MediaPlayer2.pixelplayer` when there is one. No session bus (a bare X session, a
container) and the app carries on without it.

macOS and Windows have their own APIs for this and are not wired up yet.

## Opening files, one window

Double-click an audio file and PixelPlayer plays it. If a copy is already running, the new
launch hands over the files and exits rather than starting a second player — so you get one
window and one thing playing, and the running window comes to the front.

Install the desktop entry (`packaging/install.sh`) for your file manager to offer
PixelPlayer in "Open with". Files given on the command line take priority over the queue you
left behind.

## Tray and notifications

Under Settings → Desktop:

- **Notify on track change** — a popup per track, with Previous/Pause/Next buttons where
  your notification server can draw them. Off by default because your desktop already shows
  what is playing.
- **System tray icon** — on by default. Right-click (or click, depending on your desktop) for
  the current track, Play/Pause, Previous, Next, Show PixelPlayer and Quit. Some desktops have
  no tray at all — GNOME needs the AppIndicator extension — in which case nothing appears.
- **Close to tray** — closing the window keeps the music going. Needs the tray icon, or
  there would be no way back to the window.

## Cast (Chromecast and DLNA)

Settings → Cast finds Chromecast devices and DLNA renderers on your network and sends the
music to one. The speaker fetches the audio from this computer, so both have to be on the
same network — a guest network or an active VPN will hide the device.

While casting, PixelPlayer still runs the show: play, pause, skip and seek from anywhere in
the app drive the speaker, and your local output stays quiet. The queue, shuffle and repeat
are still decided here and each track is handed over as it starts.

What cannot be cast: a Google Drive track, because its URL needs a private header a speaker
cannot be given. Jellyfin and Navidrome sign their stream URLs, so those are passed straight
to the device and nothing is served from here at all.

## Backup and restore

Settings → Backup writes one JSON file with the parts of the app that are yours: playlists,
favourites, lyrics, listening history, search history, music folders, settings, equalizer,
and your remote accounts **without their passwords**. Not the music itself, and never an API
key, a password or a sign-in token — a backup is a file people email to themselves.

Restoring is per section, and it adds rather than replaces: a playlist you already have keeps
its songs and gains the backup's. Songs are recorded by path *and* by their tags, so a backup
restored on another machine still finds most of your library even if the music lives
somewhere else. Anything it cannot find is counted and reported rather than dropped quietly,
and restoring the same file twice will not double your play counts.

## About, updates and diagnostics

Settings → About has the version, the licence of every package the app is built from, and a
button to ask GitHub whether there is a newer release. Startup checks are off by default —
that is the only request this app makes to a server you did not configure.

When there is one, the update can be applied from inside the app: **Download and install**
fetches the release bundle for this platform, unpacks it beside the current install and
renames it into place, then offers to restart. This only happens when this copy was installed
by `install.sh` — a user-owned bundle in `~/.local/lib/com.theveloper.pixelplay_desktop`.
A distribution package, `/usr`, a build directory, Windows and macOS are all refused with the
reason, and the release page is offered instead. Nothing downloads until you press the
button, and only GitHub's own hosts are accepted as a download source.

The swap is safe because it never writes over the running program: the new bundle is
extracted next to the old one, on the same filesystem, and only a rename puts it in place —
so a failed or half-finished download cannot leave a broken install. Renaming and deleting a
running binary is harmless on Unix; overwriting it in place is not.

Diagnostics lists what this machine has and what the app found: libmpv, yt-dlp, TDLib,
whether MPRIS is actually on the session bus, your paths and library counts. Copy it whole
into a bug report. If a remote source is not working, the answer is usually here.

And if you tap the version enough times, there is a game.

## Downloading a Spotify playlist

Settings → Download from Spotify takes a public playlist, album, artist or track link and
keeps the files. It drives [spotdl](https://github.com/spotDL/spotify-downloader), which you
install yourself — the same arrangement as yt-dlp, and for the same reason: YouTube breaks
audio extraction every few weeks and your package manager is better placed to keep up than a
PixelPlayer release.

```bash
pipx install spotdl
```

Be clear about what this is. **Nothing decrypts Spotify** — its audio is protected and never
touched. The playlist's *metadata* is read from Spotify, each track is then found on
**YouTube**, downloaded, and tagged with the Spotify details and cover art. So the tags are
exact and the audio is a match rather than the original master:

- Expect the occasional live take or remix where the match went wrong.
- Quality sits below Spotify's 320 kbps — YouTube music audio is typically 128–160 kbps.
  Choosing M4A keeps the source audio; MP3 transcodes it and loses a little more.
- **A cookies file is usually required.** YouTube refuses most downloads without one, the
  same wall the YouTube Music source hits. The screen reuses whatever cookies you gave that
  source.

Files land in a folder inside your library by default, and the library rescans itself when a
run finishes. A second run only fetches what the playlist gained, unless you ask it to
overwrite.

Downloading copyrighted tracks is likely infringement where you live, and it is against
YouTube's terms of service. Your machine, your call — but note that this feature alone makes
the app ineligible for Flathub, which removes apps whose purpose is downloading copyrighted
media from streaming services.
