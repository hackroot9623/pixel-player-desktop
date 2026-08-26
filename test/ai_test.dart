import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pixelplay_desktop/data/ai/ai_client.dart';
import 'package:pixelplay_desktop/data/ai/ai_playlist_generator.dart';
import 'package:pixelplay_desktop/data/ai/ai_prompts.dart';
import 'package:pixelplay_desktop/data/ai/ai_provider.dart';
import 'package:pixelplay_desktop/data/ai/ai_response_cleaner.dart';
import 'package:pixelplay_desktop/data/models/models.dart';
import 'package:pixelplay_desktop/data/smart/smart_playlists.dart';

/// No API keys here, so every request goes through a fake. That also lets the
/// tests assert what was *sent*, which is the part a live key could not check.
class _FakeHttpClient implements HttpClient {
  _FakeHttpClient({this.status = 200, this.body = '{}', this.throwing});

  int status;
  String body;
  Object? throwing;

  /// Successive responses, for the model-recovery path.
  final List<({int status, String body})> queued = [];

  final List<_FakeRequest> requests = [];

  _FakeRequest get lastRequest => requests.last;

  ({int status, String body}) _next() {
    if (queued.isNotEmpty) return queued.removeAt(0);
    return (status: status, body: body);
  }

  @override
  Future<HttpClientRequest> postUrl(Uri url) async => _make(url, 'POST');

  @override
  Future<HttpClientRequest> getUrl(Uri url) async => _make(url, 'GET');

  _FakeRequest _make(Uri url, String method) {
    if (throwing != null) throw throwing!;
    final response = _next();
    final request = _FakeRequest(
      url,
      method,
      status: response.status,
      body: response.body,
    );
    requests.add(request);
    return request;
  }

  @override
  void close({bool force = false}) {}

  @override
  noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName} is not used');
}

class _FakeRequest implements HttpClientRequest {
  _FakeRequest(
    this.uri,
    this.method, {
    required this.status,
    required this.body,
  });

  @override
  final Uri uri;
  @override
  final String method;
  final int status;
  final String body;

  final _written = StringBuffer();

  /// What the client actually sent.
  String get sentBody => _written.toString();

  Map<String, Object?> get sentJson =>
      jsonDecode(sentBody) as Map<String, Object?>;

  @override
  final HttpHeaders headers = _FakeHeaders();

  @override
  void write(Object? object) => _written.write(object);

  @override
  Future<HttpClientResponse> close() async =>
      _FakeResponse(status: status, body: body);

  @override
  noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName} is not used');
}

class _FakeHeaders implements HttpHeaders {
  final values = <String, String>{};

  @override
  ContentType? contentType;

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) =>
      values[name.toLowerCase()] = '$value';

  @override
  noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName} is not used');
}

class _FakeResponse extends Stream<List<int>> implements HttpClientResponse {
  _FakeResponse({required int status, required this.body}) : statusCode = status;

  @override
  final int statusCode;
  final String body;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream<List<int>>.value(utf8.encode(body)).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName} is not used');
}

Song _song(
  String id, {
  String title = 'Track',
  String artist = 'Artist',
  String album = 'Album',
  String? genre,
  bool favorite = false,
}) => Song(
  id: id,
  title: title,
  artist: artist,
  artistId: 1,
  album: album,
  albumId: 1,
  path: id,
  duration: 200000,
  genre: genre,
  isFavorite: favorite,
);

String _openAiReply(String content) => jsonEncode({
  'choices': [
    {
      'message': {'role': 'assistant', 'content': content},
    },
  ],
});

String _geminiReply(String text) => jsonEncode({
  'candidates': [
    {
      'content': {
        'parts': [
          {'text': text},
        ],
      },
    },
  ],
});

void main() {
  group('response cleaner', () {
    test('a bare array survives untouched', () {
      expect(cleanJsonResponse('["1","2"]'), '["1","2"]');
    });

    test('markdown fences come off', () {
      expect(
        cleanJsonResponse('```json\n["1","2"]\n```'),
        '["1","2"]',
      );
    });

    test('chatter around the array is dropped', () {
      const raw = 'Sure! Here is your playlist:\n["1","2","3"]\nEnjoy!';
      expect(extractJsonArray(cleanJsonResponse(raw)), '["1","2","3"]');
    });

    test('trailing commentary after a leading array is cut', () {
      expect(
        cleanJsonResponse('["1"] — hope that helps!'),
        '["1"]',
      );
    });

    test('a bracket inside a string does not end the array', () {
      // Track titles contain brackets constantly: "Song [Remix]".
      const raw = '["Song [Remix]","b"]';
      expect(extractJsonArray(raw), raw);
    });

    test('an escaped quote does not confuse the scanner', () {
      const raw = r'["say \"hi\" [x]","b"]';
      expect(extractJsonArray(raw), raw);
    });

    test('no array at all is reported, not guessed at', () {
      expect(extractJsonArray('I cannot help with that.'), isNull);
    });

    test('an object is found too', () {
      expect(
        extractJsonObject('Result: {"title":"A"} done'),
        '{"title":"A"}',
      );
    });
  });

  group('providers', () {
    test('storage keys round-trip and an unknown one falls back', () {
      for (final provider in AiProvider.values) {
        expect(AiProvider.fromStorageKey(provider.storageKey), provider);
      }
      expect(AiProvider.fromStorageKey('nope'), AiProvider.defaultProvider);
      expect(AiProvider.fromStorageKey(null), AiProvider.gemini);
    });

    test('every provider can be reached without more configuration', () {
      for (final provider in AiProvider.values) {
        if (provider.hasConfigurableUrl) continue;
        expect(provider.baseUrl, startsWith('http'), reason: provider.name);
        expect(provider.defaultModel, isNotEmpty, reason: provider.name);
      }
    });

    test('only Gemini uses the Gemini dialect', () {
      final gemini = AiProvider.values.where(
        (provider) => provider.dialect == AiDialect.gemini,
      );
      expect(gemini, [AiProvider.gemini]);
    });
  });

  group('client', () {
    AiClient client(
      _FakeHttpClient http, {
      AiProvider provider = AiProvider.openai,
      String key = 'sk-test',
      String? baseUrl,
    }) => AiClient(
      provider: provider,
      apiKey: key,
      baseUrl: baseUrl,
      httpClient: http,
    );

    test('an OpenAI request carries the key as a bearer header', () async {
      final http = _FakeHttpClient(body: _openAiReply('["0"]'));
      await client(http).generate(systemPrompt: 'sys', prompt: 'hello');

      final request = http.lastRequest;
      expect(request.uri.toString(), 'https://api.openai.com/v1/chat/completions');
      expect(
        (request.headers as _FakeHeaders).values['authorization'],
        'Bearer sk-test',
      );
      // The key must never be in the URL: URLs land in logs, headers do not.
      expect(request.uri.toString(), isNot(contains('sk-test')));

      final body = request.sentJson;
      expect(body['model'], AiProvider.openai.defaultModel);
      expect((body['messages'] as List).first, {
        'role': 'system',
        'content': 'sys',
      });
    });

    test('a Gemini request uses its own header and URL shape', () async {
      final http = _FakeHttpClient(body: _geminiReply('["0"]'));
      await client(
        http,
        provider: AiProvider.gemini,
        key: 'AIza-test',
      ).generate(systemPrompt: 'sys', prompt: 'hello', model: 'gemini-x');

      final request = http.lastRequest;
      expect(request.uri.path, endsWith('/models/gemini-x:generateContent'));
      expect(
        (request.headers as _FakeHeaders).values['x-goog-api-key'],
        'AIza-test',
      );
      expect(request.uri.query, isEmpty, reason: 'no key in the query string');
      expect(request.sentJson['systemInstruction'], isNotNull);
    });

    test('a missing key fails before any request is made', () async {
      final http = _FakeHttpClient();
      await expectLater(
        client(http, key: '').generate(systemPrompt: '', prompt: 'x'),
        throwsA(
          isA<AiException>().having(
            (error) => error.message,
            'message',
            contains('API key'),
          ),
        ),
      );
      expect(http.requests, isEmpty);
    });

    test('a local provider needs no key', () async {
      final http = _FakeHttpClient(body: _openAiReply('ok'));
      final result = await client(
        http,
        provider: AiProvider.ollama,
        key: '',
      ).generate(systemPrompt: '', prompt: 'x');
      expect(result.text, 'ok');
      expect(
        (http.lastRequest.headers as _FakeHeaders).values['authorization'],
        isNull,
      );
    });

    test('a 401 is explained in terms of the key', () async {
      final http = _FakeHttpClient(
        status: 401,
        body: '{"error":{"message":"Incorrect API key provided"}}',
      );
      await expectLater(
        client(http).generate(systemPrompt: '', prompt: 'x'),
        throwsA(
          isA<AiException>()
              .having((e) => e.message, 'message', contains('key was rejected'))
              .having((e) => e.statusCode, 'status', 401)
              .having(
                (e) => e.detail,
                'detail',
                'Incorrect API key provided',
              ),
        ),
      );
    });

    test('rate limiting and server errors say what to do', () async {
      for (final (status, expected) in [
        (429, 'rate-limited'),
        (503, 'server trouble'),
      ]) {
        final http = _FakeHttpClient(status: status, body: '{}');
        await expectLater(
          client(http).generate(systemPrompt: '', prompt: 'x'),
          throwsA(
            isA<AiException>().having(
              (e) => e.message,
              'message',
              contains(expected),
            ),
          ),
        );
      }
    });

    test('no connection is reported as such', () async {
      final http = _FakeHttpClient(
        throwing: const SocketException('unreachable'),
      );
      await expectLater(
        client(http).generate(systemPrompt: '', prompt: 'x'),
        throwsA(
          isA<AiException>().having(
            (e) => e.message,
            'message',
            contains('No connection'),
          ),
        ),
      );
    });

    test('a retired model is swapped for a working one', () async {
      // 404 on the stored model, then the model list, then a real answer.
      final http = _FakeHttpClient()
        ..queued.addAll([
          (
            status: 404,
            body: '{"error":{"message":"The model `gpt-old` does not exist"}}',
          ),
          (
            status: 200,
            body: jsonEncode({
              'data': [
                {'id': 'gpt-4o-mini'},
                {'id': 'gpt-other'},
              ],
            }),
          ),
          (status: 200, body: _openAiReply('["0"]')),
        ]);

      final result = await client(
        http,
      ).generate(systemPrompt: '', prompt: 'x', model: 'gpt-old');

      expect(result.model, 'gpt-4o-mini', reason: 'the provider default');
      expect(result.text, '["0"]');
      expect(http.requests, hasLength(3));
    });

    test('a failure that is not about the model is not retried', () async {
      final http = _FakeHttpClient(status: 401, body: '{}');
      await expectLater(
        client(http).generate(systemPrompt: '', prompt: 'x'),
        throwsA(isA<AiException>()),
      );
      expect(http.requests, hasLength(1), reason: 'no pointless retry');
    });

    test('the model list drops models that cannot generate', () async {
      final http = _FakeHttpClient(
        body: jsonEncode({
          'models': [
            {
              'name': 'models/gemini-3.1-flash',
              'supportedGenerationMethods': ['generateContent'],
            },
            {
              'name': 'models/text-embedding-004',
              'supportedGenerationMethods': ['embedContent'],
            },
          ],
        }),
      );
      final models = await client(
        http,
        provider: AiProvider.gemini,
      ).listModels();
      expect(models, ['gemini-3.1-flash']);
    });

    test('a blocked prompt is reported as blocked', () async {
      final http = _FakeHttpClient(
        body: jsonEncode({
          'promptFeedback': {'blockReason': 'SAFETY'},
        }),
      );
      await expectLater(
        client(http, provider: AiProvider.gemini).generate(
          systemPrompt: '',
          prompt: 'x',
        ),
        throwsA(
          isA<AiException>().having(
            (e) => e.message,
            'message',
            contains('blocked'),
          ),
        ),
      );
    });

    test('a response cut short by the token limit says so', () async {
      final http = _FakeHttpClient(
        body: jsonEncode({
          'candidates': [
            {'finishReason': 'MAX_TOKENS'},
          ],
        }),
      );
      await expectLater(
        client(http, provider: AiProvider.gemini).generate(
          systemPrompt: '',
          prompt: 'x',
        ),
        throwsA(
          isA<AiException>().having(
            (e) => e.message,
            'message',
            contains('output limit'),
          ),
        ),
      );
    });

    test('a custom endpoint is used verbatim, minus trailing slashes', () async {
      final http = _FakeHttpClient(body: _openAiReply('ok'));
      await client(
        http,
        provider: AiProvider.custom,
        baseUrl: 'https://my-host/v1///',
      ).generate(systemPrompt: '', prompt: 'x');
      expect(
        http.lastRequest.uri.toString(),
        'https://my-host/v1/chat/completions',
      );
    });

    test('an unconfigured custom endpoint fails clearly', () async {
      final http = _FakeHttpClient();
      await expectLater(
        client(http, provider: AiProvider.custom).generate(
          systemPrompt: '',
          prompt: 'x',
        ),
        throwsA(
          isA<AiException>().having(
            (e) => e.message,
            'message',
            contains('endpoint URL'),
          ),
        ),
      );
      expect(http.requests, isEmpty);
    });
  });

  group('candidate pool', () {
    final songs = [
      _song('/m/a.mp3', title: 'Heavy rotation'),
      _song('/m/b.mp3', title: 'Liked but unplayed', favorite: true),
      _song('/m/c.mp3', title: 'Never touched'),
    ];
    const stats = ListeningStats(
      msListened: {'/m/a.mp3': 7200000},
      playCounts: {'/m/a.mp3': 20},
    );

    test('what you listen to ranks first', () {
      final ranked = rankCandidates(songs, stats);
      expect(ranked.first.song.id, '/m/a.mp3');
      // 70 for saturated listening time + 20 for play count; the last 10 are
      // reserved for a like, which this track does not have.
      expect(ranked.first.score, 90);
      expect(ranked.last.score, 0, reason: 'never played, never liked');
    });

    test('a like counts for something on its own', () {
      final ranked = rankCandidates(songs, stats);
      final liked = ranked.firstWhere((c) => c.song.id == '/m/b.mp3');
      expect(liked.score, 10);
    });

    test('the sample size caps the pool', () {
      expect(rankCandidates(songs, stats, limit: 2), hasLength(2));
    });

    test('ranking is stable for equal scores', () {
      // Two runs of the same library must produce the same prompt, or an
      // identical request looks different to a cache.
      final first = rankCandidates(songs, stats).map((c) => c.song.id);
      final second = rankCandidates(songs, stats).map((c) => c.song.id);
      expect(first, second);
    });
  });

  group('prompt', () {
    final candidates = rankCandidates([
      _song('/home/elieser/Music/private/a.mp3', title: 'Alpha'),
      _song('/home/elieser/Music/private/b.mp3', title: 'Beta'),
    ], const ListeningStats());

    test('no file path or home directory is sent to the provider', () {
      final prompt = buildPlaylistPrompt(
        request: 'something upbeat',
        candidates: candidates,
        minLength: 5,
        maxLength: 10,
      );
      // The song ID is an absolute path. Sending it would hand a third party
      // the user's directory layout for nothing — the pool index does the job.
      expect(prompt, isNot(contains('/home/')));
      expect(prompt, isNot(contains('.mp3')));
      expect(prompt, contains('"id":"0"'));
      expect(prompt, contains('Alpha'));
      expect(prompt, contains('5-10 tracks'));
    });

    test('extra detail is only sent when asked for', () {
      final lean = buildPlaylistPrompt(
        request: 'x',
        candidates: candidates,
        minLength: 5,
        maxLength: 10,
      );
      final rich = buildPlaylistPrompt(
        request: 'x',
        candidates: candidates,
        minLength: 5,
        maxLength: 10,
        options: const AiSampleOptions(includeExtendedFields: true),
      );
      expect(lean, isNot(contains('"al":')));
      expect(rich, contains('"al":'));
      expect(rich.length, greaterThan(lean.length));
    });

    test('a quote in a title cannot break the JSON pool', () {
      final tricky = rankCandidates([
        _song('/m/x.mp3', title: 'She said "no"'),
      ], const ListeningStats());
      final prompt = buildPlaylistPrompt(
        request: 'x',
        candidates: tricky,
        minLength: 1,
        maxLength: 2,
      );
      final pool = extractJsonArray(prompt);
      expect(pool, isNotNull);
      expect(() => jsonDecode(pool!), returnsNormally);
    });

    test('a long request is clipped rather than sent whole', () {
      final prompt = buildPlaylistPrompt(
        request: 'x' * 5000,
        candidates: candidates,
        minLength: 1,
        maxLength: 2,
      );
      expect(prompt.contains('x' * 501), isFalse);
    });

    test('the digest names top artists, and is empty without history', () {
      final songs = [
        _song('/m/a.mp3', artist: 'Moneda Dura', genre: 'Rock'),
        _song('/m/b.mp3', artist: 'Buena Fe', genre: 'Trova'),
      ];
      expect(buildUserDigest(songs, const ListeningStats()), isEmpty);

      final digest = buildUserDigest(
        songs,
        const ListeningStats(msListened: {'/m/a.mp3': 60000}),
      );
      expect(digest, contains('Moneda Dura'));
      expect(digest, contains('Rock'));
      expect(digest, isNot(contains('Buena Fe')), reason: 'never listened to');
    });

    test('the system prompt demands bare JSON', () {
      final prompt = buildSystemPrompt(AiPromptType.playlist);
      expect(prompt, contains('JSON array'));
      expect(prompt, contains('NO markdown fences'));
    });
  });

  group('resolving the answer', () {
    final candidates = rankCandidates([
      _song('/m/a.mp3', title: 'A'),
      _song('/m/b.mp3', title: 'B'),
      _song('/m/c.mp3', title: 'C'),
    ], const ListeningStats());

    test('indices become real songs, in the order given', () {
      final songs = resolvePlaylist('["2","0"]', candidates);
      expect(songs.map((song) => song.title), ['C', 'A']);
    });

    test('a fenced, chatty answer still resolves', () {
      final songs = resolvePlaylist(
        'Here you go:\n```json\n["1"]\n```\nEnjoy!',
        candidates,
      );
      expect(songs.single.title, 'B');
    });

    test('numbers and objects are accepted as well as strings', () {
      expect(resolvePlaylist('[0, 1]', candidates), hasLength(2));
      expect(
        resolvePlaylist('[{"id":"1"},{"id":"2"}]', candidates),
        hasLength(2),
      );
    });

    test('invented indices are dropped, not fatal', () {
      // A model that answers with an out-of-range index should cost that one
      // track, not the whole playlist.
      final songs = resolvePlaylist('["0","99","-3","abc","2"]', candidates);
      expect(songs.map((song) => song.title), ['A', 'C']);
    });

    test('a repeated pick appears once', () {
      final songs = resolvePlaylist('["1","1","1"]', candidates);
      expect(songs, hasLength(1));
    });

    test('an answer with no usable picks explains itself', () {
      expect(
        () => resolvePlaylist('["99","100"]', candidates),
        throwsA(
          isA<AiException>().having(
            (e) => e.message,
            'message',
            contains('not in your library'),
          ),
        ),
      );
    });

    test('a refusal is reported as a bad response, not a crash', () {
      expect(
        () => resolvePlaylist(
          "I'm sorry, I can't help with that request.",
          candidates,
        ),
        throwsA(
          isA<AiException>().having(
            (e) => e.message,
            'message',
            contains('did not return a playlist'),
          ),
        ),
      );
    });

    test('a JSON object instead of an array is rejected clearly', () {
      expect(
        () => resolvePlaylist('{"playlist":"none"}', candidates),
        throwsA(isA<AiException>()),
      );
    });
  });

  group('end to end', () {
    final library = [
      _song('/m/a.mp3', title: 'Alpha', genre: 'Rock'),
      _song('/m/b.mp3', title: 'Beta', genre: 'Jazz'),
      _song('/m/c.mp3', title: 'Gamma', genre: 'Rock'),
    ];

    test('a request becomes a playlist of real library tracks', () async {
      final http = _FakeHttpClient(body: _openAiReply('["1","0"]'));
      final generator = AiPlaylistGenerator(
        AiClient(
          provider: AiProvider.openai,
          apiKey: 'sk-test',
          httpClient: http,
        ),
      );

      final result = await generator.generate(
        request: 'something for the evening',
        library: library,
        stats: const ListeningStats(msListened: {'/m/b.mp3': 600000}),
      );

      expect(result.songs.map((song) => song.title), ['Alpha', 'Beta']);
      expect(result.model, AiProvider.openai.defaultModel);

      // Only titles, artists and genres go out — never the paths.
      final sent = jsonEncode(http.lastRequest.sentJson);
      expect(sent, contains('Alpha'));
      expect(sent, isNot(contains('/m/a.mp3')));
    });

    test('the sample size limits what is described to the model', () async {
      final http = _FakeHttpClient(body: _openAiReply('["0"]'));
      final generator = AiPlaylistGenerator(
        AiClient(
          provider: AiProvider.openai,
          apiKey: 'sk-test',
          httpClient: http,
        ),
      );
      await generator.generate(
        request: 'x',
        library: library,
        stats: const ListeningStats(),
        options: const AiSampleOptions(sampleSize: 1),
      );

      final sent = jsonEncode(http.lastRequest.sentJson);
      expect(sent, contains('"id\\":\\"0'));
      expect(sent, isNot(contains('"id\\":\\"1')));
    });

    test('an empty library fails before spending a request', () async {
      final http = _FakeHttpClient();
      final generator = AiPlaylistGenerator(
        AiClient(
          provider: AiProvider.openai,
          apiKey: 'sk-test',
          httpClient: http,
        ),
      );
      await expectLater(
        generator.generate(
          request: 'x',
          library: const [],
          stats: const ListeningStats(),
        ),
        throwsA(isA<AiException>()),
      );
      expect(http.requests, isEmpty);
    });
  });
}
