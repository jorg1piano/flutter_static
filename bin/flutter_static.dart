import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:args/command_runner.dart';
import 'package:flutter_static/src/tokens.dart';
import 'package:path/path.dart' as p;
import 'package:watcher/watcher.dart';

/// Catalog URL for the current directory: the port registered for it in
/// ~/.flutter_static/ports.jsonl, else the base port.
String _defaultUrl() =>
    'http://localhost:${_PortRegistry.lookup() ?? _PortRegistry.basePort}';

Directory _flutterStaticHome() => Directory(
  Platform.environment['FLUTTER_STATIC_HOME'] ??
      p.join(Platform.environment['HOME'] ?? '.', '.flutter_static'),
);

Future<void> main(List<String> arguments) async {
  final runner =
      CommandRunner<int>(
          'flutter_static',
          'Widget story catalog: PNG renders over HTTP.',
        )
        ..addCommand(_UpCommand())
        ..addCommand(_DownCommand())
        ..addCommand(_RunCommand())
        ..addCommand(_StudioCommand())
        ..addCommand(_StudioHostCommand())
        ..addCommand(_InitCommand())
        ..addCommand(_BuildWebCommand())
        ..addCommand(_SetupCommand())
        ..addCommand(_ListCommand())
        ..addCommand(_RenderCommand())
        ..addCommand(_InspectCommand())
        ..addCommand(_PortCommand())
        ..addCommand(_TokensCommand())
        ..addCommand(_AddCommand());
  try {
    exitCode = await runner.run(arguments) ?? 0;
  } on UsageException catch (e) {
    stderr.writeln(e);
    exitCode = 64;
  }
}

class _RunCommand extends Command<int> {
  _RunCommand() {
    argParser
      ..addOption(
        'target',
        abbr: 't',
        defaultsTo: 'story/main.dart',
        help: 'Entry point that calls runFlutterStatic().',
      )
      ..addOption('device', abbr: 'd', defaultsTo: 'macos')
      ..addOption(
        'port',
        help:
            'Catalog server port. Default: the port registered for this '
            'directory in ~/.flutter_static/ports.jsonl, allocating the next '
            'free one on first use.',
      )
      ..addOption(
        'snapshots',
        allowed: const ['off', 'jj'],
        defaultsTo: Platform.environment['FLUTTER_STATIC_SNAPSHOTS'] ?? 'off',
        help:
            'Snapshot successful reloads. "jj" commits the current change '
            'after each save-triggered hot reload.',
      );
  }

  @override
  String get name => 'run';
  @override
  String get description =>
      'Launch the catalog app and hot reload it on every source change.';

  @override
  Future<int> run() async {
    final target = argResults!['target'] as String;
    if (!File(target).existsSync()) {
      stderr.writeln(
        'Target $target not found. Scaffold one with: flutter_static setup',
      );
      return 1;
    }
    if (argResults!['device'] == 'macos' && !Directory('macos').existsSync()) {
      stderr.writeln(
        'This project has no macOS runner (the catalog renders on desktop). '
        'Add one with: flutter_static setup',
      );
      return 1;
    }
    final requested = argResults!['port'] as String?;
    final port = await _PortRegistry.claim(
      requested: requested == null ? null : int.tryParse(requested),
    );
    if (port == null) {
      stderr.writeln('Invalid port: $requested');
      return 64;
    }
    stdout.writeln(
      'flutter_static: catalog port $port '
      '(registered in ${_PortRegistry.file.path})',
    );
    return _Runner(
      target: target,
      device: argResults!['device'] as String,
      port: port,
      snapshots: _Snapshots.from(argResults!['snapshots'] as String),
    ).run();
  }
}

/// `flutter_static up`: setup, start the catalog, block until it renders.
///
/// Runs setup (a no-op when everything exists), then reuses this project's
/// runner when one is alive, restarts it with `--restart`, or starts one
/// detached with its output in `.dart_tool/flutter_static.log`. Returns
/// once `/index.json` answers, the story is listed, and one render of it
/// has passed the freshness gate, so the caller cannot get ahead of the
/// build or the first reload.
class _UpCommand extends Command<int> {
  _UpCommand() {
    argParser
      ..addOption(
        'story',
        abbr: 's',
        help:
            'Story id that must be listed and rendered before up returns '
            '(default: the first listed story).',
      )
      ..addOption(
        'out',
        abbr: 'o',
        help:
            'Where to write that render '
            '(default: .dart_tool/flutter_static_up.png).',
      )
      ..addOption(
        'timeout',
        defaultsTo: '900',
        help:
            'Seconds to wait for the catalog to answer; the first macOS '
            'build of a project takes minutes.',
      )
      ..addOption('port', help: 'Forwarded to run.')
      ..addOption(
        'org',
        help: 'Forwarded to setup when a macOS runner has to be created.',
      )
      ..addFlag(
        'restart',
        negatable: false,
        help: 'Stop the running catalog for this project first.',
      );
  }

  @override
  String get name => 'up';
  @override
  String get description =>
      'Setup if needed, start the catalog in the background, and return '
      'only once it answers and a story has rendered.';

  static final logFile = File('.dart_tool/flutter_static.log');

  @override
  Future<int> run() async {
    final started = Stopwatch()..start();
    if (!File('pubspec.yaml').existsSync()) {
      stderr.writeln(
        'No pubspec.yaml here. Run up from the root of the Flutter project '
        'that hosts (or should host) the stories.',
      );
      return 1;
    }
    final timeout = Duration(
      seconds: int.tryParse(argResults!['timeout'] as String) ?? 900,
    );

    // 1. Setup: story/, the dependency, pub get, a macOS runner. A no-op
    //    when all of it exists.
    final org = argResults!['org'] as String?;
    final setup = await _self([
      'setup',
      if (org != null) ...['--org', org],
    ], quiet: true);
    if (setup != 0) return setup;

    // 2. A runner for this project.
    final requested = argResults!['port'] as String?;
    final port = await _PortRegistry.claim(
      requested: requested == null ? null : int.tryParse(requested),
    );
    if (port == null) {
      stderr.writeln('Invalid port: $requested');
      return 64;
    }
    final url = 'http://localhost:$port';
    var pid = _runnerPid();
    if (pid != null && argResults!['restart'] as bool) {
      await _DownCommand.stop(pid, port);
      pid = null;
    }
    if (pid != null) {
      stdout.writeln(
        'flutter_static: catalog runner already alive (pid $pid); '
        'waiting for it.',
      );
    } else {
      _DownCommand.killPortHolders(port);
      pid = await _launch(port);
      stdout.writeln(
        'flutter_static: started the catalog runner (pid $pid), '
        'log: ${logFile.path}',
      );
    }

    // 3. The catalog answers.
    final deadline = DateTime.now().add(timeout);
    var lastNote = DateTime.now();
    while (await _StoryDir._index(url) == null) {
      if (_runnerPid() == null) {
        stderr.writeln('flutter_static: the runner exited. Log tail:');
        _tailLog();
        return 1;
      }
      if (DateTime.now().isAfter(deadline)) {
        stderr.writeln(
          'flutter_static: no catalog at $url after ${timeout.inSeconds}s. '
          'Log tail:',
        );
        _tailLog();
        return 1;
      }
      if (DateTime.now().difference(lastNote) > const Duration(seconds: 15)) {
        lastNote = DateTime.now();
        stdout.writeln(
          'flutter_static: still building '
          '(${started.elapsed.inSeconds}s), last log line: ${_lastLogLine()}',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }

    // 4. The story is listed (a just-added one is a hot reload away).
    final wanted = argResults!['story'] as String?;
    final listDeadline = DateTime.now().add(const Duration(seconds: 30));
    String id;
    while (true) {
      final ids = await _StoryDir._index(url) ?? const <String>{};
      if (wanted == null && ids.isNotEmpty) {
        id = ids.first;
        break;
      }
      if (wanted != null && ids.contains(wanted)) {
        id = wanted;
        break;
      }
      if (DateTime.now().isAfter(listDeadline)) {
        stderr.writeln(
          wanted == null
              ? 'flutter_static: the catalog at $url lists no stories. Add '
                    'one with: flutter_static add story <group>/<name>'
              : 'flutter_static: "$wanted" is not listed at $url. Listed: '
                    '${ids.isEmpty ? '(none)' : ids.take(20).join(', ')}. '
                    'Add it with: flutter_static add story $wanted',
        );
        return 1;
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }

    // 5. It renders. Goes through the gate: a save made during the build
    //    has reloaded by the time this returns.
    final out =
        (argResults!['out'] as String?) ?? '.dart_tool/flutter_static_up.png';
    final render = Stopwatch()..start();
    final written = await _renderStory(id, url, out);
    if (written == null) {
      stderr.writeln(
        'flutter_static: the catalog answers but "$id" did not render. '
        'Log tail:',
      );
      _tailLog();
      return 1;
    }
    final count = (await _StoryDir._index(url))?.length ?? 0;
    stdout.writeln(
      'flutter_static: up at $url in ${started.elapsed.inSeconds}s; '
      '$count stories; rendered $id to $out in '
      '${render.elapsedMilliseconds}ms. Saves under the watched roots hot '
      'reload; renders wait for them.',
    );
    return 0;
  }

  /// Runs another subcommand of this same binary. [quiet] shows its output
  /// only when it changed something or failed.
  Future<int> _self(List<String> args, {bool quiet = false}) async {
    if (!quiet) {
      final process = await Process.start(_selfCommand.first, [
        ..._selfCommand.skip(1),
        ...args,
      ], mode: ProcessStartMode.inheritStdio);
      return process.exitCode;
    }
    final result = await Process.run(_selfCommand.first, [
      ..._selfCommand.skip(1),
      ...args,
    ]);
    final out = '${result.stdout}${result.stderr}';
    final acted = RegExp(r'^(Created|Added|No macOS)', multiLine: true);
    if (result.exitCode != 0 || acted.hasMatch(out)) stdout.write(out);
    return result.exitCode;
  }

  /// How to invoke this CLI again: the compiled binary, or `dart run
  /// flutter_static` when running from source.
  static List<String> get _selfCommand {
    final exe = Platform.resolvedExecutable;
    final viaDart = p.basename(exe) == 'dart' || p.basename(exe) == 'dartvm';
    return viaDart ? [exe, 'run', 'flutter_static'] : [exe];
  }

  /// Starts `run` detached, output to the log, and returns its pid once
  /// the runner has written its pid file.
  Future<int> _launch(int port) async {
    logFile.parent.createSync(recursive: true);
    if (logFile.existsSync()) logFile.deleteSync();
    _Runner.pidFile.existsSync() ? _Runner.pidFile.deleteSync() : null;
    final command = [..._selfCommand, 'run', '--port', '$port'];
    final quoted = command.map((a) => "'${a.replaceAll("'", r"'\''")}'");
    await Process.start('/bin/sh', [
      '-c',
      'exec ${quoted.join(' ')} < /dev/null > ${logFile.path} 2>&1',
    ], mode: ProcessStartMode.detached);
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (DateTime.now().isBefore(deadline)) {
      final pid = _runnerPid();
      if (pid != null) return pid;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    stderr.writeln('flutter_static: the runner never wrote its pid file:');
    _tailLog();
    throw StateError('runner did not start');
  }

  /// The alive runner's pid from `.dart_tool/flutter_static.pid`, or null.
  static int? _runnerPid() {
    final file = _Runner.pidFile;
    if (!file.existsSync()) return null;
    final pid = int.tryParse(file.readAsStringSync().trim());
    if (pid == null) return null;
    return _alive(pid) ? pid : null;
  }

  static bool _alive(int pid) =>
      Process.runSync('kill', ['-0', '$pid']).exitCode == 0;

  static void _tailLog() {
    if (!logFile.existsSync()) return;
    final lines = logFile.readAsLinesSync();
    for (final line in lines.skip(lines.length > 25 ? lines.length - 25 : 0)) {
      stderr.writeln('  $line');
    }
  }

  static String _lastLogLine() {
    if (!logFile.existsSync()) return '(no log yet)';
    final lines = logFile.readAsLinesSync().where((l) => l.trim().isNotEmpty);
    return lines.isEmpty ? '(empty log)' : lines.last;
  }
}

/// `flutter_static down`: stop this project's catalog runner and anything
/// else holding its port.
class _DownCommand extends Command<int> {
  @override
  String get name => 'down';
  @override
  String get description => "Stop this project's catalog runner.";

  @override
  Future<int> run() async {
    final port = _PortRegistry.lookup();
    final pid = _UpCommand._runnerPid();
    if (pid == null && port == null) {
      stdout.writeln('flutter_static: nothing running for this project.');
      return 0;
    }
    if (pid != null) await stop(pid, port);
    if (port != null) killPortHolders(port);
    stdout.writeln('flutter_static: down.');
    return 0;
  }

  /// SIGTERM to the runner (it stops the app first), SIGKILL if it lingers.
  static Future<void> stop(int pid, int? port) async {
    Process.killPid(pid, ProcessSignal.sigterm);
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (_UpCommand._alive(pid) && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    if (_UpCommand._alive(pid)) Process.killPid(pid, ProcessSignal.sigkill);
    if (port != null) killPortHolders(port);
  }

  /// Kills whatever listens on [port]: a catalog app whose runner is gone
  /// keeps serving stale code, and a new runner's server dies on bind.
  static void killPortHolders(int port) {
    final result = Process.runSync('lsof', [
      '-ti',
      'tcp:$port',
      '-sTCP:LISTEN',
    ]);
    for (final line in (result.stdout as String).split('\n')) {
      final holder = int.tryParse(line.trim());
      if (holder == null || holder == pid) continue;
      stdout.writeln(
        'flutter_static: killing stale port $port holder (pid $holder)',
      );
      Process.killPid(holder, ProcessSignal.sigkill);
    }
  }
}

/// Renders [id] from the catalog at [url] into [out], through the gate.
/// Returns the written path, or null after printing why not.
Future<String?> _renderStory(
  String id,
  String url,
  String out, {
  Map<String, String> knobs = const {},
}) async {
  final query = _freshQuery(knobs);
  final bytes = await _fetch(
    '$url/story/$id.png?$query',
    url,
    notFound: 'Story "$id" not found. See: flutter_static list',
    onHeaders: (headers) {
      final stale = headers.value('x-flutter-static-stale');
      if (stale != null) stderr.writeln('flutter_static: warning: $stale');
    },
  );
  if (bytes == null) return null;
  File(out).parent.createSync(recursive: true);
  File(out).writeAsBytesSync(bytes);
  return out;
}

/// Optional source checkpointing after a save-triggered reload succeeds.
class _Snapshots {
  _Snapshots._(this.mode);

  factory _Snapshots.from(String mode) => _Snapshots._(mode);

  final String mode;
  bool _checked = false;
  bool _available = false;
  bool _running = false;

  Future<void> afterSuccessfulReload({required bool full}) async {
    if (mode == 'off') return;
    if (_running) return;
    _running = true;
    try {
      if (!await _isAvailable()) return;
      final diff = await Process.run('jj', [
        '--no-pager',
        'diff',
        '--stat',
      ]).timeout(const Duration(seconds: 5));
      if (diff.exitCode != 0 || '${diff.stdout}'.trim().isEmpty) return;
      final now = DateTime.now().toIso8601String().split('.').first;
      final result = await Process.run('jj', [
        '--no-pager',
        'commit',
        '-m',
        'flutter_static: hot ${full ? 'restart' : 'reload'} $now',
      ]).timeout(const Duration(seconds: 10));
      if (result.exitCode == 0) {
        stdout.writeln('flutter_static: jj snapshot saved');
      } else {
        stderr.writeln('flutter_static: jj snapshot failed: ${result.stderr}');
      }
    } on Object catch (e) {
      stderr.writeln('flutter_static: jj snapshot failed: $e');
    } finally {
      _running = false;
    }
  }

  Future<bool> _isAvailable() async {
    if (_checked) return _available;
    _checked = true;
    if (mode != 'jj') return false;
    try {
      final result = await Process.run('jj', [
        '--no-pager',
        'root',
      ]).timeout(const Duration(seconds: 3));
      _available = result.exitCode == 0;
      if (_available) {
        stdout.writeln('flutter_static: jj snapshots on');
      } else {
        stderr.writeln(
          'flutter_static: jj snapshots requested, but this is not a jj repo',
        );
      }
    } on Object catch (e) {
      stderr.writeln('flutter_static: jj snapshots unavailable: $e');
    }
    return _available;
  }
}

/// Owns the `flutter run --machine` process, the source watcher and the
/// reload state machine between them.
///
/// The daemon protocol (JSON lines on stdin/stdout) replaces SIGUSR1 to the
/// tool: a restart requested while one is running is queued by the tool
/// instead of silently dropped, and every restart answers with a result, so
/// the catalog can be told whether the code it serves is current. The CLI's
/// own pid goes to `.dart_tool/flutter_static.pid`, and SIGUSR1/SIGUSR2 to
/// it still mean reload/restart.
class _Runner {
  _Runner({
    required this.target,
    required this.device,
    required this.port,
    required this.snapshots,
    this.projectRoot,
  });

  final String target;
  final String device;
  final int port;
  final _Snapshots snapshots;
  final String? projectRoot;

  static final pidFile = File('.dart_tool/flutter_static.pid');
  static final packageConfig = File('.dart_tool/package_config.json');

  late final Process _process;
  final _pending = <int, Completer<Map<String, dynamic>>>{};
  int _nextId = 0;
  String? _appId;
  bool _started = false;
  bool _stopping = false;
  final _exit = Completer<int>();

  /// Edits since the running reload was requested (or since the last one
  /// finished). Set by the watcher, consumed by [_reload].
  bool _dirty = false;
  bool _reloading = false;
  bool _wantFull = false;
  Timer? _debounce;
  final _reloadErrors = <String>[];
  Future<void> _notifyChain = Future.value();

  final _watched = <String>{};
  final _subscriptions = <StreamSubscription<Object?>>[];
  bool _rawTerminal = false;

  Future<int> run() async {
    pidFile.parent.createSync(recursive: true);
    _process = await Process.start('flutter', [
      'run',
      '--machine',
      '-d',
      device,
      '-t',
      target,
      '--dart-define=FLUTTER_STATIC_PORT=$port',
      if (projectRoot != null)
        '--dart-define=FLUTTER_STATIC_PROJECT_ROOT=$projectRoot',
    ]);
    pidFile.writeAsStringSync('$pid');
    _process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_onLine);
    // Compiler diagnostics bypass the daemon protocol and arrive here as
    // plain text; they are what a failed reload should report.
    _process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          _reloadErrors.add(line);
          if (_reloadErrors.length > 200) _reloadErrors.removeAt(0);
          stderr.writeln(line);
        });
    unawaited(
      _process.exitCode.then((code) {
        if (!_exit.isCompleted) _exit.complete(code);
      }),
    );
    _watchSources();
    _listenSignals();
    _listenKeys();
    final code = await _exit.future;
    _cleanUp();
    return code;
  }

  // --- daemon protocol -----------------------------------------------------

  /// `FLUTTER_STATIC_DAEMON_LOG=<file>` appends every raw daemon line.
  static final _daemonLog = Platform.environment['FLUTTER_STATIC_DAEMON_LOG'];

  void _onLine(String line) {
    if (_daemonLog != null) {
      File(_daemonLog!).writeAsStringSync('$line\n', mode: FileMode.append);
    }
    if (!line.startsWith('[{') || !line.endsWith('}]')) {
      stdout.writeln(line);
      return;
    }
    List<dynamic> messages;
    try {
      messages = jsonDecode(line) as List<dynamic>;
    } catch (_) {
      stdout.writeln(line);
      return;
    }
    for (final message in messages.cast<Map<String, dynamic>>()) {
      if (message.containsKey('id')) {
        _pending.remove(message['id'])?.complete(message);
        continue;
      }
      final params =
          (message['params'] as Map?)?.cast<String, dynamic>() ?? const {};
      switch (message['event']) {
        case 'app.start':
          _appId = params['appId'] as String?;
        case 'app.debugPort':
          stdout.writeln('flutter_static: VM service at ${params['wsUri']}');
        case 'app.started':
          _started = true;
          stdout.writeln(
            'flutter_static: app running; saves hot reload it '
            '(r reload, R restart, q quit)',
          );
          if (_dirty) unawaited(_reload());
        case 'app.log':
          final text = params['log'] as String? ?? '';
          if (params['error'] == true) {
            _reloadErrors.add(text);
            stderr.writeln(text);
          } else {
            // Compiler diagnostics arrive as plain log lines; keep them
            // for the catalog's 409 body. The buffer is cleared when a
            // reload starts and read when one fails.
            if (_looksLikeDiagnostic(text)) _reloadErrors.add(text);
            stdout.writeln(text);
          }
        case 'app.progress':
          final text = params['message'] as String?;
          if (text != null && params['finished'] != true) {
            stdout.writeln(text);
          }
        case 'app.stop':
          _started = false;
        case 'daemon.logMessage':
          final text = '${params['message']}';
          if (params['level'] == 'error') {
            _reloadErrors.add(text);
            stderr.writeln(text);
          }
      }
    }
  }

  /// A compiler diagnostic, its indented source excerpt, or its caret line.
  static bool _looksLikeDiagnostic(String line) =>
      line.contains(': Error: ') ||
      line.contains(': Warning: ') ||
      line.startsWith(' ') ||
      line.trimLeft().startsWith('^');

  Future<Map<String, dynamic>> _call(
    String method,
    Map<String, Object?> params,
  ) {
    final id = ++_nextId;
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    _process.stdin.writeln(
      jsonEncode([
        {'id': id, 'method': method, 'params': params},
      ]),
    );
    return completer.future;
  }

  // --- reload state machine ------------------------------------------------

  /// First save of the current edit burst; reported when its reload lands.
  DateTime? _lastSaveAt;

  void _onSourceChanged() {
    _lastSaveAt ??= DateTime.now();
    _dirty = true;
    _notifyCatalog('pending');
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 60), _reload);
  }

  /// Runs one hot reload (or restart) and reports the outcome to the
  /// catalog. Edits that land while it runs trigger a follow-up as soon as
  /// it finishes.
  Future<void> _reload({bool full = false}) async {
    _wantFull |= full;
    if (_appId == null || !_started || _stopping) return;
    if (_reloading) return;
    _reloading = true;
    _dirty = false;
    final fullNow = _wantFull;
    _wantFull = false;
    _reloadErrors.clear();
    final sw = Stopwatch()..start();
    Map<String, dynamic> response;
    try {
      response = await _call('app.restart', {
        'appId': _appId,
        'fullRestart': fullNow,
        'reason': 'save',
        'pause': false,
      });
    } catch (e) {
      response = {'error': '$e'};
    } finally {
      _reloading = false;
    }
    final result = (response['result'] as Map?)?.cast<String, dynamic>();
    final ok = result != null && result['code'] == 0;
    if (_dirty || _wantFull) {
      // Superseded already; the follow-up reports for both.
      unawaited(_reload());
      return;
    }
    if (ok) {
      _notifyCatalog(
        'done',
        message: '${result['message']} (${sw.elapsedMilliseconds}ms)',
        full: fullNow,
      );
      if (_lastSaveAt != null) {
        unawaited(snapshots.afterSuccessfulReload(full: fullNow));
        stdout.writeln(
          'flutter_static: renders are current '
          '(${DateTime.now().difference(_lastSaveAt!).inMilliseconds}ms '
          'after the save)',
        );
        _lastSaveAt = null;
      }
      return;
    }
    // The tool answers before its last diagnostic lines are flushed.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final detail = [
      if (result != null) '${result['message']}',
      if (response['error'] != null) '${response['error']}',
      ..._reloadErrors,
    ].join('\n');
    stderr.writeln(
      'flutter_static: hot ${fullNow ? 'restart' : 'reload'} failed; '
      'the catalog keeps serving the previous code until the next save '
      'compiles.',
    );
    _notifyCatalog('failed', message: detail, full: fullNow);
  }

  /// Tells the catalog whether the code it serves is current. Posts are
  /// chained so a slow `pending` does not land after its own `done`.
  void _notifyCatalog(String state, {String? message, bool full = false}) {
    _notifyChain = _notifyChain.then((_) async {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 2);
      try {
        final request = await client.postUrl(
          Uri.parse('http://localhost:$port/reload'),
        );
        request.headers.contentType = ContentType.json;
        request.write(
          jsonEncode({'state': state, 'message': message, 'full': full}),
        );
        final response = await request.close().timeout(
          const Duration(seconds: 5),
        );
        await response.drain<void>();
      } catch (_) {
        // Catalog not up yet (first launch) or restarting; the next state
        // change reports again.
      } finally {
        client.close();
      }
    });
  }

  // --- sources -------------------------------------------------------------

  /// Watches every local package's `lib/` and `story/`, and keeps that set
  /// in sync with `.dart_tool/package_config.json`: in a fresh checkout the
  /// file only exists once `flutter run` has finished pub get, and it
  /// changes whenever a path dependency is added.
  void _watchSources() {
    _syncWatchTargets();
    var stamp = _packageConfigStamp();
    final timer = Timer.periodic(const Duration(seconds: 1), (_) {
      final now = _packageConfigStamp();
      if (now == stamp) return;
      stamp = now;
      _syncWatchTargets();
    });
    _exit.future.whenComplete(timer.cancel);
  }

  String _packageConfigStamp() {
    if (!packageConfig.existsSync()) return '';
    final stat = packageConfig.statSync();
    return '${stat.modified.microsecondsSinceEpoch}:${stat.size}';
  }

  void _syncWatchTargets() {
    final added = _watchTargets().where(_watched.add).toList();
    if (added.isEmpty) return;
    added.forEach(_watchRoot);
    stdout.writeln(
      'flutter_static: watching ${added.map(_shortPath).join(', ')}'
      '${packageConfig.existsSync() ? '' : ' (package_config.json not written yet; path dependencies join once pub get has run)'}',
    );
  }

  static String _shortPath(String path) {
    final cwd = Directory.current.path;
    return path.startsWith('$cwd/') ? path.substring(cwd.length + 1) : path;
  }

  void _watchRoot(String root) {
    DirectoryWatcher(root).events.listen(
      (event) {
        final path = event.path;
        if (!path.endsWith('.dart')) return;
        if (path.contains('/.dart_tool/') ||
            path.contains('/build/') ||
            path.contains('/.git/')) {
          return;
        }
        _onSourceChanged();
      },
      onError: (Object e) {
        stderr.writeln(
          'flutter_static: watcher error on $root: $e; restarting watcher',
        );
        _watchRoot(root);
      },
      onDone: () {
        if (_exit.isCompleted) return;
        stderr.writeln('flutter_static: watcher for $root ended; restarting');
        _watchRoot(root);
      },
    );
  }

  // --- signals and keys ----------------------------------------------------

  void _listenSignals() {
    _subscriptions.addAll([
      ProcessSignal.sigusr1.watch().listen((_) => _reload()),
      ProcessSignal.sigusr2.watch().listen((_) => _reload(full: true)),
      ProcessSignal.sigint.watch().listen((_) => _stop()),
      ProcessSignal.sigterm.watch().listen((_) => _stop()),
    ]);
  }

  void _listenKeys() {
    if (!stdin.hasTerminal) return;
    try {
      stdin.echoMode = false;
      stdin.lineMode = false;
      _rawTerminal = true;
    } on StdinException {
      return;
    }
    _subscriptions.add(
      stdin.listen((bytes) {
        for (final byte in bytes) {
          switch (String.fromCharCode(byte)) {
            case 'r':
              unawaited(_reload());
            case 'R':
              unawaited(_reload(full: true));
            case 'q':
              unawaited(_stop());
            case 'h' || '?':
              stdout.writeln(
                'r hot reload, R hot restart, q quit. Saves under every '
                'watched directory hot reload by themselves.',
              );
          }
        }
      }),
    );
  }

  Future<void> _stop() async {
    if (_stopping) return;
    _stopping = true;
    stdout.writeln('flutter_static: stopping');
    if (_appId != null) {
      try {
        await _call('app.stop', {
          'appId': _appId,
        }).timeout(const Duration(seconds: 8));
      } catch (_) {}
    }
    try {
      await _process.exitCode.timeout(const Duration(seconds: 3));
    } on TimeoutException {
      _process.kill(ProcessSignal.sigkill);
    }
  }

  void _cleanUp() {
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    if (_rawTerminal) {
      try {
        stdin.echoMode = true;
        stdin.lineMode = true;
      } on StdinException {
        // Terminal went away.
      }
    }
    try {
      if (pidFile.existsSync() && pidFile.readAsStringSync().trim() == '$pid') {
        pidFile.deleteSync();
      }
    } on FileSystemException {
      // Nothing to clean.
    }
  }
}

/// The directories `run` watches: `lib/` and `story/` of the app and of
/// every path dependency. Only the Dart-bearing subdirectories: watching a
/// whole package root means the watcher's initial scan crawls
/// deps/_build/node_modules (minutes on a big repo) before delivering a
/// single event.
List<String> _watchTargets() {
  final targets = <String>[];
  for (final root in _localPackageRoots()) {
    final narrow = [
      '$root/lib',
      '$root/story',
    ].where((d) => Directory(d).existsSync()).toList();
    targets.addAll(narrow.isEmpty ? [root] : narrow);
  }
  return targets;
}

/// The app package itself plus every path dependency: exactly the code the
/// resident compiler can hot reload. Hosted and SDK packages have absolute
/// file:// rootUris; local packages are written as relative URIs.
List<String> _localPackageRoots() {
  final packageConfig = _Runner.packageConfig;
  final cwd = Directory.current.resolveSymbolicLinksSync();
  if (!packageConfig.existsSync()) return [cwd];
  final roots = <String>{};
  try {
    final json =
        jsonDecode(packageConfig.readAsStringSync()) as Map<String, dynamic>;
    for (final package
        in (json['packages'] as List).cast<Map<String, dynamic>>()) {
      final rootUri = package['rootUri'] as String;
      try {
        final dir = Directory.fromUri(
          packageConfig.absolute.parent.uri.resolveUri(Uri.parse(rootUri)),
        ).resolveSymbolicLinksSync();
        // Hosted packages and the Flutter SDK are immutable for this run.
        // Absolute file:// roots outside those caches are path dependencies,
        // including generated Studio hosts that point at a real project.
        if (rootUri.startsWith('file://') &&
            (dir.contains('/.pub-cache/') ||
                dir.contains('/flutter/packages/') ||
                dir.contains('/flutter/bin/cache/'))) {
          continue;
        }
        roots.add(dir);
      } on FileSystemException {
        // Stale entry; skip.
      }
    }
  } catch (_) {
    // Half-written by pub get; the next stamp change re-reads it.
  }
  return roots.isEmpty ? [cwd] : roots.toList();
}

/// Newest mtime of any .dart file under the watched roots, or null outside
/// a project. A few hundred stats, ~15ms on a large app.
DateTime? _newestSourceMtime() {
  if (!File('pubspec.yaml').existsSync()) return null;
  DateTime? newest;
  for (final root in _watchTargets()) {
    final dir = Directory(root);
    if (!dir.existsSync()) continue;
    try {
      for (final entity in dir.listSync(recursive: true, followLinks: false)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final path = entity.path;
        if (path.contains('/.dart_tool/') ||
            path.contains('/build/') ||
            path.contains('/.git/')) {
          continue;
        }
        final modified = entity.statSync().modified;
        if (newest == null || modified.isAfter(newest)) newest = modified;
      }
    } on FileSystemException {
      // Unreadable subtree; the watcher skips it too.
    }
  }
  return newest;
}

class _InitCommand extends Command<int> {
  _InitCommand() {
    argParser.addFlag(
      'force',
      negatable: false,
      help: 'Overwrite an existing story/main.dart.',
    );
  }

  @override
  String get name => 'init';
  @override
  String get description => 'Scaffold story/main.dart.';

  @override
  Future<int> run() async {
    final file = File('story/main.dart');
    if (file.existsSync() && !(argResults!['force'] as bool)) {
      stderr.writeln('${file.path} already exists (use --force to overwrite).');
      return 1;
    }
    for (final created in _scaffoldStories(force: true)) {
      stdout.writeln('Created $created.');
    }
    stdout.writeln('Start the catalog with:');
    stdout.writeln('  flutter_static run');
    return 0;
  }
}

class _SetupCommand extends Command<int> {
  _SetupCommand() {
    argParser
      ..addOption(
        'path',
        help:
            'Path to the flutter_static package '
            '(default: auto-detected from the binary or package config).',
      )
      ..addOption(
        'org',
        help:
            'Bundle-id org for the generated macOS runner, forwarded to '
            'flutter create (needed when existing platforms disagree).',
      );
  }

  @override
  String get name => 'setup';
  @override
  String get description =>
      'Create the story/ folder, add the flutter_static dependency to '
      'pubspec.yaml, and run flutter pub get. Idempotent.';

  @override
  Future<int> run() async {
    final pubspec = File('pubspec.yaml');
    if (!pubspec.existsSync()) {
      stderr.writeln(
        'No pubspec.yaml here. Run setup from the root of the Flutter '
        'project that should host the stories.',
      );
      return 1;
    }
    final created = _scaffoldStories();
    if (created.isEmpty) {
      stdout.writeln('story/main.dart already exists; keeping it.');
    } else {
      for (final path in created) {
        stdout.writeln('Created $path.');
      }
    }

    final content = pubspec.readAsStringSync();
    final hasDep = RegExp(
      r'^  flutter_static\s*:',
      multiLine: true,
    ).hasMatch(content);
    if (hasDep) {
      stdout.writeln('flutter_static already in pubspec.yaml.');
    } else {
      final root = (argResults!['path'] as String?) ?? await _packageRoot();
      final lines = content.split('\n');
      final depsIndex = lines.indexWhere(
        (l) => RegExp(r'^dependencies:\s*$').hasMatch(l),
      );
      if (root == null || depsIndex == -1) {
        stdout.writeln('');
        stdout.writeln(
          root == null
              ? 'Could not locate the flutter_static package '
                    '(pass --path). Add manually:'
              : 'No plain "dependencies:" section found. Add manually:',
        );
        stdout.writeln('');
        stdout.writeln('  dependencies:');
        stdout.writeln('    flutter_static:');
        stdout.writeln('      path: ${root ?? '<path to flutter_static>'}');
        stdout.writeln('');
        stdout.writeln('then run: flutter pub get');
        return 1;
      }
      final rel = p.relative(root, from: Directory.current.path);
      // A nearby repo reads well as ../flutter_static; a far-away one is
      // clearer (and no longer) as an absolute path.
      final dep = p.split(rel).where((s) => s == '..').length > 3 ? root : rel;
      lines.insertAll(depsIndex + 1, ['  flutter_static:', '    path: $dep']);
      pubspec.writeAsStringSync(lines.join('\n'));
      stdout.writeln('Added flutter_static (path: $dep) to pubspec.yaml.');
      final pub = await Process.start('flutter', [
        'pub',
        'get',
      ], mode: ProcessStartMode.inheritStdio);
      final code = await pub.exitCode;
      if (code != 0) return code;
    }

    // The catalog renders on the desktop; mobile-only projects need a
    // macOS runner added once.
    if (!Directory('macos').existsSync()) {
      stdout.writeln(
        'No macOS runner; adding one (flutter create '
        '--platforms=macos .)',
      );
      final org = argResults!['org'] as String?;
      final create = await Process.start('flutter', [
        'create',
        '--platforms=macos',
        if (org != null) ...['--org', org],
        '.',
      ], mode: ProcessStartMode.inheritStdio);
      final code = await create.exitCode;
      if (code != 0) {
        stderr.writeln(
          'flutter create failed. If it reported an ambiguous organization, '
          're-run with: flutter_static setup --org <your.org>',
        );
        return code;
      }
    }
    stdout.writeln('Start the catalog with: flutter_static run');
    return 0;
  }
}

/// Where the flutter_static package lives: baked in at compile time for
/// the global binary (-DFLUTTER_STATIC_ROOT=...), resolved from the
/// package config when running via `dart run flutter_static`.
Future<String?> _packageRoot() async {
  const compiled = String.fromEnvironment('FLUTTER_STATIC_ROOT');
  if (compiled.isNotEmpty && Directory(compiled).existsSync()) {
    return compiled;
  }
  final uri = await Isolate.resolvePackageUri(
    Uri.parse('package:flutter_static/'),
  );
  if (uri == null) return null;
  final lib = Directory.fromUri(uri);
  return lib.existsSync() ? lib.parent.path : null;
}

/// `flutter_static studio`: the catalog with Studio in its window. Runs
/// the project's `story/studio_main.dart` (scaffolded here if missing)
/// the way `run` runs `story/main.dart`: same runner, same watcher, same
/// HTTP API, plus a canvas of live widgets and the token editors.
class _StudioHostCommand extends Command<int> {
  _StudioHostCommand() {
    argParser
      ..addOption(
        'project',
        abbr: 'p',
        defaultsTo: Directory.current.path,
        help: 'Flutter project whose story/main.dart should run in the host.',
      )
      ..addOption('device', abbr: 'd', defaultsTo: 'macos')
      ..addOption('port')
      ..addOption(
        'host-dir',
        help:
            'Generated host directory (default: ~/.flutter_static/hosts/<project>).',
      )
      ..addOption(
        'flutter-static-path',
        defaultsTo: _findFlutterStaticRoot(),
        help:
            'Path dependency for the flutter_static package under development.',
      )
      ..addOption(
        'snapshots',
        allowed: const ['off', 'jj'],
        defaultsTo: Platform.environment['FLUTTER_STATIC_SNAPSHOTS'] ?? 'off',
      );
  }

  @override
  String get name => 'studio-host';

  @override
  String get description =>
      'Experimental: run Studio from a generated macOS host that references '
      'the real project as a path dependency.';

  @override
  Future<int> run() async {
    final project = Directory(
      argResults!['project'] as String,
    ).absolute.resolveSymbolicLinksSync();
    final pubspec = File('$project/pubspec.yaml');
    final storyMain = File('$project/story/main.dart');
    if (!pubspec.existsSync()) {
      stderr.writeln('No pubspec.yaml in $project');
      return 1;
    }
    if (!storyMain.existsSync()) {
      stderr.writeln('No story/main.dart in $project');
      return 1;
    }
    final packageName = _pubspecName(pubspec) ?? p.basename(project);
    final storiesClass = RegExp(
      r'class\s+(\w+)\s+extends\s+Stories',
    ).firstMatch(storyMain.readAsStringSync())?.group(1);
    if (storiesClass == null) {
      stderr.writeln('Could not find `class X extends Stories` in $storyMain');
      return 1;
    }

    final hostDir = Directory(
      argResults!['host-dir'] as String? ??
          p.join(_flutterStaticHome().path, 'hosts', _slug(project)),
    ).absolute;
    await _ensureHost(hostDir, project, packageName, storiesClass);

    final requested = argResults!['port'] as String?;
    Directory.current = hostDir.path;
    final port = await _PortRegistry.claim(
      requested: requested == null ? null : int.tryParse(requested),
    );
    if (port == null) {
      stderr.writeln('Invalid port: $requested');
      return 64;
    }
    stdout.writeln('flutter_static: Studio host ${hostDir.path}');
    stdout.writeln('flutter_static: project $project');
    stdout.writeln('flutter_static: Studio, catalog on port $port');
    return _Runner(
      target: 'lib/main.dart',
      device: argResults!['device'] as String,
      port: port,
      snapshots: _Snapshots.from(argResults!['snapshots'] as String),
      projectRoot: project,
    ).run();
  }

  Future<void> _ensureHost(
    Directory hostDir,
    String project,
    String packageName,
    String storiesClass,
  ) async {
    if (!Directory('${hostDir.path}/macos').existsSync()) {
      hostDir.createSync(recursive: true);
      final create = await Process.start(
        'flutter',
        [
          'create',
          '--platforms=macos',
          '--project-name=${p.basename(hostDir.path).replaceAll('-', '_')}',
          '.',
        ],
        workingDirectory: hostDir.path,
        mode: ProcessStartMode.inheritStdio,
      );
      final code = await create.exitCode;
      if (code != 0) throw StateError('flutter create failed');
    }
    Directory('${hostDir.path}/lib').createSync(recursive: true);
    File('${hostDir.path}/pubspec.yaml').writeAsStringSync('''
name: ${p.basename(hostDir.path).replaceAll('-', '_')}
description: Generated Flutter Static Studio host for $project.
publish_to: 'none'
version: 0.0.0+1

environment:
  sdk: ^3.12.2

dependencies:
  flutter:
    sdk: flutter
  flutter_static:
    path: ${argResults!['flutter-static-path']}
  $packageName:
    path: $project

flutter:
  uses-material-design: true
''');
    File('${hostDir.path}/lib/main.dart').writeAsStringSync('''
import 'dart:io';

import 'package:flutter_static/flutter_static.dart';

import '${storyMainUri(project)}';

void main() {
  Directory.current = '$project';
  runFlutterStudio(const $storiesClass());
}
''');
    _StudioCommand._prepareRunnerIn(hostDir.path);
    final get = await Process.start(
      'flutter',
      ['pub', 'get'],
      workingDirectory: hostDir.path,
      mode: ProcessStartMode.inheritStdio,
    );
    final code = await get.exitCode;
    if (code != 0) throw StateError('flutter pub get failed');
  }

  static String storyMainUri(String project) =>
      File('$project/story/main.dart').absolute.uri.toString();

  static String _slug(String project) =>
      p.basename(project).replaceAll(RegExp(r'[^A-Za-z0-9_]+'), '_');

  static String? _pubspecName(File pubspec) => RegExp(
    r'^name:\s*([^\s#]+)',
    multiLine: true,
  ).firstMatch(pubspec.readAsStringSync())?.group(1);

  static String _findFlutterStaticRoot() {
    var dir = Directory.current.absolute;
    while (dir.path != dir.parent.path) {
      final pubspec = File('${dir.path}/pubspec.yaml');
      if (pubspec.existsSync() && _pubspecName(pubspec) == 'flutter_static') {
        return dir.path;
      }
      dir = dir.parent;
    }
    return Directory.current.absolute.path;
  }
}

class _StudioCommand extends Command<int> {
  _StudioCommand() {
    argParser
      ..addOption('device', abbr: 'd', defaultsTo: 'macos')
      ..addOption(
        'port',
        help:
            'Catalog port (default: the port registered for this '
            'directory, see `flutter_static port`).',
      )
      ..addOption(
        'snapshots',
        allowed: const ['off', 'jj'],
        defaultsTo: Platform.environment['FLUTTER_STATIC_SNAPSHOTS'] ?? 'off',
        help:
            'Snapshot successful reloads. "jj" commits the current change '
            'after each save-triggered hot reload.',
      )
      ..addFlag(
        'prepare-runner',
        defaultsTo: false,
        help:
            'Apply one-time macOS runner edits for Studio. Off by default so '
            'Studio does not leave artifacts in the app being designed.',
      );
  }

  @override
  String get name => 'studio';
  @override
  String get description =>
      'Open Studio for this project: stories live on a canvas, design '
      'tokens editable, the catalog API on the same port.';

  static const target = 'story/studio_main.dart';

  @override
  Future<int> run() async {
    if (!File('pubspec.yaml').existsSync()) {
      stderr.writeln('No pubspec.yaml here. Run studio from the project.');
      return 1;
    }
    if (!File('story/main.dart').existsSync()) {
      stderr.writeln('No story/main.dart. Run: flutter_static setup');
      return 1;
    }
    if (!Directory('macos').existsSync()) {
      stderr.writeln('No macOS runner. Run: flutter_static setup');
      return 1;
    }
    final scaffolded = _scaffoldStudioMain();
    if (scaffolded != null) stdout.writeln(scaffolded);
    if (argResults!['prepare-runner'] as bool) {
      for (final line in _prepareRunner()) {
        stdout.writeln(line);
      }
    } else {
      for (final line in _runnerPreparationWarnings()) {
        stdout.writeln(line);
      }
    }
    // Studio serves the catalog itself; a runner from `up` would fight it
    // for the port.
    final pid = _UpCommand._runnerPid();
    final registered = _PortRegistry.lookup();
    if (pid != null) {
      stdout.writeln(
        'flutter_static: stopping the catalog runner (pid $pid); '
        'Studio serves the catalog on the same port.',
      );
      await _DownCommand.stop(pid, registered);
    }
    final requested = argResults!['port'] as String?;
    final port = await _PortRegistry.claim(
      requested: requested == null ? null : int.tryParse(requested),
    );
    if (port == null) {
      stderr.writeln('Invalid port: $requested');
      return 64;
    }
    stdout.writeln('flutter_static: Studio, catalog on port $port');
    return _Runner(
      target: target,
      device: argResults!['device'] as String,
      port: port,
      snapshots: _Snapshots.from(argResults!['snapshots'] as String),
    ).run();
  }

  /// Writes `story/studio_main.dart` for the Stories class in
  /// `story/main.dart`; returns what it did, or null when it exists.
  static String? _scaffoldStudioMain() {
    final file = File(target);
    if (file.existsSync()) return null;
    final main = File('story/main.dart').readAsStringSync();
    final cls = RegExp(r'class\s+(\w+)\s+extends\s+Stories').firstMatch(main);
    if (cls == null) {
      return 'Could not find `class X extends Stories` in story/main.dart; '
          'write $target by hand: '
          'void main() => runFlutterStudio(const X());';
    }
    file.writeAsStringSync('''
import 'package:flutter_static/flutter_static.dart';

import 'main.dart';

// Run with: flutter_static studio
// The catalog with Studio in its window: the same stories mounted live
// on a canvas, and the design tokens from lib/**/tokens.dart editable.
void main() => runFlutterStudio(const ${cls.group(1)}());
''');
    return 'Created $target.';
  }

  /// Reports runner changes that may help Studio, without mutating the app.
  static List<String> _runnerPreparationWarnings() {
    final warnings = <String>[];
    for (final name in ['DebugProfile', 'Release']) {
      final file = File('macos/Runner/$name.entitlements');
      if (!file.existsSync()) continue;
      final content = file.readAsStringSync();
      const key = '<key>com.apple.security.app-sandbox</key>';
      if (RegExp('$key\\s*<true/>').hasMatch(content)) {
        warnings.add(
          'flutter_static: ${file.path} keeps the app sandbox on; Studio may '
          'not be able to edit files. Run with --prepare-runner if you want '
          'flutter_static to change it.',
        );
      }
    }
    final window = File('macos/Runner/MainFlutterWindow.swift');
    if (window.existsSync() &&
        window.readAsStringSync().trim() == _templateWindow.trim()) {
      warnings.add(
        'flutter_static: ${window.path} is the template 800x600 window. Run '
        'with --prepare-runner if you want flutter_static to enlarge it.',
      );
    }
    return warnings;
  }

  /// Studio reads and writes the project's source and wants a window
  /// with room for a canvas: sandbox off, template window enlarged. Both
  /// are opt-in edits to the runner, reported when made.
  static List<String> _prepareRunner() =>
      _prepareRunnerIn(Directory.current.path);

  static List<String> _prepareRunnerIn(String root) {
    final done = <String>[];
    for (final name in ['DebugProfile', 'Release']) {
      final file = File('$root/macos/Runner/$name.entitlements');
      if (!file.existsSync()) continue;
      final content = file.readAsStringSync();
      const key = '<key>com.apple.security.app-sandbox</key>';
      final on = RegExp('$key\\s*<true/>');
      if (!on.hasMatch(content)) continue;
      file.writeAsStringSync(content.replaceFirst(on, '$key\n\t<false/>'));
      done.add(
        'Turned the app sandbox off in ${file.path} '
        '(Studio edits the project\'s files).',
      );
    }
    final window = File('$root/macos/Runner/MainFlutterWindow.swift');
    if (window.existsSync() &&
        window.readAsStringSync().trim() == _templateWindow.trim()) {
      window.writeAsStringSync(_studioWindow);
      done.add('Enlarged the default window in ${window.path}.');
    }
    return done;
  }

  static const _templateWindow = '''
import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
''';

  static const _studioWindow = '''
import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    // flutter_static studio: room for a sidebar, a canvas and an
    // inspector. The template opened at 800x600.
    var windowFrame = self.frame
    if let screen = NSScreen.main?.visibleFrame {
      let width = min(1480, screen.width - 80)
      let height = min(940, screen.height - 60)
      windowFrame = NSRect(
        x: screen.minX + (screen.width - width) / 2,
        y: screen.minY + (screen.height - height) / 2,
        width: width,
        height: height)
    }
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
''';
}

/// `flutter_static tokens [list|set]`: the project's design tokens,
/// straight from source. No catalog needed.
class _TokensCommand extends Command<int> {
  _TokensCommand() {
    addSubcommand(_TokensListCommand());
    addSubcommand(_TokensSetCommand());
  }

  @override
  String get name => 'tokens';
  @override
  String get description =>
      'List or edit design tokens (static consts in tokens.dart files).';
}

class _TokensListCommand extends Command<int> {
  _TokensListCommand() {
    argParser.addFlag('json', negatable: false, help: 'Print the full JSON.');
  }

  @override
  String get name => 'list';
  @override
  String get description =>
      'List tokens under lib/ of this project and its path dependencies.';

  @override
  Future<int> run() async {
    final set = TokenSet.load(Directory.current.path);
    if (argResults!['json'] as bool) {
      stdout.writeln(tokensJson(set));
      return 0;
    }
    if (set.files.isEmpty) {
      stdout.writeln(
        'No token files. Convention: lib/**/tokens.dart or lib/**/tokens/*.dart '
        'with `static const` members, in the project or a path dependency.',
      );
      return 0;
    }
    for (final file in set.files) {
      stdout.writeln(p.relative(file.path));
      for (final group in file.groups) {
        stdout.writeln('  ${group.name}');
        for (final t in group.tokens) {
          final value = switch (t.kind) {
            TokenKind.color => colorHex(t.argb!),
            TokenKind.text =>
              t.args.map((a) => '${a.name}: ${a.value}').join(', '),
            _ => t.source,
          };
          stdout.writeln('    ${t.id}  ${t.kind.name}  $value');
        }
      }
    }
    return 0;
  }
}

class _TokensSetCommand extends Command<int> {
  _TokensSetCommand() {
    argParser.addOption(
      'arg',
      help: 'For a TextStyle token: the argument to set (fontSize, ...).',
    );
  }

  @override
  String get name => 'set';
  @override
  String get description =>
      'Set a token: `tokens set AppColors.primary "#4F46E5"`, '
      '`tokens set Space.md 16`, `tokens set AppText.title --arg fontSize 28`.';
  @override
  String get invocation => 'flutter_static tokens set <Group.name> <value>';

  @override
  Future<int> run() async {
    final rest = argResults!.rest;
    if (rest.length != 2) usageException('Expected <Group.name> <value>.');
    final [id, raw] = rest;
    final set = TokenSet.load(Directory.current.path);
    final token = set.find(id);
    if (token == null) {
      stderr.writeln('No token $id. `flutter_static tokens list` shows them.');
      return 1;
    }
    final arg = argResults!['arg'] as String?;
    final DesignToken written;
    if (arg != null) {
      written = writeTokenArg(token, arg, raw);
    } else {
      final expression = switch (token.kind) {
        TokenKind.color => colorSource(
          parseColorHex(raw) ??
              (throw UsageException('Not a colour: $raw', usage)),
        ),
        TokenKind.number ||
        TokenKind.radius ||
        TokenKind.duration => numberSourceFor(
          token,
          double.tryParse(raw) ??
              (throw UsageException('Not a number: $raw', usage)),
        ),
        _ => raw,
      };
      written = writeToken(token, expression);
    }
    stdout.writeln(
      '${written.id} = ${written.source} '
      '(${p.relative(written.file)}:${written.line})',
    );
    return 0;
  }
}

class _BuildWebCommand extends Command<int> {
  @override
  String get name => 'build-web';
  @override
  String get description =>
      'Compile the stories to a wasm web build the detail pages embed live.';

  @override
  Future<int> run() async {
    if (!File('story/main.dart').existsSync()) {
      stderr.writeln('No story/main.dart here. Run this in the catalog app.');
      return 1;
    }
    if (!Directory('web').existsSync()) {
      stdout.writeln('flutter_static: adding web platform...');
      var create = await Process.run('flutter', [
        'create',
        '--platforms=web',
        '.',
      ]);
      if (create.exitCode != 0) {
        // Projects with mixed org identifiers need --org to be explicit.
        final ambiguous = RegExp(
          r'Ambiguous organization in existing files: \{([^,}]+)',
        ).firstMatch('${create.stderr}${create.stdout}');
        if (ambiguous != null) {
          final org = ambiguous.group(1)!.trim();
          stdout.writeln('flutter_static: retrying with --org $org');
          create = await Process.run('flutter', [
            'create',
            '--platforms=web',
            '--org',
            org,
            '.',
          ]);
        }
      }
      if (create.exitCode != 0) {
        stderr.writeln(create.stderr);
        return create.exitCode;
      }
    }
    // The bootstrap template: multi-view engine, views added by the pages.
    const marker = '// flutter_static multiview bootstrap';
    final bootstrap = File('web/flutter_bootstrap.js');
    if (!bootstrap.existsSync() ||
        bootstrap.readAsStringSync().contains(marker)) {
      bootstrap.writeAsStringSync("""$marker
{{flutter_js}}
{{flutter_build_config}}
// Works from the catalog's /live/ and from a standalone page: resolve
// bases from this script's own URL.
const BASE = new URL('.', document.currentScript.src).href;
const onEntrypointLoaded = async (engineInitializer) => {
    // The engine resolves assets and CanvasKit against these, not the
    // loader config above, which only covers the entrypoint.
    const engine = await engineInitializer.initializeEngine({
      multiViewEnabled: true,
      assetBase: BASE,
      canvasKitBaseUrl: BASE + 'canvaskit/',
    });
    const app = await engine.runApp();
    window.flutterStaticApp = app;
    let host = document.getElementById('host');
    const storyId = window._flutterStaticStory ||
        new URLSearchParams(location.search).get('storyId');
    if (!host && storyId) {
      // Standalone (dev server) page: fill it with a single view.
      document.body.style.cssText = 'margin:0;height:100vh;background:#131518';
      host = document.createElement('div');
      host.id = 'host';
      host.style.cssText = 'position:absolute;inset:0';
      document.body.appendChild(host);
    }
    if (host && storyId) {
      app.addView({hostElement: host, initialData: {storyId: storyId}});
    }
    // Pages that mount their own views (the gallery) listen for this.
    document.dispatchEvent(new CustomEvent('flutter-static-ready', {detail: app}));
};
_flutter.loader.load({
  config: {
    entrypointBaseUrl: BASE,
    assetBase: BASE,
    canvasKitBaseUrl: BASE + 'canvaskit/',
  },
  onEntrypointLoaded: onEntrypointLoaded,
});
""");
    }
    final webMain = File('story/web_main.dart');
    if (!webMain.existsSync()) {
      final main = File('story/main.dart').readAsStringSync();
      final match = RegExp(r'class (\w+) extends Stories').firstMatch(main);
      if (match == null) {
        stderr.writeln('Could not find a Stories subclass in story/main.dart');
        return 1;
      }
      webMain.writeAsStringSync(
        """import 'package:flutter_static/flutter_static.dart';

import 'main.dart';

// Web entry point: the detail pages mount stories as live views.
void main() => runFlutterStaticWeb(const ${match.group(1)}());
""",
      );
      stdout.writeln('Created story/web_main.dart');
    }
    stdout.writeln('flutter_static: building web (wasm)...');
    var build = await Process.start('flutter', [
      'build',
      'web',
      '--wasm',
      '-t',
      'story/web_main.dart',
    ], mode: ProcessStartMode.inheritStdio);
    var code = await build.exitCode;
    if (code != 0) {
      // Legacy dart:html plugins in the dependency tree cannot compile to
      // wasm; the JS compiler handles them.
      stdout.writeln(
        'flutter_static: wasm build failed, retrying as a JS build...',
      );
      build = await Process.start('flutter', [
        'build',
        'web',
        '-t',
        'story/web_main.dart',
      ], mode: ProcessStartMode.inheritStdio);
      code = await build.exitCode;
    }
    if (code == 0) {
      stdout.writeln(
        'Web build done. Story detail pages now serve a live view at '
        '/story/<id>.',
      );
    }
    return code;
  }
}

class _ListCommand extends Command<int> {
  _ListCommand() {
    argParser
      ..addFlag('json', negatable: false, help: 'Print the raw index JSON.')
      ..addOption('url', help: _urlHelp);
  }

  @override
  String get name => 'list';
  @override
  String get description => 'List story ids from the running catalog.';

  @override
  Future<int> run() async {
    final url = (argResults!['url'] as String?) ?? _defaultUrl();
    final body = await _fetch('$url/index.json', url);
    if (body == null) return 1;
    if (argResults!['json'] as bool) {
      stdout.writeln(utf8.decode(body));
    } else {
      final index = jsonDecode(utf8.decode(body)) as Map<String, dynamic>;
      for (final story
          in (index['stories'] as List).cast<Map<String, dynamic>>()) {
        stdout.writeln(story['id']);
      }
    }
    return 0;
  }
}

class _RenderCommand extends Command<int> {
  _RenderCommand() {
    argParser
      ..addOption(
        'out',
        abbr: 'o',
        help: 'Output file (default: <id>.png with / as _).',
      )
      ..addMultiOption(
        'knob',
        abbr: 'k',
        valueHelp: 'id=option',
        help:
            'A storyline knob choice (the line\'s mock switches; see '
            '"knobs" in `list --json`). Repeatable.',
      )
      ..addOption('url', help: _urlHelp);
  }

  @override
  String get name => 'render';
  @override
  String get description => 'Render one story to a PNG file.';
  @override
  String get invocation =>
      'flutter_static render <story-id> [-o out.png] [-k knob=option]';

  @override
  Future<int> run() async {
    final rest = argResults!.rest;
    if (rest.isEmpty) usageException('A story id is required.');
    final id = rest.first;
    final url = (argResults!['url'] as String?) ?? _defaultUrl();
    final out =
        (argResults!['out'] as String?) ?? '${id.replaceAll('/', '_')}.png';
    final knobs = _knobChoices(argResults!['knob'] as List<String>);
    if (await _renderStory(id, url, out, knobs: knobs) == null) return 1;
    stdout.writeln(out);
    return 0;
  }
}

/// Which widgets made a render and where they are written: the widget
/// under a point of the PNG, or the whole tree. The agent-side twin of
/// Studio's Option-click.
class _InspectCommand extends Command<int> {
  _InspectCommand() {
    argParser
      ..addOption(
        'at',
        valueHelp: 'X,Y',
        help:
            'A point in pixels of the story\'s PNG (as `render` writes it): '
            'the widgets under it, nearest first, instead of the whole tree.',
      )
      ..addMultiOption(
        'knob',
        abbr: 'k',
        valueHelp: 'id=option',
        help: 'A storyline knob choice, as for `render`. Repeatable.',
      )
      ..addFlag('json', negatable: false, help: 'Print the raw JSON.')
      ..addOption('url', help: _urlHelp);
  }

  @override
  String get name => 'inspect';
  @override
  String get description =>
      'Which widgets are in a story\'s render, and which source lines '
      'made them.';
  @override
  String get invocation =>
      'flutter_static inspect <story-id> [--at X,Y] [-k knob=option] [--json]';

  @override
  Future<int> run() async {
    final rest = argResults!.rest;
    if (rest.isEmpty) usageException('A story id is required.');
    final id = rest.first;
    final url = (argResults!['url'] as String?) ?? _defaultUrl();
    final knobs = _knobChoices(argResults!['knob'] as List<String>);
    final at = argResults!['at'] as String?;
    var query = _freshQuery(knobs);
    var kind = 'tree';
    if (at != null) {
      final xy = at.split(',').map((s) => double.tryParse(s.trim())).toList();
      if (xy.length != 2 || xy.contains(null)) {
        usageException('--at takes X,Y in PNG pixels; got "$at".');
      }
      query += '&x=${xy[0]}&y=${xy[1]}';
      kind = 'at';
    }
    final body = await _fetch(
      '$url/story/$id/$kind.json?$query',
      url,
      notFound: 'Story "$id" not found. See: flutter_static list',
    );
    if (body == null) return 1;
    final text = utf8.decode(body);
    if (argResults!['json'] as bool) {
      stdout.writeln(text);
      return 0;
    }
    final json = jsonDecode(text) as Map<String, dynamic>;
    if (kind == 'tree') {
      final widgets = (json['widgets'] as List).cast<Map<String, dynamic>>();
      if (widgets.isEmpty) {
        stdout.writeln('No widgets from this project in $id.');
      }
      _printTree(widgets, 0);
    } else {
      final chain = (json['chain'] as List).cast<Map<String, dynamic>>();
      if (chain.isEmpty) {
        stdout.writeln(
          'Nothing from this project at ${json['x']},${json['y']}.',
        );
      } else {
        stdout.writeln('At ${json['x']},${json['y']}, nearest first:');
        for (final w in chain) {
          stdout.writeln('  ${_widgetLine(w)}');
        }
      }
    }
    return 0;
  }

  void _printTree(List<Map<String, dynamic>> widgets, int depth) {
    for (final w in widgets) {
      stdout.writeln('${'  ' * depth}${_widgetLine(w)}');
      _printTree(
        (w['children'] as List).cast<Map<String, dynamic>>(),
        depth + 1,
      );
    }
  }

  /// `AppButton "Primary"  story/stories/buttons.dart:13:11  @24,24 120x40`
  static String _widgetLine(Map<String, dynamic> w) {
    final text = w['text'] == null ? '' : ' "${w['text']}"';
    final bounds = w['bounds'] as List?;
    final where = bounds == null
        ? ''
        : '  @${bounds[0]},${bounds[1]} ${bounds[2]}x${bounds[3]}';
    return '${w['widget']}$text  ${w['location'] ?? 'no source location'}$where';
  }
}

const _urlHelp =
    'Catalog URL. Default: localhost on the port registered for this '
    'directory in ~/.flutter_static/ports.jsonl (else 8474).';

class _PortCommand extends Command<int> {
  _PortCommand() {
    argParser.addFlag(
      'all',
      negatable: false,
      help: 'Print every registered project and its port.',
    );
  }

  @override
  String get name => 'port';
  @override
  String get description =>
      'Print the catalog port for this directory (allocating one if needed).';

  @override
  Future<int> run() async {
    if (argResults!['all'] as bool) {
      for (final entry in _PortRegistry.read().entries) {
        stdout.writeln('${entry.value}\t${entry.key}');
      }
      return 0;
    }
    stdout.writeln(await _PortRegistry.claim());
    return 0;
  }
}

/// Global port registry: ~/.flutter_static/ports.jsonl holds one
/// `{"pwd": "/abs/project", "port": 8474}` line per project, so catalogs of
/// different projects never fight over a port and `list`/`render` find the
/// right one without --url. A project keeps its port across sessions.
class _PortRegistry {
  static const basePort = 8474;

  static File get file {
    final home =
        Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        Directory.current.path;
    return File(p.join(home, '.flutter_static', 'ports.jsonl'));
  }

  /// Canonical current directory: symlinked checkouts map to one entry.
  static String get _cwd {
    try {
      return Directory.current.resolveSymbolicLinksSync();
    } on FileSystemException {
      return Directory.current.path;
    }
  }

  /// pwd -> port in file order. Malformed lines are skipped, not fatal.
  static Map<String, int> read() {
    final f = file;
    if (!f.existsSync()) return {};
    final entries = <String, int>{};
    for (final line in f.readAsLinesSync()) {
      if (line.trim().isEmpty) continue;
      try {
        final json = jsonDecode(line);
        if (json is! Map) continue;
        final pwd = json['pwd'];
        final port = json['port'];
        if (pwd is String && port is int) entries[pwd] = port;
      } on FormatException {
        continue;
      }
    }
    return entries;
  }

  static void _write(Map<String, int> entries) {
    final f = file;
    f.parent.createSync(recursive: true);
    final out = StringBuffer();
    for (final entry in entries.entries) {
      out.writeln(jsonEncode({'pwd': entry.key, 'port': entry.value}));
    }
    f.writeAsStringSync(out.toString());
  }

  /// Port registered for the current directory, or null.
  static int? lookup() => read()[_cwd];

  /// Port for the current directory. Reuses the registered one; otherwise
  /// (or when [requested] is given) records the port and returns it. A new
  /// allocation is the lowest port from [basePort] that no other project
  /// holds and that binds right now. Returns null for an invalid request.
  static Future<int?> claim({int? requested}) async {
    if (requested != null && (requested < 1 || requested > 65535)) return null;
    final entries = read();
    final dir = _cwd;
    // Projects that were deleted or moved free their ports.
    final before = entries.length;
    entries.removeWhere((pwd, _) => pwd != dir && !Directory(pwd).existsSync());
    var dirty = entries.length != before;
    final int port;
    final registered = entries[dir];
    if (requested != null) {
      port = requested;
    } else if (registered != null) {
      port = registered;
    } else {
      final taken = entries.values.toSet();
      var candidate = basePort;
      while (taken.contains(candidate) || !await _bindable(candidate)) {
        candidate++;
      }
      port = candidate;
    }
    if (requested != null) {
      final holders = entries.entries
          .where((e) => e.value == requested && e.key != dir)
          .map((e) => e.key);
      for (final holder in holders) {
        stderr.writeln(
          'flutter_static: port $requested is also registered to $holder',
        );
      }
    }
    if (entries[dir] != port) {
      entries[dir] = port;
      dirty = true;
    }
    if (dirty || !file.existsSync()) _write(entries);
    return port;
  }

  static Future<bool> _bindable(int port) async {
    try {
      final socket = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        port,
      );
      await socket.close();
      return true;
    } on SocketException {
      return false;
    }
  }
}

/// The query that makes a request see the latest save, plus the [knobs].
///
/// A request sent right after a save can reach the catalog before the
/// watcher's notice of that save. `edited` is the newest source mtime
/// under the watched roots; when it is newer than the last reload, the
/// catalog waits for the next one. `settle` is the fallback outside a
/// project, where there are no roots to walk.
String _freshQuery(Map<String, String> knobs) {
  final edited = _newestSourceMtime();
  final query = StringBuffer(
    edited == null ? 'settle=250' : 'edited=${edited.millisecondsSinceEpoch}',
  );
  for (final entry in knobs.entries) {
    query.write(
      '&k.${Uri.encodeQueryComponent(entry.key)}='
      '${Uri.encodeQueryComponent(entry.value)}',
    );
  }
  return '$query';
}

/// `id=option` choices from a repeated `--knob`.
Map<String, String> _knobChoices(List<String> choices) {
  final knobs = <String, String>{};
  for (final choice in choices) {
    final eq = choice.indexOf('=');
    if (eq < 1 || eq == choice.length - 1) {
      throw UsageException('--knob takes id=option; got "$choice".', '');
    }
    knobs[choice.substring(0, eq)] = choice.substring(eq + 1);
  }
  return knobs;
}

/// GET [url]; on failure print a hint mentioning [serverUrl] and return null.
Future<List<int>?> _fetch(
  String url,
  String serverUrl, {
  String? notFound,
  void Function(HttpHeaders headers)? onHeaders,
}) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri.parse(url));
    final response = await request.close();
    onHeaders?.call(response.headers);
    if (response.statusCode == HttpStatus.notFound) {
      stderr.writeln(notFound ?? '404: $url');
      return null;
    }
    final bytes = (await response.toList()).expand((chunk) => chunk).toList();
    if (response.statusCode != HttpStatus.ok) {
      stderr.writeln('HTTP ${response.statusCode}: $url');
      // A 409 carries the hot reload failure; a 500 the capture error.
      final text = utf8.decode(bytes, allowMalformed: true).trim();
      if (text.isNotEmpty) stderr.writeln(text);
      return null;
    }
    return bytes;
  } on SocketException {
    stderr.writeln(
      'No catalog running at $serverUrl. '
      'Start one with: flutter_static run',
    );
    return null;
  } finally {
    client.close();
  }
}

/// Writes story/main.dart and story/stories/example.dart, skipping files
/// that exist unless [force]. Returns the paths written.
List<String> _scaffoldStories({bool force = false}) {
  final written = <String>[];
  // A project with its own story/main.dart has its own stories; the
  // example only belongs next to a freshly scaffolded main.
  if (File('story/main.dart').existsSync() && !force) return written;
  for (final (path, content) in [
    ('story/main.dart', _mainTemplate),
    ('story/stories/example.dart', _exampleTemplate),
  ]) {
    final file = File(path);
    if (file.existsSync() && !force) continue;
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
    written.add(path);
  }
  return written;
}

const _mainTemplate = '''
import 'package:flutter_static/flutter_static.dart';

import 'stories/example.dart' as example;

// Run with: flutter_static run
void main() => runFlutterStatic(const MyStories());

// One file per story group under stories/ and one per flow under lines/,
// each exposing a top-level function that build() calls fresh on every
// hot reload. Never store stories in a variable: main() never re-runs,
// so a closure created by the old main() keeps its old code.
//
// Scaffold more with:
//   flutter_static add story <group>/<name>
//   flutter_static add storyline <name>
class MyStories extends Stories {
  const MyStories();

  @override
  List<Storyline> storylines() => [];

  @override
  List<Story> build() => [
    ...example.stories(),
  ];
}
''';

const _exampleTemplate = '''
import 'package:flutter/material.dart';
import 'package:flutter_static/flutter_static.dart';

List<Story> stories() => [
  Story(
    'example/hello',
    () => Container(
      padding: const EdgeInsets.all(24),
      color: Colors.indigo,
      child: const Text(
        'Hello, flutter_static',
        style: TextStyle(color: Colors.white, fontSize: 24),
      ),
    ),
  ),
];
''';

class _AddCommand extends Command<int> {
  _AddCommand() {
    addSubcommand(_AddStoryCommand());
    addSubcommand(_AddStorylineCommand());
  }

  @override
  String get name => 'add';
  @override
  String get description =>
      'Scaffold a story or a storyline and register it in story/main.dart.';
}

/// `add story <group>/<name>`: a placeholder story in `stories/<group>.dart`
/// (created on first use), registered in main.dart.
class _AddStoryCommand extends Command<int> {
  _AddStoryCommand() {
    argParser
      ..addOption(
        'width',
        help:
            "The design's outer width, for a new group's shell "
            '(default: 390). Ignored when the group file exists.',
      )
      ..addOption(
        'bg',
        help:
            "The design's background as hex, for a new group's shell "
            '(default: FFFFFF). Ignored when the group file exists.',
      )
      ..addOption('url', help: _urlHelp);
  }

  @override
  String get name => 'story';
  @override
  String get description =>
      'Add a placeholder story. The group becomes stories/<group>.dart; '
      'the first story in a group also gets the shell (background, width) '
      'every story in it renders in.';
  @override
  String get invocation =>
      'flutter_static add story <group>/<name> [--width 390] [--bg 0A0B0D]';

  @override
  Future<int> run() async {
    final rest = argResults!.rest;
    if (rest.isEmpty) usageException('A story id is required.');
    final id = rest.first;
    if (!RegExp(r'^[a-z0-9][a-z0-9_-]*(/[a-z0-9][a-z0-9_-]*)+$').hasMatch(id)) {
      usageException(
        'Story ids are lowercase slugs with at least two segments, '
        'like torget/listing-card.',
      );
    }
    if (!_StoryDir.check()) return 1;

    final segments = id.split('/');
    final group = segments.sublist(0, segments.length - 1);
    final relPath = '${group.map(_StoryDir.ident).join('/')}.dart';
    final file = File('story/stories/$relPath');
    final alias = group.map(_StoryDir.ident).join('_');

    final String frameCall;
    if (file.existsSync()) {
      final existing = file.readAsStringSync();
      if (RegExp("'${RegExp.escape(id)}'").hasMatch(existing)) {
        stderr.writeln('$id already exists in ${file.path}.');
        return 1;
      }
      frameCall = _StoryDir.frameIn(existing);
      final lines = existing.split('\n');
      final ok = _StoryDir.insertInList(
        lines,
        RegExp(r'List<Story> stories\(\)\s*=>'),
        "Story('$id', () => ${frameCall}const Placeholder())),",
      );
      if (!ok) {
        stderr.writeln(
          'Could not find `List<Story> stories() => [` in ${file.path}; '
          'add the story by hand.',
        );
        return 1;
      }
      file.writeAsStringSync(lines.join('\n'));
      stdout.writeln('Added $id to ${file.path}');
    } else {
      final width = argResults!['width'] as String?;
      final bg = argResults!['bg'] as String?;
      final support = File('story/stories/support.dart');
      final useSupport =
          width == null &&
          bg == null &&
          support.existsSync() &&
          support.readAsStringSync().contains('Widget storyFrame(');
      final String head;
      if (useSupport) {
        // The project already has a frame every story uses; join it.
        final rel = p.posix.relative(
          'stories/support.dart',
          from: p.posix.dirname('stories/$relPath'),
        );
        head = "import '$rel';\n";
        frameCall = 'storyFrame(';
      } else {
        final hex = (bg ?? 'FFFFFF').replaceFirst('#', '').toUpperCase();
        if (!RegExp(r'^[0-9A-F]{6}$').hasMatch(hex)) {
          usageException('--bg takes six hex digits, like 0A0B0D.');
        }
        final w = width ?? '390';
        if (double.tryParse(w) == null) {
          usageException('--width must be a number.');
        }
        head =
            '/// The design\'s background and outer width, so renders line up\n'
            '/// with the reference. Every story in this group renders in it.\n'
            'Widget _shell(Widget child) => ColoredBox(\n'
            '  color: const Color(0xFF$hex),\n'
            '  child: SizedBox(width: $w, child: child),\n'
            ');\n';
        frameCall = '_shell(';
      }
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(
        "import 'package:flutter/material.dart';\n"
        "import 'package:flutter_static/flutter_static.dart';\n"
        '\n'
        '$head'
        '\n'
        'List<Story> stories() => [\n'
        "  Story('$id', () => ${frameCall}const Placeholder())),\n"
        '];\n',
      );
      stdout.writeln('Created ${file.path}');
      final registered = _StoryDir.registerGroup(relPath, alias);
      if (!registered) return 1;
    }
    stdout.writeln('  $id');
    await _StoryDir.reportListed([
      id,
    ], (argResults!['url'] as String?) ?? _defaultUrl());
    return 0;
  }
}

/// `add storyline <name>`: `lines/<name>.dart` with one row of placeholder
/// cells, registered in main.dart.
class _AddStorylineCommand extends Command<int> {
  _AddStorylineCommand() {
    argParser
      ..addOption('title', help: 'Page title (default: from the name).')
      ..addOption(
        'cells',
        help:
            'Comma-separated cell ids for the first row, one screen each '
            '(default: one cell, "home").',
      )
      ..addOption('url', help: _urlHelp);
  }

  @override
  String get name => 'storyline';
  @override
  String get description =>
      'Add a flow: lines/<name>.dart with a row of placeholder screens. '
      'The id is flows/<name> unless you give both segments.';
  @override
  String get invocation =>
      'flutter_static add storyline <name> [--title T] [--cells a,b,c]';

  @override
  Future<int> run() async {
    final rest = argResults!.rest;
    if (rest.isEmpty) usageException('A storyline name is required.');
    final arg = rest.first;
    if (!RegExp(
      r'^[a-z0-9][a-z0-9_-]*(/[a-z0-9][a-z0-9_-]*)?$',
    ).hasMatch(arg)) {
      usageException(
        'Storyline names are lowercase slugs: house-os or flows/house-os.',
      );
    }
    if (!_StoryDir.check()) return 1;

    final id = arg.contains('/') ? arg : 'flows/$arg';
    final name = id.split('/').last;
    final fileName = _StoryDir.ident(name);
    final file = File('story/lines/$fileName.dart');
    if (file.existsSync()) {
      stderr.writeln('${file.path} already exists.');
      return 1;
    }
    final title = (argResults!['title'] as String?) ?? _StoryDir.title(name);
    final cells = ((argResults!['cells'] as String?) ?? 'home')
        .split(',')
        .map((c) => c.trim())
        .where((c) => c.isNotEmpty)
        .toSet()
        .toList();
    for (final cell in cells) {
      if (!RegExp(r'^[a-z0-9][a-z0-9_-]*$').hasMatch(cell)) {
        usageException('Cell ids are lowercase slugs; got "$cell".');
      }
    }

    final buf = StringBuffer()
      ..writeln("import 'package:flutter/material.dart';")
      ..writeln("import 'package:flutter_static/flutter_static.dart';")
      ..writeln()
      ..writeln('/// $title.')
      ..writeln('Storyline storyline() => const Storyline(')
      ..writeln("  '$id',")
      ..writeln("  title: '${title.replaceAll("'", r"\'")}',")
      ..writeln('  rows: [')
      ..writeln('    StorylineRow(')
      ..writeln("      'Screens',")
      ..writeln('      cells: [');
    for (final cell in cells) {
      buf
        ..writeln('        Cell(')
        ..writeln("          '$cell',")
        ..writeln("          title: '${_StoryDir.title(cell)}',")
        ..writeln(
          "          variants: [Story('default', _${_StoryDir.camel(cell)})],",
        )
        ..writeln('        ),');
    }
    buf
      ..writeln('      ],')
      ..writeln('    ),')
      ..writeln('  ],')
      ..writeln(');');
    for (final cell in cells) {
      buf
        ..writeln()
        ..writeln('Widget _${_StoryDir.camel(cell)}() => const Placeholder();');
    }
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(buf.toString());
    stdout.writeln('Created ${file.path}');

    if (!_StoryDir.registerLine(fileName)) return 1;
    final ids = [for (final cell in cells) '$id/$cell/default'];
    for (final storyId in ids) {
      stdout.writeln('  $storyId');
    }
    await _StoryDir.reportListed(
      ids,
      (argResults!['url'] as String?) ?? _defaultUrl(),
    );
    return 0;
  }
}

/// The consumer's story/ folder and the edits `add` makes to main.dart.
class _StoryDir {
  static final main = File('story/main.dart');

  static bool check() {
    if (main.existsSync()) return true;
    stderr.writeln(
      'No story/main.dart here. Scaffold one with: flutter_static setup',
    );
    return false;
  }

  /// `house-os` -> `house_os`.
  static String ident(String segment) => segment.replaceAll('-', '_');

  /// `house-os` -> `houseOs`.
  static String camel(String s) {
    final parts = s.split(RegExp(r'[-_]')).where((x) => x.isNotEmpty).toList();
    return parts.first +
        parts.skip(1).map((x) => x[0].toUpperCase() + x.substring(1)).join();
  }

  /// `house-os` -> `House os`.
  static String title(String s) {
    final t = s.replaceAll(RegExp(r'[-_]'), ' ');
    return t[0].toUpperCase() + t.substring(1);
  }

  /// The frame call (with its opening paren) the stories in [source]
  /// wrap themselves in, or '' when they render bare.
  static String frameIn(String source) {
    for (final frame in ['storyFrame(', '_shell(', '_frame(']) {
      if (source.contains(frame)) return frame;
    }
    return '';
  }

  /// Registers `stories/<relPath>` in main.dart: an import and a spread in
  /// build(). Prints what to do by hand if main.dart is not in the
  /// expected shape.
  static bool registerGroup(String relPath, String alias) {
    final lines = main.readAsStringSync().split('\n');
    final importLine = "import 'stories/$relPath' as $alias;";
    if (!lines.contains(importLine)) {
      _addImport(lines, importLine, "import 'stories/", fallbackAfter: null);
    }
    final ok = insertInList(
      lines,
      RegExp(r'List<Story> build\(\)\s*=>'),
      '...$alias.stories(),',
    );
    if (!ok) {
      stderr.writeln(
        'Could not find `List<Story> build() => [` in story/main.dart. '
        'Register the group by hand:\n'
        '  $importLine\n'
        '  ...$alias.stories(),',
      );
      return false;
    }
    main.writeAsStringSync(lines.join('\n'));
    stdout.writeln('Registered $alias in story/main.dart');
    return true;
  }

  /// Registers `lines/<fileName>.dart` in main.dart: an import and an
  /// entry in storylines(), adding the override if the class has none.
  static bool registerLine(String fileName) {
    final lines = main.readAsStringSync().split('\n');
    final alias = 'line_$fileName';
    final importLine = "import 'lines/$fileName.dart' as $alias;";
    if (!lines.contains(importLine)) {
      _addImport(
        lines,
        importLine,
        "import 'lines/",
        fallbackAfter: "import 'stories/",
      );
    }
    final opener = RegExp(r'List<Storyline> storylines\(\)\s*=>');
    if (!lines.any(opener.hasMatch)) {
      // No override yet: add one just above build()'s @override.
      var at = lines.indexWhere(RegExp(r'List<Story> build\(\)').hasMatch);
      if (at == -1) {
        stderr.writeln(
          'Could not find build() in story/main.dart. Register the line by '
          'hand:\n  $importLine\n  $alias.storyline(),',
        );
        return false;
      }
      if (at > 0 && lines[at - 1].trim() == '@override') {
        at--;
      }
      final indent = RegExp(r'^\s*').firstMatch(lines[at])!.group(0)!;
      lines.insertAll(at, [
        '$indent@override',
        '${indent}List<Storyline> storylines() => [];',
        '',
      ]);
    }
    insertInList(lines, opener, '$alias.storyline(),');
    main.writeAsStringSync(lines.join('\n'));
    stdout.writeln('Registered $alias in story/main.dart');
    return true;
  }

  /// Inserts [importLine] among the imports starting with [prefix],
  /// keeping them sorted; starts a new block after the last
  /// [fallbackAfter] import (or the last import at all) when there are
  /// none yet.
  static void _addImport(
    List<String> lines,
    String importLine,
    String prefix, {
    required String? fallbackAfter,
  }) {
    final block = [
      for (var i = 0; i < lines.length; i++)
        if (lines[i].startsWith(prefix)) i,
    ];
    if (block.isNotEmpty) {
      for (final i in block) {
        if (lines[i].compareTo(importLine) > 0) {
          lines.insert(i, importLine);
          return;
        }
      }
      lines.insert(block.last + 1, importLine);
      return;
    }
    var after = -1;
    if (fallbackAfter != null) {
      after = lines.lastIndexWhere((l) => l.startsWith(fallbackAfter));
    }
    if (after == -1) {
      after = lines.lastIndexWhere((l) => l.startsWith('import '));
    }
    if (after == -1) {
      lines.insertAll(0, [importLine, '']);
      return;
    }
    lines.insertAll(after + 1, ['', importLine]);
  }

  /// Appends [entry] to the list literal that the first line matching
  /// [opener] opens, handling both `=> [` with a closing `];` on its own
  /// line and the one-line `=> [];`. Returns false if neither is found.
  static bool insertInList(List<String> lines, Pattern opener, String entry) {
    final start = lines.indexWhere((l) => l.contains(opener));
    if (start == -1) return false;
    final line = lines[start];
    final oneLine = RegExp(r'=>\s*(const\s+)?\[\];\s*$');
    if (oneLine.hasMatch(line)) {
      final indent = RegExp(r'^\s*').firstMatch(line)!.group(0)!;
      lines.replaceRange(start, start + 1, [
        line.replaceFirst(oneLine, '=> ['),
        '$indent  $entry',
        '$indent];',
      ]);
      return true;
    }
    if (!RegExp(r'\[\s*$').hasMatch(line)) return false;
    final close = lines.indexWhere(
      (l) => RegExp(r'^\s*\];\s*$').hasMatch(l),
      start,
    );
    if (close == -1) return false;
    final prev = lines[close - 1];
    final closeIndent = RegExp(r'^\s*').firstMatch(lines[close])!.group(0)!;
    final indent = close - 1 > start && prev.trim().isNotEmpty
        ? RegExp(r'^\s*').firstMatch(prev)!.group(0)!
        : '$closeIndent  ';
    lines.insert(close, '$indent$entry');
    return true;
  }

  /// Polls the running catalog until every id in [ids] is listed, for a
  /// few seconds, and says what happened. Never fails the command: the
  /// files are written either way.
  static Future<void> reportListed(List<String> ids, String url) async {
    final deadline = DateTime.now().add(const Duration(seconds: 8));
    while (true) {
      final listed = await _index(url);
      if (listed == null) {
        stdout.writeln(
          'No catalog running at $url; start one with: flutter_static run',
        );
        return;
      }
      final missing = ids.where((id) => !listed.contains(id)).toList();
      if (missing.isEmpty) {
        stdout.writeln('Listed at $url/story/${ids.first}');
        stdout.writeln('Render: flutter_static render ${ids.first} -o out.png');
        return;
      }
      if (DateTime.now().isAfter(deadline)) {
        stdout.writeln(
          'Not listed yet at $url: ${missing.join(', ')}. The reload may '
          'have failed; check the flutter_static run terminal.',
        );
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
  }

  /// Story ids from the catalog at [url], or null when nothing answers.
  static Future<Set<String>?> _index(String url) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    try {
      final request = await client.getUrl(Uri.parse('$url/index.json'));
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) return null;
      final body = await response.transform(utf8.decoder).join();
      final index = jsonDecode(body) as Map<String, dynamic>;
      return {
        for (final story
            in (index['stories'] as List).cast<Map<String, dynamic>>())
          story['id'] as String,
      };
    } on SocketException {
      return null;
    } on HttpException {
      return null;
    } finally {
      client.close();
    }
  }
}
