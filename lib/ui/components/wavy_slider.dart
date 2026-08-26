import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Port of `presentation/components/WavySliderExpressive` (and the earlier
/// `WavyMusicSlider`): the played portion of the track renders as a travelling
/// sine wave, the remainder as a flat line, with the M3 expressive stop-dot at
/// the far end.
///
/// Behaviours carried over from the Kotlin version:
/// * the wave amplitude animates to zero while paused **or** while the user is
///   scrubbing, so the line is straight and easy to aim with;
/// * the thumb morphs from a dot into a tall rounded bar while scrubbing;
/// * the track is cut away around the thumb by a gap that grows with it;
/// * the wave travels at half a wavelength per second.
class WavySlider extends StatefulWidget {
  const WavySlider({
    super.key,
    required this.value,
    this.onChanged,
    this.onChangeEnd,
    this.animate = true,
    this.height = 40,
    this.waveAmplitude = 4,
    this.wavelength = 40,
    this.strokeWidth = 5,
    this.thumbRadius = 8,
    this.thumbLineHeight = 24,
    this.activeColor,
    this.inactiveColor,
  });

  /// 0..1 progress.
  final double value;

  /// Called continuously while scrubbing. Optional: the player only needs the
  /// committed value, and seeking on every frame fights mpv.
  final ValueChanged<double>? onChanged;
  final ValueChanged<double>? onChangeEnd;

  /// The wave only travels while something is actually playing.
  final bool animate;
  final double height;
  final double waveAmplitude;
  final double wavelength;
  final double strokeWidth;
  final double thumbRadius;
  final double thumbLineHeight;
  final Color? activeColor;
  final Color? inactiveColor;

  @override
  State<WavySlider> createState() => _WavySliderState();
}

class _WavySliderState extends State<WavySlider>
    with TickerProviderStateMixin {
  /// One full period per two seconds — `waveSpeed = wavelength / 2` in the
  /// Kotlin defaults.
  late final AnimationController _phase = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2000),
  );

  /// 0 = idle (wave on, dot thumb), 1 = scrubbing (flat line, bar thumb).
  late final AnimationController _interaction = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 250),
  );

  late final Animation<double> _interactionCurve = CurvedAnimation(
    parent: _interaction,
    curve: Curves.fastOutSlowIn,
  );

  double? _dragValue;
  bool _hovering = false;

  @override
  void initState() {
    super.initState();
    if (widget.animate) _phase.repeat();
  }

  @override
  void didUpdateWidget(WavySlider old) {
    super.didUpdateWidget(old);
    if (widget.animate && !_phase.isAnimating) {
      _phase.repeat();
    } else if (!widget.animate && _phase.isAnimating) {
      _phase.stop();
    }
  }

  @override
  void dispose() {
    _phase.dispose();
    _interaction.dispose();
    super.dispose();
  }

  double _fractionFor(Offset local, double width) =>
      (local.dx / width).clamp(0.0, 1.0);

  void _begin(Offset local, double width) {
    _interaction.forward();
    setState(() => _dragValue = _fractionFor(local, width));
    widget.onChanged?.call(_dragValue!);
  }

  void _update(Offset local, double width) {
    setState(() => _dragValue = _fractionFor(local, width));
    widget.onChanged?.call(_dragValue!);
  }

  void _commit() {
    final fraction = _dragValue;
    _interaction.reverse();
    setState(() => _dragValue = null);
    if (fraction != null) {
      (widget.onChangeEnd ?? widget.onChanged)?.call(fraction);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final active = widget.activeColor ?? scheme.primary;
    final inactive =
        widget.inactiveColor ?? scheme.onSurface.withValues(alpha: 0.2);

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hovering = true),
          onExit: (_) => setState(() => _hovering = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) => _begin(d.localPosition, width),
            onTapUp: (_) => _commit(),
            onTapCancel: _commit,
            onHorizontalDragStart: (d) => _begin(d.localPosition, width),
            onHorizontalDragUpdate: (d) => _update(d.localPosition, width),
            onHorizontalDragEnd: (_) => _commit(),
            onHorizontalDragCancel: _commit,
            child: SizedBox(
              height: widget.height,
              width: width,
              child: AnimatedBuilder(
                animation: Listenable.merge([_phase, _interactionCurve]),
                builder: (context, _) {
                  final interaction = _interactionCurve.value;
                  return CustomPaint(
                    painter: _WavyPainter(
                      value: (_dragValue ?? widget.value).clamp(0.0, 1.0),
                      phase: _phase.value * 2 * math.pi,
                      interaction: interaction,
                      active: active,
                      inactive: inactive,
                      // Amplitude collapses while paused or scrubbing.
                      amplitude:
                          widget.animate
                          ? widget.waveAmplitude * (1 - interaction)
                          : 0,
                      wavelength: widget.wavelength,
                      strokeWidth: widget.strokeWidth,
                      thumbRadius:
                          widget.thumbRadius + (_hovering ? 1.5 : 0),
                      thumbLineHeight: widget.thumbLineHeight,
                    ),
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }
}

class _WavyPainter extends CustomPainter {
  _WavyPainter({
    required this.value,
    required this.phase,
    required this.interaction,
    required this.active,
    required this.inactive,
    required this.amplitude,
    required this.wavelength,
    required this.strokeWidth,
    required this.thumbRadius,
    required this.thumbLineHeight,
  });

  final double value;
  final double phase;
  final double interaction;
  final Color active;
  final Color inactive;
  final double amplitude;
  final double wavelength;
  final double strokeWidth;
  final double thumbRadius;
  final double thumbLineHeight;

  @override
  void paint(Canvas canvas, Size size) {
    final midY = size.height / 2;
    // Thumb morph: dot of `thumbRadius` -> vertical bar of half-width
    // `strokeWidth * 0.6`, exactly as `currentHalfWidth` in the Kotlin source.
    final halfWidth =
        thumbRadius * (1 - interaction) + strokeWidth * 0.6 * interaction;
    final thumbHeight =
        thumbRadius * 2 * (1 - interaction) + thumbLineHeight * interaction;
    final thumbX = (size.width - halfWidth * 2) * value + halfWidth;
    final gap = halfWidth + 5;

    final trackPaint = Paint()
      ..color = inactive
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    final rightEnd = size.width - strokeWidth / 2;
    if (thumbX + gap < rightEnd) {
      canvas.drawLine(
        Offset(thumbX + gap, midY),
        Offset(rightEnd, midY),
        trackPaint,
      );
    }
    // M3 expressive end-of-track stop indicator.
    canvas.drawCircle(
      Offset(rightEnd, midY),
      strokeWidth / 2,
      Paint()..color = inactive,
    );

    final wavePaint = Paint()
      ..color = active
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    final leftEnd = strokeWidth / 2;
    final end = thumbX - gap;
    if (end > leftEnd) {
      final path = Path()..moveTo(leftEnd, midY);
      if (amplitude <= 0.05) {
        path.lineTo(end, midY);
      } else {
        for (var x = leftEnd; x <= end; x += 1.5) {
          // Taper the amplitude in at both ends so the line meets the cap flat.
          final taper =
              math.min(
                (x - leftEnd) / wavelength,
                (end - x) / wavelength,
              ).clamp(0.0, 1.0);
          final y =
              midY +
              math.sin((x / wavelength) * 2 * math.pi - phase) *
                  amplitude *
                  taper;
          path.lineTo(x, y);
        }
        path.lineTo(end, midY);
      }
      canvas.drawPath(path, wavePaint);
    }

    final thumbRect = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: Offset(thumbX, midY),
        width: halfWidth * 2,
        height: thumbHeight,
      ),
      Radius.circular(halfWidth),
    );
    canvas.drawRRect(thumbRect, Paint()..color = active);
  }

  @override
  bool shouldRepaint(_WavyPainter old) =>
      old.value != value ||
      old.phase != phase ||
      old.interaction != interaction ||
      old.amplitude != amplitude ||
      old.active != active ||
      old.inactive != inactive ||
      old.thumbRadius != thumbRadius;
}
