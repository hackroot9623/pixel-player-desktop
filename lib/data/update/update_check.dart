import 'dart:async';
import 'dart:convert';
import 'dart:io';

// Is there a newer build?
//
// The releases page is the only thing that knows, so this asks GitHub. Nothing
// is downloaded by this file: it reports what is out there, and the assets on
// the release are what `update_installer.dart` then fetches — but only after the
// user presses the button. An app that replaces its own binary unasked is a
// worse problem than a stale version.
//
// Off by default. Reaching out to a server on every launch is not something to
// do to someone without asking, so there is a button, and automatic checks are a
// setting.

const updateRepository = 'hackroot9623/pixel-player-desktop';

/// One downloadable file attached to a release.
class ReleaseAsset {
  const ReleaseAsset({required this.name, required this.url, this.size = 0});

  final String name;
  final String url;

  /// Bytes, as GitHub reports them. Used to draw a progress bar and to notice a
  /// truncated download.
  final int size;
}

/// One release from the releases page.
class Release {
  const Release({
    required this.tag,
    required this.url,
    this.name = '',
    this.notes = '',
    this.publishedAt,
    this.isPrerelease = false,
    this.assets = const [],
  });

  final String tag;
  final String url;
  final String name;
  final String notes;
  final DateTime? publishedAt;
  final bool isPrerelease;
  final List<ReleaseAsset> assets;

  /// The version out of a `v1.2.3` style tag.
  String get version => tag.startsWith('v') ? tag.substring(1) : tag;
}

/// Compares two dotted versions. Negative when [a] is older.
///
/// Segments are compared numerically, so 1.10.0 is newer than 1.9.0 — which
/// string comparison gets backwards. Anything non-numeric after the digits (a
/// `-beta`, a `+build`) is ignored for ordering: it is not this function's job to
/// rank pre-releases against each other.
int compareVersions(String a, String b) {
  final left = _segments(a);
  final right = _segments(b);
  for (var i = 0; i < left.length || i < right.length; i++) {
    final x = i < left.length ? left[i] : 0;
    final y = i < right.length ? right[i] : 0;
    if (x != y) return x.compareTo(y);
  }
  return 0;
}

List<int> _segments(String version) {
  final cleaned = version.startsWith('v') ? version.substring(1) : version;
  // Stop at the first thing that is not part of the number.
  final match = RegExp(r'^[0-9]+(\.[0-9]+)*').firstMatch(cleaned.trim());
  if (match == null) return const [0];
  return [for (final part in match.group(0)!.split('.')) int.parse(part)];
}

/// Picks the release worth telling the user about.
///
/// The build workflow publishes a rolling `latest` prerelease on every push as
/// well as a real release per tag, so `/releases/latest` is not the answer —
/// it skips prereleases, and the rolling one is not a version anyway. What counts
/// is the newest tag that looks like a version.
Release? pickLatestRelease(Iterable<Release> releases) {
  Release? best;
  for (final release in releases) {
    // The rolling build has no version in its tag.
    if (_segments(release.tag).every((segment) => segment == 0)) continue;
    if (best == null || compareVersions(release.version, best.version) > 0) {
      best = release;
    }
  }
  return best;
}

/// What a check found.
class UpdateStatus {
  const UpdateStatus({
    required this.currentVersion,
    this.latest,
    this.error,
  });

  final String currentVersion;
  final Release? latest;
  final String? error;

  bool get hasUpdate =>
      latest != null && compareVersions(latest!.version, currentVersion) > 0;

  bool get isCurrent => latest != null && !hasUpdate;

  /// The check worked but found no versioned release.
  ///
  /// This is the real state of the repository today: CI publishes a rolling
  /// `latest` prerelease on every push and no `v*` tag has been cut yet, so
  /// there is nothing to compare against. Claiming "up to date" here would be
  /// asserting something this app does not know.
  bool get noReleases => error == null && latest == null;
}

/// Asks GitHub what the newest release is.
class UpdateChecker {
  UpdateChecker({HttpClient? httpClient, this.repository = updateRepository})
    : _http = httpClient;

  final HttpClient? _http;
  final String repository;

  Future<UpdateStatus> check({required String currentVersion}) async {
    final http = _http ?? HttpClient();
    try {
      final request = await http.getUrl(
        Uri.parse('https://api.github.com/repos/$repository/releases?per_page=20'),
      );
      // GitHub wants a User-Agent and answers 403 without one.
      request.headers.set(HttpHeaders.userAgentHeader, 'PixelPlayer-Desktop');
      request.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');

      final response = await request.close().timeout(
        const Duration(seconds: 15),
      );
      final body = await response.transform(utf8.decoder).join();

      if (response.statusCode == HttpStatus.forbidden) {
        return UpdateStatus(
          currentVersion: currentVersion,
          error:
              'GitHub is rate-limiting this address. Try again in a little '
              'while, or look at the releases page directly.',
        );
      }
      if (response.statusCode == HttpStatus.notFound) {
        return UpdateStatus(
          currentVersion: currentVersion,
          error: 'The releases page for $repository could not be found.',
        );
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return UpdateStatus(
          currentVersion: currentVersion,
          error: 'GitHub answered ${response.statusCode}.',
        );
      }

      return UpdateStatus(
        currentVersion: currentVersion,
        latest: pickLatestRelease(parseReleases(body)),
      );
    } on SocketException {
      return UpdateStatus(
        currentVersion: currentVersion,
        error: 'Could not reach GitHub. Check your connection.',
      );
    } on TimeoutException {
      return UpdateStatus(
        currentVersion: currentVersion,
        error: 'GitHub did not answer in time.',
      );
    } finally {
      if (_http == null) http.close(force: true);
    }
  }
}

/// The bundle for this platform, or null when the release has none.
///
/// The names are the ones the build workflow publishes. Matched loosely on the
/// platform word rather than the whole filename, so renaming the artifact to add
/// a version does not break the updater.
ReleaseAsset? assetForPlatform(Release release, String operatingSystem) {
  final want = switch (operatingSystem) {
    'linux' => ('linux', '.tar.gz'),
    'windows' => ('windows', '.zip'),
    'macos' => ('macos', '.zip'),
    _ => null,
  };
  if (want == null) return null;
  for (final asset in release.assets) {
    final name = asset.name.toLowerCase();
    if (name.contains(want.$1) && name.endsWith(want.$2)) return asset;
  }
  return null;
}

/// Whether a download URL is one worth trusting with a binary.
///
/// The URL arrives over the network, so it is not allowed to point anywhere it
/// likes: GitHub serves release assets from github.com and redirects to its own
/// object storage, and nothing else is accepted. Without this a compromised or
/// spoofed API answer could hand the installer any host's executable.
bool isTrustedAssetUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || uri.scheme != 'https') return false;
  const hosts = {
    'github.com',
    'api.github.com',
    'objects.githubusercontent.com',
    'release-assets.githubusercontent.com',
  };
  final host = uri.host.toLowerCase();
  return hosts.contains(host);
}

/// Reads the assets of one release. Anything without a name and URL is skipped.
List<ReleaseAsset> parseAssets(Object? raw) {
  if (raw is! List) return const [];
  return [
    for (final entry in raw)
      if (entry is Map)
        if (entry['name'] case final String name)
          if (entry['browser_download_url'] case final String url)
            ReleaseAsset(
              name: name,
              url: url,
              size: switch (entry['size']) {
                final int size => size,
                _ => 0,
              },
            ),
  ];
}

/// Reads the releases list. Anything unreadable is skipped rather than fatal.
List<Release> parseReleases(String body) {
  final Object? decoded;
  try {
    decoded = jsonDecode(body);
  } on FormatException {
    return const [];
  }
  if (decoded is! List) return const [];

  return [
    for (final entry in decoded)
      if (entry is Map && entry['draft'] != true)
        if (entry['tag_name'] case final String tag)
          Release(
            tag: tag,
            url: '${entry['html_url'] ?? 'https://github.com/$updateRepository/releases'}',
            name: '${entry['name'] ?? ''}',
            notes: '${entry['body'] ?? ''}',
            publishedAt: DateTime.tryParse('${entry['published_at'] ?? ''}'),
            isPrerelease: entry['prerelease'] == true,
            assets: parseAssets(entry['assets']),
          ),
  ];
}
