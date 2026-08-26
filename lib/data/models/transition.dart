import 'dart:math' as math;

/// Ported from `data/model/Transition.kt`.
enum TransitionMode {
  /// No transition — the next song starts when the previous one ends.
  none('None'),

  /// The current song fades out completely before the next one fades in.
  fadeInOut('Fade out, then in'),

  /// The songs overlap while one fades out and the other fades in.
  overlap('Crossfade'),

  /// An S-shaped curve applied across the overlap.
  smooth('Smooth crossfade');

  const TransitionMode(this.label);

  final String label;

  /// True when the mode needs two decoders running at once. mpv drives a single
  /// playlist here, so these are accepted in settings but degrade to
  /// [fadeInOut] until the dual-player engine lands (see PLAN.md phase 7).
  bool get needsOverlap =>
      this == TransitionMode.overlap || this == TransitionMode.smooth;
}

/// Ported from `Curve` in Transition.kt — the volume ramp shape.
enum TransitionCurve {
  linear('Linear'),
  exp('Exponential'),
  log('Logarithmic'),
  sCurve('S-curve');

  const TransitionCurve(this.label);

  final String label;

  /// Maps a 0..1 ramp position to a 0..1 volume multiplier.
  double apply(double t) {
    final x = t.clamp(0.0, 1.0);
    return switch (this) {
      TransitionCurve.linear => x,
      TransitionCurve.exp => x * x,
      TransitionCurve.log => math.sqrt(x),
      TransitionCurve.sCurve => x * x * (3 - 2 * x),
    };
  }
}

/// Ported from `TransitionSettings`.
class TransitionSettings {
  const TransitionSettings({
    this.mode = TransitionMode.none,
    this.durationMs = 2000,
    this.curveIn = TransitionCurve.sCurve,
    this.curveOut = TransitionCurve.sCurve,
  });

  final TransitionMode mode;
  final int durationMs;
  final TransitionCurve curveIn;
  final TransitionCurve curveOut;

  bool get enabled => mode != TransitionMode.none && durationMs > 0;

  Duration get duration => Duration(milliseconds: durationMs);

  TransitionSettings copyWith({
    TransitionMode? mode,
    int? durationMs,
    TransitionCurve? curveIn,
    TransitionCurve? curveOut,
  }) => TransitionSettings(
    mode: mode ?? this.mode,
    durationMs: durationMs ?? this.durationMs,
    curveIn: curveIn ?? this.curveIn,
    curveOut: curveOut ?? this.curveOut,
  );

  Map<String, dynamic> toJson() => {
    'mode': mode.name,
    'durationMs': durationMs,
    'curveIn': curveIn.name,
    'curveOut': curveOut.name,
  };

  static TransitionSettings fromJson(Map<String, dynamic> json) {
    if (json.isEmpty) return const TransitionSettings();
    T pick<T extends Enum>(List<T> values, Object? name, T fallback) =>
        values.firstWhere((v) => v.name == name, orElse: () => fallback);
    return TransitionSettings(
      mode: pick(TransitionMode.values, json['mode'], TransitionMode.none),
      durationMs: (json['durationMs'] as num?)?.toInt() ?? 2000,
      curveIn: pick(
        TransitionCurve.values,
        json['curveIn'],
        TransitionCurve.sCurve,
      ),
      curveOut: pick(
        TransitionCurve.values,
        json['curveOut'],
        TransitionCurve.sCurve,
      ),
    );
  }
}
