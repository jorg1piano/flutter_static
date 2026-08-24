import 'story.dart';

/// The catalog server needs dart:io; on the web only the story types exist.
void runFlutterStatic(Stories stories, {int port = 8474}) {
  throw UnsupportedError('runFlutterStatic is not available on the web');
}
