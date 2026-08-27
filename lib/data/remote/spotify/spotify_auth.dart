import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

// Spotify OAuth 2.0, Authorization Code with PKCE.
//
// PKCE is what makes this safe in a program the user can read: there is no
// client secret to leak, because the client proves it started the flow by
// producing the verifier whose hash it sent up front. Spotify documents this as
// the flow for desktop and mobile apps for exactly that reason.
//
// The redirect comes back to a one-shot HTTP server on the loopback interface.
// Nothing is exposed off the machine, and the server stops as soon as the code
// arrives.

/// Thrown for anything the user should see.
class SpotifyAuthException implements Exception {
  const SpotifyAuthException(this.message, {this.detail});

  final String message;
  final String? detail;

  @override
  String toString() => message;
}

/// Opens a URL in the user's browser.
abstract class UrlLauncher {
  Future<void> open(String url);
}

class SystemUrlLauncher implements UrlLauncher {
  const SystemUrlLauncher();

  @override
  Future<void> open(String url) async {
    // Arguments as a list, never a shell string: the URL carries a query the
    // shell would happily interpret.
    final (executable, arguments) = switch (Platform.operatingSystem) {
      'linux' => ('xdg-open', [url]),
      'macos' => ('open', [url]),
      'windows' => ('rundll32', ['url.dll,FileProtocolHandler', url]),
      final other => throw SpotifyAuthException(
        'Cannot open a browser on $other.',
      ),
    };
    try {
      await Process.run(executable, arguments, runInShell: false);
    } on ProcessException catch (error) {
      throw SpotifyAuthException(
        'Could not open your browser. Open this URL by hand instead.',
        detail: error.message,
      );
    }
  }
}

/// The tokens Spotify issued.
class SpotifyTokens {
  const SpotifyTokens({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAt,
  });

  final String accessToken;

  /// Spotify rotates this, so whatever comes back on a refresh has to be kept.
  final String refreshToken;
  final DateTime expiresAt;

  /// A minute of slack, so a request does not start with a token that dies
  /// in flight.
  bool get isExpired =>
      DateTime.now().isAfter(expiresAt.subtract(const Duration(minutes: 1)));
}

/// Everything the importer needs to read a library. No playback scopes: this
/// cannot play Spotify audio and does not pretend to.
const spotifyScopes = [
  'playlist-read-private',
  'playlist-read-collaborative',
  'user-library-read',
  'user-read-private',
];

/// Handles the browser handshake and the token endpoint.
class SpotifyAuth {
  const SpotifyAuth({
    required this.clientId,
    this.launcher = const SystemUrlLauncher(),
    HttpClient? httpClient,
    this.redirectPort = 8888,
    this.timeout = const Duration(minutes: 3),
  }) : _http = httpClient;

  final String clientId;
  final UrlLauncher launcher;
  final HttpClient? _http;

  /// Fixed, because Spotify only accepts redirect URIs registered in advance —
  /// the user has to paste this exact string into their app's settings.
  final int redirectPort;

  final Duration timeout;

  String get redirectUri => 'http://127.0.0.1:$redirectPort/callback';

  static const _authorizeEndpoint = 'https://accounts.spotify.com/authorize';
  static const _tokenEndpoint = 'https://accounts.spotify.com/api/token';

  /// A high-entropy PKCE verifier, per RFC 7636: 43–128 unreserved characters.
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

  /// The URL to send the browser to.
  Uri authorizeUrl({required String verifier, required String state}) =>
      Uri.parse(_authorizeEndpoint).replace(
        queryParameters: {
          'client_id': clientId,
          'response_type': 'code',
          'redirect_uri': redirectUri,
          'code_challenge_method': 'S256',
          'code_challenge': challengeFor(verifier),
          'state': state,
          'scope': spotifyScopes.join(' '),
        },
      );

  /// Runs the whole handshake: opens the browser, waits for the redirect, and
  /// exchanges the code for tokens.
  Future<SpotifyTokens> authorize() async {
    if (clientId.trim().isEmpty) {
      throw const SpotifyAuthException(
        'Add your Spotify client ID first — create an app at '
        'developer.spotify.com and paste its client ID.',
      );
    }

    final verifier = createVerifier();
    // Guards against a stray or forged redirect landing on our loopback port.
    final state = createVerifier().substring(0, 16);

    final HttpServer server;
    try {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, redirectPort);
    } on SocketException catch (error) {
      throw SpotifyAuthException(
        'Port $redirectPort is already in use, so the Spotify redirect has '
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

  /// Waits for Spotify to redirect the browser back to us.
  Future<String> _waitForCode(HttpServer server, String state) async {
    final completer = Completer<String>();

    final subscription = server.listen((request) async {
      final query = request.uri.queryParameters;
      final error = query['error'];
      final code = query['code'];
      final returnedState = query['state'];

      String body;
      if (error != null) {
        body = error == 'access_denied'
            ? 'Permission was declined. Nothing was changed.'
            : 'Spotify reported: $error';
        if (!completer.isCompleted) {
          completer.completeError(
            SpotifyAuthException(
              error == 'access_denied'
                  ? 'You declined the permission request.'
                  : 'Spotify refused the request: $error',
            ),
          );
        }
      } else if (returnedState != state) {
        // Not the redirect we started, so it does not get to hand us a code.
        body = 'Unexpected response. Start the connection again from the app.';
        if (!completer.isCompleted) {
          completer.completeError(
            const SpotifyAuthException(
              'The redirect did not match the request that started it, so it '
              'was ignored. Try connecting again.',
            ),
          );
        }
      } else if (code == null || code.isEmpty) {
        body = 'No authorisation code arrived.';
        if (!completer.isCompleted) {
          completer.completeError(
            const SpotifyAuthException('Spotify sent no authorisation code.'),
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
        onTimeout: () => throw SpotifyAuthException(
          'Gave up waiting for Spotify after ${timeout.inMinutes} minutes.',
        ),
      );
    } finally {
      await subscription.cancel();
    }
  }

  /// Swaps the authorisation code for tokens.
  Future<SpotifyTokens> exchangeCode({
    required String code,
    required String verifier,
  }) => _token({
    'grant_type': 'authorization_code',
    'code': code,
    'redirect_uri': redirectUri,
    'client_id': clientId,
    'code_verifier': verifier,
  });

  /// Renews an access token. Spotify may rotate the refresh token here, so the
  /// result must replace what was stored.
  Future<SpotifyTokens> refresh(String refreshToken) => _token({
    'grant_type': 'refresh_token',
    'refresh_token': refreshToken,
    'client_id': clientId,
  }, fallbackRefreshToken: refreshToken);

  Future<SpotifyTokens> _token(
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
        throw const SpotifyAuthException('Spotify sent an unreadable reply.');
      }

      if (response.statusCode != HttpStatus.ok) {
        final description =
            decoded['error_description'] ?? decoded['error'] ?? 'unknown';
        throw SpotifyAuthException(
          switch ('$description') {
            final text when text.contains('redirect_uri') =>
              'Spotify rejected the redirect URI. Add exactly '
                  '$redirectUri to your app in the Spotify dashboard.',
            final text when text.contains('client') =>
              'Spotify did not recognise that client ID.',
            final text when text.contains('revoked') ||
                text.contains('Refresh token') =>
              'The saved Spotify session is no longer valid. Connect again.',
            final text => 'Spotify refused the request: $text',
          },
          detail: text.length > 300 ? text.substring(0, 300) : text,
        );
      }

      final accessToken = decoded['access_token'];
      if (accessToken is! String) {
        throw const SpotifyAuthException('Spotify returned no access token.');
      }
      final refreshed = decoded['refresh_token'];
      final expiresIn = (decoded['expires_in'] as num?)?.toInt() ?? 3600;

      return SpotifyTokens(
        accessToken: accessToken,
        refreshToken: refreshed is String && refreshed.isNotEmpty
            ? refreshed
            : (fallbackRefreshToken ?? ''),
        expiresAt: DateTime.now().add(Duration(seconds: expiresIn)),
      );
    } on SpotifyAuthException {
      rethrow;
    } on SocketException catch (error) {
      throw SpotifyAuthException(
        'Could not reach Spotify. Check your connection.',
        detail: error.message,
      );
    } on TimeoutException {
      throw const SpotifyAuthException('Spotify did not answer in time.');
    } on FormatException catch (error) {
      throw SpotifyAuthException(
        'Spotify sent a reply that was not JSON.',
        detail: error.message,
      );
    } finally {
      if (_http == null) http.close(force: true);
    }
  }
}
