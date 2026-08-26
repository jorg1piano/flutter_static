import 'package:flutter/material.dart';
import 'package:flutter_static_story/flutter_static_story.dart';

List<Story> stories() => [
  Story('studio_page_2/default', () => const StudioPage2Page()),
];

/// Page created from Flutter Static Studio.
class StudioPage2Page extends StatelessWidget {
  const StudioPage2Page({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xFFF8FAFC),
    body: Center(
      child: Text(
        'Studio Page 2',
        style: const TextStyle(
          color: Color(0xFF0F172A),
          fontSize: 28,
          fontWeight: FontWeight.w700,
        ),
      ),
    ),
  );
}
