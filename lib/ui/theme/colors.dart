import 'package:flutter/material.dart';

/// Ported from `ui/theme/Color.kt`.
const pixelPlayPurpleDark = Color(0xFF1E1234);
const pixelPlayPurplePrimary = Color(0xFFAB47BC);
const pixelPlayPink = Color(0xFFF06292);
const pixelPlayOrange = Color(0xFFFF8A65);
const pixelPlayLightPurple = Color(0xFFE1BEE7);
const pixelPlayWhite = Color(0xFFFFFFFF);
const pixelPlayBlack = Color(0xFF000000);
const pixelPlaySurface = Color(0xFF2A1F40);

const lightBackground = Color(0xFFF7F2FF);
const lightSurface = Color(0xFFFBF8FF);
const lightSurfaceVariant = Color(0xFFE8DEF9);
const lightOnSurface = Color(0xFF1E1237);
const lightOnSurfaceVariant = Color(0xFF4D4165);
const lightPrimary = Color(0xFF6C4FF5);
const lightPrimaryContainer = Color(0xFFE3DBFF);
const lightOnPrimaryContainer = Color(0xFF23005C);
const lightOutline = Color(0xFF78659A);

/// Default seed used when no album-art palette is active. Matches the
/// light-theme primary of the Android app.
const defaultSeedColor = lightPrimary;

/// Ported from `ui/theme/Theme.kt` — the hand-written fallback schemes used when
/// dynamic color is unavailable.
final darkColorScheme = ColorScheme.fromSeed(
  seedColor: pixelPlayPurplePrimary,
  brightness: Brightness.dark,
).copyWith(
  primary: pixelPlayPurplePrimary,
  secondary: pixelPlayPink,
  tertiary: pixelPlayOrange,
  surface: pixelPlaySurface,
  onPrimary: pixelPlayWhite,
  onSecondary: pixelPlayWhite,
  onTertiary: pixelPlayWhite,
  onSurface: pixelPlayLightPurple,
  error: const Color(0xFFFF5252),
  onError: pixelPlayWhite,
);

final lightColorScheme = ColorScheme.fromSeed(
  seedColor: lightPrimary,
).copyWith(
  primary: lightPrimary,
  onPrimary: pixelPlayWhite,
  primaryContainer: lightPrimaryContainer,
  onPrimaryContainer: lightOnPrimaryContainer,
  secondary: pixelPlayPink,
  onSecondary: pixelPlayWhite,
  secondaryContainer: pixelPlayPink.withValues(alpha: 0.15),
  onSecondaryContainer: pixelPlayPink.withValues(alpha: 0.85),
  tertiary: pixelPlayOrange,
  onTertiary: pixelPlayBlack,
  surface: lightSurface,
  onSurface: lightOnSurface,
  surfaceContainerHighest: lightSurfaceVariant,
  onSurfaceVariant: lightOnSurfaceVariant,
  outline: lightOutline,
  outlineVariant: lightOutline.withValues(alpha: 0.6),
  surfaceTint: lightPrimary,
  error: const Color(0xFFD32F2F),
  onError: pixelPlayWhite,
);
