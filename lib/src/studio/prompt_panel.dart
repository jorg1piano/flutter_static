import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'controller.dart';
import 'terminal.dart';
import 'theme.dart';
import 'widgets.dart';

/// Codex-style prompt composer kept next to the canvas. It mirrors the
/// current Studio context, so selecting a story/widget or drawing a box makes
/// the prompt immediately useful to paste into an agent.
class PromptPanel extends StatefulWidget {
  const PromptPanel({
    super.key,
    required this.controller,
    required this.terminal,
    required this.onCollapse,
  });

  final StudioController controller;
  final StudioTerminal terminal;
  final VoidCallback onCollapse;

  @override
  State<PromptPanel> createState() => _PromptPanelState();
}

class _PromptPanelState extends State<PromptPanel> {
  final _request = TextEditingController();
  bool _copied = false;

  @override
  void initState() {
    super.initState();
    _request.text = widget.controller.promptText;
    widget.controller.addListener(_syncFromController);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_syncFromController);
    _request.dispose();
    super.dispose();
  }

  void _syncFromController() {
    final text = widget.controller.promptText;
    if (text == _request.text) return;
    _request.value = _request.value.copyWith(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
      composing: TextRange.empty,
    );
    if (mounted) setState(() {});
  }

  String _prompt() {
    final request = _request.text.trim();
    return [
      widget.controller.agentContext(),
      if (widget.controller.looseBoxes.isNotEmpty)
        'The highlighted canvas rectangle is ${_rect(widget.controller.looseBoxes.last)}.',
      if (request.isNotEmpty) 'User request: $request',
    ].join('\n');
  }

  static String _rect(Rect r) =>
      'x=${r.left.toStringAsFixed(1)}, y=${r.top.toStringAsFixed(1)}, '
      'w=${r.width.abs().toStringAsFixed(1)}, h=${r.height.abs().toStringAsFixed(1)}';

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _prompt()));
    if (!mounted) return;
    setState(() => _copied = true);
    Future<void>.delayed(const Duration(milliseconds: 1200), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  void _sendToTerminal() {
    final prompt = _prompt();
    final file = File(
      '${widget.controller.project}/.dart_tool/flutter_static_codex_prompt.txt',
    );
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(prompt);
    final image = _latestScreenshot(prompt);
    widget.terminal.write(
      '\x15codex exec --sandbox workspace-write --approve-for-me '
      '${image == null ? '' : '-i ${_sh(image)} '}'
      '- < ${_sh(file.path)}\n',
    );
  }

  static String _sh(String text) => "'${text.replaceAll("'", r"'\''")}'";

  static String? _latestScreenshot(String prompt) {
    final matches = RegExp(
      r'Screenshot with the rectangle: (\S+)',
    ).allMatches(prompt).toList();
    return matches.isEmpty ? null : matches.last.group(1);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final c = widget.controller;
      final story = c.selectedStoryId;
      final picked = c.pickedWidget;
      final box = c.looseBoxes.isEmpty ? null : c.looseBoxes.last;
      final contextLines = [
        if (c.selectedPage case final page?) '${page.title}  ${page.id}',
        if (story != null) 'story: $story',
        if (picked != null)
          'selected: ${picked.type}${picked.text == null ? '' : ' “${picked.text}”'}',
        if (box != null) 'highlight: ${_rect(box)}',
        if (story == null && picked == null && box == null)
          'Click a render/widget or Command-drag a rectangle on the canvas.',
      ];
      return Container(
        color: StudioColors.panel,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: StudioColors.border)),
              ),
              child: Row(
                children: [
                  Text('Codex', style: StudioText.title),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text('prompt context', style: StudioText.muted),
                  ),
                  IconButton(
                    tooltip: 'Collapse Codex panel',
                    visualDensity: VisualDensity.compact,
                    onPressed: widget.onCollapse,
                    icon: const Icon(
                      Icons.keyboard_double_arrow_left,
                      size: 16,
                    ),
                    color: StudioColors.muted,
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: StudioColors.raised,
                  border: Border.all(color: StudioColors.border),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: SelectableText(
                    contextLines.join('\n'),
                    style: StudioText.monoMuted,
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: TextField(
                controller: _request,
                minLines: 5,
                maxLines: 8,
                style: StudioText.body,
                decoration: InputDecoration(
                  hintText: 'What should Codex change in the highlighted area?',
                  hintStyle: StudioText.muted,
                  filled: true,
                  fillColor: const Color(0xFF141518),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: StudioColors.border),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: StudioColors.border),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: StudioColors.accent),
                  ),
                ),
                onChanged: (value) {
                  widget.controller.setPromptText(value);
                  setState(() {});
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Row(
                children: [
                  StudioButton(label: 'Copy prompt', onTap: _copy),
                  const SizedBox(width: 8),
                  StudioButton(
                    label: 'Send',
                    primary: true,
                    onTap: widget.terminal.running ? _sendToTerminal : null,
                  ),
                  const SizedBox(width: 8),
                  if (_copied) Text('Copied', style: StudioText.monoMuted),
                ],
              ),
            ),
            const Divider(height: 1, color: StudioColors.border),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(12),
                child: SelectableText(_prompt(), style: StudioText.monoMuted),
              ),
            ),
          ],
        ),
      );
    },
  );
}
