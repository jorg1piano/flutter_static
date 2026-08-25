import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'agent.dart';
import 'controller.dart';
import 'theme.dart';

/// The chat: prompts go to the agent with what Studio knows (the
/// selected story, the port) in the system prompt; its text, tool calls
/// and errors stream back. The canvas shows the result on its own.
class AgentPanel extends StatefulWidget {
  const AgentPanel({super.key, required this.agent, required this.controller});

  final AgentSession agent;
  final StudioController controller;

  @override
  State<AgentPanel> createState() => _AgentPanelState();
}

class _AgentPanelState extends State<AgentPanel> {
  final _input = TextEditingController();
  final _focus = FocusNode();
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    widget.agent.addListener(_scrollToEnd);
  }

  @override
  void dispose() {
    widget.agent.removeListener(_scrollToEnd);
    _input.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  void _send() {
    final text = _input.text;
    if (text.trim().isEmpty || widget.agent.busy) return;
    _input.clear();
    widget.agent.send(text);
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([widget.agent, widget.controller]),
    builder: (context, _) {
      final agent = widget.agent;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Header(agent: agent),
          Expanded(
            child: agent.messages.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      'Ask for a change. The agent edits the project, the '
                      'canvas follows. Select a story first to point it '
                      'there.',
                      style: StudioText.muted,
                    ),
                  )
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    itemCount: agent.messages.length,
                    itemBuilder: (context, i) =>
                        _MessageView(agent.messages[i]),
                  ),
          ),
          _Composer(
            controller: _input,
            focus: _focus,
            busy: agent.busy,
            storyId: widget.controller.selectedStoryId,
            onSend: _send,
            onCancel: agent.cancel,
          ),
        ],
      );
    },
  );
}

class _Header extends StatelessWidget {
  const _Header({required this.agent});

  final AgentSession agent;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(12, 8, 6, 6),
    decoration: const BoxDecoration(
      border: Border(bottom: BorderSide(color: StudioColors.border)),
    ),
    child: Row(
      children: [
        Text('Agent', style: StudioText.title),
        const SizedBox(width: 8),
        Text(agent.command.name, style: StudioText.muted),
        if (agent.busy) ...[
          const SizedBox(width: 8),
          const SizedBox(
            width: 10,
            height: 10,
            child: CircularProgressIndicator(
              strokeWidth: 1.5,
              color: StudioColors.accent,
            ),
          ),
        ],
        const Spacer(),
        IconButton(
          tooltip: 'New conversation',
          onPressed: agent.messages.isEmpty ? null : agent.reset,
          icon: const Icon(Icons.add_comment_outlined, size: 15),
          color: StudioColors.muted,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints.tightFor(width: 26, height: 24),
        ),
      ],
    ),
  );
}

class _MessageView extends StatelessWidget {
  const _MessageView(this.message);

  final AgentMessage message;

  @override
  Widget build(BuildContext context) {
    switch (message.role) {
      case AgentRole.user:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Align(
            alignment: Alignment.centerRight,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: BoxDecoration(
                color: StudioColors.accentSoft,
                borderRadius: BorderRadius.circular(10),
              ),
              child: SelectableText(message.text, style: StudioText.body),
            ),
          ),
        );
      case AgentRole.assistant:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: SelectableText(message.text, style: StudioText.body),
        );
      case AgentRole.tool:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(
                Icons.chevron_right,
                size: 12,
                color: StudioColors.faint,
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  '${message.text} ${message.detail ?? ''}'.trim(),
                  style: StudioText.monoMuted,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        );
      case AgentRole.status:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text(message.text, style: StudioText.muted),
        );
      case AgentRole.error:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: SelectableText(
            message.text,
            style: StudioText.mono.copyWith(color: StudioColors.bad),
          ),
        );
    }
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.focus,
    required this.busy,
    required this.storyId,
    required this.onSend,
    required this.onCancel,
  });

  final TextEditingController controller;
  final FocusNode focus;
  final bool busy;
  final String? storyId;
  final VoidCallback onSend;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
    decoration: const BoxDecoration(
      border: Border(top: BorderSide(color: StudioColors.border)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (storyId != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              children: [
                const Icon(
                  Icons.my_location,
                  size: 11,
                  color: StudioColors.faint,
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    storyId!,
                    style: StudioText.monoMuted,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        // Enter sends; Shift+Enter is a newline.
        CallbackShortcuts(
          bindings: {const SingleActivator(LogicalKeyboardKey.enter): onSend},
          child: TextField(
            controller: controller,
            focusNode: focus,
            minLines: 1,
            maxLines: 5,
            style: StudioText.body,
            cursorColor: StudioColors.accent,
            decoration: InputDecoration(
              isDense: true,
              hintText: busy ? 'Working…' : 'Make the primary button rounder',
              hintStyle: StudioText.muted,
              contentPadding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
              filled: true,
              fillColor: StudioColors.sidebar,
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: StudioColors.border),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: StudioColors.accent),
              ),
              suffixIcon: busy
                  ? IconButton(
                      tooltip: 'Stop',
                      onPressed: onCancel,
                      icon: const Icon(Icons.stop_circle_outlined, size: 18),
                      color: StudioColors.bad,
                    )
                  : IconButton(
                      tooltip: 'Send (Enter)',
                      onPressed: onSend,
                      icon: const Icon(Icons.arrow_upward, size: 18),
                      color: StudioColors.accent,
                    ),
            ),
          ),
        ),
      ],
    ),
  );
}
