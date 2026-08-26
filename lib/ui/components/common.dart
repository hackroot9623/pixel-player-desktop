import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/providers.dart';
import '../theme/typography.dart';

String formatDuration(Duration duration) {
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60);
  final seconds = duration.inSeconds.remainder(60);
  final mm = hours > 0 ? minutes.toString().padLeft(2, '0') : '$minutes';
  return hours > 0
      ? '$hours:$mm:${seconds.toString().padLeft(2, '0')}'
      : '$mm:${seconds.toString().padLeft(2, '0')}';
}

String formatLongDuration(Duration duration) {
  if (duration.inHours >= 1) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    return minutes == 0 ? '$hours h' : '$hours h $minutes min';
  }
  return '${duration.inMinutes} min';
}

String plural(int count, String singular, [String? pluralForm]) =>
    '$count ${count == 1 ? singular : (pluralForm ?? '${singular}s')}';

/// The oversized Montserrat screen title from `ExpTitleTypography`, including
/// the horizontal stretch Compose applies via `TextGeometricTransform`.
class ExpressiveTitle extends StatelessWidget {
  const ExpressiveTitle(
    this.text, {
    super.key,
    this.style,
    this.scaleX = expTitleMediumScaleX,
    this.color,
  });

  final String text;
  final TextStyle? style;
  final double scaleX;
  final Color? color;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: Transform(
      alignment: Alignment.centerLeft,
      transform: Matrix4.diagonal3Values(scaleX, 1, 1),
      child: Text(
        text,
        style: (style ?? expTitleMedium).copyWith(
          color: color ?? Theme.of(context).colorScheme.onSurface,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    ),
  );
}

class SectionHeader extends StatelessWidget {
  const SectionHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 12),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(title, style: theme.textTheme.titleMedium),
                        if (onTap != null)
                          const Padding(
                            padding: EdgeInsets.only(left: 4),
                            child: Icon(Icons.chevron_right_rounded, size: 20),
                          ),
                      ],
                    ),
                    if (subtitle != null)
                      Text(
                        subtitle!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

/// Port of `presentation/screens/LibraryEmptyState`.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.action,
  });

  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                shape: BoxShape.circle,
              ),
              child: Icon(
                icon,
                size: 44,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              title,
              style: theme.textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            if (message != null) ...[
              const SizedBox(height: 8),
              Text(
                message!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            if (action != null) ...[const SizedBox(height: 24), action!],
          ],
        ),
      ),
    );
  }
}

/// Port of `subcomps/PlayingEqIcon` — the three animated bars marking the
/// track that is currently playing.
class PlayingEqIcon extends StatefulWidget {
  const PlayingEqIcon({super.key, this.animate = true, this.size = 16});

  final bool animate;
  final double size;

  @override
  State<PlayingEqIcon> createState() => _PlayingEqIconState();
}

class _PlayingEqIconState extends State<PlayingEqIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void initState() {
    super.initState();
    if (widget.animate) _c.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(PlayingEqIcon old) {
    super.didUpdateWidget(old);
    if (widget.animate && !_c.isAnimating) {
      _c.repeat(reverse: true);
    } else if (!widget.animate && _c.isAnimating) {
      _c.stop();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) => Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            for (final offset in const [0.0, 0.35, 0.7])
              Container(
                width: widget.size / 5,
                height:
                    widget.size *
                    (0.35 +
                        0.65 *
                            ((_c.value + offset) % 1.0 < 0.5
                                ? (_c.value + offset) % 1.0 * 2
                                : 2 - (_c.value + offset) % 1.0 * 2)),
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(widget.size / 10),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Rebuilds only on playback-position changes.
///
/// The player's position ticks many times a second. It is deliberately kept off
/// the main notifier so that seek bars and time labels can subscribe to it
/// without dragging every other listener into a rebuild.
class PositionBuilder extends ConsumerWidget {
  const PositionBuilder({super.key, required this.builder});

  final Widget Function(BuildContext context, Duration position) builder;

  @override
  Widget build(BuildContext context, WidgetRef ref) => ValueListenableBuilder(
    valueListenable: ref.read(playerProvider).positionListenable,
    builder: (context, position, _) => builder(context, position),
  );
}
