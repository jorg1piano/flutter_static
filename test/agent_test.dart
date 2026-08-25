import 'dart:io';

import 'package:flutter_static/src/studio/agent.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;
  late File script;
  late File argv;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('agent_test');
    argv = File('${dir.path}/argv.txt');
    script = File('${dir.path}/fake_agent.sh')
      ..writeAsStringSync('''
#!/bin/sh
printf '%s\\n' "\$@" > "${argv.path}"
cat <<'JSON'
{"type":"system","subtype":"init","session_id":"sess-1"}
{"type":"assistant","message":{"content":[{"type":"text","text":"On it."},{"type":"tool_use","name":"Edit","input":{"file_path":"/x/packages/app_ui/lib/src/button.dart"}}]},"session_id":"sess-1"}
{"type":"user","message":{"content":[{"type":"tool_result","is_error":true,"content":"boom"}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"Done."}]},"session_id":"sess-1"}
{"type":"result","subtype":"success","is_error":false,"result":"Done.","session_id":"sess-1"}
JSON
''');
    Process.runSync('chmod', ['+x', script.path]);
  });

  tearDown(() => dir.deleteSync(recursive: true));

  AgentCommand command() => AgentCommand(
    name: 'fake',
    executable: script.path,
    streamJson: true,
    arguments: const [
      '-p',
      '{prompt}',
      '--system',
      '{system}',
      '--resume',
      '{resume}',
    ],
  );

  test('streams text, tool calls and errors; resumes the session', () async {
    final agent = AgentSession(
      project: dir.path,
      context: () => 'CTX',
      command: command(),
    );
    await agent.send('make it blue');
    expect(agent.busy, isFalse);
    expect(agent.sessionId, 'sess-1');
    expect(agent.messages.map((m) => m.role), [
      AgentRole.user,
      AgentRole.assistant,
      AgentRole.tool,
      AgentRole.error,
      AgentRole.assistant,
    ]);
    expect(agent.messages[2].detail, 'packages/app_ui/lib/src/button.dart');
    expect(agent.messages[3].text, 'boom');
    // The first turn had no session to resume: no --resume at all.
    expect(argv.readAsLinesSync(), ['-p', 'make it blue', '--system', 'CTX']);
    await agent.send('and rounder');
    expect(argv.readAsLinesSync(), [
      '-p',
      'and rounder',
      '--system',
      'CTX',
      '--resume',
      'sess-1',
    ]);
    agent.reset();
    expect(agent.sessionId, isNull);
    expect(agent.messages, isEmpty);
  });

  test('a missing executable is reported, not thrown', () async {
    final agent = AgentSession(
      project: dir.path,
      context: () => '',
      command: const AgentCommand(
        name: 'nope',
        executable: '/nonexistent/agent',
        arguments: ['{prompt}'],
        streamJson: false,
      ),
    );
    await agent.send('hi');
    expect(agent.messages.last.role, AgentRole.error);
    expect(agent.busy, isFalse);
  });

  test('claude code command drops --resume without a session', () {
    final args = AgentCommand.claudeCode.build(prompt: 'p', system: 's');
    expect(args, isNot(contains('--resume')));
    expect(args, isNot(contains('{resume}')));
    expect(args.first, '-p');
    expect(args[1], 'p');
    final resumed = AgentCommand.claudeCode.build(
      prompt: 'p',
      system: 's',
      resume: 'id',
    );
    expect(resumed.sublist(resumed.length - 2), ['--resume', 'id']);
  });
}
