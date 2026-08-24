import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'story.dart';
import 'package:flutter/rendering.dart';

/// Ports, overridable at build time (flutter_static run --port/--web-port
/// passes them as dart-defines).
const _catalogPort = int.fromEnvironment(
  'FLUTTER_STATIC_PORT',
  defaultValue: 8474,
);
const _webDevPort = int.fromEnvironment(
  'FLUTTER_STATIC_WEB_PORT',
  defaultValue: 8476,
);

void runFlutterStatic(Stories stories, {int port = _catalogPort}) {
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
    for (final story in stories.build()) {
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

/// Bumped by the CLI (POST /web-reloaded) when the live web dev server
/// finishes a hot restart, with the outcome it reported.
int _webVersion = 0;
String _webStatus = '';

String _eventData() =>
    '{"version": $_version, "web": $_webVersion, "webStatus": "$_webStatus"}';

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
              for (final s in stories.build())
                {'id': s.id, 'png': '/story/${s.id}.png'},
            ],
          }),
        );
        await response.close();
      } else if (path == '/' || path == '/index.html') {
        response.headers.contentType = ContentType.html;
        response.write(
          _galleryPage(
            stories.build(),
            null,
            liveDev: await _liveDevAvailable(),
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
      } else if (path == '/web-reloaded') {
        final status = request.uri.queryParameters['status'] ?? '';
        _webStatus = RegExp(r'^[a-z]+$').hasMatch(status) ? status : '';
        _webVersion++;
        _broadcastEvent();
        response.statusCode = HttpStatus.noContent;
        await response.close();
      } else if (path.startsWith('/story/') && path.endsWith('.png')) {
        final id = path.substring(
          '/story/'.length,
          path.length - '.png'.length,
        );
        final matches = stories.build().where((s) => s.id == id);
        if (matches.isEmpty) {
          response.statusCode = HttpStatus.notFound;
          await response.close();
        } else {
          // Renders are pure per (story, reload version): cached, and
          // capture work is serialized behind _captureQueue.
          final png = await _renderCached(matches.first);
          response.headers.set('x-render-trace', _lastTrace);
          response.headers.contentType = ContentType('image', 'png');
          response.add(png);
          await response.close();
        }
      } else if (path.startsWith('/story/') && !path.endsWith('.png')) {
        final id = Uri.decodeComponent(path.substring('/story/'.length));
        final all = stories.build();
        final index = all.indexWhere((s) => s.id == id);
        if (index == -1) {
          response.statusCode = HttpStatus.notFound;
          await response.close();
        } else {
          // A running dev server (flutter_static run --live) beats the
          // static /live build: it hot reloads. The dev page is embedded
          // cross-origin in an iframe, so the wasm isolation headers must
          // stay off in that mode (the dev build is JS and needs neither).
          final liveDev = await _liveDevAvailable();
          response.headers.contentType = ContentType.html;
          if (!liveDev) {
            response.headers.set('Cross-Origin-Opener-Policy', 'same-origin');
            response.headers.set(
              'Cross-Origin-Embedder-Policy',
              'require-corp',
            );
          }
          response.write(_storyDetailPage(all, index, liveDev: liveDev));
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
        response.write(
          _galleryPage(
            stories.build(),
            _groupFor(path, stories),
            liveDev: await _liveDevAvailable(),
          ),
        );
        await response.close();
      } else if (_looksLikeDevAsset(path) &&
          await _liveDevAvailable() &&
          await _proxyToDev(request)) {
        // Served by the dev server: the gallery runs its bundle on this
        // origin, and the bundle's hot-restart path fetches page-relative
        // URLs (reloaded_sources.json, then the changed modules).
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

/// Catalog routes have no extension (the .png and index.json ones are
/// matched first); dev-server assets always do.
bool _looksLikeDevAsset(String path) {
  final last = path.substring(path.lastIndexOf('/') + 1);
  return last.contains('.');
}

/// Forwards [request] to the live web dev server. False when it could not
/// be reached, so the caller can answer instead.
Future<bool> _proxyToDev(HttpRequest request) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
  try {
    final target = request.uri.replace(
      scheme: 'http',
      host: 'localhost',
      port: _webDevPort,
    );
    final upstream = await client.openUrl(request.method, target);
    request.headers.forEach((name, values) {
      if (name == HttpHeaders.hostHeader) return;
      for (final value in values) {
        upstream.headers.add(name, value);
      }
    });
    await upstream.addStream(request);
    final reply = await upstream.close();
    final response = request.response;
    response.statusCode = reply.statusCode;
    // Let the dev server's caching policy through instead of the
    // catalog's no-store (a 17MB SDK bundle per gallery load otherwise).
    response.headers.removeAll(HttpHeaders.cacheControlHeader);
    reply.headers.forEach((name, values) {
      if (name == HttpHeaders.transferEncodingHeader ||
          name == HttpHeaders.contentLengthHeader) {
        return;
      }
      for (final value in values) {
        response.headers.add(name, value);
      }
    });
    await response.addStream(reply);
    await response.close();
    return true;
  } catch (_) {
    return false;
  } finally {
    client.close();
  }
}

/// Stories that need the real window (e.g. they embed a MaterialApp, whose
/// View.of has no answer in an offscreen tree). Routed directly on later
/// renders instead of re-attempting offscreen.
final _needsWindow = <String>{};

/// Whether the hot-reloading web dev server (flutter_static run --live)
/// answers on the web dev port. Probed at most every few seconds.
var _liveDevUp = false;
var _liveDevChecked = DateTime.fromMillisecondsSinceEpoch(0);
Future<bool> _liveDevAvailable() async {
  final now = DateTime.now();
  if (now.difference(_liveDevChecked) < const Duration(seconds: 3)) {
    return _liveDevUp;
  }
  _liveDevChecked = now;
  try {
    final socket = await Socket.connect(
      '127.0.0.1',
      _webDevPort,
      timeout: const Duration(milliseconds: 300),
    );
    socket.destroy();
    _liveDevUp = true;
  } catch (_) {
    _liveDevUp = false;
  }
  return _liveDevUp;
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

String _storyDetailPage(List<Story> all, int index, {required bool liveDev}) {
  final story = all[index];
  final id = _escape(story.id);
  final group = _escape(story.id.split('/').first);
  final prev = all[(index - 1 + all.length) % all.length].id;
  final next = all[(index + 1) % all.length].id;
  final live = liveDev
      ? '<iframe id="devframe" '
            'src="http://localhost:$_webDevPort/?storyId=${Uri.encodeComponent(story.id)}" '
            'allow="clipboard-write"></iframe>'
      : '<div id="host"></div>';
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
#host{width:100%;height:100%;min-height:120px}
#devframe{border:0;width:100%;height:100%;min-height:120px;border-radius:8px;background:#131518}
</style></head><body>
<div class="nav"><a href="/">&larr; alle</a><a href="/$group">$group</a>
<a href="/story/${_escape(prev)}">&larr; forrige</a><a href="/story/${_escape(next)}">neste &rarr;</a>
<a href="/story/$id.png">png</a></div>
<h1>$id</h1>
<section><h2>Live${liveDev ? ' (hot reload)' : ''}</h2><div id="live">$live</div></section>
<!-- The render stays out of view: the gallery is where the PNGs earn their
     place, as thumbnails. It only shows when no live view is possible. The
     img still loads so its natural size can size the live box. -->
<section id="render" hidden><h2>Render</h2>
<a class="png" href="/story/$id.png"><img src="/story/$id.png?v=$_version" alt="$id"></a></section>
<script>
const STORY = '$id';
const LIVE_DEV = $liveDev;
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
  // Keep the PNG in sync with hot reloads. The live frame: when the dev
  // server had this page as a client it hot restarted the app in place
  // ('restarted'); when it only recompiled, reload the frame to fetch the
  // new bundle. A static /live build cannot change underneath us.
  let seen = $_version, webSeen = $_webVersion;
  new EventSource('/events').onmessage = (e) => {
    const d = JSON.parse(e.data);
    if (d.version !== seen) {
      seen = d.version;
      img.src = '/story/' + STORY + '.png?v=' + d.version;
    }
    if (LIVE_DEV && d.web !== webSeen) {
      webSeen = d.web;
      const frame = document.getElementById('devframe');
      frame.style.outline = d.webStatus === 'failed' ? '2px solid #E5484D' : '';
      if (d.webStatus === 'recompiled') frame.src = frame.src;
    }
  };
}
if (!LIVE_DEV) {
  fetch('/live/flutter_bootstrap.js', {method: 'HEAD'}).then((r) => {
    if (!r.ok) throw 0;
    window._flutterStaticStory = STORY;
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
  return stories.build().any((s) => s.id.startsWith('$group/')) ? group : null;
}

String _galleryPage(
  List<Story> stories,
  String? only, {
  required bool liveDev,
}) {
  final ordered = <String>[];
  for (final story in stories) {
    final group = story.id.split('/').first;
    if (!ordered.contains(group)) ordered.add(group);
  }
  return _indexHtml
      .replaceFirst('{{GROUPS}}', _galleryGroupsHtml(stories, only))
      .replaceFirst('{{GROUP_LIST}}', jsonEncode(ordered))
      .replaceFirst('{{FILTER}}', only ?? '')
      .replaceFirst(
        '{{BACK}}',
        only == null ? '' : '<a class="back" href="/">&larr; alle grupper</a>',
      )
      .replaceFirst('{{VERSION}}', '$_version')
      .replaceFirst('{{LIVE_DEV}}', '$liveDev');
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
      final id = _escape(story.id);
      buffer.write(
        '<div class="card" data-id="$id"><figure>'
        '<a class="media" href="/story/$id">'
        '<img src="/story/$id.png?v=$_version" alt="$id" loading="lazy" decoding="async"></a>'
        '<a class="name" href="/story/$id">$id</a></figure></div>',
      );
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
img{display:block;max-width:420px;height:auto;border-radius:8px;background:#0A0B0D}
.host{border-radius:8px;background:#0A0B0D;overflow:hidden}
.card.booting img{opacity:.5;transition:opacity .3s}
.name{display:block;margin-top:8px;font-size:12px;color:#6B6E7A;font-family:ui-monospace,monospace;text-decoration:none}
.name:hover{color:#E2E4E9}
</style></head><body>
<h1>flutter_static</h1>
<!-- fs-marker-7 -->
{{BACK}}
<div id="groups">{{GROUPS}}</div>
<script>
const FILTER = '{{FILTER}}';
const GROUPS = {{GROUP_LIST}};
const LIVE_DEV = {{LIVE_DEV}};
// Live views: inside a group every card goes live as it scrolls near; the
// front page keeps its pngs and swaps a card for the real widget on hover.
// The dev bundle boots on first need, not on page load, and comes through
// this origin (the catalog proxies dev assets): its hot-restart path
// fetches page-relative URLs, and cross-origin XHR trips on dwds. The png
// stays the size reference (rendered at 2x) and the fallback for
// automation.
const WEB = '/';
const LIVE = LIVE_DEV && !navigator.webdriver;
const GROUP_LIVE = LIVE && !!FILTER;
let app = null, booting = false;
const pending = new Set();
function boot() {
  if (booting) return;
  booting = true;
  document.addEventListener('flutter-static-ready', (e) => {
    // Fires again after every hot restart: the engine drops all views and
    // hands out a fresh app; the old handle cannot add views any more.
    const rerun = app !== null;
    app = e.detail;
    if (rerun) {
      for (const c of document.querySelectorAll('.card[data-view]')) delete c.dataset.view;
      observeAll();
    }
    for (const c of pending) mount(c);
    pending.clear();
  });
  const s = document.createElement('script');
  s.src = WEB + 'flutter_bootstrap.js';
  document.body.appendChild(s);
}
const io = new IntersectionObserver((entries) => {
  for (const e of entries) {
    if (!e.isIntersecting) continue;
    io.unobserve(e.target);
    mount(e.target);
  }
}, {rootMargin: '300px'});
function mount(card) {
  if (card.dataset.view) return;
  boot();
  if (!app) { pending.add(card); card.classList.add('booting'); return; }
  const existing = card.querySelector('.host');
  if (existing) {
    // A handle from before a restart cannot add views; the ready event of
    // that restart observes the card again.
    try {
      card.dataset.view = app.addView({hostElement: existing, initialData: {storyId: card.dataset.id}});
    } catch (e) { console.warn('flutter_static: view not added', card.dataset.id, e); }
    return;
  }
  const img = card.querySelector('img');
  const go = () => {
    const w = Math.round(img.naturalWidth / 2), h = Math.round(img.naturalHeight / 2);
    if (!w || !h || card.dataset.view) return;
    const scale = Math.min(1, 420 / w);
    const box = document.createElement('div');
    box.className = 'media';
    box.style.cssText = 'width:' + Math.round(w * scale) + 'px;height:' + Math.round(h * scale) + 'px';
    const host = document.createElement('div');
    host.className = 'host';
    host.style.cssText = 'width:' + w + 'px;height:' + h + 'px;transform:scale(' + scale + ');transform-origin:0 0';
    box.appendChild(host);
    card.querySelector('a.media').replaceWith(box);
    card.classList.remove('booting');
    card.dataset.view = app.addView({hostElement: host, initialData: {storyId: card.dataset.id}});
  };
  if (img.complete && img.naturalWidth) go(); else img.addEventListener('load', go, {once: true});
}
// Cards that are (or were) live get a view when they scroll near: all of
// them inside a group, the hovered ones on the front page.
function observeAll() {
  if (!LIVE) return;
  // Start observation over: observe() is a no-op for a card still being
  // observed, and a restart between its observation and its mount would
  // otherwise leave it empty for good.
  io.disconnect();
  for (const c of document.querySelectorAll('.card:not([data-view])')) {
    if (GROUP_LIVE || c.dataset.live) io.observe(c);
  }
}
function armHover() {
  if (!LIVE || GROUP_LIVE) return;
  for (const c of document.querySelectorAll('.card:not([data-live])')) {
    c.addEventListener('pointerenter', () => { c.dataset.live = '1'; mount(c); }, {once: true});
  }
}
function unmountAll() {
  if (!app) return;
  for (const c of document.querySelectorAll('.card[data-view]')) {
    app.removeView(+c.dataset.view);
    delete c.dataset.view;
  }
}
observeAll();
armHover();
let shownVersion = {{VERSION}};
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
  const idx = await (await fetch('/index.json')).json();
  const ids = idx.stories.map((s) => s.id).filter((id) => !FILTER || id.split('/')[0] === FILTER);
  const shown = [...document.querySelectorAll('.card')].map((c) => c.dataset.id);
  if (ids.join('|') === shown.join('|')) {
    // Same stories: live views were hot restarted in place; refresh the PNGs
    // when they are what is visible.
    if (!LIVE && (v ?? idx.version) !== shownVersion) {
      shownVersion = v ?? idx.version;
      for (const img of document.querySelectorAll('.card img')) {
        img.src = '/story/' + img.alt + '.png?v=' + shownVersion;
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
      img.src = s.png + '?v=' + shownVersion;
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
  let webSeen = null;
  new EventSource('/events').onmessage = (e) => {
    const d = JSON.parse(e.data);
    if (webSeen !== null && d.web !== webSeen && LIVE && app) {
      // Views stay attached through a hot restart: it re-runs main in
      // place and the engine keeps them (a view added afterwards through
      // the pre-restart app handle fails). A bare recompile means this
      // page is no longer the dev server's client (it relaunched): start
      // over with the new bundle.
      if (d.webStatus === 'recompiled') { location.reload(); return; }
    }
    webSeen = d.web;
    load(d.version);
  };
}
</script>
</body></html>
""";
