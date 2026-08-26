import 'package:flutter/material.dart';

/// Port of `presentation/components/ExpressiveScrollBar`.
///
/// A pill thumb sits at the right edge, 8 px wide at rest. Hovering or dragging
/// it widens it to 28 px, fades in an unfold-more glyph, and — when
/// [labelForOffset] is supplied — pops a bubble beside it showing where the
/// drag has landed (the Kotlin version uses it for the A-Z jump label). It
/// hides itself entirely when the content does not scroll.
class ExpressiveScrollbar extends StatefulWidget {
  const ExpressiveScrollbar({
    super.key,
    required this.controller,
    required this.child,
    this.thickness = 8,
    this.expandedThickness = 28,
    this.minThumbHeight = 48,
    this.paddingEnd = 4,
    this.labelForOffset,
    this.enabled = true,
  });

  final ScrollController controller;
  final Widget child;
  final double thickness;
  final double expandedThickness;
  final double minThumbHeight;
  final double paddingEnd;

  /// Given the scroll fraction (0..1), the text to show in the drag bubble.
  final String? Function(double fraction)? labelForOffset;

  /// Mirrors `LocalShowScrollbar` — the user can switch scrollbars off.
  final bool enabled;

  @override
  State<ExpressiveScrollbar> createState() => _ExpressiveScrollbarState();
}

class _ExpressiveScrollbarState extends State<ExpressiveScrollbar> {
  bool _hovering = false;
  bool _dragging = false;

  bool get _interacting => _hovering || _dragging;

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    final scheme = Theme.of(context).colorScheme;

    return Stack(
      children: [
        widget.child,
        Positioned(
          top: 0,
          bottom: 0,
          right: widget.paddingEnd,
          width: widget.expandedThickness,
          child: LayoutBuilder(
            builder: (context, constraints) => ListenableBuilder(
              listenable: widget.controller,
              builder: (context, _) {
                if (!widget.controller.hasClients) {
                  return const SizedBox.shrink();
                }
                final position = widget.controller.position;
                final maxScroll = position.maxScrollExtent;
                if (maxScroll <= 0) return const SizedBox.shrink();

                final viewport = constraints.maxHeight;
                final visibleRatio =
                    position.viewportDimension /
                    (position.viewportDimension + maxScroll);
                final thumbHeight = (viewport * visibleRatio).clamp(
                  widget.minThumbHeight,
                  viewport,
                );
                final fraction = (position.pixels / maxScroll).clamp(0.0, 1.0);
                final top = (viewport - thumbHeight) * fraction;
                final label = _dragging
                    ? widget.labelForOffset?.call(fraction)
                    : null;

                void scrollToLocal(double dy) {
                  final travel = viewport - thumbHeight;
                  if (travel <= 0) return;
                  final target =
                      ((dy - thumbHeight / 2) / travel).clamp(0.0, 1.0) *
                      maxScroll;
                  widget.controller.jumpTo(target);
                }

                return Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Positioned(
                      top: top,
                      right: 0,
                      height: thumbHeight,
                      child: MouseRegion(
                        cursor: SystemMouseCursors.click,
                        onEnter: (_) => setState(() => _hovering = true),
                        onExit: (_) => setState(() => _hovering = false),
                        child: GestureDetector(
                          onVerticalDragStart: (_) =>
                              setState(() => _dragging = true),
                          onVerticalDragUpdate: (d) {
                            final box =
                                context.findRenderObject() as RenderBox?;
                            if (box == null) return;
                            scrollToLocal(
                              box.globalToLocal(d.globalPosition).dy,
                            );
                          },
                          onVerticalDragEnd: (_) =>
                              setState(() => _dragging = false),
                          onVerticalDragCancel: () =>
                              setState(() => _dragging = false),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              if (label != null)
                                Padding(
                                  padding: const EdgeInsets.only(right: 10),
                                  child: Material(
                                    color: scheme.secondaryContainer,
                                    shape: const StadiumBorder(),
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 14,
                                        vertical: 8,
                                      ),
                                      child: Text(
                                        label,
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleMedium
                                            ?.copyWith(
                                              color: scheme
                                                  .onSecondaryContainer,
                                            ),
                                      ),
                                    ),
                                  ),
                                ),
                              AnimatedContainer(
                                duration: const Duration(milliseconds: 200),
                                curve: Curves.fastOutSlowIn,
                                width: _interacting
                                    ? widget.expandedThickness
                                    : widget.thickness,
                                decoration: ShapeDecoration(
                                  color: _interacting
                                      ? scheme.primary
                                      : scheme.primary.withValues(alpha: 0.55),
                                  shape: const StadiumBorder(),
                                ),
                                alignment: Alignment.center,
                                child: AnimatedOpacity(
                                  duration: const Duration(milliseconds: 200),
                                  opacity: _interacting ? 1 : 0,
                                  child: Icon(
                                    Icons.unfold_more_rounded,
                                    size: 16,
                                    color: scheme.onPrimary,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}
