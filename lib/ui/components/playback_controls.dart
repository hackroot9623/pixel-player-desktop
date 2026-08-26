import 'dart:async';

// `RepeatMode` also exists in flutter/widgets (RepeatingAnimationBuilder);
// ours is the playback one.
import 'package:flutter/material.dart' hide RepeatMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../player/player_service.dart' show RepeatMode;
import '../../state/providers.dart';
import '../theme/shapes.dart';

/// Desktop transport bar.
///
/// The Android original (`AnimatedPlaybackControls` + `BottomToggleRow`) uses
/// two stacked rows of 80 dp full-width pills — sized for thumbs. On a desktop
/// window that reads as enormous and wastes the panel, so the same controls are
/// laid out as one dense centred row with pointer affordances instead: hover
/// states, tooltips carrying the keyboard shortcut, and a much smaller hit area.
///
/// What is kept from the original: the press-squeeze (the pressed button grows
/// while its neighbours compress), the play/pause squircle that squares off
/// while playing, the morphing play/pause glyph, and the "fixed" colour roles
/// on the three toggles.
class TransportBar extends ConsumerStatefulWidget {
  const TransportBar({super.key, this.compact = false});

  /// Slightly tighter still, for the mini player.
  final bool compact;

  @override
  ConsumerState<TransportBar> createState() => _TransportBarState();
}

class _TransportBarState extends ConsumerState<TransportBar> {
  static const _spatial = Duration(milliseconds: 260);

  _PressTarget? _pressed;
  Timer? _release;

  @override
  void dispose() {
    _release?.cancel();
    super.dispose();
  }

  void _press(_PressTarget target, Duration releaseAfter) {
    _release?.cancel();
    setState(() => _pressed = target);
    _release = Timer(releaseAfter, () {
      if (mounted) setState(() => _pressed = null);
    });
  }

  /// Scale factor standing in for the Compose weight animation: pressed grows,
  /// the others shrink. Subtler than the phone version (1.1 / 0.65) because at
  /// desktop sizes that much movement reads as a glitch.
  double _scaleFor(_PressTarget target) => _pressed == null
      ? 1
      : (_pressed == target ? 1.06 : 0.94);

  @override
  Widget build(BuildContext context) {
    final player = ref.watch(playerProvider);
    final scheme = Theme.of(context).colorScheme;
    final song = player.current;
    final favorite = song?.isFavorite ?? false;

    final skipSize = widget.compact ? 34.0 : 40.0;
    final playSize = widget.compact ? 42.0 : 52.0;
    final toggleSize = widget.compact ? 30.0 : 36.0;

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      spacing: widget.compact ? 4 : 8,
      children: [
        _IconToggle(
          size: toggleSize,
          active: player.shuffle,
          icon: Icons.shuffle_rounded,
          tooltip: 'Shuffle',
          activeColor: scheme.primaryFixed,
          activeContentColor: scheme.onPrimaryFixed,
          onTap: player.toggleShuffle,
        ),
        _ScaledButton(
          scale: _scaleFor(_PressTarget.previous),
          duration: _spatial,
          child: _RoundButton(
            size: skipSize,
            color: scheme.secondaryContainer,
            contentColor: scheme.onSecondaryContainer,
            icon: Icons.skip_previous_rounded,
            tooltip: 'Previous  (Shift+←)',
            onTap: () {
              _press(_PressTarget.previous, const Duration(milliseconds: 320));
              player.previous();
            },
          ),
        ),
        _ScaledButton(
          scale: _scaleFor(_PressTarget.playPause),
          duration: _spatial,
          child: TweenAnimationBuilder<double>(
            // Squares off while playing, rounds out when paused.
            tween: Tween(end: player.playing ? playSize * 0.34 : playSize / 2),
            duration: _spatial,
            curve: Curves.fastOutSlowIn,
            builder: (context, corner, _) => Tooltip(
              message: player.playing ? 'Pause  (Space)' : 'Play  (Space)',
              child: Material(
                color: scheme.primary,
                shape: smoothCorner(corner),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () {
                    _press(
                      _PressTarget.playPause,
                      const Duration(milliseconds: 200),
                    );
                    player.toggle();
                  },
                  child: SizedBox(
                    width: playSize * 1.35,
                    height: playSize,
                    child: Center(
                      child: MorphingPlayPauseIcon(
                        playing: player.playing,
                        size: playSize * 0.5,
                        color: scheme.onPrimary,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        _ScaledButton(
          scale: _scaleFor(_PressTarget.next),
          duration: _spatial,
          child: _RoundButton(
            size: skipSize,
            color: scheme.secondaryContainer,
            contentColor: scheme.onSecondaryContainer,
            icon: Icons.skip_next_rounded,
            tooltip: 'Next  (Shift+→)',
            onTap: () {
              _press(_PressTarget.next, const Duration(milliseconds: 320));
              player.next();
            },
          ),
        ),
        _IconToggle(
          size: toggleSize,
          active: player.repeatMode != RepeatMode.off,
          icon: player.repeatMode == RepeatMode.one
              ? Icons.repeat_one_rounded
              : Icons.repeat_rounded,
          tooltip: switch (player.repeatMode) {
            RepeatMode.off => 'Repeat off',
            RepeatMode.all => 'Repeat all',
            RepeatMode.one => 'Repeat one',
          },
          activeColor: scheme.secondaryFixed,
          activeContentColor: scheme.onSecondaryFixed,
          onTap: player.cycleRepeatMode,
        ),
        _IconToggle(
          size: toggleSize,
          active: favorite,
          icon: favorite
              ? Icons.favorite_rounded
              : Icons.favorite_border_rounded,
          tooltip: favorite ? 'Unlike  (L)' : 'Like  (L)',
          activeColor: scheme.tertiaryFixed,
          activeContentColor: scheme.onTertiaryFixed,
          onTap: song == null
              ? null
              : () => ref.read(libraryProvider.notifier).toggleFavorite(song),
        ),
      ],
    );
  }
}

enum _PressTarget { previous, playPause, next }

class _ScaledButton extends StatelessWidget {
  const _ScaledButton({
    required this.scale,
    required this.duration,
    required this.child,
  });

  final double scale;
  final Duration duration;
  final Widget child;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(end: scale),
    duration: duration,
    curve: Curves.easeOutBack,
    builder: (context, value, child) =>
        Transform.scale(scale: value, child: child),
    child: child,
  );
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    required this.size,
    required this.color,
    required this.contentColor,
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final double size;
  final Color color;
  final Color contentColor;
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: Material(
      color: color,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        // Pointer feedback: desktop users expect hover, not just a ripple.
        hoverColor: contentColor.withValues(alpha: 0.12),
        child: SizedBox(
          width: size,
          height: size,
          child: Center(
            child: Icon(icon, size: size * 0.55, color: contentColor),
          ),
        ),
      ),
    ),
  );
}

/// A flat icon that fills in with its "fixed" colour role when active — the
/// desktop-weight version of `ToggleSegmentButton`.
class _IconToggle extends StatelessWidget {
  const _IconToggle({
    required this.size,
    required this.active,
    required this.icon,
    required this.tooltip,
    required this.activeColor,
    required this.activeContentColor,
    required this.onTap,
  });

  final double size;
  final bool active;
  final IconData icon;
  final String tooltip;
  final Color activeColor;
  final Color activeContentColor;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: TweenAnimationBuilder<double>(
        tween: Tween(end: active ? size / 2 : size * 0.28),
        duration: const Duration(milliseconds: 220),
        curve: Curves.fastOutSlowIn,
        builder: (context, corner, _) => Material(
          color: active ? activeColor : Colors.transparent,
          shape: smoothCorner(corner),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            hoverColor: scheme.onSurface.withValues(alpha: 0.08),
            child: SizedBox(
              width: size,
              height: size,
              child: Center(
                child: Icon(
                  icon,
                  size: size * 0.55,
                  color: active ? activeContentColor : scheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Port of `MorphingPlayPauseIcon`. Flutter ships the same morph as
/// [AnimatedIcons.play_pause], so this only drives it.
class MorphingPlayPauseIcon extends StatefulWidget {
  const MorphingPlayPauseIcon({
    super.key,
    required this.playing,
    required this.size,
    required this.color,
  });

  final bool playing;
  final double size;
  final Color color;

  @override
  State<MorphingPlayPauseIcon> createState() => _MorphingPlayPauseIconState();
}

class _MorphingPlayPauseIconState extends State<MorphingPlayPauseIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 240),
    value: widget.playing ? 1 : 0,
  );

  @override
  void didUpdateWidget(MorphingPlayPauseIcon old) {
    super.didUpdateWidget(old);
    if (widget.playing != old.playing) {
      widget.playing ? _c.forward() : _c.reverse();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedIcon(
    icon: AnimatedIcons.play_pause,
    progress: _c,
    size: widget.size,
    color: widget.color,
  );
}
