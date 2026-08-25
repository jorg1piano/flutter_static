"""Ink runs along x (words, glyph groups) in a horizontal band of two
images, side by side. Answers "which part of this row is off".

Usage: python3 segs.py <a.png> <b.png> y0 y1 [gap]

y0/y1 are PNG pixel rows (2x for catalog renders). Ink is anything more
than 40 levels away from the band's median; runs closer than `gap` px
(default 6) merge into one segment.
"""
import sys
import numpy as np
from PIL import Image

if len(sys.argv) < 5:
    sys.exit(f'usage: python3 segs.py <a.png> <b.png> y0 y1 [gap]')
a, b, y0, y1 = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
gap = int(sys.argv[5]) if len(sys.argv) > 5 else 6


def runs(path):
    img = np.asarray(Image.open(path).convert('L')).astype(int)
    band = img[y0:y1]
    bg = np.median(band)
    ink = (np.abs(band - bg) > 40).any(axis=0)
    out, start, last = [], None, None
    for x, v in enumerate(ink):
        if v and start is None:
            start = x
        if v:
            last = x
        if not v and start is not None and x - last > gap:
            out.append((start, last))
            start = None
    if start is not None:
        out.append((start, last))
    return out


ra, rb = runs(a), runs(b)
print(f'{"a":>14s} {"":>5s}   |   {"b":>14s}')
for i in range(max(len(ra), len(rb))):
    sa = ra[i] if i < len(ra) else None
    sb = rb[i] if i < len(rb) else None
    wa = (sa[1] - sa[0] + 1) if sa else 0
    wb = (sb[1] - sb[0] + 1) if sb else 0
    print(f'{str(sa):>14s} w{wa:4d}   |   {str(sb):>14s} w{wb:4d}')
