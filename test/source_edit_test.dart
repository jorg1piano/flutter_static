import 'package:flutter_static/src/studio/source_edit.dart';
import 'package:flutter_test/flutter_test.dart';

const line = '''
import 'package:flutter/material.dart';
import 'package:flutter_static_story/flutter_static_story.dart';

Storyline storyline() => Storyline(
  'flows/onboarding',
  title: 'Onboarding, "quoted" [brackets]', // ] in a comment
  rows: [
    StorylineRow(
      'Top',
      cells: [
        Cell('welcome', variants: [Story('base', () => const Text('A'))]),
        _phone('signin', 'Sign in (again)'),
      ],
    ),
    StorylineRow(
      'Bottom',
      cells: [
        for (final id in const ['a', 'b'])
          Cell(id, variants: [Story('base', () => Text(id))]),
      ],
    ),
  ],
);
''';

void main() {
  test('inserts before a cell at its indentation', () {
    final out = addStorylineCell(
      line,
      lineId: 'flows/onboarding',
      rowIndex: 0,
      cellId: 'screen-3',
      title: 'Screen 3',
      beforeCell: 1,
      cellCount: 2,
    );
    expect(
      out,
      contains('''
        Cell('welcome', variants: [Story('base', () => const Text('A'))]),
        Cell(
          'screen-3',
          title: 'Screen 3',
          variants: [Story('default', () => const Placeholder())],
        ),
        _phone('signin', 'Sign in (again)'),
'''),
    );
  });

  test('appends at the end of a row', () {
    final out = addStorylineCell(
      line,
      lineId: 'flows/onboarding',
      rowIndex: 0,
      cellId: 'screen-3',
      title: 'Screen 3',
    );
    expect(
      out,
      contains('''
        _phone('signin', 'Sign in (again)'),
        Cell(
          'screen-3',
          title: 'Screen 3',
          variants: [Story('default', () => const Placeholder())],
        ),
      ],
    ),
    StorylineRow(
      'Bottom','''),
    );
  });

  test('a for element is one element, so the cell goes at the end', () {
    final out = addStorylineCell(
      line,
      lineId: 'flows/onboarding',
      rowIndex: 1,
      cellId: 'screen-3',
      title: 'Screen 3',
      beforeCell: 1,
      cellCount: 2,
    );
    expect(
      out,
      contains('''
          Cell(id, variants: [Story('base', () => Text(id))]),
        Cell(
          'screen-3','''),
    );
  });

  test('a row past the last adds a row', () {
    final out = addStorylineCell(
      line,
      lineId: 'flows/onboarding',
      rowIndex: 2,
      cellId: 'screen-3',
      title: 'Screen 3',
      rowTitle: 'Row 3',
    );
    expect(
      out,
      contains('''
      ],
    ),
    StorylineRow(
      'Row 3',
      cells: [
        Cell(
          'screen-3',
          title: 'Screen 3',
          variants: [Story('default', () => const Placeholder())],
        ),
      ],
    ),
  ],
);
'''),
    );
  });

  test('names what it cannot find', () {
    expect(
      () => addStorylineCell(
        line,
        lineId: 'flows/other',
        rowIndex: 0,
        cellId: 'x',
        title: 'x',
      ),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('flows/other'),
        ),
      ),
    );
    const helper = "Storyline('flows/h', rows: [_row('a'), _row('b')]);";
    expect(
      () => addStorylineCell(
        helper,
        lineId: 'flows/h',
        rowIndex: 1,
        cellId: 'x',
        title: 'x',
      ),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('row 2'),
        ),
      ),
    );
  });

  test('appends a story to a page file', () {
    const page = '''
List<Story> stories() => [
  Story('auth/one', () => const Text('1')),
];
''';
    expect(addPageStory(page, storyId: 'auth/screen-2'), '''
List<Story> stories() => [
  Story('auth/one', () => const Text('1')),
  Story('auth/screen-2', () => const Placeholder()),
];
''');
    expect(
      addPageStory('List<Story> stories() => [];\n', storyId: 'p/screen-1'),
      '''
List<Story> stories() => [
  Story('p/screen-1', () => const Placeholder()),
];
''',
    );
  });

  test('adds the widgets import only when nothing defines Placeholder', () {
    expect(ensureWidgetsImport(line), line);
    const bare = '''
import 'dart:io';

import 'package:flutter_static_story/flutter_static_story.dart';
''';
    expect(ensureWidgetsImport(bare), '''
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_static_story/flutter_static_story.dart';
''');
    expect(
      ensureWidgetsImport('void main() {}\n'),
      "import 'package:flutter/widgets.dart';\n\nvoid main() {}\n",
    );
  });

  test('brackets inside strings and comments do not count', () {
    const text = r"""
[
  f('a]b', "c[d", r'e\]', /* ] */ '''
  ]
  ''', '${x}'), // ]
  g(),
]
""";
    final open = text.indexOf('[');
    final close = matchBracket(text, open)!;
    expect(text[close], ']');
    expect(close, text.lastIndexOf(']'));
    final elements = SourceList(text, open, close).elements;
    expect(elements.length, 2);
    // The comment ahead of g() belongs to it; the code starts after it.
    expect(text.substring(elements[1].$1, elements[1].$2), '// ]\n  g()');
    expect(text.substring(codeStart(text, elements[1].$1)), startsWith('g()'));
  });

  test('a commented row is still a row', () {
    const commented = '''
Storyline('flows/c', rows: [
  // The first screen.
  StorylineRow('a', cells: [Cell('x', variants: [])]),
]);
''';
    final out = addStorylineCell(
      commented,
      lineId: 'flows/c',
      rowIndex: 0,
      cellId: 'screen-2',
      title: 'Screen 2',
    );
    expect(
      out,
      contains("Cell('x', variants: []),\n    Cell(\n      'screen-2'"),
    );
  });
}
