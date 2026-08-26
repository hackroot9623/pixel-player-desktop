import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixelplay_desktop/data/models/models.dart';
import 'package:pixelplay_desktop/player/deck_controller.dart';
import 'package:pixelplay_desktop/ui/screens/mashup_screen.dart';

/// The decks themselves need mpv, which a widget test cannot drive. The
/// crossfader curve is the part that decides what you actually hear, and it is
/// pure, so it is the part worth testing.
void main() {
  group('crossfader', () {
    test('hard left is deck A alone', () {
      final gains = crossfaderGains(-1);
      expect(gains.a, 1);
      expect(gains.b, 0);
    });

    test('hard right is deck B alone', () {
      final gains = crossfaderGains(1);
      expect(gains.a, 0);
      expect(gains.b, 1);
    });

    test('centre blends both', () {
      final gains = crossfaderGains(0);
      expect(gains.a, 0.5);
      expect(gains.b, 0.5);
    });

    test('the deck fader scales on top of the crossfader', () {
      // Deck A is at half volume and the crossfader is centred, so it lands at
      // a quarter. Both controls apply, not whichever moved last.
      final gains = crossfaderGains(0, volumeA: 0.5);
      expect(gains.a, 0.25);
      expect(gains.b, 0.5);
    });

    test('a silenced deck stays silent wherever the crossfader is', () {
      for (final position in [-1.0, -0.5, 0.0, 0.5, 1.0]) {
        expect(crossfaderGains(position, volumeA: 0).a, 0);
      }
    });

    test('gains never leave 0..1, even for out-of-range input', () {
      for (final position in [-5.0, -1.0, 0.0, 1.0, 5.0]) {
        final gains = crossfaderGains(position, volumeA: 9, volumeB: -9);
        expect(gains.a, inInclusiveRange(0, 1));
        expect(gains.b, inInclusiveRange(0, 1));
      }
    });

    test('sweeping across moves the balance one way, monotonically', () {
      var previousA = 2.0;
      var previousB = -1.0;
      for (var step = 0; step <= 20; step++) {
        final gains = crossfaderGains(-1 + step * 0.1);
        expect(gains.a, lessThanOrEqualTo(previousA));
        expect(gains.b, greaterThanOrEqualTo(previousB));
        previousA = gains.a;
        previousB = gains.b;
      }
      expect(previousA, 0);
      expect(previousB, 1);
    });

    test('the ported fade is linear, so the centre dips in power', () {
      // Documenting the Android behaviour rather than endorsing it: a
      // constant-power fade would keep a² + b² at 1 through the middle.
      final centre = crossfaderGains(0);
      expect(centre.a + centre.b, 1, reason: 'linear: gains sum to 1');
      expect(
        centre.a * centre.a + centre.b * centre.b,
        lessThan(1),
        reason: 'which means a perceptible dip mid-blend',
      );
    });
  });

  test('deck speed limits match the Android mixer', () {
    expect(minDeckSpeed, 0.5);
    expect(maxDeckSpeed, 2.0);
  });

  group('deck card', () {
    const song = Song(
      id: '/music/a.mp3',
      title: 'A Very Long Track Title That Will Not Fit In A Narrow Deck',
      artist: 'Some Artist With A Long Name Too',
      artistId: 1,
      album: 'Album',
      albumId: 1,
      path: '/music/a.mp3',
      duration: 210000,
    );

    Widget host(Widget child, {double width = 420}) => MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(width: width, child: child),
        ),
      ),
    );

    DeckCard card({Song? track = song, double speed = 1}) => DeckCard(
      label: 'A',
      song: track,
      playing: false,
      position: const Duration(seconds: 30),
      duration: const Duration(milliseconds: 210000),
      progress: 0.25,
      volume: 1,
      speed: speed,
      gain: 0.5,
      onPick: () {},
      onVolume: (_) {},
    );

    // The deck stacks below 900px, so the card has to survive a narrow column.
    for (final width in [320.0, 360.0, 420.0, 600.0, 900.0]) {
      testWidgets('fits at ${width.toInt()}px wide', (tester) async {
        await tester.pumpWidget(host(card(), width: width));
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('an empty deck says so and disables the transport', (
      tester,
    ) async {
      await tester.pumpWidget(host(card(track: null)));
      expect(find.text('No track loaded'), findsOne);
      expect(find.text('Load track'), findsOne);

      // Nothing loaded means nothing to play, seek or nudge.
      for (final icon in [
        Icons.play_arrow_rounded,
        Icons.keyboard_double_arrow_left_rounded,
        Icons.keyboard_double_arrow_right_rounded,
      ]) {
        final button = tester.widget<IconButton>(
          find.ancestor(
            of: find.byIcon(icon),
            matching: find.byType(IconButton),
          ),
        );
        expect(button.onPressed, isNull, reason: '$icon should be disabled');
      }
    });

    testWidgets('a loaded deck shows the track and its position', (
      tester,
    ) async {
      await tester.pumpWidget(host(card()));
      expect(find.text('Deck A'), findsOne);
      expect(find.text('0:30'), findsOne);
      expect(find.text('3:30'), findsOne);
      expect(find.text('Change'), findsOne);
    });

    testWidgets('the speed reset only appears off 1.00x', (tester) async {
      await tester.pumpWidget(host(card()));
      expect(find.byIcon(Icons.restart_alt_rounded), findsNothing);

      await tester.pumpWidget(host(card(speed: 1.5)));
      expect(find.text('1.50×'), findsOne);
      expect(find.byIcon(Icons.restart_alt_rounded), findsOne);
    });
  });
}
