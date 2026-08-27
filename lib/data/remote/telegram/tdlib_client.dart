import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Port of `TelegramClientManager`, on top of TDLib's JSON interface.
///
/// The Android app links `org.drinkless.tdlib` and talks to it through generated
/// Java classes. There is no such binding for Dart, but `libtdjson` exposes the
/// whole API as four C functions taking JSON strings, which is a far smaller
/// surface to bind than the generated one — every request is a map with an
/// `@type`.
///
/// [TdlibTransport] is the seam: the real one is FFI, and the tests use a fake,
/// so the auth state machine and the message mapping are exercised without the
/// native library present.
abstract class TdlibTransport {
  /// Creates a client and returns its id.
  int createClientId();

  /// Queues a request. Replies arrive through [receive].
  void send(int clientId, String request);

  /// Waits up to [timeout] for the next event, or null if none arrived.
  String? receive(double timeout);

  /// Runs a request that TDLib answers synchronously, such as `setLogVerbosity`.
  String? execute(String request);

  void dispose() {}
}

/// Thrown when the native library is missing or TDLib refuses a request.
class TdlibException implements Exception {
  const TdlibException(this.message, {this.detail, this.code});

  final String message;
  final String? detail;
  final int? code;

  @override
  String toString() => message;
}

// The four functions libtdjson exports for the JSON interface.
typedef _CreateClientIdNative = Int32 Function();
typedef _CreateClientId = int Function();
typedef _SendNative = Void Function(Int32, Pointer<Utf8>);
typedef _Send = void Function(int, Pointer<Utf8>);
typedef _ReceiveNative = Pointer<Utf8> Function(Double);
typedef _Receive = Pointer<Utf8> Function(double);
typedef _ExecuteNative = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _Execute = Pointer<Utf8> Function(Pointer<Utf8>);

/// Where to look for `libtdjson` when the user has not named a path.
///
/// TDLib is not packaged on most distributions, so the search is deliberately
/// broad before giving up with instructions.
List<String> get tdlibSearchPaths {
  if (Platform.isWindows) {
    return const ['tdjson.dll', 'libtdjson.dll'];
  }
  if (Platform.isMacOS) {
    return const [
      'libtdjson.dylib',
      '/usr/local/lib/libtdjson.dylib',
      // Homebrew's prefix on Apple silicon.
      '/opt/homebrew/lib/libtdjson.dylib',
    ];
  }
  return const [
    'libtdjson.so',
    'libtdjson.so.1.8.0',
    '/usr/lib/libtdjson.so',
    '/usr/local/lib/libtdjson.so',
    '/usr/lib/x86_64-linux-gnu/libtdjson.so',
  ];
}

/// The real transport: `dart:ffi` over libtdjson.
class FfiTdlibTransport implements TdlibTransport {
  FfiTdlibTransport._(DynamicLibrary library)
    : _createClientId = library
          .lookupFunction<_CreateClientIdNative, _CreateClientId>(
            'td_create_client_id',
          ),
      _send = library.lookupFunction<_SendNative, _Send>('td_send'),
      _receive = library.lookupFunction<_ReceiveNative, _Receive>('td_receive'),
      _execute = library.lookupFunction<_ExecuteNative, _Execute>('td_execute');

  /// Opens the library, trying [explicitPath] first.
  ///
  /// Throws [TdlibException] with installation guidance rather than the raw
  /// loader error, which names a file the user has never heard of.
  /// [searchPaths] exists so a test can assert the not-installed path without
  /// depending on whether the machine running it happens to have TDLib.
  factory FfiTdlibTransport.open({
    String? explicitPath,
    List<String>? searchPaths,
  }) {
    final candidates = [
      if (explicitPath != null && explicitPath.trim().isNotEmpty)
        explicitPath.trim(),
      ...(searchPaths ?? tdlibSearchPaths),
    ];
    final failures = <String>[];
    for (final candidate in candidates) {
      try {
        return FfiTdlibTransport._(DynamicLibrary.open(candidate));
      } on ArgumentError catch (error) {
        failures.add('$candidate: ${error.message}');
      }
    }
    throw TdlibException(
      'TDLib is not installed. Telegram needs libtdjson, which most '
      'distributions do not package — build it from '
      'github.com/tdlib/td, or install the tdlib package if your distribution '
      'has one, then point at the .so in the Telegram settings if it is not on '
      'the default library path.',
      detail: failures.join('\n'),
    );
  }

  final _CreateClientId _createClientId;
  final _Send _send;
  final _Receive _receive;
  final _Execute _execute;

  @override
  int createClientId() => _createClientId();

  @override
  void send(int clientId, String request) {
    final pointer = request.toNativeUtf8();
    try {
      _send(clientId, pointer);
    } finally {
      calloc.free(pointer);
    }
  }

  @override
  String? receive(double timeout) {
    final pointer = _receive(timeout);
    // TDLib owns this string and reuses the buffer, so it must be copied out
    // before the next receive and must never be freed here.
    return pointer == nullptr ? null : pointer.toDartString();
  }

  @override
  String? execute(String request) {
    final pointer = request.toNativeUtf8();
    try {
      final result = _execute(pointer);
      return result == nullptr ? null : result.toDartString();
    } finally {
      calloc.free(pointer);
    }
  }

  @override
  void dispose() {}
}

/// Where the login has got to, mirroring TDLib's `authorizationState`.
enum TdAuthState {
  /// Nothing sent yet, or TDLib is still starting up.
  initial,
  waitPhoneNumber,
  waitCode,
  waitPassword,

  /// TDLib wants the user to register — PixelPlayer does not do sign-up.
  waitRegistration,
  ready,
  loggedOut,
  closed,
}

/// A running TDLib client.
///
/// Requests are correlated by `@extra`, since replies arrive out of order on a
/// single event stream.
class TdlibClient {
  TdlibClient({
    required this.transport,
    required this.apiId,
    required this.apiHash,
    required this.databaseDirectory,
    required this.filesDirectory,
    this.pollInterval = const Duration(milliseconds: 20),
  });

  final TdlibTransport transport;
  final int apiId;
  final String apiHash;
  final String databaseDirectory;
  final String filesDirectory;
  final Duration pollInterval;

  int? _clientId;
  Timer? _pump;
  var _nextExtra = 1;
  final _pending = <String, Completer<Map<String, Object?>>>{};

  final _authStates = StreamController<TdAuthState>.broadcast();
  final _updates = StreamController<Map<String, Object?>>.broadcast();

  TdAuthState _authState = TdAuthState.initial;

  /// The current login stage.
  TdAuthState get authState => _authState;

  /// Login stages as they change, for the setup screen to follow.
  Stream<TdAuthState> get authStates => _authStates.stream;

  /// Every update TDLib emits — file progress, new messages, and the rest.
  Stream<Map<String, Object?>> get updates => _updates.stream;

  bool get isReady => _authState == TdAuthState.ready;

  /// Starts the client and begins draining events.
  void start() {
    if (_clientId != null) return;
    // Errors go to stderr by default, which on a desktop app means the
    // terminal; 1 is fatal-only.
    transport.execute(
      jsonEncode({'@type': 'setLogVerbosityLevel', 'new_verbosity_level': 1}),
    );
    _clientId = transport.createClientId();
    // TDLib only starts once something is sent.
    _sendRaw({'@type': 'getAuthorizationState'});
    _pump = Timer.periodic(pollInterval, (_) => drain());
  }

  /// Reads everything waiting from TDLib. Public so a test can pump it by hand.
  void drain() {
    while (true) {
      final event = transport.receive(0);
      if (event == null) break;
      Map<String, Object?> decoded;
      try {
        final parsed = jsonDecode(event);
        if (parsed is! Map<String, Object?>) break;
        decoded = parsed;
      } on FormatException {
        break;
      }
      _handle(decoded);
    }
  }

  void _handle(Map<String, Object?> event) {
    final extra = event['@extra'];
    if (extra is String) {
      final pending = _pending.remove(extra);
      if (pending != null) {
        pending.complete(event);
        return;
      }
    }
    if (event['@type'] == 'updateAuthorizationState') {
      final state = event['authorization_state'];
      if (state is Map<String, Object?>) _onAuthState(state);
      return;
    }
    _updates.add(event);
  }

  void _onAuthState(Map<String, Object?> state) {
    switch (state['@type']) {
      case 'authorizationStateWaitTdlibParameters':
        // The first thing TDLib asks for. `use_message_database` off keeps the
        // footprint small: this app only ever searches for audio.
        _sendRaw({
          '@type': 'setTdlibParameters',
          'database_directory': databaseDirectory,
          'files_directory': filesDirectory,
          'use_message_database': false,
          'use_secret_chats': false,
          'api_id': apiId,
          'api_hash': apiHash,
          'system_language_code': 'en',
          'device_model': 'Desktop',
          'application_version': '1.0.0',
        });
      case 'authorizationStateWaitPhoneNumber':
        _setAuth(TdAuthState.waitPhoneNumber);
      case 'authorizationStateWaitCode':
        _setAuth(TdAuthState.waitCode);
      case 'authorizationStateWaitPassword':
        _setAuth(TdAuthState.waitPassword);
      case 'authorizationStateWaitRegistration':
        _setAuth(TdAuthState.waitRegistration);
      case 'authorizationStateReady':
        _setAuth(TdAuthState.ready);
      case 'authorizationStateLoggingOut':
      case 'authorizationStateClosing':
        break;
      case 'authorizationStateClosed':
        _setAuth(TdAuthState.closed);
      default:
        break;
    }
  }

  void _setAuth(TdAuthState state) {
    _authState = state;
    if (!_authStates.isClosed) _authStates.add(state);
  }

  void _sendRaw(Map<String, Object?> request) {
    final id = _clientId;
    if (id == null) throw const TdlibException('The client is not started.');
    transport.send(id, jsonEncode(request));
  }

  /// Sends a request and waits for its reply.
  ///
  /// TDLib reports failures as an `error` object rather than by throwing, so
  /// those are turned into [TdlibException] here — otherwise a wrong code just
  /// looks like nothing happening.
  Future<Map<String, Object?>> request(
    Map<String, Object?> request, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final extra = 'req-${_nextExtra++}';
    final completer = Completer<Map<String, Object?>>();
    _pending[extra] = completer;
    _sendRaw({...request, '@extra': extra});

    final reply = await completer.future.timeout(
      timeout,
      onTimeout: () {
        _pending.remove(extra);
        throw TdlibException(
          'Telegram did not answer in ${timeout.inSeconds}s.',
        );
      },
    );
    if (reply['@type'] == 'error') {
      throw TdlibException(
        _readableError(reply),
        detail: reply['message'] as String?,
        code: (reply['code'] as num?)?.toInt(),
      );
    }
    return reply;
  }

  String _readableError(Map<String, Object?> error) {
    final message = error['message'] as String? ?? 'Unknown error';
    return switch (message) {
      'PHONE_CODE_INVALID' => 'That code is not right.',
      'PHONE_CODE_EXPIRED' => 'That code has expired — request a new one.',
      'PASSWORD_HASH_INVALID' => 'That two-step password is not right.',
      'PHONE_NUMBER_INVALID' => 'That phone number is not valid.',
      'API_ID_INVALID' =>
        'That api_id and api_hash pair was rejected. Check them at '
            'my.telegram.org.',
      final other when other.startsWith('FLOOD_WAIT') =>
        'Telegram is rate-limiting this account. Wait a few minutes.',
      final other => 'Telegram refused the request: $other',
    };
  }

  Future<void> sendPhoneNumber(String phone) => request({
    '@type': 'setAuthenticationPhoneNumber',
    'phone_number': phone.trim(),
  }).then((_) {});

  Future<void> sendCode(String code) => request({
    '@type': 'checkAuthenticationCode',
    'code': code.trim(),
  }).then((_) {});

  Future<void> sendPassword(String password) => request({
    '@type': 'checkAuthenticationPassword',
    'password': password,
  }).then((_) {});

  Future<void> logOut() => request({'@type': 'logOut'}).then((_) {});

  Future<void> close() async {
    _pump?.cancel();
    _pump = null;
    if (_clientId != null) {
      try {
        _sendRaw({'@type': 'close'});
      } on TdlibException {
        // Already gone; nothing to close.
      }
    }
    await _authStates.close();
    await _updates.close();
    transport.dispose();
  }
}
