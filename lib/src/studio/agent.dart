/// The agent behind Studio's chat: a coding agent CLI run as a child
/// process in the project, its output streamed into the panel. Studio
/// does not implement an agent; it drives one. The default is Claude
/// Code headless (`claude -p --output-format stream-json`), which edits
/// files, runs `flutter_static render` to check its work, and keeps a
/// session across turns. `FLUTTER_STATIC_AGENT` swaps in any other
/// command (`codex exec {prompt}`), shown as plain text.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

enum AgentRole { user, assistant, tool, status, error }

class AgentMessage {
  AgentMessage(this.role, this.text, {this.detail});

  final AgentRole role;
  String text;

  /// A tool call's argument of note: the file, the command.
  final String? detail;
}

/// How to start the agent for one turn.
class AgentCommand {
  const AgentCommand({
    required this.name,
    required this.executable,
    required this.arguments,
    required this.streamJson,
  });

  final String name;
  final String executable;

  /// Arguments with `{prompt}`, `{system}` and `{resume}` placeholders;
  /// an argument that is exactly `{resume}` (or `--resume`) is dropped
  /// when there is no session to resume.
  final List<String> arguments;

  /// Whether stdout is Claude Code's stream-json (one event per line).
  final bool streamJson;

  /// Claude Code, allowed to edit the project and to render, but not to
  /// start or stop catalogs (this process is the catalog).
  static const claudeCode = AgentCommand(
    name: 'Claude Code',
    executable: 'claude',
    streamJson: true,
    arguments: [
      '-p',
      '{prompt}',
      '--output-format',
      'stream-json',
      '--verbose',
      '--permission-mode',
      'acceptEdits',
      '--allowedTools',
      'Edit,Write,Read,Glob,Grep,MultiEdit,'
          'Bash(dart run flutter_static render *),'
          'Bash(dart run flutter_static list *),'
          'Bash(dart run flutter_static tokens *),'
          'Bash(dart run flutter_static add *),'
          'Bash(flutter_static render *),'
          'Bash(flutter_static list *),'
          'Bash(flutter_static tokens *),'
          'Bash(flutter analyze *),'
          'Bash(dart format *),'
          'Bash(dart analyze *)',
      '--append-system-prompt',
      '{system}',
      '--resume',
      '{resume}',
    ],
  );

  /// `FLUTTER_STATIC_AGENT="codex exec {prompt}"` in the environment
  /// Studio was launched from, split on spaces; null when unset.
  static AgentCommand? fromEnvironment() {
    final raw = Platform.environment['FLUTTER_STATIC_AGENT'];
    if (raw == null || raw.trim().isEmpty) return null;
    final parts = raw.trim().split(RegExp(r'\s+'));
    return AgentCommand(
      name: parts.first,
      executable: parts.first,
      arguments: parts.skip(1).toList(),
      streamJson: false,
    );
  }

  List<String> build({
    required String prompt,
    required String system,
    String? resume,
  }) {
    final out = <String>[];
    for (var i = 0; i < arguments.length; i++) {
      final arg = arguments[i];
      if (arg == '--resume' || arg == '-r') {
        if (resume == null) {
          i++; // skip its {resume} value too
        } else {
          out.add(arg);
        }
        continue;
      }
      if (arg == '{resume}') {
        if (resume != null) out.add(resume);
        continue;
      }
      out.add(
        arg.replaceAll('{prompt}', prompt).replaceAll('{system}', system),
      );
    }
    return out;
  }
}

class AgentSession extends ChangeNotifier {
  AgentSession({
    required this.project,
    required this.context,
    AgentCommand? command,
  }) : command =
           command ?? AgentCommand.fromEnvironment() ?? AgentCommand.claudeCode;

  final String project;

  /// What Studio knows right now (the selected story, the port), for the
  /// system prompt of the next turn.
  final String Function() context;
  final AgentCommand command;

  final messages = <AgentMessage>[];
  bool busy = false;
  String? sessionId;
  Process? _process;

  /// Starts a new conversation on the next prompt.
  void reset() {
    cancel();
    sessionId = null;
    messages.clear();
    notifyListeners();
  }

  void cancel() {
    _process?.kill();
    _process = null;
    if (busy) {
      busy = false;
      messages.add(AgentMessage(AgentRole.status, 'stopped'));
      notifyListeners();
    }
  }

  Future<void> send(String prompt) async {
    final text = prompt.trim();
    if (text.isEmpty || busy) return;
    busy = true;
    messages.add(AgentMessage(AgentRole.user, text));
    notifyListeners();
    final args = command.build(
      prompt: text,
      system: context(),
      resume: sessionId,
    );
    try {
      final process = await Process.start(
        command.executable,
        args,
        workingDirectory: project,
      );
      _process = process;
      // Nothing comes over stdin; a CLI that waits for it (Claude Code
      // gives piped stdin 3 s) should start at once.
      unawaited(process.stdin.close());
      final stderr = <String>[];
      process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(stderr.add);
      final lines = process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter());
      await for (final line in lines) {
        if (command.streamJson) {
          _onEvent(line);
        } else {
          _appendText(line);
        }
      }
      final code = await process.exitCode;
      if (code != 0 && _process == process) {
        _add(
          AgentRole.error,
          '${command.name} exited with $code'
          '${stderr.isEmpty ? '' : '\n${stderr.join('\n')}'}',
        );
      }
    } on ProcessException catch (e) {
      _add(
        AgentRole.error,
        'Could not start ${command.executable}: ${e.message}. Is it on the '
        'PATH of the terminal Studio was launched from?',
      );
    } finally {
      _process = null;
      busy = false;
      notifyListeners();
    }
  }

  void _add(AgentRole role, String text, {String? detail}) {
    messages.add(AgentMessage(role, text, detail: detail));
    notifyListeners();
  }

  /// Plain-text agents: one growing assistant message per turn.
  void _appendText(String line) {
    final last = messages.isEmpty ? null : messages.last;
    if (last != null && last.role == AgentRole.assistant) {
      last.text = '${last.text}\n$line';
      notifyListeners();
    } else {
      _add(AgentRole.assistant, line);
    }
  }

  void _onEvent(String line) {
    if (line.trim().isEmpty) return;
    final Object? json;
    try {
      json = jsonDecode(line);
    } on FormatException {
      _appendText(line);
      return;
    }
    if (json is! Map) return;
    final type = json['type'];
    if (json['session_id'] is String) {
      sessionId = json['session_id'] as String;
    }
    switch (type) {
      case 'assistant':
        final content = (json['message'] as Map?)?['content'];
        if (content is! List) return;
        for (final block in content.cast<Map>()) {
          switch (block['type']) {
            case 'text':
              final text = (block['text'] as String? ?? '').trim();
              if (text.isNotEmpty) _add(AgentRole.assistant, text);
            case 'tool_use':
              _add(
                AgentRole.tool,
                block['name'] as String? ?? 'tool',
                detail: _toolDetail(block),
              );
          }
        }
      case 'result':
        final error = json['is_error'] == true;
        final result = json['result'];
        if (error) {
          _add(AgentRole.error, result is String ? result : 'the turn failed');
        } else if (json['subtype'] != 'success') {
          _add(AgentRole.status, '${json['subtype']}');
        }
      case 'user':
        // Tool results; an error in one is worth a line.
        final content = (json['message'] as Map?)?['content'];
        if (content is List) {
          for (final block in content.whereType<Map>()) {
            if (block['type'] == 'tool_result' && block['is_error'] == true) {
              final c = block['content'];
              final text = c is String
                  ? c
                  : c is List
                  ? c.whereType<Map>().map((m) => m['text'] ?? '').join('\n')
                  : '$c';
              _add(AgentRole.error, text.trim());
            }
          }
        }
    }
  }

  static String _toolDetail(Map block) {
    final input = block['input'];
    if (input is! Map) return '';
    final path = input['file_path'] ?? input['path'] ?? input['pattern'];
    if (path is String) {
      // Relative to the first packages/, story/ or lib/ segment.
      return path.replaceFirstMapped(
        RegExp(r'^.*?/(packages/|story/|lib/)'),
        (m) => m.group(1)!,
      );
    }
    final cmd = input['command'];
    if (cmd is String) return cmd;
    return '';
  }

  @override
  void dispose() {
    _process?.kill();
    super.dispose();
  }
}
