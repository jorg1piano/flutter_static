import 'story.dart';

/// Only the web build can mount live story views.
void runFlutterStaticWeb(Stories stories) {
  throw UnsupportedError('runFlutterStaticWeb only exists in web builds');
}
