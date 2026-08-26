import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../../data/prefs/settings.dart';
import '../../state/providers.dart';

/// Height of the client-side title strip. Slimmer than a GNOME header bar, so
/// turning system decorations off genuinely buys vertical space.
const windowTitleBarHeight = 34.0;

/// Applies the decoration setting to the real window.
///
/// `TitleBarStyle.hidden` maps to `gtk_window_set_decorated(false)` on Linux,
/// and to the equivalent on Windows and macOS, so the app has to draw its own
/// close/minimise/maximise controls and its own drag region.
Future<void> applyWindowDecorations({required bool useCustomTitleBar}) async {
  await windowManager.setTitleBarStyle(
    useCustomTitleBar ? TitleBarStyle.hidden : TitleBarStyle.normal,
    windowButtonVisibility: !useCustomTitleBar,
  );
}

/// The client-side title bar: a draggable strip carrying the window controls.
///
/// Renders nothing at all when the user keeps the system title bar, so there is
/// no dead space in that mode.
class WindowTitleBar extends ConsumerWidget {
  const WindowTitleBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    if (!settings.useCustomTitleBar) return const SizedBox.shrink();

    final controls = WindowControls(style: settings.windowControlsStyle);
    final onLeft =
        settings.windowControlsPlacement == WindowControlsPlacement.topLeft;

    return SizedBox(
      height: windowTitleBarHeight,
      child: Row(
        children: [
          if (onLeft) ...[const SizedBox(width: 8), controls],
          // Everything that is not a button drags the window, and a
          // double-click toggles maximise — the conventions a real title bar
          // provides and which are otherwise lost with decorations off.
          const Expanded(child: WindowDragArea()),
          if (!onLeft) ...[controls, const SizedBox(width: 8)],
        ],
      ),
    );
  }
}

class WindowDragArea extends StatelessWidget {
  const WindowDragArea({super.key, this.child});

  final Widget? child;

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.translucent,
    onPanStart: (_) => windowManager.startDragging(),
    onDoubleTap: () async =>
        await windowManager.isMaximized()
            ? windowManager.unmaximize()
            : windowManager.maximize(),
    child: child ?? const SizedBox.expand(),
  );
}

/// Minimise / maximise / close, in either of the two conventions people
/// actually expect: Windows-and-GNOME style glyphs, or macOS traffic lights.
class WindowControls extends StatefulWidget {
  const WindowControls({super.key, required this.style});

  final WindowControlsStyle style;

  @override
  State<WindowControls> createState() => _WindowControlsState();
}

class _WindowControlsState extends State<WindowControls> with WindowListener {
  bool _maximized = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    windowManager.isMaximized().then((value) {
      if (mounted) setState(() => _maximized = value);
    });
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  // The maximise glyph has to follow the real window state, including changes
  // the user makes through the compositor (a keyboard shortcut, a snap gesture).
  @override
  void onWindowMaximize() => setState(() => _maximized = true);

  @override
  void onWindowUnmaximize() => setState(() => _maximized = false);

  void _toggleMaximize() =>
      _maximized ? windowManager.unmaximize() : windowManager.maximize();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDots = widget.style == WindowControlsStyle.dots;

    // Traffic lights read left-to-right close/minimise/maximise; glyph sets
    // read minimise/maximise/close.
    final buttons = <Widget>[
      if (isDots)
        _Dot(
          color: const Color(0xFFFF5F57),
          tooltip: 'Close',
          icon: Icons.close_rounded,
          onTap: windowManager.close,
        ),
      _Dot(
        color: const Color(0xFFFEBC2E),
        tooltip: 'Minimise',
        icon: Icons.remove_rounded,
        onTap: windowManager.minimize,
        asDot: isDots,
        glyphColor: scheme.onSurfaceVariant,
      ),
      _Dot(
        color: const Color(0xFF28C840),
        tooltip: _maximized ? 'Restore' : 'Maximise',
        icon: _maximized
            ? Icons.filter_none_rounded
            : Icons.crop_square_rounded,
        onTap: _toggleMaximize,
        asDot: isDots,
        glyphColor: scheme.onSurfaceVariant,
      ),
      if (!isDots)
        _Dot(
          color: const Color(0xFFFF5F57),
          tooltip: 'Close',
          icon: Icons.close_rounded,
          asDot: false,
          onTap: windowManager.close,
          glyphColor: scheme.onSurfaceVariant,
          // Closing is the one destructive control, so it gets the red hover
          // treatment rather than the neutral one.
          dangerous: true,
        ),
    ];

    return Row(
      mainAxisSize: MainAxisSize.min,
      spacing: isDots ? 8 : 2,
      children: buttons,
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({
    required this.color,
    required this.tooltip,
    required this.icon,
    required this.onTap,
    this.asDot = true,
    this.glyphColor,
    this.dangerous = false,
  });

  final Color color;
  final String tooltip;
  final IconData icon;
  final VoidCallback onTap;
  final bool asDot;
  final Color? glyphColor;
  final bool dangerous;

  @override
  Widget build(BuildContext context) {
    if (asDot) {
      return Tooltip(
        message: tooltip,
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: Container(
            width: 13,
            height: 13,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
        ),
      );
    }
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        hoverColor: dangerous
            ? color.withValues(alpha: 0.9)
            : Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.1),
        child: SizedBox(
          width: 40,
          height: windowTitleBarHeight,
          child: Center(child: Icon(icon, size: 16, color: glyphColor)),
        ),
      ),
    );
  }
}

/// Drag handles along the window edges.
///
/// Required, not decorative: hiding the system decorations also removes the
/// compositor's resize borders, so without these the window cannot be resized
/// with the mouse at all. Renders nothing in system-decoration mode, where the
/// compositor still owns the edges.
class WindowResizeArea extends ConsumerWidget {
  const WindowResizeArea({super.key, required this.child});

  final Widget child;

  /// Wide enough to hit comfortably, narrow enough not to swallow clicks meant
  /// for the UI underneath.
  static const _edge = 5.0;
  static const _corner = 12.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final custom = ref.watch(
      settingsProvider.select((settings) => settings.useCustomTitleBar),
    );
    if (!custom) return child;

    return Stack(
      // Tight constraints for the wrapped app: with the default loose fit the
      // content sized to itself, and a Row with an Expanded inside it ended up
      // laid out against unbounded width.
      fit: StackFit.expand,
      children: [
        child,
        // Edges.
        _handle(
          left: 0,
          top: _corner,
          bottom: _corner,
          width: _edge,
          edge: ResizeEdge.left,
          cursor: SystemMouseCursors.resizeLeftRight,
        ),
        _handle(
          right: 0,
          top: _corner,
          bottom: _corner,
          width: _edge,
          edge: ResizeEdge.right,
          cursor: SystemMouseCursors.resizeLeftRight,
        ),
        _handle(
          top: 0,
          left: _corner,
          right: _corner,
          height: _edge,
          edge: ResizeEdge.top,
          cursor: SystemMouseCursors.resizeUpDown,
        ),
        _handle(
          bottom: 0,
          left: _corner,
          right: _corner,
          height: _edge,
          edge: ResizeEdge.bottom,
          cursor: SystemMouseCursors.resizeUpDown,
        ),
        // Corners.
        _handle(
          top: 0,
          left: 0,
          width: _corner,
          height: _corner,
          edge: ResizeEdge.topLeft,
          cursor: SystemMouseCursors.resizeUpLeftDownRight,
        ),
        _handle(
          top: 0,
          right: 0,
          width: _corner,
          height: _corner,
          edge: ResizeEdge.topRight,
          cursor: SystemMouseCursors.resizeUpRightDownLeft,
        ),
        _handle(
          bottom: 0,
          left: 0,
          width: _corner,
          height: _corner,
          edge: ResizeEdge.bottomLeft,
          cursor: SystemMouseCursors.resizeUpRightDownLeft,
        ),
        _handle(
          bottom: 0,
          right: 0,
          width: _corner,
          height: _corner,
          edge: ResizeEdge.bottomRight,
          cursor: SystemMouseCursors.resizeUpLeftDownRight,
        ),
      ],
    );
  }

  Widget _handle({
    required ResizeEdge edge,
    required MouseCursor cursor,
    double? left,
    double? right,
    double? top,
    double? bottom,
    double? width,
    double? height,
  }) => Positioned(
    left: left,
    right: right,
    top: top,
    bottom: bottom,
    width: width,
    height: height,
    child: MouseRegion(
      cursor: cursor,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onPanStart: (_) => windowManager.startResizing(edge),
      ),
    ),
  );
}

/// Wraps the entire app — above the root navigator — so the title bar and the
/// resize handles are present on every screen.
///
/// Installed through `MaterialApp.builder` rather than inside the shell: routes
/// pushed on the root navigator (the full player) and dialogs would otherwise
/// cover the strip, leaving no way to move or close the window without
/// navigating back first.
class WindowChrome extends ConsumerWidget {
  const WindowChrome({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final custom = ref.watch(
      settingsProvider.select((settings) => settings.useCustomTitleBar),
    );
    // With system decorations there is nothing to add, and no reason to put
    // another layer between the app and the view.
    if (!custom) return child;

    return WindowResizeArea(
      child: Column(
        children: [
          // Above the root navigator there is no Material and no Overlay, which
          // the strip's InkWells and Tooltips both require — the controls
          // rendered as error widgets without them. The Overlay wraps only the
          // strip, never `child`: an OverlayEntry captures its builder, so
          // putting the app inside one would freeze it on the first route.
          Material(
            color: Theme.of(context).colorScheme.surface,
            child: SizedBox(
              height: windowTitleBarHeight,
              child: Overlay(
                initialEntries: [
                  OverlayEntry(builder: (context) => const WindowTitleBar()),
                ],
              ),
            ),
          ),
          Expanded(child: child),
        ],
      ),
    );
  }
}
