import 'package:flutter_static/flutter_static.dart';

import 'main.dart' show DemoStories;

// Dogfood: Studio on this package's own demo story.
// A real project runs `flutter_static studio`, which scaffolds
// story/studio_main.dart with the same one-liner for its Stories.
void main() => runFlutterStudio(const DemoStories());
