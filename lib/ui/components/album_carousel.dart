import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/providers.dart';
import '../navigation.dart';
import 'album_art.dart';

/// Port of `AlbumCarouselSection` + `RoundedParallaxCarousell`.
///
/// The Kotlin file vendors a whole copy of Material 3's multi-browse carousel
/// (keylines, shift steps, snap positions — 1500 lines) to get rounded
/// clipping. Flutter ships that layout as `CarouselView.weighted`, so this is
/// the same design expressed through the framework: one item per queue entry,
/// neighbours peeking in according to the user's carousel style, and the
/// "pause squish" scale from `FullPlayerAlbumCoverSection`.
class AlbumCarousel extends ConsumerStatefulWidget {
  const AlbumCarousel({super.key, required this.height});

  final double height;

  @override
  ConsumerState<AlbumCarousel> createState() => _AlbumCarouselState();
}

class _AlbumCarouselState extends ConsumerState<AlbumCarousel> {
  CarouselController? _controller;
  int _attachedIndex = -1;

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final player = ref.watch(playerProvider);
    final style = ref.watch(settingsProvider).carouselStyle;
    final queue = player.queue;
    if (queue.isEmpty) return SizedBox(height: widget.height);

    // Rebuild the controller when the playing index changes underneath us
    // (mpv advanced, or the user picked a track elsewhere) so the carousel
    // scrolls to the new track.
    if (_attachedIndex != player.index) {
      _attachedIndex = player.index;
      _controller?.dispose();
      _controller = CarouselController(initialItem: player.index);
    }

    return TweenAnimationBuilder<double>(
      // 0.95 while paused — `albumArtScale`, 260 ms FastOutSlowIn.
      tween: Tween(end: player.playing ? 1.0 : 0.95),
      duration: const Duration(milliseconds: 260),
      curve: Curves.fastOutSlowIn,
      builder: (context, scale, child) =>
          Transform.scale(scale: scale, child: child),
      child: SizedBox(
        height: widget.height,
        child: CarouselView.weighted(
          controller: _controller,
          flexWeights: [for (final w in style.flexWeights) w.round()],
          consumeMaxWeight: false,
          itemSnapping: true,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(28)),
          ),
          backgroundColor: Colors.transparent,
          padding: const EdgeInsets.symmetric(horizontal: 4),
          onTap: (index) {
            // Tapping the centre item opens its album; tapping a peeking
            // neighbour jumps the queue to it, matching `onSongSelected`.
            if (index == player.index) {
              openAlbum(context, queue[index].albumId);
            } else {
              player.jumpTo(index);
            }
          },
          children: [
            for (final song in queue)
              AlbumArt(
                path: song.albumArtPath,
                radius: 28,
                heroTag: song.id == player.current?.id
                    ? 'now-playing-art'
                    : null,
              ),
          ],
        ),
      ),
    );
  }
}
