import 'package:flutter/material.dart';

import 'controller.dart';
import 'model.dart';
import 'theme.dart';
import 'widgets.dart';

/// The page on an infinite pan/zoom surface: rows of cells, each cell a
/// stack of variant renders. Nothing here is editable; the canvas is a
/// render target and the source is the truth.
class StudioCanvas extends StatefulWidget {
  const StudioCanvas({super.key, required this.controller});

  final StudioController controller;

  @override
  State<StudioCanvas> createState() => _StudioCanvasState();
}

class _StudioCanvasState extends State<StudioCanvas> {
  final _transform = TransformationController();
  String? _pageShown;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onController);
    _pageShown = widget.controller.selectedPage?.id;
    _transform.value = _home;
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onController);
    _transform.dispose();
    super.dispose();
  }

  /// A page opens at its origin, at half size: a phone row fits.
  static Matrix4 get _home => Matrix4.identity()
    ..translateByDouble(24, 24, 0, 1)
    ..scaleByDouble(0.5, 0.5, 1, 1);

  void _onController() {
    final id = widget.controller.selectedPage?.id;
    if (id == _pageShown) return;
    _pageShown = id;
    // Not during the notification's build: InteractiveViewer listens to
    // the controller and would setState mid-build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _transform.value = _home;
    });
  }

  /// The canvas zoom: the x axis's scale (there is no rotation).
  /// `getMaxScaleOnAxis` would include z, which stays at 1.
  double get _scale => _transform.value.storage[0];

  void _zoomTo(double scale) {
    final size = context.size ?? const Size(800, 600);
    final centre = Offset(size.width / 2, size.height / 2);
    final current = _transform.value;
    final factor = scale / _scale;
    _transform.value = Matrix4.identity()
      ..translateByDouble(centre.dx, centre.dy, 0, 1)
      ..scaleByDouble(factor, factor, 1, 1)
      ..translateByDouble(-centre.dx, -centre.dy, 0, 1)
      ..multiply(current);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final controller = widget.controller;
      final page = controller.selectedPage;
      return Container(
        color: StudioColors.canvas,
        child: Stack(
          children: [
            Positioned.fill(child: CustomPaint(painter: _DotGrid(_transform))),
            Positioned.fill(
              child: GestureDetector(
                onTap: () => controller.selectStory(null),
                child: InteractiveViewer(
                  transformationController: _transform,
                  constrained: false,
                  minScale: 0.05,
                  maxScale: 4,
                  boundaryMargin: const EdgeInsets.all(4000),
                  child: page == null
                      ? const SizedBox(width: 400, height: 300)
                      : _PageBody(page: page, controller: controller),
                ),
              ),
            ),
            Positioned(
              left: 16,
              top: 12,
              child: _PageTitle(page: page, controller: controller),
            ),
            Positioned(
              right: 16,
              top: 12,
              child: ListenableBuilder(
                listenable: _transform,
                builder: (context, _) =>
                    _ZoomControls(scale: _scale, onZoom: _zoomTo),
              ),
            ),
          ],
        ),
      );
    },
  );
}

class _PageTitle extends StatelessWidget {
  const _PageTitle({required this.page, required this.controller});

  final StudioPage? page;
  final StudioController controller;

  @override
  Widget build(BuildContext context) {
    if (page == null) return const SizedBox.shrink();
    return IgnorePointer(
      child: Row(
        children: [
          Text(page!.title, style: StudioText.title),
          const SizedBox(width: 8),
          Text(
            page!.isLine ? page!.id : '${page!.storyIds.length} stories',
            style: StudioText.muted,
          ),
        ],
      ),
    );
  }
}

class _ZoomControls extends StatelessWidget {
  const _ZoomControls({required this.scale, required this.onZoom});

  final double scale;
  final ValueChanged<double> onZoom;

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: StudioColors.panel,
      borderRadius: BorderRadius.circular(6),
      border: Border.all(color: StudioColors.border),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _ZoomButton(icon: Icons.remove, onTap: () => onZoom(scale / 1.25)),
        InkWell(
          onTap: () => onZoom(1),
          child: SizedBox(
            width: 48,
            child: Center(
              child: Text('${(scale * 100).round()}%', style: StudioText.mono),
            ),
          ),
        ),
        _ZoomButton(icon: Icons.add, onTap: () => onZoom(scale * 1.25)),
      ],
    ),
  );
}

class _ZoomButton extends StatelessWidget {
  const _ZoomButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    child: SizedBox(
      width: 28,
      height: 28,
      child: Icon(icon, size: 14, color: StudioColors.muted),
    ),
  );
}

class _PageBody extends StatelessWidget {
  const _PageBody({required this.page, required this.controller});

  final StudioPage page;
  final StudioController controller;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(64, 96, 64, 64),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final (i, row) in page.rows.indexed) ...[
          if (i > 0) const SizedBox(height: 96),
          Text(row.title, style: StudioText.title.copyWith(fontSize: 22)),
          const SizedBox(height: 24),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (j, cell) in row.cells.indexed) ...[
                if (j > 0) const SizedBox(width: 64),
                _CellColumn(cell: cell, controller: controller),
              ],
            ],
          ),
        ],
      ],
    ),
  );
}

class _CellColumn extends StatelessWidget {
  const _CellColumn({required this.cell, required this.controller});

  final PageCell cell;
  final StudioController controller;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(cell.title, style: StudioText.muted.copyWith(fontSize: 15)),
      const SizedBox(height: 12),
      for (final (k, id) in cell.variants.indexed) ...[
        if (k > 0) const SizedBox(height: 32),
        StoryCard(id: id, controller: controller),
        if (cell.variants.length > 1) ...[
          const SizedBox(height: 8),
          Text(
            id.split('/').last,
            style: StudioText.monoMuted.copyWith(fontSize: 13),
          ),
        ],
      ],
    ],
  );
}

/// One render. Keeps the last image while a new one loads, and paints the
/// selection ring over it so selecting never moves the layout.
class StoryCard extends StatelessWidget {
  const StoryCard({super.key, required this.id, required this.controller});

  final String id;
  final StudioController controller;

  @override
  Widget build(BuildContext context) {
    final png = controller.png(id);
    final selected = controller.selectedStoryId == id;
    final loading = controller.isFetching(id);
    return GestureDetector(
      onTap: () => controller.selectStory(id),
      child: Container(
        foregroundDecoration: BoxDecoration(
          border: Border.all(
            color: selected ? StudioColors.accent : Colors.transparent,
            width: 3,
            strokeAlign: BorderSide.strokeAlignOutside,
          ),
          borderRadius: BorderRadius.circular(2),
        ),
        decoration: const BoxDecoration(
          boxShadow: [
            BoxShadow(
              color: Color(0x66000000),
              blurRadius: 24,
              offset: Offset(0, 8),
            ),
          ],
        ),
        child: png == null
            ? Container(
                width: 390,
                height: 240,
                color: StudioColors.raised,
                alignment: Alignment.center,
                child: Text(
                  loading ? 'rendering…' : id,
                  style: StudioText.monoMuted,
                ),
              )
            : Stack(
                children: [
                  Image.memory(
                    png.bytes,
                    scale: 2,
                    gaplessPlayback: true,
                    filterQuality: FilterQuality.medium,
                  ),
                  if (loading)
                    const Positioned(
                      right: 8,
                      top: 8,
                      child: SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: StudioColors.accent,
                        ),
                      ),
                    ),
                ],
              ),
      ),
    );
  }
}

/// Dots that move with the canvas, so panning reads as motion.
class _DotGrid extends CustomPainter {
  _DotGrid(this.transform) : super(repaint: transform);

  final TransformationController transform;

  @override
  void paint(Canvas canvas, Size size) {
    final m = transform.value;
    var step = 32.0 * m.storage[0];
    while (step < 16) {
      step *= 2;
    }
    while (step > 64) {
      step /= 2;
    }
    final dx = m.storage[12] % step;
    final dy = m.storage[13] % step;
    final paint = Paint()..color = StudioColors.canvasDot;
    for (var x = dx; x < size.width; x += step) {
      for (var y = dy; y < size.height; y += step) {
        canvas.drawCircle(Offset(x, y), 1, paint);
      }
    }
  }

  @override
  bool shouldRepaint(_DotGrid old) => true;
}

/// Shown instead of the canvas until the catalog is up.
class CanvasPlaceholder extends StatelessWidget {
  const CanvasPlaceholder({super.key, required this.controller});

  final StudioController controller;

  @override
  Widget build(BuildContext context) => Container(
    color: StudioColors.canvas,
    alignment: Alignment.center,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(switch (controller.status) {
          CatalogStatus.stopped => 'Catalog stopped',
          CatalogStatus.starting => 'Starting the catalog…',
          CatalogStatus.error => 'Catalog error',
          _ => '',
        }, style: StudioText.title),
        const SizedBox(height: 6),
        Text(
          controller.statusDetail ?? controller.project,
          style: StudioText.muted,
        ),
        const SizedBox(height: 16),
        if (controller.status == CatalogStatus.starting)
          const SizedBox(
            width: 160,
            child: LinearProgressIndicator(
              color: StudioColors.accent,
              backgroundColor: StudioColors.raised,
            ),
          )
        else
          StudioButton(
            label: 'Start',
            icon: Icons.play_arrow,
            primary: true,
            onTap: controller.start,
          ),
      ],
    ),
  );
}
