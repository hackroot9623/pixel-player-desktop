import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../games/brick_breaker.dart';

/// The easter egg. Tap the version in About enough times and here it is.
///
/// Mouse or arrow keys move the paddle; space launches. Coloured from the app's
/// own scheme so it looks like part of the player rather than a bolted-on demo.
class BrickBreakerScreen extends StatefulWidget {
  const BrickBreakerScreen({super.key});

  @override
  State<BrickBreakerScreen> createState() => _BrickBreakerScreenState();
}

class _BrickBreakerScreenState extends State<BrickBreakerScreen>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  BrickBreakerState _state = BrickBreakerState.newGame();
  Duration _last = Duration.zero;

  /// Held arrow keys, so keyboard steering is smooth rather than one nudge per
  /// key repeat.
  final _held = <LogicalKeyboardKey>{};

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  void _onTick(Duration elapsed) {
    final dt = _last == Duration.zero
        ? 0.0
        : (elapsed - _last).inMicroseconds / 1000000;
    _last = elapsed;
    if (dt <= 0) return;

    var next = _state;
    // Keyboard steering, at a speed that crosses the board in about a second.
    if (_held.contains(LogicalKeyboardKey.arrowLeft)) {
      next = next.withPaddle(next.paddleX - dt);
    }
    if (_held.contains(LogicalKeyboardKey.arrowRight)) {
      next = next.withPaddle(next.paddleX + dt);
    }
    next = next.step(dt);
    if (!mounted) return;
    setState(() => _state = next);
  }

  void _restart() => setState(() {
    _state = BrickBreakerState.newGame();
    _last = Duration.zero;
  });

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent || event is KeyRepeatEvent) {
      if (event.logicalKey == LogicalKeyboardKey.space) {
        setState(() {
          _state = _state.outcome == GameOutcome.playing
              ? _state.launch()
              : BrickBreakerState.newGame();
        });
        return KeyEventResult.handled;
      }
      _held.add(event.logicalKey);
      return KeyEventResult.handled;
    }
    if (event is KeyUpEvent) {
      _held.remove(event.logicalKey);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Brick Breaker'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Center(
              child: Text(
                'Score ${_state.score}   Lives ${_state.lives}',
                style: theme.textTheme.bodyMedium,
              ),
            ),
          ),
          IconButton(
            tooltip: 'Restart',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _restart,
          ),
        ],
      ),
      body: Focus(
        autofocus: true,
        onKeyEvent: _onKey,
        child: LayoutBuilder(
          builder: (context, constraints) {
            // A square board, centred: the physics is in unit coordinates, so a
            // stretched board would change the angles.
            final side = constraints.biggest.shortestSide;
            return Center(
              child: SizedBox.square(
                dimension: side,
                child: MouseRegion(
                  onHover: (event) => setState(
                    () => _state = _state.withPaddle(event.localPosition.dx / side),
                  ),
                  child: GestureDetector(
                    onTapDown: (_) => setState(() {
                      _state = _state.outcome == GameOutcome.playing
                          ? _state.launch()
                          : BrickBreakerState.newGame();
                    }),
                    onHorizontalDragUpdate: (details) => setState(
                      () => _state = _state.withPaddle(
                        details.localPosition.dx / side,
                      ),
                    ),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        CustomPaint(
                          painter: _BoardPainter(
                            state: _state,
                            scheme: theme.colorScheme,
                          ),
                        ),
                        if (!_state.launched ||
                            _state.outcome != GameOutcome.playing)
                          Center(
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 20,
                                vertical: 12,
                              ),
                              decoration: BoxDecoration(
                                color: theme.colorScheme.surface.withValues(
                                  alpha: 0.85,
                                ),
                                borderRadius: BorderRadius.circular(16),
                              ),
                              child: Text(
                                switch (_state.outcome) {
                                  GameOutcome.won =>
                                    'Cleared, ${_state.score} points — '
                                        'space to play again',
                                  GameOutcome.lost =>
                                    'Out of lives, ${_state.score} points — '
                                        'space to play again',
                                  GameOutcome.playing =>
                                    'Space or click to launch',
                                },
                                style: theme.textTheme.titleMedium,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _BoardPainter extends CustomPainter {
  _BoardPainter({required this.state, required this.scheme});

  final BrickBreakerState state;
  final ColorScheme scheme;

  @override
  void paint(Canvas canvas, Size size) {
    final side = size.width;
    Offset at(double x, double y) => Offset(x * side, y * side);

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Offset.zero & size,
        const Radius.circular(16),
      ),
      Paint()..color = scheme.surfaceContainerHighest,
    );

    for (final brick in state.bricks) {
      final (left, top, right, bottom) = BrickBreakerState.rectFor(brick);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromPoints(at(left, top), at(right, bottom)),
          const Radius.circular(4),
        ),
        Paint()
          ..color = brick.hits > 1
              ? scheme.primary
              : scheme.primary.withValues(alpha: 0.55),
      );
    }

    final paddleTop = BrickBreakerState.paddleY - BrickBreakerState.paddleHeight;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromPoints(
          at(state.paddleX - BrickBreakerState.paddleWidth / 2, paddleTop),
          at(
            state.paddleX + BrickBreakerState.paddleWidth / 2,
            BrickBreakerState.paddleY,
          ),
        ),
        const Radius.circular(8),
      ),
      Paint()..color = scheme.secondary,
    );

    canvas.drawCircle(
      at(state.ball.x, state.ball.y),
      BrickBreakerState.ballRadius * side,
      Paint()..color = scheme.tertiary,
    );
  }

  @override
  bool shouldRepaint(_BoardPainter old) =>
      old.state != state || old.scheme != scheme;
}
