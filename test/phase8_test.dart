import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:pixelplay_desktop/data/backup/backup_format.dart';
import 'package:pixelplay_desktop/data/diagnostics/diagnostics.dart';
import 'package:pixelplay_desktop/data/models/models.dart';
import 'package:pixelplay_desktop/data/update/update_check.dart';
import 'package:pixelplay_desktop/ui/games/brick_breaker.dart';

/// Backup, updates, diagnostics and the easter egg. The parts that matter are
/// pure by design: what a backup file says, whether one version is newer than
/// another, and where the ball goes.

Song _song({
  String path = '/music/a.mp3',
  String title = 'Al Sudeste',
  String artist = 'Moneda Dura',
  String album = 'Sin Blasfemias',
}) => Song(
  id: path,
  title: title,
  artist: artist,
  artistId: 1,
  album: album,
  albumId: 1,
  path: path,
  duration: 200000,
);

void main() {
  group('backup files', () {
    BackupFile file({Map<String, Object?>? modules}) => BackupFile(
      createdAt: DateTime.utc(2026, 3, 1, 12),
      appVersion: '1.0.0',
      platform: 'linux',
      modules: modules ?? {'favorites': []},
    );

    test('a file round-trips', () {
      final original = file(
        modules: {
          'favorites': [SongRef.of(_song()).toJson()],
          'search_history': ['moneda'],
        },
      );
      final restored = BackupFile.decode(original.encode());

      expect(restored.appVersion, '1.0.0');
      expect(restored.platform, 'linux');
      expect(restored.createdAt, original.createdAt);
      expect(restored.sections, [
        BackupSection.favorites,
        BackupSection.searchHistory,
      ]);
      expect(restored.listFor(BackupSection.searchHistory), ['moneda']);
    });

    test('the file says what it is, and something else is refused', () {
      expect(jsonDecode(file().encode())['format'], backupFormat);
      expect(
        () => BackupFile.decode('{"format":"something-else","version":1}'),
        throwsA(
          isA<BackupException>().having(
            (e) => e.message,
            'message',
            contains('not a PixelPlayer backup'),
          ),
        ),
      );
    });

    test('a backup from a newer version is refused, not half-read', () {
      // Reading unknown sections optimistically is how a restore corrupts
      // something.
      expect(
        () => BackupFile.decode(
          '{"format":"$backupFormat","version":99,"modules":{}}',
        ),
        throwsA(
          isA<BackupException>().having(
            (e) => e.message,
            'message',
            contains('newer version'),
          ),
        ),
      );
    });

    test('junk is refused with something readable', () {
      for (final text in ['', 'not json', '[]', '{"version":1}']) {
        expect(
          () => BackupFile.decode(text),
          throwsA(isA<BackupException>()),
          reason: text,
        );
      }
    });

    test('unknown sections survive a round trip', () {
      // A file written by a newer build can still be read by this one without
      // losing the parts it does not understand.
      final restored = BackupFile.decode(
        file(modules: {'favorites': [], 'from_the_future': [1, 2]}).encode(),
      );
      expect(restored.modules.containsKey('from_the_future'), isTrue);
      // But they are not offered as restorable sections.
      expect(restored.sections, [BackupSection.favorites]);
    });

    test('a payload of the wrong shape reads as absent', () {
      final restored = BackupFile.decode(
        file(modules: {'favorites': 'not a list'}).encode(),
      );
      expect(restored.listFor(BackupSection.favorites), isNull);
    });

    test('every section has a distinct key', () {
      // The keys are the file format; a collision would silently overwrite.
      final keys = BackupSection.values.map((s) => s.key).toList();
      expect(keys.toSet(), hasLength(keys.length));
      for (final section in BackupSection.values) {
        expect(BackupSection.fromKey(section.key), section);
      }
      expect(BackupSection.fromKey('nonsense'), isNull);
    });
  });

  group('secrets never reach a backup', () {
    test('the obvious names are refused', () {
      // A backup is a file people email to themselves.
      for (final key in [
        'ai_api_key',
        'openai_apikey',
        'jellyfin_password',
        'spotify_refresh_token',
        'drive_client_secret',
        'telegram_api_hash',
        'some_access_token',
        'remote_accounts',
      ]) {
        expect(isSecretPreference(key), isTrue, reason: key);
      }
    });

    test('ordinary preferences are allowed', () {
      for (final key in [
        'theme_mode',
        'volume',
        'equalizer',
        'music_folders',
        'shuffle',
        'check_updates',
      ]) {
        expect(isSecretPreference(key), isFalse, reason: key);
      }
    });
  });

  group('matching songs across machines', () {
    test('an exact path wins', () {
      final matcher = SongMatcher([_song(path: '/music/a.mp3')]);
      expect(
        matcher.match(SongRef.of(_song(path: '/music/a.mp3')))?.path,
        '/music/a.mp3',
      );
    });

    test('a moved library still matches by tags', () {
      // The whole reason tags are stored alongside the path: a backup restored
      // on another machine, or after the music moved.
      final matcher = SongMatcher([_song(path: '/mnt/media/music/a.mp3')]);
      final ref = SongRef.of(_song(path: '/home/old/a.mp3'));
      expect(matcher.match(ref)?.path, '/mnt/media/music/a.mp3');
    });

    test('punctuation and case do not stop a tag match', () {
      final matcher = SongMatcher([
        _song(path: '/new/a.mp3', title: 'Al  Sudeste!', artist: 'MONEDA DURA'),
      ]);
      expect(
        matcher.match(SongRef.of(_song(path: '/old/a.mp3'))),
        isNotNull,
      );
    });

    test('a different song is not matched', () {
      final matcher = SongMatcher([
        _song(path: '/new/b.mp3', title: 'Something Else', artist: 'Nobody'),
      ]);
      expect(matcher.match(SongRef.of(_song(path: '/old/a.mp3'))), isNull);
    });

    test('a reference with no tags and no path match yields nothing', () {
      // Better a reported skip than the wrong song in a playlist.
      final matcher = SongMatcher([_song(path: '/new/a.mp3')]);
      expect(
        matcher.match(
          const SongRef(path: '/old/a.mp3', title: '', artist: '', album: ''),
        ),
        isNull,
      );
    });

    test('an empty library matches nothing without throwing', () {
      expect(SongMatcher(const []).match(SongRef.of(_song())), isNull);
    });

    test('a bad reference in a file is skipped', () {
      expect(SongRef.fromJson(null), isNull);
      expect(SongRef.fromJson({'title': 'no path'}), isNull);
      expect(SongRef.fromJson({'path': '/a.mp3'})?.title, isEmpty);
    });
  });

  group('the restore report', () {
    test('counts add up per section', () {
      final report = RestoreReport()
        ..add(BackupSection.playlists, restored: 3, skipped: 2)
        ..add(BackupSection.playlists, restored: 1)
        ..add(BackupSection.favorites, restored: 5);

      expect(report.restored[BackupSection.playlists], 4);
      expect(report.skipped[BackupSection.playlists], 2);
      expect(report.totalRestored, 9);
      expect(report.totalSkipped, 2);
      expect(report.anythingRestored, isTrue);
    });

    test('a restore that did nothing says so', () {
      final report = RestoreReport()..add(BackupSection.favorites, skipped: 4);
      expect(report.anythingRestored, isFalse);
      expect(report.totalSkipped, 4);
    });
  });

  group('version comparison', () {
    test('numbers are compared as numbers', () {
      // The bug string comparison would introduce.
      expect(compareVersions('1.10.0', '1.9.0'), greaterThan(0));
      expect(compareVersions('2.0.0', '10.0.0'), lessThan(0));
    });

    test('equal versions compare equal, however they are written', () {
      expect(compareVersions('1.2.3', '1.2.3'), 0);
      expect(compareVersions('v1.2.3', '1.2.3'), 0);
      expect(compareVersions('1.2', '1.2.0'), 0);
    });

    test('a suffix does not change the ordering', () {
      expect(compareVersions('1.2.3-beta', '1.2.3'), 0);
      expect(compareVersions('1.2.4-beta', '1.2.3'), greaterThan(0));
    });

    test('nonsense sorts oldest rather than throwing', () {
      expect(compareVersions('unknown', '1.0.0'), lessThan(0));
      expect(compareVersions('', '0.0.1'), lessThan(0));
    });
  });

  group('picking a release', () {
    Release release(String tag, {bool prerelease = false}) =>
        Release(tag: tag, url: 'https://example/$tag', isPrerelease: prerelease);

    test('the newest version tag wins, not the newest publish', () {
      expect(
        pickLatestRelease([
          release('v1.2.0'),
          release('v1.10.0'),
          release('v1.9.9'),
        ])?.version,
        '1.10.0',
      );
    });

    test('the rolling build is ignored', () {
      // CI publishes a `latest` prerelease on every push; it is not a version.
      expect(
        pickLatestRelease([release('latest', prerelease: true), release('v1.1.0')])
            ?.version,
        '1.1.0',
      );
      expect(pickLatestRelease([release('latest')]), isNull);
    });

    test('a versioned prerelease is still offered', () {
      // The releases here are prereleases by policy, so skipping them would
      // mean never reporting an update at all.
      expect(
        pickLatestRelease([release('v2.0.0', prerelease: true)])?.version,
        '2.0.0',
      );
    });

    test('nothing at all yields nothing', () {
      expect(pickLatestRelease(const []), isNull);
    });
  });

  group('reading the releases list', () {
    test('a GitHub payload is read', () {
      final releases = parseReleases(jsonEncode([
        {
          'tag_name': 'v1.1.0',
          'html_url': 'https://github.com/x/y/releases/tag/v1.1.0',
          'name': 'PixelPlayer 1.1.0',
          'body': 'notes',
          'published_at': '2026-03-01T10:00:00Z',
          'prerelease': true,
        },
      ]));

      expect(releases, hasLength(1));
      expect(releases.first.version, '1.1.0');
      expect(releases.first.isPrerelease, isTrue);
      expect(releases.first.publishedAt, isNotNull);
    });

    test('drafts are skipped', () {
      // A draft is not published; offering it sends the user to a 404.
      final releases = parseReleases(jsonEncode([
        {'tag_name': 'v9.9.9', 'draft': true},
        {'tag_name': 'v1.0.0'},
      ]));
      expect(releases.map((r) => r.tag), ['v1.0.0']);
    });

    test('an entry with no tag is skipped, not guessed at', () {
      expect(parseReleases(jsonEncode([{'name': 'no tag'}])), isEmpty);
    });

    test('garbage yields an empty list', () {
      expect(parseReleases('not json'), isEmpty);
      expect(parseReleases('{}'), isEmpty);
    });

    test('an update is only reported when it is actually newer', () {
      const older = Release(tag: 'v1.0.0', url: 'u');
      const newer = Release(tag: 'v1.1.0', url: 'u');

      expect(
        const UpdateStatus(currentVersion: '1.0.0', latest: newer).hasUpdate,
        isTrue,
      );
      expect(
        const UpdateStatus(currentVersion: '1.1.0', latest: newer).hasUpdate,
        isFalse,
      );
      // Running something newer than the newest release is not a downgrade
      // prompt.
      expect(
        const UpdateStatus(currentVersion: '1.2.0', latest: older).hasUpdate,
        isFalse,
      );
      expect(
        const UpdateStatus(currentVersion: '1.2.0', latest: older).isCurrent,
        isTrue,
      );
      // Nothing fetched yet is neither.
      expect(const UpdateStatus(currentVersion: '1.0.0').hasUpdate, isFalse);
      expect(const UpdateStatus(currentVersion: '1.0.0').isCurrent, isFalse);
    });

    test('a check that found no numbered release says so', () {
      // The live state of this repository: CI publishes a rolling `latest`
      // prerelease and no v-tag exists, so there is nothing to compare against.
      // Claiming "up to date" would be asserting what the app cannot know.
      const status = UpdateStatus(currentVersion: '1.0.0');
      expect(status.noReleases, isTrue);
      expect(status.isCurrent, isFalse);
      expect(status.hasUpdate, isFalse);

      // An error is a different thing from finding nothing.
      const failed = UpdateStatus(currentVersion: '1.0.0', error: 'offline');
      expect(failed.noReleases, isFalse);
    });
  });

  group('diagnostics', () {
    test('the report is readable and marks what is missing', () {
      final text = formatDiagnostics([
        const DiagnosticsSection('App', [
          Diagnostic('Version', '1.0.0'),
          Diagnostic('yt-dlp', 'not installed', ok: false),
          Diagnostic('TDLib', '/usr/lib/libtdjson.so', ok: true),
        ]),
      ]);

      expect(text, contains('## App'));
      expect(text, contains('Version: 1.0.0'));
      expect(text, contains('[miss] yt-dlp'));
      expect(text, contains('[ok]   TDLib'));
    });

    test('a missing binary is an answer, not an error', () async {
      expect(
        await probeVersion('definitely-not-a-real-binary-xyz', ['--version']),
        isNull,
      );
    });

    test('a version probe returns the first line only', () async {
      Future<ProcessResultLike> fake(String _, List<String> __) async =>
          ProcessResultLike(0, '2026.03.01\nextra noise');
      expect(
        await probeVersion(
          'anything',
          const [],
          run: (executable, arguments) async {
            final result = await fake(executable, arguments);
            return result.asProcessResult();
          },
        ),
        '2026.03.01',
      );
    });

    test('a non-zero exit is treated as absent', () async {
      expect(
        await probeVersion(
          'anything',
          const [],
          run: (_, __) async => ProcessResultLike(1, 'boom').asProcessResult(),
        ),
        isNull,
      );
    });

    test('a library that is not there is reported as such', () {
      expect(findLibrary(const ['libdefinitelynothere.so.999']), isNull);
      expect(findLibrary(const []), isNull);
    });
  });

  group('brick breaker', () {
    test('a new game is full and waiting', () {
      final game = BrickBreakerState.newGame();
      expect(
        game.bricks,
        hasLength(BrickBreakerState.columns * BrickBreakerState.rows),
      );
      expect(game.launched, isFalse);
      expect(game.lives, 3);
      expect(game.outcome, GameOutcome.playing);
    });

    test('nothing moves before launch', () {
      final game = BrickBreakerState.newGame();
      final stepped = game.step(0.016);
      expect(stepped.ball, game.ball);
    });

    test('the ball rides the paddle before launch, and not after', () {
      final game = BrickBreakerState.newGame().withPaddle(0.3);
      expect(game.ball.x, closeTo(0.3, 0.0001));

      final launched = game.launch().withPaddle(0.7);
      expect(launched.ball.x, closeTo(0.3, 0.0001));
      expect(launched.paddleX, closeTo(0.7, 0.0001));
    });

    test('the paddle cannot leave the board', () {
      const half = BrickBreakerState.paddleWidth / 2;
      expect(BrickBreakerState.newGame().withPaddle(-1).paddleX, half);
      expect(BrickBreakerState.newGame().withPaddle(2).paddleX, 1 - half);
    });

    test('the ball bounces off a side wall', () {
      var game = BrickBreakerState.newGame().launch().copyWith(
        ball: const Point(0.02, 0.5),
        velocity: const Point(-0.5, 0.1),
        bricks: const [],
      );
      game = game.step(0.1);
      expect(game.velocity.x, greaterThan(0));
      expect(game.ball.x, greaterThanOrEqualTo(BrickBreakerState.ballRadius));
    });

    test('the ball bounces off the ceiling', () {
      var game = BrickBreakerState.newGame().launch().copyWith(
        ball: const Point(0.5, 0.02),
        velocity: const Point(0.1, -0.5),
        bricks: const [],
      );
      game = game.step(0.1);
      expect(game.velocity.y, greaterThan(0));
    });

    test('the paddle sends the ball back up, angled by where it hit', () {
      BrickBreakerState hit(double offset) => BrickBreakerState.newGame()
          .launch()
          .copyWith(
            paddleX: 0.5,
            ball: Point(0.5 + offset, BrickBreakerState.paddleY - 0.03),
            velocity: const Point(0, 0.6),
            bricks: const [],
          )
          .step(1 / 60);

      // Middle: straight back up.
      expect(hit(0).velocity.y, lessThan(0));
      expect(hit(0).velocity.x.abs(), lessThan(0.01));
      // Right of centre: away to the right. Left: to the left.
      expect(hit(0.08).velocity.x, greaterThan(0));
      expect(hit(-0.08).velocity.x, lessThan(0));
    });

    test('speed is preserved by a paddle bounce', () {
      // Otherwise the angle change quietly makes the game faster or slower.
      final before = BrickBreakerState.newGame().launch().copyWith(
        paddleX: 0.5,
        ball: const Point(0.55, BrickBreakerState.paddleY - 0.03),
        velocity: const Point(0.3, 0.6),
        bricks: const [],
      );
      final after = before.step(1 / 60);
      double speed(Point<double> v) => sqrt(v.x * v.x + v.y * v.y);
      expect(speed(after.velocity), closeTo(speed(before.velocity), 0.001));
    });

    test('a brick is hit, scored and removed', () {
      const brick = Brick(column: 3, row: 4, hits: 1);
      final (left, top, right, bottom) = BrickBreakerState.rectFor(brick);
      final game = BrickBreakerState.newGame()
          .launch()
          .copyWith(
            bricks: const [brick],
            ball: Point((left + right) / 2, bottom + 0.01),
            velocity: const Point(0, -0.6),
          )
          .step(1 / 30);

      expect(game.bricks, isEmpty);
      expect(game.score, 25);
      // Sent back down the way it came.
      expect(game.velocity.y, greaterThan(0));
      expect(top, lessThan(bottom));
    });

    test('a two-hit brick survives the first hit and scores less', () {
      const brick = Brick(column: 0, row: 0, hits: 2);
      final (left, right) = (
        BrickBreakerState.rectFor(brick).$1,
        BrickBreakerState.rectFor(brick).$3,
      );
      final game = BrickBreakerState.newGame()
          .launch()
          .copyWith(
            bricks: const [brick],
            ball: Point(
              (left + right) / 2,
              BrickBreakerState.rectFor(brick).$4 + 0.01,
            ),
            velocity: const Point(0, -0.6),
          )
          .step(1 / 30);

      expect(game.bricks.single.hits, 1);
      expect(game.score, 10);
    });

    test('at most one brick per frame', () {
      // Otherwise a fast ball clears a whole column in a single step.
      const first = Brick(column: 0, row: 0, hits: 1);
      const second = Brick(column: 1, row: 0, hits: 1);
      final game = BrickBreakerState.newGame()
          .launch()
          .copyWith(
            bricks: const [first, second],
            ball: Point(
              BrickBreakerState.brickWidth,
              BrickBreakerState.rectFor(first).$2 + 0.01,
            ),
            velocity: const Point(0.9, -0.9),
          )
          .step(1 / 30);
      expect(game.bricks, hasLength(greaterThanOrEqualTo(1)));
    });

    test('clearing the board wins', () {
      const brick = Brick(column: 2, row: 2, hits: 1);
      final rect = BrickBreakerState.rectFor(brick);
      final game = BrickBreakerState.newGame()
          .launch()
          .copyWith(
            bricks: const [brick],
            ball: Point((rect.$1 + rect.$3) / 2, rect.$4 + 0.01),
            velocity: const Point(0, -0.6),
          )
          .step(1 / 30);
      expect(game.outcome, GameOutcome.won);
    });

    test('missing the ball costs a life and resets the ball', () {
      final game = BrickBreakerState.newGame().launch().copyWith(
        ball: const Point(0.5, 0.99),
        velocity: const Point(0, 0.9),
      );
      final after = game.step(1 / 30);

      expect(after.lives, 2);
      expect(after.launched, isFalse);
      expect(after.outcome, GameOutcome.playing);
      // Back on the paddle, ready to launch again.
      expect(after.ball.x, closeTo(after.paddleX, 0.0001));
    });

    test('the last life ends the game', () {
      final game = BrickBreakerState.newGame().launch().copyWith(
        lives: 1,
        ball: const Point(0.5, 0.99),
        velocity: const Point(0, 0.9),
      );
      final after = game.step(1 / 30);
      expect(after.outcome, GameOutcome.lost);
      expect(after.lives, 0);
      // A finished game does not keep simulating.
      expect(after.step(1 / 30).ball, after.ball);
    });

    test('a stalled frame cannot tunnel the ball through the board', () {
      // dt is clamped: a slow rescan or a dragged window would otherwise move
      // the ball further than a brick is thick.
      final game = BrickBreakerState.newGame().launch().copyWith(
        ball: const Point(0.5, 0.5),
        velocity: const Point(0, -0.6),
        bricks: const [],
      );
      final after = game.step(5);
      expect(after.ball.y, greaterThan(0));
      expect((after.ball.y - 0.5).abs(), lessThan(0.05));
    });

    test('bricks tile the board without overlapping', () {
      final game = BrickBreakerState.newGame();
      for (final brick in game.bricks) {
        final (left, top, right, bottom) = BrickBreakerState.rectFor(brick);
        expect(left, greaterThanOrEqualTo(0));
        expect(right, lessThanOrEqualTo(1));
        expect(right, greaterThan(left));
        expect(bottom, greaterThan(top));
        // Well clear of the paddle.
        expect(bottom, lessThan(BrickBreakerState.paddleY - 0.1));
      }
    });
  });
}

/// A stand-in for ProcessResult, which has no public constructor worth using in
/// a test.
class ProcessResultLike {
  ProcessResultLike(this.exitCode, this.stdout);

  final int exitCode;
  final String stdout;

  ProcessResult asProcessResult() => ProcessResult(0, exitCode, stdout, '');
}
