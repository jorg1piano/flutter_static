# Design iteration test: Sendi popup cards

First real dogfood of the flutter_static loop (2026-08-23): implement the three
popup cards from the Claude Design project (`Popup.dc.html`) pixel-perfect in
Flutter, iterating render-diff-fix against Chrome reference screenshots.

Result: all three cards (help, danger, permission) visually indistinguishable
from the reference at 2x except for known glyph-set differences. Mean absolute
pixel diff ~3-4/255, which is the rasterizer floor (see below). Widgets live in
`flutter_static_test_app/packages/ui_library/lib/src/sendi_popup.dart`.

## Loop mechanics that worked

- `dart run flutter_static run` + the built-in watcher: every edit hot reloaded
  in ~0.5s across path deps without manual signals. Zero babysitting.
- Iteration cycle (edit, render 3 stories, numeric diff + heatmap) ~15s.
- Headless Chrome (`--headless --screenshot --force-device-scale-factor=2`)
  produced deterministic 2x references that align 1:1 with flutter_static's
  2x renders. Better than the browser extension for this job.
- A diff heatmap (abs-diff overlay) plus per-band horizontal shift measurement
  located every discrepancy class: wrap, tracking, border shape, glyph shape.

## Issues found, in order

1. **DesignSync `get_file` caps at 256KiB** and silently truncates binary
   assets (`truncated: true`). Both map images in the project were unusable;
   the permission card uses a procedural stand-in. Pixel-perfect image areas
   need an asset export path.
2. **Chrome extension wasn't connected**; headless Chrome CLI was the fallback
   and turned out preferable (deterministic sizing/DPR).
3. **pubspec.yaml changes (font assets) need a full runner restart.** Hot
   reload and hot restart don't pick up new assets. The CLI should watch
   pubspec.yaml and restart the child process automatically.
4. **Google Fonts serves InterVariable; bundling static Inter TTFs gives
   slightly wider tracking.** Line wraps broke one word earlier in two texts.
   Fixed wrap parity with small negative letterSpacing per style:
   body 14px: -0.25 · chip 12.5px: -0.15 · big button 16px/w800: -0.32 ·
   flat button 14.5px/w700: -0.25 · email 14.5px/w700: -0.3 ·
   title 21px/w900: -0.63 (= the design's -0.03em, correct as-is).
   Residual sub-pixel drift within lines is shaping/AA-level and not worth
   chasing; wrap parity is the right target when comparing across text stacks.
5. **Material Icons (Flutter built-in) is not Material Symbols Rounded.**
   `block` has a mirrored slash, `mail` is filled vs outline; `help`,
   `star_half`, `my_location`, `arrow_outward` match closely. True glyph parity
   requires bundling the Material Symbols Rounded font and mapping codepoints.
6. **CSS `border-top` on a rounded box is a tapered wedge**, not a straight
   strip: it wraps the top corner arcs to ~45 deg. Implemented as a custom
   BoxPainter stroking the top path; a plain 2px Container reads clearly wrong.
7. **CSS `linear-gradient(135deg, ...)` is not `Alignment.topLeft ->
   bottomRight`** on non-square boxes (angle vs corner semantics). Visually
   negligible here; left as-is.
8. **`dart run flutter_static ...` pays ~1-2s JIT startup per invocation.**
   Fine interactively, noticeable in scripted loops. `dart compile exe` or a
   resident mode would remove it.
9. Diff-metric caveat: mean pixel diff rewards misaligned-but-blurry over
   crisp-but-one-word-different; it dropped when wraps were wrong and rose
   when they were fixed. Use it to find regions, not as the target.
