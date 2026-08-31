import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_static/src/server_io.dart';
import 'package:flutter_static/src/story.dart';
import 'package:flutter_test/flutter_test.dart';

/// A 1x1 opaque PNG.
final _png = Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, //
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, //
  0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53, 0xDE, 0x00, 0x00, 0x00, //
  0x0C, 0x49, 0x44, 0x41, 0x54, 0x08, 0xD7, 0x63, 0xF8, 0xCF, 0xC0, 0x00, //
  0x00, 0x03, 0x01, 0x01, 0x00, 0x18, 0xDD, 0x8D, 0xB0, 0x00, 0x00, 0x00, //
  0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

class _Stories extends Stories {
  const _Stories();

  @override
  List<Story> build() => [
    // An image inside a scrollable: Flutter's scroll physics answer
    // ScrollAwareImageProvider with View.of(context), which the offscreen
    // tree cannot provide. The story environment's physics never defer.
    Story(
      'scroll/image',
      () => SizedBox(
        width: 200,
        height: 200,
        child: ListView(children: [Image.memory(_png)]),
      ),
    ),
  ];
}

void main() {
  testWidgets('an image inside a scrollable captures offscreen', (
    tester,
  ) async {
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      final png = await renderStoryPng(const _Stories(), 'scroll/image');
      expect(png, isNotEmpty);
    });
    expect(storyShellOf('scroll/image'), StoryShell.unbounded);
  });
}
