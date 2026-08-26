import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'ai_provider.dart';

// Port of `GeminiAiClient` + `GenericOpenAiClient` + `AiProviderSupport`.
//
// One client for both dialects: the request and response shapes differ, the
// error handling does not, and two classes to say that twice earned nothing.

/// Generation knobs. Defaults match `AiPreferencesRepository`.
class AiParams {
  const AiParams({
    this.temperature = 0.7,
    this.topP = 0.95,
    this.topK = 64,
    this.maxTokens = 4096,
    this.presencePenalty = 0,
    this.frequencyPenalty = 0,
  });

  final double temperature;
  final double topP;
  final int topK;
  final int maxTokens;
  final double presencePenalty;
  final double frequencyPenalty;

  AiParams copyWith({double? temperature, int? maxTokens}) => AiParams(
    temperature: temperature ?? this.temperature,
    topP: topP,
    topK: topK,
    maxTokens: maxTokens ?? this.maxTokens,
    presencePenalty: presencePenalty,
    frequencyPenalty: frequencyPenalty,
  );
}

/// A failure with a message worth showing the user.
///
/// [message] is the readable form; [detail] keeps the provider's own words for
/// the expandable part of the error card. Never holds the API key.
class AiException implements Exception {
  const AiException(this.message, {this.detail, this.statusCode});

  final String message;
  final String? detail;
  final int? statusCode;

  /// Whether retrying with a different model might work — drives the model
  /// recovery in [AiClient.generate].
  bool get isModelUnavailable {
    final haystack = '$message ${detail ?? ''}'.toLowerCase();
    if (statusCode == 404) return true;
    return haystack.contains('model') &&
        (haystack.contains('not found') ||
            haystack.contains('does not exist') ||
            haystack.contains('unavailable') ||
            haystack.contains('decommissioned'));
  }

  @override
  String toString() => message;
}

/// Talks to one provider with one key.
class AiClient {
  AiClient({
    required this.provider,
    required this.apiKey,
    String? baseUrl,
    HttpClient? httpClient,
    this.timeout = const Duration(seconds: 90),
  }) : baseUrl = (baseUrl?.trim().isNotEmpty ?? false)
           ? baseUrl!.trim().replaceAll(RegExp(r'/+$'), '')
           : provider.baseUrl,
       _http = httpClient ?? HttpClient();

  final AiProvider provider;
  final String apiKey;
  final String baseUrl;
  final Duration timeout;
  final HttpClient _http;

  String get defaultModel => provider.defaultModel;

  /// Generates a completion, retrying once on a different model if the chosen
  /// one has been retired — providers drop model names regularly, and a stored
  /// setting pointing at a dead model should not read as "AI is broken".
  ///
  /// Returns the text and the model that produced it, so a recovered model can
  /// be written back to settings.
  Future<({String text, String model})> generate({
    required String systemPrompt,
    required String prompt,
    String model = '',
    AiParams params = const AiParams(),
  }) async {
    if (provider.requiresApiKey && apiKey.trim().isEmpty) {
      throw AiException('Add your ${provider.displayName} API key first.');
    }
    if (baseUrl.isEmpty) {
      throw AiException('Set the endpoint URL for ${provider.displayName}.');
    }

    final requested = model.trim().isEmpty ? defaultModel : model.trim();
    try {
      return (
        text: await _generateWith(requested, systemPrompt, prompt, params),
        model: requested,
      );
    } on AiException catch (error) {
      if (!error.isModelUnavailable) rethrow;

      final available = await listModels().catchError(
        (_) => const <String>[],
      );
      final recovered = _pickRecoveryModel(requested, available);
      if (recovered == null) rethrow;

      return (
        text: await _generateWith(recovered, systemPrompt, prompt, params),
        model: recovered,
      );
    }
  }

  Future<String> _generateWith(
    String model,
    String systemPrompt,
    String prompt,
    AiParams params,
  ) => switch (provider.dialect) {
    AiDialect.gemini => _generateGemini(model, systemPrompt, prompt, params),
    AiDialect.openai => _generateOpenAi(model, systemPrompt, prompt, params),
  };

  // -------------------------------------------------------------- OpenAI

  Future<String> _generateOpenAi(
    String model,
    String systemPrompt,
    String prompt,
    AiParams params,
  ) async {
    final body = <String, Object?>{
      'model': model,
      'messages': [
        if (systemPrompt.trim().isNotEmpty)
          {'role': 'system', 'content': systemPrompt},
        {'role': 'user', 'content': prompt},
      ],
      'temperature': params.temperature,
      'top_p': params.topP,
      if (params.maxTokens > 0) 'max_tokens': params.maxTokens,
      'presence_penalty': params.presencePenalty,
      'frequency_penalty': params.frequencyPenalty,
    };

    final json = await _post(
      Uri.parse('$baseUrl/chat/completions'),
      body,
      model: model,
    );
    final choices = json['choices'];
    if (choices is List && choices.isNotEmpty) {
      final content = (choices.first as Map)['message']?['content'];
      if (content is String && content.trim().isNotEmpty) return content;
    }
    throw AiException(
      '${provider.displayName} returned an empty response.',
      detail: _snippet(jsonEncode(json)),
    );
  }

  // -------------------------------------------------------------- Gemini

  Future<String> _generateGemini(
    String model,
    String systemPrompt,
    String prompt,
    AiParams params,
  ) async {
    final body = <String, Object?>{
      'contents': [
        {
          'role': 'user',
          'parts': [
            {'text': prompt},
          ],
        },
      ],
      if (systemPrompt.trim().isNotEmpty)
        'systemInstruction': {
          'parts': [
            {'text': systemPrompt},
          ],
        },
      'generationConfig': {
        'temperature': params.temperature,
        'topK': params.topK,
        'topP': params.topP,
        'maxOutputTokens': params.maxTokens,
      },
    };

    final json = await _post(
      Uri.parse('$baseUrl/models/$model:generateContent'),
      body,
      model: model,
    );

    final feedback = json['promptFeedback'];
    final blockReason = feedback is Map ? feedback['blockReason'] : null;
    if (blockReason != null) {
      throw AiException(
        'Gemini blocked the prompt ($blockReason). Try rephrasing it.',
      );
    }

    final candidates = json['candidates'];
    if (candidates is List && candidates.isNotEmpty) {
      final first = candidates.first as Map<String, Object?>;
      final content = first['content'];
      final parts = content is Map ? content['parts'] : null;
      if (parts is List && parts.isNotEmpty) {
        final text = parts
            .map((part) => (part as Map)['text'])
            .whereType<String>()
            .join();
        if (text.trim().isNotEmpty) return text;
      }
      // A response truncated by the token limit comes back with no parts at
      // all, which is worth saying plainly rather than "empty response".
      if (first['finishReason'] == 'MAX_TOKENS') {
        throw const AiException(
          'The model hit its output limit before finishing. Raise "Max tokens" '
          'in AI settings, or ask for a shorter playlist.',
        );
      }
    }
    throw const AiException('Gemini returned an empty response.');
  }

  // ------------------------------------------------------------- models

  /// Lists the models the key can actually use.
  Future<List<String>> listModels() async {
    final uri = provider.dialect == AiDialect.gemini
        ? Uri.parse('$baseUrl/models')
        : Uri.parse('$baseUrl/models');
    final json = await _get(uri);

    final models = <String>[];
    if (provider.dialect == AiDialect.gemini) {
      for (final entry in (json['models'] as List? ?? const [])) {
        final name = (entry as Map)['name'];
        final methods = entry['supportedGenerationMethods'];
        // Embedding-only models cannot answer a prompt; offering them in the
        // picker just produces a confusing 400 later.
        final canGenerate =
            methods is! List || methods.contains('generateContent');
        if (name is String && canGenerate) {
          models.add(name.replaceFirst('models/', ''));
        }
      }
    } else {
      for (final entry in (json['data'] as List? ?? const [])) {
        final id = (entry as Map)['id'];
        if (id is String) models.add(id);
      }
    }
    models.sort();
    return models;
  }

  /// True if the key works. Used by the "Test key" button in settings.
  Future<bool> validateApiKey() async {
    try {
      final models = await listModels();
      return models.isNotEmpty;
    } on AiException {
      return false;
    }
  }

  /// Prefers the provider's default, then anything sharing the dead model's
  /// family, then the first model offered.
  String? _pickRecoveryModel(String current, List<String> available) {
    if (available.isEmpty) return null;
    if (defaultModel.isNotEmpty &&
        defaultModel != current &&
        available.contains(defaultModel)) {
      return defaultModel;
    }
    final family = current.split(RegExp('[-:/]')).first.toLowerCase();
    for (final model in available) {
      if (model != current && model.toLowerCase().startsWith(family)) {
        return model;
      }
    }
    return available.firstWhere(
      (model) => model != current,
      orElse: () => available.first,
    );
  }

  // ---------------------------------------------------------------- http

  void _authorise(HttpClientRequest request) {
    // The key goes in a header, never the query string: URLs end up in logs and
    // crash reports in a way headers do not.
    if (provider.dialect == AiDialect.gemini) {
      request.headers.set('x-goog-api-key', apiKey);
    } else if (apiKey.trim().isNotEmpty) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $apiKey');
    }
    if (provider == AiProvider.openrouter) {
      request.headers.set('HTTP-Referer', 'https://github.com/PixelPlayerHQ');
      request.headers.set('X-Title', 'PixelPlayer');
    }
  }

  Future<Map<String, Object?>> _post(
    Uri uri,
    Map<String, Object?> body, {
    required String model,
  }) => _send(uri, body: body, model: model);

  Future<Map<String, Object?>> _get(Uri uri) => _send(uri);

  Future<Map<String, Object?>> _send(
    Uri uri, {
    Map<String, Object?>? body,
    String? model,
  }) async {
    try {
      final request = body == null
          ? await _http.getUrl(uri)
          : await _http.postUrl(uri);
      _authorise(request);
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      }

      final response = await request.close().timeout(timeout);
      final text = await response
          .transform(utf8.decoder)
          .join()
          .timeout(timeout);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw _describeFailure(response.statusCode, text, model);
      }
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, Object?>) {
        throw AiException(
          '${provider.displayName} sent a response in an unexpected shape.',
          detail: text.length > 400 ? text.substring(0, 400) : text,
        );
      }
      return decoded;
    } on AiException {
      rethrow;
    } on TimeoutException {
      throw AiException(
        'Request timed out after ${timeout.inSeconds}s. '
        '${provider.displayName} may be overloaded — try again.',
      );
    } on SocketException catch (error) {
      throw AiException(
        'No connection to ${provider.displayName}. Check your network.',
        detail: error.message,
      );
    } on FormatException catch (error) {
      throw AiException(
        '${provider.displayName} sent a response that was not JSON.',
        detail: error.message,
      );
    } on HandshakeException catch (error) {
      throw AiException(
        'Could not establish a secure connection to ${provider.displayName}.',
        detail: error.message,
      );
    }
  }

  /// Turns an HTTP failure into something actionable, ported from
  /// `buildDetailedErrorMessage`.
  AiException _describeFailure(int status, String rawBody, String? model) {
    final detail = _providerMessage(rawBody) ?? _snippet(rawBody);
    final name = provider.displayName;

    final message = switch (status) {
      400 =>
        '$name rejected the request'
            '${model == null ? '' : ' for "$model"'}. '
            'The model name or a generation setting may be invalid.',
      401 => 'Your $name API key was rejected. Check it in AI settings.',
      403 =>
        '$name denied access. Check that this key may use '
            '${model ?? 'the selected model'}, and that the API is enabled.',
      404 =>
        'Model "${model ?? '?'}" was not found on $name. '
            'Pick another in AI settings.',
      413 => 'The prompt was too large for $name. Lower the sample size.',
      429 => '$name rate-limited the request. Wait a moment and try again.',
      >= 500 => '$name is having server trouble ($status). Try again shortly.',
      _ => '$name returned an error ($status).',
    };
    return AiException(message, detail: detail, statusCode: status);
  }

  /// Both dialects nest their real explanation under `error`.
  String? _providerMessage(String rawBody) {
    try {
      final decoded = jsonDecode(rawBody);
      if (decoded is Map) {
        final error = decoded['error'];
        if (error is Map && error['message'] is String) {
          return error['message'] as String;
        }
        if (error is String) return error;
        if (decoded['message'] is String) return decoded['message'] as String;
      }
    } on FormatException {
      return null;
    }
    return null;
  }

  String? _snippet(String rawBody) {
    final trimmed = rawBody.trim();
    if (trimmed.isEmpty) return null;
    return trimmed.length > 400 ? trimmed.substring(0, 400) : trimmed;
  }

  void close() => _http.close(force: true);
}
