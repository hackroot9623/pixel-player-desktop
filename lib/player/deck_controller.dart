import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

import '../data/models/models.dart' show Song;

// Ported from `MashupViewModel` + its `DeckController`: the two-deck mixer.
//
// Each deck is its own decoder, entirely separate from the main player, so
// mixing does not disturb what is in the queue. They are created when the
// mixer screen opens and released when it closes — two extra mpv instances is
// not something to keep alive for a feature nobody is looking at.

/// Speed limits from the Kotlin `setSpeed`.
const minDeckSpeed = 0.5;
const maxDeckSpeed = 2.0;

/// How far a nudge moves the deck. Used to slide one track against the other
/// until the beats line up.
const deckNudge = Duration(milliseconds: 250);

/// Per-deck gain from the crossfader position, ported from
/// `updateCrossfaderAndVolumes`.
///
/// [crossfader] runs -1 (deck A only) to +1 (deck B only). Pure, because the
/// curve is the one thing here worth testing without an audio device.
///
/// Note this reproduces the Android app's *linear* fade: at the centre both
/// decks sit at 0.5, which dips the perceived loudness through the middle of a
/// blend. A constant-power curve would hold it, but that would be a different
/// mixer from the one being ported.
({double a, double b}) crossfaderGains(
  double crossfader, {
  double volumeA = 1,
  double volumeB = 1,
}) {
  final position = ((crossfader.clamp(-1.0, 1.0)) + 1) / 2;
  return (
    a: (volumeA.clamp(0.0, 1.0) * (1 - position)).clamp(0.0, 1.0),
    b: (volumeB.clamp(0.0, 1.0) * position).clamp(0.0, 1.0),
  );
}

/// One deck: a song, a transport, and its own speed and volume.
class DeckController extends ChangeNotifier {
  DeckController() {
    _player = Player(
      configuration: const PlayerConfiguration(title: 'PixelPlayer deck'),
    );
    _subs.addAll([
      _player.stream.playing.listen((value) {
        _playing = value;
        notifyListeners();
      }),
      _player.stream.position.listen((value) {
        _position = value;
        notifyListeners();
      }),
      _player.stream.duration.listen((value) {
        _duration = value;
        notifyListeners();
      }),
    ]);
  }

  late final Player _player;
  final _subs = <StreamSubscription<Object?>>[];

  Song? _song;
  bool _playing = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  double _volume = 1;
  double _speed = 1;

  Song? get song => _song;
  bool get playing => _playing;
  Duration get position => _position;
  Duration get duration => _duration;

  /// The deck's own fader, before the crossfader is applied.
  double get volume => _volume;
  double get speed => _speed;
  bool get loaded => _song != null;

  double get progress {
    final total = _duration.inMilliseconds;
    if (total <= 0) return 0;
    return (_position.inMilliseconds / total).clamp(0.0, 1.0);
  }

  Future<void> load(Song song) async {
    _song = song;
    notifyListeners();
    await _player.open(
      Media('file://${Uri.encodeFull(song.path)}'),
      play: false,
    );
    // A newly loaded deck keeps the speed the DJ had dialled in.
    await _player.setRate(_speed);
  }

  Future<void> playPause() =>
      _song == null ? Future.value() : _player.playOrPause();

  Future<void> seekToFraction(double fraction) {
    final total = _duration.inMilliseconds;
    if (total <= 0) return Future.value();
    return _player.seek(
      Duration(milliseconds: (total * fraction.clamp(0.0, 1.0)).round()),
    );
  }

  /// Slides the deck by a small amount, for lining up beats by ear.
  Future<void> nudge(Duration amount) {
    if (_song == null) return Future.value();
    final target = _position + amount;
    return _player.seek(
      target < Duration.zero
          ? Duration.zero
          : (target > _duration ? _duration : target),
    );
  }

  Future<void> setSpeed(double speed) async {
    _speed = speed.clamp(minDeckSpeed, maxDeckSpeed);
    notifyListeners();
    await _player.setRate(_speed);
  }

  /// Sets the deck's own fader. The audible level also depends on the
  /// crossfader, so the mixer re-applies both.
  void setVolume(double volume) {
    _volume = volume.clamp(0.0, 1.0);
    notifyListeners();
  }

  /// Applies the final gain, deck fader and crossfader combined.
  Future<void> applyGain(double gain) =>
      _player.setVolume((gain.clamp(0.0, 1.0) * 100));

  @override
  void dispose() {
    for (final sub in _subs) {
      sub.cancel();
    }
    _player.dispose();
    super.dispose();
  }
}

/// The mixer: two decks and the crossfader between them.
class MashupController extends ChangeNotifier {
  MashupController() {
    // Any deck change can alter the mix, so re-apply the gains.
    deckA.addListener(_onDeckChanged);
    deckB.addListener(_onDeckChanged);
    _applyGains();
  }

  final DeckController deckA = DeckController();
  final DeckController deckB = DeckController();

  double _crossfader = 0;

  /// -1 is deck A alone, +1 is deck B alone, 0 is both.
  double get crossfader => _crossfader;

  void setCrossfader(double value) {
    _crossfader = value.clamp(-1.0, 1.0);
    _applyGains();
    notifyListeners();
  }

  void setDeckVolume(DeckController deck, double volume) {
    deck.setVolume(volume);
    _applyGains();
  }

  ({double a, double b}) get gains => crossfaderGains(
    _crossfader,
    volumeA: deckA.volume,
    volumeB: deckB.volume,
  );

  void _onDeckChanged() => notifyListeners();

  void _applyGains() {
    final current = gains;
    deckA.applyGain(current.a);
    deckB.applyGain(current.b);
  }

  @override
  void dispose() {
    deckA.removeListener(_onDeckChanged);
    deckB.removeListener(_onDeckChanged);
    deckA.dispose();
    deckB.dispose();
    super.dispose();
  }
}
