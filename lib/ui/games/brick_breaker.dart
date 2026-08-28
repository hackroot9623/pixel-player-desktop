import 'dart:math';

// The easter egg, ported from the Android app's BrickBreaker.
//
// The board is a unit square: 0..1 on both axes, with y growing downwards like
// the screen. Nothing here knows about pixels or widgets, so the rules — where
// the ball goes, what it hits, when a life is lost — are testable without a frame
// being drawn, which is the only way to be sure a corner bounce is not a
// tunnelling bug.

/// How the game ended, or that it has not.
enum GameOutcome { playing, won, lost }

class Brick {
  const Brick({
    required this.column,
    required this.row,
    required this.hits,
  });

  final int column;
  final int row;

  /// Hits left. Two-hit bricks in the back rows give the grid some shape.
  final int hits;

  Brick hit() => Brick(column: column, row: row, hits: hits - 1);
}

/// The board, as a value. [step] returns the next one.
class BrickBreakerState {
  const BrickBreakerState({
    required this.ball,
    required this.velocity,
    required this.paddleX,
    required this.bricks,
    this.score = 0,
    this.lives = 3,
    this.outcome = GameOutcome.playing,
    this.launched = false,
  });

  /// Ball centre, in board units.
  final Point<double> ball;

  /// Board units per second.
  final Point<double> velocity;

  /// Paddle centre on the x axis.
  final double paddleX;

  final List<Brick> bricks;
  final int score;
  final int lives;
  final GameOutcome outcome;

  /// False while the ball sits on the paddle waiting to be sent off.
  final bool launched;

  static const columns = 8;
  static const rows = 5;

  static const ballRadius = 0.018;
  static const paddleWidth = 0.22;
  static const paddleHeight = 0.025;

  /// The paddle sits this far above the bottom.
  static const paddleY = 0.94;

  static const brickTop = 0.08;
  static const brickHeight = 0.045;
  static const brickGap = 0.006;

  static double get brickWidth => 1 / columns;

  /// A fresh game.
  static BrickBreakerState newGame() => BrickBreakerState(
    ball: const Point(0.5, paddleY - ballRadius - paddleHeight),
    // Straight up until the player launches, which never happens while
    // `launched` is false.
    velocity: const Point(0.42, -0.62),
    paddleX: 0.5,
    bricks: [
      for (var row = 0; row < rows; row++)
        for (var column = 0; column < columns; column++)
          Brick(
            column: column,
            row: row,
            // The two back rows take two hits, so clearing the board has a
            // shape rather than being uniform.
            hits: row < 2 ? 2 : 1,
          ),
    ],
  );

  BrickBreakerState copyWith({
    Point<double>? ball,
    Point<double>? velocity,
    double? paddleX,
    List<Brick>? bricks,
    int? score,
    int? lives,
    GameOutcome? outcome,
    bool? launched,
  }) => BrickBreakerState(
    ball: ball ?? this.ball,
    velocity: velocity ?? this.velocity,
    paddleX: paddleX ?? this.paddleX,
    bricks: bricks ?? this.bricks,
    score: score ?? this.score,
    lives: lives ?? this.lives,
    outcome: outcome ?? this.outcome,
    launched: launched ?? this.launched,
  );

  /// Moves the paddle, clamped so it stays on the board.
  ///
  /// The ball rides along with it before launch, which is what makes aiming the
  /// first shot possible.
  BrickBreakerState withPaddle(double x) {
    final clamped = x.clamp(paddleWidth / 2, 1 - paddleWidth / 2);
    return copyWith(
      paddleX: clamped,
      ball: launched
          ? ball
          : Point(clamped, paddleY - ballRadius - paddleHeight),
    );
  }

  BrickBreakerState launch() =>
      outcome == GameOutcome.playing ? copyWith(launched: true) : this;

  /// The rectangle a brick occupies, as (left, top, right, bottom).
  static (double, double, double, double) rectFor(Brick brick) {
    final left = brick.column * brickWidth + brickGap / 2;
    final top = brickTop + brick.row * (brickHeight + brickGap);
    return (left, top, left + brickWidth - brickGap, top + brickHeight);
  }

  /// One frame.
  ///
  /// [dt] is clamped: a stalled frame — a slow rescan, a dragged window — would
  /// otherwise move the ball far enough to pass straight through a brick.
  BrickBreakerState step(double dt) {
    if (outcome != GameOutcome.playing || !launched) return this;
    final delta = dt.clamp(0.0, 1 / 30);

    var vx = velocity.x;
    var vy = velocity.y;
    var x = ball.x + vx * delta;
    var y = ball.y + vy * delta;

    // Walls.
    if (x - ballRadius <= 0) {
      x = ballRadius;
      vx = vx.abs();
    } else if (x + ballRadius >= 1) {
      x = 1 - ballRadius;
      vx = -vx.abs();
    }
    if (y - ballRadius <= 0) {
      y = ballRadius;
      vy = vy.abs();
    }

    // Paddle. Only when travelling downwards, or a ball that clips the edge can
    // get stuck inside it.
    final paddleTop = paddleY - paddleHeight;
    if (vy > 0 &&
        y + ballRadius >= paddleTop &&
        y - ballRadius <= paddleY &&
        (x - paddleX).abs() <= paddleWidth / 2 + ballRadius) {
      y = paddleTop - ballRadius;
      vy = -vy.abs();
      // Where it hit decides the angle: this is the whole skill of the game.
      final offset = ((x - paddleX) / (paddleWidth / 2)).clamp(-1.0, 1.0);
      final speed = sqrt(vx * vx + vy * vy);
      final angle = offset * (pi / 3);
      vx = speed * sin(angle);
      vy = -speed * cos(angle);
    }

    // Bricks: at most one per frame, so a ball cannot clear a column in a step.
    var score = this.score;
    var bricks = this.bricks;
    for (final brick in bricks) {
      final (left, top, right, bottom) = rectFor(brick);
      if (x + ballRadius < left ||
          x - ballRadius > right ||
          y + ballRadius < top ||
          y - ballRadius > bottom) {
        continue;
      }

      // Bounce off whichever side it came through: the smaller overlap is the
      // one it crossed.
      final overlapX = min((x + ballRadius) - left, right - (x - ballRadius));
      final overlapY = min((y + ballRadius) - top, bottom - (y - ballRadius));
      if (overlapX < overlapY) {
        vx = -vx;
        x += vx > 0 ? overlapX : -overlapX;
      } else {
        vy = -vy;
        y += vy > 0 ? overlapY : -overlapY;
      }

      final damaged = brick.hit();
      bricks = [
        for (final other in bricks)
          if (other.column != brick.column || other.row != brick.row)
            other
          else if (damaged.hits > 0)
            damaged,
      ];
      score += damaged.hits > 0 ? 10 : 25;
      break;
    }

    // Below the paddle: a life.
    if (y - ballRadius > 1) {
      final remaining = lives - 1;
      if (remaining <= 0) {
        return copyWith(
          lives: 0,
          outcome: GameOutcome.lost,
          launched: false,
          score: score,
          bricks: bricks,
        );
      }
      return copyWith(
        lives: remaining,
        launched: false,
        ball: Point(paddleX, paddleY - ballRadius - paddleHeight),
        velocity: const Point(0.42, -0.62),
        score: score,
        bricks: bricks,
      );
    }

    return copyWith(
      ball: Point(x, y),
      velocity: Point(vx, vy),
      bricks: bricks,
      score: score,
      outcome: bricks.isEmpty ? GameOutcome.won : GameOutcome.playing,
    );
  }
}
