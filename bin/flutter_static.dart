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
      ..addOption('device', abbr: 'd', defaultsTo: 'macos');
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
    final pidFile = File('.dart_tool/flutter_static.pid');
    pidFile.parent.createSync(recursive: true);
    final child = await Process.start('flutter', [
      'run',
      '-d',
      argResults!['device'] as String,
      '-t',
      target,
      '--pid-file',
      pidFile.path,
    ], mode: ProcessStartMode.inheritStdio);
    _watchSources(pidFile);
    return child.exitCode;
  }

  void _watchSources(File pidFile) {
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
            final raw = pidFile.existsSync()
                ? pidFile.readAsStringSync().trim()
                : '';
            final pid = int.tryParse(raw);
            if (pid != null) Process.killPid(pid, ProcessSignal.sigusr1);
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

    for (final root in roots) {
      watchRoot(root);
    }
    stdout.writeln('flutter_static: watching ${roots.join(', ')}');
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
