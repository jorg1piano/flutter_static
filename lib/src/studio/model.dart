/// What Studio shows, derived from the catalog's `/index.json`.
library;

/// A page on the canvas: a storyline, or every story under one id prefix.
class StudioPage {
  const StudioPage({
    required this.id,
    required this.title,
    required this.rows,
    this.isLine = false,
    this.knobs = const [],
  });

  final String id;
  final String title;
  final bool isLine;
  final List<PageRow> rows;
  final List<KnobInfo> knobs;

  Iterable<String> get storyIds =>
      rows.expand((r) => r.cells).expand((c) => c.variants);
}

class PageRow {
  const PageRow(this.title, this.cells);

  final String title;
  final List<PageCell> cells;
}

/// A column on the canvas: the variants stack under the cell's title.
class PageCell {
  const PageCell({
    required this.id,
    required this.title,
    required this.variants,
  });

  final String id;
  final String title;

  /// Full story ids.
  final List<String> variants;
}

class KnobInfo {
  const KnobInfo({
    required this.id,
    required this.title,
    required this.options,
  });

  final String id;
  final String title;
  final List<KnobOptionInfo> options;
}

class KnobOptionInfo {
  const KnobOptionInfo(this.id, this.title);

  final String id;
  final String title;
}

/// Pages from an index: one per storyline (in order), then one per first
/// segment of the remaining ids, rows by second segment when ids run
/// three deep.
List<StudioPage> pagesFromIndex(Map<String, dynamic> index) {
  final pages = <StudioPage>[];
  final claimed = <String>{};
  for (final line in (index['lines'] as List? ?? const []).cast<Map>()) {
    final id = line['id'] as String;
    final rows = <PageRow>[];
    for (final row in (line['rows'] as List? ?? const []).cast<Map>()) {
      rows.add(
        PageRow(row['title'] as String? ?? '', [
          for (final cell in (row['cells'] as List).cast<Map>())
            PageCell(
              id: cell['id'] as String,
              title: cell['title'] as String? ?? cell['id'] as String,
              variants: [
                for (final v in (cell['variants'] as List).cast<Map>())
                  v['story'] as String,
              ],
            ),
        ]),
      );
    }
    claimed.addAll(rows.expand((r) => r.cells).expand((c) => c.variants));
    pages.add(
      StudioPage(
        id: id,
        title: line['title'] as String? ?? id.split('/').last,
        isLine: true,
        rows: rows,
        knobs: [
          for (final knob in (line['knobs'] as List? ?? const []).cast<Map>())
            KnobInfo(
              id: knob['id'] as String,
              title: knob['title'] as String? ?? knob['id'] as String,
              options: [
                for (final o in (knob['options'] as List).cast<Map>())
                  KnobOptionInfo(
                    o['id'] as String,
                    o['title'] as String? ?? o['id'] as String,
                  ),
              ],
            ),
        ],
      ),
    );
  }
  final byGroup = <String, List<String>>{};
  for (final story in (index['stories'] as List? ?? const []).cast<Map>()) {
    final id = story['id'] as String;
    if (claimed.contains(id)) continue;
    byGroup.putIfAbsent(id.split('/').first, () => []).add(id);
  }
  for (final entry in byGroup.entries) {
    final group = entry.key;
    final deep = entry.value.any((id) => id.split('/').length > 2);
    final byRow = <String, List<String>>{};
    for (final id in entry.value) {
      final segments = id.split('/');
      final row = deep && segments.length > 2 ? segments[1] : group;
      byRow.putIfAbsent(row, () => []).add(id);
    }
    pages.add(
      StudioPage(
        id: group,
        title: group,
        rows: [
          for (final row in byRow.entries)
            PageRow(row.key, [
              for (final id in row.value)
                PageCell(
                  id: id,
                  title: id.split('/').skip(row.key == group ? 1 : 2).join('/'),
                  variants: [id],
                ),
            ]),
        ],
      ),
    );
  }
  return pages;
}
