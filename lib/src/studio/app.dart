import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'canvas.dart';
import 'controller.dart';
import 'inspector.dart';
import 'prompt_panel.dart';
import 'sidebar.dart';
import 'terminal.dart';
import 'terminal_panel.dart';
import 'theme.dart';

/// The Studio window: the catalog's window mounts painted underneath
/// (so they can still be snapshotted), the Studio UI on top.
class StudioApp extends StatelessWidget {
  const StudioApp({
    super.key,
    required this.controller,
    required this.terminal,
    required this.mounts,
  });

  final StudioController controller;
  final StudioTerminal terminal;
  final Widget mounts;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Flutter Static Studio',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      brightness: Brightness.dark,
      useMaterial3: true,
      // The stories run as the project's platform (iOS, say); Studio's
      // own chrome is a Mac app.
      platform: TargetPlatform.macOS,
      colorScheme: const ColorScheme.dark(
        primary: StudioColors.accent,
        surface: StudioColors.panel,
      ),
      scaffoldBackgroundColor: StudioColors.canvas,
      splashFactory: NoSplash.splashFactory,
      textTheme: const TextTheme(bodyMedium: StudioText.body),
      tooltipTheme: const TooltipThemeData(
        textStyle: StudioText.body,
        decoration: BoxDecoration(
          color: StudioColors.raised,
          borderRadius: BorderRadius.all(Radius.circular(4)),
        ),
      ),
    ),
    home: Stack(
      children: [
        Positioned.fill(child: Center(child: mounts)),
        Positioned.fill(
          child: StudioShell(controller: controller, terminal: terminal),
        ),
      ],
    ),
  );
}

class StudioShell extends StatefulWidget {
  const StudioShell({
    super.key,
    required this.controller,
    required this.terminal,
  });

  final StudioController controller;
  final StudioTerminal terminal;

  @override
  State<StudioShell> createState() => _StudioShellState();
}

class _StudioShellState extends State<StudioShell> {
  final _focus = FocusNode(debugLabel: 'studio shell');
  bool _promptOpen = true;
  bool _inspectorOpen = true;

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final keyboard = HardwareKeyboard.instance;
    if (!keyboard.isMetaPressed ||
        event.logicalKey != LogicalKeyboardKey.backslash) {
      return KeyEventResult.ignored;
    }
    setState(() {
      if (keyboard.isShiftPressed) {
        _promptOpen = true;
        _inspectorOpen = true;
      } else {
        final anyOpen = _promptOpen || _inspectorOpen;
        _promptOpen = !anyOpen;
        _inspectorOpen = !anyOpen;
      }
    });
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: _focus,
    autofocus: true,
    onKeyEvent: _onKey,
    child: Scaffold(
      body: Row(
        children: [
          SizedBox(width: 224, child: Sidebar(controller: widget.controller)),
          const VerticalDivider(width: 1, color: StudioColors.border),
          _CollapsiblePane(
            open: _promptOpen,
            width: 340,
            label: 'Codex',
            icon: Icons.auto_awesome,
            side: _PaneSide.left,
            onToggle: () => setState(() => _promptOpen = !_promptOpen),
            child: PromptPanel(
              controller: widget.controller,
              terminal: widget.terminal,
              onCollapse: () => setState(() => _promptOpen = false),
            ),
          ),
          const VerticalDivider(width: 1, color: StudioColors.border),
          Expanded(
            child: Column(
              children: [
                Expanded(
                  child: ListenableBuilder(
                    listenable: widget.controller,
                    builder: (context, _) => widget.controller.pages.isEmpty
                        ? CanvasPlaceholder(controller: widget.controller)
                        : StudioCanvas(controller: widget.controller),
                  ),
                ),
                _LogDrawer(controller: widget.controller),
              ],
            ),
          ),
          const VerticalDivider(width: 1, color: StudioColors.border),
          _CollapsiblePane(
            open: _inspectorOpen,
            width: 380,
            label: 'Inspector',
            icon: Icons.tune,
            side: _PaneSide.right,
            onToggle: () => setState(() => _inspectorOpen = !_inspectorOpen),
            child: _RightPanel(
              controller: widget.controller,
              terminal: widget.terminal,
              onCollapse: () => setState(() => _inspectorOpen = false),
            ),
          ),
        ],
      ),
    ),
  );
}

enum _PaneSide { left, right }

class _CollapsiblePane extends StatelessWidget {
  const _CollapsiblePane({
    required this.open,
    required this.width,
    required this.label,
    required this.icon,
    required this.side,
    required this.onToggle,
    required this.child,
  });

  final bool open;
  final double width;
  final String label;
  final IconData icon;
  final _PaneSide side;
  final VoidCallback onToggle;
  final Widget child;

  @override
  Widget build(BuildContext context) => AnimatedContainer(
    duration: const Duration(milliseconds: 160),
    curve: Curves.easeOutCubic,
    width: open ? width : 36,
    color: StudioColors.panel,
    child: open
        ? child
        : InkWell(
            onTap: onToggle,
            child: RotatedBox(
              quarterTurns: side == _PaneSide.left ? 3 : 1,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, size: 14, color: StudioColors.muted),
                  const SizedBox(width: 8),
                  Text(label, style: StudioText.muted),
                ],
              ),
            ),
          ),
  );
}

class _RightPanel extends StatelessWidget {
  const _RightPanel({
    required this.controller,
    required this.terminal,
    required this.onCollapse,
  });

  final StudioController controller;
  final StudioTerminal terminal;
  final VoidCallback onCollapse;

  @override
  Widget build(BuildContext context) => Container(
    color: StudioColors.panel,
    child: Column(
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: IconButton(
            tooltip: 'Collapse inspector',
            onPressed: onCollapse,
            icon: const Icon(Icons.keyboard_double_arrow_right, size: 16),
            color: StudioColors.muted,
          ),
        ),
        Expanded(child: Inspector(controller: controller)),
        const Divider(height: 1, color: StudioColors.border),
        SizedBox(height: 400, child: TerminalPanel(terminal: terminal)),
      ],
    ),
  );
}

class _LogDrawer extends StatelessWidget {
  const _LogDrawer({required this.controller});

  final StudioController controller;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final error = controller.reloadError;
      if (!controller.showLogs && error == null) return const SizedBox.shrink();
      return Container(
        height: error != null && !controller.showLogs ? 120 : 200,
        decoration: const BoxDecoration(
          color: StudioColors.sidebar,
          border: Border(top: BorderSide(color: StudioColors.border)),
        ),
        child: error != null && !controller.showLogs
            ? SingleChildScrollView(
                padding: const EdgeInsets.all(12),
                child: Text(
                  'Hot reload failed. The canvas shows the last good code.'
                  '\n\n$error',
                  style: StudioText.mono.copyWith(color: StudioColors.bad),
                ),
              )
            : ListView.builder(
                padding: const EdgeInsets.all(8),
                reverse: true,
                itemCount: controller.logs.length,
                itemBuilder: (context, i) => Text(
                  controller.logs[controller.logs.length - 1 - i],
                  style: StudioText.monoMuted,
                ),
              ),
      );
    },
  );
}
