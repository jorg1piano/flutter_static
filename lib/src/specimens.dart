/// Built-in story widgets for showing design tokens: colour swatches, a
/// type scale, spacing and radius scales. A design system's `tokens/`
/// stories put these on the canvas so the tokens are visible next to the
/// components that use them.
///
/// ```dart
/// Story('tokens/colors', () => ColorSwatches(colors: {
///   'primary': AppColors.primary,
///   'surface': AppColors.surface,
/// }));
/// ```
///
/// Only `flutter/widgets`: no Material theme is needed around them.
library;

import 'package:flutter/widgets.dart';

/// Colours and font of the specimen sheets themselves.
class SpecimenStyle {
  const SpecimenStyle({
    required this.background,
    required this.foreground,
    required this.muted,
    required this.border,
    this.fontFamily,
    this.monoFamily = 'Menlo',
  });

  final Color background;
  final Color foreground;
  final Color muted;
  final Color border;
  final String? fontFamily;
  final String monoFamily;

  static const light = SpecimenStyle(
    background: Color(0xFFFFFFFF),
    foreground: Color(0xFF111827),
    muted: Color(0xFF6B7280),
    border: Color(0x14000000),
  );

  static const dark = SpecimenStyle(
    background: Color(0xFF16181D),
    foreground: Color(0xFFF3F4F6),
    muted: Color(0xFF9CA3AF),
    border: Color(0x1FFFFFFF),
  );

  TextStyle get label => TextStyle(
    color: foreground,
    fontSize: 12,
    fontWeight: FontWeight.w600,
    fontFamily: fontFamily,
    height: 1.3,
  );

  TextStyle get meta => TextStyle(
    color: muted,
    fontSize: 11,
    fontFamily: monoFamily,
    height: 1.3,
  );

  TextStyle get title => TextStyle(
    color: foreground,
    fontSize: 14,
    fontWeight: FontWeight.w700,
    fontFamily: fontFamily,
    letterSpacing: 0.2,
  );
}

/// A sheet: padding, background and an optional title over [child].
class Specimen extends StatelessWidget {
  const Specimen({
    super.key,
    required this.child,
    this.title,
    this.style = SpecimenStyle.light,
    this.padding = const EdgeInsets.all(24),
    this.width,
  });

  final Widget child;
  final String? title;
  final SpecimenStyle style;
  final EdgeInsets padding;
  final double? width;

  @override
  Widget build(BuildContext context) => Container(
    width: width,
    padding: padding,
    color: style.background,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (title != null) ...[
          Text(title!, style: style.title),
          const SizedBox(height: 16),
        ],
        child,
      ],
    ),
  );
}

/// A grid of colour swatches, each with its name and hex value.
class ColorSwatches extends StatelessWidget {
  const ColorSwatches({
    super.key,
    required this.colors,
    this.title,
    this.columns = 4,
    this.swatchSize = const Size(112, 64),
    this.gap = 16,
    this.style = SpecimenStyle.light,
  });

  final Map<String, Color> colors;
  final String? title;
  final int columns;
  final Size swatchSize;
  final double gap;
  final SpecimenStyle style;

  @override
  Widget build(BuildContext context) => Specimen(
    title: title,
    style: style,
    child: SizedBox(
      width: columns * swatchSize.width + (columns - 1) * gap,
      child: Wrap(
        spacing: gap,
        runSpacing: gap,
        children: [
          for (final entry in colors.entries)
            _Swatch(
              name: entry.key,
              color: entry.value,
              size: swatchSize,
              style: style,
            ),
        ],
      ),
    ),
  );
}

class _Swatch extends StatelessWidget {
  const _Swatch({
    required this.name,
    required this.color,
    required this.size,
    required this.style,
  });

  final String name;
  final Color color;
  final Size size;
  final SpecimenStyle style;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: size.width,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          height: size.height,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: style.border),
          ),
          clipBehavior: Clip.antiAlias,
          child: CustomPaint(
            painter: _CheckerPainter(color),
            child: const SizedBox.expand(),
          ),
        ),
        const SizedBox(height: 8),
        Text(name, style: style.label, overflow: TextOverflow.ellipsis),
        Text(hexOf(color), style: style.meta),
      ],
    ),
  );
}

/// `#4F46E5`, alpha first when it is not opaque.
String hexOf(Color color) {
  final hex = color.toARGB32().toRadixString(16).toUpperCase().padLeft(8, '0');
  return '#${hex.startsWith('FF') ? hex.substring(2) : hex}';
}

/// Paints a checkerboard under a translucent colour so alpha shows.
class _CheckerPainter extends CustomPainter {
  const _CheckerPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (color.a < 1) {
      const cell = 8.0;
      final light = Paint()..color = const Color(0xFFFFFFFF);
      final dark = Paint()..color = const Color(0xFFD1D5DB);
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

/// One row per text style: its name and metrics in a fixed left column,
/// [sample] set in the style on the right.
class TypeSpecimen extends StatelessWidget {
  const TypeSpecimen({
    super.key,
    required this.styles,
    this.title,
    this.sample = 'The quick brown fox jumps over the lazy dog',
    this.width = 560,
    this.labelWidth = 128,
    this.style = SpecimenStyle.light,
  });

  final Map<String, TextStyle> styles;
  final String? title;
  final String sample;
  final double width;
  final double labelWidth;
  final SpecimenStyle style;

  @override
  Widget build(BuildContext context) => Specimen(
    title: title,
    style: style,
    width: width,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final (i, entry) in styles.entries.indexed) ...[
          if (i > 0)
            Container(
              height: 1,
              margin: const EdgeInsets.symmetric(vertical: 14),
              color: style.border,
            ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: labelWidth,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(entry.key, style: style.label),
                    Text(_metrics(entry.value), style: style.meta),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  sample,
                  style: entry.value.copyWith(
                    color: entry.value.color ?? style.foreground,
                  ),
                ),
              ),
            ],
          ),
        ],
      ],
    ),
  );

  static String _metrics(TextStyle s) {
    final parts = <String>[];
    if (s.fontSize != null) {
      final size = _short(s.fontSize!);
      parts.add(
        s.height == null ? size : '$size/${_short(s.fontSize! * s.height!)}',
      );
    }
    if (s.fontWeight != null) parts.add('w${s.fontWeight!.value}');
    if (s.letterSpacing != null && s.letterSpacing != 0) {
      parts.add('${_short(s.letterSpacing!)}ls');
    }
    if (s.fontFamily != null) parts.add(s.fontFamily!);
    return parts.join(' · ');
  }
}

String _short(double v) =>
    v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(2);

/// One row per spacing value: name, value and a bar that long.
class SpacingScale extends StatelessWidget {
  const SpacingScale({
    super.key,
    required this.values,
    this.title,
    this.color = const Color(0xFF6366F1),
    this.labelWidth = 96,
    this.style = SpecimenStyle.light,
  });

  final Map<String, double> values;
  final String? title;
  final Color color;
  final double labelWidth;
  final SpecimenStyle style;

  @override
  Widget build(BuildContext context) => Specimen(
    title: title,
    style: style,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final (i, entry) in values.entries.indexed) ...[
          if (i > 0) const SizedBox(height: 10),
          Row(
            children: [
              SizedBox(
                width: labelWidth,
                child: Text(entry.key, style: style.label),
              ),
              SizedBox(
                width: 40,
                child: Text(_short(entry.value), style: style.meta),
              ),
              Container(
                width: entry.value,
                height: 16,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ],
          ),
        ],
      ],
    ),
  );
}

/// One box per radius, cornered accordingly.
class RadiusScale extends StatelessWidget {
  const RadiusScale({
    super.key,
    required this.radii,
    this.title,
    this.boxSize = 72,
    this.gap = 16,
    this.fill = const Color(0xFFE0E7FF),
    this.stroke = const Color(0xFF6366F1),
    this.style = SpecimenStyle.light,
  });

  final Map<String, double> radii;
  final String? title;
  final double boxSize;
  final double gap;
  final Color fill;
  final Color stroke;
  final SpecimenStyle style;

  @override
  Widget build(BuildContext context) => Specimen(
    title: title,
    style: style,
    child: Wrap(
      spacing: gap,
      runSpacing: gap,
      children: [
        for (final entry in radii.entries)
          SizedBox(
            width: boxSize,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: boxSize,
                  height: boxSize,
                  decoration: BoxDecoration(
                    color: fill,
                    border: Border.all(color: stroke, width: 1.5),
                    borderRadius: BorderRadius.circular(
                      entry.value.clamp(0, boxSize / 2),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  entry.key,
                  style: style.label,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(_short(entry.value), style: style.meta),
              ],
            ),
          ),
      ],
    ),
  );
}
