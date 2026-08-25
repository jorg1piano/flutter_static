import 'dart:io';

import 'package:flutter_static/src/tokens.dart';
import 'package:flutter_test/flutter_test.dart';

const _sample = '''
import 'package:flutter/painting.dart';

/// Brand palette.
abstract final class AppColors {
  /// Buttons, links, focus rings.
  static const primary = Color(0xFF4F46E5);
  static const scrim = Color(0x80000000);
}

abstract final class Space {
  static const xs = 4.0;
  static const sm = 8;
}

abstract final class Radii {
  static const card = BorderRadius.circular(16);
}

abstract final class Motion {
  static const fast = Duration(milliseconds: 120);
}

abstract final class AppText {
  static const title = TextStyle(
    fontSize: 24,
    fontWeight: FontWeight.w700,
    fontFamily: 'Inter',
  );
  static const body = TextStyle(fontSize: 14, height: 1.43);
  static const List<String> names = ['a', 'b}'];
}
''';

void main() {
  late Directory dir;
  late String path;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('tokens_test');
    path = '${dir.path}/tokens.dart';
    File(path).writeAsStringSync(_sample);
  });

  tearDown(() => dir.deleteSync(recursive: true));

  test('parses groups, kinds, values and docs', () {
    final file = TokenFile.parse(path, _sample);
    expect(file.groups.map((g) => g.name), [
      'AppColors',
      'Space',
      'Radii',
      'Motion',
      'AppText',
    ]);
    expect(file.groups.first.doc, 'Brand palette.');
    final primary = file.tokens.firstWhere((t) => t.id == 'AppColors.primary');
    expect(primary.kind, TokenKind.color);
    expect(primary.argb, 0xFF4F46E5);
    expect(primary.doc, 'Buttons, links, focus rings.');
    expect(primary.line, 6);
    expect(file.tokens.firstWhere((t) => t.id == 'Space.sm').number, 8);
    expect(
      file.tokens.firstWhere((t) => t.id == 'Radii.card').kind,
      TokenKind.radius,
    );
    expect(file.tokens.firstWhere((t) => t.id == 'Motion.fast').number, 120);
    final title = file.tokens.firstWhere((t) => t.id == 'AppText.title');
    expect(title.kind, TokenKind.text);
    expect(title.arg('fontWeight')?.value, 'FontWeight.w700');
    expect(title.arg('fontFamily')?.value, "'Inter'");
    expect(
      file.tokens.firstWhere((t) => t.id == 'AppText.names').kind,
      TokenKind.other,
    );
  });

  test('writes replace only the expression and keep literal style', () {
    final file = TokenFile.parse(path, _sample);
    writeToken(
      file.tokens.firstWhere((t) => t.id == 'AppColors.primary'),
      colorSource(0xFF00FF00),
    );
    final sm = file.tokens.firstWhere((t) => t.id == 'Space.sm');
    writeToken(sm, numberSourceFor(sm, 10));
    final xs = file.tokens.firstWhere((t) => t.id == 'Space.xs');
    writeToken(xs, numberSourceFor(xs, 6));
    final card = file.tokens.firstWhere((t) => t.id == 'Radii.card');
    writeToken(card, numberSourceFor(card, 20));
    final source = File(path).readAsStringSync();
    expect(source, contains('static const primary = Color(0xFF00FF00);'));
    expect(source, contains('static const sm = 10;'));
    expect(source, contains('static const xs = 6.0;'));
    expect(source, contains('static const card = BorderRadius.circular(20);'));
    expect(source, contains('/// Buttons, links, focus rings.'));
  });

  test('text style arguments replace in place or append', () {
    final file = TokenFile.parse(path, _sample);
    final body = file.tokens.firstWhere((t) => t.id == 'AppText.body');
    final after = writeTokenArg(body, 'fontSize', '16');
    final again = writeTokenArg(after, 'fontWeight', 'FontWeight.w500');
    expect(
      again.source,
      'TextStyle(fontSize: 16, height: 1.43, fontWeight: FontWeight.w500)',
    );
    final title = TokenFile.parse(
      path,
      File(path).readAsStringSync(),
    ).tokens.firstWhere((t) => t.id == 'AppText.title');
    expect(writeTokenArg(title, 'fontSize', '28').arg('fontSize')?.value, '28');
  });

  test('discovers token files in the project and path dependencies', () {
    final project = Directory('${dir.path}/app')..createSync();
    File('${project.path}/pubspec.yaml').writeAsStringSync(
      'name: app\ndependencies:\n  ui:\n    path: packages/ui\n  flutter:\n    sdk: flutter\n',
    );
    Directory('${project.path}/lib/theme').createSync(recursive: true);
    File('${project.path}/lib/theme/tokens.dart').writeAsStringSync(_sample);
    Directory(
      '${project.path}/packages/ui/lib/src/tokens',
    ).createSync(recursive: true);
    File(
      '${project.path}/packages/ui/lib/src/tokens/colors.dart',
    ).writeAsStringSync(_sample);
    File(
      '${project.path}/packages/ui/lib/src/button.dart',
    ).writeAsStringSync('');
    final found = TokenSet.discover(project.path);
    expect(found.map((f) => f.split('/').last).toList()..sort(), [
      'colors.dart',
      'tokens.dart',
    ]);
    expect(TokenSet.load(project.path).find('Space.sm')?.number, 8);
  });

  test('colour helpers', () {
    expect(colorHex(0xFF4F46E5), '#4F46E5');
    expect(colorHex(0x804F46E5), '#804F46E5');
    expect(parseColorHex('#abc'), 0xFFAABBCC);
    expect(parseColorHex('4F46E5'), 0xFF4F46E5);
    expect(parseColorHex('0x804F46E5'), 0x804F46E5);
    expect(parseColorHex('nope'), isNull);
  });
}
