import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixelplay_desktop/ui/components/collage.dart';

void main() {
  group('shapes', () {
    const size = Size(120, 80);

    test('a circle fills its box', () {
      final bounds = const CircleCollageShape().pathFor(size).getBounds();
      expect(bounds, const Rect.fromLTWH(0, 0, 120, 80));
    });

    test('a 50% corner is a pill, elliptical per axis like Compose', () {
      // A circular 50% radius would round to min(w,h)/2 and leave straight
      // edges; Compose scales each axis, which is what makes it read as a pill.
      final path = const RoundedRectCollageShape.percent(50).pathFor(size);
      expect(path.getBounds(), const Rect.fromLTWH(0, 0, 120, 80));
      // Mid-height on the left edge is inside a pill but outside a rectangle
      // with circular corners of radius 40.
      expect(path.contains(const Offset(1, 40)), isTrue);
      // The corner itself is cut away.
      expect(path.contains(const Offset(1, 1)), isFalse);
    });

    test('a rounded rectangle keeps its corners inside the box', () {
      final path = const RoundedRectCollageShape.radius(20).pathFor(size);
      expect(path.getBounds(), const Rect.fromLTWH(0, 0, 120, 80));
      expect(path.contains(const Offset(60, 40)), isTrue, reason: 'centre');
      expect(path.contains(const Offset(0.5, 0.5)), isFalse, reason: 'corner');
    });

    group('star', () {
      test('stays within its box and is centred', () {
        const shape = StarCollageShape(sides: 6, curve: 0.09, rotation: 45);
        final bounds = shape.pathFor(size).getBounds();
        expect(bounds.left, greaterThanOrEqualTo(0));
        expect(bounds.top, greaterThanOrEqualTo(0));
        expect(bounds.right, lessThanOrEqualTo(120));
        expect(bounds.bottom, lessThanOrEqualTo(80));
        // Drawn around the box centre, per the Kotlin.
        expect(bounds.center.dx, closeTo(60, 0.5));
        expect(bounds.center.dy, closeTo(40, 0.5));
      });

      test('a spikier curve reaches further than a gentle one', () {
        double reach(double curve) => StarCollageShape(sides: 6, curve: curve)
            .pathFor(const Size(100, 100))
            .getBounds()
            .width;
        expect(reach(0.18), greaterThan(reach(0.04)));
      });

      test('the number of sides shows up as that many lobes', () {
        // Sampling the radius around the curve should peak once per side.
        for (final sides in [4, 5, 6, 8]) {
          final path = StarCollageShape(
            sides: sides,
            curve: 0.12,
          ).pathFor(const Size(200, 200));
          final metric = path.computeMetrics().single;
          final radii = [
            for (var i = 0; i < 720; i++)
              (metric
                          .getTangentForOffset(metric.length * i / 720)!
                          .position -
                      const Offset(100, 100))
                  .distance,
          ];
          var peaks = 0;
          for (var i = 0; i < radii.length; i++) {
            final previous = radii[(i - 1 + radii.length) % radii.length];
            final next = radii[(i + 1) % radii.length];
            if (radii[i] > previous && radii[i] >= next) peaks++;
          }
          expect(peaks, sides, reason: '$sides-sided star');
        }
      });
    });
  });

  group('patterns', () {
    test('every pattern places the same number of covers', () {
      for (final pattern in CollagePattern.values) {
        final configs = buildCollageConfigs(
          pattern,
          min: 300,
          boxHeight: 400,
          nominalWidth: 300,
        );
        // Three in the upper band, two in the lower — as in the Kotlin, which
        // holds six covers but only ever positions five.
        expect(configs, hasLength(5), reason: pattern.label);
      }
    });

    test('shapes are sized within the scale they are given', () {
      for (final pattern in CollagePattern.values) {
        final configs = buildCollageConfigs(
          pattern,
          min: 300,
          boxHeight: 400,
          nominalWidth: 300,
        );
        for (final config in configs) {
          expect(config.width, inExclusiveRange(0, 300));
          expect(config.height, inExclusiveRange(0, 300));
        }
      }
    });

    test('storage keys round-trip, and an unknown key falls back', () {
      for (final pattern in CollagePattern.values) {
        expect(CollagePattern.fromStorageKey(pattern.storageKey), pattern);
      }
      expect(
        CollagePattern.fromStorageKey('nonsense'),
        CollagePattern.defaultPattern,
      );
      expect(CollagePattern.fromStorageKey(null), CollagePattern.cosmicSwirl);
    });
  });

  group('scatter', () {
    Widget host(
      List<String?> paths, {
      CollagePattern pattern = CollagePattern.defaultPattern,
      Size size = const Size(420, 260),
    }) => MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: size.width,
            height: size.height,
            child: AlbumArtScatter(artworkPaths: paths, pattern: pattern),
          ),
        ),
      ),
    );

    testWidgets('nothing played yet means nothing drawn', (tester) async {
      await tester.pumpWidget(host(const []));
      expect(find.byType(ClipPath), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('it is decoration, not a control', (tester) async {
      await tester.pumpWidget(host(List.filled(6, null)));
      expect(
        find.descendant(
          of: find.byType(AlbumArtScatter),
          matching: find.byWidgetPredicate(
            (widget) => widget is IgnorePointer && widget.ignoring,
          ),
        ),
        findsOne,
      );
      // Nothing inside it should be tappable: the banner covers are not
      // buttons. Scoped to the scatter, since Scaffold brings its own.
      final inside = find.descendant(
        of: find.byType(AlbumArtScatter),
        matching: find.byType(GestureDetector),
      );
      expect(inside, findsNothing);
      expect(
        find.descendant(
          of: find.byType(AlbumArtScatter),
          matching: find.byType(InkWell),
        ),
        findsNothing,
      );
    });

    testWidgets('every pattern draws its five shapes at banner size', (
      tester,
    ) async {
      for (final pattern in CollagePattern.values) {
        await tester.pumpWidget(host(List.filled(6, null), pattern: pattern));
        expect(find.byType(ClipPath), findsNWidgets(5), reason: pattern.label);
        expect(tester.takeException(), isNull, reason: pattern.label);
      }
    });

    testWidgets('a short history only fills the slots it can', (tester) async {
      await tester.pumpWidget(host(const [null, null]));
      expect(find.byType(ClipPath), findsNWidgets(2));
    });

    // The banner is the one place this renders, and it resizes with the window.
    for (final width in [200.0, 320.0, 420.0, 900.0]) {
      testWidgets('survives a ${width.toInt()}px-wide banner', (tester) async {
        await tester.pumpWidget(
          host(List.filled(6, null), size: Size(width, 260)),
        );
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('unbounded height does not throw', (tester) async {
      // A Column or ListView parent would hand it infinite height; better to
      // draw nothing than to assert in the middle of the home screen.
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView(
              children: const [
                AlbumArtScatter(artworkPaths: [null, null, null]),
              ],
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
    });
  });
}
