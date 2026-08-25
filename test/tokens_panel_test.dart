import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_static/src/studio/controller.dart';
import 'package:flutter_static/src/studio/tokens_panel.dart';
import 'package:flutter_static/src/tokens.dart';
import 'package:flutter_test/flutter_test.dart';

const _source = '''
abstract final class AppColors {
  static const primary = Color(0xFFFF0000);
}

abstract final class Space {
  static const md = 12.0;
}
''';

void main() {
  late Directory project;
  late StudioController controller;

  setUp(() {
    project = Directory.systemTemp.createTempSync('panel_test');
    File('${project.path}/pubspec.yaml').writeAsStringSync('name: app\n');
    Directory('${project.path}/lib').createSync();
    File('${project.path}/lib/tokens.dart').writeAsStringSync(_source);
    controller = StudioController(
      project: project.path,
      port: 1,
      packageRoot: project.path,
    )..loadTokens();
  });

  tearDown(() {
    controller.dispose();
    project.deleteSync(recursive: true);
  });

  Widget panel(String group) => MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 320,
        child: TokensPanel(
          group: controller.tokens!.groups.firstWhere((g) => g.name == group),
          controller: controller,
        ),
      ),
    ),
  );

  String source() => File('${project.path}/lib/tokens.dart').readAsStringSync();

  testWidgets('dragging the hue bar rewrites the colour', (tester) async {
    await tester.pumpWidget(panel('AppColors'));
    await tester.tap(find.text('primary'));
    await tester.pumpAndSettle();
    final hue = find.byWidgetPredicate(
      (w) => w.runtimeType.toString() == '_HueBar',
    );
    expect(hue, findsOneWidget);
    // Red sits at hue 0, the bar's left edge; a third of the way along is
    // green.
    final box = tester.getRect(hue);
    await tester.tapAt(Offset(box.left + box.width / 3, box.center.dy));
    await tester.pump(const Duration(milliseconds: 200));
    expect(source(), isNot(contains('Color(0xFFFF0000)')));
    final written = TokenSet.load(project.path).find('AppColors.primary')!;
    final color = Color(written.argb!);
    expect(color.g, greaterThan(color.r));
    expect(color.g, greaterThan(color.b));
  });

  testWidgets('the hex field rewrites the colour', (tester) async {
    await tester.pumpWidget(panel('AppColors'));
    await tester.tap(find.text('primary'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '#00FF00');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump(const Duration(milliseconds: 200));
    expect(source(), contains('static const primary = Color(0xFF00FF00);'));
  });

  testWidgets('a number field commits on submit', (tester) async {
    await tester.pumpWidget(panel('Space'));
    await tester.enterText(find.byType(TextField), '16');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(source(), contains('static const md = 16.0;'));
  });
}
