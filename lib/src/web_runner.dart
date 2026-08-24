import 'dart:js_interop';
import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';

import 'story.dart';

/// Entry point for web builds: every JS `addView({initialData: {storyId}})`
/// mounts the matching story as its own live Flutter view.
void runFlutterStaticWeb(Stories stories) {
  runWidget(_MultiViewStories(stories: stories));
}

class _MultiViewStories extends StatefulWidget {
  const _MultiViewStories({required this.stories});

  final Stories stories;

  @override
  State<_MultiViewStories> createState() => _MultiViewStoriesState();
}

class _MultiViewStoriesState extends State<_MultiViewStories>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeMetrics() => setState(() {});

  String? _storyIdFor(int viewId) {
    try {
      final data = ui_web.views.getInitialData(viewId)?.dartify();
      return (data as Map?)?['storyId'] as String?;
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = ThemeData();
    final views = WidgetsBinding.instance.platformDispatcher.views;
    return ViewCollection(
      views: [
        for (final view in views)
          View(
            view: view,
            child: MediaQuery.fromView(
              view: view,
              child: Localizations(
                locale: const Locale('en'),
                delegates: const [
                  DefaultWidgetsLocalizations.delegate,
                  DefaultMaterialLocalizations.delegate,
                ],
                child: Directionality(
                  textDirection: TextDirection.ltr,
                  child: Theme(
                    data: theme,
                    child: DefaultTextStyle(
                      style: theme.textTheme.bodyMedium!,
                      child: Material(
                        type: MaterialType.transparency,
                        child: _storyView(view.viewId),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _storyView(int viewId) {
    final id = _storyIdFor(viewId);
    final all = widget.stories.all();
    final matches = all.where((s) => s.id == id);
    if (matches.isEmpty) {
      return Center(child: Text('unknown story: ${id ?? '<none>'}'));
    }
    return SingleChildScrollView(child: Center(child: matches.first.builder()));
  }
}
