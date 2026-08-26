// Port of `data/ai/AiResponseCleaner`.
//
// Models are asked for a bare JSON array and routinely send back a fenced code
// block, a sentence of preamble, or both. This pulls the JSON out of whatever
// arrived. Pure string handling, so it is the cheapest part of the AI feature
// to test and the part most likely to actually break.

/// Strips markdown fences and trailing chatter after the first complete value.
String cleanJsonResponse(String raw) {
  var cleaned = raw
      .replaceAll('```json', '')
      .replaceAll('```kotlin', '')
      .replaceAll('```dart', '')
      .replaceAll('```', '')
      .trim();

  if (cleaned.startsWith('[')) {
    final end = _matchingBracket(cleaned, 0, '[', ']');
    if (end > 0) cleaned = cleaned.substring(0, end + 1);
  } else if (cleaned.startsWith('{')) {
    final end = _matchingBracket(cleaned, 0, '{', '}');
    if (end > 0) cleaned = cleaned.substring(0, end + 1);
  }
  return cleaned;
}

String cleanTextResponse(String raw) =>
    raw.replaceAll('```text', '').replaceAll('```', '').trim();

/// The first balanced `[...]` in [text], or null if there is none.
String? extractJsonArray(String text) => _extract(text, '[', ']');

/// The first balanced `{...}` in [text], or null if there is none.
String? extractJsonObject(String text) => _extract(text, '{', '}');

String? _extract(String text, String open, String close) {
  for (var i = 0; i < text.length; i++) {
    if (text[i] == open) {
      final end = _matchingBracket(text, i, open, close);
      if (end > i) return text.substring(i, end + 1);
    }
  }
  return null;
}

/// Index of the bracket closing the one at [start], or -1.
///
/// String-aware: a bracket inside a quoted song title must not be counted, and
/// track names contain brackets often enough for that to matter.
int _matchingBracket(String text, int start, String open, String close) {
  var depth = 0;
  var inString = false;
  var escaped = false;

  for (var i = start; i < text.length; i++) {
    final char = text[i];

    if (escaped) {
      escaped = false;
      continue;
    }
    if (char == r'\') {
      escaped = true;
      continue;
    }
    if (char == '"') {
      inString = !inString;
      continue;
    }
    if (inString) continue;

    if (char == open) {
      depth++;
    } else if (char == close) {
      depth--;
      if (depth == 0) return i;
    }
  }
  return -1;
}
