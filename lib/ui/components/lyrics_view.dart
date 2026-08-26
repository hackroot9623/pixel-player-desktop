import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/lyrics.dart';
import '../../state/providers.dart';
import 'common.dart';

/// Port of the scrolling display inside `presentation/components/LyricsSheet`.
///
/// The active line is scaled up and fully opaque, neighbours fade out with
/// distance, and the list keeps the active line centred. Clicking a line seeks
/// to it. Unsynced lyrics fall back to a plain scrollable column.
class LyricsView extends ConsumerStatefulWidget {
  const LyricsView({
    super.key,
    required this.lyrics,
    this.padding = const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
    this.centerAlign = false,
  });

  final Lyrics lyrics;
  final EdgeInsets padding;
  final bool centerAlign;

  @override
  ConsumerState<LyricsView> createState() => _LyricsViewState();
}

class _LyricsViewState extends ConsumerState<LyricsView> {
  final _controller = ScrollController();

  int _activeIndex = -1;
  bool _userScrolling = false;

  /// Attached to whichever line is active, so it can be scrolled to by its own
  /// laid-out geometry. Lines wrap to different heights, so there is no fixed
  /// extent to compute an offset from.
  GlobalKey? _activeKey;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Keeps the active line centred, unless the user has taken over scrolling.
  void _followActive(int index, int total) {
    if (_userScrolling || index < 0 || !_controller.hasClients) return;
    final context = _activeKey?.currentContext;
    if (context != null) {
      Scrollable.ensureVisible(
        context,
        alignment: 0.5,
        duration: const Duration(milliseconds: 420),
        curve: Curves.easeOutCubic,
      );
      return;
    }
    // The line is too far off-screen to have been built (the user seeked
    // across the track). Approximate, and the next line lands it exactly.
    final position = _controller.position;
    _controller.jumpTo(
      (index / total * position.maxScrollExtent).clamp(
        0.0,
        position.maxScrollExtent,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final synced = widget.lyrics.synced;
    if (synced == null || synced.isEmpty) return _plain(context);

    final theme = Theme.of(context);
    final player = ref.read(playerProvider);

    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        // A drag hands control to the user; the next track change takes it back.
        if (notification is UserScrollNotification) {
          _userScrolling = notification.direction != ScrollDirection.idle;
        }
        return false;
      },
      child: PositionBuilder(
        builder: (context, position) {
          final index = widget.lyrics.activeIndexAt(position);
          if (index != _activeIndex) {
            _activeIndex = index;
            _activeKey = GlobalKey();
            WidgetsBinding.instance.addPostFrameCallback(
              (_) => _followActive(index, synced.length),
            );
          }
          return ListView.builder(
            controller: _controller,
            padding: widget.padding,
            itemCount: synced.length,
            // No itemExtent: a wrapped line is taller than a single one, and
            // pinning every row to the same height made long lines overlap
            // their neighbours.
            itemBuilder: (context, i) {
              final line = synced[i];
              final distance = (i - index).abs();
              final isActive = i == index;
              return _LyricLine(
                key: isActive ? _activeKey : null,
                text: line.isBlank ? '♪' : line.line,
                active: isActive,
                // Fade with distance so the eye lands on the active line.
                opacity: isActive
                    ? 1
                    : (distance > 6 ? 0.25 : 0.9 - distance * 0.1),
                centerAlign: widget.centerAlign,
                onTap: () => player.seek(
                  Duration(
                    milliseconds: (line.timeMs + widget.lyrics.offsetMs).clamp(
                      0,
                      player.duration.inMilliseconds,
                    ),
                  ),
                ),
                style: theme.textTheme.titleLarge,
              );
            },
          );
        },
      ),
    );
  }

  Widget _plain(BuildContext context) {
    final plain = widget.lyrics.plain ?? const [];
    if (plain.isEmpty) {
      return const EmptyState(
        icon: Icons.lyrics_outlined,
        title: 'No lyrics for this track',
      );
    }
    return ListView.builder(
      controller: _controller,
      padding: widget.padding,
      itemCount: plain.length,
      itemBuilder: (context, i) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: SelectableText(
          plain[i],
          textAlign: widget.centerAlign ? TextAlign.center : TextAlign.start,
          style: Theme.of(context).textTheme.titleMedium,
        ),
      ),
    );
  }
}

class _LyricLine extends StatelessWidget {
  const _LyricLine({
    super.key,
    required this.text,
    required this.active,
    required this.opacity,
    required this.centerAlign,
    required this.onTap,
    required this.style,
  });

  final String text;
  final bool active;
  final double opacity;
  final bool centerAlign;
  final VoidCallback onTap;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Align(
        alignment: centerAlign ? Alignment.center : Alignment.centerLeft,
        child: AnimatedDefaultTextStyle(
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
          style: (style ?? const TextStyle()).copyWith(
            fontSize: (style?.fontSize ?? 22) * (active ? 1.18 : 1),
            fontWeight: active ? FontWeight.w700 : FontWeight.w500,
            color: active
                ? scheme.primary
                : scheme.onSurface.withValues(alpha: opacity.clamp(0.15, 1)),
          ),
          child: Padding(
            // Vertical padding is the gap between lines now that each one sizes
            // itself; long lines wrap rather than being truncated.
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
            child: Text(
              text,
              softWrap: true,
              textAlign: centerAlign ? TextAlign.center : TextAlign.start,
            ),
          ),
        ),
      ),
    );
  }
}
