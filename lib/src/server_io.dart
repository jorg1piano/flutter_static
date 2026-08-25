import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'phone_mockup.dart';
import 'story.dart';
import 'package:flutter/rendering.dart';

/// Port, overridable at build time (flutter_static run --port passes it
/// as a dart-define).
const _catalogPort = int.fromEnvironment(
  'FLUTTER_STATIC_PORT',
  defaultValue: 8474,
);

void runFlutterStatic(Stories stories, {int port = _catalogPort}) {
  debugDefaultTargetPlatformOverride = stories.platform;
  runApp(_CatalogApp(stories: stories));
  _serve(stories, port);
  _prewarm(stories);
}

/// Renders every story into the cache in the background so user-facing
/// requests rarely pay a cold render. Yields between stories to keep the
/// server responsive; exits early when superseded by a newer reload.
void _prewarm(Stories stories) {
  final version = _version;
  Future(() async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    // Phase 1: everything that can render offscreen does; stories that
    // need the window fail in milliseconds and are only collected.
    final windowBound = <Story>[];
    for (final story in stories.all()) {
      if (_version != version) return;
      // Let interactive requests drain first; warming is idle work.
      while (_foregroundWaiters > 0) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        if (_version != version) return;
      }
      try {
        await _renderCached(story, background: true, offscreenOnly: true);
      } catch (_) {
        windowBound.add(story);
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    // Phase 2: mount the whole window batch at once - one Stack rebuild,
    // one settle - then snapshot each.
    if (windowBound.isEmpty) return;
    _mountWindowStories(windowBound);
    for (final story in windowBound) {
      if (_version != version) return;
      while (_foregroundWaiters > 0) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        if (_version != version) return;
      }
      try {
        await _renderCached(story, background: true);
      } catch (_) {}
    }
  });
}

/// Stories mounted in the window's Stack (the ones that need a real View).
/// Each paints into its own RepaintBoundary layer, so any of them can be
/// snapshotted regardless of stacking order. Mounts persist across reloads:
/// reassemble preserves State, so entrance animations never replay and the
/// one-time settle stays paid.
final _windowStories = ValueNotifier<List<Story>>([]);
final _windowKeys = <String, GlobalKey>{};
Future<void>? _windowSettled;

void _mountWindowStories(Iterable<Story> stories) {
  final added = <Story>[];
  for (final story in stories) {
    if (_windowKeys.containsKey(story.id)) continue;
    _windowKeys[story.id] = GlobalKey();
    added.add(story);
  }
  if (added.isEmpty) return;
  // One Stack rebuild and one settle for the whole batch.
  _windowStories.value = [..._windowStories.value, ...added];
  _windowSettled = null;
}

void _mountWindowStory(Story story) => _mountWindowStories([story]);

int _version = 0;

String _eventData() => '{"version": $_version}';

void _broadcastEvent() {
  for (final client in _eventClients) {
    try {
      client.write('data: ${_eventData()}\n\n');
      client.flush();
    } catch (_) {
      // Dead client; removed by its done handler.
    }
  }
}

final _renderCache = <String, Uint8List>{};
int _renderCacheVersion = -1;
String _lastTrace = '';
final List<String> _traceLines = [];
void _traceLog(String line) {
  final ts = DateTime.now().toIso8601String().substring(11, 23);
  _traceLines.add('$ts $line');
  if (_traceLines.length > 500) _traceLines.removeAt(0);
}

final _eventClients = <HttpResponse>[];

class _CatalogApp extends StatefulWidget {
  const _CatalogApp({required this.stories});

  final Stories stories;

  @override
  State<_CatalogApp> createState() => _CatalogAppState();
}

class _CatalogAppState extends State<_CatalogApp> {
  @override
  void reassemble() {
    super.reassemble();
    // Re-read on every reload: main() never runs again, the getter does.
    debugDefaultTargetPlatformOverride = widget.stories.platform;
    _version++;
    _prewarm(widget.stories);
    _broadcastEvent();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: Center(
          child: ValueListenableBuilder<List<Story>>(
            valueListenable: _windowStories,
            builder: (context, mounted, _) {
              if (mounted.isEmpty) return const Text('flutter_static');
              return Stack(
                alignment: Alignment.center,
                children: [
                  for (final story in mounted)
                    // Window-mounted stories are app screens (they embed
                    // MaterialApp, which requires BOUNDED constraints - in
                    // an unbounded OverflowBox its layout fails and the
                    // broken render tree poisons every later window frame,
                    // which offscreen captures also flush when pumping).
                    OverflowBox(
                      minWidth: 0,
                      minHeight: 0,
                      maxWidth: 430,
                      maxHeight: 932,
                      alignment: Alignment.center,
                      child: RepaintBoundary(
                        key: _windowKeys[story.id],
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(
                            maxWidth: 430,
                            maxHeight: 932,
                          ),
                          child: story.builder(),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

Future<void> _serve(Stories stories, int port) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
  debugPrint('flutter_static serving on http://localhost:$port');
  await for (final request in server) {
    // Handle concurrently: only captures are serialized (one window), so
    // cache hits and static routes never queue behind a slow render.
    unawaited(_handleRequest(request, stories));
  }
}

/// Chains captures one after another; the shared window can only show one
/// story at a time.
Future<void>? _captureQueue;

/// Foreground (browser/CLI) renders waiting in the queue; the prewarmer
/// yields to them.
int _foregroundWaiters = 0;

Future<Uint8List> _renderCached(
  Story story, {
  bool background = false,
  bool offscreenOnly = false,
}) {
  if (_renderCacheVersion == _version) {
    final hit = _renderCache[story.id];
    if (hit != null) return Future.value(hit);
  }
  if (!background) _foregroundWaiters++;
  final previous = _captureQueue ?? Future<void>.value();
  final completer = Completer<void>();
  _captureQueue = completer.future;
  return previous.then((_) async {
    try {
      if (_renderCacheVersion != _version) {
        _renderCache.clear();
        _renderCacheVersion = _version;
      }
      return _renderCache[story.id] ??= await _capture(
        story,
        offscreenOnly: offscreenOnly,
      );
    } finally {
      if (!background) _foregroundWaiters--;
      completer.complete();
    }
  });
}

Future<void> _handleRequest(HttpRequest request, Stories stories) async {
  {
    final response = request.response;
    final path = request.uri.path;
    // Renders change on every hot reload; never let browsers cache them.
    response.headers.set('Cache-Control', 'no-store');
    try {
      if (path == '/index.json') {
        response.headers.contentType = ContentType.json;
        response.write(
          jsonEncode({
            'version': _version,
            'stories': [
              for (final s in stories.all())
                {'id': s.id, 'png': '/story/${s.id}.png'},
            ],
          }),
        );
        await response.close();
      } else if (path == '/' || path == '/index.html') {
        response.headers.contentType = ContentType.html;
        _isolate(response);
        response.write(
          _galleryPage(
            stories.all(),
            null,
            liveBuild: _liveBuildExists(),
            lines: stories.storylines(),
          ),
        );
        await response.close();
      } else if (path == '/trace') {
        response.headers.contentType = ContentType.text;
        response.write(_traceLines.join('\n'));
        await response.close();
      } else if (path == '/events') {
        response.bufferOutput = false;
        response.headers.contentType = ContentType('text', 'event-stream');
        response.headers.set('Cache-Control', 'no-cache');
        response.write('data: ${_eventData()}\n\n');
        response.flush();
        _eventClients.add(response);
        response.done.whenComplete(() => _eventClients.remove(response));
      } else if (path.startsWith('/story/') && path.endsWith('.png')) {
        final id = path.substring(
          '/story/'.length,
          path.length - '.png'.length,
        );
        final matches = stories.all().where((s) => s.id == id);
        if (matches.isEmpty) {
          response.statusCode = HttpStatus.notFound;
          await response.close();
        } else {
          // Renders are pure per (story, device, reload version): cached,
          // and capture work is serialized behind _captureQueue.
          final device = PhoneSpec.byName(
            request.uri.queryParameters['device'],
          );
          final statusBar = request.uri.queryParameters['status'] == '1';
          final story = device == null && !statusBar
              ? matches.first
              : _onDevice(
                  matches.first,
                  device ?? PhoneSpec.fallback,
                  statusBar: statusBar,
                );
          final png = await _renderCached(story);
          response.headers.set('x-render-trace', _lastTrace);
          response.headers.contentType = ContentType('image', 'png');
          response.add(png);
          await response.close();
        }
      } else if (path.startsWith('/story/') && !path.endsWith('.png')) {
        final id = Uri.decodeComponent(path.substring('/story/'.length));
        final all = stories.all();
        final index = all.indexWhere((s) => s.id == id);
        if (index == -1) {
          response.statusCode = HttpStatus.notFound;
          await response.close();
        } else {
          response.headers.contentType = ContentType.html;
          _isolate(response);
          final inLine = stories.storylines().any(
            (line) => line.stories.any((s) => s.id == id),
          );
          response.write(
            _storyDetailPage(
              all,
              index,
              device: PhoneSpec.byName(request.uri.queryParameters['device']),
              statusBar: request.uri.queryParameters['status'] == '1',
              showDevices: inLine,
            ),
          );
          await response.close();
        }
      } else if (path.startsWith('/line/')) {
        final id = Uri.decodeComponent(path.substring('/line/'.length));
        final lines = stories.storylines().where((l) => l.id == id);
        if (lines.isEmpty) {
          response.statusCode = HttpStatus.notFound;
          await response.close();
        } else {
          response.headers.contentType = ContentType.html;
          _isolate(response);
          response.write(_linePage(lines.first, liveBuild: _liveBuildExists()));
          await response.close();
        }
      } else if (path.startsWith('/live/') || path == '/live') {
        final rel = path == '/live' ? '' : path.substring('/live/'.length);
        final root = _projectRoot();
        final file = root == null
            ? null
            : File('$root/build/web/${rel.isEmpty ? 'index.html' : rel}');
        if (file == null || !file.existsSync()) {
          response.statusCode = HttpStatus.notFound;
          response.write('no web build - run: flutter_static build-web');
          await response.close();
        } else {
          response.headers.contentType = _mimeFor(file.path);
          response.headers.set('Cross-Origin-Opener-Policy', 'same-origin');
          response.headers.set('Cross-Origin-Embedder-Policy', 'require-corp');
          await response.addStream(file.openRead());
          await response.close();
        }
      } else if (_groupFor(path, stories) != null) {
        response.headers.contentType = ContentType.html;
        _isolate(response);
        response.write(
          _galleryPage(
            stories.all(),
            _groupFor(path, stories),
            liveBuild: _liveBuildExists(),
          ),
        );
        await response.close();
      } else {
        response.statusCode = HttpStatus.notFound;
        await response.close();
      }
    } catch (e) {
      try {
        response.statusCode = HttpStatus.internalServerError;
        response.write('$e');
        await response.close();
      } catch (_) {}
    }
  }
}

/// Stories that need the real window (e.g. they embed a MaterialApp, whose
/// View.of has no answer in an offscreen tree). Routed directly on later
/// renders instead of re-attempting offscreen.
final _needsWindow = <String>{};

/// The static web build (flutter_static build-web) that /live/ serves; the
/// pages mount stories from it as live views.
bool _liveBuildExists() {
  final root = _projectRoot();
  return root != null &&
      File('$root/build/web/flutter_bootstrap.js').existsSync();
}

/// [story] rendered for [device], with or without the status bar: the
/// frame builders read the scope. A distinct id keeps the render cache
/// per combination.
Story _onDevice(Story story, PhoneSpec device, {bool statusBar = false}) =>
    Story(
      '${story.id}@${device.name}${statusBar ? '+status' : ''}',
      () => DeviceScope(
        spec: device,
        statusBar: statusBar,
        child: story.builder(),
      ),
    );

/// The device and status-bar toggles for pages of storyline variants.
String _deviceToolbar({
  String? selected,
  bool statusBar = false,
  bool links = false,
}) {
  final buffer = StringBuffer('<div class="toolbar"><span>Enhet</span>');
  final device = selected ?? PhoneSpec.all.first.name;
  final status = statusBar ? '&status=1' : '';
  for (final spec in PhoneSpec.all) {
    final cls = spec.name == device ? 'device on' : 'device';
    buffer.write(
      links
          ? '<a class="$cls" href="?device=${spec.name}$status">${_escape(spec.label)}</a>'
          : '<button class="$cls" data-device="${spec.name}">${_escape(spec.label)}</button>',
    );
  }
  buffer.write('<span class="sep">Statuslinje</span>');
  for (final (value, label) in [('1', 'P&aring;'), ('0', 'Av')]) {
    final cls = (value == '1') == statusBar ? 'status on' : 'status';
    buffer.write(
      links
          ? '<a class="$cls" href="?device=$device${value == '1' ? '&status=1' : ''}">$label</a>'
          : '<button class="$cls" data-status="$value">$label</button>',
    );
  }
  buffer.write('</div>');
  return buffer.toString();
}

/// Cross-origin isolation: the wasm build's engine needs it on the page
/// that embeds it.
void _isolate(HttpResponse response) {
  response.headers.set('Cross-Origin-Opener-Policy', 'same-origin');
  response.headers.set('Cross-Origin-Embedder-Policy', 'require-corp');
}

/// The consumer project root, derived from the debug binary's location
/// (`<project>/build/macos/.../app`); the server process's cwd is not the
/// project.
String? _projectRootCache;
String? _projectRoot() {
  if (_projectRootCache != null) return _projectRootCache;
  var dir = File(Platform.resolvedExecutable).parent;
  while (dir.path != dir.parent.path) {
    if (File('${dir.path}/pubspec.yaml').existsSync()) {
      return _projectRootCache = dir.path;
    }
    dir = dir.parent;
  }
  return null;
}

ContentType _mimeFor(String path) {
  final ext = path.split('.').last.toLowerCase();
  switch (ext) {
    case 'html':
      return ContentType.html;
    case 'js':
    case 'mjs':
      return ContentType('text', 'javascript');
    case 'wasm':
      return ContentType('application', 'wasm');
    case 'json':
      return ContentType.json;
    case 'png':
      return ContentType('image', 'png');
    case 'ttf':
    case 'otf':
      return ContentType('font', ext);
    default:
      return ContentType('application', 'octet-stream');
  }
}

Future<Uint8List> _capture(Story story, {bool offscreenOnly = false}) async {
  if (_needsWindow.contains(story.id)) {
    if (offscreenOnly) throw StateError('needs window');
    return _captureOnWindow(story);
  }
  try {
    return await _captureOffscreen(story);
  } catch (e, st) {
    _needsWindow.add(story.id);
    final where = st.toString().split('\n').take(4).join(' | ');
    _lastTrace = 'FALLBACK ${story.id}: $e @ $where';
    _traceLog(_lastTrace);
    if (offscreenOnly) rethrow;
    debugPrint(
      'flutter_static: offscreen capture failed for ${story.id} ($e); '
      'falling back to window capture',
    );
    return _captureOnWindow(story);
  }
}

/// Renders [story] in its own offscreen render tree: no shared window, no
/// vsync, and animations advance on synthetic timestamps instead of
/// wall-clock time, so even infinitely-animating stories capture in tens of
/// milliseconds.
RenderRepaintBoundary? _findBoundary(RenderObject node) {
  if (node is RenderRepaintBoundary) return node;
  RenderRepaintBoundary? result;
  node.visitChildren((child) {
    result ??= _findBoundary(child);
  });
  return result;
}

Future<Uint8List> _captureOffscreen(Story story) async {
  final binding = WidgetsBinding.instance;
  final theme = ThemeData();

  final container = RenderPositionedBox(alignment: Alignment.topLeft);
  final renderView = RenderView(
    view: binding.platformDispatcher.implicitView!,
    configuration: const ViewConfiguration(
      // Phone-plus headroom: expanding widgets fill this, and anything
      // larger explodes rasterization cost (the 4096x8192 canvas meant
      // 51s captures for stories with fill-width content).
      logicalConstraints: BoxConstraints(maxWidth: 1600, maxHeight: 3200),
      devicePixelRatio: 2,
    ),
    child: container,
  );
  final pipelineOwner = PipelineOwner();
  final buildOwner = BuildOwner(focusManager: FocusManager());
  pipelineOwner.rootNode = renderView;
  renderView.prepareInitialFrame();

  // Unbounded like the window's OverflowBox: Column(mainAxisSize.max)
  // shrink-wraps under unbounded constraints but inflates to any bound,
  // so bounded-loose canvases turned every card into a 932px giant.
  Widget shell(Widget inner, {required bool unbounded}) => MediaQuery(
    data: const MediaQueryData(size: Size(430, 932), devicePixelRatio: 2),
    child: Localizations(
      locale: const Locale('en'),
      delegates: const [
        DefaultWidgetsLocalizations.delegate,
        DefaultMaterialLocalizations.delegate,
      ],
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Theme(
          data: theme,
          child: DefaultTextStyle(
            style: theme.textTheme.bodyMedium!,
            child: Material(
              type: MaterialType.transparency,
              child: unbounded
                  ? OverflowBox(
                      minWidth: 0,
                      minHeight: 0,
                      maxWidth: double.infinity,
                      maxHeight: double.infinity,
                      alignment: Alignment.topLeft,
                      child: RepaintBoundary(child: inner),
                    )
                  : RepaintBoundary(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(
                          maxWidth: 430,
                          maxHeight: 932,
                        ),
                        child: inner,
                      ),
                    ),
            ),
          ),
        ),
      ),
    ),
  );

  final root = RenderObjectToWidgetAdapter<RenderBox>(
    container: container,
    child: shell(story.builder(), unbounded: true),
  ).attachToRenderTree(buildOwner);

  // Painting is the expensive pass for complex stories, so the pump loop
  // only builds and lays out; paint happens exactly once, at capture.
  void pump() {
    buildOwner.buildScope(root);
    buildOwner.finalizeTree();
    pipelineOwner.flushLayout();
  }

  final sw = Stopwatch()..start();
  final trace = StringBuffer();
  void mark(String label) {
    trace.write('$label=${sw.elapsedMilliseconds}ms ');
    sw.reset();
  }

  final baselineTickers = binding.transientCallbackCount;

  try {
    var unboundedOk = true;
    try {
      pump();
      final size = _findBoundary(container)?.size;
      unboundedOk =
          size != null &&
          size.isFinite &&
          size.width <= 1600 &&
          size.height <= 3200;
    } catch (_) {
      unboundedOk = false;
    }
    mark('first-pump');
    if (!unboundedOk) {
      // Stories that can't lay out unbounded (fill-style sizing) get the
      // phone-bounded shell instead.
      RenderObjectToWidgetAdapter<RenderBox>(
        container: container,
        child: shell(story.builder(), unbounded: false),
      ).attachToRenderTree(buildOwner, root);
      pump();
      mark('clamped');
    }
    // A few real-time microturns so async work (image decoding) can land,
    // then synthetic frame pumps so animations reach a settled-looking
    // state without waiting wall-clock time. The budget bounds stories
    // whose single frame is genuinely expensive.
    var synthetic = binding.currentSystemFrameTimeStamp;
    final budget = DateTime.now().add(const Duration(seconds: 2));
    for (var i = 0; i < 60 && DateTime.now().isBefore(budget); i++) {
      final animating = binding.transientCallbackCount > baselineTickers;
      if (i >= 3 && !animating) break;
      if (animating) {
        synthetic += const Duration(milliseconds: 16);
        try {
          binding.handleBeginFrame(synthetic);
          binding.handleDrawFrame();
        } catch (_) {
          // A real engine frame was mid-flight; skip this pump.
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 4));
      pump();
    }
    mark('anim-pumps');
    pipelineOwner.flushCompositingBits();
    pipelineOwner.flushPaint();
    mark('paint');
    // Walk from the container we hold directly: GlobalKey lookups resolve
    // through the binding's BuildOwner, not our private offscreen one.
    final boundary = _findBoundary(container);
    if (boundary == null) {
      throw StateError('offscreen boundary not mounted');
    }
    final image = await boundary.toImage(pixelRatio: 2);
    mark('toImage');
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    mark('png-encode');
    image.dispose();
    _lastTrace = '${story.id}: $trace';
    _traceLog(_lastTrace);
    return bytes!.buffer.asUint8List();
  } finally {
    // Drain one binding frame while the tree is still mounted: widgets
    // like EditableText schedule post-frame callbacks that must run
    // against a live State, or they null-check on every later frame.
    try {
      binding.handleBeginFrame(
        binding.currentSystemFrameTimeStamp + const Duration(milliseconds: 16),
      );
      binding.handleDrawFrame();
    } catch (_) {}
    // Unmount so story states (and their tickers) are disposed; an
    // animating story must not keep ticking after its capture.
    try {
      RenderObjectToWidgetAdapter<RenderBox>(
        container: container,
      ).attachToRenderTree(buildOwner, root);
      buildOwner.finalizeTree();
    } catch (_) {}
  }
}

Future<Uint8List> _captureOnWindow(Story story) async {
  _mountWindowStory(story);
  await (_windowSettled ??= _settleWindow());
  final boundary =
      _windowKeys[story.id]!.currentContext!.findRenderObject()
          as RenderRepaintBoundary;
  final image = await boundary.toImage(pixelRatio: 2);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return bytes!.buffer.asUint8List();
}

/// One settle for the whole mounted batch: entrance animations of newly
/// mounted stories run concurrently, bounded by a single budget.
Future<void> _settleWindow() async {
  final binding = WidgetsBinding.instance;
  final deadline = DateTime.now().add(const Duration(milliseconds: 700));
  var noVsync = !binding.framesEnabled;
  var synthetic = binding.currentSystemFrameTimeStamp;
  do {
    if (noVsync) {
      synthetic += const Duration(milliseconds: 16);
      binding.handleBeginFrame(synthetic);
      binding.handleDrawFrame();
      await Future<void>.delayed(Duration.zero);
    } else {
      try {
        await binding.endOfFrame.timeout(const Duration(milliseconds: 150));
      } on TimeoutException {
        noVsync = true;
      }
    }
  } while ((binding.hasScheduledFrame || binding.transientCallbackCount > 0) &&
      DateTime.now().isBefore(deadline));
}

String _storyDetailPage(
  List<Story> all,
  int index, {
  PhoneSpec? device,
  bool statusBar = false,
  bool showDevices = false,
}) {
  final story = all[index];
  final id = _escape(story.id);
  final dev =
      '${device == null ? '' : '&device=${device.name}'}${statusBar ? '&status=1' : ''}';
  final toolbar = showDevices
      ? _deviceToolbar(
          selected: device?.name,
          statusBar: statusBar,
          links: true,
        )
      : '';
  final group = _escape(story.id.split('/').first);
  final prev = all[(index - 1 + all.length) % all.length].id;
  final next = all[(index + 1) % all.length].id;
  const live = '<div id="host"></div>';
  return '''
<!DOCTYPE html>
<html><head><meta charset="utf-8"><base href="/live/"><title>$id - flutter_static</title>
<style>
body{margin:0;background:#0A0B0D;color:#E2E4E9;font:14px system-ui,sans-serif;padding:32px}
a{color:#9B9FAB;text-decoration:none}a:hover{color:#E2E4E9}
h1{font-size:16px;margin:12px 0 24px;font-family:ui-monospace,monospace}
.nav{font-size:12px;display:flex;gap:16px}
section{margin:0 0 28px}
section h2{font-size:12px;text-transform:uppercase;letter-spacing:.08em;color:#6B6E7A;margin:0 0 10px}
.png{background:#131518;border-radius:12px;padding:16px;display:inline-block;max-width:100%}
.png img{display:block;max-width:min(840px,100%);height:auto;border-radius:8px}
#live{background:#131518;border-radius:12px;padding:16px;min-height:120px;display:flex;align-items:center;justify-content:center;resize:vertical;overflow:hidden}
#live .hint{color:#6B6E7A;font-size:12.5px}
.toolbar{margin:-12px 0 16px;font-size:12px;color:#9B9FAB;display:flex;gap:8px;align-items:center}
.toolbar .device,.toolbar .status{font:inherit;color:#9B9FAB;background:#131518;border:1px solid #2A2D35;border-radius:8px;padding:4px 10px;text-decoration:none}
.toolbar .device.on,.toolbar .status.on{color:#E2E4E9;border-color:#6B6E7A}
.toolbar .sep{margin-left:12px}
#host{width:100%;height:100%;min-height:120px}
</style></head><body>
<div class="nav"><a href="/">&larr; alle</a><a href="/$group">$group</a>
<a href="/story/${_escape(prev)}">&larr; forrige</a><a href="/story/${_escape(next)}">neste &rarr;</a>
<a href="/story/$id.png">png</a></div>
<h1>$id</h1>
$toolbar
<section><h2>Live</h2><div id="live">$live</div></section>
<!-- The render stays out of view: the gallery is where the PNGs earn their
     place, as thumbnails. It only shows when no live view is possible. The
     img still loads so its natural size can size the live box. -->
<section id="render" hidden><h2>Render</h2>
<a class="png" href="/story/$id.png"><img src="/story/$id.png?v=$_version$dev" alt="$id"></a></section>
<script>
const STORY = '$id';
const DEVICE = ${jsonEncode(device?.name)};
const STATUS = $statusBar;
document.addEventListener('keydown', (e) => {
  if (e.key === 'ArrowLeft') location.href = '/story/${_escape(prev)}';
  if (e.key === 'ArrowRight') location.href = '/story/${_escape(next)}';
});
// The PNG knows the story's real size (rendered at 2x): give the live view
// the same logical height so tall stories are not squeezed into a strip.
const img = document.querySelector('.png img');
const liveBox = document.getElementById('live');
const sizeLive = () => {
  if (img.naturalHeight) {
    liveBox.style.height = Math.max(152, img.naturalHeight / 2 + 32) + 'px';
  }
};
img.addEventListener('load', sizeLive);
sizeLive();
if (!navigator.webdriver) {
  // Keep the PNG in sync with hot reloads; the static live view cannot
  // change underneath us.
  let seen = $_version;
  new EventSource('/events').onmessage = (e) => {
    const d = JSON.parse(e.data);
    if (d.version !== seen) {
      seen = d.version;
      img.src = '/story/' + STORY + '.png?v=' + d.version + (DEVICE ? '&device=' + DEVICE : '') + (STATUS ? '&status=1' : '');
    }
  };
}
{
  fetch('/live/flutter_bootstrap.js', {method: 'HEAD'}).then((r) => {
    if (!r.ok) throw 0;
    // The page adds the view itself: the device travels in its data.
    document.addEventListener('flutter-static-ready', (e) => {
      // No undefined values: the Dart side cannot convert them.
      const data = {storyId: STORY};
      if (DEVICE) data.device = DEVICE;
      if (STATUS) data.status = true;
      e.detail.addView({hostElement: document.getElementById('host'), initialData: data});
    });
    const s = document.createElement('script');
    s.src = '/live/flutter_bootstrap.js';
    document.body.appendChild(s);
  }).catch(() => {
    document.getElementById('render').hidden = false;
    document.getElementById('live').innerHTML =
      '<div class="hint">Ingen web-bygg enn&aring; - kj&oslash;r flutter_static build-web for &aring; f&aring; en interaktiv versjon her.</div>';
  });
}
</script>
</body></html>
''';
}

/// Server-rendered grid so the initial document contains every <img>:
/// the browser load event then waits for them, which makes headless
/// screenshots deterministic. The inline script only re-renders on /events.
/// The group name when [path] is a single-segment route matching an
/// existing story group ("/tokens" -> "tokens"), else null.
String? _groupFor(String path, Stories stories) {
  if (path.length < 2 || path.substring(1).contains('/')) return null;
  final group = Uri.decodeComponent(path.substring(1));
  return stories.all().any((s) => s.id.startsWith('$group/')) ? group : null;
}

String _galleryPage(
  List<Story> stories,
  String? only, {
  required bool liveBuild,
  List<Storyline> lines = const [],
}) {
  final ordered = <String>[];
  for (final story in stories) {
    final group = story.id.split('/').first;
    if (!ordered.contains(group)) ordered.add(group);
  }
  final linesHtml = only != null || lines.isEmpty
      ? ''
      : '<h2>Storylines</h2><div class="lines">${lines.map((l) => '<a href="/line/${_escape(l.id)}">${_escape(l.title ?? l.id)}</a>').join()}</div>';
  return _indexHtml
      .replaceFirst('{{GROUPS}}', _galleryGroupsHtml(stories, only))
      .replaceFirst('{{LINES}}', linesHtml)
      .replaceFirst('{{TOOLBAR}}', '')
      .replaceFirst('{{GROUP_LIST}}', jsonEncode(ordered))
      .replaceFirst('{{FILTER}}', only ?? '')
      .replaceFirst('{{LINE}}', 'false')
      .replaceFirst(
        '{{BACK}}',
        only == null ? '' : '<a class="back" href="/">&larr; alle grupper</a>',
      )
      .replaceFirst('{{VERSION}}', '$_version')
      .replaceFirst('{{LIVE_BUILD}}', '$liveBuild');
}

/// A storyline: its rows of cells, each cell its variants stacked, all
/// live (near the viewport) with the device toggle on top.
String _linePage(Storyline line, {required bool liveBuild}) {
  final device = PhoneSpec.all.first.name;
  final buffer = StringBuffer();
  for (final row in line.rows) {
    buffer.write('<h2>${_escape(row.title)}</h2><div class="grid">');
    for (final cell in row.cells) {
      buffer.write(
        '<div class="cell"><h3>${_escape(cell.title ?? cell.id)}</h3>',
      );
      for (final variant in cell.variants) {
        buffer.write(
          _cardHtml(
            '${line.id}/${cell.id}/${variant.id}',
            label: variant.id,
            device: device,
          ),
        );
      }
      buffer.write('</div>');
    }
    buffer.write('</div>');
  }
  return _indexHtml
      .replaceFirst('{{GROUPS}}', buffer.toString())
      .replaceFirst('{{LINES}}', '')
      .replaceFirst('{{TOOLBAR}}', _deviceToolbar())
      .replaceFirst('{{GROUP_LIST}}', '[]')
      .replaceFirst('{{FILTER}}', line.id)
      .replaceFirst('{{LINE}}', 'true')
      .replaceFirst(
        '{{BACK}}',
        '<a class="back" href="/">&larr; alle grupper</a>'
            '<h1 class="line">${_escape(line.title ?? line.id)}</h1>',
      )
      .replaceFirst('{{VERSION}}', '$_version')
      .replaceFirst('{{LIVE_BUILD}}', '$liveBuild');
}

/// A card: the png (the size reference and the fallback) with its name
/// linking to the story page; live mode swaps a view in above the png.
String _cardHtml(String id, {String? label, String? device}) {
  final e = _escape(id);
  final src =
      '/story/$e.png?v=$_version${device == null ? '' : '&device=$device'}';
  return '<div class="card" data-id="$e"><figure>'
      '<a class="media" href="/story/$e">'
      '<img src="$src" alt="$e" loading="lazy" decoding="async"></a>'
      '<a class="name" href="/story/$e">${_escape(label ?? id)}</a></figure></div>';
}

String _galleryGroupsHtml(List<Story> stories, String? only) {
  final groups = <String, List<Story>>{};
  for (final story in stories) {
    final group = story.id.split('/').first;
    if (only != null && group != only) continue;
    groups.putIfAbsent(group, () => []).add(story);
  }
  final buffer = StringBuffer();
  groups.forEach((group, members) {
    final g = _escape(group);
    buffer.write('<h2><a href="/$g">$g</a></h2><div class="grid">');
    for (final story in members) {
      buffer.write(_cardHtml(story.id));
    }
    buffer.write('</div>');
  });
  return buffer.toString();
}

String _escape(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

/// Story gallery served at / and /index.html: every render in a grid,
/// grouped by the id's first path segment, live-reloading via /events.
/// A getter, not a const: hot reload leaves top-level consts as they were,
/// so template edits would only land on restart.
String get _indexHtml => """
<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>flutter_static</title>
<style>
body{margin:0;background:#0A0B0D;color:#E2E4E9;font:14px system-ui,sans-serif;padding:32px}
h1{font-size:18px;margin:0 0 8px}
h2{font-size:13px;text-transform:uppercase;letter-spacing:.08em;color:#9B9FAB;margin:32px 0 12px}
h2 a{color:inherit;text-decoration:none}
h2 a:hover{color:#E2E4E9}
.back{display:inline-block;font-size:12px;color:#9B9FAB;text-decoration:none;margin:4px 0 0}
.back:hover{color:#E2E4E9}
.grid{display:flex;flex-wrap:wrap;gap:16px;align-items:flex-start}
figure{margin:0;background:#131518;border-radius:12px;padding:12px}
.card:hover figure{background:#1A1D23}
.media{display:block}
img{display:block;max-width:460px;height:auto;border-radius:8px;background:#0A0B0D}
.media{position:relative}
.png{display:block}
.host{position:absolute;left:0;top:0;border-radius:8px;overflow:hidden;pointer-events:none}
.card.booting img{opacity:.5;transition:opacity .3s}
h1.line{font-size:16px;font-family:ui-monospace,monospace;margin:8px 0 0}
.toolbar{margin:16px 0 0;font-size:12px;color:#9B9FAB;display:flex;gap:8px;align-items:center}
.toolbar .device{font:inherit;color:#9B9FAB;background:#131518;border:1px solid #2A2D35;border-radius:8px;padding:4px 10px;cursor:pointer;text-decoration:none}
.toolbar .device.on,.toolbar .status.on{color:#E2E4E9;border-color:#6B6E7A}
.toolbar .status{font:inherit;color:#9B9FAB;background:#131518;border:1px solid #2A2D35;border-radius:8px;padding:4px 10px;cursor:pointer;text-decoration:none}
.toolbar .sep{margin-left:12px}
.lines a{display:inline-block;margin:0 12px 8px 0;font-family:ui-monospace,monospace;font-size:12px;color:#9B9FAB;text-decoration:none}
.lines a:hover{color:#E2E4E9}
.cell{display:flex;flex-direction:column;gap:16px}
.cell h3{font-size:12px;color:#9B9FAB;margin:0;font-family:ui-monospace,monospace;font-weight:500}
.name{display:block;margin-top:8px;font-size:12px;color:#6B6E7A;font-family:ui-monospace,monospace;text-decoration:none}
.name:hover{color:#E2E4E9}
</style></head><body>
<h1>flutter_static</h1>
<!-- fs-marker-7 -->
{{BACK}}
{{TOOLBAR}}
{{LINES}}
<div id="groups">{{GROUPS}}</div>
<script>
const FILTER = '{{FILTER}}';
const LINE = {{LINE}};
const GROUPS = {{GROUP_LIST}};
const LIVE_BUILD = {{LIVE_BUILD}};
// Live views from the static build (flutter_static build-web) at /live/:
// inside a group every card goes live while it is near the viewport; the
// front page keeps its pngs and swaps a card for the real widget on
// hover. The engine boots on first need, not on page load. The png stays
// the size reference (rendered at 2x) and the fallback for automation.
const WEB = '/live/';
const LIVE = LIVE_BUILD && !navigator.webdriver;
// Device toggle (storyline pages): renders and views take ?device / the
// view's initial data; the choice sticks per browser.
let DEVICE = null;
const deviceButtons = [...document.querySelectorAll('.toolbar button.device')];
if (deviceButtons.length) {
  try { DEVICE = localStorage.getItem('fs-device'); } catch (e) {}
  if (!deviceButtons.some((b) => b.dataset.device === DEVICE)) DEVICE = deviceButtons[0].dataset.device;
  for (const b of deviceButtons) b.addEventListener('click', () => setDevice(b.dataset.device));
}
let STATUS = false;
const statusButtons = [...document.querySelectorAll('.toolbar button.status')];
if (statusButtons.length) {
  try { STATUS = localStorage.getItem('fs-status') === '1'; } catch (e) {}
  for (const b of statusButtons) b.addEventListener('click', () => { STATUS = b.dataset.status === '1'; try { localStorage.setItem('fs-status', STATUS ? '1' : '0'); } catch (e) {} setDevice(DEVICE); });
}
// No undefined values in view data: the Dart side cannot convert them.
function viewData(id) {
  const data = {storyId: id};
  if (DEVICE) data.device = DEVICE;
  if (STATUS) data.status = true;
  return data;
}
function pngUrl(id, v) { return '/story/' + id + '.png?v=' + v + (DEVICE ? '&device=' + DEVICE : '') + (STATUS ? '&status=1' : ''); }
function setDevice(d) {
  DEVICE = d;
  try { localStorage.setItem('fs-device', d); } catch (e) {}
  for (const b of deviceButtons) b.classList.toggle('on', b.dataset.device === d);
  for (const b of statusButtons) b.classList.toggle('on', (b.dataset.status === '1') === STATUS);
  // A device changes a variant's size: back to a plain png card, which
  // remounts (live cards) from the new render's size.
  for (const card of document.querySelectorAll('.card')) {
    unmount(card);
    const media = card.querySelector('.media');
    const link = document.createElement('a');
    link.className = 'media'; link.href = '/story/' + card.dataset.id;
    const img = document.createElement('img');
    img.alt = card.dataset.id; img.loading = 'lazy'; img.decoding = 'async'; img.src = pngUrl(card.dataset.id, shownVersion);
    link.appendChild(img); media.replaceWith(link);
  }
  observeAll();
}
const GROUP_LIVE = LIVE && !!FILTER;
let app = null, booting = false;
const pending = new Set();
function boot() {
  if (booting) return;
  booting = true;
  document.addEventListener('flutter-static-ready', (e) => {
    app = e.detail;
    for (const c of pending) mount(c);
    pending.clear();
  });
  const s = document.createElement('script');
  s.src = WEB + 'flutter_bootstrap.js';
  document.body.appendChild(s);
}
// A live card holds a view only while it is near the viewport: added as
// it comes within 300px, discarded once it is more than 900px away (the
// gap keeps a card at the edge from flapping). The png stays underneath
// as the placeholder, and its render size (2x) is the size of the view.
const near = new IntersectionObserver((entries) => {
  for (const e of entries) if (e.isIntersecting) mount(e.target);
}, {rootMargin: '300px'});
const far = new IntersectionObserver((entries) => {
  for (const e of entries) if (!e.isIntersecting) unmount(e.target);
}, {rootMargin: '900px'});
function hostFor(card) {
  let host = card.querySelector('.host');
  if (host) return host;
  const img = card.querySelector('img');
  const w = Math.round(img.naturalWidth / 2), h = Math.round(img.naturalHeight / 2);
  if (!w || !h) return null;
  // Wide enough for a phone mockup (the 13's is 440) to stay 1:1, so
  // devices keep their real size difference on the page.
  const scale = Math.min(1, 460 / w);
  const box = document.createElement('div');
  box.className = 'media';
  box.style.cssText = 'width:' + Math.round(w * scale) + 'px;height:' + Math.round(h * scale) + 'px';
  const link = card.querySelector('a.media');
  link.replaceWith(box);
  link.className = 'png';
  img.style.cssText = 'width:100%;height:100%';
  box.appendChild(link);
  host = document.createElement('div');
  host.className = 'host';
  host.style.cssText = 'width:' + w + 'px;height:' + h + 'px;transform:scale(' + scale + ');transform-origin:0 0';
  box.appendChild(host);
  return host;
}
// Views are added one per animation frame: a burst of additions leaves
// some of them painted at the wrong size until they are re-added.
const queue = [];
function drain() {
  const card = queue.shift();
  if (!card) return;
  if (card.isConnected && !card.dataset.view && (GROUP_LIVE || card.dataset.live)) addView(card);
  if (queue.length) requestAnimationFrame(drain);
}
function mount(card) {
  if (card.dataset.view || queue.includes(card)) return;
  boot();
  if (!app) { pending.add(card); card.classList.add('booting'); return; }
  queue.push(card);
  if (queue.length === 1) requestAnimationFrame(drain);
}
function addView(card) {
  const img = card.querySelector('img');
  if (!(img.complete && img.naturalWidth)) {
    img.addEventListener('load', () => mount(card), {once: true});
    return;
  }
  const host = hostFor(card);
  if (!host) return;
  try {
    // Explicit constraints: without them the engine sizes every view's
    // canvas off the last view added (flutter/flutter#185034, 3.41+),
    // which shifts and doubles content in views that repaint.
    const w = host.offsetWidth, h = host.offsetHeight;
    card.dataset.view = app.addView({
      hostElement: host,
      viewConstraints: {minWidth: w, maxWidth: w, minHeight: h, maxHeight: h},
      initialData: viewData(card.dataset.id),
    });
    host.style.pointerEvents = 'auto';
    card.classList.remove('booting');
  } catch (e) { console.warn('flutter_static: view not added', card.dataset.id, e); }
}
function unmount(card) {
  if (!card.dataset.view) return;
  const host = card.querySelector('.host');
  app.removeView(+card.dataset.view);
  delete card.dataset.view;
  host.replaceChildren();
  host.style.pointerEvents = 'none';
}
// Live cards are watched for entering and leaving: all of them inside a
// group, the hovered ones on the front page.
function observe(card) {
  near.observe(card);
  far.observe(card);
}
function observeAll() {
  if (!LIVE) return;
  near.disconnect();
  far.disconnect();
  for (const c of document.querySelectorAll('.card')) {
    if (GROUP_LIVE || c.dataset.live) observe(c);
  }
}
function armHover() {
  if (!LIVE || GROUP_LIVE) return;
  for (const c of document.querySelectorAll('.card:not([data-live])')) {
    c.addEventListener('pointerenter', () => { c.dataset.live = '1'; observe(c); }, {once: true});
  }
}
function unmountAll() {
  for (const c of document.querySelectorAll('.card[data-view]')) unmount(c);
}
let shownVersion = {{VERSION}};
if (deviceButtons.length && (DEVICE !== deviceButtons[0].dataset.device || STATUS)) setDevice(DEVICE);
else { for (const b of deviceButtons) b.classList.toggle('on', b.dataset.device === DEVICE); observeAll(); armHover(); }
// Left/right arrows cycle through the group pages.
document.addEventListener('keydown', (e) => {
  if (e.key !== 'ArrowLeft' && e.key !== 'ArrowRight') return;
  if (!GROUPS.length) return;
  const delta = e.key === 'ArrowRight' ? 1 : -1;
  const i = GROUPS.indexOf(FILTER);
  const next = i === -1
    ? (delta === 1 ? 0 : GROUPS.length - 1)
    : (i + delta + GROUPS.length) % GROUPS.length;
  location.href = '/' + encodeURIComponent(GROUPS[next]);
});
async function load(v){
  if (LINE) {
    // Server-rendered layout; only the pngs move.
    if (v !== shownVersion) {
      shownVersion = v;
      if (!LIVE) for (const img of document.querySelectorAll('.card img')) img.src = pngUrl(img.alt, v);
    }
    return;
  }
  const idx = await (await fetch('/index.json')).json();
  const ids = idx.stories.map((s) => s.id).filter((id) => !FILTER || id.split('/')[0] === FILTER);
  const shown = [...document.querySelectorAll('.card')].map((c) => c.dataset.id);
  if (ids.join('|') === shown.join('|')) {
    // Same stories: refresh the PNGs when they are what is visible (the
    // static live views only change with a new build-web).
    if (!LIVE && (v ?? idx.version) !== shownVersion) {
      shownVersion = v ?? idx.version;
      for (const img of document.querySelectorAll('.card img')) {
        img.src = pngUrl(img.alt, shownVersion);
      }
    }
    return;
  }
  shownVersion = v ?? idx.version;
  unmountAll();
  const groups = {};
  for (const s of idx.stories){
    const g = s.id.split('/')[0];
    if (FILTER && g !== FILTER) continue;
    (groups[g] ??= []).push(s);
  }
  const root = document.getElementById('groups');
  root.innerHTML = '';
  for (const [g, stories] of Object.entries(groups)){
    const h = document.createElement('h2');
    const hl = document.createElement('a');
    hl.href = '/' + encodeURIComponent(g);
    hl.textContent = g;
    h.appendChild(hl); root.appendChild(h);
    const grid = document.createElement('div'); grid.className = 'grid';
    for (const s of stories){
      const card = document.createElement('div');
      card.className = 'card';
      card.dataset.id = s.id;
      const f = document.createElement('figure');
      const media = document.createElement('a');
      media.className = 'media';
      media.href = '/story/' + s.id;
      const img = document.createElement('img');
      img.loading = 'lazy';
      img.decoding = 'async';
      img.src = pngUrl(s.id, shownVersion);
      img.alt = s.id;
      media.appendChild(img);
      const name = document.createElement('a');
      name.className = 'name';
      name.href = '/story/' + s.id;
      name.textContent = s.id;
      f.append(media, name); card.appendChild(f); grid.appendChild(card);
    }
    root.appendChild(grid);
  }
  observeAll();
  armHover();
}
// Automation (headless screenshots, drivers) waits for network idle;
// the ever-open SSE stream would hang it, so only humans get live reload.
if (!navigator.webdriver) {
  new EventSource('/events').onmessage = (e) => {
    load(JSON.parse(e.data).version);
  };
}
</script>
</body></html>
""";
