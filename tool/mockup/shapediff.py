"""1px-tolerant class-map diff (bg / rim / dark / screen), aligned on the body's bounding box.
usage: python3 shapediff3.py ref.png render.png out.png"""
import sys, json
import numpy as np
from PIL import Image
from collections import deque
from scipy.ndimage import binary_dilation
def classify(path):
    im = np.asarray(Image.open(path).convert('RGBA')).astype(int); rgb, a = im[..., :3], im[..., 3]; H, W = a.shape
    white = (np.abs(rgb - 255).sum(-1) <= 30) & (a >= 128)
    bg = a < 128
    if not bg.any():
        seen = np.zeros((H, W), bool); q = deque()
        for y in range(H):
            for x in (0, W - 1):
                if white[y, x] and not seen[y, x]: seen[y, x] = True; q.append((y, x))
        for x in range(W):
            for y in (0, H - 1):
                if white[y, x] and not seen[y, x]: seen[y, x] = True; q.append((y, x))
        while q:
            y, x = q.popleft()
            for ny, nx in ((y-1,x),(y+1,x),(y,x-1),(y,x+1)):
                if 0 <= ny < H and 0 <= nx < W and white[ny, nx] and not seen[ny, nx]: seen[ny, nx] = True; q.append((ny, nx))
        bg = seen
    cls = np.full((H, W), 4, np.uint8); cls[bg] = 0          # 4 = anti-aliased grey edge, ignored
    bluish = (rgb[..., 2] - rgb[..., 0] > 40) & ~bg
    cls[bluish] = 1
    cls[(rgb.sum(-1) < 150) & ~bg] = 2; cls[white & ~bg] = 3
    ys, xs = np.where(~bg)
    return cls, (xs.min() + xs.max()) / 2, (ys.min() + ys.max()) / 2
ref, rcx, rcy = classify(sys.argv[1]); ren, ncx, ncy = classify(sys.argv[2])
dx, dy = int(round(rcx - ncx)), int(round(rcy - ncy))
H = min(ref.shape[0] - max(0, dy), ren.shape[0] - max(0, -dy)); W = min(ref.shape[1] - max(0, dx), ren.shape[1] - max(0, -dx))
r = ref[max(0, dy):max(0, dy)+H, max(0, dx):max(0, dx)+W]; n = ren[max(0, -dy):max(0, -dy)+H, max(0, -dx):max(0, -dx)+W]
strict = r != n
# tolerant: the render's class must appear within the ref's 3x3 neighbourhood, and vice versa
strict &= (r != 4) & (n != 4)
tol = np.zeros_like(strict)
for k in range(4):
    near_ref = binary_dilation(r == k, iterations=1); near_ren = binary_dilation(n == k, iterations=1)
    tol |= (n == k) & ~near_ref & (r != 4)
    tol |= (r == k) & ~near_ren & (n != 4)
names = ['background', 'rim', 'dark', 'screen']
rep = {'strict': int(strict.sum()), 'beyond_1px': int(tol.sum()), 'compared': int(H*W), 'align_offset': [dx, dy]}
rep.update({f'beyond_1px_in_ref_{names[k]}': int(((r == k) & tol).sum()) for k in range(4)})
ys, xs = np.where(tol)
if ys.size: rep['beyond_1px_bbox'] = [int(xs.min()), int(ys.min()), int(xs.max()), int(ys.max())]
out = np.zeros((H, W, 3), np.uint8); out[r == 3] = 235; out[r == 1] = [80, 130, 180]; out[r == 2] = 30
out[strict] = [255, 200, 60]; out[tol] = [255, 30, 30]
Image.fromarray(out).save(sys.argv[3]); print(json.dumps(rep))
