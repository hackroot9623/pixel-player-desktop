import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Port of `presentation/components/WavyMusicSlider` +
/// `WavySliderExpressive`: the played portion of the track renders as a
/// travelling sine wave, the remainder as a flat line, with the M3 expressive
/// stop-dot at the end.
class WavySlider extends StatefulWidget {
  const WavySlider({
    super.key,
    required this.value,
    required this.onChanged,
    this.onChangeEnd,
    this.animate = true,
    this.height = 34,
    this.waveHeight = 6,
    this.waveLength = 26,
    this.strokeWidth = 4,
  });

  /// 0..1 progress.
  final double value;
  final ValueChanged<double> onChanged;
  final ValueChanged<double>? onChangeEnd;

  /// The wave only travels while something is actually playing.
  final bool animate;
  final double height;
  final double waveHeight;
  final double waveLength;
  final double strokeWidth;

  @override
  State<WavySlider> createState() => _WavySliderState();
}

class _WavySliderState extends State<WavySlider>
    with SingleTickerProviderStateMixin {
  late final AnimationController _phase = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
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
    super.dispose();
  }

  void _emit(Offset local, double width, {bool end = false}) {
    final fraction = (local.dx / width).clamp(0.0, 1.0);
    setState(() => _dragValue = end ? null : fraction);
    if (end) {
      (widget.onChangeEnd ?? widget.onChanged)(fraction);
    } else {
      widget.onChanged(fraction);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final value = (_dragValue ?? widget.value).clamp(0.0, 1.0);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hovering = true),
          onExit: (_) => setState(() => _hovering = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) => _emit(d.localPosition, width),
            onTapUp: (d) => _emit(d.localPosition, width, end: true),
            onHorizontalDragUpdate: (d) => _emit(d.localPosition, width),
            onHorizontalDragEnd: (_) {
              final fraction = _dragValue ?? widget.value;
              setState(() => _dragValue = null);
              (widget.onChangeEnd ?? widget.onChanged)(fraction);
            },
            child: SizedBox(
              height: widget.height,
              width: width,
              child: AnimatedBuilder(
                animation: _phase,
                builder: (context, _) => CustomPaint(
                  painter: _WavyPainter(
                    value: value,
                    phase: _phase.value * 2 * math.pi,
                    active: scheme.primary,
                    inactive: scheme.surfaceContainerHighest,
                    thumb: scheme.primary,
                    waveHeight: widget.animate ? widget.waveHeight : 0,
                    waveLength: widget.waveLength,
                    strokeWidth: widget.strokeWidth,
                    thumbRadius: _hovering ? 8 : 6,
                  ),
                ),
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
    required this.active,
    required this.inactive,
    required this.thumb,
    required this.waveHeight,
    required this.waveLength,
    required this.strokeWidth,
    required this.thumbRadius,
  });

  final double value;
  final double phase;
  final Color active;
  final Color inactive;
  final Color thumb;
  final double waveHeight;
  final double waveLength;
  final double strokeWidth;
  final double thumbRadius;

  @override
  void paint(Canvas canvas, Size size) {
    final midY = size.height / 2;
    final thumbX = size.width * value;
    final gap = thumbRadius + 4;

    final trackPaint = Paint()
      ..color = inactive
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    if (thumbX + gap < size.width) {
      canvas.drawLine(
        Offset(thumbX + gap, midY),
        Offset(size.width - 2, midY),
        trackPaint,
      );
    }
    // M3 expressive end-of-track stop indicator.
    canvas.drawCircle(
      Offset(size.width - 2, midY),
      strokeWidth / 2,
      Paint()..color = inactive,
    );

    final wavePaint = Paint()
      ..color = active
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    final end = math.max(0.0, thumbX - gap);
    if (end > 0) {
      final path = Path()..moveTo(0, midY);
      for (var x = 0.0; x <= end; x += 1) {
        // Taper the amplitude in at the start so the line leaves the edge flat.
        final taper = (x / math.max(waveLength, 1)).clamp(0.0, 1.0);
        final y =
            midY +
            math.sin((x / waveLength) * 2 * math.pi - phase) *
                waveHeight *
                taper;
        path.lineTo(x, y);
      }
      canvas.drawPath(path, wavePaint);
    }

    canvas.drawCircle(Offset(thumbX, midY), thumbRadius, Paint()..color = thumb);
  }

  @override
  bool shouldRepaint(_WavyPainter old) =>
      old.value != value ||
      old.phase != phase ||
      old.active != active ||
      old.thumbRadius != thumbRadius ||
      old.waveHeight != waveHeight;
}
