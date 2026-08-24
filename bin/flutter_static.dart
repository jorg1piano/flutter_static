import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;
import 'package:watcher/watcher.dart';

const _defaultUrl = 'http://localhost:8474';

Future<void> main(List<String> arguments) async {
  final runner =
      CommandRunner<int>(
          'flutter_static',
          'Widget story catalog: PNG renders over HTTP.',
        )
        ..addCommand(_RunCommand())
        ..addCommand(_InitCommand())
        ..addCommand(_BuildWebCommand())
        ..addCommand(_SetupCommand())
        ..addCommand(_ListCommand())
        ..addCommand(_RenderCommand());
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
      ..addOption('port', defaultsTo: '8474', help: 'Catalog server port.')
      ..addOption(
        'web-port',
        defaultsTo: '8476',
        help: 'Port for the live web dev server.',
      )
      ..addFlag(
        'live',
        defaultsTo: true,
        help:
            'Also run a hot-reloading web dev server that the story detail '
            'pages embed as the live view. Needs a one-time '
            'flutter_static build-web to scaffold web support.',
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
    _port = argResults!['port'] as String;
    final webPort = argResults!['web-port'] as String;
    final pidFile = File('.dart_tool/flutter_static.pid');
    pidFile.parent.createSync(recursive: true);
    final child = await Process.start('flutter', [
      'run',
      '-d',
      argResults!['device'] as String,
      '-t',
      target,
      '--dart-define=FLUTTER_STATIC_PORT=$_port',
      '--dart-define=FLUTTER_STATIC_WEB_PORT=$webPort',
      '--pid-file',
      pidFile.path,
    ], mode: ProcessStartMode.inheritStdio);
    final webPidFile = File('.dart_tool/flutter_static_web.pid');
    final webTarget =
        argResults!['live'] as bool &&
            File('story/web_main.dart').existsSync() &&
            Directory('web').existsSync()
        ? _linkedWebTarget()
        : null;
    if (webTarget != null) {
      _webArgs = [
        'run',
        '-d',
        'web-server',
        '--web-port',
        webPort,
        '-t',
        webTarget,
        '--pid-file',
        webPidFile.path,
      ];
      _webPidFile = webPidFile;
      stdout.writeln(
        'flutter_static: starting live web dev server on :$webPort',
      );
      await _startWeb();
    }
    _watchSources(pidFile, webTarget == null ? null : webPidFile);
    final code = await child.exitCode;
    _shuttingDown = true;
    _webChild?.kill();
    return code;
  }

  void _watchSources(File pidFile, File? webPidFile) {
    final roots = _localPackageRoots();
    Timer? debounce;
    void watchRoot(String root) {
      DirectoryWatcher(root).events.listen(
        (event) {
          final path = event.path;
          if (!path.endsWith('.dart')) return;
          if (path.contains('/.dart_tool/') ||
              path.contains('/build/') ||
              path.contains('/.git/')) {
            return;
          }
          debounce?.cancel();
          debounce = Timer(const Duration(milliseconds: 250), () {
            _signal(pidFile, ProcessSignal.sigusr1);
            // Restart, not reload: only a web hot restart updates the bundle
            // served to fresh page loads (each story navigation is one).
            if (webPidFile != null) _requestWebRestart(webPidFile);
          });
        },
        onError: (Object e) {
          stderr.writeln(
            'flutter_static: watcher error on $root: $e; '
            'restarting watcher',
          );
          watchRoot(root);
        },
        onDone: () {
          stderr.writeln('flutter_static: watcher for $root ended; restarting');
          watchRoot(root);
        },
      );
    }

    // Watch only the Dart-bearing subdirectories: watching a whole package
    // root means the watcher's initial scan crawls deps/_build/node_modules
    // (minutes on a big repo) before delivering a single event.
    final targets = <String>[];
    for (final root in roots) {
      final narrow = [
        '$root/lib',
        '$root/story',
      ].where((d) => Directory(d).existsSync()).toList();
      targets.addAll(narrow.isEmpty ? [root] : narrow);
    }
    targets.forEach(watchRoot);
    stdout.writeln('flutter_static: watching ${targets.join(', ')}');
  }

  var _port = '8474';

  void _signal(File pidFile, ProcessSignal s) {
    final raw = pidFile.existsSync() ? pidFile.readAsStringSync().trim() : '';
    final pid = int.tryParse(raw);
    if (pid != null) Process.killPid(pid, s);
  }

  /// Entry point for the web dev server, reached through the symlink
  /// lib/flutter_static_story -> ../story.
  ///
  /// A target outside lib/ is compiled under a private org-dartlang-app:
  /// scheme (flutter_tools, ResidentWebRunner._generateEntrypoint) that the
  /// hot-restart file invalidator cannot stat, so edits under story/ never
  /// recompile: the restart reports success and serves the old bundle.
  /// Through the link every story file has a package: URI, which restart
  /// tracks like any other source.
  String? _linkedWebTarget() {
    const dir = 'lib/flutter_static_story';
    final link = Link(dir);
    if (link.existsSync()) {
      final target = link.targetSync();
      if (target != '../story') {
        stderr.writeln(
          'flutter_static: $dir points at $target, expected ../story; '
          'not starting the live web server.',
        );
        return null;
      }
    } else if (FileSystemEntity.typeSync(dir) !=
        FileSystemEntityType.notFound) {
      stderr.writeln(
        'flutter_static: $dir exists and is not a symlink; '
        'not starting the live web server.',
      );
      return null;
    } else {
      link.createSync('../story');
      stdout.writeln(
        'flutter_static: created $dir -> ../story '
        '(the live web server compiles stories through it)',
      );
    }
    return '$dir/web_main.dart';
  }

  // The live web dev server. It drops SIGUSR2 while a restart is in flight,
  // so a save that lands mid-restart is re-signalled once the runner reports
  // back; and it can wedge (a restart that never reports, after which new
  // pages never run main), so a restart that stays silent past the watchdog
  // gets the runner killed and relaunched.
  List<String>? _webArgs;
  File? _webPidFile;
  Process? _webChild;
  var _shuttingDown = false;
  var _webBusy = false;
  var _webSignaledAt = DateTime.fromMillisecondsSinceEpoch(0);
  var _webLaunchedAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime? _webChangedAt;
  var _webErrors = false;
  var _webRelaunch = false;
  Timer? _webWatchdog;
  static const _webWatchdogTimeout = Duration(seconds: 45);

  Future<void> _startWeb() async {
    final args = _webArgs;
    if (args == null) return;
    _webLaunchedAt = DateTime.now();
    _webBusy = true;
    _webErrors = false;
    final child = await Process.start('flutter', args);
    _webChild = child;
    // Not inheritStdio: the macOS run owns the terminal; surface the web
    // tool's output line-prefixed instead.
    child.stdout
        .transform(const SystemEncoding().decoder)
        .transform(const LineSplitter())
        .listen((l) {
          stdout.writeln('[web] $l');
          _onWebOutput(l);
        });
    child.stderr
        .transform(const SystemEncoding().decoder)
        .transform(const LineSplitter())
        .listen((l) => stderr.writeln('[web] $l'));
    unawaited(
      child.exitCode.then((code) {
        if (_webChild != child) return;
        _webChild = null;
        _webWatchdog?.cancel();
        _webBusy = false;
        if (_shuttingDown) return;
        if (_webRelaunch) {
          _webRelaunch = false;
          stdout.writeln('flutter_static: relaunching the live web dev server');
          _startWeb();
        } else {
          stderr.writeln(
            'flutter_static: live web dev server exited ($code); '
            'it relaunches on the next save.',
          );
        }
      }),
    );
  }

  void _requestWebRestart(File webPidFile) {
    _webChangedAt = DateTime.now();
    if (_webChild == null) {
      _startWeb();
      return;
    }
    if (!_webBusy) _signalWeb(webPidFile);
  }

  void _signalWeb(File webPidFile) {
    _webBusy = true;
    _webErrors = false;
    _webSignaledAt = DateTime.now();
    _signal(webPidFile, ProcessSignal.sigusr2);
    _webWatchdog?.cancel();
    _webWatchdog = Timer(_webWatchdogTimeout, _onWebStuck);
  }

  void _onWebStuck() {
    final child = _webChild;
    if (child == null) return;
    stderr.writeln(
      'flutter_static: the live web dev server did not finish its restart '
      'in ${_webWatchdogTimeout.inSeconds}s; killing and relaunching it.',
    );
    _webRelaunch = true;
    child.kill(ProcessSignal.sigkill);
  }

  /// Follows the web runner's stdout. A restart's progress line prints when
  /// it stops: before the outcome line on success, after the compiler's
  /// errors on failure.
  void _onWebOutput(String line) {
    final webPidFile = _webPidFile;
    if (webPidFile == null) return;
    if (line.contains(': Error: ')) {
      _webErrors = true;
      return;
    }
    final String status;
    if (line.contains('is being served at')) {
      // (Re)launched and serving. Open pages hold a dead frame after a
      // relaunch: have them reload it. A save during startup is re-run.
      status = 'recompiled';
      _webWatchdog?.cancel();
      _webBusy = false;
      final changed = _webChangedAt;
      if (changed != null && changed.isAfter(_webLaunchedAt)) {
        _signalWeb(webPidFile);
      }
      _notifyCatalog(status);
      return;
    } else if (line.contains('Restarted application')) {
      status = 'restarted';
    } else if (line.contains('Recompile complete')) {
      status = 'recompiled';
    } else if (line.contains('Performing hot re') && _webErrors) {
      status = 'failed';
    } else {
      return;
    }
    _webWatchdog?.cancel();
    _webBusy = false;
    final changed = _webChangedAt;
    if (changed != null && changed.isAfter(_webSignaledAt)) {
      _signalWeb(webPidFile);
    }
    _notifyCatalog(status);
  }

  /// Tells the catalog server the web bundle changed so open detail pages
  /// refresh their live frame.
  Future<void> _notifyCatalog(String status) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    try {
      final request = await client.postUrl(
        Uri.parse('http://localhost:$_port/web-reloaded?status=$status'),
      );
      final response = await request.close().timeout(
        const Duration(seconds: 5),
      );
      await response.drain<void>();
    } catch (_) {
      // Catalog not up (yet): its pages load the current bundle anyway.
    } finally {
      client.close();
    }
  }

  /// The app package itself plus every path dependency: exactly the code the
  /// resident compiler can hot reload. Hosted and SDK packages have absolute
  /// file:// rootUris; local packages are written as relative URIs.
  List<String> _localPackageRoots() {
    final config = File('.dart_tool/package_config.json');
    if (!config.existsSync()) return [Directory.current.path];
    final roots = <String>{};
    final json = jsonDecode(config.readAsStringSync()) as Map<String, dynamic>;
    for (final package
        in (json['packages'] as List).cast<Map<String, dynamic>>()) {
      final rootUri = package['rootUri'] as String;
      if (rootUri.startsWith('file://')) continue;
      try {
        roots.add(
          Directory.fromUri(
            config.parent.uri.resolveUri(Uri.parse(rootUri)),
          ).resolveSymbolicLinksSync(),
        );
      } on FileSystemException {
        // Stale entry; skip.
      }
    }
    return roots.isEmpty ? [Directory.current.path] : roots.toList();
  }
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
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(_storyTemplate);
    stdout.writeln('Created ${file.path}. Start the catalog with:');
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
    final file = File('story/main.dart');
    if (file.existsSync()) {
      stdout.writeln('${file.path} already exists; keeping it.');
    } else {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(_storyTemplate);
      stdout.writeln('Created ${file.path}.');
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
// Works from two origins: the catalog's /live/ static build and the
// hot-reloading dev server's root. Resolve bases from this script's own URL.
const BASE = new URL('.', document.currentScript.src).pathname;
_flutter.loader.load({
  config: {
    entrypointBaseUrl: BASE,
    assetBase: BASE,
    canvasKitBaseUrl: BASE + 'canvaskit/',
  },
  onEntrypointLoaded: async (engineInitializer) => {
    const engine = await engineInitializer.initializeEngine({
      multiViewEnabled: true,
    });
    const app = await engine.runApp();
    window.flutterStaticApp = app;
    let host = document.getElementById('host');
    const storyId = window._flutterStaticStory ||
        new URLSearchParams(location.search).get('storyId');
    if (!host) {
      // Standalone (dev server) page: fill it with a single view.
      document.body.style.cssText = 'margin:0;height:100vh;background:#131518';
      host = document.createElement('div');
      host.id = 'host';
      host.style.cssText = 'position:absolute;inset:0';
      document.body.appendChild(host);
    }
    if (storyId) {
      app.addView({hostElement: host, initialData: {storyId: storyId}});
    }
  },
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
      ..addOption('url', defaultsTo: _defaultUrl);
  }

  @override
  String get name => 'list';
  @override
  String get description => 'List story ids from the running catalog.';

  @override
  Future<int> run() async {
    final url = argResults!['url'] as String;
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
      ..addOption('url', defaultsTo: _defaultUrl);
  }

  @override
  String get name => 'render';
  @override
  String get description => 'Render one story to a PNG file.';
  @override
  String get invocation => 'flutter_static render <story-id> [-o out.png]';

  @override
  Future<int> run() async {
    final rest = argResults!.rest;
    if (rest.isEmpty) usageException('A story id is required.');
    final id = rest.first;
    final url = argResults!['url'] as String;
    final bytes = await _fetch(
      '$url/story/$id.png',
      url,
      notFound: 'Story "$id" not found. See: flutter_static list',
    );
    if (bytes == null) return 1;
    final out =
        (argResults!['out'] as String?) ?? '${id.replaceAll('/', '_')}.png';
    File(out).writeAsBytesSync(bytes);
    stdout.writeln(out);
    return 0;
  }
}

/// GET [url]; on failure print a hint mentioning [serverUrl] and return null.
Future<List<int>?> _fetch(
  String url,
  String serverUrl, {
  String? notFound,
}) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri.parse(url));
    final response = await request.close();
    if (response.statusCode == HttpStatus.notFound) {
      stderr.writeln(notFound ?? '404: $url');
      return null;
    }
    if (response.statusCode != HttpStatus.ok) {
      stderr.writeln('HTTP ${response.statusCode}: $url');
      return null;
    }
    return (await response.toList()).expand((chunk) => chunk).toList();
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

const _storyTemplate = '''
import 'package:flutter/material.dart';
import 'package:flutter_static/flutter_static.dart';

// Run with: flutter_static run
void main() => runFlutterStatic(const MyStories());

// Stories must live in a class method (not a stored closure) so hot reload
// picks up edits: main() never re-runs, but method dispatch always reaches
// the newest code.
class MyStories extends Stories {
  const MyStories();

  @override
  List<Story> build() => [
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
}
''';
