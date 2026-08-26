import 'dart:ui' show PointMode;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../phone_mockup.dart';
import '../widget_pick.dart';
import 'controller.dart';
import 'model.dart';
import 'theme.dart';

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

  /// Takes focus after an inspected click, so the arrow keys walk the
  /// picked chain instead of going to the terminal.
  final _focus = FocusNode(debugLabel: 'canvas');
  WidgetPick? _focusedPick;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onController);
    _pageShown = widget.controller.selectedPage?.id;
    _transform.value = _home;
  }

  @override
  void reassemble() {
    super.reassemble();
    // A hot reload keeps the controller instance; make sure it listens.
    widget.controller.watchKeyboard();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onController);
    _transform.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// A page opens at its origin, at half size: a phone row fits.
  static Matrix4 get _home => Matrix4.identity()
    ..translateByDouble(24, 24, 0, 1)
    ..scaleByDouble(0.5, 0.5, 1, 1);

  void _onController() {
    final pick = widget.controller.pick;
    if (pick != null && pick != _focusedPick) _focus.requestFocus();
    _focusedPick = pick;
    final id = widget.controller.selectedPage?.id;
    if (id == _pageShown) return;
    _pageShown = id;
    // Not during the notification's build: InteractiveViewer listens to
    // the controller and would setState mid-build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _transform.value = _home;
    });
  }

  /// With a pick: Up to its parent, Down to its child, Escape to clear.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final controller = widget.controller;
    if (controller.pick == null || event is KeyUpEvent) {
      return KeyEventResult.ignored;
    }
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowUp:
        controller.pickParent();
      case LogicalKeyboardKey.arrowDown:
        controller.pickChild();
      case LogicalKeyboardKey.escape:
        controller.clearPick();
      default:
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
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
      return Focus(
        focusNode: _focus,
        onKeyEvent: _onKey,
        child: Container(
          color: StudioColors.canvas,
          child: Stack(
            children: [
              Positioned.fill(
                child: CustomPaint(painter: _DotGrid(_transform)),
              ),
              Positioned.fill(
                child: GestureDetector(
                  onTap: () => controller.selectStory(null),
                  child: InteractiveViewer(
                    transformationController: _transform,
                    constrained: false,
                    minScale: 0.05,
                    maxScale: 4,
                    boundaryMargin: const EdgeInsets.all(4000),
                    panEnabled: controller.spaceHeld,
                    child: page == null
                        ? const SizedBox(width: 400, height: 300)
                        : _PageBody(page: page, controller: controller),
                  ),
                ),
              ),
              Positioned.fill(child: _PanCursorOverlay(controller: controller)),
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
        ),
      );
    },
  );
}

class _PanCursorOverlay extends StatefulWidget {
  const _PanCursorOverlay({required this.controller});

  final StudioController controller;

  @override
  State<_PanCursorOverlay> createState() => _PanCursorOverlayState();
}

class _PanCursorOverlayState extends State<_PanCursorOverlay> {
  bool _dragging = false;

  @override
  void initState() {
    super.initState();
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointer);
  }

  @override
  void dispose() {
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_onPointer);
    super.dispose();
  }

  MouseCursor get _cursor => _dragging && widget.controller.spaceHeld
      ? SystemMouseCursors.grabbing
      : widget.controller.spaceHeld
      ? SystemMouseCursors.grab
      : SystemMouseCursors.basic;

  void _setDragging(bool dragging) {
    if (_dragging == dragging) return;
    setState(() => _dragging = dragging);
  }

  void _onPointer(PointerEvent event) {
    if (event is PointerDownEvent && widget.controller.spaceHeld) {
      _setDragging(true);
    } else if (event is PointerUpEvent || event is PointerCancelEvent) {
      _setDragging(false);
    }
  }

  @override
  Widget build(BuildContext context) => MouseRegion(
    key: const Key('canvas-pan-cursor'),
    cursor: _cursor,
    opaque: false,
    child: const SizedBox.expand(),
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
        for (var i = 0; i < controller.slotRowCount(page); i++) ...[
          if (i > 0) const SizedBox(height: 64),
          if (controller.rowTitle(page, i) case final title?) ...[
            Text(title, style: StudioText.title.copyWith(fontSize: 22)),
            const SizedBox(height: 24),
          ],
          DragTarget<_CellDrag>(
            onWillAcceptWithDetails: (details) =>
                details.data.pageId == page.id,
            onAcceptWithDetails: (details) => controller.moveCell(
              pageId: page.id,
              cellId: details.data.cellId,
              rowIndex: i,
            ),
            builder: (context, candidates, _) => AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: candidates.isEmpty
                    ? Colors.transparent
                    : StudioColors.hover,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final (j, cell)
                      in controller.slotsFor(page, i).indexed) ...[
                    if (j > 0)
                      _CellInsertTarget(
                        pageId: page.id,
                        rowIndex: i,
                        slotIndex: j,
                        controller: controller,
                      ),
                    if (cell == null)
                      _CellSlot(
                        pageId: page.id,
                        rowIndex: i,
                        slotIndex: j,
                        controller: controller,
                      )
                    else
                      _CellColumn(
                        pageId: page.id,
                        rowIndex: i,
                        slotIndex: j,
                        slot: cell,
                        controller: controller,
                      ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ],
    ),
  );
}

class _CellDrag {
  const _CellDrag({required this.pageId, required this.cellId});

  final String pageId;
  final String cellId;
}

class _CellInsertTarget extends StatefulWidget {
  const _CellInsertTarget({
    required this.pageId,
    required this.rowIndex,
    required this.slotIndex,
    required this.controller,
  });

  final String pageId;
  final int rowIndex;
  final int slotIndex;
  final StudioController controller;

  @override
  State<_CellInsertTarget> createState() => _CellInsertTargetState();
}

class _CellInsertTargetState extends State<_CellInsertTarget> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) => DragTarget<_CellDrag>(
    onWillAcceptWithDetails: (details) => details.data.pageId == widget.pageId,
    onAcceptWithDetails: (details) => widget.controller.insertCellAtSlot(
      pageId: widget.pageId,
      cellId: details.data.cellId,
      rowIndex: widget.rowIndex,
      slotIndex: widget.slotIndex,
    ),
    builder: (context, candidates, _) {
      final hot = candidates.isNotEmpty;
      return MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => widget.controller.insertEmptySlot(
            pageId: widget.pageId,
            rowIndex: widget.rowIndex,
            slotIndex: widget.slotIndex,
          ),
          child: SizedBox(
            width: 24,
            height: 44,
            child: Center(
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 100),
                opacity: hot || _hover ? 1 : 0,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: StudioColors.panel,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: hot ? StudioColors.accent : StudioColors.faint,
                    ),
                  ),
                  child: Icon(
                    Icons.add,
                    size: 16,
                    color: hot ? StudioColors.accent : StudioColors.muted,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}

class _CellSlot extends StatelessWidget {
  const _CellSlot({
    required this.pageId,
    required this.rowIndex,
    required this.slotIndex,
    required this.controller,
  });

  final String pageId;
  final int rowIndex;
  final int slotIndex;
  final StudioController controller;

  @override
  Widget build(BuildContext context) => DragTarget<_CellDrag>(
    onWillAcceptWithDetails: (details) => details.data.pageId == pageId,
    onAcceptWithDetails: (details) => controller.moveCellToSlot(
      pageId: pageId,
      cellId: details.data.cellId,
      rowIndex: rowIndex,
      slotIndex: slotIndex,
    ),
    builder: (context, candidates, _) {
      final hot = candidates.isNotEmpty;
      final size = controller.selectedPage?.isLine == true
          ? PhoneMockup(
              spec: controller.deviceSpec ?? PhoneSpec.fallback,
              child: const SizedBox.shrink(),
            ).size
          : const Size(260, 220);
      return AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        width: size.width,
        height: size.height,
        decoration: BoxDecoration(
          color: hot ? StudioColors.hover : Colors.transparent,
          border: Border.all(
            color: hot ? StudioColors.accent : StudioColors.faint,
            width: hot ? 2 : 1,
          ),
          borderRadius: BorderRadius.circular(12),
        ),
      );
    },
  );
}

class _CellEdgeDraggable extends StatelessWidget {
  const _CellEdgeDraggable({
    required this.pageId,
    required this.cellId,
    required this.title,
    required this.child,
  });

  final String pageId;
  final String cellId;
  final String title;
  final Widget child;

  static const _edge = 18.0;

  @override
  Widget build(BuildContext context) => Stack(
    clipBehavior: Clip.none,
    children: [
      child,
      Positioned(left: 0, top: 0, right: 0, height: _edge, child: _handle()),
      Positioned(left: 0, bottom: 0, right: 0, height: _edge, child: _handle()),
      Positioned(left: 0, top: 0, bottom: 0, width: _edge, child: _handle()),
      Positioned(right: 0, top: 0, bottom: 0, width: _edge, child: _handle()),
    ],
  );

  Widget _handle() => Draggable<_CellDrag>(
    data: _CellDrag(pageId: pageId, cellId: cellId),
    feedback: _CellDragFeedback(title),
    childWhenDragging: const SizedBox.expand(),
    child: MouseRegion(
      cursor: SystemMouseCursors.move,
      child: Container(color: Colors.transparent),
    ),
  );
}

class _CellDragFeedback extends StatelessWidget {
  const _CellDragFeedback(this.title);

  final String title;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.transparent,
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: StudioColors.panel,
        border: Border.all(color: StudioColors.accent),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Text(title, style: StudioText.muted),
      ),
    ),
  );
}

class _CellColumn extends StatelessWidget {
  const _CellColumn({
    required this.pageId,
    required this.rowIndex,
    required this.slotIndex,
    required this.slot,
    required this.controller,
  });

  final String pageId;
  final int rowIndex;
  final int slotIndex;
  final StudioSlot slot;
  final StudioController controller;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      DragTarget<_CellDrag>(
        onWillAcceptWithDetails: (details) =>
            details.data.pageId == pageId && details.data.cellId != slot.id,
        onAcceptWithDetails: (details) => controller.moveCellToSlot(
          pageId: pageId,
          cellId: details.data.cellId,
          rowIndex: rowIndex,
          slotIndex: slotIndex,
        ),
        builder: (context, candidates, _) {
          final title = Text(
            slot.title,
            style: StudioText.muted.copyWith(
              fontSize: 15,
              color: candidates.isEmpty
                  ? StudioColors.muted
                  : StudioColors.accent,
            ),
          );
          return Draggable<_CellDrag>(
            data: _CellDrag(pageId: pageId, cellId: slot.id),
            feedback: _CellDragFeedback(slot.title),
            childWhenDragging: Opacity(opacity: 0.35, child: title),
            child: MouseRegion(cursor: SystemMouseCursors.move, child: title),
          );
        },
      ),
      const SizedBox(height: 12),
      _CellEdgeDraggable(
        pageId: pageId,
        cellId: slot.id,
        title: slot.title,
        child: StoryCard(id: slot.storyId, controller: controller),
      ),
      if (slot.variantLabel != null) ...[
        const SizedBox(height: 8),
        Text(
          slot.variantLabel!,
          style: StudioText.monoMuted.copyWith(fontSize: 13),
        ),
      ],
    ],
  );
}

/// One story on the canvas: mounted live when the catalog knows a shell
/// for it, its PNG render otherwise. Keeps the last image while a new one
/// captures, and paints the selection ring over it so selecting never
/// moves the layout.
class StoryCard extends StatelessWidget {
  const StoryCard({super.key, required this.id, required this.controller});

  final String id;
  final StudioController controller;

  @override
  Widget build(BuildContext context) {
    final selected = controller.selectedStoryId == id;
    final live = controller.isLive(id);
    // A story the catalog has not captured yet: a background capture
    // tells us how it lays out, and its PNG stands in meanwhile.
    if (live == null) controller.discover(id);
    final png = live == true ? null : controller.png(id);
    Widget body;
    if (live == true) {
      body = _LiveSlot(
        interact: controller.interact,
        altHeld: controller.altHeld,
        onSelect: () => controller.selectStory(id),
        onPick: (root, position) => controller.pickAt(id, root, position),
        onSize: (size) => controller.noteSize(id, size),
        child: controller.mount(id),
      );
      // The inspected widget, outlined where it sits: the card's origin
      // is the mounted story's, so its bounds apply as they are.
      final picked = controller.pickStoryId == id
          ? controller.pickedWidget?.bounds
          : null;
      if (picked != null) {
        body = Stack(
          clipBehavior: Clip.none,
          children: [
            body,
            Positioned.fromRect(
              rect: picked,
              child: const IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Color(0x227C9CFF),
                    border: Border.fromBorderSide(
                      BorderSide(color: StudioColors.accent, width: 1.5),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      }
    } else {
      body = _RenderSlot(
        id: id,
        png: png,
        loading: controller.isFetching(id),
        placeholder: controller.placeholderSize(id),
        onSelect: () => controller.selectStory(id),
      );
    }
    return Container(
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
      child: body,
    );
  }
}

/// A live widget. Plain clicks inspect the widget under the pointer and
/// select it in the widget tree. With Option held events go through to
/// the mounted story, so controls inside a mockup can be clicked.
class _LiveSlot extends StatefulWidget {
  const _LiveSlot({
    required this.child,
    required this.interact,
    required this.altHeld,
    required this.onSelect,
    required this.onPick,
    required this.onSize,
  });

  final Widget child;
  final bool interact;
  final bool altHeld;
  final VoidCallback onSelect;

  /// An inspected click: the mounted story's render object and the
  /// pointer in its coordinates.
  final void Function(RenderObject root, Offset position) onPick;

  /// Reports the mounted story's size after each layout, so a later
  /// placeholder for it takes the same room.
  final ValueChanged<Size> onSize;

  @override
  State<_LiveSlot> createState() => _LiveSlotState();
}

class _LiveSlotState extends State<_LiveSlot> {
  final _boundary = GlobalKey();
  Size? _reported;

  Offset? _inspectAt;

  void _onPointerDown(PointerDownEvent event) {
    if (widget.altHeld && widget.interact) widget.onSelect();
  }

  void _onTapDown(TapDownDetails details) {
    final box = _boundary.currentContext?.findRenderObject();
    _inspectAt = box is RenderBox
        ? box.globalToLocal(details.globalPosition)
        : null;
  }

  void _onTap() {
    final box = _boundary.currentContext?.findRenderObject();
    final position = _inspectAt;
    _inspectAt = null;
    if (box is RenderBox && position != null) widget.onPick(box, position);
  }

  void _onTapCancel() {
    _inspectAt = null;
  }

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final size = context.size;
      if (size != null && size != _reported) {
        _reported = size;
        widget.onSize(size);
      }
    });
    // Its own layer: an animating story repaints itself, not the canvas.
    final isolated = RepaintBoundary(key: _boundary, child: widget.child);
    final inspect = !widget.altHeld;
    return MouseRegion(
      cursor: inspect ? SystemMouseCursors.precise : MouseCursor.defer,
      child: Listener(
        onPointerDown: _onPointerDown,
        // The tap recognizer keeps the canvas's own (which deselects)
        // from winning inspected clicks. Pick on tap, not down, so the
        // rebuild that adds the outline cannot reset this recognizer and
        // let mouse-up clear the pick.
        child: inspect
            ? GestureDetector(
                onTapDown: _onTapDown,
                onTap: _onTap,
                onTapCancel: _onTapCancel,
                behavior: HitTestBehavior.opaque,
                child: AbsorbPointer(child: isolated),
              )
            : isolated,
      ),
    );
  }
}

class _RenderSlot extends StatelessWidget {
  const _RenderSlot({
    required this.id,
    required this.png,
    required this.loading,
    required this.placeholder,
    required this.onSelect,
  });

  final String id;
  final StoryPng? png;
  final bool loading;
  final Size placeholder;
  final VoidCallback onSelect;

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onSelect,
    child: png == null
        ? Container(
            width: placeholder.width,
            height: placeholder.height,
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
                png!.bytes,
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
  );
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
    // One draw call: a circle per dot was ten thousand calls a frame
    // while panning.
    final points = <Offset>[
      for (var x = dx; x < size.width; x += step)
        for (var y = dy; y < size.height; y += step) Offset(x, y),
    ];
    canvas.drawPoints(
      PointMode.points,
      points,
      Paint()
        ..color = StudioColors.canvasDot
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_DotGrid old) => true;
}

/// Shown instead of the canvas when the project lists no stories.
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
        Text('No stories', style: StudioText.title),
        const SizedBox(height: 6),
        Text(
          'Add one with: flutter_static add story <group>/<name>',
          style: StudioText.muted,
        ),
        const SizedBox(height: 4),
        Text(controller.project, style: StudioText.monoMuted),
      ],
    ),
  );
}
