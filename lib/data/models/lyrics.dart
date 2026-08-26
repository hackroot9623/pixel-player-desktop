/// Ported from `data/model/Lyrics.kt` and `data/model/LyricsSourcePreference.kt`.
library;

class SyncedWord {
  const SyncedWord({
    required this.timeMs,
    required this.word,
    this.startsNewWord = true,
  });

  final int timeMs;
  final String word;
  final bool startsNewWord;
}

class SyncedLine {
  const SyncedLine({
    required this.timeMs,
    required this.line,
    this.words,
    this.translation,
    this.romanization,
  });

  final int timeMs;
  final String line;

  /// Word-level timings from "enhanced" LRC (`<mm:ss.xx>` inside a line).
  /// Null when the file only carries line-level timing.
  final List<SyncedWord>? words;
  final String? translation;
  final String? romanization;

  bool get isBlank => line.trim().isEmpty;
}

/// Where a set of lyrics came from. Mirrors the `source` column of the Android
/// `LyricsEntity`.
enum LyricsSource {
  embedded('Embedded in the file'),
  local('Local .lrc file'),
  remote('LRCLIB'),
  manual('Edited by you');

  const LyricsSource(this.label);

  final String label;

  static LyricsSource fromName(String? name) => values.firstWhere(
    (source) => source.name == name,
    orElse: () => LyricsSource.embedded,
  );
}

class Lyrics {
  const Lyrics({
    this.plain,
    this.synced,
    required this.source,
    this.offsetMs = 0,
  });

  final List<String>? plain;
  final List<SyncedLine>? synced;
  final LyricsSource source;

  /// User-applied nudge, positive means the lyrics appear later.
  final int offsetMs;

  bool get isSynced => synced != null && synced!.isNotEmpty;

  bool get isEmpty =>
      (synced == null || synced!.isEmpty) && (plain == null || plain!.isEmpty);

  bool get areFromRemote => source == LyricsSource.remote;

  /// Index of the line that should be highlighted at [position], or -1 before
  /// the first line. Binary search: this runs on every position tick.
  int activeIndexAt(Duration position) {
    final lines = synced;
    if (lines == null || lines.isEmpty) return -1;
    final t = position.inMilliseconds - offsetMs;
    if (t < lines.first.timeMs) return -1;
    var low = 0;
    var high = lines.length - 1;
    while (low < high) {
      final mid = (low + high + 1) ~/ 2;
      if (lines[mid].timeMs <= t) {
        low = mid;
      } else {
        high = mid - 1;
      }
    }
    return low;
  }

  Lyrics copyWith({int? offsetMs, LyricsSource? source}) => Lyrics(
    plain: plain,
    synced: synced,
    source: source ?? this.source,
    offsetMs: offsetMs ?? this.offsetMs,
  );
}

/// Ported from `LyricsSourcePreference` — which source is consulted first.
enum LyricsSourcePreference {
  apiFirst('Online first', [
    LyricsSource.remote,
    LyricsSource.embedded,
    LyricsSource.local,
  ]),
  embeddedFirst('Embedded first', [
    LyricsSource.embedded,
    LyricsSource.remote,
    LyricsSource.local,
  ]),
  localFirst('Local files first', [
    LyricsSource.local,
    LyricsSource.embedded,
    LyricsSource.remote,
  ]);

  const LyricsSourcePreference(this.label, this.order);

  final String label;

  /// Resolution order, most preferred first.
  final List<LyricsSource> order;
}
