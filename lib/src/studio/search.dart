/// Cmd+K: a search over everything Studio knows by name. Pages, cells,
/// stories, token groups and tokens, ranked by where the words match.
/// Enter opens the page, scrolls the canvas to the story, or opens the
/// token group in the inspector.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../tokens.dart';
import 'controller.dart';
import 'theme.dart';

enum SearchKind { page, cell, story, tokenGroup, token }

class SearchItem {
  const SearchItem({
    required this.kind,
    required this.title,
    required this.id,
    required this.detail,
    required this.target,
  });

  final SearchKind kind;

  /// What the row says.
  final String title;

  /// The id under it, in mono.
  final String id;

  /// Where it lives: the page for a cell, the group for a token.
  final String detail;

  /// What Enter opens: a page id, a story id or a token group name.
  final String target;

  String get kindLabel => switch (kind) {
    SearchKind.page => 'page',
    SearchKind.cell => 'screen',
    SearchKind.story => 'story',
    SearchKind.tokenGroup => 'tokens',
    SearchKind.token => 'token',
  };
}

/// Everything searchable, pages first.
List<SearchItem> searchItems(StudioController controller) {
  final items = <SearchItem>[];
  for (final page in controller.pages) {
    items.add(
      SearchItem(
        kind: SearchKind.page,
        title: page.title,
        id: page.id,
        detail: page.isLine ? 'flow' : 'page',
        target: page.id,
      ),
    );
  }
  for (final page in controller.pages) {
    for (final row in page.rows) {
      for (final cell in row.cells) {
        if (cell.variants.isEmpty) continue;
        if (page.isLine) {
          items.add(
            SearchItem(
              kind: SearchKind.cell,
              title: cell.title,
              id: '${page.id}/${cell.id}',
              detail: page.title,
              target: cell.variants.first,
            ),
          );
          if (cell.variants.length == 1) continue;
        }
        for (final story in cell.variants) {
          items.add(
            SearchItem(
              kind: SearchKind.story,
              title: page.isLine
                  ? '${cell.title} · ${story.split('/').last}'
                  : story.substring(page.id.length + 1),
              id: story,
              detail: page.title,
              target: story,
            ),
          );
        }
      }
    }
  }
  final groups = controller.tokens?.groups ?? const <TokenGroup>[];
  for (final group in groups) {
    items.add(
      SearchItem(
        kind: SearchKind.tokenGroup,
        title: group.name,
        id: group.file.split('/').last,
        detail: '${group.tokens.length} tokens',
        target: group.name,
      ),
    );
  }
  for (final group in groups) {
    for (final token in group.tokens) {
      items.add(
        SearchItem(
          kind: SearchKind.token,
          title: '${group.name}.${token.name}',
          id: token.source,
          detail: group.name,
          target: group.name,
        ),
      );
    }
  }
  return items;
}

/// [items] that contain every word of [query], best first: a word found
/// early in the title beats one found late, which beats one found only
/// in the id or the detail. An empty query keeps the order given.
List<SearchItem> rankSearch(List<SearchItem> items, String query) {
  final words = query.toLowerCase().split(RegExp(r'\s+'))
    ..removeWhere((w) => w.isEmpty);
  if (words.isEmpty) return items;
  final scored = <(int, int, SearchItem)>[];
  for (final (index, item) in items.indexed) {
    final title = item.title.toLowerCase();
    final rest = '${item.id} ${item.detail}'.toLowerCase();
    var score = 0;
    var matched = true;
    for (final word in words) {
      final inTitle = title.indexOf(word);
      if (inTitle >= 0) {
        score += inTitle;
        continue;
      }
      final inRest = rest.indexOf(word);
      if (inRest < 0) {
        matched = false;
        break;
      }
      score += 100 + inRest;
    }
    if (matched) scored.add((score, index, item));
  }
  scored.sort((a, b) {
    final byScore = a.$1.compareTo(b.$1);
    return byScore != 0 ? byScore : a.$2.compareTo(b.$2);
  });
  return [for (final s in scored) s.$3];
}

/// Opens the palette over the app. Resolves when it closes.
Future<void> showStudioSearch(
  BuildContext context,
  StudioController controller,
) => showDialog<void>(
  context: context,
  barrierColor: const Color(0x66000000),
  builder: (context) => Align(
    alignment: const Alignment(0, -0.7),
    child: StudioSearch(
      controller: controller,
      onClose: () => Navigator.of(context).pop(),
    ),
  ),
);

class StudioSearch extends StatefulWidget {
  const StudioSearch({
    super.key,
    required this.controller,
    required this.onClose,
  });

  final StudioController controller;
  final VoidCallback onClose;

  @override
  State<StudioSearch> createState() => _StudioSearchState();
}

class _StudioSearchState extends State<StudioSearch> {
  static const _maxRows = 12;

  final _query = TextEditingController();
  final _scroll = ScrollController();
  late List<SearchItem> _all = searchItems(widget.controller);
  late List<SearchItem> _hits = _all;
  int _index = 0;

  @override
  void dispose() {
    _query.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onQuery(String text) {
    setState(() {
      _all = searchItems(widget.controller);
      _hits = rankSearch(_all, text);
      _index = 0;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  void _move(int delta) {
    if (_hits.isEmpty) return;
    setState(() => _index = (_index + delta).clamp(0, _hits.length - 1));
    if (!_scroll.hasClients) return;
    final top = _index * _rowHeight;
    final bottom = top + _rowHeight;
    final offset = _scroll.offset;
    final viewport = _scroll.position.viewportDimension;
    if (top < offset) {
      _scroll.jumpTo(top);
    } else if (bottom > offset + viewport) {
      _scroll.jumpTo(bottom - viewport);
    }
  }

  static const _rowHeight = 44.0;

  void _choose(SearchItem item) {
    final controller = widget.controller;
    switch (item.kind) {
      case SearchKind.page:
        controller.selectPage(item.target);
      case SearchKind.cell:
      case SearchKind.story:
        controller.revealStory(item.target);
      case SearchKind.tokenGroup:
      case SearchKind.token:
        controller.setInspectorPanelOpen(true);
        controller.selectTokenGroup(item.target);
    }
    widget.onClose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowDown:
        _move(1);
      case LogicalKeyboardKey.arrowUp:
        _move(-1);
      case LogicalKeyboardKey.escape:
        widget.onClose();
      case LogicalKeyboardKey.enter:
      case LogicalKeyboardKey.numpadEnter:
        if (_index < _hits.length) _choose(_hits[_index]);
      default:
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final shown = _hits.length > 200 ? _hits.sublist(0, 200) : _hits;
    return Focus(
      onKeyEvent: _onKey,
      child: Material(
        color: StudioColors.panel,
        elevation: 12,
        borderRadius: BorderRadius.circular(10),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          width: 600,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                child: Row(
                  children: [
                    const Icon(
                      Icons.search,
                      size: 18,
                      color: StudioColors.muted,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextField(
                        controller: _query,
                        autofocus: true,
                        onChanged: _onQuery,
                        style: StudioText.body.copyWith(fontSize: 15),
                        cursorColor: StudioColors.accent,
                        decoration: const InputDecoration(
                          isDense: true,
                          border: InputBorder.none,
                          hintText: 'Pages, screens, stories, tokens',
                          hintStyle: TextStyle(
                            color: StudioColors.faint,
                            fontSize: 15,
                          ),
                        ),
                      ),
                    ),
                    const Text('esc', style: StudioText.monoMuted),
                  ],
                ),
              ),
              const Divider(height: 1, color: StudioColors.border),
              if (shown.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(14),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text('Nothing matches', style: StudioText.muted),
                  ),
                )
              else
                SizedBox(
                  height:
                      _rowHeight *
                      (shown.length < _maxRows ? shown.length : _maxRows),
                  child: ListView.builder(
                    controller: _scroll,
                    itemExtent: _rowHeight,
                    itemCount: shown.length,
                    itemBuilder: (context, i) => _Row(
                      item: shown[i],
                      selected: i == _index,
                      onTap: () => _choose(shown[i]),
                      onHover: () {
                        if (_index != i) setState(() => _index = i);
                      },
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.item,
    required this.selected,
    required this.onTap,
    required this.onHover,
  });

  final SearchItem item;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onHover;

  IconData get _icon => switch (item.kind) {
    SearchKind.page => Icons.grid_view_outlined,
    SearchKind.cell => Icons.smartphone_outlined,
    SearchKind.story => Icons.crop_portrait_outlined,
    SearchKind.tokenGroup => Icons.palette_outlined,
    SearchKind.token => Icons.tag,
  };

  @override
  Widget build(BuildContext context) => MouseRegion(
    onEnter: (_) => onHover(),
    child: GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        color: selected ? StudioColors.raised : Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Row(
          children: [
            Icon(
              _icon,
              size: 15,
              color: selected ? StudioColors.accent : StudioColors.faint,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    style: StudioText.body.copyWith(
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    item.id,
                    style: StudioText.monoMuted,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Text(item.detail, style: StudioText.muted),
            const SizedBox(width: 12),
            SizedBox(
              width: 44,
              child: Text(
                item.kindLabel,
                style: StudioText.section,
                textAlign: TextAlign.right,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
