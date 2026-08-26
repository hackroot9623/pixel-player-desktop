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
