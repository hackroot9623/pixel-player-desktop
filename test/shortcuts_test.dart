import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixelplay_desktop/ui/shell/typing_barrier.dart';

/// The player's shortcuts are single keys — l, s, r, space, the arrows — which is
/// fine until someone types in the search box. A text field takes its characters
/// from the platform text-input channel and leaves the key event unhandled, so
/// without a barrier the event reaches the shortcut layer and "l" favourites the
/// playing song.

void main() {
  late int fired;
  late FocusNode plainNode;

  /// The shell's shape: shortcuts above, barrier below, then the content.
  Widget harness({required bool withBarrier}) {
    const activators = <ShortcutActivator>[
      SingleActivator(LogicalKeyboardKey.keyL),
      SingleActivator(LogicalKeyboardKey.space),
      SingleActivator(LogicalKeyboardKey.arrowRight),
    ];

    final content = Column(
      children: [
        const TextField(key: Key('search')),
        Focus(
          focusNode: plainNode,
          child: const SizedBox(width: 40, height: 40),
        ),
      ],
    );

    return MaterialApp(
      home: Scaffold(
        body: CallbackShortcuts(
          bindings: {
            for (final activator in activators) activator: () => fired++,
          },
          child: withBarrier
              ? TypingShortcutBarrier(
                  activators: activators,
                  child: content,
                )
              : content,
        ),
      ),
    );
  }

  setUp(() {
    fired = 0;
    plainNode = FocusNode(debugLabel: 'plain');
  });

  tearDown(() => plainNode.dispose());

  group('while typing in a text field', () {
    testWidgets('a bare letter does not reach the shortcuts', (tester) async {
      await tester.pumpWidget(harness(withBarrier: true));
      await tester.tap(find.byKey(const Key('search')));
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
      await tester.pump();

      expect(fired, 0);
    });

    testWidgets('space and the arrows are held back too', (tester) async {
      // Space paused the music mid-word; the arrows seeked instead of moving
      // the caret.
      await tester.pumpWidget(harness(withBarrier: true));
      await tester.tap(find.byKey(const Key('search')));
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();

      expect(fired, 0);
    });

    testWidgets('a key the shortcuts do not claim still travels', (tester) async {
      // The barrier vetoes only what the shortcut layer wants, so Escape, Tab
      // and real chords keep working while a field has focus.
      var escapes = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CallbackShortcuts(
              bindings: {
                const SingleActivator(LogicalKeyboardKey.escape): () =>
                    escapes++,
              },
              child: const TypingShortcutBarrier(
                activators: [SingleActivator(LogicalKeyboardKey.keyL)],
                child: TextField(key: Key('search')),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('search')));
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();

      expect(escapes, 1);
    });
  });

  group('when a text field does not have focus', () {
    testWidgets('the shortcut fires as it should', (tester) async {
      await tester.pumpWidget(harness(withBarrier: true));
      // Focus something that is not a text field.
      plainNode.requestFocus();
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
      await tester.pump();

      expect(fired, 1);
    });

    testWidgets('the barrier is what makes the difference', (tester) async {
      // Without it, the same keypress in the same text field runs the binding —
      // which is the bug as reported.
      await tester.pumpWidget(harness(withBarrier: false));
      await tester.tap(find.byKey(const Key('search')));
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
      await tester.pump();

      expect(fired, 1);
    });
  });

  group('detecting a text field', () {
    testWidgets('a focused field reads as typing, a plain node does not', (
      tester,
    ) async {
      await tester.pumpWidget(harness(withBarrier: true));

      await tester.tap(find.byKey(const Key('search')));
      await tester.pump();
      expect(keyboardIsTyping(), isTrue);

      plainNode.requestFocus();
      await tester.pump();
      expect(keyboardIsTyping(), isFalse);
    });

    testWidgets('nothing focused is not typing', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      expect(keyboardIsTyping(), isFalse);
    });
  });
}
