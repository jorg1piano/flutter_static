import 'package:flutter/material.dart';
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
}
