import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pixelplay_desktop/data/models/models.dart';
import 'package:pixelplay_desktop/platform/notifications.dart';
import 'package:pixelplay_desktop/platform/single_instance.dart';
import 'package:pixelplay_desktop/platform/tray.dart';

/// The desktop shell: opening files from a file manager, the tray menu, and what
/// a notification says. None of it needs a tray or a notification daemon to be
/// tested — the parts that talk to the desktop are thin, and the parts that
/// decide what to say are pure.

Song _song({
  String title = 'Al Sudeste',
  String artist = 'Moneda Dura',
  String album = 'Sin Blasfemias',
  String? albumArtPath,
  String id = '/music/a.mp3',
}) => Song(
  id: id,
  title: title,
  artist: artist,
  artistId: 1,
  album: album,
  albumId: 1,
  albumArtPath: albumArtPath,
  path: id,
  duration: 200000,
);

void main() {
  group('files from a command line', () {
    test('audio files are picked out', () {
      expect(
        openableFiles(['/music/a.mp3', '/music/b.flac']),
        ['/music/a.mp3', '/music/b.flac'],
      );
    });

    test('Flutter\'s own switches are ignored', () {
      // The engine puts its arguments in the same list.
      expect(
        openableFiles(['--enable-dart-profiling', '/music/a.mp3']),
        ['/music/a.mp3'],
      );
    });

    test('a file URI from a file manager is turned into a path', () {
      // Nautilus and Dolphin hand over file:// URIs, not paths.
      expect(
        openableFiles(['file:///music/my%20song.mp3']),
        ['/music/my song.mp3'],
      );
    });

    test('other URI schemes are left to whoever owns them', () {
      expect(openableFiles(['https://example.com/a.mp3']), isEmpty);
      expect(openableFiles(['smb://server/a.mp3']), isEmpty);
    });

    test('non-audio files are not opened', () {
      expect(openableFiles(['/docs/notes.txt', '/pics/a.png']), isEmpty);
    });

    test('extensions match whatever their case', () {
      expect(openableFiles(['/music/A.MP3', '/music/B.FlAc']), hasLength(2));
    });

    test('an empty command line yields nothing', () {
      expect(openableFiles(const []), isEmpty);
    });
  });

  group('the hand-over message', () {
    String message(Object? body) => jsonEncode(body);

    test('a well-formed message with the right token is accepted', () {
      expect(
        SingleInstance.filesFromMessage(
          message({'token': 'secret', 'files': ['/music/a.mp3']}),
          expected: 'secret',
        ),
        ['/music/a.mp3'],
      );
    });

    test('a wrong token is refused', () {
      // The token is what stops another user on the machine from making this
      // app open arbitrary paths.
      expect(
        SingleInstance.filesFromMessage(
          message({'token': 'guessed', 'files': ['/music/a.mp3']}),
          expected: 'secret',
        ),
        isEmpty,
      );
    });

    test('a missing token is refused', () {
      expect(
        SingleInstance.filesFromMessage(
          message({'files': ['/music/a.mp3']}),
          expected: 'secret',
        ),
        isEmpty,
      );
    });

    test('nothing is accepted when we have no token to compare against', () {
      // An unreadable token file must fail closed, not open.
      expect(
        SingleInstance.filesFromMessage(
          message({'token': '', 'files': ['/music/a.mp3']}),
          expected: '',
        ),
        isEmpty,
      );
    });

    test('non-audio paths in a valid message are still dropped', () {
      expect(
        SingleInstance.filesFromMessage(
          message({
            'token': 'secret',
            'files': ['/etc/shadow', '/music/a.mp3'],
          }),
          expected: 'secret',
        ),
        ['/music/a.mp3'],
      );
    });

    test('a flood is capped', () {
      final files = List.generate(5000, (i) => '/music/$i.mp3');
      expect(
        SingleInstance.filesFromMessage(
          message({'token': 'secret', 'files': files}),
          expected: 'secret',
        ),
        hasLength(512),
      );
    });

    test('garbage is refused without throwing', () {
      for (final text in ['', 'not json', '[]', '{"files":"a.mp3"}', 'null']) {
        expect(
          SingleInstance.filesFromMessage(text, expected: 'secret'),
          isEmpty,
          reason: text,
        );
      }
    });

    test('a non-string entry does not break the list', () {
      expect(
        SingleInstance.filesFromMessage(
          message({'token': 'secret', 'files': [42, '/music/a.mp3', null]}),
          expected: 'secret',
        ),
        ['/music/a.mp3'],
      );
    });
  });

  group('claiming the instance', () {
    late Directory dir;

    setUp(() => dir = Directory.systemTemp.createTempSync('pixelplay-test'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('the first claim wins and the second hands over', () async {
      // Skipped rather than failed when the port is busy: a real PixelPlayer
      // running on this machine holds it, and that is not a test failure.
      final free = await _portIsFree(SingleInstance.port);
      if (!free) {
        markTestSkipped('port ${SingleInstance.port} is in use');
        return;
      }

      final first = await SingleInstance.claim(
        const [],
        stateDirectory: dir.path,
      );
      expect(first, isNotNull);
      expect(first!.canReceive, isTrue);

      final handed = first.opened.first;
      final second = await SingleInstance.claim(
        const ['/music/handed.mp3'],
        stateDirectory: dir.path,
      );
      // Null means "this process should exit" — the files went to the first.
      expect(second, isNull);
      expect(await handed, ['/music/handed.mp3']);

      await first.dispose();
    });

    test('a token file is written for the second copy to find', () async {
      final free = await _portIsFree(SingleInstance.port);
      if (!free) {
        markTestSkipped('port ${SingleInstance.port} is in use');
        return;
      }
      final first = await SingleInstance.claim(
        const [],
        stateDirectory: dir.path,
      );
      final token = File('${dir.path}/instance.token');
      expect(token.existsSync(), isTrue);
      expect(token.readAsStringSync(), hasLength(64));
      await first!.dispose();
    });
  });

  group('the tray menu', () {
    test('transport is disabled with an empty queue', () {
      // Offering Play with nothing to play is a button that does nothing.
      final entries = trayEntries(
        nowPlaying: null,
        playing: false,
        hasQueue: false,
      );
      final actions = {
        for (final entry in entries)
          if (entry.action != null) entry.action!: entry.enabled,
      };
      expect(actions[TrayAction.playPause], isFalse);
      expect(actions[TrayAction.next], isFalse);
      // Showing the window and quitting always work.
      expect(actions[TrayAction.show], isTrue);
      expect(actions[TrayAction.quit], isTrue);
    });

    test('the label follows what is playing', () {
      expect(
        trayEntries(nowPlaying: 'A — B', playing: true, hasQueue: true)
            .first
            .label,
        'A — B',
      );
      expect(
        trayEntries(nowPlaying: null, playing: false, hasQueue: true)
            .map((e) => e.action)
            .first,
        TrayAction.playPause,
      );
    });

    test('play becomes pause while playing', () {
      String labelFor(bool playing) => trayEntries(
        nowPlaying: null,
        playing: playing,
        hasQueue: true,
      ).firstWhere((e) => e.action == TrayAction.playPause).label!;

      expect(labelFor(true), 'Pause');
      expect(labelFor(false), 'Play');
    });

    test('a long title is shortened rather than stretching the menu', () {
      final entry = trayEntries(
        nowPlaying: 'x' * 200,
        playing: true,
        hasQueue: true,
      ).first;
      expect(entry.label!.length, lessThanOrEqualTo(48));
      expect(entry.label, endsWith('…'));
    });

    test('every action key round-trips', () {
      // The menu and the click handler agree only if these match.
      for (final action in TrayAction.values) {
        expect(TrayAction.fromKey(action.key), action);
      }
      expect(TrayAction.fromKey('nonsense'), isNull);
      expect(TrayAction.fromKey(null), isNull);
    });
  });

  group('what a notification says', () {
    test('title on top, artist and album below', () {
      final content = nowPlayingContent(_song());
      expect(content.summary, 'Al Sudeste');
      expect(content.body, 'Moneda Dura · Sin Blasfemias');
    });

    test('an album that repeats the artist is not said twice', () {
      final content = nowPlayingContent(
        _song(artist: 'Adele', album: 'Adele'),
      );
      expect(content.body, 'Adele');
    });

    test('a track with no tags still says something', () {
      final content = nowPlayingContent(_song(title: '', artist: '', album: ''));
      expect(content.summary, 'Unknown track');
      expect(content.body, isEmpty);
    });

    test('cover art is passed as a URI', () {
      expect(
        nowPlayingContent(_song(albumArtPath: '/cache/art.jpg')).iconPath,
        'file:///cache/art.jpg',
      );
      expect(nowPlayingContent(_song()).iconPath, isNull);
    });

    test('buttons are offered only when the server can draw them', () {
      // Sending actions to a server without the capability means a popup whose
      // buttons silently are not there.
      expect(
        notificationActions(serverSupportsActions: false, playing: true),
        isEmpty,
      );

      final actions = notificationActions(
        serverSupportsActions: true,
        playing: true,
      );
      // Pairs of key and label, per the specification.
      expect(actions.length.isEven, isTrue);
      expect(actions, contains('previous'));
      expect(actions, contains('next'));
      expect(actions, contains('Pause'));
      expect(actions, isNot(contains('Play')));
    });

    test('the middle button says Play when paused', () {
      expect(
        notificationActions(serverSupportsActions: true, playing: false),
        contains('Play'),
      );
    });
  });
}

Future<bool> _portIsFree(int port) async {
  try {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
    await socket.close();
    return true;
  } on SocketException {
    return false;
  }
}
