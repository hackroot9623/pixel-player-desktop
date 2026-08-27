import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';

import 'album_art.dart' show isNetworkArtwork;

/// Port of `presentation/components/AlbumArtCollage` + `CollagePatterns` +
/// `utils/shapes/RoundedStarShape`.
///
/// Album covers scattered across two bands in Material's shape vocabulary —
/// circles, pills, squircles and rounded stars. Purely decorative here: the
/// Android version makes each cover tappable, the desktop banner does not.

/// A shape a cover can be clipped to. Kept as data rather than a `ShapeBorder`
/// so the patterns below stay `const`-friendly tables.
sealed class CollageShape {
  const CollageShape();

  Path pathFor(Size size);
}

class CircleCollageShape extends CollageShape {
  const CircleCollageShape();

  @override
  Path pathFor(Size size) =>
      Path()..addOval(Rect.fromLTWH(0, 0, size.width, size.height));
}

/// `RoundedCornerShape`. A corner given as a percentage is elliptical per axis
/// in Compose, which is what makes the 50% case a pill rather than a circle.
class RoundedRectCollageShape extends CollageShape {
  const RoundedRectCollageShape.radius(double this.cornerRadius)
    : percent = null;

  const RoundedRectCollageShape.percent(int this.percent) : cornerRadius = null;

  final double? cornerRadius;
  final int? percent;

  @override
  Path pathFor(Size size) {
    final rect = Rect.fromLTWH(0, 0, size.width, size.height);
    final radius = percent != null
        ? Radius.elliptical(
            size.width * percent! / 100,
            size.height * percent! / 100,
          )
        : Radius.circular(cornerRadius!);
    return Path()..addRRect(RRect.fromRectAndRadius(rect, radius));
  }
}

/// `RoundedStarShape`, ported point for point: a polar curve sampled at
/// `iterations` steps. [curve] is the spikiness, 0..1.
class StarCollageShape extends CollageShape {
  const StarCollageShape({
    required this.sides,
    this.curve = 0.09,
    this.rotation = 0,
    this.iterations = 360,
  });

  final int sides;
  final double curve;
  final double rotation;
  final int iterations;

  @override
  Path pathFor(Size size) {
    const twoPi = 2 * pi;
    final steps = twoPi / min(iterations, 360);
    final rotationRadians = (pi / 180) * rotation;

    // The Kotlin maps `curve` through mapRange(1, 0, 0.5, 1) so a spikier star
    // keeps roughly the same visual mass.
    final radius =
        min(size.height, size.width) * 0.4 * ((1 - curve) * 0.5 + 0.5);
    final centerX = size.width * 0.5;
    final centerY = size.height * 0.5;

    Offset pointAt(double t) {
      final scale = 1 + curve * cos(sides * t);
      return Offset(
        (radius * cos(t - rotationRadians) * scale + centerX),
        (radius * sin(t - rotationRadians) * scale + centerY),
      );
    }

    final path = Path()..moveTo(pointAt(0).dx, pointAt(0).dy);
    for (var t = steps; t < twoPi; t += steps) {
      final point = pointAt(t);
      path.lineTo(point.dx, point.dy);
    }
    return path..close();
  }
}

/// One cover's placement. `Config` in the Kotlin, minus its `size` field —
/// nothing ever read it there, width/height did the work.
class CollageConfig {
  const CollageConfig({
    required this.width,
    required this.height,
    required this.alignment,
    required this.rotation,
    required this.shape,
    this.offsetX = 0,
    this.offsetY = 0,
  });

  final double width;
  final double height;
  final Alignment alignment;

  /// Degrees, clockwise.
  final double rotation;
  final CollageShape shape;
  final double offsetX;
  final double offsetY;
}

/// Port of `data/preferences/CollagePattern`.
enum CollagePattern {
  cosmicSwirl('cosmic_swirl', 'Cosmic Swirl'),
  honeycombGroove('honeycomb_groove', 'Honeycomb Groove'),
  vinylStack('vinyl_stack', 'Vinyl Stack'),
  pixelMosaic('pixel_mosaic', 'Pixel Mosaic'),
  stardustScatter('stardust_scatter', 'Stardust Scatter');

  const CollagePattern(this.storageKey, this.label);

  final String storageKey;
  final String label;

  static const CollagePattern defaultPattern = CollagePattern.cosmicSwirl;

  static CollagePattern fromStorageKey(String? value) {
    for (final pattern in values) {
      if (pattern.storageKey == value) return pattern;
    }
    return defaultPattern;
  }
}

/// Six placements per pattern: the first three occupy the upper band, the rest
/// the lower one.
///
/// [min] scales every shape, [boxHeight] and [nominalWidth] scale the offsets.
/// The Kotlin hard-codes `300.dp` where [nominalWidth] appears, since on a
/// phone the collage is always about that wide; on desktop the banner is not,
/// so it is passed in.
List<CollageConfig> buildCollageConfigs(
  CollagePattern pattern, {
  required double min,
  required double boxHeight,
  required double nominalWidth,
}) => switch (pattern) {
  CollagePattern.cosmicSwirl => [
    CollageConfig(
      width: min * 0.48,
      height: min * 0.8,
      alignment: Alignment.center,
      rotation: 45,
      shape: const RoundedRectCollageShape.percent(50),
    ),
    CollageConfig(
      width: min * 0.24,
      height: min * 0.24,
      alignment: Alignment.topLeft,
      rotation: 0,
      shape: const CircleCollageShape(),
      offsetX: nominalWidth * 0.05,
      offsetY: boxHeight * 0.05,
    ),
    CollageConfig(
      width: min * 0.24,
      height: min * 0.24,
      alignment: Alignment.bottomRight,
      rotation: 0,
      shape: const CircleCollageShape(),
      offsetX: -nominalWidth * 0.05,
      offsetY: -boxHeight * 0.05,
    ),
    CollageConfig(
      width: min * 0.35,
      height: min * 0.35,
      alignment: Alignment.topLeft,
      rotation: -20,
      shape: const RoundedRectCollageShape.radius(20),
      offsetX: nominalWidth * 0.1,
      offsetY: boxHeight * 0.1,
    ),
    CollageConfig(
      width: min * 0.9,
      height: min * 0.9,
      alignment: Alignment.bottomRight,
      rotation: 0,
      shape: const StarCollageShape(sides: 6, curve: 0.09, rotation: 45),
      offsetX: 42,
    ),
  ],
  CollagePattern.honeycombGroove => [
    CollageConfig(
      width: min * 0.7,
      height: min * 0.7,
      alignment: Alignment.center,
      rotation: 0,
      shape: const StarCollageShape(sides: 6, curve: 0.05),
    ),
    CollageConfig(
      width: min * 0.22,
      height: min * 0.22,
      alignment: Alignment.topRight,
      rotation: 15,
      shape: const RoundedRectCollageShape.radius(16),
      offsetX: -nominalWidth * 0.03,
      offsetY: boxHeight * 0.04,
    ),
    CollageConfig(
      width: min * 0.18,
      height: min * 0.18,
      alignment: Alignment.bottomLeft,
      rotation: 0,
      shape: const CircleCollageShape(),
      offsetX: nominalWidth * 0.04,
      offsetY: -boxHeight * 0.04,
    ),
    CollageConfig(
      width: min * 0.55,
      height: min * 0.55,
      alignment: Alignment.bottomLeft,
      rotation: -10,
      shape: const StarCollageShape(sides: 6, curve: 0.05, rotation: 30),
      offsetX: nominalWidth * 0.02,
      offsetY: -boxHeight * 0.02,
    ),
    CollageConfig(
      width: min * 0.42,
      height: min * 0.55,
      alignment: Alignment.topRight,
      rotation: 30,
      shape: const RoundedRectCollageShape.percent(50),
      offsetX: -nominalWidth * 0.06,
      offsetY: boxHeight * 0.03,
    ),
  ],
  CollagePattern.vinylStack => [
    CollageConfig(
      width: min * 0.55,
      height: min * 0.55,
      alignment: Alignment.centerLeft,
      rotation: 0,
      shape: const CircleCollageShape(),
      offsetX: nominalWidth * 0.02,
    ),
    CollageConfig(
      width: min * 0.38,
      height: min * 0.38,
      alignment: Alignment.centerRight,
      rotation: 0,
      shape: const CircleCollageShape(),
      offsetX: -nominalWidth * 0.04,
      offsetY: -boxHeight * 0.08,
    ),
    CollageConfig(
      width: min * 0.15,
      height: min * 0.15,
      alignment: Alignment.topRight,
      rotation: -45,
      shape: const RoundedRectCollageShape.percent(50),
      offsetX: -nominalWidth * 0.02,
      offsetY: boxHeight * 0.43,
    ),
    CollageConfig(
      width: min * 0.5,
      height: min * 0.5,
      alignment: Alignment.center,
      rotation: 0,
      shape: const CircleCollageShape(),
      offsetX: 70,
      offsetY: -boxHeight * 0.02,
    ),
    CollageConfig(
      width: min * 0.35,
      height: min * 0.35,
      alignment: Alignment.bottomLeft,
      rotation: 0,
      shape: const StarCollageShape(sides: 8, curve: 0.06, rotation: 22),
      offsetX: nominalWidth * 0.05,
      offsetY: -boxHeight * 0.03,
    ),
  ],
  CollagePattern.pixelMosaic => [
    CollageConfig(
      width: min * 0.42,
      height: min * 0.65,
      alignment: Alignment.topLeft,
      rotation: 0,
      shape: const RoundedRectCollageShape.radius(24),
      offsetX: nominalWidth * 0.03,
      offsetY: boxHeight * 0.02,
    ),
    CollageConfig(
      width: min * 0.52,
      height: min * 0.42,
      alignment: Alignment.topRight,
      rotation: 8,
      shape: const RoundedRectCollageShape.radius(20),
      offsetX: -nominalWidth * 0.04,
      offsetY: boxHeight * 0.06,
    ),
    CollageConfig(
      width: min * 0.52,
      height: min * 0.12,
      alignment: Alignment.bottomRight,
      rotation: -5,
      shape: const RoundedRectCollageShape.radius(12),
      offsetX: -nominalWidth * 0.06,
      offsetY: -boxHeight * 0.05,
    ),
    CollageConfig(
      width: min * 0.42,
      height: min * 0.52,
      alignment: Alignment.bottomRight,
      rotation: -12,
      shape: const RoundedRectCollageShape.radius(28),
      offsetX: -nominalWidth * 0.02,
      offsetY: -boxHeight * 0.02,
    ),
    CollageConfig(
      width: min * 0.50,
      height: min * 0.48,
      alignment: Alignment.topLeft,
      rotation: 5,
      shape: const RoundedRectCollageShape.radius(16),
      offsetX: nominalWidth * 0.04,
      offsetY: boxHeight * 0.04,
    ),
  ],
  CollagePattern.stardustScatter => [
    CollageConfig(
      width: min * 0.65,
      height: min * 0.65,
      alignment: Alignment.center,
      rotation: 10,
      shape: const StarCollageShape(sides: 5, curve: 0.12),
    ),
    CollageConfig(
      width: min * 0.22,
      height: min * 0.22,
      alignment: Alignment.topLeft,
      rotation: 0,
      shape: const CircleCollageShape(),
      offsetX: nominalWidth * 0.04,
      offsetY: boxHeight * 0.03,
    ),
    CollageConfig(
      width: min * 0.26,
      height: min * 0.26,
      alignment: Alignment.bottomRight,
      rotation: 0,
      shape: const StarCollageShape(sides: 4, curve: 0.18, rotation: 45),
      offsetX: -nominalWidth * 0.06,
    ),
    CollageConfig(
      width: min * 0.5,
      height: min * 0.5,
      alignment: Alignment.centerRight,
      rotation: -15,
      shape: const StarCollageShape(sides: 8, curve: 0.04),
      offsetX: -nominalWidth * 0.04,
    ),
    CollageConfig(
      width: min * 0.5,
      height: min * 0.42,
      alignment: Alignment.bottomLeft,
      rotation: 25,
      shape: const RoundedRectCollageShape.percent(50),
      offsetX: nominalWidth * 0.06,
      offsetY: -boxHeight * 0.03,
    ),
  ],
};

/// Album covers scattered in Material shapes.
///
/// Presentational: it takes artwork paths, not songs or providers, so the
/// layout can be tested without a library behind it. Decorative, so it is
/// wrapped in [IgnorePointer] — the covers here are not controls.
class AlbumArtScatter extends StatelessWidget {
  const AlbumArtScatter({
    super.key,
    required this.artworkPaths,
    this.pattern = CollagePattern.defaultPattern,
    this.opacity = 1,
  });

  /// Up to six covers, most recent first. Nulls and short lists are fine:
  /// missing covers simply leave their slot empty.
  final List<String?> artworkPaths;
  final CollagePattern pattern;

  /// The banner runs it below full strength so the greeting stays readable.
  final double opacity;

  @override
  Widget build(BuildContext context) {
    if (artworkPaths.isEmpty) return const SizedBox.shrink();

    return IgnorePointer(
      child: Opacity(
        opacity: opacity,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final boxWidth = constraints.maxWidth;
            final boxHeight = constraints.maxHeight;
            if (!boxWidth.isFinite || !boxHeight.isFinite) {
              return const SizedBox.shrink();
            }

            // The phone version is a tall 400dp block against min=300, so the
            // shapes are sized at roughly three quarters of the box. A desktop
            // banner is wide and short, so the tighter axis has to drive it —
            // the tallest shape is 0.8 of the scale and lives in a band 0.6 of
            // the height, which is what the 0.75 keeps it inside.
            final scale = min(300.0, min(boxWidth * 0.72, boxHeight * 0.75));
            final configs = buildCollageConfigs(
              pattern,
              min: scale,
              boxHeight: boxHeight,
              nominalWidth: min(300.0, boxWidth),
            );

            // Two bands, 60/40, so the upper shapes cannot land on the lower.
            return Column(
              children: [
                SizedBox(
                  height: boxHeight * 0.6,
                  width: boxWidth,
                  child: _Band(
                    configs: configs.take(3).toList(),
                    artworkPaths: artworkPaths,
                    startIndex: 0,
                  ),
                ),
                SizedBox(
                  height: boxHeight * 0.4,
                  width: boxWidth,
                  child: _Band(
                    configs: configs.skip(3).toList(),
                    artworkPaths: artworkPaths,
                    startIndex: 3,
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _Band extends StatelessWidget {
  const _Band({
    required this.configs,
    required this.artworkPaths,
    required this.startIndex,
  });

  final List<CollageConfig> configs;
  final List<String?> artworkPaths;
  final int startIndex;

  @override
  Widget build(BuildContext context) => Stack(
    clipBehavior: Clip.none,
    children: [
      for (var i = 0; i < configs.length; i++)
        if (startIndex + i < artworkPaths.length)
          Align(
            alignment: configs[i].alignment,
            child: Transform.translate(
              offset: Offset(configs[i].offsetX, configs[i].offsetY),
              child: Transform.rotate(
                angle: configs[i].rotation * pi / 180,
                child: _Cover(
                  path: artworkPaths[startIndex + i],
                  config: configs[i],
                ),
              ),
            ),
          ),
    ],
  );
}

class _Cover extends StatelessWidget {
  const _Cover({required this.path, required this.config});

  final String? path;
  final CollageConfig config;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: config.width,
      height: config.height,
      child: ClipPath(
        clipper: _ShapeClipper(config.shape),
        child: ColoredBox(
          color: scheme.surfaceContainerHigh,
          child: switch (path) {
            null => null,
            // Remote covers are URLs; local ones are files.
            final value when isNetworkArtwork(value) => Image.network(
              value,
              fit: BoxFit.cover,
              errorBuilder: (context, _, _) => const SizedBox.shrink(),
            ),
            final value => Image.file(
              File(value),
              fit: BoxFit.cover,
              // A cover that vanished since the scan should leave the shape
              // standing, not throw an exception into the banner.
              errorBuilder: (context, _, _) => const SizedBox.shrink(),
            ),
          },
        ),
      ),
    );
  }
}

class _ShapeClipper extends CustomClipper<Path> {
  const _ShapeClipper(this.shape);

  final CollageShape shape;

  @override
  Path getClip(Size size) => shape.pathFor(size);

  @override
  bool shouldReclip(_ShapeClipper oldClipper) => oldClipper.shape != shape;
}
