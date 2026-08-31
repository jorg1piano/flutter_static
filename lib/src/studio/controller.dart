/// Studio's state, in the catalog's own process: the pages derived from
/// the [Stories], live mounts and PNG renders through the catalog's
/// public API, reload state from its notifiers, and the project's
/// tokens. One [ChangeNotifier]; the views rebuild off it.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../phone_mockup.dart';
import '../server_io.dart';
import '../story.dart';
import '../tokens.dart';
import '../widget_pick.dart';
import 'herdr.dart';
import 'model.dart';
import 'source_edit.dart';

enum CatalogStatus { ready, reloading, error }

/// One fetched render, with the version and options it was captured at.
/// Owns its image handle: [dispose] once nothing paints it any more.
class StoryRender {
  const StoryRender(this.image, this.key);

  final ui.Image image;

  /// Version plus render options; a different key means stale.
  final String key;

  void dispose() => image.dispose();
}

class StudioSlot {
  const StudioSlot({
    required this.id,
    required this.cellId,
    required this.title,
    required this.storyId,
    this.variantLabel,
  });

  final String id;
  final String cellId;
  final String title;
  final String storyId;
  final String? variantLabel;
}

class StudioController extends ChangeNotifier {
  StudioController({
    required this.stories,
    required this.project,
    required this.port,
  }) {
    catalogVersion.addListener(_onVersion);
    catalogReloadTick.addListener(notifyListeners);
    watchKeyboard();
    _loadStudioState();
    refreshIndex();
    loadTokens();
  }

  final Stories stories;
  final String project;
  final int port;

  String get url => 'http://localhost:$port';
  String get projectName => project.split('/').last;

  CatalogStatus get status => reloadError != null
      ? CatalogStatus.error
      : catalogReloadPending
      ? CatalogStatus.reloading
      : CatalogStatus.ready;
  String? get reloadError => catalogReloadError;

  final logs = <String>[];
  bool showLogs = false;

  /// Studio chrome expansion state. Persisted in .dart_tool so restarting
  /// Studio restores the same open/collapsed panels.
  bool promptPanelOpen = true;
  bool inspectorPanelOpen = true;

  List<StudioPage> pages = const [];

  /// Studio-only freeform slots on each row. Null means an intentional
  /// gap. Kept across hot reloads so a cell just written to the storyline
  /// file stays in its slot while the reload catches up.
  final _storySlots = <String, List<List<StudioSlot?>>>{};
  final _slotUndo = <Map<String, List<List<StudioSlot?>>>>[];

  int version = 0;
  String? selectedPageId;
  String? selectedStoryId;

  /// The token group open in the right panel, or null for the inspector.
  String? selectedTokenGroup;
  TokenSet? tokens;

  /// Render options for storyline pages.
  String? device;
  bool statusBar = false;
  final knobs = <String, String>{};

  /// Live mounts on the canvas, or the PNG renders the catalog serves.
  bool live = true;

  /// Whether an Option-click that reaches the mounted widget also selects
  /// its story. Plain clicks always inspect the widget tree.
  bool interact = true;

  /// Stories shown as renders even while [live] is on.
  final renderOnly = <String>{};

  final looseBoxes = <Rect>[];

  /// Text in the Codex prompt panel. Canvas voice/selection tools append to
  /// this, and the panel edits it directly.
  String promptText = '';

  void setPromptText(String text) {
    if (promptText == text) return;
    promptText = text;
    notifyListeners();
  }

  void appendPromptText(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    promptText = promptText.trim().isEmpty
        ? trimmed
        : '${promptText.trim()}\n\n$trimmed';
    notifyListeners();
  }

  // --- herdr --------------------------------------------------------------

  /// Herdr panes the selection can be sent to, and which one is chosen.
  /// The chosen pane id is persisted with the panel state, so the second
  /// send goes straight through after a restart.
  final herdr = Herdr();
  List<HerdrPane> herdrPanes = const [];
  String? herdrPaneId;
  bool herdrBusy = false;

  /// What the last Herdr action did, for the inspector: "Sent to ...",
  /// or the error. Cleared by the next action.
  String? herdrStatus;
  bool _herdrListed = false;

  HerdrPane? get herdrPane {
    for (final p in herdrPanes) {
      if (p.id == herdrPaneId) return p;
    }
    return null;
  }

  /// Lists panes the first time the inspector shows the Herdr section;
  /// later refreshes are explicit.
  void ensureHerdrPanes() {
    if (_herdrListed) return;
    _herdrListed = true;
    refreshHerdrPanes();
  }

  /// Re-reads the pane list. Agent panes come first, those in the
  /// project before the rest; shells outside the project are left out,
  /// or the list would be every terminal on the machine.
  Future<void> refreshHerdrPanes() async {
    _herdrListed = true;
    herdrBusy = true;
    notifyListeners();
    try {
      final all = await herdr.panes();
      int rank(HerdrPane p) => switch ((p.hasAgent, p.inProject(project))) {
        (true, true) => 0,
        (true, false) => 1,
        (false, true) => 2,
        (false, false) => 3,
      };
      herdrPanes = [
        for (final p in all)
          if (p.hasAgent || p.inProject(project)) p,
      ]..sort((a, b) => rank(a).compareTo(rank(b)));
      if (herdrPane == null && herdrPaneId != null) {
        // The remembered pane is gone; pick the best remaining one.
        herdrPaneId = herdrPanes.firstOrNull?.id;
        _saveStudioState();
      }
      herdrPaneId ??= herdrPanes.firstOrNull?.id;
      herdrStatus = null;
    } on HerdrException catch (e) {
      herdrPanes = const [];
      herdrStatus = e.message;
      log('herdr: ${e.message}');
    }
    herdrBusy = false;
    notifyListeners();
  }

  void setHerdrPane(String? id) {
    if (herdrPaneId == id) return;
    herdrPaneId = id;
    herdrStatus = null;
    _saveStudioState();
    notifyListeners();
  }

  /// The selection as one line for an agent in another terminal, which
  /// has none of Studio's launch context: where the project is, which
  /// story, which widget and its source line, and how to check a change.
  /// Ends in a space so a request can be typed straight after it. Null
  /// when nothing is selected.
  String? herdrMessage() {
    final story = selectedStoryId;
    if (story == null) return null;
    final knobArgs = knobs.entries.map((e) => ' -k ${e.key}=${e.value}').join();
    final png = '/tmp/${story.replaceAll('/', '-')}.png';
    final render =
        'Check by running `dart run flutter_static render $story$knobArgs '
        '-o $png` from the project and reading the PNG.';
    final pick = this.pick;
    final picked = pickedWidget;
    if (pick == null || picked == null || pickStoryId != story) {
      return 'In Flutter Static Studio (project $project) I am looking at '
          'story `$story`. $render ';
    }
    String line(PickedWidget w) {
      final where = w.location == null
          ? 'no source location'
          : scopes.describe(w.location!);
      final text = w.text == null ? '' : ' with text "${w.text}"';
      return '`${w.type}`$text at $where';
    }

    final outward = [
      for (final w in pick.local)
        if (w != picked) line(w),
    ];
    return [
      'In Flutter Static Studio (project $project, story `$story`) I '
          'selected ${line(picked)}',
      if (outward.isNotEmpty) ', inside ${outward.join(', inside ')}',
      '; the line is where it is constructed, so edit that call to change '
          'what it shows and its own class to change how it looks. $render ',
    ].join();
  }

  /// Types the selection into the chosen Herdr pane. With [submit] the
  /// prompt panel's request goes with it and the whole thing is sent as
  /// a prompt to the pane's agent; without, it lands at the cursor for
  /// the user to finish.
  Future<void> sendToHerdr({bool submit = false}) async {
    final paneId = herdrPaneId;
    final message = herdrMessage();
    if (paneId == null || message == null) return;
    herdrBusy = true;
    herdrStatus = null;
    notifyListeners();
    final target = herdrPane?.name ?? paneId;
    try {
      if (submit) {
        final request = promptText.trim();
        await herdr.prompt(
          paneId,
          request.isEmpty ? message.trim() : '$message\nUser request: $request',
        );
        herdrStatus = 'Prompted $target';
      } else {
        await herdr.sendText(paneId, message);
        herdrStatus = 'Typed into $target';
      }
    } on HerdrException catch (e) {
      herdrStatus = e.message;
      log('herdr: ${e.message}');
    }
    herdrBusy = false;
    notifyListeners();
  }

  final _renders = <String, StoryRender>{};
  final _inflight = <String>{};

  /// Renders replaced since the last notification. Disposed after the
  /// frame that paints their replacements: painting a disposed image is
  /// an assertion, and a repaint can come before the rebuild.
  final _retired = <StoryRender>[];
  bool _disposed = false;
  bool _notifyScheduled = false;

  /// One notification per frame however many captures land in it: every
  /// notification rebuilds the whole page of live cards.
  void _notifySoon() {
    if (_notifyScheduled || _disposed) return;
    _notifyScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _notifyScheduled = false;
      if (_disposed) return;
      notifyListeners();
      _disposeRetiredAfterFrame();
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  void _disposeRetiredAfterFrame() {
    if (_retired.isEmpty) return;
    final retired = List.of(_retired);
    _retired.clear();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final render in retired) {
        render.dispose();
      }
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  /// What the agent needs before a turn: where it is, how to check its
  /// work without touching this process, and what the user is looking
  /// at. Facts, one per line; the agent reads it, nobody else should
  /// have to.
  String agentContext({bool withSelection = true}) {
    final page = withSelection ? selectedPage : null;
    final story = withSelection ? selectedStoryId : null;
    final knobArgs = knobs.entries.map((e) => ' -k ${e.key}=${e.value}').join();
    return [
      'Flutter Static Studio. Project: $project. The story catalog is '
          'already running at $url and hot reloads saves under lib/, story/ '
          'and packages/. Do not run `flutter_static up`, `run`, `down` or '
          '`studio`.',
      'Verify with `dart run flutter_static render <story id> -o '
          '/tmp/<name>.png` (from the project), then read the PNG. `dart run '
          'flutter_static list` lists story ids. `dart run flutter_static '
          'tokens list` lists design tokens; `dart run flutter_static tokens '
          'set <Group.name> <value>` edits one.',
      'Change tokens and components in packages/ before one-off values. '
          'Stories live in story/. Reply in a few sentences; the canvas '
          'shows the result.',
      if (!withSelection) ...[
        'A story id in backticks typed into this terminal, like '
            '`buttons/kinds`, is what the user clicked; a request after it '
            'is about that story.',
        'A source position in backticks, like '
            '`story/stories/buttons.dart:13:11`, is where the clicked widget '
            'is constructed; a request after it is about that widget. Edit '
            'the call to change what it shows, its class to change how it '
            'looks. `dart run flutter_static inspect <story id> --at X,Y` '
            'names the widgets and lines at a pixel of a render.',
      ],
      if (page != null) 'Page: ${page.title} (${page.id}).',
      if (story != null)
        'Story: `$story`. Render it with `dart run flutter_static render '
            '$story$knobArgs`. A request that names no story is about it.',
      ?_pickContext(),
    ].join('\n');
  }

  /// The clicked widget, for the agent: it and the project's widgets
  /// around it, each with its source line.
  String? _pickContext() {
    final pick = this.pick;
    final picked = pickedWidget;
    if (pick == null || picked == null || pickStoryId != selectedStoryId) {
      return null;
    }
    String line(PickedWidget w) {
      final where = w.location == null
          ? 'no source location'
          : scopes.describe(w.location!);
      final text = w.text == null ? '' : ' with text "${w.text}"';
      return '`${w.type}`$text at $where';
    }

    final outward = [
      for (final w in pick.local)
        if (w != picked) line(w),
    ];
    return [
      'Selected widget: ${line(picked)}. "This" or "it" means that widget; '
          'the line is where it is constructed. Edit the call to change '
          'what it shows, its class to change how it looks.',
      if (outward.isNotEmpty) 'Around it, outward: ${outward.join('; ')}.',
    ].join('\n');
  }

  StudioPage? get selectedPage {
    for (final p in pages) {
      if (p.id == selectedPageId) return p;
    }
    return pages.isEmpty ? null : pages.first;
  }

  PhoneSpec? get deviceSpec => PhoneSpec.byName(device);

  void log(String line) {
    logs.add(line);
    if (logs.length > 500) logs.removeRange(0, logs.length - 500);
    notifyListeners();
  }

  Future<void> chooseProjectFolder() async {
    final result = await Process.run('/usr/bin/osascript', const [
      '-e',
      'POSIX path of (choose folder with prompt "Choose the Flutter project to open in Studio")',
    ]);
    if (result.exitCode != 0) return;
    await openProjectPath('${result.stdout}');
  }

  Future<void> openProjectPath(String input) async {
    final selected = input.trim().replaceFirst(RegExp(r'/$'), '');
    if (selected.isEmpty) return;
    if (!Directory(selected).existsSync()) {
      log('open project: $selected does not exist');
      return;
    }
    if (!File('$selected/pubspec.yaml').existsSync()) {
      log('open project: $selected has no pubspec.yaml');
      return;
    }
    if (!File('$selected/story/main.dart').existsSync()) {
      log('open project: $selected has no story/main.dart');
      return;
    }

    final command = _studioCommand;
    final quoted = command
        .map((a) => "'${a.replaceAll("'", r"'\''")}'")
        .join(' ');
    log('Opening Studio for $selected...');
    await Process.start('/bin/sh', [
      '-lc',
      'sleep 1; exec $quoted studio-host --project ${_shQuote(selected)}',
    ], mode: ProcessStartMode.detached);
    unawaited(
      Future<void>.delayed(const Duration(milliseconds: 250), () {
        exit(0);
      }),
    );
  }

  static String _shQuote(String value) => "'${value.replaceAll("'", r"'\''")}'";

  static List<String> get _studioCommand {
    final exe = Platform.resolvedExecutable;
    final name = exe.split(Platform.pathSeparator).last;
    if (name != 'dart' && name != 'dartvm') return [exe];

    final found = Process.runSync('/usr/bin/which', ['flutter_static']);
    final path = '${found.stdout}'.trim();
    if (found.exitCode == 0 && path.isNotEmpty) return [path];

    final local = '${Platform.environment['HOME']}/.local/bin/flutter_static';
    if (File(local).existsSync()) return [local];

    return [exe, 'run', 'flutter_static'];
  }

  // --- stories ------------------------------------------------------------

  void refreshIndex() {
    try {
      pages = pagesFromIndex(storiesIndex(stories));
    } catch (e) {
      log('stories: $e');
      pages = const [];
    }
    selectedPageId ??= pages.isEmpty ? null : pages.first.id;
    if (selectedPage?.id != selectedPageId) selectedPageId = selectedPage?.id;
    notifyListeners();
  }

  void _onVersion() {
    version = catalogVersion.value;
    // The picked elements are rebuilt, and their lines may have moved.
    pick = null;
    refreshIndex();
    // Tokens may have changed on disk (an agent editing the file is the
    // point), and stories may have been added or renamed.
    loadTokens();
  }

  void selectPage(String id) {
    selectedPageId = id;
    selectedStoryId = null;
    notifyListeners();
  }

  void selectStory(String? id) {
    selectedStoryId = id;
    selectedTokenGroup = null;
    pick = null;
    notifyListeners();
  }

  /// The slot the canvas should scroll to, and a tick that changes each
  /// time it is asked to; set by [revealStory].
  String? revealSlotId;
  int revealTick = 0;

  /// Selects [id] on its page and asks the canvas to scroll to it. On a
  /// plain page every variant of a cell shares one slot, the first
  /// variant's.
  void revealStory(String id) {
    StudioPage? owner;
    PageCell? cell;
    for (final page in pages) {
      for (final row in page.rows) {
        for (final c in row.cells) {
          if (c.variants.contains(id)) {
            owner = page;
            cell = c;
            break;
          }
        }
        if (cell != null) break;
      }
      if (cell != null) break;
    }
    if (owner == null || cell == null) {
      log('reveal: no page shows $id');
      return;
    }
    selectedPageId = owner.id;
    selectedStoryId = id;
    selectedTokenGroup = null;
    pick = null;
    revealSlotId = owner.isLine ? id : cell.variants.first;
    revealTick++;
    notifyListeners();
  }

  Future<void> addPage({String? name}) async {
    try {
      final storiesDir = Directory('$project/story/stories');
      storiesDir.createSync(recursive: true);
      var slug = name == null || name.trim().isEmpty
          ? 'studio_page'
          : _slug(name.trim().replaceFirst(RegExp(r'\.dart$'), ''));
      var n = 2;
      final base = slug;
      while (File('${storiesDir.path}/$slug.dart').existsSync()) {
        slug = '${base}_$n';
        n++;
      }
      final title = slug.replaceAll('_', ' ');
      final className = _pageClassName(slug);
      final file = File('${storiesDir.path}/$slug.dart');
      file.writeAsStringSync('''
import 'package:flutter/material.dart';
import 'package:flutter_static_story/flutter_static_story.dart';

List<Story> stories() => [
  Story('$slug/default', () => const $className()),
];

/// Page created from Flutter Static Studio.
class $className extends StatelessWidget {
  const $className({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xFFF8FAFC),
    body: Center(
      child: Text(
        '${_titleCase(title)}',
        style: const TextStyle(
          color: Color(0xFF0F172A),
          fontSize: 28,
          fontWeight: FontWeight.w700,
        ),
      ),
    ),
  );
}
''');
      _wireStoryFile(slug);
      log('Created page story ${file.path}');
      selectedPageId = slug;
      selectedTokenGroup = null;
      notifyListeners();
    } on Object catch (e) {
      log('add page: $e');
    }
  }

  Future<void> renamePageFile(String pageId, String input) async {
    try {
      final newSlug = _slug(input.trim().replaceFirst(RegExp(r'\.dart$'), ''));
      if (newSlug.isEmpty || newSlug == pageId) return;
      final dir = Directory('$project/story/stories');
      final oldFile = File('${dir.path}/$pageId.dart');
      final newFile = File('${dir.path}/$newSlug.dart');
      if (!oldFile.existsSync()) {
        log('rename page: ${oldFile.path} does not exist');
        return;
      }
      if (newFile.existsSync()) {
        log('rename page: ${newFile.path} already exists');
        return;
      }

      var text = oldFile.readAsStringSync();
      text = text
          .replaceAll(_pageClassName(pageId), _pageClassName(newSlug))
          .replaceAll("Story('$pageId/", "Story('$newSlug/")
          .replaceAll('Story("$pageId/', 'Story("$newSlug/');
      newFile.writeAsStringSync(text);
      oldFile.deleteSync();
      _renameStoryImport(pageId, newSlug);
      if (_storySlots.remove(pageId) case final slots?) {
        _storySlots[newSlug] = slots;
      }
      selectedPageId = newSlug;
      log('Renamed page story ${oldFile.path} -> ${newFile.path}');
      refreshIndex();
    } on Object catch (e) {
      log('rename page: $e');
    }
  }

  void _renameStoryImport(String oldSlug, String newSlug) {
    final main = File('$project/story/main.dart');
    if (!main.existsSync()) return;
    var text = main.readAsStringSync();
    text = text
        .replaceAll(
          "import 'stories/$oldSlug.dart' as $oldSlug;",
          "import 'stories/$newSlug.dart' as $newSlug;",
        )
        .replaceAll('...$oldSlug.stories(),', '...$newSlug.stories(),');
    main.writeAsStringSync(text);
  }

  void _wireStoryFile(String slug) {
    final main = File('$project/story/main.dart');
    if (!main.existsSync()) {
      log(
        'add page: story/main.dart not found; import stories/$slug.dart manually',
      );
      return;
    }
    var text = main.readAsStringSync();
    final alias = slug;
    final importLine = "import 'stories/$slug.dart' as $alias;";
    if (!text.contains(importLine)) {
      final storyImport = RegExp(
        r"^import 'stories/[^']+' as \w+;\n",
        multiLine: true,
      ).allMatches(text).lastOrNull;
      if (storyImport != null) {
        text = text.replaceRange(
          storyImport.end,
          storyImport.end,
          '$importLine\n',
        );
      } else {
        text = '$importLine\n$text';
      }
    }
    final spread = '    ...$alias.stories(),\n';
    if (!text.contains(spread)) {
      const marker = '  List<Story> build() => [\n';
      final index = text.indexOf(marker);
      if (index < 0) {
        log(
          'add page: add `...$alias.stories(),` to SendiStories.build() manually',
        );
      } else {
        final insert = index + marker.length;
        text = text.replaceRange(insert, insert, spread);
      }
    }
    main.writeAsStringSync(text);
  }

  static String _titleCase(String text) => text
      .split(RegExp(r'[_\s-]+'))
      .where((part) => part.isNotEmpty)
      .map((part) => part[0].toUpperCase() + part.substring(1))
      .join(' ');

  static String _pageClassName(String slug) =>
      '${_titleCase(slug).replaceAll(' ', '')}Page';

  static const _emptySlotsLeft = 1;
  static const _emptySlotsRight = 1;
  static const _extraEmptyRows = 1;

  int slotRowCount(StudioPage page) =>
      page.isLine ? _pageSlots(page).length : page.rows.length;

  String? rowTitle(StudioPage page, int rowIndex) =>
      rowIndex < page.rows.length ? page.rows[rowIndex].title : null;

  List<StudioSlot?> slotsFor(StudioPage page, int rowIndex) => page.isLine
      ? _pageSlots(page)[rowIndex]
      : [
          for (final cell in page.rows[rowIndex].cells)
            _slotFor(cell, cell.variants.first, showVariant: false),
        ];

  List<List<StudioSlot?>> _pageSlots(StudioPage page) {
    final pageSlots = _storySlots.putIfAbsent(page.id, () {
      final rowSlots = [
        for (final row in page.rows)
          [
            for (var i = 0; i < _emptySlotsLeft; i++) null,
            for (final cell in row.cells)
              for (final (i, storyId) in cell.variants.indexed)
                _slotFor(cell, storyId, showVariant: i > 0),
          ],
      ];
      final widest = rowSlots.fold<int>(
        0,
        (max, row) => row.length > max ? row.length : max,
      );
      final width = widest + _emptySlotsRight;
      for (final row in rowSlots) {
        while (row.length < width) {
          row.add(null);
        }
      }
      return [
        ...rowSlots,
        for (var i = 0; i < _extraEmptyRows; i++)
          [for (var j = 0; j < width; j++) null],
      ];
    });
    final width = pageSlots.fold<int>(
      0,
      (max, row) => row.length > max ? row.length : max,
    );
    while (pageSlots.length < page.rows.length + _extraEmptyRows) {
      pageSlots.add([for (var i = 0; i < width; i++) null]);
    }
    for (final row in pageSlots) {
      while (row.length < width) {
        row.add(null);
      }
    }
    return pageSlots;
  }

  static StudioSlot _slotFor(
    PageCell cell,
    String storyId, {
    required bool showVariant,
  }) => StudioSlot(
    id: storyId,
    cellId: cell.id,
    title: cell.title,
    storyId: storyId,
    variantLabel: showVariant ? storyId.split('/').last : null,
  );

  Map<String, List<List<StudioSlot?>>> _copySlots() => {
    for (final entry in _storySlots.entries)
      entry.key: [
        for (final row in entry.value) [...row],
      ],
  };

  void undoCanvas() {
    if (looseBoxes.isNotEmpty) {
      looseBoxes.removeLast();
      notifyListeners();
      return;
    }
    undoLayout();
  }

  void undoLayout() {
    if (_slotUndo.isEmpty) return;
    _storySlots
      ..clear()
      ..addAll(_slotUndo.removeLast());
    notifyListeners();
  }

  void addLooseBox(Rect rect) {
    if (rect.width.abs() < 4 || rect.height.abs() < 4) return;
    looseBoxes.add(rect);
    notifyListeners();
  }

  void removeLooseBox(Rect rect) {
    if (looseBoxes.remove(rect)) notifyListeners();
  }

  Future<void> runOneShotEdit({
    required String prompt,
    required Rect box,
    String? imagePath,
  }) async {
    final page = selectedPage;
    final story = selectedStoryId;
    final text = [
      'You are editing the Flutter project at $project.',
      if (page != null) 'The current Studio page is ${page.id}.',
      if (story != null) 'The selected story is `$story`.',
      'The user drew a rectangle at canvas coordinates '
          '${box.left.toStringAsFixed(1)},${box.top.toStringAsFixed(1)} '
          '${box.width.toStringAsFixed(1)}x${box.height.toStringAsFixed(1)}.',
      if (imagePath != null)
        'A screenshot of the full mockup/canvas with the rectangle is at '
            '$imagePath. Use it because the rectangle may point to whitespace.',
      'User request: $prompt',
    ].join('\n');
    final promptFile = File('$project/.dart_tool/flutter_static_ai_prompt.txt');
    promptFile.parent.createSync(recursive: true);
    promptFile.writeAsStringSync(text);
    final template =
        Platform.environment['FLUTTER_STATIC_ONESHOT'] ??
        'codex exec --sandbox workspace-write --approve-for-me {image} {prompt}';
    final command = template
        .replaceAll('{prompt}', _shellQuote(text))
        .replaceAll('{promptFile}', _shellQuote(promptFile.path))
        .replaceAll(
          '{image}',
          imagePath == null ? '' : '-i ${_shellQuote(imagePath)}',
        );
    final shellCommand =
        template.contains('{prompt}') ||
            template.contains('{promptFile}') ||
            template.contains('{image}')
        ? command
        : '$command < ${_shellQuote(promptFile.path)}';
    log('AI edit: $shellCommand');
    try {
      final result = await Process.run('/bin/sh', [
        '-lc',
        shellCommand,
      ], workingDirectory: project);
      if ('${result.stdout}'.trim().isNotEmpty) log('${result.stdout}'.trim());
      if (result.exitCode != 0) {
        log('AI edit failed (${result.exitCode}): ${result.stderr}'.trim());
      } else if ('${result.stderr}'.trim().isNotEmpty) {
        log('${result.stderr}'.trim());
      }
    } on Object catch (e) {
      log('AI edit failed: $e');
    }
  }

  static String _shellQuote(String s) => "'${s.replaceAll("'", r"'\''")}'";

  /// Moves a canvas cell into a concrete slot. Empty slots are preserved,
  /// so a screen can leave a gap behind it. This is a Studio-only layout
  /// tweak; a catalog hot reload rebuilds pages from the stories again.
  void moveCellToSlot({
    required String pageId,
    required String cellId,
    required int rowIndex,
    required int slotIndex,
  }) {
    final page = pages.where((p) => p.id == pageId).firstOrNull;
    if (page == null || rowIndex < 0) return;
    final pageSlots = [
      for (final row in _pageSlots(page)) [...row],
    ];
    final width = pageSlots.fold<int>(
      0,
      (max, row) => row.length > max ? row.length : max,
    );
    while (rowIndex >= pageSlots.length) {
      pageSlots.add([for (var i = 0; i < width; i++) null]);
    }
    if (slotIndex < 0) return;
    while (slotIndex >= pageSlots[rowIndex].length) {
      for (final row in pageSlots) {
        row.add(null);
      }
    }

    StudioSlot? moved;
    int? sourceRow;
    int? sourceSlot;
    for (final (r, row) in pageSlots.indexed) {
      final index = row.indexWhere(
        (c) => c?.id == cellId || c?.cellId == cellId,
      );
      if (index >= 0) {
        moved = row[index];
        sourceRow = r;
        sourceSlot = index;
        break;
      }
    }
    if (moved == null || sourceRow == null || sourceSlot == null) return;
    if (sourceRow == rowIndex && sourceSlot == slotIndex) return;

    _slotUndo.add(_copySlots());
    if (_slotUndo.length > 100) _slotUndo.removeAt(0);

    final displaced = pageSlots[rowIndex][slotIndex];
    pageSlots[rowIndex][slotIndex] = moved;
    pageSlots[sourceRow][sourceSlot] = displaced;
    _storySlots[pageId] = pageSlots;
    notifyListeners();
  }

  /// Click on an empty slot: a new placeholder cell in the storyline
  /// file, at that spot in the row, and the slot filled with it while
  /// hot reload catches up. On a plain page, a new story in the page
  /// file instead.
  void newCellAtSlot({
    required String pageId,
    required int rowIndex,
    required int slotIndex,
  }) {
    final page = pages.where((p) => p.id == pageId).firstOrNull;
    if (page == null || rowIndex < 0 || slotIndex < 0) return;
    if (!page.isLine) {
      _writePageStory(page);
      return;
    }
    final pageSlots = [
      for (final row in _pageSlots(page)) [...row],
    ];
    _growSlots(pageSlots, rowIndex, slotIndex);
    if (pageSlots[rowIndex][slotIndex] != null) return;
    final slot = _writeStorylineCell(page, pageSlots, rowIndex, slotIndex);
    if (slot == null) return;
    _slotUndo.add(_copySlots());
    if (_slotUndo.length > 100) _slotUndo.removeAt(0);
    pageSlots[rowIndex][slotIndex] = slot;
    _storySlots[pageId] = pageSlots;
    notifyListeners();
  }

  /// The plus between screens: a new cell before [slotIndex], the row's
  /// content shifted right until the next gap.
  void newCellBefore({
    required String pageId,
    required int rowIndex,
    required int slotIndex,
  }) {
    final page = pages.where((p) => p.id == pageId).firstOrNull;
    if (page == null || rowIndex < 0 || slotIndex < 0) return;
    if (!page.isLine) {
      _writePageStory(page);
      return;
    }
    final pageSlots = [
      for (final row in _pageSlots(page)) [...row],
    ];
    _growSlots(pageSlots, rowIndex, slotIndex);
    final target = pageSlots[rowIndex];
    var gap = target.indexWhere((slot) => slot == null, slotIndex);
    if (gap < 0) {
      target.add(null);
      gap = target.length - 1;
    }
    for (var i = gap; i > slotIndex; i--) {
      target[i] = target[i - 1];
    }
    target[slotIndex] = null;
    final slot = _writeStorylineCell(page, pageSlots, rowIndex, slotIndex);
    if (slot == null) return;
    _slotUndo.add(_copySlots());
    if (_slotUndo.length > 100) _slotUndo.removeAt(0);
    target[slotIndex] = slot;
    _storySlots[pageId] = pageSlots;
    notifyListeners();
  }

  static void _growSlots(
    List<List<StudioSlot?>> pageSlots,
    int rowIndex,
    int slotIndex,
  ) {
    final width = pageSlots.fold<int>(
      0,
      (max, row) => row.length > max ? row.length : max,
    );
    while (rowIndex >= pageSlots.length) {
      pageSlots.add([for (var i = 0; i < width; i++) null]);
    }
    while (slotIndex >= pageSlots[rowIndex].length) {
      for (final row in pageSlots) {
        row.add(null);
      }
    }
  }

  /// Writes a placeholder cell into the storyline's source, before the
  /// cell in the next occupied slot of the row (or at the row's end),
  /// and returns the slot that shows it. Undo on the canvas does not
  /// undo the file.
  StudioSlot? _writeStorylineCell(
    StudioPage page,
    List<List<StudioSlot?>> pageSlots,
    int rowIndex,
    int slotIndex,
  ) {
    try {
      final file = _storylineFile(page.id);
      if (file == null) {
        log("add screen: no file under story/ defines Storyline('${page.id}')");
        return null;
      }
      final row = rowIndex < page.rows.length ? page.rows[rowIndex] : null;
      int? before;
      if (row != null) {
        for (final slot in pageSlots[rowIndex].skip(slotIndex + 1)) {
          if (slot == null) continue;
          final index = row.cells.indexWhere((c) => c.id == slot.cellId);
          if (index >= 0) {
            before = index;
            break;
          }
        }
      }
      final taken = {
        for (final r in page.rows)
          for (final c in r.cells) c.id,
      };
      var n = taken.length + 1;
      while (taken.contains('screen-$n')) {
        n++;
      }
      final cellId = 'screen-$n';
      final title = 'Screen $n';
      final text = addStorylineCell(
        file.readAsStringSync(),
        lineId: page.id,
        rowIndex: rowIndex,
        cellId: cellId,
        title: title,
        beforeCell: before,
        cellCount: row?.cells.length ?? 0,
        rowTitle: 'Row ${rowIndex + 1}',
      );
      file.writeAsStringSync(ensureWidgetsImport(text));
      log('Added $cellId to ${file.path}');
      final storyId = '${page.id}/$cellId/default';
      return StudioSlot(
        id: storyId,
        cellId: cellId,
        title: title,
        storyId: storyId,
      );
    } on Object catch (e) {
      log('add screen: $e');
      return null;
    }
  }

  /// A placeholder story appended to a plain page's file. It shows once
  /// hot reload lands, in the row its id puts it in.
  void _writePageStory(StudioPage page) {
    try {
      final file = File('$project/story/stories/${page.id}.dart');
      if (!file.existsSync()) {
        log('add story: ${file.path} not found');
        return;
      }
      final taken = {
        for (final r in page.rows)
          for (final c in r.cells) ...c.variants,
      };
      var n = taken.length + 1;
      while (taken.contains('${page.id}/screen-$n')) {
        n++;
      }
      final storyId = '${page.id}/screen-$n';
      final text = addPageStory(file.readAsStringSync(), storyId: storyId);
      file.writeAsStringSync(ensureWidgetsImport(text));
      log('Added $storyId to ${file.path}');
    } on Object catch (e) {
      log('add story: $e');
    }
  }

  /// The first Dart file under story/ that declares the storyline,
  /// lines/ first.
  File? _storylineFile(String lineId) {
    final dir = Directory('$project/story');
    if (!dir.existsSync()) return null;
    final pattern = RegExp(
      "Storyline\\(\\s*(['\"])${RegExp.escape(lineId)}\\1",
    );
    final files =
        dir
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart'))
            .where((f) => !f.path.contains('/.dart_tool/'))
            .toList()
          ..sort((a, b) {
            final al = a.path.contains('/story/lines/') ? 0 : 1;
            final bl = b.path.contains('/story/lines/') ? 0 : 1;
            return al != bl ? al - bl : a.path.compareTo(b.path);
          });
    for (final file in files) {
      if (pattern.hasMatch(file.readAsStringSync())) return file;
    }
    return null;
  }

  static String _slug(String input) => input
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');

  /// Inserts a dragged canvas cell before [slotIndex], shifting only that
  /// row's content to the right until the next gap. Existing gaps
  /// elsewhere are left alone.
  void insertCellAtSlot({
    required String pageId,
    required String cellId,
    required int rowIndex,
    required int slotIndex,
  }) {
    final page = pages.where((p) => p.id == pageId).firstOrNull;
    if (page == null || rowIndex < 0 || slotIndex < 0) return;
    final pageSlots = [
      for (final row in _pageSlots(page)) [...row],
    ];
    final width = pageSlots.fold<int>(
      0,
      (max, row) => row.length > max ? row.length : max,
    );
    while (rowIndex >= pageSlots.length) {
      pageSlots.add([for (var i = 0; i < width; i++) null]);
    }
    while (slotIndex >= pageSlots[rowIndex].length) {
      for (final row in pageSlots) {
        row.add(null);
      }
    }

    StudioSlot? moved;
    int? sourceRow;
    int? sourceSlot;
    for (final (r, row) in pageSlots.indexed) {
      final index = row.indexWhere(
        (c) => c?.id == cellId || c?.cellId == cellId,
      );
      if (index >= 0) {
        moved = row[index];
        sourceRow = r;
        sourceSlot = index;
        row[index] = null;
        break;
      }
    }
    if (moved == null || sourceRow == null || sourceSlot == null) return;
    if (sourceRow == rowIndex &&
        (sourceSlot == slotIndex || sourceSlot + 1 == slotIndex)) {
      return;
    }

    _slotUndo.add(_copySlots());
    if (_slotUndo.length > 100) _slotUndo.removeAt(0);

    final target = pageSlots[rowIndex];
    var gap = target.indexWhere((slot) => slot == null, slotIndex);
    if (gap < 0) {
      target.add(null);
      gap = target.length - 1;
    }
    for (var i = gap; i > slotIndex; i--) {
      target[i] = target[i - 1];
    }
    target[slotIndex] = moved;
    _storySlots[pageId] = pageSlots;
    notifyListeners();
  }

  /// Back-compat for tests and title drop targets: moves to the row's end.
  void moveCell({
    required String pageId,
    required String cellId,
    required int rowIndex,
    String? beforeCellId,
  }) {
    final page = pages.where((p) => p.id == pageId).firstOrNull;
    if (page == null || rowIndex < 0 || rowIndex >= slotRowCount(page)) return;
    final slots = slotsFor(page, rowIndex);
    final before = beforeCellId == null
        ? -1
        : slots.indexWhere(
            (c) => c?.id == beforeCellId || c?.cellId == beforeCellId,
          );
    moveCellToSlot(
      pageId: pageId,
      cellId: cellId,
      rowIndex: rowIndex,
      slotIndex: before >= 0 ? before : slots.length - 1,
    );
  }

  // --- picking a widget ---------------------------------------------------

  /// Whether Option is held: while down, clicks on a live card reach the
  /// mounted story instead of inspecting the widget under the pointer.
  bool altHeld = false;

  /// Whether Space is held: while down, canvas drags pan the surface.
  bool spaceHeld = false;

  /// Whether Command is held: while down, drags draw loose boxes.
  bool metaHeld = false;

  bool _watchingKeyboard = false;

  /// Starts tracking Option. Idempotent: the constructor calls it, and
  /// so does the canvas on hot reload, which never re-runs a constructor
  /// (Studio's own code reloads when it is a path dependency).
  void watchKeyboard() {
    if (_watchingKeyboard) return;
    _watchingKeyboard = true;
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  bool _onKey(KeyEvent event) {
    final keyboard = HardwareKeyboard.instance;
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.keyZ &&
        (keyboard.isControlPressed || keyboard.isMetaPressed)) {
      undoCanvas();
      return true;
    }
    final alt = keyboard.isAltPressed;
    final space = keyboard.isLogicalKeyPressed(LogicalKeyboardKey.space);
    final meta = keyboard.isMetaPressed;
    if (alt != altHeld || space != spaceHeld || meta != metaHeld) {
      altHeld = alt;
      spaceHeld = space;
      metaHeld = meta;
      notifyListeners();
    }
    return false;
  }

  /// The last inspected click: the widgets under it, nearest first, and
  /// which story's card it landed on. Cleared by selecting elsewhere or
  /// a reload (the tree is rebuilt, and lines move).
  WidgetPick? pick;
  String? pickStoryId;

  /// Which widget in [pick]'s chain is selected; starts at the nearest
  /// one written in the project.
  int pickIndex = 0;

  PickedWidget? get pickedWidget {
    final chain = pick?.chain;
    if (chain == null || pickIndex >= chain.length) return null;
    return chain[pickIndex];
  }

  /// The project and its path packages, for telling a story's widgets
  /// from a component's and both from the framework's.
  late final scopes = SourceScopes(
    project,
    packageRoots: TokenSet.packageRoots(project),
  );

  /// Picks the widget at [position] (in [root]'s coordinates) on story
  /// [id]'s card, and selects the story.
  void pickAt(String id, RenderObject root, Offset position) {
    selectedStoryId = id;
    selectedTokenGroup = null;
    pickStoryId = id;
    pick = pickWidgetAt(root, position, scopes);
    pickIndex = pick?.localIndex ?? 0;
    notifyListeners();
  }

  void setPickIndex(int index) {
    pickIndex = index;
    notifyListeners();
  }

  /// Moves the selection one project widget outward in the chain: the
  /// row above in the inspector. Stays put at the outermost.
  void pickParent() => _movePick(1);

  /// The row below: one project widget inward, towards what was clicked.
  void pickChild() => _movePick(-1);

  void _movePick(int step) {
    final chain = pick?.chain;
    if (chain == null) return;
    for (var i = pickIndex + step; i >= 0 && i < chain.length; i += step) {
      if (chain[i].isLocal) {
        pickIndex = i;
        notifyListeners();
        return;
      }
    }
  }

  void clearPick() {
    if (pick == null) return;
    pick = null;
    notifyListeners();
  }

  /// Opens [widget]'s line in the editor `FLUTTER_STATIC_EDITOR` names
  /// (`{file}`, `{line}` and `{column}` placeholders), VS Code's
  /// `code -g` when unset.
  Future<void> openInEditor(PickedWidget widget) async {
    final location = widget.location;
    if (location == null) return;
    final template =
        Platform.environment['FLUTTER_STATIC_EDITOR'] ??
        'code -g {file}:{line}:{column}';
    final parts = [
      for (final part in template.trim().split(RegExp(r'\s+')))
        part
            .replaceAll('{file}', location.file)
            .replaceAll('{line}', '${location.line}')
            .replaceAll('{column}', '${location.column}'),
    ];
    try {
      final result = await Process.run(parts.first, parts.skip(1).toList());
      if (result.exitCode != 0) log('editor: ${result.stderr}'.trim());
    } on ProcessException catch (e) {
      log('editor: ${e.message}; set FLUTTER_STATIC_EDITOR');
    }
  }

  void selectTokenGroup(String? name) {
    selectedTokenGroup = name;
    notifyListeners();
  }

  void setDevice(String? name) {
    device = name;
    notifyListeners();
  }

  void setStatusBar(bool on) {
    statusBar = on;
    notifyListeners();
  }

  void setKnob(String knob, String option) {
    knobs[knob] = option;
    notifyListeners();
  }

  void setPromptPanelOpen(bool open) {
    if (promptPanelOpen == open) return;
    promptPanelOpen = open;
    _saveStudioState();
    notifyListeners();
  }

  void setInspectorPanelOpen(bool open) {
    if (inspectorPanelOpen == open) return;
    inspectorPanelOpen = open;
    _saveStudioState();
    notifyListeners();
  }

  void setChromePanelsOpen({required bool prompt, required bool inspector}) {
    if (promptPanelOpen == prompt && inspectorPanelOpen == inspector) return;
    promptPanelOpen = prompt;
    inspectorPanelOpen = inspector;
    _saveStudioState();
    notifyListeners();
  }

  void toggleLogs() {
    showLogs = !showLogs;
    _saveStudioState();
    notifyListeners();
  }

  void toggleLive() {
    live = !live;
    notifyListeners();
  }

  void toggleInteract() {
    interact = !interact;
    notifyListeners();
  }

  void toggleRenderOnly(String id) {
    renderOnly.contains(id) ? renderOnly.remove(id) : renderOnly.add(id);
    notifyListeners();
  }

  // --- live mounts --------------------------------------------------------

  /// Whether [id] mounts live: [live] is on, the story is not forced to
  /// render, and its first capture found a shell the canvas can host.
  /// Null until that capture has happened.
  bool? isLive(String id) {
    if (!live || renderOnly.contains(id)) return false;
    return switch (storyShellOf(id)) {
      null => null,
      StoryShell.window => false,
      _ => true,
    };
  }

  /// The story's widget in the catalog's environment, built fresh on
  /// every rebuild so hot reload reaches it.
  Widget mount(String id) => Builder(
    builder: (context) {
      final story = findStory(stories, id);
      if (story == null) return const SizedBox.shrink();
      final bounded = storyShellOf(id) == StoryShell.bounded;
      try {
        return storyEnvironment(
          storyOnPage(
            story,
            device: deviceSpec,
            statusBar: statusBar,
            knobs: knobs,
          ),
          bounded: bounded,
        );
      } catch (e) {
        return ErrorWidget.withDetails(message: '$id: $e');
      }
    },
  );

  // --- renders ------------------------------------------------------------

  /// What a render depends on: a card whose render has a different key
  /// shows it, stale, while the current one captures.
  String get _renderKey =>
      '$version|$device|$statusBar|${knobs.entries.map((e) => '${e.key}=${e.value}').join(',')}';

  /// The latest render of [id], capturing a fresh one when it is behind
  /// [version] or the render options. Returns the stale one meanwhile so
  /// cards keep their size and their last screen.
  StoryRender? render(String id) {
    final cached = _renders[id];
    if (cached == null || cached.key != _renderKey) _fetch(id);
    return cached;
  }

  /// A background capture of [id], so the catalog learns its shell and a
  /// live card can replace the placeholder. Never joins the hot set.
  void discover(String id) {
    if (storyShellOf(id) == null) _fetch(id, background: true);
  }

  bool isFetching(String id) => _inflight.contains(id);

  void _fetch(String id, {bool background = false}) {
    if (_inflight.contains(id)) return;
    _inflight.add(id);
    final key = _renderKey;
    renderStoryImage(
          stories,
          id,
          device: deviceSpec,
          statusBar: statusBar,
          knobs: Map.of(knobs),
          background: background,
        )
        .then((image) {
          if (_disposed) {
            image.dispose();
            return;
          }
          final old = _renders[id];
          if (old != null) _retired.add(old);
          _renders[id] = StoryRender(image, key);
          noteSize(id, Size(image.width / 2, image.height / 2));
        })
        .catchError((Object e) {
          if (!_disposed) log('render $id: $e');
        })
        .whenComplete(() {
          if (_disposed) return;
          _inflight.remove(id);
          _notifySoon();
        });
  }

  /// Marks a render stale so the next paint captures it again, keeping
  /// the old one on screen meanwhile.
  void rerender(String id) {
    final old = _renders[id];
    if (old != null) _renders[id] = StoryRender(old.image, 'stale');
    notifyListeners();
  }

  // --- sizes --------------------------------------------------------------

  /// Every story's last known size, so a placeholder or a card whose
  /// render is on its way takes the room the story took last time and
  /// the canvas does not shift. Kept in .dart_tool across sessions.
  final _sizes = <String, Size>{};
  Timer? _sizesSave;

  File get _studioStateFile =>
      File('$project/.dart_tool/flutter_static_studio.json');

  Size? sizeOf(String id) => _sizes[id];

  /// The size a card takes before its content is known: the story's
  /// last size, else the device mockup on a flow page, else a card.
  Size placeholderSize(String id) {
    final known = _sizes[id];
    if (known != null) return known;
    if (selectedPage?.isLine == true) {
      return PhoneMockup(
        spec: deviceSpec ?? PhoneSpec.fallback,
        child: const SizedBox.shrink(),
      ).size;
    }
    return const Size(390, 240);
  }

  void noteSize(String id, Size size) {
    if (_sizes[id] == size) return;
    _sizes[id] = size;
    _sizesSave?.cancel();
    _sizesSave = Timer(const Duration(seconds: 1), _saveSizes);
  }

  void _loadStudioState() {
    try {
      if (!_studioStateFile.existsSync()) return;
      final json = jsonDecode(_studioStateFile.readAsStringSync()) as Map;
      final sizes = json['sizes'];
      if (sizes is Map) {
        for (final entry in sizes.entries) {
          final wh = (entry.value as List).cast<num>();
          _sizes[entry.key as String] = Size(
            wh[0].toDouble(),
            wh[1].toDouble(),
          );
        }
      }
      final panels = json['panels'];
      if (panels is Map) {
        promptPanelOpen = panels['prompt'] as bool? ?? promptPanelOpen;
        inspectorPanelOpen = panels['inspector'] as bool? ?? inspectorPanelOpen;
        showLogs = panels['logs'] as bool? ?? showLogs;
      }
      final herdr = json['herdr'];
      if (herdr is Map) herdrPaneId = herdr['pane'] as String?;
    } catch (e) {
      log('studio state: $e');
    }
  }

  void _saveSizes() => _saveStudioState();

  void _saveStudioState() {
    try {
      _studioStateFile.parent.createSync(recursive: true);
      _studioStateFile.writeAsStringSync(
        jsonEncode({
          'sizes': {
            for (final e in _sizes.entries)
              e.key: [e.value.width, e.value.height],
          },
          'panels': {
            'prompt': promptPanelOpen,
            'inspector': inspectorPanelOpen,
            'logs': showLogs,
          },
          if (herdrPaneId != null) 'herdr': {'pane': herdrPaneId},
        }),
      );
    } catch (e) {
      log('studio state: $e');
    }
  }

  // --- tokens -------------------------------------------------------------

  void loadTokens() {
    try {
      tokens = TokenSet.load(project);
    } catch (e) {
      log('tokens: $e');
    }
    notifyListeners();
  }

  /// Writes [expression] as [token]'s value and re-parses the project's
  /// tokens so spans stay right for the next edit. The CLI's watcher sees
  /// the save and hot reloads this process.
  void setToken(DesignToken token, String expression) {
    try {
      writeToken(token, expression);
      tokens = TokenSet.load(project);
    } catch (e) {
      log('write ${token.id}: $e');
    }
    notifyListeners();
  }

  void setTokenArg(DesignToken token, String arg, String value) {
    try {
      writeTokenArg(token, arg, value);
      tokens = TokenSet.load(project);
    } catch (e) {
      log('write ${token.id}.$arg: $e');
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _sizesSave?.cancel();
    for (final render in _renders.values) {
      render.dispose();
    }
    _renders.clear();
    for (final render in _retired) {
      render.dispose();
    }
    _retired.clear();
    HardwareKeyboard.instance.removeHandler(_onKey);
    catalogVersion.removeListener(_onVersion);
    catalogReloadTick.removeListener(notifyListeners);
    super.dispose();
  }
}
