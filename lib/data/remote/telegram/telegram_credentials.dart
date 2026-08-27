import 'dart:convert';
import 'dart:io';

/// Where Telegram's application credentials come from.
///
/// `api_id`/`api_hash` identify the *application*, not the person: MTProto wants
/// them before a phone number can even be offered, which is why signing in
/// cannot produce them. The Android app registers PixelPlayer once and reads the
/// pair out of `local.properties` into `BuildConfig`, so a user only ever sees
/// the phone-and-code steps. This is the same arrangement for the desktop build.
///
/// Resolution order, first hit wins:
///  1. `--dart-define=TELEGRAM_API_ID=… --dart-define=TELEGRAM_API_HASH=…`,
///     the direct parallel to `BuildConfig`.
///  2. A JSON file beside the app's data, so an existing build can be pointed at
///     a pair without recompiling.
///  3. Nothing — the setup screen then asks, and the user brings their own.
class TelegramAppCredentials {
  const TelegramAppCredentials({required this.apiId, required this.apiHash});

  static const none = TelegramAppCredentials(apiId: 0, apiHash: '');

  final int apiId;
  final String apiHash;

  bool get isPresent => apiId > 0 && apiHash.isNotEmpty;

  /// Baked in at compile time. Empty in a plain `flutter build`.
  static const _definedId = String.fromEnvironment('TELEGRAM_API_ID');
  static const _definedHash = String.fromEnvironment('TELEGRAM_API_HASH');

  /// The file consulted when nothing was compiled in.
  static const fileName = 'telegram_app.json';

  /// Resolves the pair.
  ///
  /// [configDirectory] is where [fileName] is looked for; pass null to skip the
  /// file entirely, which is what the tests do to stay off the filesystem.
  static TelegramAppCredentials resolve({String? configDirectory}) {
    final compiled = fromStrings(_definedId, _definedHash);
    if (compiled.isPresent) return compiled;
    if (configDirectory == null) return none;

    final file = File('$configDirectory/$fileName');
    if (!file.existsSync()) return none;
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map) return none;
      return fromStrings(
        '${decoded['api_id'] ?? decoded['TELEGRAM_API_ID'] ?? ''}',
        '${decoded['api_hash'] ?? decoded['TELEGRAM_API_HASH'] ?? ''}',
      );
    } on FormatException {
      // A malformed file should send the user to the manual fields, not crash
      // the account screen.
      return none;
    } on FileSystemException {
      return none;
    }
  }

  /// Parses a pair that arrived as text, from either source.
  static TelegramAppCredentials fromStrings(String id, String hash) {
    final parsed = int.tryParse(id.trim()) ?? 0;
    final trimmedHash = hash.trim();
    if (parsed <= 0 || trimmedHash.isEmpty) return none;
    return TelegramAppCredentials(apiId: parsed, apiHash: trimmedHash);
  }
}
