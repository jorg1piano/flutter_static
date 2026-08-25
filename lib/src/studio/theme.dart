import 'package:flutter/widgets.dart';

/// Studio's own look. Dark, quiet, so the user's renders are the colour.
abstract final class StudioColors {
  static const sidebar = Color(0xFF1B1C1F);
  static const panel = Color(0xFF202124);
  static const canvas = Color(0xFF2A2B2F);
  static const canvasDot = Color(0xFF36373C);
  static const border = Color(0xFF34363B);
  static const raised = Color(0xFF2C2E33);
  static const hover = Color(0xFF34363C);
  static const text = Color(0xFFE8E8EA);
  static const muted = Color(0xFF9A9DA4);
  static const faint = Color(0xFF6C6F76);
  static const accent = Color(0xFF7C9CFF);
  static const accentSoft = Color(0x337C9CFF);
  static const ok = Color(0xFF4ADE80);
  static const warn = Color(0xFFFBBF24);
  static const bad = Color(0xFFF87171);
}

abstract final class StudioText {
  static const body = TextStyle(
    color: StudioColors.text,
    fontSize: 12.5,
    height: 1.3,
  );
  static const muted = TextStyle(
    color: StudioColors.muted,
    fontSize: 12,
    height: 1.3,
  );
  static const section = TextStyle(
    color: StudioColors.faint,
    fontSize: 10.5,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.8,
    height: 1.3,
  );
  static const title = TextStyle(
    color: StudioColors.text,
    fontSize: 13.5,
    fontWeight: FontWeight.w600,
    height: 1.3,
  );
  static const mono = TextStyle(
    color: StudioColors.text,
    fontSize: 11.5,
    fontFamily: 'Menlo',
    height: 1.35,
  );
  static const monoMuted = TextStyle(
    color: StudioColors.muted,
    fontSize: 11,
    fontFamily: 'Menlo',
    height: 1.35,
  );
}
