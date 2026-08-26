/// Studio's state, in the catalog's own process: the pages derived from
/// the [Stories], live mounts and PNG renders through the catalog's
/// public API, reload state from its notifiers, and the project's
/// tokens. One [ChangeNotifier]; the views rebuild off it.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../phone_mockup.dart';
import '../server_io.dart';
import '../story.dart';
import '../tokens.dart';
import '../widget_pick.dart';
import 'model.dart';

enum CatalogStatus { ready, reloading, error }

/// One fetched render, with the version and options it was captured at.
class StoryPng {
  const StoryPng(this.bytes, this.key);

  final Uint8List bytes;

  /// Version plus render options; a different key means stale.
  final String key;
}

class StudioController extends ChangeNotifier {
  StudioController({
    required this.stories,
    required this.project,
    required this.port,
  }) {
    catalogVersion.addListener(_onVersion);
    catalogReloadTick.addListener(notifyListeners);
    HardwareKeyboard.instance.addHandler(_onKey);
    _loadSizes();
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

  List<StudioPage> pages = const [];
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

  /// Whether pointer events reach the mounted widgets, which a pointer
  /// down also selects; off, a click only selects the card.
  bool interact = true;

  /// Stories shown as renders even while [live] is on.
  final renderOnly = <String>{};

  final _pngs = <String, StoryPng>{};
  final _inflight = <String>{};
  bool _disposed = false;
  bool _notifyScheduled = false;

  /// One notification per frame however many captures land in it: every
  /// notification rebuilds the whole page of live cards.
  void _notifySoon() {
    if (_notifyScheduled || _disposed) return;
    _notifyScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _notifyScheduled = false;
      if (!_disposed) notifyListeners();
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  /// What the agent should know before a turn: where it is, what the
  /// user is looking at, and how to check its work without touching the
  /// process it is talking to.
  String agentContext({bool withSelection = true}) {
    final page = withSelection ? selectedPage : null;
    final story = withSelection ? selectedStoryId : null;
    final knobArgs = knobs.entries.map((e) => ' -k ${e.key}=${e.value}').join();
    return [
      'You are working inside Flutter Static Studio on the Flutter project '
          'at $project. Its story catalog is this very process, live at '
          '$url, and it hot reloads every save under lib/, story/ and the '
          'path packages. Never run `flutter_static up`, `run`, `down` or '
          '`studio`; the catalog is already running.',
      'Check your work by rendering: `dart run flutter_static render '
          '<story id> -o /tmp/<name>.png` (run from the project), then read '
          'the PNG. `dart run flutter_static list` lists story ids; '
          '`dart run flutter_static tokens list` lists design tokens '
          '(static consts in lib/**/tokens/*.dart), and `dart run '
          'flutter_static tokens set <Group.name> <value>` edits one.',
      'Prefer changing tokens and components over one-off values: the '
          'design system lives in the path packages under packages/, the '
          'stories in story/. Keep answers to a few sentences; the user '
          'sees the result on the canvas.',
      if (!withSelection) ...[
        'When the user clicks a story on the canvas its id is typed into '
            'this terminal in backticks, like `buttons/kinds`; a request '
            'after such an id is about that story.',
        'When the user Option-clicks a widget on the canvas its source '
            'position is typed in backticks, like '
            '`story/stories/buttons.dart:13:11`: the file, line and column '
            'where that widget is constructed. A request after one is '
            'about that widget; edit that call to change what it shows, '
            'and its class to change how it looks. '
            '`dart run flutter_static inspect <story id> --at X,Y` (PNG '
            'pixels) tells which widgets and lines made a point in a '
            'render you are looking at.',
      ],
      if (page != null)
        'The user is looking at the page "${page.title}" (${page.id}).',
      if (story != null)
        'The selected story is `$story`; its render command is '
            '`dart run flutter_static render $story$knobArgs`. Requests '
            'that do not name a story are about this one.',
      ?_pickContext(),
    ].join('\n');
  }

  /// The Option-clicked widget, for the agent: the project's widgets from
  /// the clicked one outward, each with its source line.
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
      'The user Option-clicked a widget on the canvas and selected '
          '${line(picked)}. Requests about "this", "it" or "the selected '
          'widget" mean that one; the line is where it is constructed, so '
          'edit that call to change what it shows and its own class to '
          'change how it looks.',
      if (outward.isNotEmpty)
        'The project\'s widgets around it, from the selection outward: '
            '${outward.join('; ')}.',
    ].join(' ');
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

  // --- picking a widget ---------------------------------------------------

  /// Whether Option is held: a click on a live card then picks the widget
  /// under the pointer instead of reaching it or selecting the card.
  bool altHeld = false;

  bool _onKey(KeyEvent event) {
    final alt = HardwareKeyboard.instance.isAltPressed;
    if (alt != altHeld) {
      altHeld = alt;
      notifyListeners();
    }
    return false;
  }

  /// The last Option-click: the widgets under it, nearest first, and
  /// which story's card it landed on. Cleared by a plain click or a
  /// reload (the tree is rebuilt, and lines move).
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

  void toggleLogs() {
    showLogs = !showLogs;
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
  StoryPng? png(String id) {
    final cached = _pngs[id];
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
    renderStoryPng(
          stories,
          id,
          device: deviceSpec,
          statusBar: statusBar,
          knobs: Map.of(knobs),
          background: background,
        )
        .then((bytes) {
          if (_disposed) return;
          _pngs[id] = StoryPng(bytes, key);
          final size = _pngSize(bytes);
          if (size != null) noteSize(id, size);
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
    final old = _pngs[id];
    if (old != null) _pngs[id] = StoryPng(old.bytes, 'stale');
    notifyListeners();
  }

  // --- sizes --------------------------------------------------------------

  /// Every story's last known size, so a placeholder or a card whose
  /// render is on its way takes the room the story took last time and
  /// the canvas does not shift. Kept in .dart_tool across sessions.
  final _sizes = <String, Size>{};
  Timer? _sizesSave;

  File get _sizesFile => File('$project/.dart_tool/flutter_static_studio.json');

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

  void _loadSizes() {
    try {
      if (!_sizesFile.existsSync()) return;
      final json = jsonDecode(_sizesFile.readAsStringSync()) as Map;
      for (final entry in (json['sizes'] as Map).entries) {
        final wh = (entry.value as List).cast<num>();
        _sizes[entry.key as String] = Size(wh[0].toDouble(), wh[1].toDouble());
      }
    } catch (e) {
      log('sizes: $e');
    }
  }

  void _saveSizes() {
    try {
      _sizesFile.parent.createSync(recursive: true);
      _sizesFile.writeAsStringSync(
        jsonEncode({
          'sizes': {
            for (final e in _sizes.entries)
              e.key: [e.value.width, e.value.height],
          },
        }),
      );
    } catch (e) {
      log('sizes: $e');
    }
  }

  /// Logical size of a 2x PNG from its header, or null.
  static Size? _pngSize(Uint8List bytes) {
    if (bytes.length < 24) return null;
    final data = ByteData.sublistView(bytes, 16, 24);
    return Size(data.getUint32(0) / 2, data.getUint32(4) / 2);
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
    HardwareKeyboard.instance.removeHandler(_onKey);
    catalogVersion.removeListener(_onVersion);
    catalogReloadTick.removeListener(notifyListeners);
    super.dispose();
  }
}
