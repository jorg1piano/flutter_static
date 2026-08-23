import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

class Story {
  const Story(this.id, this.builder);

  final String id;
  final Widget Function() builder;
}

/// Subclass this and implement [build] to define your stories.
///
/// It must be a class method, not a stored closure: hot reload never re-runs
/// `main()`, and a closure created by the old `main()` keeps executing the
/// code it was created with. Method calls dispatch through the class, whose
/// code is reliably replaced on reload, so [build] is re-evaluated fresh on
/// every request and every reload.
abstract class Stories {
  const Stories();

  List<Story> build();
}

void runFlutterStatic(Stories stories, {int port = 8474}) {
  runApp(_CatalogApp(stories: stories));
  _serve(stories, port);
}

final _boundaryKey = GlobalKey();
final _currentId = ValueNotifier<String?>(null);
int _version = 0;
final _eventClients = <HttpResponse>[];

class _CatalogApp extends StatefulWidget {
  const _CatalogApp({required this.stories});

  final Stories stories;

  @override
  State<_CatalogApp> createState() => _CatalogAppState();
}

class _CatalogAppState extends State<_CatalogApp> {
  @override
  void reassemble() {
    super.reassemble();
    _version++;
    for (final client in _eventClients) {
      try {
        client.write('data: {"version": $_version}\n\n');
        client.flush();
      } catch (_) {
        // Dead client; removed by its done handler.
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: Center(
          child: ValueListenableBuilder<String?>(
            valueListenable: _currentId,
            builder: (context, id, _) {
              final all = widget.stories.build();
              if (all.isEmpty) return const Text('no stories registered');
              final story = all.firstWhere(
                (s) => s.id == id,
                orElse: () => all.first,
              );
              return RepaintBoundary(key: _boundaryKey, child: story.builder());
            },
          ),
        ),
      ),
    );
  }
}

Future<void> _serve(Stories stories, int port) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
  debugPrint('flutter_static serving on http://localhost:$port');
  await for (final request in server) {
    final response = request.response;
    final path = request.uri.path;
    // Renders change on every hot reload; never let browsers cache them.
    response.headers.set('Cache-Control', 'no-store');
    try {
      if (path == '/index.json') {
        response.headers.contentType = ContentType.json;
        response.write(
          jsonEncode({
            'version': _version,
            'stories': [
              for (final s in stories.build())
                {'id': s.id, 'png': '/story/${s.id}.png'},
            ],
          }),
        );
        await response.close();
      } else if (path == '/events') {
        response.bufferOutput = false;
        response.headers.contentType = ContentType('text', 'event-stream');
        response.headers.set('Cache-Control', 'no-cache');
        response.write('data: {"version": $_version}\n\n');
        response.flush();
        _eventClients.add(response);
        response.done.whenComplete(() => _eventClients.remove(response));
      } else if (path.startsWith('/story/') && path.endsWith('.png')) {
        final id = path.substring(
          '/story/'.length,
          path.length - '.png'.length,
        );
        if (!stories.build().any((s) => s.id == id)) {
          response.statusCode = HttpStatus.notFound;
          await response.close();
        } else {
          final png = await _capture(id);
          response.headers.contentType = ContentType('image', 'png');
          response.add(png);
          await response.close();
        }
      } else {
        response.statusCode = HttpStatus.notFound;
        await response.close();
      }
    } catch (e) {
      try {
        response.statusCode = HttpStatus.internalServerError;
        response.write('$e');
        await response.close();
      } catch (_) {}
    }
  }
}

Future<Uint8List> _capture(String id) async {
  _currentId.value = id;
  final binding = WidgetsBinding.instance;
  // Pump frames until the tree settles: implicit animations (e.g.
  // CircleAvatar's 200ms theme-change tween) keep scheduling frames until
  // they finish, and capturing the first frame would freeze them at t=0.
  // The deadline bounds stories that animate forever.
  //
  // An occluded or hidden window gets no vsync on macOS, so once a natural
  // frame times out we pump frames manually with an advancing timestamp.
  // (Warm-up frames are no good here: they reuse the last frame's timestamp,
  // so tickers see zero elapsed time and animations never progress.)
  // A hidden app has framesEnabled == false: scheduleFrame() is silently
  // ignored, so hasScheduledFrame can't be trusted as a settle signal.
  // transientCallbackCount counts active tickers and works either way.
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  var noVsync = !binding.framesEnabled;
  var synthetic = binding.currentSystemFrameTimeStamp;
  do {
    if (noVsync) {
      synthetic += const Duration(milliseconds: 16);
      binding.handleBeginFrame(synthetic);
      binding.handleDrawFrame();
      await Future<void>.delayed(Duration.zero);
    } else {
      try {
        await binding.endOfFrame.timeout(const Duration(milliseconds: 150));
      } on TimeoutException {
        noVsync = true;
      }
    }
  } while ((binding.hasScheduledFrame || binding.transientCallbackCount > 0) &&
      DateTime.now().isBefore(deadline));
  final boundary =
      _boundaryKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
  final image = await boundary.toImage(pixelRatio: 2);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return bytes!.buffer.asUint8List();
}
