import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

/// Proves libmpv is actually wired up and decoding: without this, a broken
/// audio backend only shows up as silence at runtime.
///
/// Needs one playable file: `MUSIC_FILE=/path/to/track.mp3`.
void main() {
  test('media_kit decodes a local file and advances position', () async {
    final path = Platform.environment['MUSIC_FILE'];
    if (path == null || !File(path).existsSync()) {
      markTestSkipped('set MUSIC_FILE to a playable audio file');
      return;
    }
    MediaKit.ensureInitialized();
    final player = Player();
    addTearDown(player.dispose);

    await player.setVolume(0);
    await player.open(Playlist([Media('file://${Uri.encodeFull(path)}')]));

    final duration = await player.stream.duration.firstWhere(
      (d) => d > Duration.zero,
    );
    expect(duration, greaterThan(Duration.zero));

    final advanced = await player.stream.position.firstWhere(
      (p) => p > const Duration(milliseconds: 300),
    );
    expect(advanced, greaterThan(const Duration(milliseconds: 300)));

    await player.seek(const Duration(milliseconds: 100));
    await player.pause();
    // `state` is the last emitted value; `stream.playing.first` would hang
    // waiting for the *next* broadcast event.
    expect(player.state.playing, isFalse);
  }, timeout: const Timeout(Duration(seconds: 30)));
}
