import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/transition.dart';
import '../../data/prefs/settings.dart';
import '../../state/providers.dart';
import '../components/album_art.dart';
import '../components/playback_controls.dart';
import '../components/window_controls.dart';
import '../theme/shapes.dart';

/// Port of `presentation/screens/PaletteStyleSettingsScreen`. Each Material
/// tonal-palette algorithm gets a live swatch strip built from the current seed.
class PaletteStyleScreen extends ConsumerWidget {
  const PaletteStyleScreen({super.key});

  static const _labels = {
    DynamicSchemeVariant.tonalSpot: (
      'Tonal spot',
      'Material default — soft, low-chroma palettes',
    ),
    DynamicSchemeVariant.vibrant: (
      'Vibrant',
      'Maximum chroma on the primary palette',
    ),
    DynamicSchemeVariant.expressive: (
      'Expressive',
      'Hue-shifted accents for more contrast between roles',
    ),
    DynamicSchemeVariant.content: (
      'Content',
      'Keeps the source colour intact, accents derived from it',
    ),
    DynamicSchemeVariant.fidelity: (
      'Fidelity',
      'Matches the source colour even when it is very saturated',
    ),
    DynamicSchemeVariant.neutral: ('Neutral', 'Barely any chroma'),
    DynamicSchemeVariant.monochrome: ('Monochrome', 'Greyscale only'),
    DynamicSchemeVariant.rainbow: ('Rainbow', 'Colourful accents, neutral base'),
    DynamicSchemeVariant.fruitSalad: (
      'Fruit salad',
      'Playful, hue-rotated primary and secondary',
    ),
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final brightness = Theme.of(context).brightness;

    return Scaffold(
      appBar: AppBar(title: const Text('Palette style')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text(
            'How a single colour — your accent, or the artwork of the playing '
            'track — is expanded into the full Material palette.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 20),
          for (final entry in _labels.entries)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _PaletteOption(
                variant: entry.key,
                title: entry.value.$1,
                description: entry.value.$2,
                selected: settings.paletteStyle == entry.key,
                scheme: ColorScheme.fromSeed(
                  seedColor: settings.seedColor,
                  brightness: brightness,
                  dynamicSchemeVariant: entry.key,
                ),
                onTap: () => settings.paletteStyle = entry.key,
              ),
            ),
        ],
      ),
    );
  }
}

class _PaletteOption extends StatelessWidget {
  const _PaletteOption({
    required this.variant,
    required this.title,
    required this.description,
    required this.selected,
    required this.scheme,
    required this.onTap,
  });

  final DynamicSchemeVariant variant;
  final String title;
  final String description;
  final bool selected;
  final ColorScheme scheme;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: selected
          ? theme.colorScheme.secondaryContainer
          : theme.colorScheme.surfaceContainerLow,
      shape: smoothCorner(24),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Column(
                children: [
                  for (final row in [
                    [scheme.primary, scheme.secondary, scheme.tertiary],
                    [
                      scheme.primaryContainer,
                      scheme.secondaryContainer,
                      scheme.surfaceContainerHighest,
                    ],
                  ])
                    Row(
                      children: [
                        for (final color in row)
                          Container(width: 26, height: 26, color: color),
                      ],
                    ),
                ],
              ),
              const SizedBox(width: 20),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: theme.textTheme.titleSmall),
                    Text(
                      description,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              if (selected)
                Icon(
                  Icons.check_circle_rounded,
                  color: theme.colorScheme.primary,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Port of `presentation/screens/NavBarCornerRadiusScreen` — a slider with a
/// live mock of the navigation rail so the radius can be judged in place.
class NavCornerRadiusScreen extends ConsumerWidget {
  const NavCornerRadiusScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final theme = Theme.of(context);
    final radius = settings.navBarCornerRadius;

    return Scaffold(
      appBar: AppBar(title: const Text('Navigation corner radius')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Center(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // Rail mock.
                    Container(
                      width: 84,
                      height: 260,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerHigh,
                        borderRadius: BorderRadius.circular(radius),
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        spacing: 22,
                        children: [
                          for (final icon in [
                            Icons.home_rounded,
                            Icons.search_rounded,
                            Icons.library_music_rounded,
                          ])
                            Icon(icon, color: theme.colorScheme.onSurfaceVariant),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    // Content mock.
                    Container(
                      width: 220,
                      height: 260,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerLow,
                        borderRadius: BorderRadius.only(
                          topLeft: Radius.circular(radius),
                          bottomLeft: Radius.circular(radius),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Text('${radius.round()} px', style: theme.textTheme.titleMedium),
            Slider(
              value: radius,
              max: 48,
              divisions: 48,
              onChanged: (value) => settings.navBarCornerRadius = value,
            ),
            Row(
              children: [
                TextButton(
                  onPressed: () => settings.navBarCornerRadius = 0,
                  child: const Text('Square'),
                ),
                TextButton(
                  onPressed: () => settings.navBarCornerRadius = 28,
                  child: const Text('Default'),
                ),
                TextButton(
                  onPressed: () => settings.navBarCornerRadius = 48,
                  child: const Text('Round'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Port of `presentation/screens/EditTransitionScreen` — mode, duration and the
/// in/out volume curves, with the curves drawn so the choice is legible.
class TransitionEditorScreen extends ConsumerWidget {
  const TransitionEditorScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final transition = settings.transition;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Transitions')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text('Mode', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          for (final mode in TransitionMode.values)
            RadioListTile<TransitionMode>(
              value: mode,
              groupValue: transition.mode,
              title: Text(mode.label),
              subtitle: mode.needsOverlap
                  ? const Text(
                      'Rendered as fade out then in — true overlap needs the '
                      'dual-decoder engine (see PLAN.md phase 7)',
                    )
                  : null,
              onChanged: (value) {
                if (value != null) {
                  settings.transition = transition.copyWith(mode: value);
                }
              },
            ),
          const Divider(height: 32),
          Text(
            'Duration — ${(transition.durationMs / 1000).toStringAsFixed(1)} s',
            style: theme.textTheme.titleSmall,
          ),
          Slider(
            value: transition.durationMs.toDouble(),
            min: 250,
            max: 12000,
            divisions: 47,
            label: '${(transition.durationMs / 1000).toStringAsFixed(1)} s',
            onChanged: transition.mode == TransitionMode.none
                ? null
                : (value) => settings.transition = transition.copyWith(
                    durationMs: value.round(),
                  ),
          ),
          const Divider(height: 32),
          Row(
            spacing: 24,
            children: [
              Expanded(
                child: _CurvePicker(
                  title: 'Fade in',
                  value: transition.curveIn,
                  enabled: transition.mode != TransitionMode.none,
                  onChanged: (value) =>
                      settings.transition = transition.copyWith(curveIn: value),
                ),
              ),
              Expanded(
                child: _CurvePicker(
                  title: 'Fade out',
                  value: transition.curveOut,
                  enabled: transition.mode != TransitionMode.none,
                  onChanged: (value) => settings.transition = transition
                      .copyWith(curveOut: value),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CurvePicker extends StatelessWidget {
  const _CurvePicker({
    required this.title,
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  final String title;
  final TransitionCurve value;
  final bool enabled;
  final ValueChanged<TransitionCurve> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        Container(
          height: 90,
          decoration: ShapeDecoration(
            color: theme.colorScheme.surfaceContainerLow,
            shape: smoothCorner(18),
          ),
          padding: const EdgeInsets.all(12),
          child: CustomPaint(
            painter: _CurvePainter(
              curve: value,
              color: enabled
                  ? theme.colorScheme.primary
                  : theme.colorScheme.outlineVariant,
            ),
            child: const SizedBox.expand(),
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            for (final curve in TransitionCurve.values)
              ChoiceChip(
                label: Text(curve.label),
                selected: value == curve,
                onSelected: enabled ? (_) => onChanged(curve) : null,
              ),
          ],
        ),
      ],
    );
  }
}

class _CurvePainter extends CustomPainter {
  _CurvePainter({required this.curve, required this.color});

  final TransitionCurve curve;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()..moveTo(0, size.height);
    for (var i = 0; i <= 40; i++) {
      final t = i / 40;
      path.lineTo(t * size.width, size.height * (1 - curve.apply(t)));
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(_CurvePainter old) =>
      old.curve != curve || old.color != color;
}

/// The carousel-style picker from the Android player settings, with a live
/// preview of how much of the neighbouring artwork peeks in.
class PlayerLookScreen extends ConsumerWidget {
  const PlayerLookScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final songs = ref.watch(libraryProvider).songs.take(3).toList();
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Player look')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text('Artwork carousel', style: theme.textTheme.titleSmall),
          const SizedBox(height: 12),
          for (final style in CarouselStyle.values)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Material(
                color: settings.carouselStyle == style
                    ? theme.colorScheme.secondaryContainer
                    : theme.colorScheme.surfaceContainerLow,
                shape: smoothCorner(24),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () => settings.carouselStyle = style,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        // Mock of the peek layout: one wide tile plus slivers.
                        SizedBox(
                          width: 140,
                          height: 70,
                          child: Row(
                            spacing: 4,
                            children: [
                              for (final (i, weight)
                                  in style.flexWeights.indexed)
                                Expanded(
                                  flex: weight,
                                  child: AlbumArt(
                                    path: songs.isEmpty
                                        ? null
                                        : songs[i % songs.length].albumArtPath,
                                    radius: 10,
                                  ),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 20),
                        Expanded(
                          child: Text(
                            style.label,
                            style: theme.textTheme.titleSmall,
                          ),
                        ),
                        if (settings.carouselStyle == style)
                          Icon(
                            Icons.check_circle_rounded,
                            color: theme.colorScheme.primary,
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          const Divider(height: 32),
          SwitchListTile(
            secondary: const Icon(Icons.info_outline_rounded),
            title: const Text('Show file info under the seek bar'),
            subtitle: const Text('Format, bitrate and sample rate'),
            value: settings.showPlayerFileInfo,
            onChanged: (value) => settings.showPlayerFileInfo = value,
          ),
          SwitchListTile(
            secondary: const Icon(Icons.straighten_rounded),
            title: const Text('Show scrollbars'),
            subtitle: const Text('The draggable jump bar on long lists'),
            value: settings.showScrollbar,
            onChanged: (value) => settings.showScrollbar = value,
          ),
          const Divider(height: 32),
          Text('Transport preview', style: theme.textTheme.titleSmall),
          const SizedBox(height: 12),
          const TransportBar(),
          const SizedBox(height: 12),
          Text(
            'These are the real controls — they drive playback.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// Window decoration settings: replace the system title bar with our own, and
/// choose where its controls sit and how they look.
///
/// There is no Android counterpart — a phone has no window chrome — so this is
/// desktop-only surface area rather than a port.
class WindowScreen extends ConsumerWidget {
  const WindowScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final theme = Theme.of(context);
    final custom = settings.useCustomTitleBar;

    return Scaffold(
      appBar: AppBar(title: const Text('Window')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Card(
            child: SwitchListTile(
              secondary: const Icon(Icons.web_asset_rounded),
              title: const Text('Use the app’s own title bar'),
              subtitle: const Text(
                'Hides the system title bar and draws the window buttons '
                'in-app, so the interface reaches the window edges',
              ),
              value: custom,
              onChanged: (value) {
                settings.useCustomTitleBar = value;
                // Applied to the real window immediately — no restart.
                applyWindowDecorations(useCustomTitleBar: value);
              },
            ),
          ),
          const SizedBox(height: 24),

          Text('Preview', style: theme.textTheme.titleSmall),
          const SizedBox(height: 12),
          _WindowPreview(
            custom: custom,
            placement: settings.windowControlsPlacement,
            style: settings.windowControlsStyle,
          ),
          const SizedBox(height: 24),

          // Disabled rather than hidden, so it is clear what the switch above
          // unlocks.
          Opacity(
            opacity: custom ? 1 : 0.4,
            child: IgnorePointer(
              ignoring: !custom,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Button position', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 8),
                  SegmentedButton<WindowControlsPlacement>(
                    segments: [
                      for (final placement in WindowControlsPlacement.values)
                        ButtonSegment(
                          value: placement,
                          label: Text(placement.label),
                          icon: Icon(
                            placement == WindowControlsPlacement.topLeft
                                ? Icons.format_align_left_rounded
                                : Icons.format_align_right_rounded,
                          ),
                        ),
                    ],
                    selected: {settings.windowControlsPlacement},
                    onSelectionChanged: (value) =>
                        settings.windowControlsPlacement = value.first,
                  ),
                  const SizedBox(height: 24),
                  Text('Button style', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 8),
                  for (final style in WindowControlsStyle.values)
                    RadioListTile<WindowControlsStyle>(
                      value: style,
                      groupValue: settings.windowControlsStyle,
                      title: Text(style.label),
                      subtitle: Text(style.description),
                      secondary: WindowControlsPreview(style: style),
                      onChanged: (value) {
                        if (value != null) settings.windowControlsStyle = value;
                      },
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            color: theme.colorScheme.surfaceContainerHighest,
            child: const ListTile(
              leading: Icon(Icons.info_outline_rounded),
              title: Text('Dragging and maximising'),
              subtitle: Text(
                'With the app’s own title bar, drag the empty strip to '
                'move the window and double-click it to maximise.',
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A miniature window showing where the controls land.
class _WindowPreview extends StatelessWidget {
  const _WindowPreview({
    required this.custom,
    required this.placement,
    required this.style,
  });

  final bool custom;
  final WindowControlsPlacement placement;
  final WindowControlsStyle style;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final onLeft = placement == WindowControlsPlacement.topLeft;

    Widget bar({required bool system}) => Container(
      height: 22,
      color: system
          ? scheme.surfaceContainerHighest
          : scheme.surfaceContainerLow,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Row(
        children: [
          if (system)
            Text(
              'PixelPlayer',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          const Spacer(),
          WindowControlsPreview(style: style, scale: 0.7),
        ],
      ),
    );

    return Container(
      height: 150,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          if (custom)
            SizedBox(
              height: 22,
              child: Row(
                mainAxisAlignment: onLeft
                    ? MainAxisAlignment.start
                    : MainAxisAlignment.end,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: WindowControlsPreview(style: style, scale: 0.7),
                  ),
                ],
              ),
            )
          else
            bar(system: true),
          // Body: a stand-in for the rail plus content, to show how much
          // vertical space the choice costs.
          Expanded(
            child: Row(
              children: [
                Container(width: 26, color: scheme.surfaceContainerHigh),
                Expanded(
                  child: Container(color: scheme.surfaceContainerLowest),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Non-interactive rendering of the control cluster, for previews and pickers.
class WindowControlsPreview extends StatelessWidget {
  const WindowControlsPreview({super.key, required this.style, this.scale = 1});

  final WindowControlsStyle style;
  final double scale;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (style == WindowControlsStyle.dots) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 5 * scale,
        children: [
          for (final color in const [
            Color(0xFFFF5F57),
            Color(0xFFFEBC2E),
            Color(0xFF28C840),
          ])
            Container(
              width: 11 * scale,
              height: 11 * scale,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
        ],
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 6 * scale,
      children: [
        for (final icon in const [
          Icons.remove_rounded,
          Icons.crop_square_rounded,
          Icons.close_rounded,
        ])
          Icon(icon, size: 13 * scale, color: scheme.onSurfaceVariant),
      ],
    );
  }
}
