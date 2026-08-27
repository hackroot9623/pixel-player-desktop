import 'package:flutter_test/flutter_test.dart';
import 'package:pixelplay_desktop/player/equalizer.dart';

/// The equalizer is a string generator: whatever mpv is handed is the whole
/// behaviour, so that string is what these tests read. No audio device needed.

void main() {
  group('bands', () {
    test('the frequencies match the phone, band for band', () {
      // A preset has to sound like the same preset on both, which only holds if
      // the centres are the same.
      expect(equalizerFrequencies, [
        31,
        62,
        125,
        250,
        500,
        1000,
        2000,
        4000,
        8000,
        16000,
      ]);
      expect(equalizerBandCount, 10);
    });

    test('labels shorten the thousands', () {
      expect(equalizerBandLabel(0), '31');
      expect(equalizerBandLabel(5), '1k');
      expect(equalizerBandLabel(9), '16k');
    });

    test('a state always has one gain per band', () {
      expect(EqualizerState().gains, hasLength(10));
      // Too few, and the rest are flat; too many, and the extras are ignored.
      expect(EqualizerState(gains: const [3, 3]).gains, hasLength(10));
      expect(EqualizerState(gains: const [3, 3]).gains.last, 0);
      expect(
        EqualizerState(gains: List.filled(40, 2)).gains,
        hasLength(10),
      );
    });

    test('gains are clamped to the usable range', () {
      final state = EqualizerState(gains: const [99, -99, 0, 0, 0, 0, 0, 0, 0, 0]);
      expect(state.gains[0], equalizerMaxGain);
      expect(state.gains[1], equalizerMinGain);
    });

    test('setting one band leaves the others alone', () {
      final state = EqualizerState(enabled: true).withGain(3, 6);
      expect(state.gains[3], 6);
      expect(state.gains.where((g) => g != 0), hasLength(1));
    });

    test('a band outside the range is ignored, not an error', () {
      final state = EqualizerState();
      expect(state.withGain(-1, 5).gains, state.gains);
      expect(state.withGain(99, 5).gains, state.gains);
    });
  });

  group('presets', () {
    test('all ten from the phone are here', () {
      expect(EqualizerPreset.all, hasLength(10));
      expect(
        EqualizerPreset.all.map((p) => p.name),
        containsAll([
          'flat',
          'rock',
          'pop',
          'hip_hop',
          'jazz',
          'classical',
          'electronic',
          'bass_boost',
          'treble_boost',
          'vocal',
        ]),
      );
    });

    test('each preset has a gain for every band, in range', () {
      for (final preset in EqualizerPreset.all) {
        expect(preset.gains, hasLength(equalizerBandCount), reason: preset.name);
        for (final gain in preset.gains) {
          expect(gain, inInclusiveRange(equalizerMinGain, equalizerMaxGain));
        }
      }
    });

    test('the curves are the phone\'s values', () {
      // Spot-checked against EqualizerPreset.kt rather than re-derived.
      expect(EqualizerPreset.rock.gains, [5, 4, 3, 1, -1, -1, 1, 3, 4, 5]);
      expect(EqualizerPreset.vocal.gains, [-3, -2, -1, 2, 5, 6, 5, 3, 1, 0]);
      expect(EqualizerPreset.flat.gains.every((g) => g == 0), isTrue);
    });

    test('an unknown name falls back to flat', () {
      expect(EqualizerPreset.byName('nonsense').name, 'flat');
      expect(EqualizerPreset.byName('rock').name, 'rock');
    });

    test('a curve is recognised as the preset it equals', () {
      expect(
        EqualizerState(gains: EqualizerPreset.jazz.gains).preset?.name,
        'jazz',
      );
    });

    test('a curve of your own is not any preset', () {
      final state = EqualizerState(
        gains: EqualizerPreset.jazz.gains,
      ).withGain(0, 15);
      expect(state.preset, isNull);
    });

    test('applying a preset replaces the whole curve', () {
      final state = EqualizerState(
        enabled: true,
      ).withGain(9, 12).withPreset(EqualizerPreset.pop);
      expect(state.gains, EqualizerPreset.pop.gains);
    });
  });

  group('the filter mpv is given', () {
    test('a disabled equalizer produces nothing', () {
      // Not a flat curve: ten no-op biquads are still ten biquads in the path.
      final state = EqualizerState(gains: EqualizerPreset.rock.gains);
      expect(state.enabled, isFalse);
      expect(state.filter, isEmpty);
    });

    test('an enabled but flat equalizer produces nothing either', () {
      expect(EqualizerState(enabled: true).filter, isEmpty);
      expect(EqualizerState(enabled: true).isNeutral, isTrue);
    });

    test('one raised band becomes one biquad at that frequency', () {
      final filter = EqualizerState(enabled: true).withGain(5, 4).filter;
      expect(filter, 'lavfi=[equalizer=f=1000:width_type=o:width=2:g=4]');
    });

    test('a cut band carries its negative gain', () {
      final filter = EqualizerState(enabled: true).withGain(0, -6).filter;
      expect(filter, contains('f=31'));
      expect(filter, contains('g=-6'));
    });

    test('only the bands that do something appear', () {
      // Rock touches every band except none — vocal leaves the last one flat.
      final filter = EqualizerState(
        enabled: true,
      ).withPreset(EqualizerPreset.vocal).filter;
      expect('equalizer='.allMatches(filter), hasLength(9));
      expect(filter, isNot(contains('f=16000')));
    });

    test('a full preset becomes one chained lavfi graph', () {
      final filter = EqualizerState(
        enabled: true,
      ).withPreset(EqualizerPreset.rock).filter;

      expect(filter, startsWith('lavfi=['));
      expect(filter, endsWith(']'));
      expect('equalizer='.allMatches(filter), hasLength(10));
      // Chained, not separate filters, or only the last would apply.
      expect(filter.split(',').length, 10);
    });

    test('the bands come out in frequency order', () {
      final filter = EqualizerState(
        enabled: true,
      ).withPreset(EqualizerPreset.rock).filter;
      expect(filter.indexOf('f=31'), lessThan(filter.indexOf('f=1000')));
      expect(filter.indexOf('f=1000'), lessThan(filter.indexOf('f=16000')));
    });

    test('bass boost is a shelf, not another band', () {
      // Android's BassBoost lifts everything under a corner rather than peaking
      // at one frequency.
      final filter = EqualizerState(
        enabled: true,
        bassBoost: 100,
      ).filter;
      expect(filter, contains('bass=g=12:f=100'));
      expect(filter, isNot(contains('equalizer=')));
    });

    test('stereo width stays inside a sane range', () {
      // Past about 2.0 extrastereo sounds hollow rather than wide.
      expect(
        EqualizerState(enabled: true, virtualizer: 1).filter,
        contains('extrastereo=m=1.01'),
      );
      expect(
        EqualizerState(enabled: true, virtualizer: 100).filter,
        contains('extrastereo=m=1.80'),
      );
    });

    test('levelling is dynaudnorm, not loudnorm', () {
      // loudnorm wants two passes over a whole file, which a live stream cannot
      // give it.
      final filter = EqualizerState(enabled: true, loudness: 50).filter;
      expect(filter, contains('dynaudnorm=g='));
      expect(filter, isNot(contains('loudnorm')));
    });

    test('the levelling window is always odd', () {
      // ffmpeg rounds an even window up itself and logs "filter size N is
      // invalid", so an even value is not fatal — it just means the filter is
      // not running with the value it was given. Verified against mpv 0.40.
      for (var strength = 1; strength <= 100; strength++) {
        final filter = EqualizerState(
          enabled: true,
          loudness: strength,
        ).filter;
        final window = int.parse(
          RegExp(r'dynaudnorm=g=(\d+)').firstMatch(filter)!.group(1)!,
        );
        expect(window.isOdd, isTrue, reason: 'strength $strength → $window');
        expect(window, inInclusiveRange(3, 301));
      }
    });

    test('an effect at zero adds nothing', () {
      final filter = EqualizerState(
        enabled: true,
        bassBoost: 0,
        virtualizer: 0,
        loudness: 30,
      ).filter;
      expect(filter, isNot(contains('bass=')));
      expect(filter, isNot(contains('extrastereo')));
      expect(filter, contains('dynaudnorm'));
    });

    test('effects sit after the bands', () {
      final filter = EqualizerState(
        enabled: true,
        gains: EqualizerPreset.rock.gains,
        bassBoost: 50,
        virtualizer: 50,
        loudness: 50,
      ).filter;
      expect(filter.indexOf('equalizer='), lessThan(filter.indexOf('bass=')));
      expect(filter.indexOf('bass='), lessThan(filter.indexOf('extrastereo')));
      expect(
        filter.indexOf('extrastereo'),
        lessThan(filter.indexOf('dynaudnorm')),
      );
    });

    test('effects alone still count as something to do', () {
      final state = EqualizerState(enabled: true, bassBoost: 40);
      expect(state.isNeutral, isFalse);
      expect(state.filter, isNotEmpty);
    });

    test('the chain never contains an unbalanced bracket', () {
      // A malformed graph makes mpv reject the whole thing silently.
      for (final preset in EqualizerPreset.all) {
        final filter = EqualizerState(
          enabled: true,
          gains: preset.gains,
          bassBoost: 25,
          virtualizer: 25,
          loudness: 25,
        ).filter;
        expect('['.allMatches(filter), hasLength(1), reason: preset.name);
        expect(']'.allMatches(filter), hasLength(1), reason: preset.name);
        expect(filter, isNot(contains(',]')));
        expect(filter, isNot(contains('[,')));
      }
    });
  });

  group('effect strengths', () {
    test('they are clamped to 0..100', () {
      final state = EqualizerState().copyWith(
        bassBoost: 400,
        virtualizer: -20,
        loudness: 101,
      );
      expect(state.bassBoost, 100);
      expect(state.virtualizer, 0);
      expect(state.loudness, 100);
    });
  });

  group('storage', () {
    test('a setting round-trips', () {
      final state = EqualizerState(
        enabled: true,
        gains: EqualizerPreset.electronic.gains,
        bassBoost: 30,
        virtualizer: 40,
        loudness: 50,
      );
      final restored = EqualizerState.decode(state.encode());

      expect(restored.enabled, isTrue);
      expect(restored.gains, state.gains);
      expect(restored.bassBoost, 30);
      expect(restored.virtualizer, 40);
      expect(restored.loudness, 50);
      // The point of the round trip: the same sound comes back.
      expect(restored.filter, state.filter);
    });

    test('nothing stored yet means off and flat', () {
      final state = EqualizerState.decode(null);
      expect(state.enabled, isFalse);
      expect(state.isNeutral, isTrue);
      expect(EqualizerState.decode('').isNeutral, isTrue);
    });

    test('a corrupt setting does not stop the player starting', () {
      // Falling back to off is the one behaviour that cannot make things worse.
      expect(EqualizerState.decode('not json').enabled, isFalse);
      expect(EqualizerState.decode('[1,2,3]').enabled, isFalse);
      expect(EqualizerState.decode('{"gains":"nonsense"}').isNeutral, isTrue);
    });

    test('out-of-range stored values are brought back in', () {
      final state = EqualizerState.decode(
        '{"enabled":true,"gains":[99,0,0,0,0,0,0,0,0,0],"bassBoost":900}',
      );
      expect(state.gains.first, equalizerMaxGain);
      expect(state.bassBoost, 100);
    });
  });
}
