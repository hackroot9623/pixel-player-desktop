import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// Stops the player's single-key shortcuts from firing while someone is typing.
//
// The problem is a real one in Flutter and not obvious: a text field receives its
// characters through the platform text-input channel, and does *not* mark the
// corresponding key event as handled. The event therefore keeps travelling up the
// focus chain, and a `CallbackShortcuts` above the field happily runs its
// binding. Typing "l" in the search box toggled the favourite on the playing
// song, "s" toggled shuffle, and space paused the music.
//
// The fix has to sit *below* the shortcuts in the tree, because key events
// propagate upwards from the focused node: only a descendant of the shortcut
// widget can stop the event before it gets there. Returning `handled` swallows
// the key for the shortcut layer while leaving text entry — which never looked at
// the key event — untouched.

/// Whether the keyboard currently belongs to a text field.
bool keyboardIsTyping([FocusNode? focus]) {
  final node = focus ?? FocusManager.instance.primaryFocus;
  final context = node?.context;
  if (context == null) return false;
  // EditableText is what every text field is built from, so one check covers
  // TextField, TextFormField, search bars and the tag editor alike.
  if (context.widget is EditableText) return true;
  return context.findAncestorWidgetOfExactType<EditableText>() != null;
}

/// Swallows keys that would otherwise reach [activators] while typing.
///
/// Only the keys the shortcut layer claims are swallowed. Anything else — Escape,
/// Tab, a real Ctrl chord — keeps travelling, so dialogs and traversal still
/// work while a field has focus.
class TypingShortcutBarrier extends StatelessWidget {
  const TypingShortcutBarrier({
    super.key,
    required this.activators,
    required this.child,
  });

  final Iterable<ShortcutActivator> activators;
  final Widget child;

  @override
  Widget build(BuildContext context) => Focus(
    // Not a focus stop of its own: it exists only to sit in the chain and veto.
    canRequestFocus: false,
    skipTraversal: true,
    onKeyEvent: (node, event) {
      if (!keyboardIsTyping()) return KeyEventResult.ignored;
      final claimed = activators.any(
        (activator) => activator.accepts(event, HardwareKeyboard.instance),
      );
      return claimed ? KeyEventResult.handled : KeyEventResult.ignored;
    },
    child: child,
  );
}
