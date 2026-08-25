/// Flutter Static Studio: a macOS workbench for a Flutter project's design
/// system. Pages of stories on a canvas, design tokens editable in place,
/// everything re-rendered by the project's own catalog process on every
/// save.
///
/// Launched by `flutter_static studio --project <dir>`, which passes the
/// project, its catalog port and this package's root as dart-defines.
/// The project's code never compiles into Studio: it runs in the child
/// catalog (`flutter_static up`), and Studio talks to it over HTTP.
library;

import 'dart:io';

import 'package:flutter/material.dart';

import 'src/studio/canvas.dart';
import 'src/studio/controller.dart';
import 'src/studio/inspector.dart';
import 'src/studio/sidebar.dart';
import 'src/studio/theme.dart';

const _project = String.fromEnvironment('FLUTTER_STATIC_STUDIO_PROJECT');
const _packageRoot = String.fromEnvironment('FLUTTER_STATIC_ROOT');
const _port = int.fromEnvironment(
  'FLUTTER_STATIC_STUDIO_PORT',
  defaultValue: 8474,
);

void main() {
  final controller = StudioController(
    project: _project.isEmpty ? Directory.current.path : _project,
    port: _port,
    packageRoot: _packageRoot.isEmpty ? Directory.current.path : _packageRoot,
  );
  runApp(StudioApp(controller: controller));
  controller.start();
}

class StudioApp extends StatelessWidget {
  const StudioApp({super.key, required this.controller});

  final StudioController controller;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Flutter Static Studio',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      brightness: Brightness.dark,
      useMaterial3: true,
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
    home: StudioShell(controller: controller),
  );
}

class StudioShell extends StatelessWidget {
  const StudioShell({super.key, required this.controller});

  final StudioController controller;

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
          width: 304,
          color: StudioColors.panel,
          child: Inspector(controller: controller),
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
                  'Hot reload failed. Renders show the last good code.\n\n$error',
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
