/// Flutter Static Studio, in the project's own process.
///
/// `runFlutterStudio` is `runFlutterStatic` with the Studio UI as the
/// window's contents: the same stories, served over HTTP for agents as
/// before, and mounted live on a canvas for people. Hot reload reaches
/// the widgets, the tokens they read and Studio itself in one go.
///
/// A project's `story/studio_main.dart` (scaffolded by
/// `flutter_static studio`) is one line:
///
/// ```dart
/// void main() => runFlutterStudio(const MyStories());
/// ```
library;

import 'dart:io';

import 'package:flutter/widgets.dart';

import 'server_io.dart';
import 'story.dart';
import 'studio/app.dart';
import 'studio/controller.dart';
import 'studio/terminal.dart';

void runFlutterStudio(Stories stories, {int? port}) {
  // The controller listens to the keyboard from construction.
  WidgetsFlutterBinding.ensureInitialized();
  final resolvedPort = port ?? defaultCatalogPort;
  final controller = StudioController(
    stories: stories,
    project: projectRoot() ?? Directory.current.path,
    port: resolvedPort,
  );
  final terminal = StudioTerminal(
    project: controller.project,
    context: () => controller.agentContext(withSelection: false),
  );
  // A click on the canvas types the story it selected into the terminal,
  // at the agent's cursor; an Option-click types the picked widget's
  // source position after it (and again when a chain row picks another).
  String? mentioned;
  String? mentionedLocation;
  controller.addListener(() {
    final id = controller.selectedStoryId;
    if (id != null && id != mentioned && terminal.running) {
      terminal.mention(id);
    }
    mentioned = id;
    final location = controller.pickedWidget?.location;
    final where = location == null
        ? null
        : controller.scopes.describe(location);
    if (where != null && where != mentionedLocation && terminal.running) {
      terminal.mention(where);
    }
    mentionedLocation = where;
  });
  runFlutterStatic(
    stories,
    port: resolvedPort,
    shell: (context, mounts) =>
        StudioApp(controller: controller, terminal: terminal, mounts: mounts),
  );
}
