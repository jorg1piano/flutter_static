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

class _LineStories extends Stories {
  const _LineStories();

  @override
  List<Story> build() => const [];

  @override
  List<Storyline> storylines() => [
    Storyline(
      'flows/onboarding',
      rows: [
        StorylineRow(
          'Top',
          cells: [
            Cell('welcome', variants: [Story('base', () => const Text('A'))]),
            Cell('signin', variants: [Story('base', () => const Text('B'))]),
          ],
        ),
        StorylineRow(
          'Bottom',
          cells: [
            Cell('home', variants: [Story('base', () => const Text('C'))]),
          ],
        ),
      ],
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

  testWidgets('a plain click picks the widget under the pointer', (
    tester,
  ) async {
    controller.interact = true;
    await tester.pumpWidget(canvas());
    await tester.pumpAndSettle();
    expect(find.text('Press me'), findsOneWidget);
    await tester.tap(find.text('Press me'), warnIfMissed: false);
    await tester.pumpAndSettle();
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
    await tester.pump(const Duration(seconds: 1)); // the sizes-save timer
  });

  testWidgets('plain click inspects in select mode too', (tester) async {
    controller.interact = false;
    await tester.pumpWidget(canvas());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Press me'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(taps, 0);
    expect(controller.selectedStoryId, 'buttons/one');
    expect(controller.pick, isNotNull);
    await tester.pump(const Duration(seconds: 1)); // the sizes-save timer
  });

  testWidgets('option-click reaches the widget inside the mockup', (
    tester,
  ) async {
    controller.interact = true;
    await tester.pumpWidget(canvas());
    await tester.pumpAndSettle();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.pump();
    expect(controller.altHeld, isTrue);
    await tester.tap(find.text('Press me'));
    await tester.pumpAndSettle();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.pump();

    expect(taps, 1);
    expect(controller.selectedStoryId, 'buttons/one');
    expect(controller.pick, isNull);
    await tester.pump(const Duration(seconds: 1)); // the sizes-save timer
  });

  testWidgets('dragging pans the canvas only while Space is held', (
    tester,
  ) async {
    await tester.pumpWidget(canvas());
    await tester.pumpAndSettle();
    final viewer = tester.widget<InteractiveViewer>(
      find.byType(InteractiveViewer),
    );
    final transform = viewer.transformationController!;
    final before = transform.value.clone();

    await tester.drag(find.byType(InteractiveViewer), const Offset(80, 40));
    await tester.pumpAndSettle();
    expect(transform.value, before);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(controller.spaceHeld, isTrue);
    final canvasCursor = find.byKey(const Key('canvas-pan-cursor'));
    expect(
      tester.widget<MouseRegion>(canvasCursor).cursor,
      SystemMouseCursors.grab,
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(InteractiveViewer)),
    );
    await tester.pump();
    expect(
      tester.widget<MouseRegion>(canvasCursor).cursor,
      SystemMouseCursors.grabbing,
    );
    await gesture.up();
    await tester.pumpAndSettle();
    expect(
      tester.widget<MouseRegion>(canvasCursor).cursor,
      SystemMouseCursors.grab,
    );

    await tester.drag(find.byType(InteractiveViewer), const Offset(80, 40));
    await tester.pumpAndSettle();
    expect(transform.value, isNot(before));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(controller.spaceHeld, isFalse);
    await tester.pump(const Duration(seconds: 1)); // the sizes-save timer
  });

  test('moveCell rearranges screens between rows', () {
    controller.dispose();
    controller = StudioController(
      stories: const _LineStories(),
      project: Directory.current.path,
      port: 1,
    );

    List<String?> slots(int row) => [
      for (final cell in controller.slotsFor(controller.selectedPage!, row))
        cell?.cellId,
    ];

    expect(slots(0).whereType<String>(), ['welcome', 'signin']);
    expect(slots(1).whereType<String>(), ['home']);

    controller.moveCell(
      pageId: 'flows/onboarding',
      cellId: 'home',
      rowIndex: 0,
    );

    expect(slots(0).whereType<String>(), ['welcome', 'signin', 'home']);
    expect(slots(1).whereType<String>(), isEmpty);
    expect(slots(1), contains(null));

    controller.undoLayout();

    expect(slots(0).whereType<String>(), ['welcome', 'signin']);
    expect(slots(1).whereType<String>(), ['home']);
  });

  testWidgets('revealStory scrolls the card to the centre', (tester) async {
    controller.dispose();
    controller = StudioController(
      stories: const _LineStories(),
      project: Directory.current.path,
      port: 1,
    );
    await tester.pumpWidget(canvas());
    await tester.pumpAndSettle();
    final home = find.byWidgetPredicate(
      (w) => w is StoryCard && w.id == 'flows/onboarding/home/base',
    );
    final before = tester.getCenter(home);

    controller.revealStory('flows/onboarding/home/base');
    await tester.pumpAndSettle();

    expect(controller.selectedStoryId, 'flows/onboarding/home/base');
    // The slot (title, gap, card) is centred, so the card sits a little
    // below the middle of the 800x600 viewport.
    final after = tester.getCenter(home);
    expect(after, isNot(before));
    expect(after.dx, closeTo(400, 1));
    expect(after.dy, closeTo(300, 24));
    await tester.pump(const Duration(seconds: 1)); // the sizes-save timer
  });

  test('a click on an empty slot writes a cell into the storyline file', () {
    final project = Directory.systemTemp.createTempSync('studio_line');
    addTearDown(() => project.deleteSync(recursive: true));
    final file = File('${project.path}/story/lines/onboarding.dart')
      ..createSync(recursive: true)
      ..writeAsStringSync('''
import 'package:flutter/material.dart';
import 'package:flutter_static_story/flutter_static_story.dart';

Storyline storyline() => Storyline(
  'flows/onboarding',
  rows: [
    StorylineRow(
      'Top',
      cells: [
        Cell('welcome', variants: [Story('base', () => const Text('A'))]),
        Cell('signin', variants: [Story('base', () => const Text('B'))]),
      ],
    ),
    StorylineRow(
      'Bottom',
      cells: [
        Cell('home', variants: [Story('base', () => const Text('C'))]),
      ],
    ),
  ],
);
''');
    controller.dispose();
    controller = StudioController(
      stories: const _LineStories(),
      project: project.path,
      port: 1,
    );

    List<String?> slots(int row) => [
      for (final cell in controller.slotsFor(controller.selectedPage!, row))
        cell?.cellId,
    ];

    // The plus between welcome and signin: before signin in the file.
    controller.newCellBefore(
      pageId: 'flows/onboarding',
      rowIndex: 0,
      slotIndex: 2,
    );
    expect(slots(0).whereType<String>(), ['welcome', 'screen-4', 'signin']);
    var text = file.readAsStringSync();
    expect(
      text,
      contains('''
        Cell('welcome', variants: [Story('base', () => const Text('A'))]),
        Cell(
          'screen-4',
          title: 'Screen 4',
          variants: [Story('default', () => const Placeholder())],
        ),
        Cell('signin', variants: [Story('base', () => const Text('B'))]),
'''),
    );

    // The empty row under the last one: a new row in the file.
    controller.newCellAtSlot(
      pageId: 'flows/onboarding',
      rowIndex: 2,
      slotIndex: 1,
    );
    expect(slots(2).whereType<String>(), ['screen-4']);
    text = file.readAsStringSync();
    expect(text, contains("    StorylineRow(\n      'Row 3',\n"));
    expect(controller.logs.last, startsWith('Added screen-4'));
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
    await tester.tap(find.text('Press me'), warnIfMissed: false);
    await tester.pumpAndSettle();
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
