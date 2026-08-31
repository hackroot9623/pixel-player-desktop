import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pixelplay_desktop/data/update/update_check.dart';
import 'package:pixelplay_desktop/data/update/update_installer.dart';

/// The updater downloads a binary from the network and moves it over the one
/// that is running, so the parts worth testing are: which file it picks, whether
/// it will accept a URL that is not GitHub's, whether it knows when it must not
/// touch the installation, and whether the swap leaves a working install.

Release release({List<ReleaseAsset> assets = const []}) =>
    Release(tag: 'v1.2.0', url: 'https://github.com/x/y/releases/tag/v1.2.0', assets: assets);

const linuxAsset = ReleaseAsset(
  name: 'pixelplayer-linux-x64.tar.gz',
  url: 'https://github.com/x/y/releases/download/v1.2.0/pixelplayer-linux-x64.tar.gz',
  size: 0,
);

void main() {
  group('picking the right file', () {
    final assets = [
      linuxAsset,
      const ReleaseAsset(name: 'pixelplayer-windows-x64.zip', url: 'https://github.com/a'),
      const ReleaseAsset(name: 'pixelplayer-macos-arm64.zip', url: 'https://github.com/b'),
    ];

    test('each platform gets its own bundle', () {
      expect(assetForPlatform(release(assets: assets), 'linux')?.name, contains('linux'));
      expect(assetForPlatform(release(assets: assets), 'windows')?.name, contains('windows'));
      expect(assetForPlatform(release(assets: assets), 'macos')?.name, contains('macos'));
    });

    test('a release with nothing attached gives null', () {
      expect(assetForPlatform(release(), 'linux'), isNull);
    });

    test('an unknown platform gives null rather than a guess', () {
      expect(assetForPlatform(release(assets: assets), 'fuchsia'), isNull);
    });

    test('the source tarball GitHub adds is not mistaken for a bundle', () {
      // Every release carries Source code (tar.gz); installing it would be
      // installing a folder of Dart files.
      final withSource = release(assets: [
        const ReleaseAsset(name: 'Source code (tar.gz)', url: 'https://github.com/s'),
      ]);
      expect(assetForPlatform(withSource, 'linux'), isNull);
    });
  });

  group('where a download may come from', () {
    test('GitHub and its object storage are accepted', () {
      for (final url in [
        'https://github.com/x/y/releases/download/v1/a.tar.gz',
        'https://objects.githubusercontent.com/blob/1',
        'https://release-assets.githubusercontent.com/blob/1',
      ]) {
        expect(isTrustedAssetUrl(url), isTrue, reason: url);
      }
    });

    test('anywhere else is refused', () {
      for (final url in [
        // The URL comes from the network, so a lookalike host must not pass.
        'https://github.com.evil.test/x.tar.gz',
        'https://evil.test/x.tar.gz',
        // Plain http would let anyone on the path swap the binary.
        'http://github.com/x.tar.gz',
        'file:///tmp/x.tar.gz',
        'not a url at all',
      ]) {
        expect(isTrustedAssetUrl(url), isFalse, reason: url);
      }
    });
  });

  group('reading assets off the API answer', () {
    test('name, url and size come through', () {
      final releases = parseReleases('''
        [{"tag_name":"v1.2.0","html_url":"https://github.com/x/y/r/1","assets":[
          {"name":"pixelplayer-linux-x64.tar.gz",
           "browser_download_url":"https://github.com/x/y/d/a.tar.gz",
           "size":48000000}]}]
      ''');
      final asset = releases.single.assets.single;
      expect(asset.name, 'pixelplayer-linux-x64.tar.gz');
      expect(asset.size, 48000000);
    });

    test('an asset without a download url is skipped, not fatal', () {
      final releases = parseReleases(
        '[{"tag_name":"v1","assets":[{"name":"a.tar.gz"},"junk"]}]',
      );
      expect(releases.single.assets, isEmpty);
    });

    test('a release with no assets key still parses', () {
      expect(parseReleases('[{"tag_name":"v1"}]').single.assets, isEmpty);
    });
  });

  group('knowing what may be replaced', () {
    test('the install.sh layout is recognised', () {
      final layout = installLayoutFor(
        '/home/me/.local/lib/com.theveloper.pixelplay_desktop/pixelplay_desktop',
      );
      expect(layout?.prefix, '/home/me/.local');
      expect(layout?.libDir, '/home/me/.local/lib/com.theveloper.pixelplay_desktop');
    });

    test('anything else is not our layout', () {
      expect(installLayoutFor('/usr/bin/pixelplay_desktop'), isNull);
      expect(
        installLayoutFor('/opt/com.theveloper.pixelplay_desktop/pixelplay_desktop'),
        isNull,
      );
    });

    test('only Linux is offered an in-place update', () {
      for (final os in ['windows', 'macos']) {
        expect(
          selfInstallRefusal(
            operatingSystem: os,
            executablePath: '/home/me/.local/lib/com.theveloper.pixelplay_desktop/pixelplay_desktop',
          ),
          contains('Linux'),
        );
      }
    });

    test('a build directory is never overwritten', () {
      // Running from `flutter build`'s output during development.
      expect(
        selfInstallRefusal(
          operatingSystem: 'linux',
          executablePath: '/home/me/src/app/build/linux/x64/release/bundle/pixelplay_desktop',
        ),
        contains('build directory'),
      );
    });

    test('a packaged install is left to its package manager', () {
      expect(
        selfInstallRefusal(
          operatingSystem: 'linux',
          executablePath: '/usr/bin/pixelplay_desktop',
        ),
        contains('install.sh'),
      );
    });
  });

  test('a download that is not an archive is spotted by its first bytes', () {
    expect(looksLikeGzip([0x1f, 0x8b, 0x08]), isTrue);
    // An HTML error page, which is what an expired link returns.
    expect(looksLikeGzip('<!DOCTYPE html>'.codeUnits), isFalse);
    expect(looksLikeGzip([0x1f]), isFalse);
    expect(looksLikeGzip(const []), isFalse);
  });

  group('the swap', () {
    late Directory root;
    late String libDir;
    late String executable;

    /// A real tarball shaped like the one CI publishes: one `pixelplayer/`
    /// folder holding the bundle.
    Future<File> buildTarball({String binary = installedBinaryName}) async {
      final source = Directory(p.join(root.path, 'src', 'pixelplayer'))
        ..createSync(recursive: true);
      File(p.join(source.path, binary)).writeAsStringSync('#!/bin/true\n');
      File(p.join(source.path, 'version.txt')).writeAsStringSync('1.2.0');
      final archive = File(p.join(root.path, 'bundle.tar.gz'));
      final result = await Process.run('tar', [
        '-czf', archive.path,
        '-C', p.join(root.path, 'src'),
        'pixelplayer',
      ]);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      return archive;
    }

    UpdateInstaller installerFor(File tarball) => UpdateInstaller(
      operatingSystem: 'linux',
      executablePath: executable,
      downloader: (asset, target) async => target.writeAsBytesSync(
        tarball.readAsBytesSync(),
      ),
    );

    setUp(() {
      root = Directory.systemTemp.createTempSync('pixelplay-update-test');
      libDir = p.join(root.path, 'prefix', 'lib', installedAppId);
      executable = p.join(libDir, installedBinaryName);
      Directory(libDir).createSync(recursive: true);
      File(executable).writeAsStringSync('old binary');
      File(p.join(libDir, 'version.txt')).writeAsStringSync('1.0.0');
    });

    tearDown(() => root.deleteSync(recursive: true));

    test('the new bundle replaces the old one', () async {
      final installer = installerFor(await buildTarball());

      expect(await installer.install(release(assets: const [linuxAsset])), isTrue);

      expect(installer.stage, InstallStage.done);
      expect(File(p.join(libDir, 'version.txt')).readAsStringSync(), '1.2.0');
      // No leftovers beside the install.
      expect(Directory('$libDir.new').existsSync(), isFalse);
      expect(Directory('$libDir.old').existsSync(), isFalse);
    });

    test('an archive that is not PixelPlayer leaves the install alone', () async {
      // Someone else's tarball, or the wrong asset: it unpacks fine and has no
      // binary in it, and that must not cost the working install.
      final installer = installerFor(await buildTarball(binary: 'something_else'));

      expect(await installer.install(release(assets: const [linuxAsset])), isFalse);
      expect(installer.error, contains('no $installedBinaryName'));
      expect(File(executable).readAsStringSync(), 'old binary');
      expect(File(p.join(libDir, 'version.txt')).readAsStringSync(), '1.0.0');
    });

    test('a URL that is not GitHub is refused before anything downloads', () async {
      var downloaded = false;
      final installer = UpdateInstaller(
        operatingSystem: 'linux',
        executablePath: executable,
        downloader: (asset, target) async => downloaded = true,
      );

      final result = await installer.install(release(assets: const [
        ReleaseAsset(name: 'pixelplayer-linux-x64.tar.gz', url: 'https://evil.test/a.tar.gz'),
      ]));

      expect(result, isFalse);
      expect(downloaded, isFalse);
      expect(installer.error, contains('does not point at GitHub'));
    });

    test('a release with no Linux bundle says so', () async {
      final installer = installerFor(await buildTarball());
      expect(await installer.install(release()), isFalse);
      expect(installer.error, contains('no bundle'));
    });

    test('a refusal stops it even with a valid archive', () async {
      final tarball = await buildTarball();
      final installer = UpdateInstaller(
        operatingSystem: 'linux',
        executablePath: '/usr/bin/pixelplay_desktop',
        downloader: (asset, target) async =>
            target.writeAsBytesSync(tarball.readAsBytesSync()),
      );

      expect(await installer.install(release(assets: const [linuxAsset])), isFalse);
      expect(installer.error, contains('install.sh'));
    });

    test('a failed unpack does not touch the install', () async {
      final installer = UpdateInstaller(
        operatingSystem: 'linux',
        executablePath: executable,
        downloader: (asset, target) async => target.writeAsStringSync('rubbish'),
        runner: (command, arguments) async =>
            ProcessResult(0, 2, '', 'tar: not in gzip format'),
      );

      expect(await installer.install(release(assets: const [linuxAsset])), isFalse);
      expect(installer.error, contains('gzip'));
      expect(File(executable).readAsStringSync(), 'old binary');
    });

    test('progress is unknown until a size is known', () {
      final installer = UpdateInstaller(
        operatingSystem: 'linux',
        executablePath: executable,
      );
      expect(installer.progress, isNull);
      expect(installer.busy, isFalse);
      expect(installer.refusal, isNull);
    });
  });
}
