import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_static/src/widget_pick.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  // `flutter test` runs in the package root; this file is under test/,
  // so its widgets count as the project's.
  final scopes = SourceScopes(Directory.current.path);

  /// The source line a location points at, so the test needs no
  /// hard-coded line numbers.
  String lineAt(SourceLocation location) =>
      File(location.file).readAsLinesSync()[location.line - 1];

  final root = GlobalKey();
  Widget subject() => Directionality(
    textDirection: TextDirection.ltr,
    child: Center(
      child: RepaintBoundary(
        key: root,
        child: Container(
          width: 200,
          height: 100,
          color: const Color(0xFFFF0000),
          alignment: Alignment.center,
          child: const Text('Hello'),
        ),
      ),
    ),
  );

  testWidgets('a point maps to the widgets that made it, with their lines', (
    tester,
  ) async {
    await tester.pumpWidget(subject());
    final render = root.currentContext!.findRenderObject()!;
    final pick = pickWidgetAt(render, const Offset(100, 50), scopes)!;

    final types = pick.chain.map((w) => w.type).toList();
    // Nearest first: the RichText that Text builds, then Text, then the
    // Container and what it builds, and nothing above the root.
    expect(types.first, 'RichText');
    expect(types, containsAllInOrder(['Text', 'Container']));
    expect(types, isNot(contains('RepaintBoundary')));
    expect(types, isNot(contains('Center')));

    final text = pick.chain.firstWhere((w) => w.type == 'Text');
    expect(text.text, 'Hello');
    expect(text.scope, SourceScope.project);
    expect(p.basename(text.location!.file), 'widget_pick_test.dart');
    expect(lineAt(text.location!), contains("Text('Hello')"));

    final container = pick.chain.firstWhere((w) => w.type == 'Container');
    expect(lineAt(container.location!), contains('Container('));
    expect(container.bounds, const Rect.fromLTWH(0, 0, 200, 100));

    expect(pick.chain.first.scope, SourceScope.framework);
    expect(pick.local.map((w) => w.type), ['Text', 'Container']);
    expect(pick.chain[pick.localIndex].type, 'Text');
    expect(scopes.describe(text.location!), startsWith('test/'));

    // Outside the render: nothing.
    expect(pickWidgetAt(render, const Offset(-10, -10), scopes), isNull);
  });

  testWidgets('the tree lists the project\'s widgets, nested, in PNG pixels', (
    tester,
  ) async {
    await tester.pumpWidget(subject());
    final render = root.currentContext!.findRenderObject()!;
    final tree = widgetTreeJson(render, scopes, scale: 2);
    expect(tree, hasLength(1));
    final container = tree.single;
    expect(container['widget'], 'Container');
    expect(container['bounds'], [0, 0, 400, 200]);
    expect(container['file'], 'test/widget_pick_test.dart');
    final children = container['children'] as List;
    expect(children, hasLength(1));
    final text = children.single as Map;
    expect(text['widget'], 'Text');
    expect(text['text'], 'Hello');
    expect(text['scope'], 'project');
    expect(text['children'], isEmpty);
  });

  test('scopes: story/, the project and its packages, the framework', () {
    final s = SourceScopes('/p', packageRoots: ['/p', '/p/packages/ui']);
    expect(s.of('/p/story/stories/a.dart'), SourceScope.story);
    expect(s.of('/p/lib/a.dart'), SourceScope.project);
    expect(s.of('/p/packages/ui/lib/x.dart'), SourceScope.project);
    expect(
      s.of('/sdk/packages/flutter/lib/src/widgets/text.dart'),
      SourceScope.framework,
    );
    expect(s.of('/elsewhere/lib/x.dart'), SourceScope.other);
    expect(
      s.describe(const SourceLocation('/p/story/a.dart', 3, 4)),
      'story/a.dart:3:4',
    );
    expect(s.display('/elsewhere/lib/x.dart'), '/elsewhere/lib/x.dart');
  });
}
