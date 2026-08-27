import 'dart:math' as math;
import 'dart:ui';

/// Contrast helpers, so tinted backgrounds cannot end up the same colour as the
/// text on top of them.
///
/// The home banner tints its background from the palette, and the palette comes
/// from whatever album art happens to be playing. Hand-picked tint strengths
/// held for the covers that were on screen at the time and failed for others —
/// with a monochrome palette, `primaryContainer` can land within 0.3% of
/// `onSurface`, which is an invisible title. These derive the tint instead.

/// WCAG 2.1 relative luminance of an opaque colour.
double relativeLuminance(Color color) {
  double channel(double value) => value <= 0.03928
      ? value / 12.92
      : math.pow((value + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * channel(color.r) +
      0.7152 * channel(color.g) +
      0.0722 * channel(color.b);
}

/// WCAG 2.1 contrast ratio between two opaque colours, 1..21.
///
/// 4.5 is the AA threshold for body text, 3.0 for large text (>=24px, or >=19px
/// bold).
double contrastRatio(Color foreground, Color background) {
  final a = relativeLuminance(foreground);
  final b = relativeLuminance(background);
  return (math.max(a, b) + 0.05) / (math.min(a, b) + 0.05);
}

/// Flattens a translucent [foreground] onto an opaque [background].
Color compositeOver(Color foreground, Color background) {
  final alpha = foreground.a;
  return Color.from(
    alpha: 1,
    red: foreground.r * alpha + background.r * (1 - alpha),
    green: foreground.g * alpha + background.g * (1 - alpha),
    blue: foreground.b * alpha + background.b * (1 - alpha),
  );
}

/// Blends [tint] into [surface] as strongly as [text] can still be read on it.
///
/// Starts at [strength] and backs off until the contrast clears [minRatio],
/// returning the plain [surface] if even a trace of tint would not do. Keeps a
/// tinted panel decorative: the tint is as strong as it can be without costing
/// legibility, whatever palette the artwork produced.
Color legibleTint(
  Color surface,
  Color tint, {
  required Color text,
  double strength = 0.5,
  double minRatio = 4.5,
  double step = 0.05,
}) {
  for (var t = strength; t > 0; t -= step) {
    final candidate = Color.lerp(surface, tint, t)!;
    if (contrastRatio(text, candidate) >= minRatio) return candidate;
  }
  return surface;
}
