import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../phone_mockup.dart';
import '../server_io.dart';
import '../widget_pick.dart';
import 'controller.dart';
import 'herdr.dart';
import 'theme.dart';
import 'tokens_panel.dart';
import 'widgets.dart';

/// The right panel: a token group's editors when one is open, otherwise
/// the page's render options and the selected story.
class Inspector extends StatelessWidget {
  const Inspector({super.key, required this.controller});

  final StudioController controller;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final groupName = controller.selectedTokenGroup;
      if (groupName != null) {
        final group = controller.tokens?.groups
            .where((g) => g.name == groupName)
            .firstOrNull;
        if (group != null) {
          return TokensPanel(group: group, controller: controller);
        }
      }
      return _StoryInspector(controller: controller);
    },
  );
}

class _StoryInspector extends StatelessWidget {
  const _StoryInspector({required this.controller});

  final StudioController controller;

  @override
  Widget build(BuildContext context) {
    final page = controller.selectedPage;
    final story = controller.selectedStoryId;
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
      children: [
        if (page == null)
          Text('No page', style: StudioText.muted)
        else ...[
          Text(page.title, style: StudioText.title),
          Text(page.id, style: StudioText.monoMuted),
          if (page.isLine) ...[
            const SectionLabel('Device'),
            StudioChips<String?>(
              options: [
                for (final spec in PhoneSpec.all) (spec.name, spec.label),
              ],
              selected: controller.device ?? PhoneSpec.fallback.name,
              onSelect: controller.setDevice,
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Text('Status bar', style: StudioText.muted),
                const Spacer(),
                Switch(
                  value: controller.statusBar,
                  onChanged: controller.setStatusBar,
                  activeThumbColor: StudioColors.accent,
                ),
              ],
            ),
            for (final knob in page.knobs) ...[
              SectionLabel(knob.title),
              StudioChips<String>(
                options: [for (final o in knob.options) (o.id, o.title)],
                selected: controller.knobs[knob.id] ?? knob.options.first.id,
                onSelect: (o) => controller.setKnob(knob.id, o),
              ),
            ],
          ],
          const SectionLabel('Story'),
          if (story == null)
            Text('Click a render to select it.', style: StudioText.muted)
          else ...[
            SelectableText(story, style: StudioText.mono),
            const SizedBox(height: 8),
            StudioChips<bool>(
              options: const [(true, 'Live'), (false, 'Render')],
              selected: !controller.renderOnly.contains(story),
              onSelect: (_) => controller.toggleRenderOnly(story),
            ),
            if (storyShellOf(story) == StoryShell.window)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'Needs a real window; shown as its render.',
                  style: StudioText.muted,
                ),
              ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                StudioButton(
                  label: 'Re-render',
                  icon: Icons.refresh,
                  dense: true,
                  onTap: () => controller.rerender(story),
                ),
                StudioButton(
                  label: 'Copy id',
                  icon: Icons.copy,
                  dense: true,
                  onTap: () => Clipboard.setData(ClipboardData(text: story)),
                ),
                StudioButton(
                  label: 'Open in browser',
                  icon: Icons.open_in_new,
                  dense: true,
                  onTap: () =>
                      Process.run('open', ['${controller.url}/story/$story']),
                ),
              ],
            ),
            const SectionLabel('Widget'),
            if (controller.pick == null || controller.pickStoryId != story)
              Text(
                'Click a widget on the card to find it in the source.',
                style: StudioText.muted,
              )
            else
              _WidgetChain(controller: controller),
            const SectionLabel('For an agent'),
            SelectableText(
              'flutter_static render $story'
              '${controller.knobs.entries.map((e) => ' -k ${e.key}=${e.value}').join()}'
              '${_pickedLine(controller)}',
              style: StudioText.monoMuted,
            ),
            _HerdrSection(controller: controller),
          ],
        ],
      ],
    );
  }

  static String _pickedLine(StudioController controller) {
    final picked = controller.pickedWidget;
    final location = picked?.location;
    if (picked == null || location == null) return '';
    return '\n${picked.type} at ${controller.scopes.describe(location)}';
  }
}

/// The clicked widget and the project's widgets around it,
/// nearest first; a row selects that widget. Framework and package
/// widgets in between are counted, not listed.
class _WidgetChain extends StatelessWidget {
  const _WidgetChain({required this.controller});

  final StudioController controller;

  @override
  Widget build(BuildContext context) {
    final chain = controller.pick!.chain;
    final picked = controller.pickedWidget;
    final hidden = chain.where((w) => !w.isLocal).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (i, w) in chain.indexed)
          if (w.isLocal)
            _ChainRow(
              widget: w,
              selected: i == controller.pickIndex,
              scopes: controller.scopes,
              onTap: () => controller.setPickIndex(i),
            ),
        if (chain.every((w) => !w.isLocal))
          Text(
            'Nothing here is written in the project.',
            style: StudioText.muted,
          ),
        if (hidden > 0)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '$hidden more from Flutter and packages',
              style: StudioText.muted,
            ),
          ),
        if (chain.any((w) => w.isLocal))
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              '↑ parent   ↓ child   esc clear',
              style: StudioText.monoMuted,
            ),
          ),
        if (picked?.location != null) ...[
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              StudioButton(
                label: 'Copy location',
                icon: Icons.copy,
                dense: true,
                onTap: () => Clipboard.setData(
                  ClipboardData(text: '${picked!.location}'),
                ),
              ),
              StudioButton(
                label: 'Open in editor',
                icon: Icons.code,
                dense: true,
                onTap: () => controller.openInEditor(picked!),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

/// Sends the selection to a Herdr pane: a dropdown of the panes worth
/// sending to, typed at the cursor or submitted as a prompt.
class _HerdrSection extends StatefulWidget {
  const _HerdrSection({required this.controller});

  final StudioController controller;

  @override
  State<_HerdrSection> createState() => _HerdrSectionState();
}

class _HerdrSectionState extends State<_HerdrSection> {
  @override
  void initState() {
    super.initState();
    // Listing runs a process and notifies; not during this build.
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => widget.controller.ensureHerdrPanes(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final pane = c.herdrPane;
    final ready = !c.herdrBusy && pane != null && c.herdrMessage() != null;
    final status = c.herdrStatus;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionLabel(
          'Herdr',
          trailing: InkWell(
            onTap: c.herdrBusy ? null : c.refreshHerdrPanes,
            borderRadius: BorderRadius.circular(4),
            child: Padding(
              padding: const EdgeInsets.all(2),
              child: Icon(Icons.refresh, size: 14, color: StudioColors.muted),
            ),
          ),
        ),
        if (c.herdrPanes.isEmpty)
          Text(
            c.herdrBusy ? 'Listing panes...' : 'No agent panes open in Herdr.',
            style: StudioText.muted,
          )
        else
          Container(
            height: 28,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            decoration: BoxDecoration(
              color: StudioColors.sidebar,
              borderRadius: BorderRadius.circular(5),
              border: Border.all(color: StudioColors.border),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: pane?.id,
                hint: Text('Choose a pane', style: StudioText.muted),
                isDense: true,
                isExpanded: true,
                dropdownColor: StudioColors.panel,
                style: StudioText.body,
                iconSize: 14,
                items: [
                  for (final p in c.herdrPanes)
                    DropdownMenuItem(
                      value: p.id,
                      child: _PaneLabel(pane: p, project: c.project),
                    ),
                ],
                onChanged: c.herdrBusy ? null : c.setHerdrPane,
              ),
            ),
          ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            StudioButton(
              label: 'Type into pane',
              icon: Icons.keyboard_alt_outlined,
              dense: true,
              onTap: ready ? () => c.sendToHerdr() : null,
            ),
            StudioButton(
              label: 'Prompt agent',
              icon: Icons.send,
              dense: true,
              onTap: ready && pane.hasAgent
                  ? () => c.sendToHerdr(submit: true)
                  : null,
            ),
          ],
        ),
        if (status != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              status,
              style: StudioText.muted,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
    );
  }
}

/// `✳ Merge into main · mobile_elixir`: the pane's name, then where it
/// is when that is not this project, and the agent's state.
class _PaneLabel extends StatelessWidget {
  const _PaneLabel({required this.pane, required this.project});

  final HerdrPane pane;
  final String project;

  @override
  Widget build(BuildContext context) {
    final where = pane.inProject(project)
        ? null
        : pane.cwd.split('/').where((s) => s.isNotEmpty).lastOrNull;
    final state = pane.hasAgent
        ? '${pane.agent}${pane.agentStatus == null ? '' : ' ${pane.agentStatus}'}'
        : 'shell';
    return Row(
      children: [
        Flexible(
          child: Text(
            pane.name,
            style: StudioText.body,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (where != null) ...[
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              where,
              style: StudioText.muted,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
        const SizedBox(width: 6),
        Text(state, style: StudioText.monoMuted),
      ],
    );
  }
}

class _ChainRow extends StatelessWidget {
  const _ChainRow({
    required this.widget,
    required this.selected,
    required this.scopes,
    required this.onTap,
  });

  final PickedWidget widget;
  final bool selected;
  final SourceScopes scopes;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final location = widget.location;
    return Material(
      color: selected ? StudioColors.accentSoft : Colors.transparent,
      borderRadius: BorderRadius.circular(5),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(5),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.description,
                      style: StudioText.mono.copyWith(
                        color: selected
                            ? StudioColors.accent
                            : StudioColors.text,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (widget.text != null)
                    Flexible(
                      child: Text(
                        '"${widget.text}"',
                        style: StudioText.muted,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
              ),
              Text(
                location == null
                    ? 'no source location'
                    : scopes.describe(location),
                style: StudioText.monoMuted,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
