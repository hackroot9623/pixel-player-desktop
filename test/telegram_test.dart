import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pixelplay_desktop/data/remote/remote_account.dart';
import 'package:pixelplay_desktop/data/remote/telegram/tdlib_client.dart';
import 'package:pixelplay_desktop/data/remote/telegram/telegram_source.dart';

/// TDLib is a native library this machine does not have, so the transport is
/// faked. Everything above it — the login state machine, the request/reply
/// correlation, the message mapping — is real code under test; only the four
/// FFI symbol lookups are not exercised.
class _FakeTransport implements TdlibTransport {
  _FakeTransport();

  final sent = <Map<String, Object?>>[];
  final executed = <Map<String, Object?>>[];
  final _inbox = <String>[];

  /// Replies to hand back when a request of a given `@type` is sent.
  final replies = <String, Map<String, Object?>>{};

  /// Answers to give in order for one `@type`, ahead of [replies].
  final queued = <String, List<Map<String, Object?>>>{};

  int created = 0;
  var disposed = false;

  @override
  int createClientId() => ++created;

  @override
  void send(int clientId, String request) {
    final decoded = jsonDecode(request) as Map<String, Object?>;
    sent.add(decoded);
    final type = decoded['@type'] as String?;
    final extra = decoded['@extra'];

    final pending = queued[type];
    final reply = (pending != null && pending.isNotEmpty)
        ? pending.removeAt(0)
        : replies[type];
    if (reply == null) return;
    _inbox.add(
      jsonEncode({...reply, if (extra != null) '@extra': extra}),
    );
  }

  @override
  String? receive(double timeout) => _inbox.isEmpty ? null : _inbox.removeAt(0);

  @override
  String? execute(String request) {
    executed.add(jsonDecode(request) as Map<String, Object?>);
    return null;
  }

  @override
  void dispose() => disposed = true;

  /// Pushes an unsolicited update, the way TDLib does.
  void emit(Map<String, Object?> event) => _inbox.add(jsonEncode(event));

  void emitAuthState(String type, [Map<String, Object?> extra = const {}]) =>
      emit({
        '@type': 'updateAuthorizationState',
        'authorization_state': {'@type': type, ...extra},
      });
}

TdlibClient _client(_FakeTransport transport) => TdlibClient(
  transport: transport,
  apiId: 12345,
  apiHash: 'hash',
  databaseDirectory: '/tmp/td/db',
  filesDirectory: '/tmp/td/files',
);

RemoteAccount _account({String chats = '-100,42'}) => RemoteAccount(
  id: 'tg-1',
  kind: RemoteKind.telegram,
  serverUrl: '',
  username: '',
  password: '',
  extra: {'apiId': '12345', 'apiHash': 'hash', 'chats': chats},
);

Map<String, Object?> _audioMessage({
  int id = 1000,
  String? title = 'Al Sudeste',
  String? performer = 'Moneda Dura',
  String? album = 'Sin Blasfemias',
  int fileId = 77,
  int duration = 249,
  String mime = 'audio/mpeg',
  String? localPath,
  bool completed = false,
  int date = 1700000000,
}) => {
  'id': id,
  'date': date,
  'content': {
    '@type': 'messageAudio',
    'audio': {
      '@type': 'audio',
      'title': title,
      'performer': performer,
      'album': album,
      'duration': duration,
      'mime_type': mime,
      'file_name': 'track.mp3',
      'audio': {
        'id': fileId,
        'local': {
          'path': localPath ?? '',
          'is_downloading_completed': completed,
        },
      },
    },
  },
};

void main() {
  group('login', () {
    test('TDLib parameters are sent the moment it asks', () async {
      // TDLib refuses everything until it has been configured, so this has to
      // happen without any prompting from the UI.
      final transport = _FakeTransport();
      final client = _client(transport)..start();

      transport.emitAuthState('authorizationStateWaitTdlibParameters');
      client.drain();

      final params = transport.sent.firstWhere(
        (request) => request['@type'] == 'setTdlibParameters',
      );
      expect(params['api_id'], 12345);
      expect(params['api_hash'], 'hash');
      expect(params['database_directory'], '/tmp/td/db');
      expect(params['use_secret_chats'], false);
      await client.close();
    });

    test('it walks phone, code, password and lands on ready', () async {
      final transport = _FakeTransport();
      final client = _client(transport)..start();
      final seen = <TdAuthState>[];
      client.authStates.listen(seen.add);

      for (final state in [
        'authorizationStateWaitPhoneNumber',
        'authorizationStateWaitCode',
        'authorizationStateWaitPassword',
        'authorizationStateReady',
      ]) {
        transport.emitAuthState(state);
        client.drain();
      }
      await Future<void>.delayed(Duration.zero);

      expect(seen, [
        TdAuthState.waitPhoneNumber,
        TdAuthState.waitCode,
        TdAuthState.waitPassword,
        TdAuthState.ready,
      ]);
      expect(client.isReady, isTrue);
      await client.close();
    });

    test('an account that needs registering is not treated as ready', () async {
      final transport = _FakeTransport();
      final client = _client(transport)..start();
      transport.emitAuthState('authorizationStateWaitRegistration');
      client.drain();
      expect(client.authState, TdAuthState.waitRegistration);
      expect(client.isReady, isFalse);
      await client.close();
    });

    test('credentials are sent as TDLib expects them', () async {
      final transport = _FakeTransport()
        ..replies['setAuthenticationPhoneNumber'] = {'@type': 'ok'}
        ..replies['checkAuthenticationCode'] = {'@type': 'ok'}
        ..replies['checkAuthenticationPassword'] = {'@type': 'ok'};
      final client = _client(transport)..start();

      final phone = client.sendPhoneNumber(' +5351234567 ');
      client.drain();
      await phone;
      final code = client.sendCode(' 12345 ');
      client.drain();
      await code;
      final password = client.sendPassword('s3cret');
      client.drain();
      await password;

      expect(
        transport.sent
            .firstWhere(
              (r) => r['@type'] == 'setAuthenticationPhoneNumber',
            )['phone_number'],
        '+5351234567',
        reason: 'trimmed',
      );
      expect(
        transport.sent
            .firstWhere((r) => r['@type'] == 'checkAuthenticationCode')['code'],
        '12345',
      );
      expect(
        transport.sent.firstWhere(
          (r) => r['@type'] == 'checkAuthenticationPassword',
        )['password'],
        's3cret',
      );
      await client.close();
    });

    test('a wrong code is reported in words, not as a code', () async {
      // TDLib answers with an error object rather than failing the call, so
      // without this a wrong code just looks like nothing happening.
      final transport = _FakeTransport()
        ..replies['checkAuthenticationCode'] = {
          '@type': 'error',
          'code': 400,
          'message': 'PHONE_CODE_INVALID',
        };
      final client = _client(transport)..start();

      final future = client.sendCode('00000');
      client.drain();
      await expectLater(
        future,
        throwsA(
          isA<TdlibException>()
              .having((e) => e.message, 'message', 'That code is not right.')
              .having((e) => e.code, 'code', 400),
        ),
      );
      await client.close();
    });

    test('bad api credentials point at my.telegram.org', () async {
      final transport = _FakeTransport()
        ..replies['setAuthenticationPhoneNumber'] = {
          '@type': 'error',
          'code': 400,
          'message': 'API_ID_INVALID',
        };
      final client = _client(transport)..start();
      final future = client.sendPhoneNumber('+1');
      client.drain();
      await expectLater(
        future,
        throwsA(
          isA<TdlibException>().having(
            (e) => e.message,
            'message',
            contains('my.telegram.org'),
          ),
        ),
      );
      await client.close();
    });

    test('rate limiting is explained rather than echoed', () async {
      final transport = _FakeTransport()
        ..replies['setAuthenticationPhoneNumber'] = {
          '@type': 'error',
          'code': 429,
          'message': 'FLOOD_WAIT_86400',
        };
      final client = _client(transport)..start();
      final future = client.sendPhoneNumber('+1');
      client.drain();
      await expectLater(
        future,
        throwsA(
          isA<TdlibException>().having(
            (e) => e.message,
            'message',
            contains('rate-limiting'),
          ),
        ),
      );
      await client.close();
    });

    test('replies are matched to their request, not to arrival order', () async {
      // Everything shares one event stream, so @extra is what keeps two
      // in-flight requests apart.
      final transport = _FakeTransport()
        ..replies['getMe'] = {'@type': 'user', 'id': 5};
      final client = _client(transport)..start();

      final first = client.request({'@type': 'getMe'});
      final second = client.request({'@type': 'getMe'});
      client.drain();

      expect((await first)['id'], 5);
      expect((await second)['id'], 5);
      final extras = transport.sent
          .where((request) => request['@type'] == 'getMe')
          .map((request) => request['@extra'])
          .toSet();
      expect(extras, hasLength(2), reason: 'each request gets its own @extra');
      await client.close();
    });

    test('closing stops the client and releases the transport', () async {
      final transport = _FakeTransport();
      final client = _client(transport)..start();
      await client.close();
      expect(transport.disposed, isTrue);
      expect(
        transport.sent.any((request) => request['@type'] == 'close'),
        isTrue,
      );
    });
  });

  group('audio mapping', () {
    test('an audio message becomes a song', () {
      final song = songFromMessage(_account(), -100, _audioMessage());
      expect(song, isNotNull);
      expect(song!.id, 'telegram:tg-1:-100/1000');
      expect(song.title, 'Al Sudeste');
      expect(song.artist, 'Moneda Dura');
      expect(song.album, 'Sin Blasfemias');
      expect(song.duration, 249000, reason: 'seconds become milliseconds');
      expect(song.mimeType, 'audio/mpeg');
      expect(telegramFileId(song), 77);
      // Nothing can play this until the file is fetched.
      expect(song.path, isEmpty);
    });

    test('an already-downloaded file is playable straight away', () {
      final song = songFromMessage(
        _account(),
        -100,
        _audioMessage(localPath: '/home/me/.td/files/track.mp3', completed: true),
      );
      expect(song!.path, '/home/me/.td/files/track.mp3');
    });

    test('a half-downloaded file is not treated as playable', () {
      final song = songFromMessage(
        _account(),
        -100,
        _audioMessage(localPath: '/partial/track.mp3'),
      );
      expect(song!.path, isEmpty);
    });

    test('missing tags fall back to the file name', () {
      final song = songFromMessage(
        _account(),
        -100,
        _audioMessage(title: null, performer: null, album: null),
      );
      expect(song!.title, 'track.mp3');
      expect(song.artist, 'Telegram');
      expect(song.album, 'Telegram');
    });

    test('a document that is audio is accepted', () {
      // Plenty of music is shared as a plain file rather than an audio message.
      final message = {
        'id': 7,
        'content': {
          '@type': 'messageDocument',
          'document': {
            'file_name': 'song.flac',
            'mime_type': 'application/octet-stream',
            'document': {
              'id': 12,
              'local': {'path': '', 'is_downloading_completed': false},
            },
          },
        },
      };
      final song = songFromMessage(_account(), 42, message);
      expect(song, isNotNull);
      expect(song!.title, 'song.flac');
      expect(telegramFileId(song), 12);
    });

    test('a document that is not audio is skipped', () {
      final message = {
        'id': 8,
        'content': {
          '@type': 'messageDocument',
          'document': {
            'file_name': 'holiday.pdf',
            'mime_type': 'application/pdf',
            'document': {
              'id': 13,
              'local': {'path': '', 'is_downloading_completed': false},
            },
          },
        },
      };
      expect(songFromMessage(_account(), 42, message), isNull);
    });

    test('a photo or text message is skipped', () {
      expect(
        songFromMessage(_account(), 42, {
          'id': 9,
          'content': {'@type': 'messageText'},
        }),
        isNull,
      );
    });

    test('configured chats are parsed, and rubbish ignored', () {
      expect(telegramChatIds(_account()), [-100, 42]);
      expect(telegramChatIds(_account(chats: '')), isEmpty);
      expect(telegramChatIds(_account(chats: 'abc, 7 ,')), [7]);
    });
  });

  group('fetching a chat', () {
    test('audio is searched with the audio filter and paged', () async {
      final transport = _FakeTransport()
        ..queued['searchChatMessages'] = [
          {
            '@type': 'foundChatMessages',
            'messages': [_audioMessage(id: 10)],
          },
          {'@type': 'foundChatMessages', 'messages': const []},
        ];
      final client = _client(transport)..start();
      final source = TelegramSource(account: _account(), client: client);

      final future = source.audioIn(-100, pageSize: 1);
      // The fake answers synchronously; drain until the walk finishes.
      for (var i = 0; i < 6; i++) {
        client.drain();
        await Future<void>.delayed(Duration.zero);
      }
      final songs = await future;

      expect(songs, hasLength(1));
      final search = transport.sent.firstWhere(
        (request) => request['@type'] == 'searchChatMessages',
      );
      expect(search['chat_id'], -100);
      expect(
        (search['filter'] as Map)['@type'],
        'searchMessagesFilterAudio',
      );
      await client.close();
    });

    test('a track with no file behind it cannot be downloaded', () async {
      final transport = _FakeTransport();
      final client = _client(transport)..start();
      final source = TelegramSource(account: _account(), client: client);
      final song = songFromMessage(_account(), -100, _audioMessage())!;

      await expectLater(
        source.download(song.copyWith(lyrics: 'not-a-file-marker')),
        throwsA(isA<TdlibException>()),
      );
      await client.close();
    });

    test('an already-downloaded file is returned without downloading', () async {
      final transport = _FakeTransport()
        ..replies['getFile'] = {
          '@type': 'file',
          'id': 77,
          'local': {
            'path': '/cached/track.mp3',
            'is_downloading_completed': true,
          },
        };
      final client = _client(transport)..start();
      final source = TelegramSource(account: _account(), client: client);
      final song = songFromMessage(_account(), -100, _audioMessage())!;

      final future = source.download(song);
      client.drain();
      expect(await future, '/cached/track.mp3');
      expect(
        transport.sent.any((request) => request['@type'] == 'downloadFile'),
        isFalse,
        reason: 'a cached file must not be fetched again',
      );
      await client.close();
    });

    test('a missing file is downloaded synchronously and its path returned', () async {
      final transport = _FakeTransport()
        ..replies['getFile'] = {
          '@type': 'file',
          'id': 77,
          'local': {'path': '', 'is_downloading_completed': false},
        }
        ..replies['downloadFile'] = {
          '@type': 'file',
          'id': 77,
          'local': {
            'path': '/fresh/track.mp3',
            'is_downloading_completed': true,
          },
        };
      final client = _client(transport)..start();
      final source = TelegramSource(account: _account(), client: client);
      final song = songFromMessage(_account(), -100, _audioMessage())!;

      final future = source.download(song);
      for (var i = 0; i < 4; i++) {
        client.drain();
        await Future<void>.delayed(Duration.zero);
      }
      expect(await future, '/fresh/track.mp3');

      final request = transport.sent.firstWhere(
        (entry) => entry['@type'] == 'downloadFile',
      );
      expect(request['file_id'], 77);
      expect(
        request['synchronous'],
        true,
        reason: 'the reply has to wait for the whole file',
      );
      await client.close();
    });
  });

  group('account', () {
    test('Telegram is complete once it has api credentials', () {
      // It has no server address, so the usual url/user/password rule does not
      // apply to it.
      expect(_account().isComplete, isTrue);
      expect(
        RemoteAccount(
          id: 'x',
          kind: RemoteKind.telegram,
          serverUrl: '',
          username: '',
          password: '',
        ).isComplete,
        isFalse,
      );
    });

    test('it is only authenticated once TDLib has a session', () {
      expect(_account().isAuthenticated, isFalse);
      final signedIn = _account().copyWith(
        extra: {..._account().extra, 'session': 'ready'},
      );
      expect(signedIn.isAuthenticated, isTrue);
    });

    test('the extra settings survive storage', () {
      final restored = RemoteAccount.fromJson(_account().toJson());
      expect(restored.extra['apiId'], '12345');
      expect(restored.extra['apiHash'], 'hash');
      expect(telegramChatIds(restored), [-100, 42]);
    });

    test('a missing library is reported with instructions', () {
      // The loader error names a file the user has never heard of, so it is
      // replaced with something actionable.
      expect(
        () => FfiTdlibTransport.open(explicitPath: '/nonexistent/libtdjson.so'),
        throwsA(
          isA<TdlibException>().having(
            (e) => e.message,
            'message',
            allOf(contains('TDLib is not installed'), contains('tdlib/td')),
          ),
        ),
      );
    });
  });
}
