"""Compare catalog renders with reference screenshots.

For each (story, reference) pair: size check, mean absolute pixel
difference (0-255), the worst 16 logical px band, and a composite PNG
(reference | render | x4 heatmap) in --out.

Usage:
  python3 diff.py --ref DIR --out DIR [--port 8474] [--renders DIR]
                  (--pairs FILE | --pair STORY=REF.png ...) [STORY ...]

--pairs FILE   JSON object {story id: reference path relative to --ref}
--pair ID=REF  one pair on the command line (repeatable)
--renders DIR  read DIR/<story>.png instead of fetching from the catalog
               (story ids with slashes become files in subdirectories)
STORY ...      only compare these ids

Prints numbers first; open only the outliers' .cmp.png.
"""
import argparse
import io
import json
import os
import urllib.request

import numpy as np
from PIL import Image, ImageChops

BAND_PX = 32  # 16 logical px at 2x


def parse():
    p = argparse.ArgumentParser()
    p.add_argument('--ref', required=True)
    p.add_argument('--out', required=True)
    p.add_argument('--port', type=int, default=8474)
    p.add_argument('--renders')
    p.add_argument('--pairs')
    p.add_argument('--pair', action='append', default=[])
    p.add_argument('stories', nargs='*')
    a = p.parse_args()
    pairs = {}
    if a.pairs:
        with open(a.pairs) as f:
            pairs.update(json.load(f))
    for kv in a.pair:
        k, _, v = kv.partition('=')
        pairs[k] = v
    if not pairs:
        p.error('give --pairs FILE or at least one --pair ID=REF')
    a.pairs = pairs
    return a


ARGS = parse()
os.makedirs(ARGS.out, exist_ok=True)


def fetch(story):
    if ARGS.renders:
        return Image.open(os.path.join(ARGS.renders, story + '.png')).convert('RGB')
    url = f'http://localhost:{ARGS.port}/story/{story}.png'
    err = None
    for _ in range(2):  # the first render after a hot restart can come back empty
        try:
            data = urllib.request.urlopen(url, timeout=60).read()
            if data:
                return Image.open(io.BytesIO(data)).convert('RGB')
        except Exception as e:  # noqa: BLE001
            err = e
    raise RuntimeError(f'{story}: {err or "empty response"}')


def compare(story, ref_path):
    ref = Image.open(os.path.join(ARGS.ref, ref_path)).convert('RGB')
    got = fetch(story)
    name = story.replace('/', '_')
    got.save(os.path.join(ARGS.out, f'{name}.render.png'))
    w, h = max(ref.width, got.width), max(ref.height, got.height)
    fill = ref.getpixel((0, 0))
    a = Image.new('RGB', (w, h), fill); a.paste(ref, (0, 0))
    b = Image.new('RGB', (w, h), fill); b.paste(got, (0, 0))
    d = np.asarray(ImageChops.difference(a, b)).astype(np.float32)
    mean = d.mean()
    worst = max((d[y:y + BAND_PX].mean(), y // 2) for y in range(0, h, BAND_PX))
    heat = np.clip(d.max(axis=2) * 4, 0, 255).astype(np.uint8)
    heat_img = Image.fromarray(np.stack([heat, heat // 3, heat // 3], axis=2))
    comp = Image.new('RGB', (w * 3 + 8, h), (60, 60, 60))
    comp.paste(a, (0, 0)); comp.paste(b, (w + 4, 0)); comp.paste(heat_img, (2 * w + 8, 0))
    comp.save(os.path.join(ARGS.out, f'{name}.cmp.png'))
    size_note = '' if ref.size == got.size else f'  SIZE ref {ref.size} vs render {got.size}'
    print(f'{story:32s} mean {mean:5.2f}  worst band {worst[0]:5.1f} @y{worst[1]:4d}{size_note}')


if __name__ == '__main__':
    for story in ARGS.stories or list(ARGS.pairs):
        compare(story, ARGS.pairs[story])
