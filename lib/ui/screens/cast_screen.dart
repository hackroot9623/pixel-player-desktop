import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../platform/cast/cast_controller.dart';
import '../../state/providers.dart';
import '../components/common.dart';

/// Sends what is playing to a Chromecast or a DLNA speaker.
///
/// The app stays in charge of the queue while casting — the speaker is handed one
/// track at a time — so the transport controls everywhere else in the app keep
/// working and drive the speaker instead of the local output.
class CastScreen extends ConsumerStatefulWidget {
  const CastScreen({super.key});

  @override
  ConsumerState<CastScreen> createState() => _CastScreenState();
}

class _CastScreenState extends ConsumerState<CastScreen> {
  List<CastTarget>? _targets;
  bool _searching = false;
  int _deviceVolume = 60;

  @override
  void initState() {
    super.initState();
    // Search on arrival: nobody opens this screen for any other reason.
    WidgetsBinding.instance.addPostFrameCallback((_) => _search());
  }

  Future<void> _search() async {
    setState(() => _searching = true);
    final found = await ref.read(castControllerProvider).discover();
    if (!mounted) return;
    setState(() {
      _targets = found;
      _searching = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cast = ref.watch(castControllerProvider);
    final targets = _targets;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Cast'),
        actions: [
          IconButton(
            tooltip: 'Search again',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _searching ? null : _search,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        children: [
          if (cast.casting) ...[
            Card(
              color: theme.colorScheme.secondaryContainer,
              child: Column(
                children: [
                  ListTile(
                    leading: Icon(
                      _iconFor(cast.target!.protocol),
                      color: theme.colorScheme.onSecondaryContainer,
                    ),
                    title: Text('Playing on ${cast.target!.name}'),
                    subtitle: Text(
                      _protocolLabel(cast.target!.protocol),
                      style: theme.textTheme.bodySmall,
                    ),
                    trailing: FilledButton.tonal(
                      onPressed: () => ref.read(castControllerProvider).stop(),
                      child: const Text('Stop'),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: Row(
                      children: [
                        const Icon(Icons.speaker_rounded, size: 18),
                        Expanded(
                          child: Slider(
                            value: _deviceVolume.toDouble(),
                            max: 100,
                            onChanged: (value) =>
                                setState(() => _deviceVolume = value.round()),
                            onChangeEnd: (value) => ref
                                .read(castControllerProvider)
                                .setDeviceVolume(value.round()),
                          ),
                        ),
                        SizedBox(
                          width: 44,
                          child: Text(
                            '$_deviceVolume%',
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: Text(
                      'Play, pause, skip and seek from anywhere in the app — '
                      'they drive the speaker while this is on. Your local '
                      'output stays quiet.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSecondaryContainer,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
          ],

          if (cast.error != null) ...[
            Card(
              color: theme.colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  cast.error!,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onErrorContainer,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
          ],

          Text('Speakers on your network', style: theme.textTheme.titleSmall),
          Text(
            'Chromecast and DLNA renderers. The speaker fetches the music from '
            'this computer, so both have to be on the same network.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),

          if (_searching && targets == null)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 32),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (targets == null || targets.isEmpty)
            EmptyState(
              icon: Icons.cast_rounded,
              title: 'No speakers found',
              message:
                  'Nothing answered on this network. A device has to be awake '
                  'and on the same subnet — a guest network or a VPN will hide '
                  'it.',
              action: FilledButton.tonal(
                onPressed: _searching ? null : _search,
                child: const Text('Search again'),
              ),
            )
          else
            for (final target in targets)
              Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  leading: Icon(_iconFor(target.protocol)),
                  title: Text(target.name),
                  subtitle: Text(
                    '${_protocolLabel(target.protocol)} · ${target.address}',
                  ),
                  trailing: cast.target?.id == target.id
                      ? Icon(
                          Icons.check_circle_rounded,
                          color: theme.colorScheme.primary,
                        )
                      : TextButton(
                          onPressed: () =>
                              ref.read(castControllerProvider).start(target),
                          child: const Text('Play here'),
                        ),
                ),
              ),

          if (_searching && targets != null)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: LinearProgressIndicator(),
            ),
        ],
      ),
    );
  }
}

IconData _iconFor(CastProtocol protocol) => switch (protocol) {
  CastProtocol.chromecast => Icons.cast_rounded,
  CastProtocol.dlna => Icons.speaker_group_rounded,
};

String _protocolLabel(CastProtocol protocol) => switch (protocol) {
  CastProtocol.chromecast => 'Chromecast',
  CastProtocol.dlna => 'DLNA',
};
