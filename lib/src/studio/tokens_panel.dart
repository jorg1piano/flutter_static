import 'dart:async';

import 'package:flutter/material.dart';

import '../tokens.dart';
import 'controller.dart';
import 'theme.dart';
import 'widgets.dart';

/// One token group, editable. Every change writes the Dart file; the
/// catalog hot reloads it and the canvas refreshes over /events.
class TokensPanel extends StatelessWidget {
  const TokensPanel({super.key, required this.group, required this.controller});

  final TokenGroup group;
  final StudioController controller;

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
    children: [
      Row(
        children: [
          Expanded(child: Text(group.name, style: StudioText.title)),
          IconButton(
            tooltip: 'Back to the inspector',
            onPressed: () => controller.selectTokenGroup(null),
            icon: const Icon(Icons.close, size: 16, color: StudioColors.muted),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 24, height: 24),
          ),
        ],
      ),
      Text(
        group.file.replaceFirst('${controller.project}/', ''),
        style: StudioText.monoMuted,
      ),
      if (group.doc != null) ...[
        const SizedBox(height: 6),
        Text(group.doc!, style: StudioText.muted),
      ],
      const SizedBox(height: 8),
      for (final token in group.tokens)
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: switch (token.kind) {
            TokenKind.color => _ColorRow(
              key: ValueKey(token.id),
              token: token,
              controller: controller,
            ),
            TokenKind.number ||
            TokenKind.radius ||
            TokenKind.duration => _NumberRow(
              key: ValueKey(token.id),
              token: token,
              controller: controller,
            ),
            TokenKind.text => _TextStyleRow(
              key: ValueKey(token.id),
              token: token,
              controller: controller,
            ),
            TokenKind.other => _OtherRow(token: token),
          },
        ),
    ],
  );
}

class _TokenHeader extends StatelessWidget {
  const _TokenHeader({required this.token, this.trailing});

  final DesignToken token;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              token.name,
              style: StudioText.body.copyWith(fontWeight: FontWeight.w600),
            ),
            if (token.doc != null)
              Text(
                token.doc!,
                style: StudioText.muted.copyWith(fontSize: 11),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
          ],
        ),
      ),
      ?trailing,
    ],
  );
}

/// Coalesces slider drags into one write per 250 ms: each write is a
/// save, each save a hot reload of the whole process (about 350 ms),
/// and reloads that queue up behind each other make the canvas lag the
/// pointer instead of following it.
class _Debounce {
  Timer? _timer;

  void call(VoidCallback action) {
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 250), action);
  }

  void dispose() => _timer?.cancel();
}

// --- colour ---------------------------------------------------------------

class _ColorRow extends StatefulWidget {
  const _ColorRow({super.key, required this.token, required this.controller});

  final DesignToken token;
  final StudioController controller;

  @override
  State<_ColorRow> createState() => _ColorRowState();
}

class _ColorRowState extends State<_ColorRow> {
  bool _open = false;
  late HSVColor _hsv = HSVColor.fromColor(Color(widget.token.argb!));
  final _debounce = _Debounce();

  @override
  void didUpdateWidget(_ColorRow old) {
    super.didUpdateWidget(old);
    // An edit from outside (the agent, a hex field) wins over our drag
    // state once it lands in the file.
    final fresh = Color(widget.token.argb!);
    if (old.token.argb != widget.token.argb && _hsv.toColor() != fresh) {
      _hsv = HSVColor.fromColor(fresh);
    }
  }

  @override
  void dispose() {
    _debounce.dispose();
    super.dispose();
  }

  void _set(HSVColor hsv) {
    setState(() => _hsv = hsv);
    _debounce(() {
      widget.controller.setToken(
        widget.token,
        colorSource(hsv.toColor().toARGB32()),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final color = _hsv.toColor();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: () => setState(() => _open = !_open),
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              children: [
                _SwatchBox(color: color, size: 28),
                const SizedBox(width: 10),
                Expanded(child: _TokenHeader(token: widget.token)),
                const SizedBox(width: 8),
                Text(colorHex(color.toARGB32()), style: StudioText.monoMuted),
              ],
            ),
          ),
        ),
        if (_open)
          Padding(
            padding: const EdgeInsets.only(top: 8, left: 2),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _SaturationValueBox(hsv: _hsv, onChanged: _set),
                const SizedBox(height: 8),
                _HueBar(hsv: _hsv, onChanged: _set),
                const SizedBox(height: 8),
                _AlphaBar(hsv: _hsv, onChanged: _set),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Text('Hex', style: StudioText.muted),
                    const SizedBox(width: 8),
                    StudioField(
                      width: 110,
                      value: colorHex(color.toARGB32()),
                      onCommit: (text) {
                        final argb = parseColorHex(text);
                        if (argb != null) _set(HSVColor.fromColor(Color(argb)));
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _SwatchBox extends StatelessWidget {
  const _SwatchBox({required this.color, required this.size});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(5),
      border: Border.all(color: StudioColors.border),
    ),
    clipBehavior: Clip.antiAlias,
    child: CustomPaint(painter: _CheckerPainter(color)),
  );
}

class _CheckerPainter extends CustomPainter {
  const _CheckerPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (color.a < 1) {
      const cell = 6.0;
      final light = Paint()..color = const Color(0xFFCCCCCC);
      final dark = Paint()..color = const Color(0xFF888888);
      for (var y = 0.0; y < size.height; y += cell) {
        for (var x = 0.0; x < size.width; x += cell) {
          final odd = ((x / cell).floor() + (y / cell).floor()).isOdd;
          canvas.drawRect(Rect.fromLTWH(x, y, cell, cell), odd ? dark : light);
        }
      }
    }
    canvas.drawRect(Offset.zero & size, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_CheckerPainter old) => old.color != color;
}

/// Saturation along x, value along y, at the current hue.
class _SaturationValueBox extends StatelessWidget {
  const _SaturationValueBox({required this.hsv, required this.onChanged});

  final HSVColor hsv;
  final ValueChanged<HSVColor> onChanged;

  void _pick(Offset local, Size size) => onChanged(
    hsv
        .withSaturation((local.dx / size.width).clamp(0, 1))
        .withValue((1 - local.dy / size.height).clamp(0, 1)),
  );

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final size = Size(constraints.maxWidth, 140);
      return GestureDetector(
        onPanDown: (d) => _pick(d.localPosition, size),
        onPanUpdate: (d) => _pick(d.localPosition, size),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: CustomPaint(size: size, painter: _SvPainter(hsv)),
        ),
      );
    },
  );
}

class _SvPainter extends CustomPainter {
  const _SvPainter(this.hsv);

  final HSVColor hsv;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final pure = HSVColor.fromAHSV(1, hsv.hue, 1, 1).toColor();
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          colors: [Colors.white, pure],
        ).createShader(rect),
    );
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.transparent, Colors.black],
        ).createShader(rect),
    );
    final p = Offset(
      hsv.saturation * size.width,
      (1 - hsv.value) * size.height,
    );
    canvas.drawCircle(
      p,
      6,
      Paint()..color = Colors.black.withValues(alpha: 0.5),
    );
    canvas.drawCircle(
      p,
      6,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(_SvPainter old) => old.hsv != hsv;
}

class _HueBar extends StatelessWidget {
  const _HueBar({required this.hsv, required this.onChanged});

  final HSVColor hsv;
  final ValueChanged<HSVColor> onChanged;

  @override
  Widget build(BuildContext context) => _Bar(
    position: hsv.hue / 360,
    onPosition: (t) => onChanged(hsv.withHue(t * 360)),
    gradient: LinearGradient(
      colors: [
        for (var h = 0; h <= 360; h += 60)
          HSVColor.fromAHSV(1, h.toDouble() % 360, 1, 1).toColor(),
      ],
    ),
  );
}

class _AlphaBar extends StatelessWidget {
  const _AlphaBar({required this.hsv, required this.onChanged});

  final HSVColor hsv;
  final ValueChanged<HSVColor> onChanged;

  @override
  Widget build(BuildContext context) => _Bar(
    position: hsv.alpha,
    onPosition: (t) => onChanged(hsv.withAlpha(t)),
    checker: true,
    gradient: LinearGradient(
      colors: [
        hsv.toColor().withValues(alpha: 0),
        hsv.toColor().withValues(alpha: 1),
      ],
    ),
  );
}

class _Bar extends StatelessWidget {
  const _Bar({
    required this.position,
    required this.onPosition,
    required this.gradient,
    this.checker = false,
  });

  final double position;
  final ValueChanged<double> onPosition;
  final Gradient gradient;
  final bool checker;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final width = constraints.maxWidth;
      return GestureDetector(
        onPanDown: (d) => onPosition((d.localPosition.dx / width).clamp(0, 1)),
        onPanUpdate: (d) =>
            onPosition((d.localPosition.dx / width).clamp(0, 1)),
        child: SizedBox(
          height: 14,
          child: CustomPaint(painter: _BarPainter(gradient, position, checker)),
        ),
      );
    },
  );
}

class _BarPainter extends CustomPainter {
  const _BarPainter(this.gradient, this.position, this.checker);

  final Gradient gradient;
  final double position;
  final bool checker;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(7));
    canvas.save();
    canvas.clipRRect(rrect);
    if (checker) _CheckerPainter(const Color(0x00000000)).paint(canvas, size);
    canvas.drawRect(rect, Paint()..shader = gradient.createShader(rect));
    canvas.restore();
    final x = position * size.width;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(x, size.height / 2),
          width: 6,
          height: size.height + 4,
        ),
        const Radius.circular(3),
      ),
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(_BarPainter old) =>
      old.position != position || old.gradient != gradient;
}

// --- numbers --------------------------------------------------------------

class _NumberRow extends StatefulWidget {
  const _NumberRow({super.key, required this.token, required this.controller});

  final DesignToken token;
  final StudioController controller;

  @override
  State<_NumberRow> createState() => _NumberRowState();
}

class _NumberRowState extends State<_NumberRow> {
  late double _value = widget.token.number!;
  final _debounce = _Debounce();

  @override
  void didUpdateWidget(_NumberRow old) {
    super.didUpdateWidget(old);
    if (old.token.number != widget.token.number) {
      _value = widget.token.number!;
    }
  }

  @override
  void dispose() {
    _debounce.dispose();
    super.dispose();
  }

  void _set(double v, {bool now = false}) {
    setState(() => _value = v);
    void write() => widget.controller.setToken(
      widget.token,
      numberSourceFor(widget.token, _value),
    );
    now ? write() : _debounce(write);
  }

  double get _max => switch (widget.token.kind) {
    TokenKind.duration => 2000,
    _ => _value > 48 ? (_value * 2).ceilToDouble() : 64,
  };

  @override
  Widget build(BuildContext context) {
    final unit = switch (widget.token.kind) {
      TokenKind.duration => 'ms',
      TokenKind.radius => 'r',
      _ => '',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _TokenHeader(
          token: widget.token,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              StudioField(
                width: 64,
                value: numberSource(_value, like: widget.token.source),
                onCommit: (text) {
                  final v = double.tryParse(text);
                  if (v != null) _set(v, now: true);
                },
              ),
              if (unit.isNotEmpty) ...[
                const SizedBox(width: 4),
                Text(unit, style: StudioText.monoMuted),
              ],
            ],
          ),
        ),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 3,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
            activeTrackColor: StudioColors.accent,
            inactiveTrackColor: StudioColors.border,
            thumbColor: StudioColors.text,
          ),
          child: Slider(
            value: _value.clamp(0, _max),
            min: 0,
            max: _max,
            onChanged: (v) => _set(
              widget.token.kind == TokenKind.duration
                  ? v.roundToDouble()
                  : (v * 2).round() / 2,
            ),
          ),
        ),
      ],
    );
  }
}

// --- text styles ----------------------------------------------------------

class _TextStyleRow extends StatelessWidget {
  const _TextStyleRow({
    super.key,
    required this.token,
    required this.controller,
  });

  final DesignToken token;
  final StudioController controller;

  static const _weights = [100, 200, 300, 400, 500, 600, 700, 800, 900];

  @override
  Widget build(BuildContext context) {
    final size = double.tryParse(token.arg('fontSize')?.value ?? '');
    final weight = int.tryParse(
      (token.arg('fontWeight')?.value ?? 'FontWeight.w400').replaceFirst(
        'FontWeight.w',
        '',
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _TokenHeader(token: token),
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: StudioColors.sidebar,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            'Aa Quick brown fox',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: StudioColors.text,
              fontSize: (size ?? 14).clamp(8, 28),
              fontWeight: weight == null
                  ? FontWeight.w400
                  : FontWeight.values[(weight ~/ 100 - 1).clamp(0, 8)],
              letterSpacing: double.tryParse(
                token.arg('letterSpacing')?.value ?? '',
              ),
              fontFamily: token
                  .arg('fontFamily')
                  ?.value
                  .replaceAll("'", '')
                  .replaceAll('"', ''),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 10,
          runSpacing: 6,
          children: [
            _argField('size', 'fontSize', width: 56),
            _weightField(weight),
            _argField('height', 'height', width: 56),
            _argField('spacing', 'letterSpacing', width: 56),
            if (token.arg('fontFamily') != null)
              _argField('family', 'fontFamily', width: 110),
          ],
        ),
      ],
    );
  }

  Widget _argField(String label, String arg, {required double width}) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(label, style: StudioText.muted),
      const SizedBox(width: 6),
      StudioField(
        width: width,
        value: token.arg(arg)?.value ?? '',
        onCommit: (text) {
          if (text.trim().isEmpty) return;
          controller.setTokenArg(token, arg, text.trim());
        },
      ),
    ],
  );

  Widget _weightField(int? weight) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text('weight', style: StudioText.muted),
      const SizedBox(width: 6),
      Container(
        height: 26,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        decoration: BoxDecoration(
          color: StudioColors.sidebar,
          borderRadius: BorderRadius.circular(5),
          border: Border.all(color: StudioColors.border),
        ),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<int>(
            value: _weights.contains(weight) ? weight : null,
            hint: Text('–', style: StudioText.mono),
            isDense: true,
            dropdownColor: StudioColors.panel,
            style: StudioText.mono,
            iconSize: 14,
            items: [
              for (final w in _weights)
                DropdownMenuItem(value: w, child: Text('w$w')),
            ],
            onChanged: (w) {
              if (w != null) {
                controller.setTokenArg(token, 'fontWeight', 'FontWeight.w$w');
              }
            },
          ),
        ),
      ),
    ],
  );
}

class _OtherRow extends StatelessWidget {
  const _OtherRow({required this.token});

  final DesignToken token;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _TokenHeader(token: token),
      const SizedBox(height: 4),
      Text(
        token.source,
        style: StudioText.monoMuted,
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
      ),
    ],
  );
}
