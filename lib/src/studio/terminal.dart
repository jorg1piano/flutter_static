/// A terminal inside Studio, running the user's own shell in the project.
/// Whatever agent they use (Claude Code, codex, a TUI of their own) runs
/// here with its own prompts and permissions; Studio only types into it:
/// the story a click selected, and a launch line for Claude Code with
/// Studio's context as the system prompt.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_pty/flutter_pty.dart';
import 'package:xterm/xterm.dart';

class StudioTerminal extends ChangeNotifier {
  StudioTerminal({required this.project, required this.context});

  final String project;

  /// Studio's context for an agent's system prompt (no selection: the
  /// selection is typed in as it changes).
  final String Function() context;

  final terminal = Terminal(maxLines: 10000);
  Pty? _pty;
  int? exitCode;

  bool get running => _pty != null;

  /// The user's login shell in the project, so PATH is the terminal's.
  void start() {
    _pty?.kill();
    exitCode = null;
    final shell = Platform.environment['SHELL'] ?? '/bin/zsh';
    final pty = Pty.start(
      shell,
      arguments: const ['-l'],
      workingDirectory: project,
      environment: {
        ...Platform.environment,
        'TERM': 'xterm-256color',
        'COLORTERM': 'truecolor',
        'FLUTTER_STATIC_STUDIO': '1',
      },
      columns: terminal.viewWidth,
      rows: terminal.viewHeight,
    );
    _pty = pty;
    pty.output
        .cast<List<int>>()
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(terminal.write);
    pty.exitCode.then((code) {
      if (_pty != pty) return;
      _pty = null;
      exitCode = code;
      terminal.write('\r\n[shell exited with $code]\r\n');
      notifyListeners();
    });
    terminal.onOutput = (data) => pty.write(utf8.encode(data));
    terminal.onResize = (w, h, pw, ph) => pty.resize(h, w);
    notifyListeners();
  }

  /// Types [text] at the cursor, as if pasted.
  void write(String text) {
    final pty = _pty;
    if (pty == null) return;
    pty.write(utf8.encode(text));
  }

  /// Types the story id in backticks, the way the system prompt says
  /// stories are referred to, and leaves the cursor after it.
  void mention(String storyId) => write('`$storyId` ');

  /// Types and runs the Claude Code launch line with Studio's context.
  void launchClaude() {
    final prompt = context().replaceAll("'", r"'\''");
    write("claude --append-system-prompt '$prompt'\n");
  }

  @override
  void dispose() {
    _pty?.kill();
    super.dispose();
  }
}
