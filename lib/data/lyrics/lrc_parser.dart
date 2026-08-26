import '../models/lyrics.dart';

/// LRC parsing and serialisation, ported from the LRC half of
/// `utils/LyricsUtils.kt`.
///
/// Handles what real-world files contain:
/// * `[mm:ss]`, `[mm:ss.xx]` and `[mm:ss.xxx]` timestamps;
/// * several timestamps on one line (a repeated chorus);
/// * "enhanced" word timings written inline as `<mm:ss.xx>`;
/// * the `[offset:±ms]` tag, plus `[ti:]`/`[ar:]`/`[al:]`/`[by:]` metadata,
///   which are read for the offset and otherwise skipped;
/// * plain-text files with no timestamps at all.

final _lineTimeTag = RegExp(r'\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]');
final _wordTimeTag = RegExp(r'<(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?>');
final _metadataTag = RegExp(r'^\[([a-zA-Z]+):(.*)\]$');

int _toMillis(String minutes, String seconds, String? fraction) {
  final ms = switch (fraction?.length) {
    null || 0 => 0,
    1 => int.parse(fraction!) * 100,
    2 => int.parse(fraction!) * 10,
    _ => int.parse(fraction!.substring(0, 3)),
  };
  return int.parse(minutes) * 60000 + int.parse(seconds) * 1000 + ms;
}

/// Strips zero-width and bidi control characters, which show up in lyrics
/// pasted from web pages and otherwise render as boxes.
String sanitizeLyricLine(String raw) => raw
    .replaceAll(
      RegExp('[\u200B-\u200F\u202A-\u202E\u2060\uFEFF]'),
      '',
    )
    .trimRight();

/// Parses [content] as LRC, falling back to plain text when it carries no
/// timestamps. Returns null only when there is nothing usable at all.
Lyrics? parseLyrics(
  String content, {
  required LyricsSource source,
  int offsetMs = 0,
}) {
  if (content.trim().isEmpty) return null;

  final synced = <SyncedLine>[];
  final plain = <String>[];
  var tagOffsetMs = 0;

  for (final rawLine in content.split(RegExp(r'\r?\n'))) {
    final line = sanitizeLyricLine(rawLine);
    if (line.trim().isEmpty) continue;

    final metadata = _metadataTag.firstMatch(line.trim());
    if (metadata != null && _lineTimeTag.firstMatch(line) == null) {
      if (metadata.group(1)!.toLowerCase() == 'offset') {
        tagOffsetMs = int.tryParse(metadata.group(2)!.trim()) ?? 0;
      }
      continue;
    }

    final stamps = _lineTimeTag.allMatches(line).toList();
    if (stamps.isEmpty) {
      plain.add(line.trim());
      continue;
    }

    // Text is whatever follows the final leading timestamp.
    final text = line.substring(stamps.last.end);
    final words = _parseWords(text);
    final cleanText = text.replaceAll(_wordTimeTag, '').trim();
    plain.add(cleanText);

    for (final stamp in stamps) {
      synced.add(
        SyncedLine(
          timeMs: _toMillis(stamp.group(1)!, stamp.group(2)!, stamp.group(3)),
          line: cleanText,
          words: words,
        ),
      );
    }
  }

  if (synced.isEmpty && plain.isEmpty) return null;

  synced.sort((a, b) => a.timeMs.compareTo(b.timeMs));
  return Lyrics(
    plain: plain.isEmpty ? null : plain,
    synced: synced.isEmpty ? null : synced,
    source: source,
    // An explicit user offset wins over the file's own tag.
    offsetMs: offsetMs != 0 ? offsetMs : tagOffsetMs,
  );
}

List<SyncedWord>? _parseWords(String text) {
  final matches = _wordTimeTag.allMatches(text).toList();
  if (matches.isEmpty) return null;
  final words = <SyncedWord>[];
  for (var i = 0; i < matches.length; i++) {
    final match = matches[i];
    final end = i + 1 < matches.length ? matches[i + 1].start : text.length;
    final word = text.substring(match.end, end);
    if (word.trim().isEmpty) continue;
    words.add(
      SyncedWord(
        timeMs: _toMillis(match.group(1)!, match.group(2)!, match.group(3)),
        word: word,
        // A leading space means this token starts a new word rather than
        // continuing the previous one syllable-by-syllable.
        startsNewWord: word.startsWith(' ') || words.isEmpty,
      ),
    );
  }
  return words.isEmpty ? null : words;
}

String formatTimestamp(int millis) {
  final clamped = millis < 0 ? 0 : millis;
  final minutes = clamped ~/ 60000;
  final seconds = (clamped % 60000) / 1000;
  return '${minutes.toString().padLeft(2, '0')}:'
      '${seconds.toStringAsFixed(2).padLeft(5, '0')}';
}

/// Serialises back to LRC so edits and offsets can be written to disk or to the
/// database in the same format they came from.
String toLrc(Lyrics lyrics) {
  final synced = lyrics.synced;
  if (synced == null || synced.isEmpty) {
    return (lyrics.plain ?? const []).join('\n');
  }
  final out = StringBuffer();
  if (lyrics.offsetMs != 0) out.writeln('[offset:${lyrics.offsetMs}]');
  for (final line in synced) {
    out.writeln('[${formatTimestamp(line.timeMs)}]${line.line}');
  }
  return out.toString().trimRight();
}
