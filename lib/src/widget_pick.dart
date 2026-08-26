/// Which line of which file made the widget under a point.
///
/// Every debug build compiles with `--track-widget-creation`, which stamps
/// each widget constructor call with its file, line and column. The
/// inspector's JSON is the public way to read that stamp back, so a hit
/// test on a live render tree plus a walk up the element chain answers
/// "where was this written". Studio uses it for Option-click; the catalog
/// serves it over HTTP so an agent can ask the same about a point in a
/// render it is looking at.
///
/// Nothing here needs the project to change: the stamps are already in
/// every widget, the project's own and the framework's alike.
library;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;

/// A widget constructor call site: absolute file path, 1-based line and
/// column.
class SourceLocation {
  const SourceLocation(this.file, this.line, this.column);

  final String file;
  final int line;
  final int column;

  /// Where [element]'s widget was constructed, or null when the build
  /// does not track creation (profile and release builds) or the element
  /// is gone.
  static SourceLocation? of(Element element) {
    if (element.debugIsDefunct) return null;
    final json = element.toDiagnosticsNode().toJsonMap(
      InspectorSerializationDelegate(
        service: WidgetInspectorService.instance,
        subtreeDepth: 0,
      ),
    );
    final location = json['creationLocation'];
    if (location is! Map) return null;
    final file = location['file'];
    final line = location['line'];
    final column = location['column'];
    if (file is! String || line is! int || column is! int) return null;
    return SourceLocation(_pathOf(file), line, column);
  }

  /// The stamp is a `file:///` URI; a path is what editors and agents
  /// take.
  static String _pathOf(String uri) {
    final parsed = Uri.tryParse(uri);
    if (parsed != null && parsed.scheme == 'file') return parsed.toFilePath();
    return uri;
  }

  @override
  String toString() => '$file:$line:$column';
}

/// Which side of the project a source file is on.
enum SourceScope {
  /// Under the project's `story/`: the story definitions.
  story,

  /// Under the project's `lib/` or a path dependency's: the components.
  project,

  /// The Flutter framework.
  framework,

  /// Anything else: flutter_static, pub packages.
  other,
}

/// Classifies files against a project and shows their paths relative to
/// it.
class SourceScopes {
  SourceScopes(this.project, {Iterable<String> packageRoots = const []})
    : roots = [
        project,
        for (final root in packageRoots)
          if (root != project) root,
      ];

  final String project;

  /// The project and its path dependencies.
  final List<String> roots;

  SourceScope of(String file) {
    if (p.isWithin(p.join(project, 'story'), file)) return SourceScope.story;
    if (roots.any((root) => p.isWithin(root, file))) return SourceScope.project;
    if (file.contains('/packages/flutter/lib/')) return SourceScope.framework;
    return SourceScope.other;
  }

  /// [file] relative to the project when it is the project's (a path
  /// dependency reads `../ui_kit/lib/...`), absolute otherwise.
  String display(String file) => switch (of(file)) {
    SourceScope.story || SourceScope.project => p.relative(file, from: project),
    _ => file,
  };

  /// `story/stories/buttons.dart:13:11`.
  String describe(SourceLocation location) =>
      '${display(location.file)}:${location.line}:${location.column}';
}

/// One widget in a pick: what it is, where it was written, where it sits.
class PickedWidget {
  const PickedWidget({
    required this.type,
    required this.description,
    required this.location,
    required this.scope,
    required this.bounds,
    this.text,
  });

  /// `AppButton`.
  final String type;

  /// `AppButton-[<'primary'>]`: the type with its key, when it has one.
  final String description;

  final SourceLocation? location;
  final SourceScope scope;

  /// In the pick root's coordinates, logical pixels; null for a widget
  /// whose render object is not a box.
  final Rect? bounds;

  /// A [Text] or [RichText]'s content.
  final String? text;

  /// Written in the project: a story file or a component.
  bool get isLocal =>
      scope == SourceScope.story || scope == SourceScope.project;

  Map<String, Object?> toJson(SourceScopes scopes, {double scale = 1}) {
    final location = this.location;
    final bounds = this.bounds;
    return {
      'widget': type,
      if (description != type) 'description': description,
      if (text != null) 'text': text,
      if (location != null) ...{
        'file': scopes.display(location.file),
        'line': location.line,
        'column': location.column,
        'location': scopes.describe(location),
      },
      'scope': scope.name,
      if (bounds != null)
        'bounds': [
          (bounds.left * scale).round(),
          (bounds.top * scale).round(),
          (bounds.width * scale).round(),
          (bounds.height * scale).round(),
        ],
    };
  }
}

/// The widgets that made what is under a point, nearest first, up to the
/// root the pick ran on.
class WidgetPick {
  const WidgetPick(this.chain);

  final List<PickedWidget> chain;

  /// The project's widgets in the chain, nearest first: the ones worth
  /// telling an agent about.
  List<PickedWidget> get local => [
    for (final widget in chain)
      if (widget.isLocal) widget,
  ];

  /// Index of the nearest widget written in the project: what a click
  /// most likely meant.
  int get localIndex {
    final i = chain.indexWhere((w) => w.isLocal);
    return i < 0 ? 0 : i;
  }

  /// The outermost widget written in a story file, which is inside the
  /// `Story(...)` that defines the story: the story's own source line.
  PickedWidget? get story {
    for (final widget in chain.reversed) {
      if (widget.scope == SourceScope.story) return widget;
    }
    return null;
  }

  Map<String, Object?> toJson(SourceScopes scopes, {double scale = 1}) {
    final local = this.local;
    final story = this.story;
    return {
      if (local.isNotEmpty) 'widget': local.first.toJson(scopes, scale: scale),
      if (story != null) 'story': story.toJson(scopes, scale: scale),
      'chain': [for (final w in local) w.toJson(scopes, scale: scale)],
    };
  }
}

/// The render objects under [position] (in [root]'s coordinates),
/// smallest first. The widget inspector's walk: by paint bounds rather
/// than the pointer hit test, so a widget that takes no events (a
/// `SizedBox`, a `Padding`) can be picked too, and a hit on the edge of a
/// box wins, so a container can be picked by its border.
List<RenderObject> renderObjectsAt(RenderObject root, Offset position) {
  final regular = <RenderObject>[];
  final edge = <RenderObject>[];
  _hitTest(regular, edge, position, root, Matrix4.identity());
  double area(RenderObject o) {
    final size = o.semanticBounds.size;
    return size.width * size.height;
  }

  regular.sort((a, b) => area(a).compareTo(area(b)));
  return {...edge, ...regular}.toList();
}

const _edgeMargin = 2.0;

bool _hitTest(
  List<RenderObject> hits,
  List<RenderObject> edgeHits,
  Offset position,
  RenderObject object,
  Matrix4 transform,
) {
  final inverse = Matrix4.tryInvert(transform);
  if (inverse == null) return false;
  final local = MatrixUtils.transformPoint(inverse, position);
  var hit = false;
  final children = object.debugDescribeChildren();
  for (var i = children.length - 1; i >= 0; i--) {
    final node = children[i];
    if (node.style == DiagnosticsTreeStyle.offstage ||
        node.value is! RenderObject) {
      continue;
    }
    final child = node.value! as RenderObject;
    final clip = object.describeApproximatePaintClip(child);
    if (clip != null && !clip.contains(local)) continue;
    final childTransform = transform.clone();
    object.applyPaintTransform(child, childTransform);
    if (_hitTest(hits, edgeHits, position, child, childTransform)) hit = true;
  }
  final bounds = object.semanticBounds;
  if (bounds.contains(local)) {
    hit = true;
    if (!bounds.deflate(_edgeMargin).contains(local)) edgeHits.add(object);
  }
  if (hit) hits.add(object);
  return hit;
}

/// The widgets that made what is at [position] in [root], nearest first,
/// up to but not including [root]'s own widget. Null when nothing is
/// there or the tree has no elements to walk (a render tree built
/// without widgets).
WidgetPick? pickWidgetAt(
  RenderObject root,
  Offset position,
  SourceScopes scopes,
) {
  final hits = renderObjectsAt(root, position);
  if (hits.isEmpty) return null;
  final element = (hits.first.debugCreator as DebugCreator?)?.element;
  if (element == null) return null;
  final stop = (root.debugCreator as DebugCreator?)?.element;
  final chain = <PickedWidget>[];
  for (final e in element.debugGetDiagnosticChain()) {
    if (e == stop) break;
    if (stop == null && !_isWithin(e.renderObject, root)) break;
    chain.add(describeElement(e, root, scopes));
  }
  return chain.isEmpty ? null : WidgetPick(chain);
}

bool _isWithin(RenderObject? object, RenderObject root) {
  for (var node = object; node != null; node = node.parent) {
    if (node == root) return true;
  }
  return false;
}

/// [element] as a [PickedWidget], with bounds in [root]'s coordinates.
PickedWidget describeElement(
  Element element,
  RenderObject root,
  SourceScopes scopes,
) {
  final widget = element.widget;
  final location = SourceLocation.of(element);
  final render = element.renderObject;
  Rect? bounds;
  if (render is RenderBox && render.hasSize && _isWithin(render, root)) {
    bounds = MatrixUtils.transformRect(
      render.getTransformTo(root),
      Offset.zero & render.size,
    );
  }
  return PickedWidget(
    type: widget.runtimeType.toString(),
    description: widget.toStringShort(),
    location: location,
    scope: location == null ? SourceScope.other : scopes.of(location.file),
    bounds: bounds,
    text: switch (widget) {
      Text(:final data) => data,
      RichText(:final text) => text.toPlainText(),
      _ => null,
    },
  );
}

/// The project's widgets under [root], nested as in the tree, each with
/// its location and bounds. Framework and package widgets between them
/// are skipped over, so a `Column` of `AppButton`s reads as one list.
List<Map<String, Object?>> widgetTreeJson(
  RenderObject root,
  SourceScopes scopes, {
  double scale = 1,
}) {
  final rootElement = (root.debugCreator as DebugCreator?)?.element;
  if (rootElement == null) return const [];
  List<Map<String, Object?>> children(Element parent) {
    final out = <Map<String, Object?>>[];
    parent.visitChildren((child) {
      final picked = describeElement(child, root, scopes);
      if (picked.isLocal) {
        out.add({
          ...picked.toJson(scopes, scale: scale),
          'children': children(child),
        });
      } else {
        out.addAll(children(child));
      }
    });
    return out;
  }

  return children(rootElement);
}
