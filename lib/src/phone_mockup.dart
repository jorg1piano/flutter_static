import 'package:flutter/widgets.dart';

/// A device's geometry, in pixels of a reference photo's screen width, plus
/// its logical screen size. Scaled uniformly with the screen width.
class PhoneSpec {
  const PhoneSpec({
    required this.name,
    required this.label,
    required this.screenSize,
    required this.refScreenWidth,
    required this.frame,
    required this.rim,
    required this.outerRadius,
    required this.screenRadius,
    required this.notch,
    required this.notchRadius,
    required this.fillet,
    required this.camera,
    required this.cameraDiameter,
    required this.buttonDepth,
    required this.leftButtons,
    required this.rightButtons,
    this.rimColor = const Color(0xFF4982B2),
    this.bezelColor = const Color(0xFF000000),
  });

  /// Slug used in URLs (`?device=`) and view data.
  final String name;
  final String label;

  /// Logical size of the screen the child is laid out in.
  final Size screenSize;

  final double refScreenWidth;
  final double frame; // rim + bezel, each side
  final double rim;
  final double outerRadius;
  final double screenRadius;
  final Size notch;
  final double notchRadius;
  final double fillet;
  final Offset camera; // from the notch's top-left
  final double cameraDiameter;
  final double buttonDepth;
  // (top, height) as fractions of the body height.
  final List<(double, double)> leftButtons;
  final List<(double, double)> rightButtons;
  final Color rimColor;
  final Color bezelColor;

  /// Measured from docs/reference/phone.png (tool/mockup).
  static const iphone13 = PhoneSpec(
    name: 'iphone-13',
    label: 'iPhone 13',
    screenSize: Size(390, 844),
    refScreenWidth: 243,
    frame: 13.5,
    rim: 3.5,
    outerRadius: 44,
    screenRadius: 30,
    notch: Size(101, 21),
    notchRadius: 9,
    fillet: 2,
    camera: Offset(14.5, 7),
    cameraDiameter: 4,
    buttonDepth: 2,
    leftButtons: [(0.2018, 0.0378), (0.2739, 0.0739), (0.3694, 0.0739)],
    rightButtons: [(0.2973, 0.1225)],
  );

  /// Provisional: the 13's proportions at the mini's screen size, until a
  /// reference photo is measured.
  static const iphone12mini = PhoneSpec(
    name: 'iphone-12-mini',
    label: 'iPhone 12 mini',
    screenSize: Size(375, 812),
    refScreenWidth: 243,
    frame: 13.5,
    rim: 3.5,
    outerRadius: 44,
    screenRadius: 30,
    notch: Size(101, 21),
    notchRadius: 9,
    fillet: 2,
    camera: Offset(14.5, 7),
    cameraDiameter: 4,
    buttonDepth: 2,
    leftButtons: [(0.2018, 0.0378), (0.2739, 0.0739), (0.3694, 0.0739)],
    rightButtons: [(0.2973, 0.1225)],
  );

  static const all = [iphone13, iphone12mini];
  static const fallback = iphone13;

  static PhoneSpec? byName(String? name) {
    for (final spec in all) {
      if (spec.name == name) return spec;
    }
    return null;
  }
}

/// The device pages and renders ask for; read by [phoneMockupFrame].
class DeviceScope extends InheritedWidget {
  const DeviceScope({super.key, required this.spec, required super.child});

  final PhoneSpec spec;

  static PhoneSpec of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DeviceScope>()?.spec ??
      PhoneSpec.fallback;

  @override
  bool updateShouldNotify(DeviceScope old) => old.spec != spec;
}

/// A phone around a screen-sized [child]: rim, bezel, side buttons, and the
/// notch painted over the top of the content, which runs under it as on the
/// device. Geometry comes from [spec]; [screenSize] overrides its screen
/// size (a reference-scale render, say) keeping the proportions.
class PhoneMockup extends StatelessWidget {
  const PhoneMockup({
    super.key,
    required this.child,
    this.spec = PhoneSpec.iphone13,
    this.screenSize,
  });

  final Widget child;
  final PhoneSpec spec;
  final Size? screenSize;

  Size get _screen => screenSize ?? spec.screenSize;
  double get _s => _screen.width / spec.refScreenWidth;

  /// The size the widget takes, buttons included.
  Size get size => Size(
    _screen.width + 2 * (spec.frame + spec.buttonDepth) * _s,
    _screen.height + 2 * spec.frame * _s,
  );

  @override
  Widget build(BuildContext context) {
    final s = _s;
    final screen = _screen;
    final frame = spec.frame * s;
    final depth = spec.buttonDepth * s;
    final notch = spec.notch * s;
    return SizedBox(
      width: size.width,
      height: size.height,
      child: Stack(
        children: [
          Positioned.fill(
            child: CustomPaint(
              painter: _BodyPainter(spec: spec, scale: s),
            ),
          ),
          Positioned(
            left: depth + frame,
            top: frame,
            width: screen.width,
            height: screen.height,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(spec.screenRadius * s),
              child: MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  size: screen,
                  padding: EdgeInsets.only(top: notch.height),
                ),
                child: SizedBox(
                  width: screen.width,
                  height: screen.height,
                  child: child,
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: _NotchPainter(spec: spec, scale: s),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BodyPainter extends CustomPainter {
  const _BodyPainter({required this.spec, required this.scale});

  final PhoneSpec spec;
  final double scale;

  @override
  void paint(Canvas canvas, Size size) {
    final s = scale;
    final depth = spec.buttonDepth * s;
    final body = Rect.fromLTWH(depth, 0, size.width - 2 * depth, size.height);
    final rimPaint = Paint()..color = spec.rimColor;
    // Buttons sit behind the body and stick out by their depth.
    for (final (top, height) in spec.leftButtons) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(0, body.height * top, depth * 2, body.height * height),
          Radius.circular(depth / 2),
        ),
        rimPaint,
      );
    }
    for (final (top, height) in spec.rightButtons) {
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
      RRect.fromRectAndRadius(body, Radius.circular(spec.outerRadius * s)),
      rimPaint,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        body.deflate(spec.rim * s),
        Radius.circular((spec.outerRadius - spec.rim) * s),
      ),
      Paint()..color = spec.bezelColor,
    );
  }

  @override
  bool shouldRepaint(_BodyPainter old) =>
      old.scale != scale || old.spec != spec;
}

class _NotchPainter extends CustomPainter {
  const _NotchPainter({required this.spec, required this.scale});

  final PhoneSpec spec;
  final double scale;

  @override
  void paint(Canvas canvas, Size size) {
    final s = scale;
    final frame = spec.frame * s;
    final depth = spec.buttonDepth * s;
    final screenLeft = depth + frame;
    final screenWidth = size.width - 2 * screenLeft;
    final w = spec.notch.width * s;
    final h = spec.notch.height * s;
    final r = spec.notchRadius * s;
    final f = spec.fillet * s;
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
    canvas.drawPath(path, Paint()..color = spec.bezelColor);
    canvas.drawCircle(
      Offset(left + spec.camera.dx * s, top + spec.camera.dy * s),
      spec.cameraDiameter * s / 2,
      Paint()..color = const Color(0xFF2E3238),
    );
  }

  @override
  bool shouldRepaint(_NotchPainter old) =>
      old.scale != scale || old.spec != spec;
}
