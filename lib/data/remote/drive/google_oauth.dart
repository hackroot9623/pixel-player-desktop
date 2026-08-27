import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

// Google OAuth 2.0 for an installed application: authorization code with PKCE
// and a loopback redirect.
//
// Google issues credentials per project, so nothing here can be shipped — the
// user creates a "Desktop app" client and pastes its id. Google hands out a
// client secret alongside it and calls it one, but for an installed app it is
// embedded in something the user can read; PKCE is what actually proves the
// client started the flow. The secret is sent when present because Google's
// token endpoint expects it for that client type, and left out otherwise.
//
// The redirect lands on a one-shot HTTP server on loopback, which closes as
// soon as the code arrives. Nothing listens off the machine.

class GoogleAuthException implements Exception {
  const GoogleAuthException(this.message, {this.detail});

  final String message;
  final String? detail;

  @override
  String toString() => message;
}

/// Opens a URL in the user's browser.
abstract class BrowserLauncher {
  Future<void> open(String url);
}

class SystemBrowserLauncher implements BrowserLauncher {
  const SystemBrowserLauncher();

  @override
  Future<void> open(String url) async {
    // Arguments as a list, never a shell string: the URL carries a query the
    // shell would happily interpret.
    final (executable, arguments) = switch (Platform.operatingSystem) {
      'linux' => ('xdg-open', [url]),
      'macos' => ('open', [url]),
      'windows' => ('rundll32', ['url.dll,FileProtocolHandler', url]),
      final other => throw GoogleAuthException(
        'Cannot open a browser on $other.',
      ),
    };
    try {
      await Process.run(executable, arguments, runInShell: false);
    } on ProcessException catch (error) {
      throw GoogleAuthException(
        'Could not open your browser. Open the sign-in URL by hand instead.',
        detail: error.message,
      );
    }
  }
}

/// What Google issued.
class GoogleTokens {
  const GoogleTokens({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAt,
  });

  final String accessToken;

  /// Google only sends this on the first consent, and never again unless the
  /// user is asked to consent afresh — losing it means signing in again.
  final String refreshToken;
  final DateTime expiresAt;

  /// A minute of slack, so a request does not start on a token that dies in
  /// flight.
  bool get isExpired =>
      DateTime.now().isAfter(expiresAt.subtract(const Duration(minutes: 1)));

  Map<String, String> get storage => {
    'access_token': accessToken,
    if (refreshToken.isNotEmpty) 'refresh_token': refreshToken,
    'expires_at': expiresAt.toIso8601String(),
  };

  /// Reads back what [storage] wrote, treating anything unreadable as expired.
  static GoogleTokens? fromStorage(Map<String, String> extra) {
    final refresh = extra['refresh_token'] ?? '';
    if (refresh.isEmpty) return null;
    return GoogleTokens(
      accessToken: extra['access_token'] ?? '',
      refreshToken: refresh,
      expiresAt:
          DateTime.tryParse(extra['expires_at'] ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}

/// Read-only access to the user's Drive. Nothing here may modify a file.
const driveScopes = ['https://www.googleapis.com/auth/drive.readonly'];

class GoogleOAuth {
  const GoogleOAuth({
    required this.clientId,
    this.clientSecret = '',
    this.launcher = const SystemBrowserLauncher(),
    HttpClient? httpClient,
    this.redirectPort = 8890,
    this.timeout = const Duration(minutes: 3),
  }) : _http = httpClient;

  final String clientId;
  final String clientSecret;
  final BrowserLauncher launcher;
  final HttpClient? _http;
  final int redirectPort;
  final Duration timeout;

  /// Must be registered on the client, byte for byte.
  String get redirectUri => 'http://127.0.0.1:$redirectPort';

  static const _authorizeEndpoint =
      'https://accounts.google.com/o/oauth2/v2/auth';
  static const _tokenEndpoint = 'https://oauth2.googleapis.com/token';

  /// A PKCE verifier: 43–128 unreserved characters, per RFC 7636.
  static String createVerifier([Random? random]) {
    const alphabet =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
    final source = random ?? Random.secure();
    return List.generate(
      96,
      (_) => alphabet[source.nextInt(alphabet.length)],
    ).join();
  }

  /// S256 challenge: base64url(sha256(verifier)), unpadded.
  static String challengeFor(String verifier) => base64Url
      .encode(sha256.convert(ascii.encode(verifier)).bytes)
      .replaceAll('=', '');

  Uri authorizeUrl({required String verifier, required String state}) =>
      Uri.parse(_authorizeEndpoint).replace(
        queryParameters: {
          'client_id': clientId,
          'response_type': 'code',
          'redirect_uri': redirectUri,
          'scope': driveScopes.join(' '),
          'code_challenge_method': 'S256',
          'code_challenge': challengeFor(verifier),
          'state': state,
          // Without both of these Google returns no refresh token, and the
          // session would die in an hour with no way to renew it.
          'access_type': 'offline',
          'prompt': 'consent',
        },
      );

  /// Opens the browser, waits for the redirect, exchanges the code.
  Future<GoogleTokens> authorize() async {
    if (clientId.trim().isEmpty) {
      throw const GoogleAuthException(
        'Add your Google client ID first — create a Desktop app client in the '
        'Google Cloud console and paste its ID.',
      );
    }

    final verifier = createVerifier();
    // Guards against a stray or forged redirect landing on the loopback port.
    final state = createVerifier().substring(0, 16);

    final HttpServer server;
    try {
      server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        redirectPort,
      );
    } on SocketException catch (error) {
      throw GoogleAuthException(
        'Port $redirectPort is already in use, so the Google redirect has '
        'nowhere to land. Close whatever is using it and try again.',
        detail: error.message,
      );
    }

    try {
      await launcher.open(
        authorizeUrl(verifier: verifier, state: state).toString(),
      );
      final code = await _waitForCode(server, state);
      return exchangeCode(code: code, verifier: verifier);
    } finally {
      await server.close(force: true);
    }
  }

  Future<String> _waitForCode(HttpServer server, String state) async {
    final completer = Completer<String>();

    final subscription = server.listen((request) async {
      final query = request.uri.queryParameters;
      final error = query['error'];
      final code = query['code'];

      String body;
      if (error != null) {
        body = error == 'access_denied'
            ? 'Permission was declined. Nothing was changed.'
            : 'Google reported: $error';
        if (!completer.isCompleted) {
          completer.completeError(
            GoogleAuthException(
              error == 'access_denied'
                  ? 'You declined the permission request.'
                  : 'Google refused the request: $error',
            ),
          );
        }
      } else if (query['state'] != state) {
        // Not the redirect we started, so it does not get to hand us a code.
        body = 'Unexpected response. Start the sign-in again from the app.';
        if (!completer.isCompleted) {
          completer.completeError(
            const GoogleAuthException(
              'The redirect did not match the request that started it, so it '
              'was ignored. Try signing in again.',
            ),
          );
        }
      } else if (code == null || code.isEmpty) {
        body = 'No authorisation code arrived.';
        if (!completer.isCompleted) {
          completer.completeError(
            const GoogleAuthException('Google sent no authorisation code.'),
          );
        }
      } else {
        body = 'Connected. You can close this tab and go back to PixelPlayer.';
        if (!completer.isCompleted) completer.complete(code);
      }

      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.html
        ..write(
          '<!doctype html><meta charset="utf-8">'
          '<title>PixelPlayer</title>'
          '<body style="font:16px system-ui;padding:3rem;text-align:center">'
          '<p>$body</p></body>',
        );
      await request.response.close();
    });

    try {
      return await completer.future.timeout(
        timeout,
        onTimeout: () => throw GoogleAuthException(
          'Gave up waiting for Google after ${timeout.inMinutes} minutes.',
        ),
      );
    } finally {
      await subscription.cancel();
    }
  }

  Future<GoogleTokens> exchangeCode({
    required String code,
    required String verifier,
  }) => _token({
    'grant_type': 'authorization_code',
    'code': code,
    'redirect_uri': redirectUri,
    'client_id': clientId,
    if (clientSecret.isNotEmpty) 'client_secret': clientSecret,
    'code_verifier': verifier,
  });

  /// Renews an access token. Google does not rotate the refresh token, so the
  /// old one is carried through.
  Future<GoogleTokens> refresh(String refreshToken) => _token({
    'grant_type': 'refresh_token',
    'refresh_token': refreshToken,
    'client_id': clientId,
    if (clientSecret.isNotEmpty) 'client_secret': clientSecret,
  }, fallbackRefreshToken: refreshToken);

  Future<GoogleTokens> _token(
    Map<String, String> form, {
    String? fallbackRefreshToken,
  }) async {
    final http = _http ?? HttpClient();
    try {
      final request = await http.postUrl(Uri.parse(_tokenEndpoint));
      request.headers.contentType = ContentType(
        'application',
        'x-www-form-urlencoded',
      );
      request.write(
        form.entries
            .map(
              (e) =>
                  '${Uri.encodeQueryComponent(e.key)}='
                  '${Uri.encodeQueryComponent(e.value)}',
            )
            .join('&'),
      );

      final response = await request.close().timeout(timeout);
      final text = await response.transform(utf8.decoder).join();
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, Object?>) {
        throw const GoogleAuthException('Google sent an unreadable reply.');
      }

      if (response.statusCode != HttpStatus.ok) {
        final description =
            decoded['error_description'] ?? decoded['error'] ?? 'unknown';
        throw GoogleAuthException(
          switch ('$description') {
            final t when t.contains('redirect_uri') =>
              'Google rejected the redirect URI. Add exactly $redirectUri to '
                  'your OAuth client.',
            final t when t.contains('client_secret') =>
              'Google wants the client secret for this client type. Paste the '
                  'one shown next to the client ID.',
            final t when t.contains('invalid_client') =>
              'Google did not recognise that client ID and secret.',
            final t when t.contains('invalid_grant') =>
              'The saved Google session is no longer valid. Sign in again.',
            final t => 'Google refused the request: $t',
          },
          detail: text.length > 300 ? text.substring(0, 300) : text,
        );
      }

      final accessToken = decoded['access_token'];
      if (accessToken is! String) {
        throw const GoogleAuthException('Google returned no access token.');
      }
      final refreshed = decoded['refresh_token'];
      final expiresIn = (decoded['expires_in'] as num?)?.toInt() ?? 3600;

      return GoogleTokens(
        accessToken: accessToken,
        refreshToken: refreshed is String && refreshed.isNotEmpty
            ? refreshed
            : (fallbackRefreshToken ?? ''),
        expiresAt: DateTime.now().add(Duration(seconds: expiresIn)),
      );
    } on GoogleAuthException {
      rethrow;
    } on SocketException catch (error) {
      throw GoogleAuthException(
        'Could not reach Google. Check your connection.',
        detail: error.message,
      );
    } on TimeoutException {
      throw const GoogleAuthException('Google did not answer in time.');
    } on FormatException catch (error) {
      throw GoogleAuthException(
        'Google sent a reply that was not JSON.',
        detail: error.message,
      );
    } finally {
      if (_http == null) http.close(force: true);
    }
  }
}
