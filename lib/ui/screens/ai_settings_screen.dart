import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/ai/ai_client.dart';
import '../../data/ai/ai_provider.dart';
import '../../state/providers.dart';

/// Port of the AI section of `SettingsCategoryScreen`.
///
/// One provider is active at a time, but the key, model and endpoint are stored
/// per provider, so switching to compare two of them does not mean pasting keys
/// back in.
class AiSettingsScreen extends ConsumerStatefulWidget {
  const AiSettingsScreen({super.key});

  @override
  ConsumerState<AiSettingsScreen> createState() => _AiSettingsScreenState();
}

class _AiSettingsScreenState extends ConsumerState<AiSettingsScreen> {
  final _keyController = TextEditingController();
  final _urlController = TextEditingController();
  AiProvider? _loadedFor;

  /// null while untested, then the outcome of the last test.
  bool? _keyValid;
  bool _testing = false;
  String? _testError;

  @override
  void dispose() {
    _keyController.dispose();
    _urlController.dispose();
    super.dispose();
  }

  /// Reloads the fields when the active provider changes.
  void _syncFields(AiProvider provider) {
    if (_loadedFor == provider) return;
    final settings = ref.read(settingsProvider);
    _loadedFor = provider;
    _keyController.text = settings.apiKey(provider);
    _urlController.text = settings.aiBaseUrl(provider);
    _keyValid = null;
    _testError = null;
  }

  Future<void> _test() async {
    setState(() {
      _testing = true;
      _testError = null;
    });
    try {
      final ok = await ref.read(aiClientProvider).validateApiKey();
      if (mounted) setState(() => _keyValid = ok);
    } on AiException catch (error) {
      if (mounted) {
        setState(() {
          _keyValid = false;
          _testError = error.message;
        });
      }
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final provider = settings.aiProvider;
    _syncFields(provider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('AI')),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        children: [
          Text(
            'Playlists are built by sending a list of candidate tracks — '
            'titles, artists and genres — to the provider you choose. Your '
            'files never leave the machine.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 20),
          DropdownButtonFormField<AiProvider>(
            initialValue: provider,
            decoration: const InputDecoration(
              labelText: 'Provider',
              border: OutlineInputBorder(),
            ),
            items: [
              for (final option in AiProvider.values)
                DropdownMenuItem(
                  value: option,
                  child: Text(option.displayName),
                ),
            ],
            onChanged: (value) {
              if (value != null) settings.aiProvider = value;
            },
          ),
          const SizedBox(height: 16),
          if (provider.hasConfigurableUrl) ...[
            TextField(
              controller: _urlController,
              decoration: InputDecoration(
                labelText: 'Endpoint URL',
                hintText: provider.baseUrl.isEmpty
                    ? 'https://your-host/v1'
                    : provider.baseUrl,
                helperText: 'OpenAI-compatible /chat/completions endpoint',
                border: const OutlineInputBorder(),
              ),
              onSubmitted: (value) =>
                  settings.setAiBaseUrl(provider, value),
              onTapOutside: (_) =>
                  settings.setAiBaseUrl(provider, _urlController.text),
            ),
            const SizedBox(height: 16),
          ],
          if (provider.requiresApiKey)
            TextField(
              controller: _keyController,
              obscureText: true,
              autofillHints: const [],
              decoration: InputDecoration(
                labelText: 'API key',
                border: const OutlineInputBorder(),
                helperText: 'Stored on this machine in plain text',
                suffixIcon: _keyValid == null
                    ? null
                    : Icon(
                        _keyValid!
                            ? Icons.check_circle_outline_rounded
                            : Icons.error_outline_rounded,
                        color: _keyValid!
                            ? theme.colorScheme.primary
                            : theme.colorScheme.error,
                      ),
              ),
              onChanged: (value) {
                settings.setApiKey(provider, value);
                if (_keyValid != null || _testError != null) {
                  setState(() {
                    _keyValid = null;
                    _testError = null;
                  });
                }
              },
            ),
          if (_testError != null) ...[
            const SizedBox(height: 8),
            Text(
              _testError!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              FilledButton.tonalIcon(
                onPressed: _testing ? null : _test,
                icon: _testing
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.wifi_tethering_rounded, size: 18),
                label: Text(_testing ? 'Testing…' : 'Test connection'),
              ),
            ],
          ),
          const Divider(height: 40),
          _ModelPicker(provider: provider),
          const Divider(height: 40),
          Text('Request size', style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(
            'How much of your library is described to the model. More '
            'candidates give better picks and cost more tokens.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          _SliderRow(
            label: 'Candidate tracks',
            value: settings.aiSampleSize.toDouble(),
            min: 10,
            max: 200,
            divisions: 19,
            display: '${settings.aiSampleSize}',
            onChanged: (value) => settings.aiSampleSize = value.round(),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Safe token limit'),
            subtitle: const Text(
              'Keeps the candidate list to the size above. Off doubles it.',
            ),
            value: settings.aiSafeTokenLimit,
            onChanged: (value) => settings.aiSafeTokenLimit = value,
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Send extra detail'),
            subtitle: const Text(
              'Adds album, length and likes to each candidate.',
            ),
            value: settings.aiExtendedFields,
            onChanged: (value) => settings.aiExtendedFields = value,
          ),
          const Divider(height: 40),
          Text('Generation', style: theme.textTheme.titleSmall),
          _SliderRow(
            label: 'Temperature',
            value: settings.aiTemperature,
            min: 0,
            max: 2,
            divisions: 20,
            display: settings.aiTemperature.toStringAsFixed(2),
            onChanged: (value) => settings.aiTemperature = value,
          ),
          _SliderRow(
            label: 'Top P',
            value: settings.aiTopP,
            min: 0,
            max: 1,
            divisions: 20,
            display: settings.aiTopP.toStringAsFixed(2),
            onChanged: (value) => settings.aiTopP = value,
          ),
          _SliderRow(
            label: 'Max tokens',
            value: settings.aiMaxTokens.toDouble(),
            min: 256,
            max: 16384,
            divisions: 63,
            display: '${settings.aiMaxTokens}',
            onChanged: (value) => settings.aiMaxTokens = value.round(),
          ),
        ],
      ),
    );
  }
}

/// Lists the models the key can actually use, rather than a hardcoded set that
/// goes stale every time a provider retires one.
class _ModelPicker extends ConsumerWidget {
  const _ModelPicker({required this.provider});

  final AiProvider provider;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final theme = Theme.of(context);
    final selected = settings.aiModel(provider);
    final models = ref.watch(aiModelsProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: Text('Model', style: theme.textTheme.titleSmall)),
            IconButton(
              tooltip: 'Reload models',
              icon: const Icon(Icons.refresh_rounded),
              onPressed: () => ref.invalidate(aiModelsProvider),
            ),
          ],
        ),
        Text(
          selected.isEmpty
              ? 'Using the default: ${provider.defaultModel}'
              : selected,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 12),
        models.when(
          loading: () => const LinearProgressIndicator(),
          error: (error, _) => Text(
            error is AiException
                ? error.message
                : 'Could not list models. $error',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
          data: (available) => available.isEmpty
              ? Text(
                  'No models reported.',
                  style: theme.textTheme.bodySmall,
                )
              : Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    ChoiceChip(
                      label: const Text('Default'),
                      selected: selected.isEmpty,
                      onSelected: (_) => settings.setAiModel(provider, ''),
                    ),
                    for (final model in available)
                      ChoiceChip(
                        label: Text(model),
                        selected: model == selected,
                        onSelected: (_) =>
                            settings.setAiModel(provider, model),
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}

class _SliderRow extends StatelessWidget {
  const _SliderRow({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.display,
    required this.onChanged,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String display;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      SizedBox(width: 140, child: Text(label)),
      Expanded(
        child: Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          divisions: divisions,
          onChanged: onChanged,
        ),
      ),
      SizedBox(
        width: 56,
        child: Text(
          display,
          textAlign: TextAlign.right,
          style: Theme.of(context).textTheme.labelMedium,
        ),
      ),
    ],
  );
}
