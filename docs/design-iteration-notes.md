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
   strip. Exact Chrome geometry: with zero-width side borders the whole corner
   belongs to the top border, and the painted region is the area between the
   outer circular arc (r) and an inner *elliptical* arc (rx = r, ry = r - t),
   so the border is t thick at the top and tapers to zero exactly where the
   sides begin. Implemented as a filled Path in a custom BoxPainter; verified
   pixel-identical to the reference (straight run diff 0, corners AA-only).
7. **CSS `linear-gradient(135deg, ...)` is not `Alignment.topLeft ->
   bottomRight`** on non-square boxes (angle vs corner semantics). Visually
   negligible here; left as-is.
8. **`dart run flutter_static ...` pays ~1-2s JIT startup per invocation.**
   Fine interactively, noticeable in scripted loops. `dart compile exe` or a
   resident mode would remove it.
9. Diff-metric caveat: mean pixel diff rewards misaligned-but-blurry over
   crisp-but-one-word-different; it dropped when wraps were wrong and rose
   when they were fixed. Use it to find regions, not as the target.

## Round 2 (Legg til bilde-kort), two more systematic converters

10. **Material's DefaultTextStyle leaks `height: 1.43` into every Text that
    doesn't set its own height** (style merge via `inherit: true`). An 11px
    label becomes 15.7px tall instead of Inter's natural 13.3, shifting every
    row below it. CSS `line-height: normal` for Inter = 1.21; set
    `height: 1.21` explicitly on any text the CSS leaves at normal.
11. **Flutter's `height` multiplier distributes extra leading proportionally
    (glyphs sink); CSS splits it half above, half below.** Add
    `leadingDistribution: TextLeadingDistribution.even` to every style that
    sets `height` when matching CSS.
12. **An icon `<span>` in a flex row occupies fontSize x ~1.222 (Material
    Symbols line box), not fontSize** - and that sets the row height. An 18px
    icon made Chrome's chip 44px tall where Flutter's exact 18px `Icon` gave
    40. Wrap `Icon` in `SizedBox(height: size * 1.222)` where the icon is the
    tallest row child.
13. **CSS default `box-sizing: content-box` bites on fixed widths**:
    `width: 346 + padding: 15` is a 376px-wide card; `76px + 2px dashed
    border` is an 80px avatar. Translate outer sizes, not the CSS numbers.
14. Tracking corrections are per-style and non-linear across font sizes
    (Chrome's variable-font optical sizing): measure per band with the
    shift-correlation script rather than scaling one value by em.

## Round 3 (Torget widgets), operational notes

15. **Outer widths can differ per card inside one design file**: padded
    content-box cards (378 + 15px padding) are 408 outer while an unpadded
    card is 378. Check each card's own padding before sizing the story.
16. **The diff floor scales with bold-text density**: a card dominated by a
    21px Black title floors at ~4.4/255 while sparse cards floor at ~2.3.
    Confirm suspicious cards by zooming glyph crops before chasing ghosts;
    positions can be pixel-identical while the amplified heatmap looks red.
17. Reference screenshots are only as good as their font loading: give
    headless Chrome a generous --virtual-time-budget and re-shoot before
    debugging a "wider text" mismatch. (One case here turned out to be an
    amplified-AA illusion, but the check is cheap.)
18. Small design-project assets (this avatar was 2.8KB) fetch fine through
    DesignSync base64; only large binaries hit the 256KiB truncation.

## Round 4 (Ferdig-kort), flex translation bug + ops traps

19. **CSS `margin-left: auto` must translate to a single Expanded, never
    Flexible + Spacer.** Two flex children split the free space by factor;
    a loose-fit Flexible's unused allocation is NOT redistributed - it ends
    up after the last child (MainAxisAlignment.start), so the "pinned right"
    text lands mid-row. The status-line clock sat 98 logical px left of the
    edge while the story's mean diff read 0.60/255 - a small displaced text
    patch dilutes below both the mean floor and the 8/255 band flag. The
    amplified heatmap showed the glyphs twice; band means alone would never
    have caught it. Always eyeball the heatmap.
20. Round-4 tracking corrections (static Inter vs Chrome variable):
    body 13px/w400: -0.05 (wrap flips somewhere in (-0.10, -0.05]; measure
    by watching where line 2 starts, the band-end numbers can mislead) ·
    button 15.5px/w800: -0.15 (interpolated from ink widths at -0.31 and 0) ·
    receipt values 15px/w800: -0.2. Positive design trackings (.06em, .08em
    on 10.5/9.5px labels) translate exactly; no correction needed.
21. **Chrome renders 13px/line-height-1.5 body ink 1 logical px lower than
    Flutter's even leading distribution predicts**, and switching the style
    to proportional distribution changes nothing (measured ink identical).
    Block positions before/after the paragraph still match exactly, so it's
    Chrome's within-line-box baseline rounding. Accepted: 1px, invisible in
    crops, worth ~2/255 on the story mean.
22. **CSS `border-left` on a rounded box is the border-top wedge rotated**:
    both left corners belong to the left border, painted between the outer
    circular arc (r) and an inner elliptical arc (rx = r - t, ry = r).
    `CssLeftBorder` in ui_library, same construction as `CssTopBorder`.
    Layout-wise the 3px border adds to padding-left (content-box).
23. **Ops trap: a stale catalog app from an earlier session holds :8474.**
    The new runner's server dies on bind ("Address already in use" scrolls
    by in the log) while its app and hot reload run fine - so renders hit
    the zombie serving old code and edits "don't apply". Kill port holders
    (`lsof -ti tcp:8474 | xargs kill`) before `flutter_static run`.
24. **The runner can silently lose its app** ("Lost connection to device"
    mid-session); the server keeps answering but subsequent edits stop
    landing. If a render stops reflecting saves, check the run log tail and
    restart the runner.
