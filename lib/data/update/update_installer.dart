import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'update_check.dart';

// Downloading a release and putting it in place.
//
// This is deliberately narrow. It only knows how to update an installation made
// by `packaging/install.sh` — a self-contained bundle sitting in
// `$PREFIX/lib/com.theveloper.pixelplay_desktop`, owned by the user, no root
// involved. Anything else (a distribution package, /usr, a build directory, or
// Windows and macOS, where replacing a running app needs the platform's own
// dance) is refused with a reason, and the release link is offered instead.
//
// Two things make the swap safe on Linux:
//
//   * The new bundle is extracted *beside* the old one, on the same filesystem,
//     and only then renamed into place. A failed or partial download therefore
//     cannot leave a half-updated install.
//   * Renaming or deleting the running binary's file is harmless on Unix — the
//     inode stays alive until the process exits. Overwriting it in place would
//     not be: that is `ETXTBSY`, or a corrupted running program.

/// The directory name install.sh uses, and the binary inside it.
const installedAppId = 'com.theveloper.pixelplay_desktop';
const installedBinaryName = 'pixelplay_desktop';

/// Where an installation lives.
class InstallLayout {
  const InstallLayout({required this.prefix, required this.libDir});

  /// `~/.local`, normally.
  final String prefix;

  /// `$prefix/lib/com.theveloper.pixelplay_desktop`.
  final String libDir;
}

/// Reads the layout out of the running executable's path.
///
/// Returns null when the path is not the shape install.sh produces, which is the
/// signal that this installation is not ours to replace.
InstallLayout? installLayoutFor(String executablePath) {
  final libDir = p.dirname(p.normalize(executablePath));
  if (p.basename(libDir) != installedAppId) return null;
  final lib = p.dirname(libDir);
  if (p.basename(lib) != 'lib') return null;
  return InstallLayout(prefix: p.dirname(lib), libDir: libDir);
}

/// Why the in-app update cannot run here, or null when it can.
String? selfInstallRefusal({
  required String operatingSystem,
  required String executablePath,
}) {
  if (operatingSystem != 'linux') {
    return 'Installing in place is only wired up for the Linux bundle. '
        'Download the release and replace the app the way you installed it.';
  }
  // A `flutter run` or a release build tree: updating it would overwrite work.
  if (p.split(p.normalize(executablePath)).contains('build')) {
    return 'This is a build directory, not an installation. Nothing will be '
        'overwritten here.';
  }
  final layout = installLayoutFor(executablePath);
  if (layout == null) {
    return 'This copy was not installed with install.sh, so where it should go '
        'is not something this app can guess. Update it however you installed '
        'it — a package manager, most likely.';
  }
  final directory = Directory(layout.libDir);
  // Owned by the user is the whole premise; anything under /usr needs root and
  // is a package manager's business.
  if (!_isWritable(directory)) {
    return 'The install at ${layout.libDir} is not writable by this user, so '
        'it needs whatever installed it — or root — to update it.';
  }
  return null;
}

bool _isWritable(Directory directory) {
  final probe = File(p.join(directory.path, '.pixelplay-write-test'));
  try {
    probe.writeAsStringSync('');
    probe.deleteSync();
    return true;
  } on FileSystemException {
    return false;
  }
}

/// gzip's magic number. Cheap protection against saving an error page and
/// handing it to tar.
bool looksLikeGzip(List<int> firstBytes) =>
    firstBytes.length >= 2 && firstBytes[0] == 0x1f && firstBytes[1] == 0x8b;

/// Runs a command to completion; the seam that keeps `tar` out of the tests.
typedef ProcessRunner =
    Future<ProcessResult> Function(String executable, List<String> arguments);

Future<ProcessResult> _runSystemProcess(
  String executable,
  List<String> arguments,
) => Process.run(executable, arguments, runInShell: false);

/// Fetches one asset to a file. The seam that lets the swap be tested without a
/// network: everything after the download is the part that can go wrong on disk.
typedef AssetDownloader =
    Future<void> Function(ReleaseAsset asset, File target);

enum InstallStage { idle, downloading, extracting, installing, done, failed }

/// Downloads a release and puts it in place.
class UpdateInstaller extends ChangeNotifier {
  UpdateInstaller({
    HttpClient? httpClient,
    ProcessRunner? runner,
    AssetDownloader? downloader,
    String? executablePath,
    String? operatingSystem,
  }) : _http = httpClient,
       _downloader = downloader,
       _run = runner ?? _runSystemProcess,
       executablePath = executablePath ?? Platform.resolvedExecutable,
       operatingSystem = operatingSystem ?? Platform.operatingSystem;

  final HttpClient? _http;
  final AssetDownloader? _downloader;
  final ProcessRunner _run;
  final String executablePath;
  final String operatingSystem;

  InstallStage _stage = InstallStage.idle;
  int _received = 0;
  int _expected = 0;
  String? _error;

  InstallStage get stage => _stage;
  bool get busy =>
      _stage == InstallStage.downloading ||
      _stage == InstallStage.extracting ||
      _stage == InstallStage.installing;
  bool get finished => _stage == InstallStage.done;
  String? get error => _error;
  int get received => _received;

  /// Null while the size is unknown — GitHub does send it, but a redirect
  /// without a content-length is not worth failing over.
  double? get progress {
    if (_expected <= 0) return null;
    return (_received / _expected).clamp(0.0, 1.0);
  }

  /// Whether this installation can be replaced from inside the app.
  String? get refusal => selfInstallRefusal(
    operatingSystem: operatingSystem,
    executablePath: executablePath,
  );

  /// Downloads [release] and swaps it in. Reports through [notifyListeners].
  Future<bool> install(Release release) async {
    if (busy) return false;

    final refused = refusal;
    if (refused != null) return _fail(refused);

    final asset = assetForPlatform(release, operatingSystem);
    if (asset == null) {
      return _fail(
        'Release ${release.tag} has no bundle for $operatingSystem attached.',
      );
    }
    if (!isTrustedAssetUrl(asset.url)) {
      return _fail('The download link does not point at GitHub: ${asset.url}');
    }

    final layout = installLayoutFor(executablePath)!;
    final staging = Directory('${layout.libDir}.new');
    final previous = Directory('${layout.libDir}.old');
    final archive = File(
      p.join(Directory.systemTemp.path, 'pixelplay-${release.tag}.tar.gz'),
    );

    try {
      _stage = InstallStage.downloading;
      _received = 0;
      _expected = asset.size;
      _error = null;
      notifyListeners();

      await (_downloader ?? _download)(asset, archive);

      _stage = InstallStage.extracting;
      notifyListeners();

      if (staging.existsSync()) staging.deleteSync(recursive: true);
      staging.createSync(recursive: true);

      // --strip-components=1: the tarball holds a single `pixelplayer/` folder.
      final result = await _run('tar', [
        '-xzf',
        archive.path,
        '-C',
        staging.path,
        '--strip-components=1',
      ]);
      if (result.exitCode != 0) {
        return _fail('Could not unpack the download: ${result.stderr}'.trim());
      }

      final binary = File(p.join(staging.path, installedBinaryName));
      if (!binary.existsSync()) {
        return _fail(
          'The download does not look like a PixelPlayer bundle — no '
          '$installedBinaryName inside it.',
        );
      }

      _stage = InstallStage.installing;
      notifyListeners();

      // Rename, never copy: the running binary is one of these files.
      if (previous.existsSync()) previous.deleteSync(recursive: true);
      Directory(layout.libDir).renameSync(previous.path);
      try {
        staging.renameSync(layout.libDir);
      } on FileSystemException catch (failure) {
        // Put the old one back rather than leaving nothing installed.
        previous.renameSync(layout.libDir);
        return _fail('Could not move the new version into place: $failure');
      }
      previous.deleteSync(recursive: true);

      _stage = InstallStage.done;
      notifyListeners();
      return true;
    } on SocketException {
      return _fail('Could not reach GitHub to download the update.');
    } on TimeoutException {
      return _fail('The download timed out.');
    } on FileSystemException catch (failure) {
      return _fail('${failure.message} (${failure.path})');
    } finally {
      if (archive.existsSync()) {
        try {
          archive.deleteSync();
        } on FileSystemException {
          // A leftover in /tmp is not worth reporting.
        }
      }
      if (staging.existsSync()) {
        try {
          staging.deleteSync(recursive: true);
        } on FileSystemException {
          // Same.
        }
      }
    }
  }

  Future<void> _download(ReleaseAsset asset, File target) async {
    final http = _http ?? HttpClient();
    try {
      final request = await http.getUrl(Uri.parse(asset.url));
      request.headers.set(HttpHeaders.userAgentHeader, 'PixelPlayer-Desktop');
      request.followRedirects = true;
      final response = await request.close().timeout(
        const Duration(seconds: 60),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException('GitHub answered ${response.statusCode}');
      }
      if (response.contentLength > 0) _expected = response.contentLength;

      final sink = target.openWrite();
      var first = <int>[];
      try {
        // An idle timeout, not a total one: a slow link is fine, a link that
        // stops delivering is not. Without this a stalled transfer leaves the
        // progress bar frozen for ever with nothing to report — which is exactly
        // what a VPN route to GitHub's asset host did while this was written.
        await for (final chunk in response.timeout(
          const Duration(seconds: 60),
          onTimeout: (sink) => sink.addError(
            const HttpException(
              'The download stopped delivering data for a minute. Check the '
              'connection — a VPN or proxy in the way is the usual cause.',
            ),
          ),
        )) {
          if (first.length < 2) first = [...first, ...chunk.take(2)];
          sink.add(chunk);
          _received += chunk.length;
          notifyListeners();
        }
      } finally {
        await sink.close();
      }

      if (!looksLikeGzip(first)) {
        throw const HttpException(
          'What arrived is not an archive — the download link may have '
          'expired.',
        );
      }
      // A truncated download would otherwise be found by tar, with a worse
      // message.
      if (asset.size > 0 && _received != asset.size) {
        throw HttpException(
          'The download stopped early: $_received of ${asset.size} bytes.',
        );
      }
    } finally {
      if (_http == null) http.close(force: true);
    }
  }

  bool _fail(String message) {
    _error = message;
    _stage = InstallStage.failed;
    notifyListeners();
    return false;
  }

  /// Starts the newly installed binary and leaves.
  ///
  /// Detached, and after a pause: the single-instance lock is held by this
  /// process, so a new one started too early would find the port taken, hand
  /// over, and exit.
  Future<void> restart() async {
    final binary = executablePath;
    await Process.start(
      'sh',
      ['-c', 'sleep 1; exec "\$0"', binary],
      mode: ProcessStartMode.detached,
    );
    exit(0);
  }
}
