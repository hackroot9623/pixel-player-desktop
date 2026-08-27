import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/models.dart';
import 'remote_account.dart';

/// What every backend has to provide, ported from the shape the Android
/// repositories share (`JellyfinRepository`, `NavidromeRepository`).
///
/// On Android each of these needed a local HTTP proxy — `JellyfinStreamProxy`
/// and friends — because ExoPlayer could not carry the auth. mpv takes a signed
/// URL directly, so the proxies do not come across: [songs] returns tracks whose
/// `path` is already playable.
abstract class RemoteSource {
  RemoteSource(this.account, {HttpClient? httpClient, this.timeout})
    : http = httpClient ?? HttpClient();

  final RemoteAccount account;
  final HttpClient http;
  final Duration? timeout;

  Duration get _timeout => timeout ?? const Duration(seconds: 30);

  /// Logs in if the protocol needs it, and returns the account with whatever
  /// the server issued. Throws [RemoteException] on failure.
  Future<RemoteAccount> connect();

  /// Every track the account can see, as playable [Song]s.
  Future<List<Song>> songs();

  /// Cover art for one track, or null when the backend has none.
  String? artUrl(String itemId, {int size = 512});

  void close() => http.close(force: true);

  // ------------------------------------------------------------------ http

  /// Adds headers a subclass needs. Subsonic signs the query string instead.
  void authorise(HttpClientRequest request) {}

  Future<Map<String, Object?>> getJson(Uri uri) async {
    final text = await getText(uri);
    final decoded = jsonDecode(text);
    if (decoded is! Map<String, Object?>) {
      throw RemoteException('${account.kind.label} sent an unexpected reply.');
    }
    return decoded;
  }

  Future<String> getText(Uri uri) async {
    try {
      final request = await http.getUrl(uri);
      authorise(request);
      final response = await request.close().timeout(_timeout);
      final text = await response
          .transform(utf8.decoder)
          .join()
          .timeout(_timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw _describe(response.statusCode, text);
      }
      return text;
    } on RemoteException {
      rethrow;
    } on TimeoutException {
      throw RemoteException(
        'The server did not answer within ${_timeout.inSeconds}s.',
      );
    } on SocketException catch (error) {
      throw RemoteException(
        'Could not reach ${account.host}. Check the address and that the '
        'server is running.',
        detail: error.message,
      );
    } on HandshakeException catch (error) {
      throw RemoteException(
        'The TLS handshake with ${account.host} failed. A self-signed '
        'certificate will do this.',
        detail: error.message,
      );
    } on FormatException catch (error) {
      throw RemoteException(
        'That address does not look like a ${account.kind.label} server.',
        detail: error.message,
      );
    }
  }

  Future<Map<String, Object?>> postJson(Uri uri, Map<String, Object?> body,
      {Map<String, String> headers = const {}}) async {
    try {
      final request = await http.postUrl(uri);
      authorise(request);
      request.headers.contentType = ContentType.json;
      headers.forEach(request.headers.set);
      request.write(jsonEncode(body));
      final response = await request.close().timeout(_timeout);
      final text = await response
          .transform(utf8.decoder)
          .join()
          .timeout(_timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw _describe(response.statusCode, text);
      }
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, Object?>) {
        throw RemoteException('${account.kind.label} sent an unexpected reply.');
      }
      return decoded;
    } on RemoteException {
      rethrow;
    } on TimeoutException {
      throw RemoteException(
        'The server did not answer within ${_timeout.inSeconds}s.',
      );
    } on SocketException catch (error) {
      throw RemoteException(
        'Could not reach ${account.host}.',
        detail: error.message,
      );
    }
  }

  RemoteException _describe(int status, String body) {
    final snippet = body.trim();
    final detail = snippet.isEmpty
        ? null
        : (snippet.length > 300 ? snippet.substring(0, 300) : snippet);
    return switch (status) {
      401 || 403 => RemoteException(
        'The server rejected that username or password.',
        detail: detail,
        statusCode: status,
      ),
      404 => RemoteException(
        'Not found on the server. Check the address includes any base path.',
        detail: detail,
        statusCode: status,
      ),
      >= 500 => RemoteException(
        '${account.host} reported a server error ($status).',
        detail: detail,
        statusCode: status,
      ),
      _ => RemoteException(
        '${account.host} returned an error ($status).',
        detail: detail,
        statusCode: status,
      ),
    };
  }
}

/// A failure worth showing the user. Never carries the password.
class RemoteException implements Exception {
  const RemoteException(this.message, {this.detail, this.statusCode});

  final String message;
  final String? detail;
  final int? statusCode;

  @override
  String toString() => message;
}

/// Stable id for a remote track, so a queue saved across restarts still points
/// at the same thing and cannot collide with a local file path.
String remoteSongId(RemoteAccount account, String itemId) =>
    '${account.kind.storageKey}:${account.id}:$itemId';

/// The item id back out of [remoteSongId], or null for a local song.
String? remoteItemId(String songId) {
  final parts = songId.split(':');
  if (parts.length < 3) return null;
  if (RemoteKind.fromStorageKey(parts.first) == null) return null;
  return parts.sublist(2).join(':');
}

bool isRemoteSongId(String songId) => remoteItemId(songId) != null;
