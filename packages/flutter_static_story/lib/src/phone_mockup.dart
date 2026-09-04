import 'package:flutter/widgets.dart';

enum DeviceFormFactor { phone, tablet }

/// A device's geometry, in pixels of a reference image's screen width, plus
/// its logical screen size. Scaled uniformly with the screen width.
class DeviceSpec {
  const DeviceSpec({
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
    required this.safeArea,
    required this.keyboardHeight,
    this.formFactor = DeviceFormFactor.phone,
    this.islandTop,
    this.bezelCameraDiameter = 0,
    this.rimColor = const Color(0xFF4982B2),
    this.bezelColor = const Color(0xFF000000),
    this.homeIndicatorColor = const Color(0x99000000),
    this.keyboardColor = const Color(0xFFD1D5DB),
  });

  /// Slug used in URLs (`?device=`) and view data.
  final String name;
  final String label;
  final DeviceFormFactor formFactor;

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

  /// What the device reports as its safe area in portrait, logical px.
  /// Separate from the painted notch: the two are different things and
  /// need not match.
  final EdgeInsets safeArea;

  /// Height of the software keyboard, logical px, for keyboard mode.
  final double keyboardHeight;

  /// Diameter of a camera centered in the top bezel. Phones place their
  /// camera in [notch] instead.
  final double bezelCameraDiameter;

  final Color homeIndicatorColor;
  final Color keyboardColor;

  /// Dynamic Island devices: the cutout floats this far below the screen's
  /// top edge as a pill ([notch] gives its size). Null means a notch
  /// attached to the bezel.
  final double? islandTop;

  bool get hasIsland => islandTop != null;
  bool get hasCutout => notch.width > 0 && notch.height > 0;

  /// Measured from docs/reference/phone.png (tool/mockup).
  static const iphone13 = DeviceSpec(
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
    safeArea: EdgeInsets.only(top: 47, bottom: 34),
    keyboardHeight: 336,
  );

  /// Measured from a product photo of the 13 mini (same design as the 12
  /// mini): a 395x854 screen, 13px bezel and 8px rim, notch 160x33. The
  /// photo hides the left side behind a second phone, so the left buttons
  /// keep the 13's proportions.
  static const iphone12mini = DeviceSpec(
    name: 'iphone-12-mini',
    label: 'iPhone 12 mini',
    screenSize: Size(375, 812),
    refScreenWidth: 395,
    frame: 21,
    rim: 8,
    outerRadius: 71,
    screenRadius: 49,
    notch: Size(160, 33),
    notchRadius: 16,
    fillet: 3,
    camera: Offset(23, 11),
    cameraDiameter: 6.5,
    buttonDepth: 3.3,
    leftButtons: [(0.2018, 0.0378), (0.2739, 0.0739), (0.3694, 0.0739)],
    rightButtons: [(0.298, 0.114)],
    safeArea: EdgeInsets.only(top: 50, bottom: 34),
    keyboardHeight: 336,
    rimColor: Color(0xFFE9E7E1),
    bezelColor: Color(0xFF000000),
  );

  /// Body measured from a product render of the 17 Pro Max: a 451x979
  /// screen, 10px bezel and 9px rim. Its outer corner is light on light
  /// in the render and could not be fitted; it follows the screen's
  /// corner plus the frame.
  ///
  /// The island is the device's own: on the iPhone 17 Pro Max simulator
  /// (iOS 26.5) it is 125.3x36.7 pt with its top edge 14.0 pt down,
  /// centred, and the clock's centre line sits at 32.5 pt. Those are in
  /// screen points; the values here are the same in the render's 451-wide
  /// reference units (x 451/440), which is what [refScreenWidth] scales.
  static const iphone17ProMax = DeviceSpec(
    name: 'iphone-17-pro-max',
    label: 'iPhone 17 Pro Max',
    screenSize: Size(440, 956),
    refScreenWidth: 451,
    frame: 19,
    rim: 7,
    outerRadius: 89,
    screenRadius: 70,
    notch: Size(128.5, 37.5),
    islandTop: 14.4,
    notchRadius: 18.75,
    fillet: 0,
    camera: Offset(64.25, 18.75),
    cameraDiameter: 0,
    buttonDepth: 5,
    leftButtons: [(0.2055, 0.0431), (0.2857, 0.0705), (0.3796, 0.0734)],
    rightButtons: [(0.2828, 0.1086)],
    safeArea: EdgeInsets.only(top: 62, bottom: 34),
    keyboardHeight: 346,
    rimColor: Color(0xFFDADADC),
    bezelColor: Color(0xFF000000),
  );

  /// Screen geometry from the device (iPhone 14 Pro Max simulator, iOS
  /// 26.5): a 430x932 screen, island 125.3x36.7 pt with its top edge
  /// 11.3 pt down and the clock's centre line at 29.2 pt. The body is not
  /// from a render: the frame and rim are the 17 Pro Max's, which the
  /// 14's 3.2 mm side border also comes to at 6.0 pt/mm, and the screen
  /// corner is the 55 pt the 6.7" Pro models are documented with. Units
  /// are screen points ([refScreenWidth] is the screen width).
  static const iphone14ProMax = DeviceSpec(
    name: 'iphone-14-pro-max',
    label: 'iPhone 14 Pro Max',
    screenSize: Size(430, 932),
    refScreenWidth: 430,
    frame: 19,
    rim: 7,
    outerRadius: 74,
    screenRadius: 55,
    notch: Size(125.3, 36.7),
    islandTop: 11.3,
    notchRadius: 18.35,
    fillet: 0,
    camera: Offset(62.65, 18.35),
    cameraDiameter: 0,
    buttonDepth: 5,
    leftButtons: [(0.2055, 0.0431), (0.2857, 0.0705), (0.3796, 0.0734)],
    rightButtons: [(0.2828, 0.1086)],
    safeArea: EdgeInsets.only(top: 59, bottom: 34),
    keyboardHeight: 346,
    rimColor: Color(0xFF3C3C41),
    bezelColor: Color(0xFF000000),
  );

  /// iPad Pro 11-inch (4th generation). Its 2388x1668 physical display is
  /// 1194x834 logical pixels. The frame follows the body-to-display ratio;
  /// the small details are kept plain so the silhouette reads at any zoom.
  static const ipadPro11 = DeviceSpec(
    name: 'ipad-pro-11',
    label: 'iPad Pro 11-inch',
    formFactor: DeviceFormFactor.tablet,
    screenSize: Size(834, 1194),
    refScreenWidth: 834,
    frame: 46,
    rim: 2,
    outerRadius: 40,
    screenRadius: 18,
    notch: Size.zero,
    notchRadius: 0,
    fillet: 0,
    camera: Offset.zero,
    cameraDiameter: 0,
    bezelCameraDiameter: 5,
    buttonDepth: 3,
    leftButtons: [],
    rightButtons: [(0.055, 0.04)],
    safeArea: EdgeInsets.only(top: 24, bottom: 20),
    keyboardHeight: 398,
    rimColor: Color(0xFF8C8C91),
    bezelColor: Color(0xFF090909),
  );

  /// The first entry is what pages open on.
  static const all = [
    iphone17ProMax,
    iphone14ProMax,
    iphone13,
    iphone12mini,
    ipadPro11,
  ];
  static const fallback = iphone13;

  static DeviceSpec? byName(String? name) {
    for (final spec in all) {
      if (spec.name == name) return spec;
    }
    return null;
  }
}

/// The old name remains source-compatible for existing catalogs.
@Deprecated('Use DeviceSpec instead.')
typedef PhoneSpec = DeviceSpec;

/// The device pages and renders ask for; read by [deviceMockupFrame].
class DeviceScope extends InheritedWidget {
  const DeviceScope({
    super.key,
    required this.spec,
    this.keyboard = false,
    this.statusBar = false,
    required super.child,
  });

  final DeviceSpec spec;

  /// Whether mockups in this scope show the keyboard.
  final bool keyboard;

  /// Whether mockups in this scope paint the status bar.
  final bool statusBar;

  static DeviceSpec of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DeviceScope>()?.spec ??
      DeviceSpec.fallback;

  static bool keyboardOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DeviceScope>()?.keyboard ??
      false;

  static bool statusBarOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DeviceScope>()?.statusBar ??
      false;

  @override
  bool updateShouldNotify(DeviceScope old) =>
      old.spec != spec ||
      old.keyboard != keyboard ||
      old.statusBar != statusBar;
}

/// A device around a screen-sized [child]. Geometry comes from [spec];
/// [screenSize] overrides its screen size while keeping the proportions.
class DeviceMockup extends StatelessWidget {
  const DeviceMockup({
    super.key,
    required this.child,
    this.spec = DeviceSpec.iphone13,
    this.screenSize,
    this.keyboard = false,
    this.statusBar = false,
    this.statusBarColor = const Color(0xFF000000),
  });

  final Widget child;
  final DeviceSpec spec;
  final Size? screenSize;

  /// Paints the status bar (time, signal, Wi-Fi, battery) over the content
  /// in the status inset, either side of the cutout.
  final bool statusBar;
  final Color statusBarColor;

  /// Keyboard mode: the keyboard's height goes into viewInsets.bottom,
  /// padding.bottom drops to zero (viewPadding keeps it), and a flat
  /// placeholder keyboard is painted over the bottom of the screen.
  final bool keyboard;

  Size get _screen => screenSize ?? spec.screenSize;
  double get _s => _screen.width / spec.refScreenWidth;

  /// Logical-px values (safe area, keyboard, indicator) scale with an
  /// overridden screen size so reference-scale renders stay proportional.
  double get _k => _screen.width / spec.screenSize.width;

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
    final k = _k;
    final safe = spec.safeArea * k;
    final keyboardHeight = keyboard ? spec.keyboardHeight * k : 0.0;
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
                  padding: safe.copyWith(bottom: keyboard ? 0 : safe.bottom),
                  viewPadding: safe,
                  viewInsets: EdgeInsets.only(bottom: keyboardHeight),
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
                painter: _OverlayPainter(
                  spec: spec,
                  scale: s,
                  logicalScale: k,
                  keyboard: keyboard,
                  statusBar: statusBar,
                  statusBarColor: statusBarColor,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The old name remains source-compatible for existing catalogs.
@Deprecated('Use DeviceMockup instead.')
typedef PhoneMockup = DeviceMockup;

class _BodyPainter extends CustomPainter {
  const _BodyPainter({required this.spec, required this.scale});

  final DeviceSpec spec;
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
    if (spec.bezelCameraDiameter > 0) {
      canvas.drawCircle(
        Offset(body.center.dx, spec.frame * s / 2),
        spec.bezelCameraDiameter * s / 2,
        Paint()..color = const Color(0xFF2E3238),
      );
    }
  }

  @override
  bool shouldRepaint(_BodyPainter old) =>
      old.scale != scale || old.spec != spec;
}

/// Everything painted over the content: notch, camera, home indicator,
/// and the keyboard placeholder in keyboard mode.
class _OverlayPainter extends CustomPainter {
  const _OverlayPainter({
    required this.spec,
    required this.scale,
    required this.logicalScale,
    required this.keyboard,
    required this.statusBar,
    required this.statusBarColor,
  });

  final DeviceSpec spec;
  final double scale;
  final double logicalScale;
  final bool keyboard;
  final bool statusBar;
  final Color statusBarColor;

  static const _indicator = Size(134, 5);
  static const _indicatorBottomGap = 8.0;

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
    if (spec.hasIsland) {
      // A floating pill, fully rounded.
      final rect = Rect.fromLTWH(left, top + spec.islandTop! * s, w, h);
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, Radius.circular(h / 2)),
        Paint()..color = spec.bezelColor,
      );
    } else if (spec.hasCutout) {
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
      if (spec.cameraDiameter > 0) {
        canvas.drawCircle(
          Offset(left + spec.camera.dx * s, top + spec.camera.dy * s),
          spec.cameraDiameter * s / 2,
          Paint()..color = const Color(0xFF2E3238),
        );
      }
    }
    if (statusBar) {
      _paintStatusBar(canvas, screenLeft, screenWidth, top, left, w, h);
    }
    // Keyboard placeholder over the bottom of the screen.
    final k = logicalScale;
    final screenBottom = size.height - frame;
    final screenRadius = spec.screenRadius * s;
    if (keyboard) {
      final kb = Rect.fromLTRB(
        screenLeft,
        screenBottom - spec.keyboardHeight * k,
        screenLeft + screenWidth,
        screenBottom,
      );
      canvas.drawRRect(
        RRect.fromRectAndCorners(
          kb,
          bottomLeft: Radius.circular(screenRadius),
          bottomRight: Radius.circular(screenRadius),
        ),
        Paint()..color = spec.keyboardColor,
      );
    }
    // Home indicator, centered, a fixed gap above the bottom edge.
    final ind = Rect.fromCenter(
      center: Offset(
        screenLeft + screenWidth / 2,
        screenBottom - (_indicatorBottomGap + _indicator.height / 2) * k,
      ),
      width: _indicator.width * k,
      height: _indicator.height * k,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(ind, Radius.circular(ind.height / 2)),
      Paint()..color = spec.homeIndicatorColor,
    );
  }

  /// Time centered in the left ear, signal, Wi-Fi and battery in the right
  /// one, both on the cutout's vertical center, as iOS lays them out.
  void _paintStatusBar(
    Canvas canvas,
    double screenLeft,
    double screenWidth,
    double screenTop,
    double cutLeft,
    double cutWidth,
    double cutHeight,
  ) {
    final k = logicalScale;
    final s = scale;
    final centerY = spec.hasCutout
        ? screenTop + (spec.islandTop ?? 0) * s + cutHeight / 2
        : screenTop + spec.safeArea.top * k / 2;
    final leftCenter = spec.hasCutout
        ? (screenLeft + cutLeft) / 2
        : screenLeft + 54 * k;
    final rightCenter = spec.hasCutout
        ? (cutLeft + cutWidth + screenLeft + screenWidth) / 2
        : screenLeft + screenWidth - 54 * k;
    final paint = Paint()..color = statusBarColor;
    // Time.
    final text = TextPainter(
      text: TextSpan(
        text: '9:41',
        style: TextStyle(
          color: statusBarColor,
          fontSize: 17 * k,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.4 * k,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    text.paint(
      canvas,
      Offset(leftCenter - text.width / 2, centerY - text.height / 2),
    );
    // Icons, 17 + 16 + 27 wide with 6 between, centered in the right ear.
    final total = (17 + 6 + 16 + 6 + 27) * k;
    var x = rightCenter - total / 2;
    // Signal: four bars.
    for (var i = 0; i < 4; i++) {
      final barH = (4 + 2 * i) * k;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x + i * 4.5 * k, centerY + 5 * k - barH, 3 * k, barH),
          Radius.circular(1 * k),
        ),
        paint,
      );
    }
    x += (17 + 6) * k;
    // Wi-Fi: three arcs and a dot.
    final wifiCenter = Offset(x + 8 * k, centerY + 5 * k);
    final stroke = Paint()
      ..color = statusBarColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2 * k
      ..strokeCap = StrokeCap.round;
    for (final radius in [8.0, 5.0]) {
      canvas.drawArc(
        Rect.fromCircle(center: wifiCenter, radius: radius * k),
        -2.36,
        1.57,
        false,
        stroke,
      );
    }
    canvas.drawCircle(wifiCenter, 1.5 * k, paint);
    x += (16 + 6) * k;
    // Battery: outline, fill, nub.
    final body = Rect.fromLTWH(x, centerY - 6 * k, 24 * k, 12 * k);
    canvas.drawRRect(
      RRect.fromRectAndRadius(body, Radius.circular(3.5 * k)),
      Paint()
        ..color = statusBarColor.withValues(alpha: 0.4)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1 * k,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(body.deflate(2 * k), Radius.circular(2 * k)),
      paint,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(body.right + 1 * k, centerY - 2 * k, 1.5 * k, 4 * k),
        Radius.circular(1 * k),
      ),
      Paint()..color = statusBarColor.withValues(alpha: 0.4),
    );
  }

  @override
  bool shouldRepaint(_OverlayPainter old) =>
      old.scale != scale ||
      old.spec != spec ||
      old.logicalScale != logicalScale ||
      old.keyboard != keyboard ||
      old.statusBar != statusBar ||
      old.statusBarColor != statusBarColor;
}
