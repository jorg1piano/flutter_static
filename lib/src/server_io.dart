import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'phone_mockup.dart';
import 'story.dart';
import 'tokens.dart';
import 'package:flutter/rendering.dart';

/// Port, overridable at build time (flutter_static run --port passes it
/// as a dart-define).
const _catalogPort = int.fromEnvironment(
  'FLUTTER_STATIC_PORT',
  defaultValue: 8474,
);

/// Builds the catalog window around [mounts], the stories that need a
/// real view (see [_windowStories]). Keep [mounts] in the tree and painted
/// so they can still be snapshotted; Studio puts its UI over them.
typedef CatalogShell = Widget Function(BuildContext context, Widget mounts);

/// The port `flutter_static run` compiled in, or 8474.
const defaultCatalogPort = _catalogPort;

void runFlutterStatic(
  Stories stories, {
  int port = _catalogPort,
  CatalogShell? shell,
}) {
  debugDefaultTargetPlatformOverride = stories.platform;
  // At launch the running code includes every save made so far.
  _reloadReportedAt = DateTime.now();
  _stayAwake();
  runApp(_CatalogApp(stories: stories, shell: shell));
  _serve(stories, port);
  // Studio hosts the window: its cards ask for the captures they need,
  // in the background, and an unasked sweep after every save would only
  // hitch the UI thread while someone drags a slider.
  _prewarmEnabled = shell == null;
  _prewarm(stories, initial: true);
}

// --- in-process API, for Studio -------------------------------------------

/// Bumped on every hot reload the catalog saw.
final catalogVersion = ValueNotifier<int>(0);

/// Bumped whenever the reload gate changes state; read
/// [catalogReloadError] and [catalogReloadPending] then.
final catalogReloadTick = ValueNotifier<int>(0);
String? get catalogReloadError => _reloadError;
bool get catalogReloadPending => _reloadPending;

/// The consumer project root, or null when the binary is not under one.
String? projectRoot() => _projectRoot();

Story? findStory(Stories stories, String id) {
  for (final story in stories.all()) {
    if (story.id == id) return story;
  }
  return null;
}

/// [story]'s widget on [device], with the status bar and on the [knobs]
/// choices, the way a page or a render shows it. Call from a build.
Widget storyOnPage(
  Story story, {
  PhoneSpec? device,
  bool statusBar = false,
  Map<String, String> knobs = const {},
}) => _onPage(
  story,
  device: device,
  statusBar: statusBar,
  knobs: knobs,
).builder();

/// The render of story [id] as `/story/<id>.png` would serve it, from the
/// same cache and capture queue. A [background] capture yields to
/// foreground ones and does not join the hot set that re-renders first
/// after every reload.
Future<Uint8List> renderStoryPng(
  Stories stories,
  String id, {
  PhoneSpec? device,
  bool statusBar = false,
  Map<String, String> knobs = const {},
  bool background = false,
}) {
  final story = findStory(stories, id);
  if (story == null) throw ArgumentError.value(id, 'id', 'no such story');
  if (!background) _noteRequested(id);
  return _renderCached(
    _onPage(story, device: device, statusBar: statusBar, knobs: knobs),
    background: background,
  );
}

/// How a story lays out, learnt at its first capture: at its natural
/// size under unbounded constraints, only inside a phone-sized box, or
/// only in the real window (a widget the offscreen tree cannot host).
enum StoryShell { unbounded, bounded, window }

final _storyShells = <String, StoryShell>{};

/// [StoryShell] of story [id], or null until it has been captured once.
StoryShell? storyShellOf(String id) => _storyShells[id];

/// Tests mount stories without a capture; this stands in for one.
@visibleForTesting
void setStoryShell(String id, StoryShell shell) => _storyShells[id] = shell;

String _baseId(String id) => id.split(RegExp('[@~]')).first;

/// The environment a story renders in: phone-sized media query, English
/// localizations, the default theme, a transparent Material. [bounded]
/// adds the phone-sized box [StoryShell.bounded] stories need.
Widget storyEnvironment(Widget child, {bool bounded = false}) =>
    _storyEnvironment(
      bounded
          ? ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 430, maxHeight: 932),
              child: child,
            )
          : child,
      _defaultTheme,
    );

/// One default theme for every mount: building a ThemeData is not free,
/// and a canvas rebuild mounts every card on the page.
final _defaultTheme = ThemeData();

Widget _storyEnvironment(Widget inner, ThemeData theme) => MediaQuery(
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
          child: Material(type: MaterialType.transparency, child: inner),
        ),
      ),
    ),
  ),
);

/// Opts the process out of App Nap. The catalog runs hidden and unfocused
/// (flutter run launches it behind the terminal), so macOS throttles it
/// after a few idle seconds: timers coalesce, the process drops to
/// priority 4, and the next hot reload, capture or PNG encode takes 10 to
/// 100 times longer (51s for a reload that takes 200ms awake).
/// NSProcessInfo's activity API is the supported opt-out; it is called over
/// dart:ffi so the consumer's runner needs no platform code.
void _stayAwake() {
  if (!Platform.isMacOS) return;
  try {
    final lib = ffi.DynamicLibrary.process();
    final getClass = lib
        .lookupFunction<
          ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Char>),
          ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Char>)
        >('objc_getClass');
    final sel = lib
        .lookupFunction<
          ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Char>),
          ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Char>)
        >('sel_registerName');
    final send0 = lib
        .lookupFunction<
          ffi.Pointer<ffi.Void> Function(
            ffi.Pointer<ffi.Void>,
            ffi.Pointer<ffi.Void>,
          ),
          ffi.Pointer<ffi.Void> Function(
            ffi.Pointer<ffi.Void>,
            ffi.Pointer<ffi.Void>,
          )
        >('objc_msgSend');
    final sendStr = lib
        .lookupFunction<
          ffi.Pointer<ffi.Void> Function(
            ffi.Pointer<ffi.Void>,
            ffi.Pointer<ffi.Void>,
            ffi.Pointer<ffi.Char>,
          ),
          ffi.Pointer<ffi.Void> Function(
            ffi.Pointer<ffi.Void>,
            ffi.Pointer<ffi.Void>,
            ffi.Pointer<ffi.Char>,
          )
        >('objc_msgSend');
    final sendActivity = lib
        .lookupFunction<
          ffi.Pointer<ffi.Void> Function(
            ffi.Pointer<ffi.Void>,
            ffi.Pointer<ffi.Void>,
            ffi.Uint64,
            ffi.Pointer<ffi.Void>,
          ),
          ffi.Pointer<ffi.Void> Function(
            ffi.Pointer<ffi.Void>,
            ffi.Pointer<ffi.Void>,
            int,
            ffi.Pointer<ffi.Void>,
          )
        >('objc_msgSend');
    final malloc = lib
        .lookupFunction<
          ffi.Pointer<ffi.Void> Function(ffi.IntPtr),
          ffi.Pointer<ffi.Void> Function(int)
        >('malloc');
    ffi.Pointer<ffi.Char> cString(String text) {
      final bytes = utf8.encode(text);
      final buffer = malloc(bytes.length + 1).cast<ffi.Uint8>();
      buffer.asTypedList(bytes.length + 1)
        ..setAll(0, bytes)
        ..[bytes.length] = 0;
      return buffer.cast();
    }

    final processInfo = send0(
      getClass(cString('NSProcessInfo')),
      sel(cString('processInfo')),
    );
    final reason = sendStr(
      getClass(cString('NSString')),
      sel(cString('stringWithUTF8String:')),
      cString('flutter_static renders on request'),
    );
    // NSActivityUserInitiatedAllowingIdleSystemSleep: no App Nap, no timer
    // throttling, and the Mac may still sleep on its own schedule.
    const userInitiatedAllowingIdleSystemSleep = 0x00EFFFFF;
    final token = sendActivity(
      processInfo,
      sel(cString('beginActivityWithOptions:reason:')),
      userInitiatedAllowingIdleSystemSleep,
      reason,
    );
    // The activity lives as long as its token; keep it out of the pool.
    send0(token, sel(cString('retain')));
  } catch (e) {
    debugPrint('flutter_static: could not disable App Nap: $e');
  }
}

/// Renders stories into the cache in the background so user-facing requests
/// rarely pay a cold render. Yields between stories to keep the server
/// responsive; exits early when superseded by a newer reload or by a save
/// the CLI has announced (its reload invalidates everything anyway).
///
/// After a hot reload only the hot set (stories clients asked for, most
/// recent first) is warmed right away. The full sweep waits until nobody
/// has saved or rendered for 4 seconds. Someone iterating on one story
/// saves every few seconds; a 130-story sweep after each save would queue
/// their next render behind a minute of work instead of 50ms.
bool _prewarmEnabled = true;

void _prewarm(Stories stories, {required bool initial}) {
  if (!_prewarmEnabled) return;
  final version = _version;
  bool superseded() => _version != version || _reloadPending;
  Future(() async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    Future<bool> yieldToForeground() async {
      // Let interactive requests drain first; warming is idle work.
      while (_foregroundWaiters > 0) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        if (superseded()) return false;
      }
      return !superseded();
    }

    final all = stories.all();
    final byId = {for (final story in all) story.id: story};
    final hot = [
      for (final id in _requested.reversed)
        if (byId[id] != null) byId[id]!,
    ];
    for (final story in hot) {
      if (!await yieldToForeground()) return;
      try {
        await _renderCached(story, background: true);
      } catch (_) {}
    }
    if (!initial) {
      const idle = Duration(seconds: 4);
      while (DateTime.now().difference(_lastActivity) < idle) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        if (superseded()) return;
      }
    }
    // Phase 1: everything that can render offscreen does; stories that
    // need the window fail in milliseconds and are only collected.
    final windowBound = <Story>[];
    for (final story in all) {
      if (!await yieldToForeground()) return;
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
      if (!await yieldToForeground()) return;
      try {
        await _renderCached(story, background: true);
      } catch (_) {}
    }
  });
}

/// Story ids clients rendered this session, oldest first; the prewarm's
/// priority list after a reload.
final _requested = <String>[];

/// Last save or client render; the full prewarm sweep waits for quiet.
DateTime _lastActivity = DateTime.fromMillisecondsSinceEpoch(0);

void _noteRequested(String id) {
  _lastActivity = DateTime.now();
  _requested.remove(id);
  _requested.add(id);
  if (_requested.length > 40) _requested.removeAt(0);
}

/// Reload gate. The CLI announces every save (`pending`) and the outcome
/// of the hot reload it triggers (`done` / `failed`), so a render requested
/// after a save waits for the new code instead of serving pre-save pixels,
/// and a reload the compiler rejected answers with its message instead of
/// a stale image.
bool _reloadPending = false;
String? _reloadError;
String? _reloadMessage;
// Epoch, not now(): top-level initializers run lazily, and a first read from
// inside the gate would make it look like a reload had just landed.
DateTime _reloadReportedAt = DateTime.fromMillisecondsSinceEpoch(0);
final _reloadWaiters = <Completer<void>>[];
final _pendingWaiters = <Completer<void>>[];

void _setReloadState(String state, String? message) {
  switch (state) {
    case 'pending':
      _reloadPending = true;
      _lastActivity = DateTime.now();
      final waiters = List.of(_pendingWaiters);
      _pendingWaiters.clear();
      for (final waiter in waiters) {
        waiter.complete();
      }
    case 'done':
      _reloadPending = false;
      _reloadReportedAt = DateTime.now();
      _reloadError = null;
      _reloadMessage = message;
    case 'failed':
      _reloadPending = false;
      _reloadReportedAt = DateTime.now();
      _reloadError = message ?? 'hot reload failed';
      _reloadMessage = null;
    default:
      return;
  }
  if (!_reloadPending) {
    final waiters = List.of(_reloadWaiters);
    _reloadWaiters.clear();
    for (final waiter in waiters) {
      waiter.complete();
    }
  }
  _broadcastEvent();
}

/// `?settle=<ms>`: how long a request that follows no announced save waits
/// for one before rendering (see [_awaitFresh]).
Duration _settleParam(HttpRequest request) => Duration(
  milliseconds: int.tryParse(request.uri.queryParameters['settle'] ?? '') ?? 0,
);

/// `?edited=<ms since epoch>`: the newest source mtime the caller saw
/// (`flutter_static render` walks the watched roots). Unlike `settle` this
/// does not depend on watcher latency: a save newer than the last reload
/// report has not reached the running code.
DateTime? _editedParam(HttpRequest request) {
  final ms = int.tryParse(request.uri.queryParameters['edited'] ?? '');
  return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
}

/// Waits for the reload that must follow a save at [edited], then for the
/// gate. Returns a note for the response when the save was never announced
/// (the watcher does not cover it, or the CLI is gone).
Future<String?> _awaitEdited(DateTime? edited, Duration settle) async {
  if (edited == null) return _awaitFresh(settle: settle).then((_) => null);
  if (_reloadPending || !edited.isAfter(_reloadReportedAt)) {
    await _awaitFresh();
    return null;
  }
  final completer = Completer<void>();
  _pendingWaiters.add(completer);
  var announced = true;
  await completer.future.timeout(
    const Duration(seconds: 5),
    onTimeout: () {
      _pendingWaiters.remove(completer);
      announced = false;
    },
  );
  if (!announced) {
    return 'a source file was saved at ${edited.toIso8601String()} but no '
        'reload was announced within 5s; is flutter_static run alive and '
        'watching that directory?';
  }
  await _awaitFresh();
  return null;
}

/// Resolves once no reload is pending. Bounded to 90s: a CLI that dies
/// mid-reload would otherwise block every render.
///
/// [settle] closes the gap between a save and the watcher's notice of it
/// (FSEvents delivers ~100ms after the write): unless a reload has just
/// landed, wait up to that long for a `pending` to arrive before deciding
/// the code is current. A render that follows no save merely waits it out.
Future<void> _awaitFresh({Duration settle = Duration.zero}) async {
  if (!_reloadPending &&
      settle > Duration.zero &&
      DateTime.now().difference(_reloadReportedAt) > settle) {
    // A settle window only proves anything if the event loop was free to
    // read the socket during it. A capture can hold the isolate for
    // hundreds of milliseconds; if the timer fired late, the notice may
    // still be unread, so wait out another window (bounded).
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (!_reloadPending && DateTime.now().isBefore(deadline)) {
      final started = DateTime.now();
      final completer = Completer<void>();
      _pendingWaiters.add(completer);
      await completer.future.timeout(
        settle,
        onTimeout: () => _pendingWaiters.remove(completer),
      );
      if (_reloadPending) break;
      final late = DateTime.now().difference(started) - settle;
      if (late < const Duration(milliseconds: 40)) break;
      await Future<void>.delayed(Duration.zero);
    }
  }
  if (!_reloadPending) return;
  final completer = Completer<void>();
  _reloadWaiters.add(completer);
  await completer.future.timeout(
    const Duration(seconds: 90),
    onTimeout: () {
      _reloadWaiters.remove(completer);
      _reloadPending = false;
      _reloadError =
          'the reload announced 90s ago never reported back; '
          'is flutter_static run still alive?';
    },
  );
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

String _eventData() => jsonEncode({
  'version': _version,
  'reloadPending': _reloadPending,
  'reloadError': _reloadError,
});

void _broadcastEvent() {
  catalogReloadTick.value++;
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
  const _CatalogApp({required this.stories, this.shell});

  final Stories stories;
  final CatalogShell? shell;

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
    // Shells survive a reload (a story rarely changes how it lays out,
    // and live cards never capture), but a story that failed offscreen
    // for a transient reason gets another try at its next capture.
    _needsWindow.clear();
    _lastActivity = DateTime.now();
    _prewarm(widget.stories, initial: false);
    _broadcastEvent();
    catalogVersion.value = _version;
  }

  @override
  Widget build(BuildContext context) {
    final mounts = ValueListenableBuilder<List<Story>>(
      valueListenable: _windowStories,
      builder: (context, mounted, _) {
        if (mounted.isEmpty) {
          return widget.shell == null
              ? const Text('flutter_static')
              : const SizedBox.shrink();
        }
        // Their own Material: MaterialApp's fallback text style (the
        // debug yellow underline) must never reach a window capture,
        // whatever shell the window has.
        return Material(
          type: MaterialType.transparency,
          child: Stack(
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
          ),
        );
      },
    );
    if (widget.shell != null) return widget.shell!(context, mounts);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(body: Center(child: mounts)),
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
      if (!background && _reloadPending) {
        // A save landed while this render waited its turn in the queue:
        // capture after its reload, not before.
        await _awaitFresh();
      }
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
      if (path == '/reload' && request.method == 'POST') {
        final body = await utf8.decoder.bind(request).join();
        final json = body.isEmpty
            ? const <String, dynamic>{}
            : jsonDecode(body) as Map<String, dynamic>;
        _setReloadState(
          json['state'] as String? ?? '',
          json['message'] as String?,
        );
        response.statusCode = HttpStatus.noContent;
        await response.close();
      } else if (path == '/index.json') {
        await _awaitEdited(_editedParam(request), _settleParam(request));
        response.headers.contentType = ContentType.json;
        response.write(
          jsonEncode({
            'version': _version,
            'reload': {
              'pending': _reloadPending,
              'error': _reloadError,
              'last': _reloadMessage,
            },
            ...storiesIndex(stories),
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
      } else if (path == '/tokens.json') {
        // The project's design tokens, parsed from source (see tokens.dart).
        final root = _projectRoot();
        if (root == null) {
          response.statusCode = HttpStatus.notFound;
          response.write('project root not found');
        } else {
          response.headers.contentType = ContentType.json;
          response.write(tokensJson(TokenSet.load(root)));
        }
        await response.close();
      } else if (path == '/tokens' && request.method == 'POST') {
        // {"id": "AppColors.primary", "value": "Color(0xFF...)"} rewrites
        // the token's expression; {"id", "arg": "fontSize", "value"} one
        // argument of a TextStyle token. The watcher hot reloads the save.
        final root = _projectRoot();
        final body = jsonDecode(await utf8.decoder.bind(request).join());
        final token = root == null
            ? null
            : TokenSet.load(root).find(body['id'] as String? ?? '');
        if (token == null) {
          response.statusCode = HttpStatus.notFound;
          response.write('no token ${body['id']}');
        } else {
          final arg = body['arg'] as String?;
          final value = body['value'] as String;
          final written = arg == null
              ? writeToken(token, value)
              : writeTokenArg(token, arg, value);
          response.headers.contentType = ContentType.json;
          response.write(jsonEncode(written.toJson()));
        }
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
        final gate = Stopwatch()..start();
        final stale = await _awaitEdited(
          _editedParam(request),
          _settleParam(request),
        );
        gate.stop();
        if (matches.isEmpty) {
          response.statusCode = HttpStatus.notFound;
          await response.close();
        } else if (_reloadError != null) {
          // The code on disk does not compile. A render now would show the
          // previous code, so answer with the compiler error instead.
          response.statusCode = HttpStatus.conflict;
          response.headers.contentType = ContentType.text;
          response.write(
            'hot reload failed; this render would show the pre-edit code.\n'
            'Fix the error and save again:\n\n$_reloadError\n',
          );
          await response.close();
        } else {
          _noteRequested(id);
          // Renders are pure per (story, device, reload version): cached,
          // and capture work is serialized behind _captureQueue.
          final story = _onPage(
            matches.first,
            device: PhoneSpec.byName(request.uri.queryParameters['device']),
            statusBar: request.uri.queryParameters['status'] == '1',
            knobs: _knobsParam(request, _lineOf(stories, id)),
          );
          final capture = Stopwatch()..start();
          final png = await _renderCached(story);
          // A fallback trace carries the exception's message, newlines and
          // all; a header value takes neither.
          response.headers.set(
            'x-render-trace',
            _lastTrace.replaceAll(RegExp(r'[\x00-\x1F\x7F]+'), ' '),
          );
          response.headers.set(
            'x-render-wait',
            'gate=${gate.elapsedMilliseconds}ms '
                'capture=${capture.elapsedMilliseconds}ms',
          );
          if (stale != null) {
            response.headers.set('x-flutter-static-stale', stale);
          }
          response.headers.contentType = ContentType('image', 'png');
          response.add(png);
          await response.close();
        }
      } else if (path.startsWith('/story/') && !path.endsWith('.png')) {
        final id = Uri.decodeComponent(path.substring('/story/'.length));
        final all = stories.all();
        final index = all.indexWhere((s) => s.id == id);
        if (index == -1) {
          // A prefix, not a story ("/story/flows/shell/now/"): what is
          // under it has its own page.
          final prefix = _groupFor('/$id', stories);
          if (prefix != null) {
            response.statusCode = HttpStatus.found;
            response.headers.set('Location', '/$prefix');
          } else {
            response.statusCode = HttpStatus.notFound;
          }
          await response.close();
        } else {
          response.headers.contentType = ContentType.html;
          _isolate(response);
          final line = _lineOf(stories, id);
          response.write(
            _storyDetailPage(
              all,
              index,
              device: PhoneSpec.byName(request.uri.queryParameters['device']),
              statusBar: request.uri.queryParameters['status'] == '1',
              showDevices: line != null,
              knobs: line?.knobs ?? const [],
              chosen: _knobsParam(request, line),
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
      } else if (_groupFor(path, stories) case final prefix?) {
        response.headers.contentType = ContentType.html;
        _isolate(response);
        final lines = stories.storylines().where((l) => l.id == prefix);
        response.write(
          lines.isNotEmpty
              ? _linePage(lines.first, liveBuild: _liveBuildExists())
              : _galleryPage(
                  stories.all(),
                  prefix,
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

/// [story] as the page asked for it: on [device], with or without the
/// status bar, and on the line's knob choices. The frame builders read
/// [DeviceScope], the variants [KnobScope]. A distinct id keeps the render
/// cache per combination; a plain request gets the story itself.
Story _onPage(
  Story story, {
  PhoneSpec? device,
  bool statusBar = false,
  Map<String, String> knobs = const {},
}) {
  final onDevice = device != null || statusBar;
  if (!onDevice && knobs.isEmpty) return story;
  final spec = device ?? PhoneSpec.fallback;
  final id = StringBuffer(story.id);
  if (onDevice) id.write('@${spec.name}${statusBar ? '+status' : ''}');
  for (final entry in knobs.entries) {
    id.write('~${entry.key}=${entry.value}');
  }
  return Story('$id', () {
    var child = story.builder();
    if (onDevice) {
      child = DeviceScope(spec: spec, statusBar: statusBar, child: child);
    }
    if (knobs.isNotEmpty) child = KnobScope(chosen: knobs, child: child);
    return child;
  });
}

/// The `stories` and `lines` of `/index.json`: every story id, and each
/// storyline's rows, cells, variants and knobs.
Map<String, Object?> storiesIndex(Stories stories) => {
  'stories': [
    for (final s in stories.all()) {'id': s.id, 'png': '/story/${s.id}.png'},
  ],
  'lines': [
    for (final line in stories.storylines())
      {
        'id': line.id,
        'title': line.title,
        'page': '/line/${line.id}',
        'rows': [
          for (final row in line.rows)
            {
              'title': row.title,
              'cells': [
                for (final cell in row.cells)
                  {
                    'id': cell.id,
                    'title': cell.title,
                    'variants': [
                      for (final v in cell.variants)
                        {'id': v.id, 'story': '${line.id}/${cell.id}/${v.id}'},
                    ],
                  },
              ],
            },
        ],
        'knobs': [
          for (final knob in line.knobs)
            {
              'id': knob.id,
              'title': knob.title,
              'options': [
                for (final option in knob.options)
                  {'id': option.id, 'title': option.title},
              ],
            },
        ],
      },
  ],
};

/// The storyline [id] is a variant of, if any.
Storyline? _lineOf(Stories stories, String id) {
  for (final line in stories.storylines()) {
    if (line.stories.any((s) => s.id == id)) return line;
  }
  return null;
}

/// The knob choices in `?k.<knob>=<option>`, kept to the knobs [line]
/// declares and the options they have, and never the default (first)
/// option. One spelling per choice, so the render cache has one entry
/// for it.
Map<String, String> _knobsParam(HttpRequest request, Storyline? line) {
  if (line == null) return const {};
  final params = request.uri.queryParameters;
  final chosen = <String, String>{};
  for (final knob in line.knobs) {
    final option = params['k.${knob.id}'];
    if (option == null || option == knob.options.first.id) continue;
    if (knob.options.any((o) => o.id == option)) chosen[knob.id] = option;
  }
  return chosen;
}

/// `&k.<knob>=<option>` for every choice in [knobs].
String _knobQuery(Map<String, String> knobs) => [
  for (final entry in knobs.entries)
    '&k.${Uri.encodeQueryComponent(entry.key)}='
        '${Uri.encodeQueryComponent(entry.value)}',
].join();

/// The device and status-bar toggles for pages of storyline variants, and
/// the line's knobs after them. As buttons for the line page, whose script
/// re-renders in place; as links for the story page, which reloads.
String _deviceToolbar({
  String? selected,
  bool statusBar = false,
  bool links = false,
  List<Knob<Object?>> knobs = const [],
  Map<String, String> chosen = const {},
}) {
  final buffer = StringBuffer('<div class="toolbar"><span>Enhet</span>');
  final device = selected ?? PhoneSpec.all.first.name;
  final current = {
    'device': device,
    if (statusBar) 'status': '1',
    for (final entry in chosen.entries) 'k.${entry.key}': entry.value,
  };
  // The link for one change: [current] with [key] set (or dropped).
  String href(String key, String? value) {
    final params = Map.of(current);
    if (value == null) {
      params.remove(key);
    } else {
      params[key] = value;
    }
    return _escape(
      '?${params.entries.map((e) => '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}').join('&')}',
    );
  }

  for (final spec in PhoneSpec.all) {
    final cls = spec.name == device ? 'device on' : 'device';
    buffer.write(
      links
          ? '<a class="$cls" href="${href('device', spec.name)}">${_escape(spec.label)}</a>'
          : '<button class="$cls" data-device="${spec.name}">${_escape(spec.label)}</button>',
    );
  }
  buffer.write('<span class="sep">Statuslinje</span>');
  for (final (value, label) in [('1', 'P&aring;'), ('0', 'Av')]) {
    final cls = (value == '1') == statusBar ? 'status on' : 'status';
    buffer.write(
      links
          ? '<a class="$cls" href="${href('status', value == '1' ? '1' : null)}">$label</a>'
          : '<button class="$cls" data-status="$value">$label</button>',
    );
  }
  for (final knob in knobs) {
    if (knob.options.isEmpty) continue;
    buffer.write('<span class="sep">${_escape(knob.title ?? knob.id)}</span>');
    final picked = chosen[knob.id] ?? knob.options.first.id;
    for (final (i, option) in knob.options.indexed) {
      final cls = option.id == picked ? 'knob on' : 'knob';
      final label = _escape(option.title ?? option.id);
      buffer.write(
        links
            ? '<a class="$cls" href="${href('k.${knob.id}', i == 0 ? null : option.id)}">$label</a>'
            : '<button class="$cls" data-knob="${_escape(knob.id)}" data-value="${_escape(option.id)}">$label</button>',
      );
    }
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
    _storyShells[_baseId(story.id)] = StoryShell.window;
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

/// What Flutter reported while offscreen captures were pumping. A story
/// whose capture reported anything is handed to the window: some of what
/// fails only fails offscreen (View.of has no answer here, and
/// ScrollAwareImageProvider asks for it when an image inside a Scrollable
/// is not cached yet), and Image paints that failure as a Placeholder
/// rather than an ErrorWidget, so the tree cannot be inspected for it.
/// Captures can overlap, so an error may be pinned on a neighbour; that
/// story only loses the fast path, and the window renders it right.
final _reportedErrors = <FlutterErrorDetails>[];
int _capturesInFlight = 0;
bool _errorHookInstalled = false;

void _installErrorHook() {
  if (_errorHookInstalled) return;
  _errorHookInstalled = true;
  final previous = FlutterError.onError;
  FlutterError.onError = (details) {
    if (_capturesInFlight > 0) _reportedErrors.add(details);
    previous?.call(details);
  };
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
  Widget shell(Widget inner, {required bool unbounded}) => _storyEnvironment(
    unbounded
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
              constraints: const BoxConstraints(maxWidth: 430, maxHeight: 932),
              child: inner,
            ),
          ),
    theme,
  );

  _installErrorHook();
  if (_capturesInFlight == 0) _reportedErrors.clear();
  _capturesInFlight++;
  final errorsBefore = _reportedErrors.length;

  // The first build happens in attachToRenderTree, so it must be inside
  // the counted window: a story that only throws on its first build (Ink,
  // and so ListTile, reads a GlobalKey the offscreen owner never
  // registers) would otherwise pass as a render of its ErrorWidgets.
  final RenderObjectToWidgetElement<RenderBox> root;
  try {
    root = RenderObjectToWidgetAdapter<RenderBox>(
      container: container,
      child: shell(story.builder(), unbounded: true),
    ).attachToRenderTree(buildOwner);
  } catch (_) {
    _capturesInFlight--;
    rethrow;
  }

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
    _storyShells[_baseId(story.id)] = unboundedOk
        ? StoryShell.unbounded
        : StoryShell.bounded;
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
    // Real frames while the window has vsync (Studio: a visible window
    // with live tickers, which must see monotonic timestamps); synthetic
    // timestamps once it has none (the hidden catalog window), so even
    // infinitely-animating stories capture in tens of milliseconds.
    var synthetic = binding.currentSystemFrameTimeStamp;
    var vsync = binding.framesEnabled;
    final budget = DateTime.now().add(const Duration(seconds: 2));
    for (var i = 0; i < 60 && DateTime.now().isBefore(budget); i++) {
      final animating = binding.transientCallbackCount > baselineTickers;
      if (i >= 3 && !animating && !_imagesPending) break;
      if (animating) {
        if (vsync) {
          try {
            await binding.endOfFrame.timeout(const Duration(milliseconds: 100));
          } on TimeoutException {
            vsync = false;
          }
        }
        if (!vsync) {
          synthetic += const Duration(milliseconds: 16);
          try {
            binding.handleBeginFrame(synthetic);
            binding.handleDrawFrame();
          } catch (_) {
            // A real engine frame was mid-flight; skip this pump.
          }
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 4));
      pump();
    }
    mark('anim-pumps');
    // A capture that reported an error is not a render; see
    // [_reportedErrors].
    if (_reportedErrors.length > errorsBefore) {
      final first = _reportedErrors[errorsBefore];
      throw StateError(
        'offscreen capture reported: ${first.exceptionAsString()}',
      );
    }
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
    _capturesInFlight--;
    // Drain one binding frame while the tree is still mounted: widgets
    // like EditableText schedule post-frame callbacks that must run
    // against a live State, or they null-check on every later frame.
    var drained = false;
    if (binding.framesEnabled) {
      try {
        await binding.endOfFrame.timeout(const Duration(milliseconds: 100));
        drained = true;
      } on TimeoutException {
        drained = false;
      }
    }
    if (!drained) {
      try {
        binding.handleBeginFrame(
          binding.currentSystemFrameTimeStamp +
              const Duration(milliseconds: 16),
        );
        binding.handleDrawFrame();
      } catch (_) {}
    }
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
  } while ((binding.hasScheduledFrame ||
          binding.transientCallbackCount > 0 ||
          _imagesPending) &&
      DateTime.now().isBefore(deadline));
}

/// An image still being read or decoded. Neither schedules a frame nor
/// ticks, so a settle that only watched those captured the first render
/// of a story with a fresh file as a blank box, and served it until the
/// next reload.
bool get _imagesPending =>
    PaintingBinding.instance.imageCache.pendingImageCount > 0;

String _storyDetailPage(
  List<Story> all,
  int index, {
  PhoneSpec? device,
  bool statusBar = false,
  bool showDevices = false,
  List<Knob<Object?>> knobs = const [],
  Map<String, String> chosen = const {},
}) {
  final story = all[index];
  final id = _escape(story.id);
  final dev =
      '${device == null ? '' : '&device=${device.name}'}${statusBar ? '&status=1' : ''}'
      '${_knobQuery(chosen)}';
  final toolbar = showDevices
      ? _deviceToolbar(
          selected: device?.name,
          statusBar: statusBar,
          links: true,
          knobs: knobs,
          chosen: chosen,
        )
      : '';
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
h1 a{color:inherit}h1 a:hover{color:#9B9FAB}
h1 .slash{color:#6B6E7A;margin:0 2px}
.nav{font-size:12px;display:flex;gap:16px}
section{margin:0 0 28px}
section h2{font-size:12px;text-transform:uppercase;letter-spacing:.08em;color:#6B6E7A;margin:0 0 10px}
.png{background:#131518;border-radius:12px;padding:16px;display:inline-block;max-width:100%}
.png img{display:block;max-width:min(840px,100%);height:auto;border-radius:8px}
#live{background:#131518;border-radius:12px;padding:16px;min-height:120px;display:flex;align-items:center;justify-content:center;resize:vertical;overflow:hidden}
#live .hint{color:#6B6E7A;font-size:12.5px}
.toolbar{margin:-12px 0 16px;font-size:12px;color:#9B9FAB;display:flex;gap:8px;align-items:center}
.toolbar .device,.toolbar .status,.toolbar .knob{font:inherit;color:#9B9FAB;background:#131518;border:1px solid #2A2D35;border-radius:8px;padding:4px 10px;text-decoration:none}
.toolbar .device.on,.toolbar .status.on,.toolbar .knob.on{color:#E2E4E9;border-color:#6B6E7A}
.toolbar .sep{margin-left:12px}
#host{width:100%;height:100%;min-height:120px}
</style></head><body>
<div class="nav"><a href="/">&larr; alle</a>
<a href="/story/${_escape(prev)}">&larr; forrige</a><a href="/story/${_escape(next)}">neste &rarr;</a>
<a href="/story/$id.png">png</a></div>
<h1>${_crumbs(story.id)}</h1>
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
const KNOBS = ${jsonEncode(chosen)};
const KNOB_QUERY = ${jsonEncode(_knobQuery(chosen))};
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
      img.src = '/story/' + STORY + '.png?v=' + d.version + (DEVICE ? '&device=' + DEVICE : '') + (STATUS ? '&status=1' : '') + KNOB_QUERY;
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
      if (Object.keys(KNOBS).length) data.knobs = KNOBS;
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
/// The id prefix when [path] is one that stories live under ("/tokens"
/// -> "tokens", "/flows/shell/now" -> "flows/shell/now"), else null.
String? _groupFor(String path, Stories stories) {
  final prefix = Uri.decodeComponent(
    path.substring(1),
  ).replaceAll(RegExp(r'/+$'), '');
  if (prefix.isEmpty) return null;
  return stories.all().any((s) => s.id.startsWith('$prefix/')) ? prefix : null;
}

bool _under(String id, String prefix) =>
    id == prefix || id.startsWith('$prefix/');

/// [id] as a path of links: every prefix is a page (a gallery of what is
/// under it, or the storyline it names); the last segment links to
/// [last], or stays text.
String _crumbs(String id, {String? last}) {
  final parts = id.split('/');
  final buffer = StringBuffer();
  for (var i = 0; i < parts.length; i++) {
    if (i > 0) buffer.write('<span class="slash">/</span>');
    final isLast = i == parts.length - 1;
    final href = isLast ? last : '/${parts.sublist(0, i + 1).join('/')}';
    final text = _escape(parts[i]);
    buffer.write(href == null ? text : '<a href="${_escape(href)}">$text</a>');
  }
  return '$buffer';
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
      .replaceFirst('{{TOOLBAR}}', _deviceToolbar(knobs: line.knobs))
      .replaceFirst('{{GROUP_LIST}}', '[]')
      .replaceFirst('{{FILTER}}', line.id)
      .replaceFirst('{{LINE}}', 'true')
      .replaceFirst(
        '{{BACK}}',
        '<a class="back" href="/">&larr; alle grupper</a>'
            '<div class="name">${_crumbs(line.id)}</div>'
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
  final name = label == null
      ? _crumbs(id, last: '/story/$id')
      : '<a href="/story/$e">${_escape(label)}</a>';
  return '<div class="card" data-id="$e"><figure>'
      '<a class="media" href="/story/$e">'
      '<img src="$src" alt="$e" loading="lazy" decoding="async"></a>'
      '<div class="name">$name</div></figure></div>';
}

String _galleryGroupsHtml(List<Story> stories, String? only) {
  final groups = <String, List<Story>>{};
  for (final story in stories) {
    if (only != null && !_under(story.id, only)) continue;
    final group = only ?? story.id.split('/').first;
    groups.putIfAbsent(group, () => []).add(story);
  }
  final buffer = StringBuffer();
  groups.forEach((group, members) {
    buffer.write(
      '<h2>${_crumbs(group, last: '/$group')}</h2><div class="grid">',
    );
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
.host{position:absolute;left:0;top:0;border-radius:8px;overflow:hidden;pointer-events:none;transition:opacity .15s}
/* Hovering a card lifts the live view: the png under it is the current
   render and links to the story page. Leave, and the view is back. */
.card:hover .host{opacity:0;pointer-events:none!important}
.card.booting img{opacity:.5;transition:opacity .3s}
h1.line{font-size:16px;font-family:ui-monospace,monospace;margin:8px 0 0}
.toolbar{margin:16px 0 0;font-size:12px;color:#9B9FAB;display:flex;gap:8px;align-items:center}
.toolbar .device{font:inherit;color:#9B9FAB;background:#131518;border:1px solid #2A2D35;border-radius:8px;padding:4px 10px;cursor:pointer;text-decoration:none}
.toolbar .device.on,.toolbar .status.on,.toolbar .knob.on{color:#E2E4E9;border-color:#6B6E7A}
.toolbar .status,.toolbar .knob{font:inherit;color:#9B9FAB;background:#131518;border:1px solid #2A2D35;border-radius:8px;padding:4px 10px;cursor:pointer;text-decoration:none}
.toolbar .sep{margin-left:12px}
.lines a{display:inline-block;margin:0 12px 8px 0;font-family:ui-monospace,monospace;font-size:12px;color:#9B9FAB;text-decoration:none}
.lines a:hover{color:#E2E4E9}
.cell{display:flex;flex-direction:column;gap:16px}
.cell h3{font-size:12px;color:#9B9FAB;margin:0;font-family:ui-monospace,monospace;font-weight:500}
.name{display:block;margin-top:8px;font-size:12px;color:#6B6E7A;font-family:ui-monospace,monospace}
.name a{color:inherit;text-decoration:none}
.name a:hover{color:#E2E4E9}
.slash{margin:0 1px}
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
// FILTER is an id prefix: 'flows', 'flows/shell/now', ...
const inFilter = (id) => !FILTER || id === FILTER || id.startsWith(FILTER + '/');
// An id as a path of links; the last segment goes to `last` or stays text.
function crumbs(id, last) {
  const box = document.createDocumentFragment();
  const parts = id.split('/');
  parts.forEach((part, i) => {
    if (i) { const s = document.createElement('span'); s.className = 'slash'; s.textContent = '/'; box.appendChild(s); }
    const href = i === parts.length - 1 ? last : '/' + parts.slice(0, i + 1).join('/');
    if (!href) { box.appendChild(document.createTextNode(part)); return; }
    const a = document.createElement('a'); a.href = href; a.textContent = part; box.appendChild(a);
  });
  return box;
}
const GROUPS = {{GROUP_LIST}};
const LIVE_BUILD = {{LIVE_BUILD}};
// Live views from the static build (flutter_static build-web) at /live/:
// inside a group every card goes live while it is near the viewport; the
// front page keeps its pngs and swaps a card for the real widget on
// hover. The engine boots on first need, not on page load. The png stays
// the size reference (rendered at 2x), the fallback for automation, and
// what a hovered card shows: it follows every hot reload, while the view
// runs the last build-web.
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
// Knobs (storyline pages): the line's mock switches. A choice is the
// option's id, absent when it is the default (the first button), and
// sticks per browser and line.
let KNOBS = {};
const knobButtons = [...document.querySelectorAll('.toolbar button.knob')];
const knobDefault = (knob) => knobButtons.find((b) => b.dataset.knob === knob);
if (knobButtons.length) {
  let saved = {};
  try { saved = JSON.parse(localStorage.getItem('fs-knobs:' + FILTER)) || {}; } catch (e) {}
  for (const b of knobButtons) {
    if (saved[b.dataset.knob] === b.dataset.value && knobDefault(b.dataset.knob) !== b) KNOBS[b.dataset.knob] = b.dataset.value;
  }
  for (const b of knobButtons) b.addEventListener('click', () => {
    if (knobDefault(b.dataset.knob) === b) delete KNOBS[b.dataset.knob]; else KNOBS[b.dataset.knob] = b.dataset.value;
    try { localStorage.setItem('fs-knobs:' + FILTER, JSON.stringify(KNOBS)); } catch (e) {}
    setDevice(DEVICE);
  });
}
function knobQuery() { return Object.entries(KNOBS).map(([k, v]) => '&k.' + encodeURIComponent(k) + '=' + encodeURIComponent(v)).join(''); }
// No undefined values in view data: the Dart side cannot convert them.
function viewData(id) {
  const data = {storyId: id};
  if (DEVICE) data.device = DEVICE;
  if (STATUS) data.status = true;
  if (Object.keys(KNOBS).length) data.knobs = {...KNOBS};
  return data;
}
function pngUrl(id, v) { return '/story/' + id + '.png?v=' + v + (DEVICE ? '&device=' + DEVICE : '') + (STATUS ? '&status=1' : '') + knobQuery(); }
function setDevice(d) {
  DEVICE = d;
  try { localStorage.setItem('fs-device', d); } catch (e) {}
  for (const b of deviceButtons) b.classList.toggle('on', b.dataset.device === d);
  for (const b of statusButtons) b.classList.toggle('on', (b.dataset.status === '1') === STATUS);
  for (const b of knobButtons) b.classList.toggle('on', (KNOBS[b.dataset.knob] ?? knobDefault(b.dataset.knob).dataset.value) === b.dataset.value);
  // A device (or a knob, whose data may change the size) changes a
  // variant: back to a plain png card, which remounts (live cards) from
  // the new render's size.
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
if (deviceButtons.length && (DEVICE !== deviceButtons[0].dataset.device || STATUS || Object.keys(KNOBS).length)) setDevice(DEVICE);
else { for (const b of deviceButtons) b.classList.toggle('on', b.dataset.device === DEVICE); observeAll(); armHover(); }
// Left/right arrows cycle through the group pages.
document.addEventListener('keydown', (e) => {
  if (e.key !== 'ArrowLeft' && e.key !== 'ArrowRight') return;
  if (!GROUPS.length) return;
  const delta = e.key === 'ArrowRight' ? 1 : -1;
  const i = GROUPS.indexOf(FILTER.split('/')[0]);
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
      for (const img of document.querySelectorAll('.card img')) img.src = pngUrl(img.alt, v);
    }
    return;
  }
  const idx = await (await fetch('/index.json')).json();
  const ids = idx.stories.map((s) => s.id).filter(inFilter);
  const shown = [...document.querySelectorAll('.card')].map((c) => c.dataset.id);
  if (ids.join('|') === shown.join('|')) {
    // Same stories: refresh the PNGs (the live views only change with a
    // new build-web; the png under each is what a hover shows).
    if ((v ?? idx.version) !== shownVersion) {
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
    if (!inFilter(s.id)) continue;
    const g = FILTER || s.id.split('/')[0];
    (groups[g] ??= []).push(s);
  }
  const root = document.getElementById('groups');
  root.innerHTML = '';
  for (const [g, stories] of Object.entries(groups)){
    const h = document.createElement('h2');
    h.appendChild(crumbs(g, '/' + g)); root.appendChild(h);
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
      const name = document.createElement('div');
      name.className = 'name';
      name.appendChild(crumbs(s.id, '/story/' + s.id));
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
