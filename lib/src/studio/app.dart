import 'package:flutter/material.dart';

import 'canvas.dart';
import 'controller.dart';
import 'inspector.dart';
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

class StudioShell extends StatelessWidget {
  const StudioShell({
    super.key,
    required this.controller,
    required this.terminal,
  });

  final StudioController controller;
  final StudioTerminal terminal;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Row(
      children: [
        SizedBox(width: 224, child: Sidebar(controller: controller)),
        const VerticalDivider(width: 1, color: StudioColors.border),
        Expanded(
          child: Column(
            children: [
              Expanded(
                child: ListenableBuilder(
                  listenable: controller,
                  builder: (context, _) => controller.pages.isEmpty
                      ? CanvasPlaceholder(controller: controller)
                      : StudioCanvas(controller: controller),
                ),
              ),
              _LogDrawer(controller: controller),
            ],
          ),
        ),
        const VerticalDivider(width: 1, color: StudioColors.border),
        Container(
          width: 380,
          color: StudioColors.panel,
          child: Column(
            children: [
              Expanded(child: Inspector(controller: controller)),
              const Divider(height: 1, color: StudioColors.border),
              SizedBox(height: 400, child: TerminalPanel(terminal: terminal)),
            ],
          ),
        ),
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
