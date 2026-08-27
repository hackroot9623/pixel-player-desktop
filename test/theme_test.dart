import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pixelplay_desktop/data/models/models.dart';
import 'package:pixelplay_desktop/data/smart/smart_playlists.dart';
import 'package:pixelplay_desktop/ui/components/library_widgets.dart';
import 'package:pixelplay_desktop/ui/screens/home_screen.dart';
import 'package:pixelplay_desktop/ui/theme/app_theme.dart';
import 'package:pixelplay_desktop/ui/theme/typography.dart';

/// Contrast and theme-switching, checked rather than eyeballed.
///
/// The light theme shipped with text coloured for a container it did not sit
/// on, and labels that kept their old colour across a theme switch. Both look
/// fine in whichever screenshot you happen to take first, so they are asserted
/// here instead.

/// WCAG 2.1 relative luminance.
double _luminance(Color color) {
  double channel(double value) => value <= 0.03928
      ? value / 12.92
      : math.pow((value + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * channel(color.r) +
      0.7152 * channel(color.g) +
      0.0722 * channel(color.b);
}

/// WCAG 2.1 contrast ratio, 1..21.
double contrast(Color foreground, Color background) {
  final a = _luminance(foreground);
  final b = _luminance(background);
  return (math.max(a, b) + 0.05) / (math.min(a, b) + 0.05);
}

/// Flattens a translucent foreground onto an opaque background.
Color composite(Color foreground, Color background) {
  final alpha = foreground.a;
  return Color.from(
    alpha: 1,
    red: foreground.r * alpha + background.r * (1 - alpha),
    green: foreground.g * alpha + background.g * (1 - alpha),
    blue: foreground.b * alpha + background.b * (1 - alpha),
  );
}

/// A muted purple plus saturated extremes, to push the tonal palettes around.
const _seeds = [
  Color(0xFF6C4FF5),
  Color(0xFF2E7D52),
  Color(0xFFB3261E),
  Color(0xFFFFEB3B),
  Color(0xFF000000),
  Color(0xFFFFFFFF),
];

/// WCAG AA for body text, and for large text (the hero greeting is 50px).
const _minBody = 4.5;
const _minLarge = 3.0;

void main() {
  void forEachTheme(void Function(ThemeData theme, String label) body) {
    for (final brightness in Brightness.values) {
      for (final variant in DynamicSchemeVariant.values) {
        for (final seed in _seeds) {
          body(
            buildTheme(brightness: brightness, seed: seed, variant: variant),
            '${brightness.name}/${variant.name}/'
            '${seed.toARGB32().toRadixString(16)}',
          );
        }
      }
    }
  }

  group('switching theme', () {
    /// Reads the colours a label in the body of the app actually resolves to.
    Future<({Color title, Color body, Color surface})> resolve(
      WidgetTester tester,
      ThemeMode mode,
    ) async {
      late ThemeData seen;
      await tester.pumpWidget(
        MaterialApp(
          themeMode: mode,
          theme: buildTheme(
            brightness: Brightness.light,
            seed: const Color(0xFF6C4FF5),
          ),
          darkTheme: buildTheme(
            brightness: Brightness.dark,
            seed: const Color(0xFF6C4FF5),
          ),
          home: Builder(
            builder: (context) {
              seen = Theme.of(context);
              return const Scaffold(body: Text('Al Sudeste'));
            },
          ),
        ),
      );
      // MaterialApp animates between themes, so settle before reading.
      await tester.pumpAndSettle();
      return (
        title: seen.textTheme.titleSmall!.color!,
        body: seen.textTheme.bodySmall!.color!,
        surface: seen.colorScheme.surface,
      );
    }

    testWidgets('labels follow the theme from light to dark', (tester) async {
      final light = await resolve(tester, ThemeMode.light);
      final dark = await resolve(tester, ThemeMode.dark);

      // The bug: labels kept their light-mode colour after the switch, leaving
      // near-black text on a near-black surface.
      expect(
        dark.title,
        isNot(light.title),
        reason: 'the title colour must change with the theme',
      );
      expect(
        contrast(dark.title, dark.surface),
        greaterThanOrEqualTo(_minBody),
        reason: 'title on the dark surface',
      );
      expect(
        contrast(dark.body, dark.surface),
        greaterThanOrEqualTo(_minBody),
        reason: 'secondary line on the dark surface',
      );
    });

    testWidgets('and back from dark to light', (tester) async {
      final dark = await resolve(tester, ThemeMode.dark);
      final light = await resolve(tester, ThemeMode.light);
      expect(light.title, isNot(dark.title));
      expect(
        contrast(light.title, light.surface),
        greaterThanOrEqualTo(_minBody),
      );
    });

    testWidgets('a live toggle repaints the labels, not just the surface', (
      tester,
    ) async {
      // Toggling within one widget tree, which is what the settings screen
      // does — a fresh pumpWidget would hide a staleness bug.
      var mode = ThemeMode.light;
      late StateSetter setMode;
      late ThemeData seen;

      await tester.pumpWidget(
        StatefulBuilder(
          builder: (context, setState) {
            setMode = setState;
            return MaterialApp(
              themeMode: mode,
              theme: buildTheme(
                brightness: Brightness.light,
                seed: const Color(0xFF6C4FF5),
              ),
              darkTheme: buildTheme(
                brightness: Brightness.dark,
                seed: const Color(0xFF6C4FF5),
              ),
              home: Builder(
                builder: (inner) {
                  seen = Theme.of(inner);
                  return const Scaffold(body: Text('Al Sudeste'));
                },
              ),
            );
          },
        ),
      );
      await tester.pumpAndSettle();
      final before = seen.textTheme.titleSmall!.color!;

      setMode(() => mode = ThemeMode.dark);
      await tester.pumpAndSettle();
      final after = seen.textTheme.titleSmall!.color!;

      expect(after, isNot(before));
      expect(
        contrast(after, seen.colorScheme.surface),
        greaterThanOrEqualTo(_minBody),
        reason: 'after toggling to dark, the label must read on the surface',
      );
    });
  });

  group('text on its own surface', () {
    test('primary and secondary body text clear AA', () {
      forEachTheme((theme, label) {
        final scheme = theme.colorScheme;
        expect(
          contrast(scheme.onSurface, scheme.surface),
          greaterThanOrEqualTo(_minBody),
          reason: 'onSurface on surface — $label',
        );
        expect(
          contrast(scheme.onSurfaceVariant, scheme.surface),
          greaterThanOrEqualTo(_minBody),
          reason: 'onSurfaceVariant on surface — $label',
        );
      });
    });

    test('text on every container role clears AA', () {
      forEachTheme((theme, label) {
        final scheme = theme.colorScheme;
        final pairs = <String, (Color, Color)>{
          'surfaceContainer': (scheme.onSurface, scheme.surfaceContainer),
          'surfaceContainerHigh': (
            scheme.onSurface,
            scheme.surfaceContainerHigh,
          ),
          'surfaceContainerHighest': (
            scheme.onSurface,
            scheme.surfaceContainerHighest,
          ),
          'primaryContainer': (
            scheme.onPrimaryContainer,
            scheme.primaryContainer,
          ),
          'secondaryContainer': (
            scheme.onSecondaryContainer,
            scheme.secondaryContainer,
          ),
          'primary': (scheme.onPrimary, scheme.primary),
          'errorContainer': (scheme.onErrorContainer, scheme.errorContainer),
        };
        pairs.forEach((role, pair) {
          expect(
            contrast(pair.$1, pair.$2),
            greaterThanOrEqualTo(_minBody),
            reason: '$role — $label',
          );
        });
      });
    });
  });

  group('artwork-tinted tiles', () {
    // Recently-played tiles take their colour from the track's own cover, via
    // that scheme's secondaryContainer. Both lines have to hold up against it.
    test('both lines of a tinted tile clear AA', () {
      forEachTheme((theme, label) {
        final scheme = theme.colorScheme;
        final tile = scheme.secondaryContainer;
        expect(
          contrast(scheme.onSecondaryContainer, tile),
          greaterThanOrEqualTo(_minBody),
          reason: 'tile title — $label',
        );
        expect(
          contrast(
            composite(
              scheme.onSecondaryContainer.withValues(alpha: 0.85),
              tile,
            ),
            tile,
          ),
          greaterThanOrEqualTo(_minLarge),
          reason: 'tile artist line at 85% — $label',
        );
      });
    });

    test('a tinted tile is distinguishable from the page behind it', () {
      // The point of tinting rather than outlining: the tile separates from the
      // surface on its own.
      forEachTheme((theme, label) {
        final scheme = theme.colorScheme;
        expect(
          contrast(scheme.secondaryContainer, scheme.surface),
          greaterThanOrEqualTo(1.08),
          reason: 'tile against page — $label',
        );
      });
    });
  });

  group('home banner', () {
    // The stops the banner actually draws, not a copy of the maths.
    List<Color> stops(ColorScheme scheme) => bannerGradient(scheme);

    test('the greeting reads on every part of the gradient', () {
      forEachTheme((theme, label) {
        final scheme = theme.colorScheme;
        for (final stop in stops(scheme)) {
          expect(
            contrast(scheme.onSurface, stop),
            // 50px counts as large text under WCAG, so 3:1 is the bar.
            greaterThanOrEqualTo(_minLarge),
            reason: 'greeting on gradient stop — $label',
          );
        }
      });
    });

    test('the song count under it reads too', () {
      forEachTheme((theme, label) {
        final scheme = theme.colorScheme;
        for (final stop in stops(scheme)) {
          expect(
            contrast(scheme.onSurfaceVariant, stop),
            // 14px: normal text, so the full 4.5:1.
            greaterThanOrEqualTo(_minBody),
            reason: 'subtitle on gradient stop — $label',
          );
        }
      });
    });

    test('onPrimaryContainer would not have read there', () {
      // Guards the original bug: the greeting used onPrimaryContainer, which is
      // only guaranteed against primaryContainer itself.
      final scheme = buildTheme(
        brightness: Brightness.light,
        seed: const Color(0xFF2E7D52),
      ).colorScheme;
      final faded = bannerGradient(scheme).first;
      expect(
        contrast(scheme.onPrimaryContainer, faded),
        lessThan(contrast(scheme.onSurface, faded)),
      );
    });
  });

  group('fixed-height cards', () {
    // A type change of two pixels a line put every "Made for you" card into
    // overflow, because the row height had no slack over its contents. The
    // labels are what grow, so the cards are checked at the heights the
    // screens actually give them.
    Song song(String id) => Song(
      id: id,
      title: 'Track',
      artist: 'Artist',
      artistId: 1,
      album: 'Album',
      albumId: 1,
      path: id,
      duration: 200000,
    );

    Widget host(Widget child, {required double height, required Brightness b}) =>
        ProviderScope(
          child: MaterialApp(
            theme: buildTheme(
              brightness: b,
              seed: const Color(0xFF6C4FF5),
            ),
            home: Scaffold(
              body: Center(
                child: SizedBox(height: height, child: child),
              ),
            ),
          ),
        );

    // 228 is what library_screen gives the row; the rest are heights a tighter
    // layout could hand it. The artwork shrinks instead of overflowing, so all
    // of them have to come out clean.
    for (final brightness in Brightness.values) {
      for (final height in [140.0, 180.0, 198.0, 210.0, 228.0, 300.0]) {
        testWidgets(
          'a smart playlist card fits ${height.toInt()}px (${brightness.name})',
          (tester) async {
            await tester.pumpWidget(
              host(
                SmartPlaylistCard(
                  rule: SmartPlaylistRule.forgottenFavorites,
                  songs: [for (var i = 0; i < 4; i++) song('/m/$i.mp3')],
                ),
                height: height,
                b: brightness,
              ),
            );
            expect(tester.takeException(), isNull);
          },
        );
      }
    }

    testWidgets('and the tallest label text still fits', (tester) async {
      // The longest rule title and a four-digit song count, since the labels
      // are the part that grows.
      await tester.pumpWidget(
        host(
          SmartPlaylistCard(
            rule: SmartPlaylistRule.forgottenFavorites,
            songs: [for (var i = 0; i < 1234; i++) song('/m/$i.mp3')],
          ),
          height: 228,
          b: Brightness.dark,
        ),
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('typography', () {
    test('the expressive titles use the bundled font, not a downloaded one', () {
      // These were Montserrat via google_fonts, which fetches over the network
      // and falls back silently to a platform face offline — so the hero title
      // rendered in an unpredictable font at an unreadably light weight.
      for (final style in [expDisplayLarge, expDisplayMedium, expTitleMedium]) {
        expect(style.fontFamily, googleSansRounded);
        expect(
          style.fontWeight!.value,
          greaterThanOrEqualTo(FontWeight.w600.value),
          reason: 'a 50px hero needs weight behind it',
        );
      }
    });

    test('small text is heavy enough to read on a desktop', () {
      expect(appTextTheme.bodySmall!.fontSize, greaterThanOrEqualTo(13));
      expect(
        appTextTheme.bodySmall!.fontWeight!.value,
        greaterThanOrEqualTo(FontWeight.w500.value),
      );
      expect(
        appTextTheme.titleSmall!.fontWeight!.value,
        greaterThanOrEqualTo(FontWeight.w600.value),
      );
    });

    test('the variable font axes are actually set', () {
      // fontWeight alone does nothing to a variable font: the weight axis has to
      // be in fontVariations, and ROND is what makes it the rounded cut.
      final variations = appTextTheme.titleSmall!.fontVariations!;
      expect(variations.any((v) => v.axis == 'wght' && v.value >= 600), isTrue);
      expect(variations.any((v) => v.axis == 'ROND' && v.value == 100), isTrue);
    });
  });
}
