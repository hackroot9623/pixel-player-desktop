import 'dart:convert';

// The equalizer, as an mpv audio filter chain.
//
// Android had three separate system effects to drive — `Equalizer`, `BassBoost`,
// `Virtualizer` and `LoudnessEnhancer` from `android.media.audiofx`. Desktop has
// no such service, but mpv carries ffmpeg's filters, so the same four controls
// become one filter string: a biquad per band, plus a low shelf, a stereo
// widener and a dynamic normaliser.
//
// The band frequencies, the ±15 dB range and the ten presets are the Android
// app's, so a preset sounds like the same preset.
//
// Everything here is pure: [EqualizerState.filter] is a string, and a string can
// be tested without an audio device.

/// The ISO band centres, matching `EqualizerPreset.BAND_FREQUENCIES`.
const equalizerFrequencies = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000];

/// Gain limits in dB, matching Android's normalised −15..+15 range.
const equalizerMinGain = -15;
const equalizerMaxGain = 15;

int get equalizerBandCount => equalizerFrequencies.length;

/// A band's label, short enough for a slider.
String equalizerBandLabel(int index) {
  final hz = equalizerFrequencies[index];
  return hz >= 1000 ? '${hz ~/ 1000}k' : '$hz';
}

/// A named set of band gains. The ten here are ported value for value from
/// `EqualizerPreset`, so "Rock" is the same curve as on the phone.
class EqualizerPreset {
  const EqualizerPreset(this.name, this.label, this.gains);

  final String name;
  final String label;
  final List<int> gains;

  static const flat = EqualizerPreset('flat', 'Flat', [
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  ]);
  static const rock = EqualizerPreset('rock', 'Rock', [
    5, 4, 3, 1, -1, -1, 1, 3, 4, 5,
  ]);
  static const pop = EqualizerPreset('pop', 'Pop', [
    -1, 2, 4, 5, 5, 4, 2, 1, 2, 2,
  ]);
  static const hipHop = EqualizerPreset('hip_hop', 'Hip hop', [
    6, 8, 4, 1, -1, -1, 1, 1, 3, 4,
  ]);
  static const jazz = EqualizerPreset('jazz', 'Jazz', [
    3, 2, 1, 2, -1, -1, 0, 2, 3, 4,
  ]);
  static const classical = EqualizerPreset('classical', 'Classical', [
    4, 3, 2, 1, -1, -1, 0, 2, 4, 4,
  ]);
  static const electronic = EqualizerPreset('electronic', 'Electronic', [
    5, 6, 2, 0, -1, 1, 0, 2, 6, 7,
  ]);
  static const bassBoost = EqualizerPreset('bass_boost', 'Bass boost', [
    7, 9, 6, 3, 0, 0, 0, 0, 0, 0,
  ]);
  static const trebleBoost = EqualizerPreset('treble_boost', 'Treble boost', [
    0, 0, 0, 0, 0, 1, 3, 6, 8, 9,
  ]);
  static const vocal = EqualizerPreset('vocal', 'Vocal', [
    -3, -2, -1, 2, 5, 6, 5, 3, 1, 0,
  ]);

  static const all = [
    flat,
    rock,
    pop,
    hipHop,
    jazz,
    classical,
    electronic,
    bassBoost,
    trebleBoost,
    vocal,
  ];

  static EqualizerPreset byName(String name) =>
      all.firstWhere((preset) => preset.name == name, orElse: () => flat);

  /// The preset whose curve these gains are, or null for a curve of the user's
  /// own — so the UI can highlight a preset without storing which was tapped.
  static EqualizerPreset? matching(List<int> gains) {
    for (final preset in all) {
      var same = true;
      for (var i = 0; i < preset.gains.length && i < gains.length; i++) {
        if (preset.gains[i] != gains[i]) {
          same = false;
          break;
        }
      }
      if (same) return preset;
    }
    return null;
  }
}

/// The whole equalizer setting: the bands and the three extra effects.
class EqualizerState {
  EqualizerState({
    this.enabled = false,
    List<int>? gains,
    this.bassBoost = 0,
    this.virtualizer = 0,
    this.loudness = 0,
  }) : gains = _normalise(gains);

  /// Master switch. Off means no filter at all, not a flat one — an untouched
  /// signal is not the same as one that has been through ten biquads.
  final bool enabled;

  /// One gain in dB per entry in [equalizerFrequencies].
  final List<int> gains;

  /// 0..100, as on Android. A low shelf under 100 Hz.
  final int bassBoost;

  /// 0..100. Stereo widening, Android's `Virtualizer` in spirit.
  final int virtualizer;

  /// 0..100. Evens out quiet and loud passages.
  final int loudness;

  static List<int> _normalise(List<int>? gains) => List.unmodifiable([
    for (var i = 0; i < equalizerBandCount; i++)
      ((gains != null && i < gains.length) ? gains[i] : 0).clamp(
        equalizerMinGain,
        equalizerMaxGain,
      ),
  ]);

  EqualizerState copyWith({
    bool? enabled,
    List<int>? gains,
    int? bassBoost,
    int? virtualizer,
    int? loudness,
  }) => EqualizerState(
    enabled: enabled ?? this.enabled,
    gains: gains ?? this.gains,
    bassBoost: (bassBoost ?? this.bassBoost).clamp(0, 100),
    virtualizer: (virtualizer ?? this.virtualizer).clamp(0, 100),
    loudness: (loudness ?? this.loudness).clamp(0, 100),
  );

  EqualizerState withGain(int band, int gain) {
    if (band < 0 || band >= equalizerBandCount) return this;
    final next = [...gains]..[band] = gain.clamp(
      equalizerMinGain,
      equalizerMaxGain,
    );
    return copyWith(gains: next);
  }

  EqualizerState withPreset(EqualizerPreset preset) =>
      copyWith(gains: preset.gains);

  /// True when nothing would change the sound, so the filter can be dropped
  /// entirely rather than run as a no-op.
  bool get isNeutral =>
      gains.every((gain) => gain == 0) &&
      bassBoost == 0 &&
      virtualizer == 0 &&
      loudness == 0;

  /// The preset this matches, or null for a custom curve.
  EqualizerPreset? get preset => EqualizerPreset.matching(gains);

  /// The value for mpv's `af` property, empty when nothing should be applied.
  ///
  /// One `equalizer` biquad per band — mpv also offers `superequalizer`, but its
  /// bands are fixed at frequencies that are not Android's, and matching the
  /// phone's presets matters more than saving a few filters. `width_type=o`
  /// with `width=2` is two octaves per band, which is roughly one band per
  /// neighbour at these centres and avoids gaps between them.
  String get filter {
    if (!enabled || isNeutral) return '';

    final stages = <String>[
      for (var i = 0; i < gains.length; i++)
        if (gains[i] != 0)
          'equalizer=f=${equalizerFrequencies[i]}:width_type=o:width=2:'
              'g=${gains[i]}',
      // A low shelf rather than another band: Android's BassBoost lifts
      // everything underneath a corner, it does not peak at one frequency.
      if (bassBoost > 0) 'bass=g=${_scale(bassBoost, 12)}:f=100',
      // extrastereo widens the difference between channels. Kept below 2.0,
      // past which it starts to sound hollow rather than wide.
      if (virtualizer > 0) 'extrastereo=m=${_scaleDouble(virtualizer, 1.0, 1.8)}',
      // dynaudnorm, not loudnorm: loudnorm wants two passes over a whole file,
      // which is no use to a live stream. Its window has to be an odd number of
      // frames; ffmpeg silently rounds an even one up and logs about it, so the
      // odd value is chosen here and the setting is what was asked for.
      if (loudness > 0) 'dynaudnorm=g=${_oddScale(loudness, 3, 27)}:p=0.9',
    ];

    if (stages.isEmpty) return '';
    // mpv reaches ffmpeg's filters through lavfi, and a comma inside the
    // brackets chains them.
    return 'lavfi=[${stages.join(',')}]';
  }

  /// A 0..100 strength as an integer in `min`..`max`.
  static int _scale(int strength, int max, {int min = 0}) =>
      min + ((max - min) * strength / 100).round();

  /// As [_scale], forced odd, for filters that only accept an odd window.
  static int _oddScale(int strength, int min, int max) {
    final value = _scale(strength, max, min: min);
    return value.isEven ? value + 1 : value;
  }

  static String _scaleDouble(int strength, double min, double max) =>
      (min + (max - min) * strength / 100).toStringAsFixed(2);

  Map<String, Object?> toJson() => {
    'enabled': enabled,
    'gains': gains,
    'bassBoost': bassBoost,
    'virtualizer': virtualizer,
    'loudness': loudness,
  };

  String encode() => jsonEncode(toJson());

  /// Reads the map [toJson] produces, with the same tolerance as [decode]:
  /// anything unreadable becomes the default rather than throwing.
  static EqualizerState fromJson(Map<String, Object?> json) =>
      decode(jsonEncode(json));

  /// Reads back [encode]. Anything unreadable becomes the default, because a
  /// corrupt setting must not stop the player from starting.
  static EqualizerState decode(String? raw) {
    if (raw == null || raw.isEmpty) return EqualizerState();
    try {
      final json = jsonDecode(raw);
      if (json is! Map) return EqualizerState();
      // Every field is checked rather than cast: a setting written by an older
      // version, or half-edited by hand, must not throw on the way in.
      final stored = json['gains'];
      return EqualizerState(
        enabled: json['enabled'] == true,
        gains: [
          if (stored is List)
            for (final value in stored)
              if (value is num) value.toInt() else 0,
        ],
        bassBoost: _int(json['bassBoost']),
        virtualizer: _int(json['virtualizer']),
        loudness: _int(json['loudness']),
      );
    } on FormatException {
      return EqualizerState();
    }
  }

  static int _int(Object? value) =>
      value is num ? value.toInt().clamp(0, 100) : 0;
}
