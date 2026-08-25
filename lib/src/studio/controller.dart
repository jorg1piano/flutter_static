/// Studio's state, in the catalog's own process: the pages derived from
/// the [Stories], live mounts and PNG renders through the catalog's
/// public API, reload state from its notifiers, and the project's
/// tokens. One [ChangeNotifier]; the views rebuild off it.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../phone_mockup.dart';
import '../server_io.dart';
import '../story.dart';
import '../tokens.dart';
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
    notifyListeners();
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
    catalogVersion.removeListener(_onVersion);
    catalogReloadTick.removeListener(notifyListeners);
    super.dispose();
  }
}
