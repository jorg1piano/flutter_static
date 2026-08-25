import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../phone_mockup.dart';
import '../server_io.dart';
import 'controller.dart';
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
            const SectionLabel('For an agent'),
            SelectableText(
              'flutter_static render $story'
              '${controller.knobs.entries.map((e) => ' -k ${e.key}=${e.value}').join()}',
              style: StudioText.monoMuted,
            ),
          ],
        ],
      ],
    );
  }
}
