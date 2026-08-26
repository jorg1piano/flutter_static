import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_static/src/server_io.dart';
import 'package:flutter_static/src/story.dart';
import 'package:flutter_static/src/studio/canvas.dart';
import 'package:flutter_static/src/studio/controller.dart';
import 'package:flutter_test/flutter_test.dart';

var taps = 0;

class _ButtonStories extends Stories {
  const _ButtonStories();

  @override
  List<Story> build() => [
    Story(
      'buttons/one',
      () => GestureDetector(
        onTap: () => taps++,
        child: Container(
          width: 120,
          height: 40,
          color: const Color(0xFFFF0000),
          child: const Text('Press me'),
        ),
      ),
    ),
  ];
}

void main() {
  late StudioController controller;

  setUp(() {
    taps = 0;
    setStoryShell('buttons/one', StoryShell.unbounded);
    controller = StudioController(
      stories: const _ButtonStories(),
      project: '/nonexistent',
      port: 1,
    );
  });

  tearDown(() => controller.dispose());

  Widget canvas() => MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 800,
        height: 600,
        child: StudioCanvas(controller: controller),
      ),
    ),
  );

  testWidgets('interact mode: a click reaches the widget and selects', (
    tester,
  ) async {
    controller.interact = true;
    await tester.pumpWidget(canvas());
    await tester.pumpAndSettle();
    expect(find.text('Press me'), findsOneWidget);
    await tester.tap(find.text('Press me'));
    await tester.pumpAndSettle();
    expect(taps, 1);
    expect(controller.selectedStoryId, 'buttons/one');
    await tester.pump(const Duration(seconds: 1)); // the sizes-save timer
  });

  testWidgets('select mode: a click only selects', (tester) async {
    controller.interact = false;
    await tester.pumpWidget(canvas());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Press me'));
    await tester.pumpAndSettle();
    expect(taps, 0);
    expect(controller.selectedStoryId, 'buttons/one');
    await tester.pump(const Duration(seconds: 1)); // the sizes-save timer
  });

  testWidgets('option-click picks the widget under the pointer, in interact '
      'mode too, and reaches nothing', (tester) async {
    controller.interact = true;
    await tester.pumpWidget(canvas());
    await tester.pumpAndSettle();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.pump();
    expect(controller.altHeld, isTrue);
    // The card absorbs the click by design; the Listener above it picks.
    await tester.tap(find.text('Press me'), warnIfMissed: false);
    await tester.pumpAndSettle();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.pump();

    expect(taps, 0);
    expect(controller.selectedStoryId, 'buttons/one');
    expect(controller.pickStoryId, 'buttons/one');
    final pick = controller.pick!;
    final text = pick.chain.firstWhere((w) => w.type == 'Text');
    expect(text.text, 'Press me');
    expect(text.location!.file, endsWith('canvas_test.dart'));
    // The story's widgets and nothing of Studio's above the mount.
    expect(pick.chain.map((w) => w.type), contains('GestureDetector'));
    expect(pick.chain.map((w) => w.type), isNot(contains('StoryCard')));

    // A plain click afterwards reaches the widget and clears the pick.
    await tester.tap(find.text('Press me'));
    await tester.pumpAndSettle();
    expect(taps, 1);
    expect(controller.pick, isNull);
    await tester.pump(const Duration(seconds: 1)); // the sizes-save timer
  });

  testWidgets('after a pick the arrows walk the chain and Escape clears it', (
    tester,
  ) async {
    // Rooted at the package, so this file's widgets count as the
    // project's and the chain has rows to walk.
    controller.dispose();
    controller = StudioController(
      stories: const _ButtonStories(),
      project: Directory.current.path,
      port: 1,
    );
    await tester.pumpWidget(canvas());
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.pump();
    await tester.tap(find.text('Press me'), warnIfMissed: false);
    await tester.pumpAndSettle();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.pump();
    expect(controller.pickedWidget!.type, 'Text');

    // Up: the parent; the outline and the row follow the same index.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(controller.pickedWidget!.type, 'Container');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(controller.pickedWidget!.type, 'GestureDetector');
    // Down: back in.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(controller.pickedWidget!.type, 'Container');
    // Down past the clicked widget stays there.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(controller.pickedWidget!.type, 'Text');

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(controller.pick, isNull);
    expect(controller.selectedStoryId, 'buttons/one');
    await tester.pump(const Duration(seconds: 1)); // the sizes-save timer
  });
}
