import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

class Story {
  const Story(this.id, this.builder);

  final String id;
  final Widget Function() builder;
}

/// Subclass this and implement [build] to define your stories.
///
/// It must be a class method, not a stored closure: hot reload never re-runs
/// `main()`, and a closure created by the old `main()` keeps executing the
/// code it was created with. Method calls dispatch through the class, whose
/// code is reliably replaced on reload, so [build] is re-evaluated fresh on
/// every request and every reload.
abstract class Stories {
  const Stories();

  List<Story> build();
}

void runFlutterStatic(Stories stories, {int port = 8474}) {
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
    for (final story in stories.build()) {
      if (_version != version) return;
      try {
        await _renderCached(story);
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  });
}

final _boundaryKey = GlobalKey();
final _currentId = ValueNotifier<String?>(null);
int _version = 0;
final _renderCache = <String, Uint8List>{};
int _renderCacheVersion = -1;
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
    for (final client in _eventClients) {
      try {
        client.write('data: {"version": $_version}\n\n');
        client.flush();
      } catch (_) {
        // Dead client; removed by its done handler.
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: Center(
          child: ValueListenableBuilder<String?>(
            valueListenable: _currentId,
            builder: (context, id, _) {
              final all = widget.stories.build();
              if (all.isEmpty) return const Text('no stories registered');
              final story = all.firstWhere(
                (s) => s.id == id,
                orElse: () => all.first,
              );
              // Decouple story constraints from the window: a story larger
              // than the window must still lay out (and capture) at its
              // natural size, not clamp to the viewport.
              return OverflowBox(
                minWidth: 0,
                minHeight: 0,
                maxWidth: double.infinity,
                maxHeight: double.infinity,
                alignment: Alignment.center,
                child: RepaintBoundary(
                  key: _boundaryKey,
                  child: story.builder(),
                ),
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

Future<Uint8List> _renderCached(Story story) {
  if (_renderCacheVersion == _version) {
    final hit = _renderCache[story.id];
    if (hit != null) return Future.value(hit);
  }
  final previous = _captureQueue ?? Future<void>.value();
  final completer = Completer<void>();
  _captureQueue = completer.future;
  return previous.then((_) async {
    try {
      if (_renderCacheVersion != _version) {
        _renderCache.clear();
        _renderCacheVersion = _version;
      }
      return _renderCache[story.id] ??= await _capture(story);
    } finally {
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
        response.write(_galleryPage(stories.build(), null));
        await response.close();
      } else if (path == '/events') {
        response.bufferOutput = false;
        response.headers.contentType = ContentType('text', 'event-stream');
        response.headers.set('Cache-Control', 'no-cache');
        response.write('data: {"version": $_version}\n\n');
        response.flush();
        _eventClients.add(response);
        response.done.whenComplete(() => _eventClients.remove(response));
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
          response.headers.contentType = ContentType('image', 'png');
          response.add(png);
          await response.close();
        }
      } else if (_groupFor(path, stories) != null) {
        response.headers.contentType = ContentType.html;
        response.write(_galleryPage(stories.build(), _groupFor(path, stories)));
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

Future<Uint8List> _capture(Story story) async {
  try {
    return await _captureOffscreen(story);
  } catch (e) {
    debugPrint(
      'flutter_static: offscreen capture failed for ${story.id} ($e); '
      'falling back to window capture',
    );
    return _captureOnWindow(story.id);
  }
}

/// Renders [story] in its own offscreen render tree: no shared window, no
/// vsync, and animations advance on synthetic timestamps instead of
/// wall-clock time, so even infinitely-animating stories capture in tens of
/// milliseconds.
Future<Uint8List> _captureOffscreen(Story story) async {
  final binding = WidgetsBinding.instance;
  final theme = ThemeData();
  final boundaryKey = GlobalKey();

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

  final adapter = RenderObjectToWidgetAdapter<RenderBox>(
    container: container,
    child: MediaQuery(
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
                child: RepaintBoundary(
                  key: boundaryKey,
                  child: story.builder(),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  final root = adapter.attachToRenderTree(buildOwner);

  // Painting is the expensive pass for complex stories, so the pump loop
  // only builds and lays out; paint happens exactly once, at capture.
  void pump() {
    buildOwner.buildScope(root);
    buildOwner.finalizeTree();
    pipelineOwner.flushLayout();
  }

  try {
    pump();
    // A few real-time microturns so async work (image decoding) can land,
    // then synthetic frame pumps so animations reach a settled-looking
    // state without waiting wall-clock time. The budget bounds stories
    // whose single frame is genuinely expensive.
    var synthetic = binding.currentSystemFrameTimeStamp;
    final budget = DateTime.now().add(const Duration(seconds: 2));
    for (var i = 0; i < 24 && DateTime.now().isBefore(budget); i++) {
      final animating = binding.transientCallbackCount > 0;
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
    pipelineOwner.flushCompositingBits();
    pipelineOwner.flushPaint();
    final boundary =
        boundaryKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return bytes!.buffer.asUint8List();
  } finally {
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

Future<Uint8List> _captureOnWindow(String id) async {
  _currentId.value = id;
  final binding = WidgetsBinding.instance;
  // Pump frames until the tree settles: implicit animations (e.g.
  // CircleAvatar's 200ms theme-change tween) keep scheduling frames until
  // they finish, and capturing the first frame would freeze them at t=0.
  // The deadline bounds stories that animate forever.
  //
  // An occluded or hidden window gets no vsync on macOS, so once a natural
  // frame times out we pump frames manually with an advancing timestamp.
  // (Warm-up frames are no good here: they reuse the last frame's timestamp,
  // so tickers see zero elapsed time and animations never progress.)
  // A hidden app has framesEnabled == false: scheduleFrame() is silently
  // ignored, so hasScheduledFrame can't be trusted as a settle signal.
  // transientCallbackCount counts active tickers and works either way.
  final deadline = DateTime.now().add(const Duration(seconds: 3));
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
  final boundary =
      _boundaryKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
  final image = await boundary.toImage(pixelRatio: 2);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return bytes!.buffer.asUint8List();
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

String _galleryPage(List<Story> stories, String? only) {
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
      .replaceFirst('{{VERSION}}', '$_version');
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
        '<figure><img src="/story/$id.png?v=$_version" alt="$id" loading="lazy" decoding="async">'
        '<figcaption>$id</figcaption></figure>',
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
const _indexHtml = """
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
img{display:block;max-width:420px;height:auto;border-radius:8px;background:#0A0B0D}
figcaption{margin-top:8px;font-size:12px;color:#6B6E7A;font-family:ui-monospace,monospace}
</style></head><body>
<h1>flutter_static</h1>
{{BACK}}
<div id="groups">{{GROUPS}}</div>
<script>
const FILTER = '{{FILTER}}';
const GROUPS = {{GROUP_LIST}};
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
  const groups = {};
  for (const s of idx.stories){
    const g = s.id.split('/')[0];
    if (FILTER && g !== FILTER) continue;
    (groups[g] ??= []).push(s);
  }
  const root = document.getElementById('groups');
  root.innerHTML = '';
  for (const [g, stories] of Object.entries(groups)){
    const h = document.createElement('h2'); h.textContent = g; root.appendChild(h);
    const grid = document.createElement('div'); grid.className = 'grid';
    for (const s of stories){
      const f = document.createElement('figure');
      const img = document.createElement('img');
      img.loading = 'lazy';
      img.decoding = 'async';
      img.src = s.png + '?v=' + (v ?? idx.version);
      img.alt = s.id;
      const c = document.createElement('figcaption'); c.textContent = s.id;
      f.append(img, c); grid.appendChild(f);
    }
    root.appendChild(grid);
  }
}
// Automation (headless screenshots, drivers) waits for network idle;
// the ever-open SSE stream would hang it, so only humans get live reload.
if (!navigator.webdriver)
  new EventSource('/events').onmessage = (e) => load(JSON.parse(e.data).version);
</script>
</body></html>
""";
