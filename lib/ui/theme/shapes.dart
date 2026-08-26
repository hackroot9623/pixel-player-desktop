import 'package:flutter/material.dart';

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
