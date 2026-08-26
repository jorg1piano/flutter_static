import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

import 'terminal.dart';
import 'theme.dart';

/// The terminal under the inspector, with a launch button for Claude
/// Code. Click into it to type; the shell is the user's own.
class TerminalPanel extends StatefulWidget {
  const TerminalPanel({super.key, required this.terminal});

  final StudioTerminal terminal;

  @override
  State<TerminalPanel> createState() => _TerminalPanelState();
}

class _TerminalPanelState extends State<TerminalPanel> {
  @override
  void initState() {
    super.initState();
    if (!widget.terminal.running) widget.terminal.start();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.terminal,
    builder: (context, _) {
      final t = widget.terminal;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: StudioColors.border)),
            ),
            child: Row(
              children: [
                Text('Terminal', style: StudioText.title),
                const SizedBox(width: 8),
                Text(
                  t.running ? 'shell in the project' : 'exited (${t.exitCode})',
                  style: StudioText.muted,
                ),
                const Spacer(),
                _Action(
                  icon: Icons.auto_awesome,
                  tooltip: 'Run Claude Code here, with Studio\'s context',
                  onTap: t.running ? t.launchClaude : null,
                ),
                _Action(
                  icon: Icons.restart_alt,
                  tooltip: 'New shell',
                  onTap: t.start,
                ),
              ],
            ),
          ),
          Expanded(
            child: Container(
              color: const Color(0xFF141518),
              padding: const EdgeInsets.fromLTRB(8, 6, 4, 4),
              child: TerminalView(
                t.terminal,
                theme: _theme,
                textStyle: const TerminalStyle(
                  fontSize: 12,
                  fontFamily: 'Menlo',
                ),
                backgroundOpacity: 0,
                autofocus: false,
                hardwareKeyboardOnly: true,
              ),
            ),
          ),
        ],
      );
    },
  );

  static const _theme = TerminalTheme(
    cursor: StudioColors.accent,
    selection: Color(0x557C9CFF),
    foreground: StudioColors.text,
    background: Color(0xFF141518),
    black: Color(0xFF1B1C1F),
    red: Color(0xFFF87171),
    green: Color(0xFF4ADE80),
    yellow: Color(0xFFFBBF24),
    blue: Color(0xFF7C9CFF),
    magenta: Color(0xFFE879F9),
    cyan: Color(0xFF67E8F9),
    white: Color(0xFFE8E8EA),
    brightBlack: Color(0xFF6C6F76),
    brightRed: Color(0xFFFCA5A5),
    brightGreen: Color(0xFF86EFAC),
    brightYellow: Color(0xFFFDE68A),
    brightBlue: Color(0xFFA5B4FC),
    brightMagenta: Color(0xFFF0ABFC),
    brightCyan: Color(0xFFA5F3FC),
    brightWhite: Color(0xFFFFFFFF),
    searchHitBackground: Color(0xFFFBBF24),
    searchHitBackgroundCurrent: Color(0xFFF59E0B),
    searchHitForeground: Color(0xFF000000),
  );
}

class _Action extends StatelessWidget {
  const _Action({required this.icon, required this.tooltip, this.onTap});

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: tooltip,
    onPressed: onTap,
    icon: Icon(icon, size: 15),
    color: StudioColors.muted,
    padding: EdgeInsets.zero,
    constraints: const BoxConstraints.tightFor(width: 26, height: 24),
  );
}
