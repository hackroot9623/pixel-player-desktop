/// Port of `data/ai/provider/AiProvider` + `AiClientFactory`.
///
/// Every provider except Gemini speaks the OpenAI chat-completions dialect, so
/// the factory's job collapses into this table: a base URL and a default model
/// per provider, and one flag for the odd one out.
enum AiProvider {
  gemini(
    'gemini',
    'Google Gemini',
    baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
    defaultModel: 'gemini-3.1-flash-lite',
    dialect: AiDialect.gemini,
  ),
  deepseek(
    'deepseek',
    'DeepSeek',
    baseUrl: 'https://api.deepseek.com',
    defaultModel: 'deepseek-chat',
  ),
  groq(
    'groq',
    'Groq',
    baseUrl: 'https://api.groq.com/openai/v1',
    defaultModel: 'llama-3.1-8b-instant',
  ),
  mistral(
    'mistral',
    'Mistral',
    baseUrl: 'https://api.mistral.ai/v1',
    defaultModel: 'mistral-large-latest',
  ),
  nvidia(
    'nvidia',
    'NVIDIA NIM',
    baseUrl: 'https://integrate.api.nvidia.com/v1',
    defaultModel: 'meta/llama-3.1-8b-instruct',
  ),
  kimi(
    'kimi',
    'Kimi (Moonshot)',
    baseUrl: 'https://api.moonshot.cn/v1',
    defaultModel: 'moonshot-v1-8k',
  ),
  glm(
    'glm',
    'Zhipu GLM',
    baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
    defaultModel: 'glm-4',
  ),
  openai(
    'openai',
    'OpenAI',
    baseUrl: 'https://api.openai.com/v1',
    defaultModel: 'gpt-4o-mini',
  ),
  openrouter(
    'openrouter',
    'OpenRouter',
    baseUrl: 'https://openrouter.ai/api/v1',
    defaultModel: 'google/gemini-2.0-flash-lite-preview-02-05:free',
  ),
  ollama(
    'ollama',
    'Ollama',
    // Ollama normally runs on the same machine, which on desktop is the point:
    // a local model needs no key and no network. The Android app pointed at the
    // hosted API instead.
    baseUrl: 'http://localhost:11434/v1',
    defaultModel: 'llama3',
    requiresApiKey: false,
    hasConfigurableUrl: true,
  ),
  custom(
    'custom',
    'Custom (OpenAI-compatible)',
    baseUrl: '',
    defaultModel: '',
    hasConfigurableUrl: true,
  );

  const AiProvider(
    this.storageKey,
    this.displayName, {
    required this.baseUrl,
    required this.defaultModel,
    this.dialect = AiDialect.openai,
    this.requiresApiKey = true,
    this.hasConfigurableUrl = false,
  });

  final String storageKey;
  final String displayName;
  final String baseUrl;
  final String defaultModel;
  final AiDialect dialect;
  final bool requiresApiKey;

  /// Self-hosted and custom endpoints need the URL asking for.
  final bool hasConfigurableUrl;

  static const AiProvider defaultProvider = AiProvider.gemini;

  static AiProvider fromStorageKey(String? value) {
    for (final provider in values) {
      if (provider.storageKey == value) return provider;
    }
    return defaultProvider;
  }
}

enum AiDialect { openai, gemini }
