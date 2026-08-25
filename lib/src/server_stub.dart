import 'package:flutter/widgets.dart';

import 'story.dart';

/// The catalog server needs dart:io; on the web only the story types exist.
typedef CatalogShell = Widget Function(BuildContext context, Widget mounts);

void runFlutterStatic(Stories stories, {int port = 8474, CatalogShell? shell}) {
  throw UnsupportedError('runFlutterStatic is not available on the web');
}
