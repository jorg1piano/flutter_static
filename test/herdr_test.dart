import 'package:flutter_static/src/studio/herdr.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('HerdrPane reads the pane list shape', () {
    final pane = HerdrPane.fromJson({
      'agent': 'claude',
      'agent_status': 'idle',
      'cwd': '/Users/me/app',
      'foreground_cwd': '/Users/me/app/packages/ui',
      'pane_id': 'w5Q:pC',
      'terminal_title': '✳ Broken tests',
      'terminal_title_stripped': 'Broken tests',
      'workspace_id': 'w5Q',
    })!;
    expect(pane.id, 'w5Q:pC');
    expect(pane.cwd, '/Users/me/app/packages/ui');
    expect(pane.name, 'Broken tests');
    expect(pane.hasAgent, isTrue);
    expect(pane.agentStatus, 'idle');
    expect(pane.inProject('/Users/me/app'), isTrue);
    expect(pane.inProject('/Users/me/application'), isFalse);
  });

  test('a shell pane is named by its directory', () {
    final pane = HerdrPane.fromJson({
      'agent_status': 'unknown',
      'cwd': '/Users/me/app',
      'foreground_cwd': '/Users/me/app',
      'pane_id': 'w5Q:pB',
    })!;
    expect(pane.hasAgent, isFalse);
    expect(pane.name, 'app');
    expect(HerdrPane.fromJson({'cwd': '/x'}), isNull);
    expect(HerdrPane.fromJson('nope'), isNull);
  });
}
