import 'package:flutter_static/flutter_static.dart';

import 'stories/example.dart' as example;
import 'stories/studio_page.dart' as studio_page;
import 'stories/studio_page_2.dart' as studio_page_2;

import 'lines/knobs.dart' as line_knobs;

// Run with: flutter_static run
void main() => runFlutterStatic(const MyStories());

// One file per story group under stories/ and one per flow under lines/,
// each exposing a top-level function that build() calls fresh on every
// hot reload. Never store stories in a variable: main() never re-runs,
// so a closure created by the old main() keeps its old code.
//
// Scaffold more with:
//   flutter_static add story <group>/<name>
//   flutter_static add storyline <name>
class MyStories extends Stories {
  const MyStories();

  @override
  List<Storyline> storylines() => [line_knobs.storyline()];

  @override
  List<Story> build() => [...example.stories()];
}
