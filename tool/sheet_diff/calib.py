"""Tracking calibration: the same sample line per text style, set by
Chrome and by the catalog, and the letterSpacing that would make
Flutter's line as wide as Chrome's.

Three steps:
  python3 calib.py html --styles styles.json > calib.html
      then shoot it at 2x (shoot.js --targets body, or headless Chrome)
  python3 calib.py dart --styles styles.json
      paste the printed Story into story/main.dart, render it
  python3 calib.py measure ref.png render.png --styles styles.json
      one row per style: Chrome width, Flutter width, suggested spacing

styles.json is a list of styles the design uses, as
  [size, weight, letterSpacing, uppercase]  e.g. [12.5, 700, 0, false]
or objects {"size": 12.5, "weight": 700, "letterSpacing": 0, "upper": false}.

If the Flutter widths are ~3% wide at every size, the culprit is
TextStyle.letterSpacing: null, not the font: set 0 in the type scale
and measure again before applying per-style corrections.
"""
import argparse
import json

SAMPLE = 'Sjåføren har ikke bekreftet · Kari M. sendte 120 kr til Hamar 14:06'
DART_STYLE = ("TextStyle(fontFamily: '{font}', fontSize: {size}, "
              "fontWeight: FontWeight.w{weight}, letterSpacing: {ls}, height: 1)")


def load_styles(path):
    with open(path) as f:
        raw = json.load(f)
    out = []
    for s in raw:
        if isinstance(s, dict):
            out.append((s['size'], s['weight'], s.get('letterSpacing', 0), bool(s.get('upper', False))))
        else:
            size, weight, ls, upper = (list(s) + [0, False])[:4]
            out.append((size, weight, ls, bool(upper)))
    return out


def html(a, styles):
    rows = []
    for size, weight, ls, upper in styles:
        text = a.sample.upper() if upper else a.sample
        rows.append(
            f'<div style="height:{a.band}px;padding:0 20px;display:flex;align-items:center">'
            f'<span style="font:{weight} {size}px/1 {a.font};letter-spacing:{ls}px;'
            f'color:{a.fg};white-space:nowrap">{text}</span></div>'
        )
    link = ''
    if a.google_fonts:
        link = (f'<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family={a.font}'
                ':wght@400;500;600;700;800;900&display=swap">')
    print('<!DOCTYPE html><html><head><meta charset="utf-8">' + link +
          f'<style>body{{margin:0;background:{a.bg};width:{a.width}px}}</style></head><body>'
          + ''.join(rows) + '</body></html>')


def dart_color(css):
    return '0xFF' + css.lstrip('#').upper()


def dart(a, styles):
    print(f"  Story(\n    '{a.story}',\n    () => Container(\n      color: const Color({dart_color(a.bg)}),\n"
          f"      width: {a.width},\n      child: Column(\n        crossAxisAlignment: CrossAxisAlignment.start,\n"
          f"        children: [")
    for size, weight, ls, upper in styles:
        text = a.sample.upper() if upper else a.sample
        style = a.style_expr.format(font=a.font, size=size, weight=weight, ls=ls)
        print(f"          SizedBox(height: {a.band}, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 20), "
              f"child: Align(alignment: Alignment.centerLeft, child: Text('{text}', maxLines: 1, softWrap: false, "
              f"style: {style}.copyWith(color: const Color({dart_color(a.fg)})))))),")
    print('        ],\n      ),\n    ),\n  ),')


def measure(a, styles):
    import numpy as np
    from PIL import Image
    ref = np.asarray(Image.open(a.ref).convert('L')).astype(int)
    got = np.asarray(Image.open(a.render).convert('L')).astype(int)
    scale = a.dpr
    print(f'{"style":>18s} {"chrome":>7s} {"flutter":>7s} {"delta/char":>10s}  suggested letterSpacing')
    for i, (size, weight, ls, upper) in enumerate(styles):
        text = a.sample.upper() if upper else a.sample
        y0, y1 = int(i * a.band * scale), int((i + 1) * a.band * scale)

        def width(img):
            band = img[y0:y1]
            bg = np.median(band)
            cols = np.where((np.abs(band - bg) > 40).any(axis=0))[0]
            return (cols.max() - cols.min() + 1) / scale if len(cols) else 0

        wc, wf = width(ref), width(got)
        per = (wc - wf) / (len(text) - 1)
        flag = '  <- ~3% wide: letterSpacing null?' if wf and abs(wf / wc - 1.03) < 0.01 else ''
        print(f'{size:>5}/{weight:<3} ls{ls:<6} {wc:7.1f} {wf:7.1f} {per:10.3f}  -> {ls + per:.2f}{flag}')


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest='cmd', required=True)
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument('--styles', required=True)
    common.add_argument('--sample', default=SAMPLE)
    common.add_argument('--band', type=float, default=40, help='px per line at 1x')
    common.add_argument('--width', type=int, default=900)
    common.add_argument('--font', default='Inter')
    common.add_argument('--bg', default='#0A0B0D')
    common.add_argument('--fg', default='#E2E4E9')
    h = sub.add_parser('html', parents=[common]); h.add_argument('--google-fonts', action='store_true')
    d = sub.add_parser('dart', parents=[common])
    d.add_argument('--story', default='calib')
    d.add_argument('--style-expr', default=DART_STYLE,
                   help='Dart expression with {font} {size} {weight} {ls} placeholders')
    m = sub.add_parser('measure', parents=[common])
    m.add_argument('ref'); m.add_argument('render'); m.add_argument('--dpr', type=float, default=2)
    args = p.parse_args()
    {'html': html, 'dart': dart, 'measure': measure}[args.cmd](args, load_styles(args.styles))
