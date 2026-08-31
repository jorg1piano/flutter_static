import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_static/src/story.dart';
import 'package:flutter_static/src/studio/controller.dart';
import 'package:flutter_static/src/studio/search.dart';
import 'package:flutter_test/flutter_test.dart';

class _Stories extends Stories {
  const _Stories();

  @override
  List<Story> build() => [
    Story('buttons/primary', () => const Text('P')),
    Story('buttons/ghost', () => const Text('G')),
  ];

  @override
  List<Storyline> storylines() => [
    Storyline(
      'flows/onboarding',
      title: 'Onboarding',
      rows: [
        StorylineRow(
          'Top',
          cells: [
            Cell(
              'welcome',
              title: 'Welcome',
              variants: [Story('base', () => const Text('A'))],
            ),
            Cell(
              'signin',
              title: 'Sign in',
              variants: [
                Story('base', () => const Text('B')),
                Story('error', () => const Text('B!')),
              ],
            ),
          ],
        ),
      ],
    ),
  ];
}

void main() {
  late StudioController controller;

  setUp(() {
    controller = StudioController(
      stories: const _Stories(),
      project: '/nonexistent',
      port: 1,
    );
  });

  tearDown(() => controller.dispose());

  test('items: pages, screens, stories with more than one variant', () {
    final items = searchItems(controller);
    String row(SearchItem i) => '${i.kindLabel} ${i.title} -> ${i.target}';
    expect(items.map(row), [
      'page Onboarding -> flows/onboarding',
      'page buttons -> buttons',
      'screen Welcome -> flows/onboarding/welcome/base',
      'screen Sign in -> flows/onboarding/signin/base',
      'story Sign in · base -> flows/onboarding/signin/base',
      'story Sign in · error -> flows/onboarding/signin/error',
      'story primary -> buttons/primary',
      'story ghost -> buttons/ghost',
    ]);
  });

  test('ranking: every word must match, title matches come first', () {
    final items = searchItems(controller);
    expect(rankSearch(items, '').length, items.length);
    expect(rankSearch(items, 'sign').map((i) => i.id).toList(), [
      'flows/onboarding/signin',
      'flows/onboarding/signin/base',
      'flows/onboarding/signin/error',
    ]);
    expect(
      rankSearch(items, 'sign error').single.id,
      'flows/onboarding/signin/error',
    );
    // "buttons" is only in the id of the stories, in the title of the page.
    expect(rankSearch(items, 'buttons').first.kind, SearchKind.page);
    expect(rankSearch(items, 'nothing here'), isEmpty);
  });

  testWidgets('typing, arrows and Enter select and reveal a story', (
    tester,
  ) async {
    var closed = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: StudioSearch(
              controller: controller,
              onClose: () => closed++,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'sign');
    await tester.pump();
    expect(find.text('Sign in · error'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(closed, 1);
    expect(controller.selectedPageId, 'flows/onboarding');
    expect(controller.selectedStoryId, 'flows/onboarding/signin/error');
    expect(controller.revealSlotId, 'flows/onboarding/signin/error');
    expect(controller.revealTick, 1);
  });

  testWidgets('the preview follows the highlight after it settles', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: StudioSearch(controller: controller, onClose: () {}),
          ),
        ),
      ),
    );
    await tester.pump();
    // The first hit previews straight away.
    var preview = tester.widget<SearchPreview>(find.byType(SearchPreview));
    expect(preview.item.id, 'flows/onboarding');

    await tester.enterText(find.byType(TextField), 'sign');
    await tester.pump();
    // Still the old one: the highlight has not settled.
    preview = tester.widget<SearchPreview>(find.byType(SearchPreview));
    expect(preview.item.id, 'flows/onboarding');
    await tester.pump(const Duration(milliseconds: 200));
    preview = tester.widget<SearchPreview>(find.byType(SearchPreview));
    expect(preview.item.id, 'flows/onboarding/signin');
    expect(preview.item.previewStory, 'flows/onboarding/signin/base');

    // Arrowing past a row does not leave its preview behind.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump(const Duration(milliseconds: 200));
    preview = tester.widget<SearchPreview>(find.byType(SearchPreview));
    expect(preview.item.id, 'flows/onboarding/signin/error');
    // The previews' captures land and schedule the sizes save; wait
    // both out so no timer outlives the test.
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('a narrow window drops the preview, not the list', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(700, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: StudioSearch(controller: controller, onClose: () {}),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(SearchPreview), findsNothing);
    expect(find.text('Onboarding'), findsWidgets);
  });

  test('revealStory on a plain page targets the cell slot', () {
    controller.revealStory('buttons/ghost');
    expect(controller.selectedPageId, 'buttons');
    expect(controller.selectedStoryId, 'buttons/ghost');
    expect(controller.revealSlotId, 'buttons/ghost');
  });
}
