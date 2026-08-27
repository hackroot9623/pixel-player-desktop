// Ported from the credential models under `data/{jellyfin,navidrome}/model`.
//
// One account record covers every backend: they all reduce to a server, a
// user, a secret, and whatever the server handed back at login.

/// Which remote backend an account talks to.
enum RemoteKind {
  jellyfin('jellyfin', 'Jellyfin', 'Media server — logs in with a password'),
  navidrome(
    'navidrome',
    'Navidrome',
    'Subsonic-compatible server — Airsonic and Gonic work too',
  ),
  telegram(
    'telegram',
    'Telegram',
    'Audio from your chats — needs TDLib and an api_id',
  );

  const RemoteKind(this.storageKey, this.label, this.description);

  final String storageKey;
  final String label;
  final String description;

  static RemoteKind? fromStorageKey(String? value) {
    for (final kind in values) {
      if (kind.storageKey == value) return kind;
    }
    return null;
  }
}

/// A configured remote account.
///
/// [password] is kept because both protocols need it per request: Subsonic
/// hashes it with a fresh salt on every call, and Jellyfin needs it again if the
/// access token is rejected. Stored in the same plain-text preferences file as
/// the AI keys — worth moving to the system keyring together.
class RemoteAccount {
  const RemoteAccount({
    required this.id,
    required this.kind,
    required this.serverUrl,
    required this.username,
    required this.password,
    this.accessToken,
    this.userId,
    this.displayName,
    this.extra = const {},
  });

  factory RemoteAccount.fromJson(Map<String, dynamic> json) => RemoteAccount(
    id: json['id'] as String,
    kind: RemoteKind.fromStorageKey(json['kind'] as String?) ??
        RemoteKind.navidrome,
    serverUrl: json['serverUrl'] as String? ?? '',
    username: json['username'] as String? ?? '',
    password: json['password'] as String? ?? '',
    accessToken: json['accessToken'] as String?,
    userId: json['userId'] as String?,
    displayName: json['displayName'] as String?,
    extra: {
      for (final MapEntry(:key, :value)
          in (json['extra'] as Map? ?? const {}).entries)
        '$key': '$value',
    },
  );

  final String id;
  final RemoteKind kind;
  final String serverUrl;
  final String username;
  final String password;

  /// Jellyfin's access token. Subsonic has no session, so it stays null.
  final String? accessToken;

  /// Jellyfin's user id, needed on every item query.
  final String? userId;

  /// What to call this account in the UI; falls back to the host.
  final String? displayName;

  /// Backend-specific settings that do not fit the server/user/password shape:
  /// Telegram's `api_id`, `api_hash`, chosen chats and library path live here.
  /// A map beats four more nullable fields that only one backend ever reads.
  final Map<String, String> extra;

  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind.storageKey,
    'serverUrl': serverUrl,
    'username': username,
    'password': password,
    if (accessToken != null) 'accessToken': accessToken,
    if (userId != null) 'userId': userId,
    if (displayName != null) 'displayName': displayName,
    if (extra.isNotEmpty) 'extra': extra,
  };

  RemoteAccount copyWith({
    String? serverUrl,
    String? username,
    String? password,
    String? accessToken,
    String? userId,
    String? displayName,
    Map<String, String>? extra,
  }) => RemoteAccount(
    id: id,
    kind: kind,
    serverUrl: serverUrl ?? this.serverUrl,
    username: username ?? this.username,
    password: password ?? this.password,
    accessToken: accessToken ?? this.accessToken,
    userId: userId ?? this.userId,
    displayName: displayName ?? this.displayName,
    extra: extra ?? this.extra,
  );

  /// The server URL with a scheme and no trailing slash.
  ///
  /// People type `music.example.com` and `http://nas:4533/` in equal measure,
  /// so the scheme is filled in and the slash trimmed rather than rejected.
  String get normalizedUrl {
    var trimmed = serverUrl.trim();
    while (trimmed.endsWith('/')) {
      trimmed = trimmed.substring(0, trimmed.length - 1);
    }
    if (trimmed.isEmpty) return '';
    final hasScheme =
        trimmed.startsWith('http://') || trimmed.startsWith('https://');
    return hasScheme ? trimmed : 'https://$trimmed';
  }

  String get host => Uri.tryParse(normalizedUrl)?.host ?? serverUrl;

  String get title => displayName?.trim().isNotEmpty == true
      ? displayName!.trim()
      : (kind == RemoteKind.telegram ? kind.label : '${kind.label} · $host');

  bool get isComplete => switch (kind) {
    // Telegram authenticates against Telegram itself, so there is no server
    // address to check. The api_id may be the build's rather than this
    // account's, which is why nothing here is required — the setup screen is
    // what refuses to start without a pair from one source or the other.
    RemoteKind.telegram => true,
    _ => normalizedUrl.isNotEmpty && username.isNotEmpty && password.isNotEmpty,
  };

  /// Jellyfin needs a token and a user id before it can query anything.
  bool get isAuthenticated => switch (kind) {
    RemoteKind.jellyfin =>
      (accessToken?.isNotEmpty ?? false) && (userId?.isNotEmpty ?? false),
    RemoteKind.navidrome => isComplete,
    // TDLib keeps the session on disk, so "signed in" is whether that session
    // is still valid — which only TDLib can answer, at startup.
    RemoteKind.telegram => extra['session'] == 'ready',
  };
}
