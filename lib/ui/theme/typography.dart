import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Ported from `ui/theme/Type.kt`.
///
/// The Android app renders everything in Google Sans Flex with the rounded
/// (`ROND`) axis pinned to 100, which reads as Google Sans Rounded. The same
/// variable font ships in `assets/fonts/gflex_variable.ttf`, so we reproduce it
/// exactly instead of approximating with a static family.
const _rond = FontVariation('ROND', 100);
const googleSansRounded = 'GoogleSansFlex';
const genreFontFamily = 'GenreVariable';

List<FontVariation> _variations(FontWeight weight) => [
  FontVariation.weight(weight.value.toDouble()),
  _rond,
];

TextStyle rounded({
  required FontWeight weight,
  required double size,
  double? height,
  double letterSpacing = 0,
}) => TextStyle(
  fontFamily: googleSansRounded,
  fontWeight: weight,
  fontVariations: _variations(weight),
  fontSize: size,
  height: height == null ? null : height / size,
  letterSpacing: letterSpacing,
);

/// `Typography` from Type.kt, sp -> logical pixels 1:1.
final appTextTheme = TextTheme(
  displayLarge: rounded(weight: FontWeight.w700, size: 48, height: 56),
  displayMedium: rounded(weight: FontWeight.w700, size: 36, height: 44),
  displaySmall: rounded(weight: FontWeight.w400, size: 30, height: 38),
  headlineLarge: rounded(weight: FontWeight.w600, size: 32, height: 40),
  headlineMedium: rounded(weight: FontWeight.w600, size: 28, height: 36),
  headlineSmall: rounded(weight: FontWeight.w600, size: 24, height: 32),
  titleLarge: rounded(weight: FontWeight.w400, size: 22, height: 28),
  titleMedium: rounded(
    weight: FontWeight.w500,
    size: 18,
    height: 24,
    letterSpacing: 0.15,
  ),
  titleSmall: rounded(
    weight: FontWeight.w500,
    size: 14,
    height: 20,
    letterSpacing: 0.1,
  ),
  bodyLarge: rounded(
    weight: FontWeight.w400,
    size: 16,
    height: 24,
    letterSpacing: 0.5,
  ),
  bodyMedium: rounded(
    weight: FontWeight.w400,
    size: 14,
    height: 20,
    letterSpacing: 0.25,
  ),
  bodySmall: rounded(
    weight: FontWeight.w400,
    size: 12,
    height: 16,
    letterSpacing: 0.4,
  ),
  labelLarge: rounded(
    weight: FontWeight.w500,
    size: 16,
    height: 20,
    letterSpacing: 0.1,
  ),
  labelMedium: rounded(
    weight: FontWeight.w500,
    size: 14,
    height: 16,
    letterSpacing: 0.5,
  ),
  labelSmall: rounded(
    weight: FontWeight.w500,
    size: 11,
    height: 16,
    letterSpacing: 0.5,
  ),
);

/// `ExpTitleTypography` from Type.kt — Montserrat, used for the oversized
/// expressive screen titles. The Android app stretches the glyphs horizontally
/// (`TextGeometricTransform(scaleX)`); we apply the same via a Transform on the
/// widget side where it matters, keeping the metrics here.
final expDisplayLarge = GoogleFonts.montserrat(
  fontWeight: FontWeight.w600,
  fontSize: 60,
  letterSpacing: -0.02 * 60,
  height: 0.95,
);

final expDisplayMedium = GoogleFonts.montserrat(
  fontWeight: FontWeight.w400,
  fontSize: 50,
  letterSpacing: -0.02 * 50,
  height: 0.95,
);

final expTitleMedium = GoogleFonts.montserrat(
  fontWeight: FontWeight.w700,
  fontSize: 32,
  letterSpacing: -0.02 * 32,
  height: 0.95,
);

/// Horizontal stretch factors from `TextGeometricTransform(scaleX = …)`.
const expDisplayLargeScaleX = 1.5;
const expTitleMediumScaleX = 1.3;
