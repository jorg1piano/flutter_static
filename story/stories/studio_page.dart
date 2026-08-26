import 'package:flutter/material.dart';
import 'package:flutter_static_story/flutter_static_story.dart';

List<Story> stories() => [
  Story('studio_page/default', () => const StudioPagePage()),
];

/// Page created from Flutter Static Studio.
class StudioPagePage extends StatelessWidget {
  const StudioPagePage({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xFFF8FAFC),
    body: Center(
      child: Text(
        'Studio Page',
        style: const TextStyle(
          color: Color(0xFF0F172A),
          fontSize: 28,
          fontWeight: FontWeight.w700,
        ),
      ),
    ),
  );
}
