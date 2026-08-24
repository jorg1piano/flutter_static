import 'package:flutter/widgets.dart';

/// A phone around a screen-sized [child]: rim, bezel, side buttons, and the
/// notch painted over the top of the content, which runs under it as on the
/// device.
///
/// Geometry is measured from a reference photo with a 243x527 screen and
/// scales uniformly with [screenSize]'s width, so any size keeps the shape.
class PhoneMockup extends StatelessWidget {
  const PhoneMockup({
    super.key,
    required this.child,
    this.screenSize = const Size(390, 846),
    this.rim = const Color(0xFF4982B2),
    this.bezel = const Color(0xFF000000),
  });

  final Widget child;

  /// Logical size of the screen area the child is laid out in.
  final Size screenSize;

  final Color rim;
  final Color bezel;

  /// Reference measurements, in pixels of a 243-wide screen.
  static const _refScreenWidth = 243.0;
  static const _frame = 13.5; // rim + bezel, each side
  static const _rim = 3.5;
  static const _outerRadius = 44.0;
  static const _screenRadius = 30.0;
  static const _notch = Size(101, 21);
  static const _notchRadius = 9.0;
  static const _fillet = 2.0;
  static const _camera = Offset(14.5, 7); // from the notch's top-left
  static const _cameraDiameter = 4.0;
  static const _buttonDepth = 2.0;
  // (top, height) as fractions of the body height; left: mute, volume up,
  // volume down; right: power.
  static const _leftButtons = [
    (0.2018, 0.0378),
    (0.2739, 0.0739),
    (0.3694, 0.0739),
  ];
  static const _rightButtons = [(0.2973, 0.1225)];

  double get _s => screenSize.width / _refScreenWidth;

  /// The size the widget takes, buttons included.
  Size get size => Size(
    screenSize.width + 2 * (_frame + _buttonDepth) * _s,
    screenSize.height + 2 * _frame * _s,
  );

  @override
  Widget build(BuildContext context) {
    final s = _s;
    final frame = _frame * s;
    final depth = _buttonDepth * s;
    final notch = _notch * s;
    final notchTop = _camera.dy * s + _cameraDiameter * s; // status inset
    return SizedBox(
      width: size.width,
      height: size.height,
      child: Stack(
        children: [
          Positioned.fill(
            child: CustomPaint(
              painter: _BodyPainter(scale: s, rim: rim, bezel: bezel),
            ),
          ),
          Positioned(
            left: depth + frame,
            top: frame,
            width: screenSize.width,
            height: screenSize.height,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(_screenRadius * s),
              child: MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  size: screenSize,
                  padding: EdgeInsets.only(
                    top: notch.height > notchTop ? notch.height : notchTop,
                  ),
                ),
                child: SizedBox(
                  width: screenSize.width,
                  height: screenSize.height,
                  child: child,
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: _NotchPainter(scale: s, color: bezel),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BodyPainter extends CustomPainter {
  const _BodyPainter({
    required this.scale,
    required this.rim,
    required this.bezel,
  });

  final double scale;
  final Color rim;
  final Color bezel;

  @override
  void paint(Canvas canvas, Size size) {
    final s = scale;
    final depth = PhoneMockup._buttonDepth * s;
    final body = Rect.fromLTWH(depth, 0, size.width - 2 * depth, size.height);
    final rimPaint = Paint()..color = rim;
    // Buttons sit behind the body and stick out by their depth.
    for (final (top, height) in PhoneMockup._leftButtons) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(0, body.height * top, depth * 2, body.height * height),
          Radius.circular(depth / 2),
        ),
        rimPaint,
      );
    }
    for (final (top, height) in PhoneMockup._rightButtons) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            size.width - depth * 2,
            body.height * top,
            depth * 2,
            body.height * height,
          ),
          Radius.circular(depth / 2),
        ),
        rimPaint,
      );
    }
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        body,
        Radius.circular(PhoneMockup._outerRadius * s),
      ),
      rimPaint,
    );
    final inset = PhoneMockup._rim * s;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        body.deflate(inset),
        Radius.circular((PhoneMockup._outerRadius - PhoneMockup._rim) * s),
      ),
      Paint()..color = bezel,
    );
  }

  @override
  bool shouldRepaint(_BodyPainter old) =>
      old.scale != scale || old.rim != rim || old.bezel != bezel;
}

class _NotchPainter extends CustomPainter {
  const _NotchPainter({required this.scale, required this.color});

  final double scale;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final s = scale;
    final frame = PhoneMockup._frame * s;
    final depth = PhoneMockup._buttonDepth * s;
    final screenLeft = depth + frame;
    final screenWidth = size.width - 2 * screenLeft;
    final w = PhoneMockup._notch.width * s;
    final h = PhoneMockup._notch.height * s;
    final r = PhoneMockup._notchRadius * s;
    final f = PhoneMockup._fillet * s;
    final left = screenLeft + (screenWidth - w) / 2;
    final top = frame;
    // Rounded bottom corners, concave fillets into the bezel at the top.
    final path = Path()
      ..moveTo(left - f, top)
      ..arcToPoint(
        Offset(left, top + f),
        radius: Radius.circular(f),
        clockwise: false,
      )
      ..lineTo(left, top + h - r)
      ..arcToPoint(
        Offset(left + r, top + h),
        radius: Radius.circular(r),
        clockwise: false,
      )
      ..lineTo(left + w - r, top + h)
      ..arcToPoint(
        Offset(left + w, top + h - r),
        radius: Radius.circular(r),
        clockwise: false,
      )
      ..lineTo(left + w, top + f)
      ..arcToPoint(
        Offset(left + w + f, top),
        radius: Radius.circular(f),
        clockwise: false,
      )
      ..close();
    canvas.drawPath(path, Paint()..color = color);
    canvas.drawCircle(
      Offset(
        left + PhoneMockup._camera.dx * s,
        top + PhoneMockup._camera.dy * s,
      ),
      PhoneMockup._cameraDiameter * s / 2,
      Paint()..color = const Color(0xFF2E3238),
    );
  }

  @override
  bool shouldRepaint(_NotchPainter old) =>
      old.scale != scale || old.color != color;
}
