import 'dart:io';

import 'package:flutter/material.dart';

import '../tokens.dart';
import 'controller.dart';
import 'theme.dart';

/// Project, status, pages, token groups, and the process controls.
class Sidebar extends StatelessWidget {
  const Sidebar({super.key, required this.controller});

  final StudioController controller;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => Container(
      color: StudioColors.sidebar,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Header(controller: controller),
          const Divider(height: 1, color: StudioColors.border),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: [
                const _Section('Pages'),
                for (final page in controller.pages)
                  _Item(
                    label: page.title,
                    icon: page.isLine
                        ? Icons.account_tree_outlined
                        : Icons.grid_view_outlined,
                    selected:
                        page.id == controller.selectedPage?.id &&
                        controller.selectedTokenGroup == null,
                    onTap: () {
                      controller.selectTokenGroup(null);
                      controller.selectPage(page.id);
                    },
                  ),
                if (controller.pages.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                    child: Text('No stories yet', style: StudioText.muted),
                  ),
                const _Section('Tokens'),
                for (final group
                    in controller.tokens?.groups ?? const <TokenGroup>[])
                  _Item(
                    label: group.name,
                    detail: '${group.tokens.length}',
                    icon: Icons.palette_outlined,
                    selected: group.name == controller.selectedTokenGroup,
                    onTap: () => controller.selectTokenGroup(group.name),
                  ),
                if ((controller.tokens?.groups ?? const []).isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                    child: Text(
                      'No token files. Add lib/**/tokens.dart with static consts.',
                      style: StudioText.muted,
                    ),
                  ),
              ],
            ),
          ),
          const Divider(height: 1, color: StudioColors.border),
          _Footer(controller: controller),
        ],
      ),
    ),
  );
}

class _Header extends StatelessWidget {
  const _Header({required this.controller});

  final StudioController controller;

  @override
  Widget build(BuildContext context) {
    final (color, label) = switch (controller.status) {
      CatalogStatus.ready => (StudioColors.ok, 'live'),
      CatalogStatus.reloading => (StudioColors.warn, 'reloading'),
      CatalogStatus.error => (StudioColors.bad, 'error'),
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  controller.projectName,
                  style: StudioText.title,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 6),
              Text(label, style: StudioText.muted),
            ],
          ),
          const SizedBox(height: 2),
          Text('localhost:${controller.port}', style: StudioText.monoMuted),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
    child: Text(text.toUpperCase(), style: StudioText.section),
  );
}

class _Item extends StatelessWidget {
  const _Item({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
    this.detail,
  });

  final String label;
  final String? detail;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
    child: Material(
      color: selected ? StudioColors.raised : Colors.transparent,
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        onTap: onTap,
        hoverColor: StudioColors.hover,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            children: [
              Icon(
                icon,
                size: 14,
                color: selected ? StudioColors.accent : StudioColors.faint,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  style: StudioText.body.copyWith(
                    color: selected ? StudioColors.text : StudioColors.muted,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (detail != null) Text(detail!, style: StudioText.monoMuted),
            ],
          ),
        ),
      ),
    ),
  );
}

class _Footer extends StatelessWidget {
  const _Footer({required this.controller});

  final StudioController controller;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
    child: Row(
      children: [
        _IconAction(
          icon: Icons.bolt,
          tooltip: controller.live
              ? 'Live widgets on the canvas (click for renders)'
              : 'PNG renders on the canvas (click for live widgets)',
          active: controller.live,
          onTap: controller.toggleLive,
        ),
        _IconAction(
          icon: Icons.touch_app_outlined,
          tooltip: controller.interact
              ? 'Option-clicks reach and select the story'
              : 'Option-clicks only reach the widget',
          active: controller.interact,
          onTap: controller.toggleInteract,
        ),
        const Spacer(),
        _IconAction(
          icon: Icons.terminal,
          tooltip: 'Logs',
          active: controller.showLogs,
          onTap: controller.toggleLogs,
        ),
        _IconAction(
          icon: Icons.language,
          tooltip: 'Open the gallery in the browser',
          onTap: () => Process.run('open', [controller.url]),
        ),
      ],
    ),
  );
}

class _IconAction extends StatelessWidget {
  const _IconAction({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.active = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final bool active;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: tooltip,
    onPressed: onTap,
    icon: Icon(icon, size: 16),
    color: active ? StudioColors.accent : StudioColors.muted,
    padding: EdgeInsets.zero,
    constraints: const BoxConstraints.tightFor(width: 30, height: 28),
  );
}
