/// Small, literal-minded edits to story source: a cell into a storyline
/// row, a story into a page file. Text only, no analyzer: the files
/// Studio scaffolds and the ones people write by hand are regular enough
/// that bracket matching, skipping strings and comments, finds the list
/// to extend. Anything stranger (rows built by a helper, a row that is a
/// `for` element) fails with a message instead of guessing.
library;

/// A list literal in [text]: its `[` at [open], its `]` at [close].
class SourceList {
  const SourceList(this.text, this.open, this.close);

  final String text;
  final int open;
  final int close;

  /// Start and end of each top-level element, whitespace trimmed. A
  /// `for` or `if` element counts as one, whatever it yields. A comment
  /// ahead of an element belongs to it, so inserting before the element
  /// keeps them together; see [codeStart] for where its code begins.
  List<(int, int)> get elements {
    final out = <(int, int)>[];
    var start = open + 1;
    var i = open + 1;
    while (i < close) {
      final skipped = _skipStringOrComment(text, i);
      if (skipped != null) {
        i = skipped;
        continue;
      }
      final c = text[i];
      if (c == '(' || c == '[' || c == '{') {
        i = (matchBracket(text, i) ?? close) + 1;
        continue;
      }
      if (c == ',') {
        _addElement(out, start, i);
        start = i + 1;
      }
      i++;
    }
    _addElement(out, start, close);
    return out;
  }

  void _addElement(List<(int, int)> out, int start, int end) {
    while (start < end && _isSpace(text[start])) {
      start++;
    }
    while (end > start && _isSpace(text[end - 1])) {
      end--;
    }
    if (end > start) out.add((start, end));
  }
}

/// The index of the bracket closing the one at [open], or null when the
/// text runs out first.
int? matchBracket(String text, int open) {
  const pairs = {'(': ')', '[': ']', '{': '}'};
  final stack = <String>[];
  var i = open;
  while (i < text.length) {
    final skipped = _skipStringOrComment(text, i);
    if (skipped != null) {
      i = skipped;
      continue;
    }
    final c = text[i];
    if (pairs.containsKey(c)) {
      stack.add(pairs[c]!);
    } else if (c == ')' || c == ']' || c == '}') {
      if (stack.isEmpty || stack.removeLast() != c) return null;
      if (stack.isEmpty) return i;
    }
    i++;
  }
  return null;
}

/// The list literal that follows [label] (`rows:`, `cells:`) at or after
/// [from], and before [before] if given.
SourceList? listAfter(
  String text,
  String label, {
  required int from,
  int? before,
}) {
  final at = text.indexOf(label, from);
  if (at < 0 || (before != null && at > before)) return null;
  var open = at + label.length;
  while (open < text.length && _isSpace(text[open])) {
    open++;
  }
  if (open >= text.length || text[open] != '[') return null;
  final close = matchBracket(text, open);
  if (close == null) return null;
  return SourceList(text, open, close);
}

/// [text] with [element] added to [list] as its last element, on its
/// own lines, indented like the closing bracket plus two.
String appendElement(String text, SourceList list, String element) {
  final inner = text.substring(list.open + 1, list.close);
  final kept = inner.trimRight();
  final comma = kept.isNotEmpty && !kept.endsWith(',') ? ',' : '';
  final closeIndent = _lineIsBlankBefore(text, list.close)
      ? _indentOf(text, list.close)
      : _indentOf(text, list.open);
  final indent = '$closeIndent  ';
  final body = element.split('\n').map((l) => '$indent$l').join('\n');
  return text.replaceRange(
    list.open + 1 + kept.length,
    list.close,
    '$comma\n$body,\n$closeIndent',
  );
}

/// [text] with [element] inserted before the element starting at [at],
/// on its own lines at the same indentation.
String insertElementBefore(String text, int at, String element) {
  if (!_lineIsBlankBefore(text, at)) {
    return text.replaceRange(at, at, '${element.replaceAll('\n', ' ')}, ');
  }
  final indent = _indentOf(text, at);
  final body = element.replaceAll('\n', '\n$indent');
  return text.replaceRange(at, at, '$body,\n$indent');
}

/// The source of a new cell with one placeholder variant.
String cellSource(String id, String title) =>
    "Cell(\n"
    "  '$id',\n"
    "  title: '$title',\n"
    "  variants: [Story('default', () => const Placeholder())],\n"
    ")";

/// The source of a new row holding one new cell.
String rowSource(String title, String cellId, String cellTitle) {
  final cell = cellSource(cellId, cellTitle).replaceAll('\n', '\n    ');
  return "StorylineRow(\n"
      "  '$title',\n"
      "  cells: [\n"
      "    $cell,\n"
      "  ],\n"
      ")";
}

/// [text] with a placeholder cell added to row [rowIndex] of the
/// storyline [lineId]. Goes before the row's [beforeCell]th cell when
/// that is given and the row's `cells:` list has one element per cell
/// ([cellCount]); at the row's end otherwise. A [rowIndex] past the last
/// row adds a row.
///
/// Throws a [FormatException] naming what it could not find.
String addStorylineCell(
  String text, {
  required String lineId,
  required int rowIndex,
  required String cellId,
  required String title,
  int? beforeCell,
  int cellCount = 0,
  String rowTitle = 'New row',
}) {
  final head = RegExp(
    "Storyline\\(\\s*(['\"])${RegExp.escape(lineId)}\\1",
  ).firstMatch(text);
  if (head == null) throw FormatException("no Storyline('$lineId') here");
  final rows = listAfter(text, 'rows:', from: head.end);
  if (rows == null) throw FormatException('no rows: [...] for $lineId');
  final rowElements = rows.elements;
  if (rowIndex >= rowElements.length) {
    return appendElement(text, rows, rowSource(rowTitle, cellId, title));
  }
  final (rowStart, rowEnd) = rowElements[rowIndex];
  if (!text.startsWith('StorylineRow(', codeStart(text, rowStart))) {
    throw FormatException(
      'row ${rowIndex + 1} of $lineId is not a StorylineRow literal',
    );
  }
  final cells = listAfter(text, 'cells:', from: rowStart, before: rowEnd);
  if (cells == null) {
    throw FormatException('no cells: [...] in row ${rowIndex + 1} of $lineId');
  }
  final cellElements = cells.elements;
  final cell = cellSource(cellId, title);
  if (beforeCell != null &&
      cellElements.length == cellCount &&
      beforeCell < cellElements.length) {
    return insertElementBefore(text, cellElements[beforeCell].$1, cell);
  }
  return appendElement(text, cells, cell);
}

/// [text] with a placeholder story appended to its top-level
/// `stories() => [...]`.
String addPageStory(String text, {required String storyId}) {
  final head = RegExp(r'stories\(\)\s*=>\s*\[').firstMatch(text);
  if (head == null) throw const FormatException('no stories() => [...] here');
  final open = head.end - 1;
  final close = matchBracket(text, open);
  if (close == null) throw const FormatException('stories() list unbalanced');
  return appendElement(
    text,
    SourceList(text, open, close),
    "Story('$storyId', () => const Placeholder())",
  );
}

/// [text] importing something that defines `Placeholder`.
String ensureWidgetsImport(String text) {
  if (RegExp(
    r"^import 'package:flutter/(widgets|material|cupertino)\.dart';",
    multiLine: true,
  ).hasMatch(text)) {
    return text;
  }
  const line = "import 'package:flutter/widgets.dart';\n";
  final firstPackage = RegExp(
    r"^import 'package:",
    multiLine: true,
  ).firstMatch(text);
  final first =
      firstPackage ?? RegExp(r'^import ', multiLine: true).firstMatch(text);
  if (first == null) return '$line\n$text';
  return text.replaceRange(first.start, first.start, line);
}

/// The first index at or after [index] that is neither whitespace nor
/// inside a comment.
int codeStart(String text, int index) {
  var i = index;
  while (i < text.length) {
    if (_isSpace(text[i])) {
      i++;
      continue;
    }
    if (text.startsWith('//', i) || text.startsWith('/*', i)) {
      i = _skipStringOrComment(text, i)!;
      continue;
    }
    return i;
  }
  return i;
}

bool _isSpace(String c) => c == ' ' || c == '\n' || c == '\t' || c == '\r';

/// Leading whitespace of the line holding [index].
String _indentOf(String text, int index) {
  final lineStart = text.lastIndexOf('\n', index - 1) + 1;
  var end = lineStart;
  while (end < text.length && (text[end] == ' ' || text[end] == '\t')) {
    end++;
  }
  return text.substring(lineStart, end);
}

/// Whether only whitespace sits between the line start and [index].
bool _lineIsBlankBefore(String text, int index) {
  final lineStart = text.lastIndexOf('\n', index - 1) + 1;
  return text.substring(lineStart, index).trim().isEmpty;
}

/// The index just past a string literal or comment starting at [i], or
/// null when [i] starts neither. Raw and triple-quoted strings are
/// handled; a string inside `${...}` of another string is not.
int? _skipStringOrComment(String text, int i) {
  if (text.startsWith('//', i)) {
    final end = text.indexOf('\n', i);
    return end < 0 ? text.length : end;
  }
  if (text.startsWith('/*', i)) {
    var depth = 0;
    var j = i;
    while (j < text.length) {
      if (text.startsWith('/*', j)) {
        depth++;
        j += 2;
      } else if (text.startsWith('*/', j)) {
        depth--;
        j += 2;
        if (depth == 0) return j;
      } else {
        j++;
      }
    }
    return text.length;
  }
  var j = i;
  var raw = false;
  if (text[j] == 'r' && j + 1 < text.length) {
    final q = text[j + 1];
    if (q == "'" || q == '"') {
      raw = true;
      j++;
    }
  }
  final q = text[j];
  if (q != "'" && q != '"') return null;
  final triple = text.startsWith(q * 3, j);
  final quote = triple ? q * 3 : q;
  j += quote.length;
  while (j < text.length) {
    if (!raw && text[j] == r'\') {
      j += 2;
      continue;
    }
    if (text.startsWith(quote, j)) return j + quote.length;
    j++;
  }
  return text.length;
}
