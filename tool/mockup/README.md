# PhoneMockup geometry

`PhoneMockup` takes its proportions from `docs/reference/phone.png`
(a 327x611 photo with a 243x527 screen). To check a change:

1. Add a story rendering `PhoneMockup(screenSize: Size(121.5, 263.5),
   child: Container(color: Colors.white))`; the catalog's 2x png then
   matches the reference pixel for pixel.
2. `python3 tool/mockup/measure.py docs/reference/phone.png` prints the
   measured boxes and radii.
3. `python3 tool/mockup/shapediff.py docs/reference/phone.png render.png
   diff.png` classifies pixels (background / rim / dark / screen), aligns on
   the body, and reports mismatches beyond a 1px tolerance; red in
   `diff.png` marks them. The photo's anti-aliased edges are ignored.

Needs `numpy`, `Pillow`, `scipy`.
