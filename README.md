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

## Spotify

Spotify is an **import** source, not a playback source. Their API will tell you
what is in a playlist but never hand over the audio: playback is only possible
through their own SDK, on a Premium account, and that SDK does not exist for
Flutter desktop. So the integration reads your library and pairs each track
with a song you already have.

Set up an app once:

1. Open <https://developer.spotify.com/dashboard> and create an app.
2. Add exactly this redirect URI: `http://127.0.0.1:8888/callback`
3. Copy the client ID into Settings → Spotify. There is no client secret —
   the flow is Authorization Code with PKCE, so nothing secret is shipped.

Connecting opens your browser; the redirect lands on a one-shot loopback server
that closes as soon as the code arrives. The scopes requested are read-only.

Importing a playlist matches every track against your local library by title,
artist and duration, with the noise stripped ("- Remastered 2011", "(feat. X)",
accents). Results come back in three buckets:

- **Imported** — matched confidently.
- **Uncertain** — matched, but something had to be forgiven, usually a duration
  that says this is a different edit. Worth a look.
- **Missing** — nothing close enough. These are reported and never added, so an
  imported playlist never contains rows that will not play.

Spotify supplies an ISRC that would settle a match outright, but the local
library does not store one, so matching stays fuzzy until the scanner reads it.

The refresh token is kept so you do not sign in repeatedly. Spotify rotates it
on every refresh, and it currently lives in `shared_preferences` in plain text —
the same known gap as the other remote credentials.
