import sys, json
import numpy as np
from PIL import Image
from collections import deque

im = np.asarray(Image.open(sys.argv[1]).convert('RGB')).astype(int)
H, W, _ = im.shape
white = (np.abs(im - 255).sum(-1) <= 30)
# background: white connected to the image border
bg = np.zeros((H, W), bool); q = deque()
for y in range(H):
    for x in (0, W - 1):
        if white[y, x] and not bg[y, x]: bg[y, x] = True; q.append((y, x))
for x in range(W):
    for y in (0, H - 1):
        if white[y, x] and not bg[y, x]: bg[y, x] = True; q.append((y, x))
while q:
    y, x = q.popleft()
    for ny, nx in ((y-1,x),(y+1,x),(y,x-1),(y,x+1)):
        if 0 <= ny < H and 0 <= nx < W and white[ny, nx] and not bg[ny, nx]:
            bg[ny, nx] = True; q.append((ny, nx))
phone = ~bg
screen = white & ~bg
dark = (im.sum(-1) < 150) & phone
blue = phone & ~screen & ~dark
def bbox(m):
    ys, xs = np.where(m); return dict(l=int(xs.min()), t=int(ys.min()), r=int(xs.max()), b=int(ys.max()), w=int(xs.max()-xs.min()+1), h=int(ys.max()-ys.min()+1))
cols = phone.sum(0); rows = phone.sum(1)
main_cols = np.where(cols > H * 0.5)[0]; bl, br = int(main_cols.min()), int(main_cols.max())
body = dict(l=bl, r=br, t=int(np.where(phone[:, bl:br+1].any(1))[0].min()), b=int(np.where(phone[:, bl:br+1].any(1))[0].max()))
body['w'] = br - bl + 1; body['h'] = body['b'] - body['t'] + 1
sc = bbox(screen)
def radius_top(mask, top, left, right):
    row = np.where(mask[top, left:right+1])[0]; return int(row.min()), int(right - left - row.max())
body_mask = phone.copy(); body_mask[:, :bl] = False; body_mask[:, br+1:] = False
r_body = radius_top(body_mask, body['t'], bl, br)
# screen corner radius: rows from the top until the white run reaches full width
full = sc['w']; r_screen = 0
for y in range(sc['t'], sc['t'] + sc['h'] // 4):
    run = np.where(screen[y, sc['l']:sc['r']+1])[0]
    if run.min() == 0 and run.max() == full - 1: break
    r_screen = y - sc['t'] + 1
# notch: rows near the top where the white run has a gap in the middle
notch_rows = []; notch_l = W; notch_r = 0
for y in range(sc['t'], sc['t'] + sc['h'] // 5):
    xs = np.where(screen[y, sc['l']:sc['r']+1])[0]
    if xs.size == 0: continue
    gaps = np.where(np.diff(xs) > 1)[0]
    if gaps.size:
        g = gaps[np.argmax(np.diff(xs)[gaps])]
        gl, gr = xs[g] + 1 + sc['l'], xs[g+1] - 1 + sc['l']
        if gr - gl > sc['w'] * 0.1:
            notch_rows.append(y); notch_l = min(notch_l, gl); notch_r = max(notch_r, gr)
notch = dict(l=int(notch_l), r=int(notch_r), t=int(min(notch_rows)), b=int(max(notch_rows)), w=int(notch_r-notch_l+1), h=int(max(notch_rows)-min(notch_rows)+1)) if notch_rows else None
# notch bottom corner radius: width shrink over the last rows
if notch:
    widths = []
    for y in notch_rows:
        xs = np.where(~screen[y, notch_l:notch_r+1])[0]; widths.append(int(xs.max()-xs.min()+1))
    notch['row_widths_tail'] = widths[-12:]
# rim (blue) thickness at mid height, left side; bezel (dark) thickness
ymid = (sc['t'] + sc['b']) // 2
row_blue = np.where(blue[ymid, bl:sc['l']])[0]; row_dark = np.where(dark[ymid, bl:sc['l']])[0]
rim_w = int(row_blue.max() - row_blue.min() + 1) if row_blue.size else 0
bezel_w = int(row_dark.max() - row_dark.min() + 1) if row_dark.size else 0
# buttons (blue outside the body columns)
def strips(mask):
    rows_ = np.where(mask.any(1))[0]; out=[]; start=None
    for i, y in enumerate(rows_):
        if start is None: start = y
        if i+1 == len(rows_) or rows_[i+1] != y+1: out.append((int(start), int(y))); start=None
    return out
left_btn = strips(phone[:, :bl]); right_btn = strips(phone[:, br+1:])
depth_l = bl - int(np.where(phone[:, :bl].any(0))[0].min()) if left_btn else 0
depth_r = int(np.where(phone[:, br+1:].any(0))[0].max()) + 1 if right_btn else 0
# camera dot: non-dark pixels inside the notch
cam = None
if notch:
    sub = ~dark[notch['t']:notch['b']+1, notch['l']:notch['r']+1] & ~screen[notch['t']:notch['b']+1, notch['l']:notch['r']+1]
    ys, xs = np.where(sub)
    if ys.size: cam = dict(cx=float(xs.mean()+notch['l']), cy=float(ys.mean()+notch['t']), d=int(xs.max()-xs.min()+1))
colors = dict(rim=im[ymid, bl + rim_w // 2].tolist(), bezel=im[ymid, sc['l'] - 2].tolist())
sw, sh = sc['w'], sc['h']
f = lambda v, base: round(v / base, 4)
out = dict(image=[W, H], body=dict(**body, radius_lr=r_body), screen=dict(**sc, radius=r_screen), rim=rim_w, bezel=bezel_w,
  bezel_box=dict(l=sc['l']-bl, t=sc['t']-body['t'], r=br-sc['r'], b=body['b']-sc['b']), notch=notch, camera=cam,
  buttons=dict(left=left_btn, right=right_btn, depth_left=int(depth_l), depth_right=int(depth_r)), colors=colors,
  screen_fractions=dict(aspect=f(sh, sw), bezel_l=f(sc['l']-bl, sw), bezel_t=f(sc['t']-body['t'], sw), rim=f(rim_w, sw), body_radius=f(r_body[0], sw), screen_radius=f(r_screen, sw),
    notch_w=f(notch['w'], sw) if notch else None, notch_h=f(notch['h'], sh) if notch else None, button_depth=f(depth_l, sw),
    buttons_left=[(f(a-body['t'], sh), f(b-a+1, sh)) for a,b in left_btn], buttons_right=[(f(a-body['t'], sh), f(b-a+1, sh)) for a,b in right_btn]))
print(json.dumps(out, indent=1))
