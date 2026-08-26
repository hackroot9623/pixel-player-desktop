import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

/// The three shapes the app is designed for, as one-click window sizes.
///
/// Resizing by hand works too — the layout follows the window either way — but
/// hitting a usable size by dragging a corner is fiddly, so these are the
/// canonical ones.
enum WindowSizePreset {
  mini(
    'Mini',
    'Artwork and transport in a strip',
    Icons.compress_rounded,
    Size(420, 200),
  ),
  player(
    'Player',
    'Big artwork with the controls below',
    Icons.album_rounded,
    Size(520, 680),
  ),
  full('Full', 'The whole library', Icons.dashboard_rounded, Size(1360, 860));

  const WindowSizePreset(this.label, this.description, this.icon, this.size);

  final String label;
  final String description;
  final IconData icon;
  final Size size;
}

/// Applies a preset to the real window.
Future<void> applyWindowSizePreset(WindowSizePreset preset) async {
  // Resizing a maximised window is ignored by the compositor, so drop out of
  // maximised state first.
  if (await windowManager.isMaximized()) await windowManager.unmaximize();
  await windowManager.setSize(preset.size);
  await windowManager.center();
}

/// Row of preset buttons.
///
/// [onApply] exists so this can be driven without a window manager; it defaults
/// to resizing the real window.
class WindowSizePresetButtons extends StatelessWidget {
  const WindowSizePresetButtons({
    super.key,
    this.onApply,
    this.labelled = false,
    this.current,
  });

  final Future<void> Function(WindowSizePreset preset)? onApply;
  final bool labelled;

  /// Highlighted when the window already matches this preset's shape.
  final WindowSizePreset? current;

  @override
  Widget build(BuildContext context) {
    final apply = onApply ?? applyWindowSizePreset;
    if (labelled) {
      return Column(
        children: [
          for (final preset in WindowSizePreset.values)
            ListTile(
              leading: Icon(preset.icon),
              title: Text(preset.label),
              subtitle: Text(preset.description),
              trailing: Text(
                '${preset.size.width.round()}×${preset.size.height.round()}',
                style: Theme.of(context).textTheme.labelSmall,
              ),
              selected: current == preset,
              onTap: () => apply(preset),
            ),
        ],
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final preset in WindowSizePreset.values)
          IconButton(
            tooltip: '${preset.label} — ${preset.description}',
            iconSize: 18,
            visualDensity: VisualDensity.compact,
            isSelected: current == preset,
            icon: Icon(preset.icon),
            onPressed: () => apply(preset),
          ),
      ],
    );
  }
}
