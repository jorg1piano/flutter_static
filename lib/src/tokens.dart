/// Design tokens as Dart source: discovery, parsing and write-back.
///
/// A token is a `static const` member of a class in a token file, and the
/// Dart file is the single source of truth. Nothing is registered at
/// runtime: the parser reads the source, Studio edits the source, and hot
/// reload carries the new value into every widget that uses it.
///
/// Token files are found by convention under `lib/` of the project and of
/// every path dependency: a file named `tokens.dart`, or any Dart file in a
/// directory named `tokens`.
///
/// ```dart
/// // packages/app_ui/lib/src/tokens/colors.dart
/// abstract final class AppColors {
///   /// Buttons, links, focus rings.
///   static const primary = Color(0xFF4F46E5);
/// }
/// ```
///
/// Recognised expressions: `Color(0xAARRGGBB)`, number literals,
/// `TextStyle(...)` (its `fontSize`, `fontWeight`, `height`,
/// `letterSpacing` and `fontFamily` arguments are editable one by one),
/// `BorderRadius.circular(n)` / `Radius.circular(n)`, and
/// `Duration(milliseconds: n)`. Anything else is listed read-only.
///
/// Pure Dart: the CLI imports this file directly.
library;

import 'dart:convert';
import 'dart:io';

enum TokenKind { color, number, text, radius, duration, other }

/// One `name: value` argument of a `TextStyle(...)` token, with the span
/// of the value in the file so it can be replaced on its own.
class TokenArg {
  const TokenArg(this.name, this.value, this.start, this.end);

  final String name;
  final String value;
  final int start;
  final int end;

  Map<String, Object?> toJson() => {'name': name, 'value': value};
}

class DesignToken {
  const DesignToken({
    required this.file,
    required this.group,
    required this.name,
    required this.kind,
    required this.source,
    required this.start,
    required this.end,
    required this.line,
    this.doc,
    this.argb,
    this.number,
    this.args = const [],
  });

  /// Absolute path of the file the token is declared in.
  final String file;

  /// The class the token is a member of.
  final String group;
  final String name;
  final TokenKind kind;

  /// The value expression as written, `Color(0xFF4F46E5)`.
  final String source;

  /// Span of [source] in the file.
  final int start;
  final int end;

  /// 1-based line of the declaration.
  final int line;

  /// The `///` comment above the declaration, joined with newlines.
  final String? doc;

  /// [TokenKind.color]: the 32-bit ARGB value.
  final int? argb;

  /// [TokenKind.number], [TokenKind.radius]: the value;
  /// [TokenKind.duration]: milliseconds.
  final double? number;

  /// [TokenKind.text]: the style's named arguments.
  final List<TokenArg> args;

  /// `Group.name`, unique within a project.
  String get id => '$group.$name';

  TokenArg? arg(String name) {
    for (final a in args) {
      if (a.name == name) return a;
    }
    return null;
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'group': group,
    'name': name,
    'kind': kind.name,
    'source': source,
    'file': file,
    'line': line,
    if (doc != null) 'doc': doc,
    if (argb != null) 'argb': argb,
    if (argb != null) 'hex': colorHex(argb!),
    if (number != null) 'number': number,
    if (args.isNotEmpty) 'args': [for (final a in args) a.toJson()],
  };
}

class TokenGroup {
  const TokenGroup({
    required this.name,
    required this.file,
    required this.tokens,
    this.doc,
  });

  final String name;
  final String file;
  final String? doc;
  final List<DesignToken> tokens;

  Map<String, Object?> toJson() => {
    'name': name,
    'file': file,
    if (doc != null) 'doc': doc,
    'tokens': [for (final t in tokens) t.toJson()],
  };
}

class TokenFile {
  const TokenFile(this.path, this.groups);

  final String path;
  final List<TokenGroup> groups;

  Iterable<DesignToken> get tokens => groups.expand((g) => g.tokens);

  /// Parses [source], the content of the file at [path].
  static TokenFile parse(String path, String source) {
    final groups = <TokenGroup>[];
    for (final m in _classHeader.allMatches(source)) {
      final open = source.indexOf('{', m.end);
      if (open == -1) continue;
      final close = _matchBrace(source, open);
      if (close == -1) continue;
      final tokens = _parseMembers(path, source, m.group(1)!, open + 1, close);
      if (tokens.isEmpty) continue;
      groups.add(
        TokenGroup(
          name: m.group(1)!,
          file: path,
          doc: _docAbove(source, m.start),
          tokens: tokens,
        ),
      );
    }
    return TokenFile(path, groups);
  }

  Map<String, Object?> toJson() => {
    'path': path,
    'groups': [for (final g in groups) g.toJson()],
  };
}

/// Every token file of a project, parsed.
class TokenSet {
  const TokenSet(this.root, this.files);

  final String root;
  final List<TokenFile> files;

  Iterable<TokenGroup> get groups => files.expand((f) => f.groups);
  Iterable<DesignToken> get tokens => files.expand((f) => f.tokens);

  DesignToken? find(String id) {
    for (final t in tokens) {
      if (t.id == id) return t;
    }
    return null;
  }

  static TokenSet load(String projectRoot) => TokenSet(projectRoot, [
    for (final path in discover(projectRoot))
      TokenFile.parse(path, File(path).readAsStringSync()),
  ]);

  /// Token files under `lib/` of [projectRoot] and of each of its path
  /// dependencies, sorted.
  static List<String> discover(String projectRoot) {
    final found = <String>{};
    for (final root in packageRoots(projectRoot)) {
      final lib = Directory('$root/lib');
      if (!lib.existsSync()) continue;
      for (final entity in lib.listSync(recursive: true, followLinks: false)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final rel = entity.path.substring(lib.path.length + 1);
        final segments = rel.split(Platform.pathSeparator);
        final dirs = segments.sublist(0, segments.length - 1);
        if (segments.last == 'tokens.dart' || dirs.contains('tokens')) {
          found.add(entity.path);
        }
      }
    }
    return found.toList()..sort();
  }

  /// [projectRoot] plus the roots of its path dependencies (one level:
  /// `packages/app_ui`), resolved to absolute paths.
  static List<String> packageRoots(String projectRoot) {
    final roots = <String>[projectRoot];
    final pubspec = File('$projectRoot/pubspec.yaml');
    if (!pubspec.existsSync()) return roots;
    final lines = pubspec.readAsLinesSync();
    for (var i = 0; i + 1 < lines.length; i++) {
      final dep = RegExp(r'^  \w+:\s*$').hasMatch(lines[i]);
      final path = RegExp(r'^    path:\s*(.+?)\s*$').firstMatch(lines[i + 1]);
      if (!dep || path == null) continue;
      var target = path.group(1)!;
      if (target.startsWith('"') || target.startsWith("'")) {
        target = target.substring(1, target.length - 1);
      }
      final absolute = target.startsWith('/')
          ? target
          : Uri.file(
              '$projectRoot/',
            ).resolve(target).toFilePath().replaceAll(RegExp(r'/$'), '');
      if (Directory(absolute).existsSync() && !roots.contains(absolute)) {
        roots.add(absolute);
      }
    }
    return roots;
  }

  Map<String, Object?> toJson() => {
    'root': root,
    'files': [for (final f in files) f.toJson()],
  };
}

/// Replaces [token]'s value expression with [expression] in its file and
/// returns the token re-parsed from the new content. The file is re-read
/// first, so an edit made elsewhere since [token] was parsed is kept.
DesignToken writeToken(DesignToken token, String expression) {
  final file = File(token.file);
  final current = TokenFile.parse(token.file, file.readAsStringSync());
  final fresh = current.tokens.where((t) => t.id == token.id).firstOrNull;
  if (fresh == null) {
    throw StateError('${token.id} no longer declared in ${token.file}');
  }
  final source = file.readAsStringSync();
  final updated =
      source.substring(0, fresh.start) +
      expression +
      source.substring(fresh.end);
  file.writeAsStringSync(updated);
  final parsed = TokenFile.parse(token.file, updated);
  return parsed.tokens.firstWhere((t) => t.id == token.id);
}

/// Replaces one named argument of a `TextStyle(...)` token. A missing
/// argument is appended before the closing parenthesis.
DesignToken writeTokenArg(DesignToken token, String arg, String value) {
  final file = File(token.file);
  final source = file.readAsStringSync();
  final fresh = TokenFile.parse(
    token.file,
    source,
  ).tokens.where((t) => t.id == token.id).firstOrNull;
  if (fresh == null) {
    throw StateError('${token.id} no longer declared in ${token.file}');
  }
  final existing = fresh.arg(arg);
  final String updated;
  if (existing != null) {
    updated =
        source.substring(0, existing.start) +
        value +
        source.substring(existing.end);
  } else {
    // Insert `, arg: value` before the `)` that closes the constructor.
    final close = source.lastIndexOf(')', fresh.end);
    var head = source.substring(0, close).trimRight();
    if (!head.endsWith('(') && !head.endsWith(',')) head += ',';
    updated = '$head $arg: $value${source.substring(close)}';
  }
  file.writeAsStringSync(updated);
  return TokenFile.parse(
    token.file,
    updated,
  ).tokens.firstWhere((t) => t.id == token.id);
}

/// `Color(0xFF4F46E5)` for an ARGB value.
String colorSource(int argb) =>
    'Color(0x${argb.toRadixString(16).toUpperCase().padLeft(8, '0')})';

/// `#4F46E5` for an opaque colour, `#804F46E5` (alpha first) otherwise.
String colorHex(int argb) {
  final hex = argb.toRadixString(16).toUpperCase().padLeft(8, '0');
  return '#${hex.startsWith('FF') ? hex.substring(2) : hex}';
}

/// Parses `#RGB`, `#RRGGBB`, `#AARRGGBB` or `0xAARRGGBB`; null when it is
/// none of those.
int? parseColorHex(String text) {
  var s = text.trim();
  if (s.startsWith('#')) s = s.substring(1);
  if (s.startsWith('0x') || s.startsWith('0X')) s = s.substring(2);
  if (!RegExp(r'^[0-9a-fA-F]+$').hasMatch(s)) return null;
  switch (s.length) {
    case 3:
      s = 'FF${s[0]}${s[0]}${s[1]}${s[1]}${s[2]}${s[2]}';
    case 6:
      s = 'FF$s';
    case 8:
      break;
    default:
      return null;
  }
  return int.parse(s, radix: 16);
}

/// A number literal in the style of [like]: `12.0` stays a double literal,
/// `12` stays an int when the value is whole.
String numberSource(double value, {String? like}) {
  final wantsDecimal = like != null && like.contains('.');
  if (value == value.roundToDouble() && !wantsDecimal) {
    return value.toInt().toString();
  }
  var s = value.toStringAsFixed(3);
  s = s.replaceAll(RegExp(r'0+$'), '');
  if (s.endsWith('.')) s += '0';
  return s;
}

/// The value expression for a [DesignToken] of the same kind as [token]
/// holding [number]: bare for numbers, wrapped for radii and durations.
String numberSourceFor(DesignToken token, double number) {
  switch (token.kind) {
    case TokenKind.radius:
      final ctor = token.source.startsWith('Radius')
          ? 'Radius.circular'
          : 'BorderRadius.circular';
      final inner = _radius.firstMatch(token.source)?.group(1);
      return '$ctor(${numberSource(number, like: inner)})';
    case TokenKind.duration:
      return 'Duration(milliseconds: ${number.round()})';
    default:
      return numberSource(number, like: token.source);
  }
}

String tokensJson(TokenSet set) =>
    const JsonEncoder.withIndent('  ').convert(set.toJson());

// --- parsing -------------------------------------------------------------

final _classHeader = RegExp(
  r'^(?:abstract\s+|final\s+|base\s+|interface\s+|sealed\s+|mixin\s+)*class\s+(\w+)',
  multiLine: true,
);

final _member = RegExp(r'static\s+const\s+(?:[\w<>?,\s]+?\s+)?(\w+)\s*=\s*');

/// Index of the `}` matching the `{` at [open], skipping strings and
/// comments; -1 when unbalanced.
int _matchBrace(String s, int open) {
  var depth = 0;
  var i = open;
  while (i < s.length) {
    final c = s[i];
    if (c == '/' && i + 1 < s.length && s[i + 1] == '/') {
      i = s.indexOf('\n', i);
      if (i == -1) return -1;
      continue;
    }
    if (c == '/' && i + 1 < s.length && s[i + 1] == '*') {
      i = s.indexOf('*/', i);
      if (i == -1) return -1;
      i += 2;
      continue;
    }
    if (c == "'" || c == '"') {
      i = _skipString(s, i);
      if (i == -1) return -1;
      continue;
    }
    if (c == '{') depth++;
    if (c == '}') {
      depth--;
      if (depth == 0) return i;
    }
    i++;
  }
  return -1;
}

/// Index just past the string literal starting at [start] (a quote).
int _skipString(String s, int start) {
  final quote = s[start];
  final triple = s.startsWith(quote * 3, start);
  var i = start + (triple ? 3 : 1);
  while (i < s.length) {
    if (s[i] == r'\') {
      i += 2;
      continue;
    }
    if (triple ? s.startsWith(quote * 3, i) : s[i] == quote) {
      return i + (triple ? 3 : 1);
    }
    i++;
  }
  return -1;
}

/// Index of the `;` that ends the expression starting at [start], at
/// bracket depth zero; -1 when none.
int _expressionEnd(String s, int start) {
  var depth = 0;
  var i = start;
  while (i < s.length) {
    final c = s[i];
    if (c == "'" || c == '"') {
      i = _skipString(s, i);
      if (i == -1) return -1;
      continue;
    }
    if (c == '(' || c == '[' || c == '{') depth++;
    if (c == ')' || c == ']' || c == '}') depth--;
    if (c == ';' && depth == 0) return i;
    if (depth < 0) return -1;
    i++;
  }
  return -1;
}

List<DesignToken> _parseMembers(
  String path,
  String source,
  String group,
  int bodyStart,
  int bodyEnd,
) {
  final tokens = <DesignToken>[];
  final body = source.substring(bodyStart, bodyEnd);
  for (final m in _member.allMatches(body)) {
    final exprStart = bodyStart + m.end;
    final semi = _expressionEnd(source, exprStart);
    if (semi == -1) continue;
    var exprEnd = semi;
    while (exprEnd > exprStart && _isSpace(source[exprEnd - 1])) {
      exprEnd--;
    }
    final expr = source.substring(exprStart, exprEnd);
    final declStart = bodyStart + m.start;
    tokens.add(
      _classify(
        file: path,
        group: group,
        name: m.group(1)!,
        source: expr,
        start: exprStart,
        end: exprEnd,
        line: _lineOf(source, declStart),
        doc: _docAbove(source, declStart),
      ),
    );
  }
  return tokens;
}

bool _isSpace(String c) => c == ' ' || c == '\n' || c == '\t' || c == '\r';

int _lineOf(String source, int offset) {
  var line = 1;
  for (var i = 0; i < offset && i < source.length; i++) {
    if (source[i] == '\n') line++;
  }
  return line;
}

/// The `///` lines directly above the declaration at [offset].
String? _docAbove(String source, int offset) {
  final lineStart = offset == 0 ? 0 : source.lastIndexOf('\n', offset - 1) + 1;
  final lines = <String>[];
  var end = lineStart;
  while (end > 1) {
    final start = source.lastIndexOf('\n', end - 2) + 1;
    final line = source.substring(start, end - 1).trim();
    if (!line.startsWith('///')) break;
    lines.insert(0, line.substring(3).trim());
    end = start;
  }
  return lines.isEmpty ? null : lines.join('\n');
}

final _color = RegExp(
  r'^(?:const\s+)?Color\(\s*0[xX]([0-9a-fA-F]{8})\s*,?\s*\)$',
);
final _number = RegExp(r'^-?\d+(?:\.\d+)?$');
final _radius = RegExp(
  r'^(?:const\s+)?(?:BorderRadius|Radius)\.circular\(\s*(-?\d+(?:\.\d+)?)\s*\)$',
);
final _duration = RegExp(
  r'^(?:const\s+)?Duration\(\s*milliseconds:\s*(\d+)\s*,?\s*\)$',
);
final _textStyle = RegExp(r'^(?:const\s+)?TextStyle\(');

DesignToken _classify({
  required String file,
  required String group,
  required String name,
  required String source,
  required int start,
  required int end,
  required int line,
  String? doc,
}) {
  DesignToken token(
    TokenKind kind, {
    int? argb,
    double? number,
    List<TokenArg> args = const [],
  }) => DesignToken(
    file: file,
    group: group,
    name: name,
    kind: kind,
    source: source,
    start: start,
    end: end,
    line: line,
    doc: doc,
    argb: argb,
    number: number,
    args: args,
  );

  final color = _color.firstMatch(source);
  if (color != null) {
    return token(TokenKind.color, argb: int.parse(color.group(1)!, radix: 16));
  }
  if (_number.hasMatch(source)) {
    return token(TokenKind.number, number: double.parse(source));
  }
  final radius = _radius.firstMatch(source);
  if (radius != null) {
    return token(TokenKind.radius, number: double.parse(radius.group(1)!));
  }
  final duration = _duration.firstMatch(source);
  if (duration != null) {
    return token(TokenKind.duration, number: double.parse(duration.group(1)!));
  }
  if (_textStyle.hasMatch(source)) {
    return token(TokenKind.text, args: _namedArgs(source, start));
  }
  return token(TokenKind.other);
}

/// The top-level `name: value` arguments of the constructor call in
/// [source], value spans offset by [base] into the file.
List<TokenArg> _namedArgs(String source, int base) {
  final open = source.indexOf('(');
  if (open == -1) return const [];
  final args = <TokenArg>[];
  var i = open + 1;
  var depth = 0;
  var argStart = i;
  void flush(int argEnd) {
    final text = source.substring(argStart, argEnd);
    final m = RegExp(r'^\s*(\w+)\s*:\s*').firstMatch(text);
    if (m == null) return;
    var valueEnd = argEnd;
    while (valueEnd > argStart + m.end && _isSpace(source[valueEnd - 1])) {
      valueEnd--;
    }
    final valueStart = argStart + m.end;
    args.add(
      TokenArg(
        m.group(1)!,
        source.substring(valueStart, valueEnd),
        base + valueStart,
        base + valueEnd,
      ),
    );
  }

  while (i < source.length) {
    final c = source[i];
    if (c == "'" || c == '"') {
      i = _skipString(source, i);
      if (i == -1) return args;
      continue;
    }
    if (c == '(' || c == '[' || c == '{') depth++;
    if (c == ')' || c == ']' || c == '}') {
      if (depth == 0) {
        flush(i);
        break;
      }
      depth--;
    }
    if (c == ',' && depth == 0) {
      flush(i);
      argStart = i + 1;
    }
    i++;
  }
  return args;
}
