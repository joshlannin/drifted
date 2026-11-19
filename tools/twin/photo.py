"""Turn a webcam photo of the table into a top-down image on the twin's grid, and score the twin against it.

Needs numpy and OpenCV (opencv-python).
"""
import math

import cv2
import numpy as np

from sand import _blur


def find_rim(img):
    """Fit an ellipse to the lit rim. Returns (centre, 2x2 matrix mapping the unit circle onto the rim).
    In a dark room the lit rim is the brightest thing in view. In daylight it isn't (the bright region runs off
    the frame), so then the edge of the textured sand disc is used instead."""
    g = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY) if img.ndim == 3 else img
    mask = (cv2.GaussianBlur(g, (9, 9), 0) > 70).astype(np.uint8)
    cs, _ = cv2.findContours(mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_NONE)
    c = max(cs, key=cv2.contourArea)[:, 0, :]
    H, W = g.shape
    keep = (c[:, 0] > 3) & (c[:, 0] < W - 4) & (c[:, 1] > 3) & (c[:, 1] < H - 4)
    clipped = 1 - keep.mean()
    if clipped > 0.1:
        (cx, cy), (w, h), ang = _sand_edge(g)
    else:
        (cx, cy), (w, h), ang = cv2.fitEllipse(c[keep].astype(np.float32))
    a = math.radians(ang)
    rot = np.array([[math.cos(a), -math.sin(a)], [math.sin(a), math.cos(a)]])
    return np.array([cx, cy]), rot @ np.diag([w / 2, h / 2]), clipped


def _sand_edge(g):
    """Ellipse round the textured sand disc: along rays from the centre, where the grooves give way to the smooth
    frosted ring for good. Outliers (glare, the ball, gaps in the drawing) are trimmed and the fit repeated."""
    g = g.astype(np.float32)
    tex = cv2.GaussianBlur(np.abs(g - cv2.GaussianBlur(g, (0, 0), 4)), (0, 0), 4)
    H, W = g.shape
    cx, cy = W / 2, H / 2
    rr = np.arange(int(0.15 * H), int(0.55 * H))
    for _ in range(2):                                # the second pass casts rays from the first fit's centre
        pts = []
        for a in np.radians(np.arange(0, 360, 1.0)):
            x = (cx + rr * math.cos(a)).round().astype(int)
            y = (cy + rr * math.sin(a)).round().astype(int)
            ok = (x >= 0) & (x < W) & (y >= 0) & (y < H)
            prof = np.where(ok, tex[y.clip(0, H - 1), x.clip(0, W - 1)], 0)
            low = prof < 0.25 * np.median(prof[:len(prof) // 3])
            run = np.convolve(low.astype(int), np.ones(25, int), 'valid') == 25
            if run.any() and ok[np.argmax(run)]:
                pts.append((x[np.argmax(run)], y[np.argmax(run)]))
        pts = np.float32(pts)
        keep = np.ones(len(pts), bool)
        for _ in range(5):
            (cx, cy), (w, h), ang = cv2.fitEllipse(pts[keep])
            th = np.arctan2(pts[:, 1] - cy, pts[:, 0] - cx) - math.radians(ang)
            r_fit = 1 / np.sqrt((np.cos(th) / (w / 2)) ** 2 + (np.sin(th) / (h / 2)) ** 2)
            err = np.abs(np.hypot(pts[:, 0] - cx, pts[:, 1] - cy) - r_fit)
            keep = err < max(3.0, 2.5 * np.median(err))
    return (cx, cy), (w, h), ang


def rectify(img, centre, M, X, Y, scale=0.965, turn=0.0, mirror=False):
    """Sample the photo at table points (X, Y). scale is the sand radius as a fraction of the lit rim."""
    t = math.radians(turn)
    u = scale * (math.cos(t) * X - math.sin(t) * Y)
    v = scale * (math.sin(t) * X + math.cos(t) * Y)
    if mirror:
        u = -u
    px = centre[0] + M[0, 0] * u + M[0, 1] * -v
    py = centre[1] + M[1, 0] * u + M[1, 1] * -v
    g = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY) if img.ndim == 3 else img
    return cv2.remap(g.astype(np.float32), px.astype(np.float32), py.astype(np.float32), cv2.INTER_LINEAR)


def highpass(a, r):
    return a - _blur(a, r)


def edges(a):
    """Edge strength: shading conventions differ (ridge light or groove dark), edges don't."""
    gy, gx = np.gradient(_blur(a, 1))
    e = np.hypot(gx, gy)
    return e - _blur(e, 10)


def grooves(a):
    """Groove-band energy, locally normalised: where the grooves are, whatever the shading convention, and
    without a sunlit patch (or the twin's strongest lines) outweighing the rest of the table."""
    e = np.abs(bandpass(a))
    return _blur(e / np.sqrt(_blur(e * e, 8) + 1e-3 * (e * e).mean()), 2)


def _deglare(img):
    """Grey photo with saturated glare spots on the glass filled in, lightly blurred against aliasing."""
    g = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY) if img.ndim == 3 else img
    mask = cv2.dilate((g >= 245).astype(np.uint8), np.ones((15, 15), np.uint8))
    g = cv2.inpaint(g.astype(np.uint8), mask, 5, cv2.INPAINT_TELEA) if mask.any() else g
    return cv2.GaussianBlur(g.astype(np.float32), (0, 0), 1.5)


def _corr(a, b, m):
    a, b = a[m] - a[m].mean(), b[m] - b[m].mean()
    return float((a * b).sum() / math.sqrt((a * a).sum() * (b * b).sum() + 1e-12))


def register(img, sim, centre, M, scales=None, mirrors=(False, True)):
    """Line the photo up with the twin. A coarse search over rotation, scale and handedness on groove-energy
    maps, then an ECC homography that soaks up camera tilt and the rim-vs-sand parallax.
    scale is the ball's reach (table radius 1) as a fraction of the lit rim's radius.
    (Blurred edge maps worked under the ring light in a dark room, but not in daylight: a sunlit patch and
    glare on the glass outweighed the grooves.)
    A symmetric drawing (a six-fold snowflake) matches nearly as well turned by a multiple of 60 degrees, so the
    best few distinct turns are each warped, and the best final match wins."""
    from sand import Sand, Params
    lo = Sand(Params(n=200, extent=sim.p.extent, rim=sim.p.rim))
    cav = sim.features(shadows=())['cavity']
    ref = grooves(cv2.resize(cav, (200, 200), interpolation=cv2.INTER_AREA))
    g = _deglare(img)
    m = lo.R < 0.9
    tried = []
    for mir in mirrors:
        for sc in (scales or np.arange(0.74, 1.0, 0.02)):
            for tn in range(0, 360, 3):
                ph = grooves(rectify(g, centre, M, lo.X, lo.Y, sc, tn, mir))
                tried.append((_corr(ph, ref, m), sc, tn, mir))
    cands = []
    for t in sorted(tried, key=lambda t: -t[0]):
        if all(t[3] != o[3] or min(abs(t[2] - o[2]), 360 - abs(t[2] - o[2])) > 20 for o in cands):
            cands.append(t)
        if len(cands) == 8:
            break
    sig = bandpass(sim.features(shadows=())['cavity'])
    best = None
    for c0, sc, tn, mir in cands:
        top = rectify(img, centre, M, sim.X, sim.Y, sc, tn, mir)
        warp = None
        for patch, search, order in ((96, 28, 1), (64, 14, 2), (48, 8, 3), (40, 5, 3)):
            warp = fit_warp(top, sig, sim.R, warp, patch, search, order)
        c = _corr(bandpass(apply_warp(top, warp)), sig, sim.R < 0.9)
        if best is None or c > best['corr']:
            best = {'corr': c, 'coarse_corr': c0, 'scale': float(sc), 'turn': float(tn), 'mirror': bool(mir),
                    'warp': warp, 'centre': centre.tolist(), 'M': M.tolist()}
    return best


def _poly_terms(x, y, order):
    return np.stack([x ** i * y ** j for i in range(order + 1) for j in range(order + 1 - i)], -1)


def apply_warp(top, warp):
    """Resample so twin-grid pixel (x, y) shows the photo-grid pixel the warp maps it to."""
    n = top.shape[0]
    if warp is None:
        return top
    jj, ii = np.meshgrid(np.arange(n, dtype=np.float64), np.arange(n, dtype=np.float64))
    u, v = (jj - n / 2) / (n / 2), (ii - n / 2) / (n / 2)
    T = _poly_terms(u, v, warp['order'])
    k = n / warp.get('n', 620)                       # the warp was fitted on a grid of warp['n'] cells
    mx = (k * (T @ np.array(warp['x']))).astype(np.float32)
    my = (k * (T @ np.array(warp['y']))).astype(np.float32)
    return cv2.remap(top.astype(np.float32), mx, my, cv2.INTER_LINEAR)


def fit_warp(top, sig, R, warp, patch, search, order, r_max=0.93):
    """Match patches of the photo's groove band to the twin's, then fit a smooth polynomial warp to the
    matches (dropping outliers). Absorbs lens distortion, parallax and tilt."""
    cur = bandpass(apply_warp(top, warp)).astype(np.float32)
    ref = sig.astype(np.float32)
    n = top.shape[0]
    src, dst = [], []
    h = patch // 2
    for i in range(search + h, n - search - h, h // 2):
        for j in range(search + h, n - search - h, h // 2):
            if R[i, j] > r_max:
                continue
            tpl = ref[i - h:i + h, j - h:j + h]
            if tpl.std() < 1e-9:
                continue
            win = cur[i - h - search:i + h + search, j - h - search:j + h + search]
            res = cv2.matchTemplate(win, tpl, cv2.TM_CCOEFF_NORMED)
            _, score, _, (x, y) = cv2.minMaxLoc(res)
            if score > 0.3:
                src.append((j, i))
                dst.append((j + x - search, i + y - search))
    if len(src) < 12:
        return warp
    src, dst = np.float64(src), np.float64(dst)
    # dst is in the current (already warped) grid: map it through the existing warp
    if warp is not None:
        T = _poly_terms((dst[:, 0] - n / 2) / (n / 2), (dst[:, 1] - n / 2) / (n / 2), warp['order'])
        k = n / warp.get('n', 620)
        dst = k * np.stack([T @ np.array(warp['x']), T @ np.array(warp['y'])], 1)
    u, v = (src[:, 0] - n / 2) / (n / 2), (src[:, 1] - n / 2) / (n / 2)
    T = _poly_terms(u, v, order)
    keep = np.ones(len(src), bool)
    for _ in range(4):
        cx, *_ = np.linalg.lstsq(T[keep], dst[keep, 0], rcond=None)
        cy, *_ = np.linalg.lstsq(T[keep], dst[keep, 1], rcond=None)
        err = np.hypot(T @ cx - dst[:, 0], T @ cy - dst[:, 1])
        keep = err < max(2.0, np.percentile(err, 70))
    return {'order': order, 'n': n, 'x': cx.tolist(), 'y': cy.tolist(), 'matches': int(keep.sum()),
            'rms': float(np.sqrt((err[keep] ** 2).mean()))}


def refine(img, sim, reg, stages=((64, 10, 3), (48, 6, 3), (40, 4, 3))):
    """Re-fit the smooth warp for one photo, starting from a registration made at the same camera position.
    Soaks up the few-pixel drift between runs (the table shifts a little as it draws)."""
    centre, M = rim_of(img, reg)
    top = rectify(img, centre, M, sim.X, sim.Y, reg['scale'], reg['turn'], reg['mirror'])
    sig = bandpass(sim.features(shadows=())['cavity'])
    warp = reg.get('warp')
    for patch, search, order in stages:
        warp = fit_warp(top, sig, sim.R, warp, patch, search, order)
    return dict(reg, warp=warp, corr=_corr(bandpass(apply_warp(top, warp)), sig, sim.R < 0.9))


def rim_of(img, reg):
    """The rim the registration was made with. The fitted rim moves with the camera's auto-exposure, so a
    registration carries its own and reuses it for every photo from the same camera position."""
    if 'centre' in reg:
        return np.array(reg['centre']), np.array(reg['M'])
    centre, M, _ = find_rim(img)
    return centre, M


def top_down(img, sim, reg):
    centre, M = rim_of(img, reg)
    return apply_warp(rectify(img, centre, M, sim.X, sim.Y, reg['scale'], reg['turn'], reg['mirror']), reg.get('warp'))


def bandpass(a, fine=2, coarse=12):
    """Groove-scale band. Radii are in cells of a 620-cell grid and scale with the grid."""
    k = a.shape[0] / 620
    return _blur(a, max(1, round(fine * k))) - _blur(a, max(1, round(coarse * k)))


def fit_render(sim, photo_top, r_max=0.93):
    """Least-squares mix of the twin's lighting terms to match the photo, on a groove-scale band (fine noise
    and slow lighting falloff both removed). Returns (prediction, weights, R^2 on that band)."""
    f = sim.features()
    m = sim.R < r_max
    names = list(f)
    cols = [bandpass(f[k]) for k in names]
    target = bandpass(photo_top)
    A = np.stack([c[m] for c in cols] + [np.ones(m.sum())], 1)
    w, *_ = np.linalg.lstsq(A, target[m], rcond=None)
    pred_bp = sum(wi * c for wi, c in zip(w, cols)) + w[-1]
    res = target[m] - pred_bp[m]
    r2 = 1 - res.var() / target[m].var()
    pred = pred_bp + _blur(photo_top, max(1, round(12 * photo_top.shape[0] / 620)))       # add back the photo's own slow lighting, for viewing
    return pred, dict(zip(names, map(float, w[:-1]))), float(r2)
