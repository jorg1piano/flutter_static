import 'package:flutter/material.dart';
import 'package:flutter_static/flutter_static.dart';

// Dogfood entry point: `flutter run -d macos` in this repo serves this demo story.
void main() => runFlutterStatic(const DemoStories());

class DemoStories extends Stories {
  const DemoStories();

  @override
  List<Story> build() => [
    Story(
      'demo/box',
      () => Container(
        padding: const EdgeInsets.all(24),
        color: Colors.purple,
        child: const Text(
          'flutter_static demo',
          style: TextStyle(color: Colors.white, fontSize: 32),
        ),
      ),
    ),
  ];
}
