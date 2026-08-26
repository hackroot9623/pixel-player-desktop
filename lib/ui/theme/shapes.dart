import 'package:flutter/material.dart';

import '../../data/models/models.dart';

/// Ported from `ui/theme/Shape.kt`.
const shapeSmall = 8.0;
const shapeMedium = 16.0;
const shapeLarge = 24.0;

const smallShape = RoundedRectangleBorder(
  borderRadius: BorderRadius.all(Radius.circular(shapeSmall)),
);
const mediumShape = RoundedRectangleBorder(
  borderRadius: BorderRadius.all(Radius.circular(shapeMedium)),
);
const largeShape = RoundedRectangleBorder(
  borderRadius: BorderRadius.all(Radius.circular(shapeLarge)),
);

/// The Android app leans on `AbsoluteSmoothCornerShape` (a squircle with a
/// tunable "smoothness" percentage) for the player transport, toggle rows and
/// playlist covers. Flutter's [RoundedSuperellipseBorder] draws the same
/// continuous-curvature corner, so smooth corners come from the framework
/// rather than a hand-rolled path.
///
/// Every Kotlin call site passes `smoothnessAsPercent = 60`, which is what the
/// superellipse produces by construction — there is no knob to carry over.
ShapeBorder smoothCorner(double radius) =>
    RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(radius));

/// Ported from `utils/shapes/PolygonShape.kt` and the hexagon / triangle
/// helpers in `utils/shapes/OtherShapes.kt`. Flutter's [StarBorder.polygon]
/// covers the whole family, so the port is a parameter mapping instead of six
/// bespoke `Shape` classes.
ShapeBorder polygonShape({
  required int sides,
  double rotation = 0,
  double cornerRounding = 0,
}) => StarBorder.polygon(
  sides: sides.clamp(3, 24).toDouble(),
  rotation: rotation,
  pointRounding: cornerRounding.clamp(0, 1),
);

/// Ported from `utils/shapes/RoundedStarShape.kt`. `curve` there controls how
/// deep the valleys cut in, which maps onto [StarBorder.innerRadiusRatio].
ShapeBorder roundedStarShape({
  int points = 5,
  double curve = 0.09,
  double rotation = 0,
  double pointRounding = 0.3,
}) => StarBorder(
  points: points.clamp(3, 24).toDouble(),
  rotation: rotation,
  innerRadiusRatio: (1 - curve * 4).clamp(0.1, 0.9),
  pointRounding: pointRounding.clamp(0, 1),
  valleyRounding: pointRounding.clamp(0, 1) * 0.6,
);

/// Ported from `PlaylistShapeType` in `data/model/PlayList.kt`, used by the
/// playlist cover editor.
ShapeBorder playlistShape(
  PlaylistShapeType type, {
  double cornerRadius = shapeLarge,
  double detail = 0.09,
  double rotation = 0,
}) => switch (type) {
  PlaylistShapeType.circle => const CircleBorder(),
  PlaylistShapeType.smoothRect => smoothCorner(cornerRadius),
  PlaylistShapeType.rotatedPill => const StadiumBorder(),
  PlaylistShapeType.star => roundedStarShape(curve: detail, rotation: rotation),
};

PlaylistShapeType playlistShapeFromName(String? name) => switch (name) {
  'Circle' => PlaylistShapeType.circle,
  'RotatedPill' => PlaylistShapeType.rotatedPill,
  'Star' => PlaylistShapeType.star,
  _ => PlaylistShapeType.smoothRect,
};
