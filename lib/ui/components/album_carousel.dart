import 'package:flutter/material.dart';

import '../../data/models/models.dart';
import '../../data/prefs/settings.dart' show CarouselStyle;
import 'album_art.dart';

/// Port of `AlbumCarouselSection` + `RoundedParallaxCarousell`.
///
/// The Kotlin file vendors a whole copy of Material 3's multi-browse carousel
/// (keylines, shift steps, snap positions — 1500 lines) to get rounded
/// clipping. Flutter ships that layout as `CarouselView.weighted`, so this is
/// the same design expressed through the framework: one item per queue entry,
/// neighbours peeking in according to the user's carousel style, and the
/// "pause squish" scale from `FullPlayerAlbumCoverSection`.
///
/// Deliberately presentational — it takes the queue rather than reading the
/// player — so it can be rendered (and regression-tested) without an audio
/// device.
class AlbumCarousel extends StatefulWidget {
  const AlbumCarousel({
    super.key,
    required this.height,
    required this.songs,
    required this.index,
    required this.playing,
    required this.style,
    required this.onTapCurrent,
    required this.onTapOther,
  });

  final double height;
  final List<Song> songs;
  final int index;
  final bool playing;
  final CarouselStyle style;

  /// Tapping the centre item opens its album, matching `onAlbumClick`.
  final ValueChanged<Song> onTapCurrent;

  /// Tapping a peeking neighbour jumps the queue to it (`onSongSelected`).
  final ValueChanged<int> onTapOther;

  @override
  State<AlbumCarousel> createState() => _AlbumCarouselState();
}

class _AlbumCarouselState extends State<AlbumCarousel> {
  /// One controller for the widget's lifetime.
  ///
  /// Creating (or disposing) it in `build` crashed the engine: `CarouselView`
  /// keeps a reference and reads `controller.position` from
  /// `didUpdateWidget`, so a swapped-in controller was always detached, and
  /// disposing the old one mid-frame left dangling dependents behind.
  late final CarouselController _controller = CarouselController(
    initialItem: _safeIndex,
  );

  /// The queue can be edited (a track removed, the queue replaced) between the
  /// player updating its index and this widget rebuilding, so the incoming
  /// index is not always in range. An out-of-range `initialItem` puts the
  /// carousel at a scroll offset with nothing in it — a blank player.
  int get _safeIndex =>
      widget.songs.isEmpty ? 0 : widget.index.clamp(0, widget.songs.length - 1);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(AlbumCarousel old) {
    super.didUpdateWidget(old);
    // Follow the playing track when it changes underneath us — mpv advanced, or
    // the user picked something elsewhere.
    //
    // Deliberately not resyncing when only the queue contents change:
    // CarouselView already re-lays-out for a new child list, and forcing a
    // scroll on top of that fought it and landed on the wrong item.
    if (widget.index != old.index && _controller.hasClients) {
      _controller.animateToItem(
        _safeIndex,
        duration: const Duration(milliseconds: 380),
        curve: Curves.easeOutCubic,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.songs.isEmpty) return SizedBox(height: widget.height);

    return TweenAnimationBuilder<double>(
      // 0.95 while paused — `albumArtScale`, 260 ms FastOutSlowIn.
      tween: Tween(end: widget.playing ? 1.0 : 0.95),
      duration: const Duration(milliseconds: 260),
      curve: Curves.fastOutSlowIn,
      builder: (context, scale, child) =>
          Transform.scale(scale: scale, child: child),
      child: SizedBox(
        height: widget.height,
        child: CarouselView.weighted(
          controller: _controller,
          // Identity-stable const list; see CarouselStyle.flexWeights.
          flexWeights: widget.style.flexWeights,
          // Must stay true (the default). With it false the layout cannot
          // scroll far enough for the last items to reach the primary slot, so
          // the playing track ended up rendered in the narrow peek slot while
          // a neighbour got the big one.
          consumeMaxWeight: true,
          itemSnapping: true,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(28)),
          ),
          backgroundColor: Colors.transparent,
          padding: const EdgeInsets.symmetric(horizontal: 4),
          onTap: (index) => index == widget.index
              ? widget.onTapCurrent(widget.songs[index])
              : widget.onTapOther(index),
          children: [
            for (final (i, song) in widget.songs.indexed)
              AlbumArt(
                path: song.albumArtPath,
                radius: 28,
                heroTag: i == widget.index ? 'now-playing-art' : null,
              ),
          ],
        ),
      ),
    );
  }
}
