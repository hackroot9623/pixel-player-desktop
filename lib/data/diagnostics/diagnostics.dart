import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import '../../platform/mpris.dart' show mprisBusName;
import '../remote/telegram/tdlib_client.dart' show tdlibSearchPaths;

// What this machine can actually do, and what the app found.
//
// Ported from `DebugPerformanceReport` in spirit rather than in shape: on Android
// the interesting unknowns were codecs and audio focus, and here they are which
// optional pieces are installed. Every remote source in this app depends on
// something the user supplies — yt-dlp, TDLib, a session bus — so "why does this
// not work" is nearly always answered by this list.
//
// Everything is probed defensively and reported as unknown rather than throwing:
// a diagnostics screen that crashes is worse than useless.

/// One line of the report.
class Diagnostic {
  const Diagnostic(this.label, this.value, {this.ok});

  final String label;
  final String value;

  /// Null when it is information rather than a pass or fail.
  final bool? ok;
}

class DiagnosticsSection {
  const DiagnosticsSection(this.title, this.entries);

  final String title;
  final List<Diagnostic> entries;
}

/// Renders the report as text, for pasting into a bug report.
String formatDiagnostics(List<DiagnosticsSection> sections) {
  final out = StringBuffer('PixelPlayer diagnostics\n');
  for (final section in sections) {
    out.writeln('\n## ${section.title}');
    for (final entry in section.entries) {
      final mark = switch (entry.ok) {
        true => '[ok]   ',
        false => '[miss] ',
        null => '       ',
      };
      out.writeln('$mark${entry.label}: ${entry.value}');
    }
  }
  return out.toString();
}

/// Runs a command and returns its first line of output, or null.
///
/// Used for version probes, where a missing binary is the answer rather than an
/// error.
Future<String?> probeVersion(
  String executable,
  List<String> arguments, {
  Future<ProcessResult> Function(String, List<String>)? run,
}) async {
  try {
    final result = await (run ?? _run)(executable, arguments);
    if (result.exitCode != 0) return null;
    final output = '${result.stdout}'.trim();
    if (output.isEmpty) return null;
    return output.split('\n').first.trim();
  } on ProcessException {
    return null;
  } catch (_) {
    return null;
  }
}

Future<ProcessResult> _run(String executable, List<String> arguments) =>
    Process.run(executable, arguments, runInShell: false);

/// Whether a shared library can be opened under any of [candidates].
///
/// This is how the app itself looks for TDLib, so reporting it here answers
/// "why does Telegram say it cannot find the library" without guessing.
String? findLibrary(List<String> candidates) {
  for (final candidate in candidates) {
    try {
      DynamicLibrary.open(candidate).providesSymbol('');
      return candidate;
    } catch (_) {
      // Not this one.
    }
  }
  return null;
}

/// Whether some process owns [name] on the session bus.
///
/// Answers "is MPRIS actually published" from the outside, which is the only
/// answer worth having — the app believing it published is what went wrong the
/// first time this was built.
Future<bool> busNameHasOwner(String name) async {
  if (!Platform.isLinux) return false;
  try {
    final result = await Process.run('gdbus', [
      'call',
      '--session',
      '--dest',
      'org.freedesktop.DBus',
      '--object-path',
      '/org/freedesktop/DBus',
      '--method',
      'org.freedesktop.DBus.NameHasOwner',
      name,
    ], runInShell: false);
    return '${result.stdout}'.contains('true');
  } catch (_) {
    return false;
  }
}

/// Gathers the environment half of the report.
///
/// The library half needs the database and lives in the screen, which has one.
Future<List<DiagnosticsSection>> collectEnvironment({
  required String appVersion,
  required Map<String, String> paths,
  required String mpvVersion,
  required String equalizerFilter,
}) async {
  final ytdlp = await probeVersion('yt-dlp', ['--version']);
  final mpvBinary = await probeVersion('mpv', ['--version']);
  final tdlib = findLibrary(tdlibSearchPaths);
  final mprisOwned = await busNameHasOwner(mprisBusName);

  return [
    DiagnosticsSection('App', [
      Diagnostic('Version', appVersion),
      Diagnostic('Platform', '${Platform.operatingSystem} '
          '${Platform.operatingSystemVersion}'),
      Diagnostic('Dart', Platform.version.split(' ').first),
      Diagnostic('Locale', Platform.localeName),
    ]),
    DiagnosticsSection('Playback', [
      Diagnostic('libmpv (in use)', mpvVersion, ok: mpvVersion != 'unknown'),
      Diagnostic(
        'mpv command line',
        mpvBinary ?? 'not installed',
        // Only libmpv matters for playback; the binary is a convenience.
        ok: null,
      ),
      Diagnostic(
        'Equalizer filter',
        equalizerFilter.isEmpty ? 'none' : equalizerFilter,
      ),
    ]),
    DiagnosticsSection('Optional pieces', [
      Diagnostic(
        'yt-dlp',
        ytdlp ?? 'not installed — YouTube Music will not work',
        ok: ytdlp != null,
      ),
      Diagnostic(
        'TDLib',
        tdlib ?? 'not found — Telegram will not work',
        ok: tdlib != null,
      ),
    ]),
    DiagnosticsSection('Desktop integration', [
      Diagnostic(
        'MPRIS on the session bus',
        mprisOwned ? 'published as $mprisBusName' : 'not published',
        ok: mprisOwned,
      ),
      Diagnostic(
        'Session bus',
        Platform.environment['DBUS_SESSION_BUS_ADDRESS'] ?? 'none',
        ok: Platform.environment.containsKey('DBUS_SESSION_BUS_ADDRESS'),
      ),
      Diagnostic(
        'Desktop',
        Platform.environment['XDG_CURRENT_DESKTOP'] ?? 'unknown',
      ),
      Diagnostic(
        'Session type',
        Platform.environment['XDG_SESSION_TYPE'] ?? 'unknown',
      ),
    ]),
    DiagnosticsSection('Paths', [
      for (final entry in paths.entries)
        Diagnostic(
          entry.key,
          entry.value,
          ok: Directory(entry.value).existsSync() ||
              File(entry.value).existsSync(),
        ),
    ]),
  ];
}
