/// Studio's state: the child catalog process, its HTTP API, the PNG cache,
/// the SSE stream that says when renders changed, and the project's
/// tokens. One [ChangeNotifier]; the views rebuild off it.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../tokens.dart';
import 'model.dart';

enum CatalogStatus { stopped, starting, ready, reloading, error }

/// One fetched render, with the version it was captured at.
class StoryPng {
  const StoryPng(this.bytes, this.version);

  final Uint8List bytes;
  final int version;
}

class StudioController extends ChangeNotifier {
  StudioController({
    required this.project,
    required this.port,
    required this.packageRoot,
  });

  final String project;
  final int port;

  /// The flutter_static checkout whose CLI runs the child.
  final String packageRoot;

  String get url => 'http://localhost:$port';
  String get projectName => project.split('/').last;

  CatalogStatus status = CatalogStatus.stopped;
  String? statusDetail;
  final logs = <String>[];
  bool showLogs = false;

  List<StudioPage> pages = const [];
  int version = -1;
  String? reloadError;
  String? selectedPageId;
  String? selectedStoryId;

  /// The token group open in the right panel, or null for the inspector.
  String? selectedTokenGroup;
  TokenSet? tokens;

  /// Render options for storyline pages.
  String? device;
  bool statusBar = false;
  final knobs = <String, String>{};

  final _pngs = <String, StoryPng>{};
  final _inflight = <String>{};
  final _queue = <String>[];
  int _fetching = 0;
  static const _maxParallel = 3;

  HttpClient? _events;
  Process? _child;
  bool _disposed = false;

  StudioPage? get selectedPage {
    for (final p in pages) {
      if (p.id == selectedPageId) return p;
    }
    return pages.isEmpty ? null : pages.first;
  }

  // --- process ------------------------------------------------------------

  void log(String line) {
    logs.add(line);
    if (logs.length > 500) logs.removeRange(0, logs.length - 500);
    notifyListeners();
  }

  /// `flutter_static up` in the project: setup if needed, the runner in
  /// the background, returns once a story rendered.
  Future<void> start({bool restart = false}) async {
    if (status == CatalogStatus.starting) return;
    _setStatus(CatalogStatus.starting, 'starting catalog on :$port');
    final code = await _cli([
      'up',
      '--port',
      '$port',
      '--timeout',
      '900',
      if (restart) '--restart',
    ]);
    if (_disposed) return;
    if (code != 0) {
      _setStatus(CatalogStatus.error, 'flutter_static up exited with $code');
      return;
    }
    await refreshIndex();
    loadTokens();
    _listenEvents();
    if (status != CatalogStatus.error) _setStatus(CatalogStatus.ready, null);
  }

  Future<void> stop() async {
    _events?.close(force: true);
    _events = null;
    await _cli(['down']);
    _pngs.clear();
    _setStatus(CatalogStatus.stopped, null);
  }

  Future<int> _cli(List<String> args) async {
    final script = '$packageRoot/bin/flutter_static.dart';
    final process = await Process.start('dart', [
      script,
      ...args,
    ], workingDirectory: project);
    _child = process;
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(log);
    process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((l) => log('! $l'));
    final code = await process.exitCode;
    _child = null;
    return code;
  }

  void _setStatus(CatalogStatus s, String? detail) {
    status = s;
    statusDetail = detail;
    notifyListeners();
  }

  // --- http ---------------------------------------------------------------

  Future<Uint8List> _get(String path) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse('$url$path'));
      final response = await request.close();
      final builder = BytesBuilder(copy: false);
      await for (final chunk in response) {
        builder.add(chunk);
      }
      final bytes = builder.takeBytes();
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException(
          '${response.statusCode}: ${utf8.decode(bytes, allowMalformed: true)}',
        );
      }
      return bytes;
    } finally {
      client.close();
    }
  }

  Future<void> refreshIndex() async {
    try {
      final index =
          jsonDecode(utf8.decode(await _get('/index.json')))
              as Map<String, dynamic>;
      pages = pagesFromIndex(index);
      final reload = index['reload'] as Map?;
      reloadError = reload?['error'] as String?;
      version = index['version'] as int? ?? version;
      selectedPageId ??= pages.isEmpty ? null : pages.first.id;
      if (selectedPage?.id != selectedPageId) {
        selectedPageId = selectedPage?.id;
      }
      notifyListeners();
    } catch (e) {
      log('index.json: $e');
      _setStatus(CatalogStatus.error, 'index.json: $e');
    }
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

  // --- renders ------------------------------------------------------------

  String _query(String id) {
    final params = <String, String>{'v': '$version'};
    if (device != null) params['device'] = device!;
    if (statusBar) params['status'] = '1';
    for (final entry in knobs.entries) {
      params['k.${entry.key}'] = entry.value;
    }
    return Uri(queryParameters: params).query;
  }

  /// The latest render of [id], fetching a fresh one when it is behind
  /// [version]. Returns the stale one meanwhile so cards never blank.
  StoryPng? png(String id) {
    final cached = _pngs[id];
    if ((cached == null || cached.version != version) &&
        status != CatalogStatus.stopped &&
        version >= 0) {
      _enqueue(id);
    }
    return cached;
  }

  bool isFetching(String id) => _inflight.contains(id) || _queue.contains(id);

  void _enqueue(String id) {
    if (_inflight.contains(id) || _queue.contains(id)) return;
    _queue.add(id);
    _pump();
  }

  void _pump() {
    while (_fetching < _maxParallel && _queue.isNotEmpty) {
      final id = _queue.removeAt(0);
      _inflight.add(id);
      _fetching++;
      final wanted = version;
      _get('/story/$id.png?${_query(id)}')
          .then((bytes) {
            if (_disposed) return;
            _pngs[id] = StoryPng(bytes, wanted);
          })
          .catchError((Object e) {
            if (_disposed) return;
            final text = '$e';
            // 409 means the code on disk does not compile: the catalog
            // already told us over /events; keep the old render.
            if (!text.contains('409')) log('render $id: $text');
          })
          .whenComplete(() {
            if (_disposed) return;
            _inflight.remove(id);
            _fetching--;
            notifyListeners();
            _pump();
          });
    }
  }

  /// Drops a render so the next paint fetches it again.
  void rerender(String id) {
    _pngs.remove(id);
    notifyListeners();
  }

  // --- events -------------------------------------------------------------

  Future<void> _listenEvents() async {
    _events?.close(force: true);
    final client = HttpClient();
    _events = client;
    try {
      final request = await client.getUrl(Uri.parse('$url/events'));
      final response = await request.close();
      var buffer = '';
      await for (final chunk in response.transform(utf8.decoder)) {
        buffer += chunk;
        while (true) {
          final end = buffer.indexOf('\n\n');
          if (end == -1) break;
          final frame = buffer.substring(0, end);
          buffer = buffer.substring(end + 2);
          for (final line in frame.split('\n')) {
            if (line.startsWith('data:')) {
              _onEvent(jsonDecode(line.substring(5).trim()) as Map);
            }
          }
        }
      }
      if (!_disposed && _events == client) {
        _setStatus(CatalogStatus.error, 'catalog event stream closed');
      }
    } catch (e) {
      if (!_disposed && _events == client) {
        _setStatus(CatalogStatus.error, 'events: $e');
      }
    }
  }

  Future<void> _onEvent(Map data) async {
    final pending = data['reloadPending'] == true;
    final error = data['reloadError'] as String?;
    final v = data['version'] as int? ?? version;
    reloadError = error;
    if (error != null) {
      _setStatus(CatalogStatus.error, 'hot reload failed');
    } else if (pending) {
      _setStatus(CatalogStatus.reloading, 'reloading');
    } else {
      _setStatus(CatalogStatus.ready, null);
    }
    if (v != version) {
      version = v;
      // Stories may have been added or renamed; tokens may have changed
      // on disk (an agent editing the file is the point).
      await refreshIndex();
      loadTokens();
    }
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
  /// tokens so spans stay right for the next edit. The catalog's watcher
  /// picks up the save; the render refresh comes back over /events.
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
    _events?.close(force: true);
    _child?.kill();
    super.dispose();
  }
}
