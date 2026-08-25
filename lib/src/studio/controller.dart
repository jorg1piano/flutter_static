/// Studio's state, in the catalog's own process: the pages derived from
/// the [Stories], live mounts and PNG renders through the catalog's
/// public API, reload state from its notifiers, and the project's
/// tokens. One [ChangeNotifier]; the views rebuild off it.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../phone_mockup.dart';
import '../server_io.dart';
import '../story.dart';
import '../tokens.dart';
import 'model.dart';

enum CatalogStatus { ready, reloading, error }

/// One fetched render, with the version it was captured at.
class StoryPng {
  const StoryPng(this.bytes, this.version);

  final Uint8List bytes;
  final int version;
}

class StudioController extends ChangeNotifier {
  StudioController({
    required this.stories,
    required this.project,
    required this.port,
  }) {
    catalogVersion.addListener(_onVersion);
    catalogReloadTick.addListener(notifyListeners);
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

  /// Whether pointer events reach the mounted widgets (else a click
  /// selects the card).
  bool interact = false;

  /// Stories shown as renders even while [live] is on.
  final renderOnly = <String>{};

  final _pngs = <String, StoryPng>{};
  final _inflight = <String>{};
  bool _disposed = false;

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
    _pngs.clear();
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
    _pngs.clear();
    notifyListeners();
  }

  void setStatusBar(bool on) {
    statusBar = on;
    _pngs.clear();
    notifyListeners();
  }

  void setKnob(String knob, String option) {
    knobs[knob] = option;
    _pngs.clear();
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

  /// The latest render of [id], capturing a fresh one when it is behind
  /// [version]. Returns the stale one meanwhile so cards never blank.
  StoryPng? png(String id) {
    final cached = _pngs[id];
    if (cached == null || cached.version != version) _fetch(id);
    return cached;
  }

  bool isFetching(String id) => _inflight.contains(id);

  void _fetch(String id) {
    if (_inflight.contains(id)) return;
    _inflight.add(id);
    final wanted = version;
    renderStoryPng(
          stories,
          id,
          device: deviceSpec,
          statusBar: statusBar,
          knobs: Map.of(knobs),
        )
        .then((bytes) {
          if (_disposed) return;
          _pngs[id] = StoryPng(bytes, wanted);
        })
        .catchError((Object e) {
          if (!_disposed) log('render $id: $e');
        })
        .whenComplete(() {
          if (_disposed) return;
          _inflight.remove(id);
          notifyListeners();
        });
  }

  /// Drops a render so the next paint captures it again.
  void rerender(String id) {
    _pngs.remove(id);
    notifyListeners();
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
    catalogVersion.removeListener(_onVersion);
    catalogReloadTick.removeListener(notifyListeners);
    super.dispose();
  }
}
