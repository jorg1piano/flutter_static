/// Studio's door to Herdr, the terminal workspace manager: which panes
/// are open and sending text into one. Everything goes through the
/// `herdr` CLI, which talks to the running server over its socket, so
/// Studio needs no protocol of its own and follows CLI upgrades.
library;

import 'dart:convert';
import 'dart:io';

/// One Herdr pane, from `herdr pane list`.
class HerdrPane {
  const HerdrPane({
    required this.id,
    required this.cwd,
    this.title,
    this.label,
    this.agent,
    this.agentStatus,
  });

  /// `w5Q:pC`.
  final String id;

  /// The pane's working directory.
  final String cwd;

  /// The terminal title without the agent's status glyph, when set.
  final String? title;

  /// A user-given pane label, when set.
  final String? label;

  /// `claude`, `pi`, ... when Herdr has detected an agent in the pane.
  final String? agent;

  /// `idle`, `working`, `blocked`, ... for an agent pane.
  final String? agentStatus;

  bool get hasAgent => agent != null;

  /// Whether the pane's shell is in [project] or under it.
  bool inProject(String project) =>
      cwd == project || cwd.startsWith('$project/');

  /// What to call the pane in a list: its label or title, else the
  /// directory it is in.
  String get name =>
      label ??
      title ??
      (cwd.split('/').where((s) => s.isNotEmpty).lastOrNull ?? id);

  static HerdrPane? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['pane_id'];
    if (id is! String) return null;
    return HerdrPane(
      id: id,
      cwd: json['foreground_cwd'] as String? ?? json['cwd'] as String? ?? '',
      title: json['terminal_title_stripped'] as String?,
      label: json['label'] as String?,
      agent: json['agent'] as String?,
      agentStatus: json['agent_status'] as String?,
    );
  }
}

/// Raised when the CLI is missing, the server is down or a command
/// fails; [message] is what to show the user.
class HerdrException implements Exception {
  const HerdrException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Runs `herdr` commands. The binary is `FLUTTER_STATIC_HERDR` when set,
/// else `herdr` on the PATH, else `~/.local/bin/herdr`, where the
/// installer puts it and where a GUI process's PATH may not reach.
class Herdr {
  Herdr({Map<String, String>? environment})
    : _env = environment ?? Platform.environment;

  final Map<String, String> _env;

  List<String> get _candidates {
    final override = _env['FLUTTER_STATIC_HERDR'];
    final home = _env['HOME'];
    return [
      if (override != null && override.trim().isNotEmpty) override.trim(),
      'herdr',
      if (home != null) '$home/.local/bin/herdr',
    ];
  }

  String? _binary;

  Future<ProcessResult> _run(List<String> args) async {
    final tried = <String>[];
    for (final binary in _binary != null ? [_binary!] : _candidates) {
      try {
        final result = await Process.run(binary, args);
        _binary = binary;
        return result;
      } on ProcessException {
        tried.add(binary);
      }
    }
    throw HerdrException(
      'herdr not found (tried ${tried.join(', ')}); '
      'set FLUTTER_STATIC_HERDR to the binary',
    );
  }

  /// Runs a command and returns its stdout, or throws with stderr.
  Future<String> _ok(List<String> args) async {
    final result = await _run(args);
    if (result.exitCode != 0) {
      final err = '${result.stderr}'.trim();
      final out = '${result.stdout}'.trim();
      throw HerdrException(
        'herdr ${args.take(2).join(' ')}: '
        '${err.isNotEmpty
            ? err
            : out.isNotEmpty
            ? out
            : 'exit ${result.exitCode}'}',
      );
    }
    return '${result.stdout}';
  }

  /// Every open pane, in the server's order.
  Future<List<HerdrPane>> panes() async {
    final out = await _ok(['pane', 'list']);
    Object? json;
    try {
      json = jsonDecode(out);
    } on FormatException {
      throw HerdrException('herdr pane list: unexpected output');
    }
    final result = json is Map ? json['result'] : null;
    final list = result is Map ? result['panes'] : null;
    if (list is! List) {
      final error = json is Map ? json['error'] : null;
      throw HerdrException(
        'herdr pane list: ${error is Map ? error['message'] ?? error : 'no panes in reply'}',
      );
    }
    return [for (final p in list) ?HerdrPane.fromJson(p)];
  }

  /// Types [text] at the pane's cursor, without Enter.
  Future<void> sendText(String paneId, String text) =>
      _ok(['pane', 'send-text', paneId, text]);

  /// Submits [text] as a prompt to the agent in the pane: text plus
  /// Enter, honouring the pane's bracketed-paste mode.
  Future<void> prompt(String paneId, String text) =>
      _ok(['agent', 'prompt', paneId, text]);
}
