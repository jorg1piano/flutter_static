"""Ink runs along y (text lines, rules, boxes) in a vertical band of two
images, side by side. Answers "which line moved".

Usage: python3 rows.py <a.png> <b.png> x0 x1 [gap]

x0/x1 are PNG pixel columns (2x for catalog renders). Ink is anything more
than 40 levels away from the band's median; runs closer than `gap` px
(default 2) merge into one line.
"""
import sys
import numpy as np
from PIL import Image

if len(sys.argv) < 5:
    sys.exit(f'usage: python3 rows.py <a.png> <b.png> x0 x1 [gap]')
a, b, x0, x1 = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
gap = int(sys.argv[5]) if len(sys.argv) > 5 else 2


def runs(path):
    img = np.asarray(Image.open(path).convert('L')).astype(int)
    band = img[:, x0:x1]
    bg = np.median(band)
    ink = (np.abs(band - bg) > 40).any(axis=1)
    out, start, last = [], None, None
    for y, v in enumerate(ink):
        if v and start is None:
            start = y
        if v:
            last = y
        if not v and start is not None and y - last > gap:
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
    ha = (sa[1] - sa[0] + 1) if sa else 0
    hb = (sb[1] - sb[0] + 1) if sb else 0
    print(f'{str(sa):>14s} h{ha:4d}   |   {str(sb):>14s} h{hb:4d}')
