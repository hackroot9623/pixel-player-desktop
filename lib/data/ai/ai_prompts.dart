// Port of `data/ai/AiSystemPromptEngine`.
//
// Only the prompt types the desktop app actually uses are carried over:
// playlist building, the daily mix, and metadata clean-up for the tag editor.
// The Android engine also has TAGGING, MOOD_ANALYSIS and PERSONA, which drive
// features that do not exist here yet.

enum AiPromptType {
  playlist,
  dailyMix,
  metadata,
  general;

  /// The Kotlin picks the temperature from the task when the user has left the
  /// global setting at its default: factual work wants a cold model, curation a
  /// warmer one.
  double get defaultTemperature => switch (this) {
    AiPromptType.metadata => 0.1,
    AiPromptType.playlist || AiPromptType.dailyMix => 0.6,
    AiPromptType.general => 0.7,
  };
}

const _universalConstraints = '''
<integrity>
- You are communicating with a programmatic parser, not a human.
- Output ONLY the expected structure — nothing else.
- NO markdown fences, NO code blocks, NO conversational framing.
- If uncertain, make your best reasoned guess rather than refusing.
- Verify your output matches the required schema before responding.
</integrity>''';

const _playlistFewShot = '''
<examples>
GOOD: ["a1b2c3","d4e5f6","g7h8i9"]
BAD: Here is a playlist for you: ["a1b2c3","d4e5f6"]
Every ID in your output MUST exist verbatim in the candidate_pool.
</examples>''';

const _metadataFewShot = '''
<examples>
Input: title="Thriller (2008 Remaster)", artist="Micheal Jakson", album="THRILLER 25", genre="Pop"
Output: {"title":"Thriller (2008 Remaster)","artist":"Michael Jackson","album":"Thriller 25","genre":"Pop"}

Input: title="untitled", artist="unknown", album="", genre="Electronic"
Output: {"title":"Untitled","artist":"Unknown Artist","album":"","genre":"Synthwave"}
</examples>''';

const defaultBasePersona =
    'You are the music intelligence engine inside PixelPlayer, a local music '
    'player. You work only with the tracks the user actually owns.';

/// Assembles the system prompt: persona, task rules, output schema, integrity.
String buildSystemPrompt(
  AiPromptType type, {
  String basePersona = defaultBasePersona,
  String context = '',
}) {
  final requirements = switch (type) {
    AiPromptType.playlist =>
      '''
<role>Expert music curator — you select songs from the provided pool to build cohesive, emotionally intelligent playlists.</role>
<strategy>
1. Parse the user's request for desired mood, energy, genre, era, or activity.
2. Review the candidate pool — note available genres, artists and scores.
3. Select songs that form a coherent arc: opening, build, peak, cool-down.
4. Ensure variety — avoid repeating the same artist consecutively.
5. Prefer higher-scored songs (the "s" field) but prioritise diversity and fit.
- Target length is specified in the request — respect it within ±2 tracks.
</strategy>
<output_schema>
Return ONLY a raw JSON array of song IDs, copied exactly from the pool.
Format: ["id_1","id_2","id_3",...,"id_N"]
</output_schema>
$_playlistFewShot''',
    AiPromptType.dailyMix =>
      '''
<role>Daily Mix curator — you build a themed mini-set from the user's library for today's listening.</role>
<strategy>
1. Identify the dominant mood or genre in the user's recent listening.
2. Select tracks that form a single coherent mood pocket.
3. Lead with something familiar, introduce one or two discoveries mid-set, close strong.
</strategy>
<output_schema>
Return ONLY a raw JSON array of song IDs, copied exactly from the pool.
Format: ["id_1","id_2","id_3",...,"id_N"]
</output_schema>
$_playlistFewShot''',
    AiPromptType.metadata =>
      '''
<role>Precision music metadata specialist — you clean and enrich song metadata.</role>
<strategy>
- Fix spelling errors (e.g. "Micheal" → "Michael").
- Capitalise properly: title case for titles and artists.
- Replace generic genres ("Music", "Other") with a specific subgenre.
- If a field is empty or "unknown", leave it as an empty string — do not fabricate data.
- Preserve edition/remaster annotations in parentheses.
</strategy>
<output_schema>
Return ONLY a raw JSON object with EXACTLY these keys:
{"title":"...", "artist":"...", "album":"...", "genre":"..."}
</output_schema>
$_metadataFewShot''',
    AiPromptType.general =>
      '<role>Helpful music assistant.</role>\n'
          '<output_schema>Plain text, no markdown.</output_schema>',
  };

  return [
    basePersona,
    requirements,
    if (context.trim().isNotEmpty) '<context>\n$context\n</context>',
    _universalConstraints,
  ].join('\n\n');
}
