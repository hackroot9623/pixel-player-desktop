import 'package:flutter/material.dart';

import 'colors.dart';
import 'shapes.dart';
import 'typography.dart';

/// Ported from `ui/theme/Theme.kt` + `ColorRoles.kt`.
///
/// Android derives the scheme from (1) an album-art override, (2) Material You
/// wallpaper colors, (3) the hand-written fallback. Desktop has no wallpaper
/// palette API, so the order here is album-art override -> user seed -> fallback.
ThemeData buildTheme({
  required Brightness brightness,
  ColorScheme? schemeOverride,
  Color? seed,
  DynamicSchemeVariant variant = DynamicSchemeVariant.tonalSpot,
}) {
  final scheme =
      schemeOverride ??
      (seed != null
          ? ColorScheme.fromSeed(
              seedColor: seed,
              brightness: brightness,
              dynamicSchemeVariant: variant,
            )
          : (brightness == Brightness.dark
                ? darkColorScheme
                : lightColorScheme));

  final light = scheme.brightness == Brightness.light;

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    textTheme: appTextTheme.apply(
      bodyColor: scheme.onSurface,
      displayColor: scheme.onSurface,
    ),
    // InkSparkle needs the `shaders/ink_sparkle.frag` asset, which the Linux
    // embedder does not ship — it throws on the first splash. InkRipple is the
    // closest thing that works everywhere.
    splashFactory: InkRipple.splashFactory,
    cardTheme: CardThemeData(
      shape: largeShape,
      clipBehavior: Clip.antiAlias,
      elevation: 0,
      color: scheme.surfaceContainerLow,
      margin: EdgeInsets.zero,
    ),
    dialogTheme: DialogThemeData(
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(28)),
      ),
      backgroundColor: scheme.surfaceContainerHigh,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: const StadiumBorder(),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(shape: const CircleBorder()),
    ),
    listTileTheme: const ListTileThemeData(shape: mediumShape),
    navigationRailTheme: NavigationRailThemeData(
      // Same colour as the scaffold left the rail with no edge at all in light
      // mode; one step of tone separates it without a divider.
      backgroundColor: light ? scheme.surfaceContainerLow : scheme.surface,
      indicatorColor: scheme.secondaryContainer,
      labelType: NavigationRailLabelType.all,
      selectedLabelTextStyle: appTextTheme.labelMedium?.copyWith(
        color: scheme.onSurface,
      ),
      unselectedLabelTextStyle: appTextTheme.labelMedium?.copyWith(
        color: scheme.onSurfaceVariant,
      ),
    ),
    sliderTheme: SliderThemeData(
      trackHeight: 6,
      activeTrackColor: scheme.primary,
      inactiveTrackColor: scheme.surfaceContainerHighest,
      thumbColor: scheme.primary,
      overlayShape: SliderComponentShape.noOverlay,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: scheme.inverseSurface,
      contentTextStyle: appTextTheme.bodyMedium?.copyWith(
        color: scheme.onInverseSurface,
      ),
      shape: mediumShape,
    ),
    tooltipTheme: const TooltipThemeData(waitDuration: Duration(seconds: 1)),
    dividerTheme: DividerThemeData(color: scheme.outlineVariant, space: 1),
    tabBarTheme: TabBarThemeData(
      dividerColor: Colors.transparent,
      indicatorSize: TabBarIndicatorSize.tab,
      labelStyle: appTextTheme.titleSmall,
      unselectedLabelStyle: appTextTheme.titleSmall,
    ),
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.linux: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.windows: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.macOS: FadeForwardsPageTransitionsBuilder(),
      },
    ),
  );
}
