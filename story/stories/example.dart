import 'package:flutter/material.dart';
import 'package:flutter_static/flutter_static.dart';

List<Story> stories() => [
  Story(
    'example/hello',
    () => Container(
      padding: const EdgeInsets.all(24),
      color: Colors.indigo,
      child: const Text(
        'Hello, flutter_static',
        style: TextStyle(color: Colors.white, fontSize: 24),
      ),
    ),
  ),
];
