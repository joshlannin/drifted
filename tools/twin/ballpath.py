"""Compare where the ball really went (ball.csv from track.py) with the path the table was sent.

    python3 ballpath.py RUN_DIR [--before PREV.json]

Prints how far the tracked ball sits from the path (overall, on straights, at sharp turns), the speed along
the path, and which ball lag in the twin's motion model best explains the tracking. Also fits a small
rotation/scale/shift between tracked and commanded positions: a consistent one points at registration or at
how the table is calibrated rather than at the ball.
"""
import argparse
import csv
import json
import math
import os

import numpy as np

from sand import _table_path, _trail


def load(run):
    rows = list(csv.DictReader(open(os.path.join(run, 'ball.csv'))))
    t = np.array([float(r['t']) for r in rows if r['x']])
    xy = np.array([(float(r['x']), float(r['y'])) for r in rows if r['x']])
    path = json.load(open(os.path.join(run, 'path.json')))['xy']
    return t, xy, path


def nearest(cmd, pts, times=None, step=0.004, tol=0.06):
    """For each tracked point, the nearest commanded point. The search runs forward along the path from the
    last good match and widens with the time since then (the ball covers at most ~0.2 r/s), so a path
    that crosses itself doesn't confuse the match and one bad frame doesn't lose the place."""
    idx, dist = [], []
    j, t_last = 0, None
    for n, p in enumerate(pts):
        if times is None:
            span = 2500
        else:
            since = times[n] - (t_last if t_last is not None else times[0] - 30)
            span = int(since * 0.2 / step) + 40
        lo, hi = max(0, j - 10), min(len(cmd), j + span)
        d = np.hypot(cmd[lo:hi, 0] - p[0], cmd[lo:hi, 1] - p[1])
        k = int(np.argmin(d))
        if d[k] < tol:
            j, t_last = lo + k, (times[n] if times is not None else None)
        idx.append(lo + k)
        dist.append(float(d[k]))
    return np.array(idx), np.array(dist)


def turn_sharpness(cmd, idx, span=12):
    """Heading change around each matched point (radians)."""
    out = []
    for i in idx:
        a, b, c = cmd[max(i - span, 0)], cmd[i], cmd[min(i + span, len(cmd) - 1)]
        h1, h2 = math.atan2(b[1] - a[1], b[0] - a[0]), math.atan2(c[1] - b[1], c[0] - b[0])
        out.append(abs((h2 - h1 + math.pi) % (2 * math.pi) - math.pi))
    return np.array(out)


def similarity(src, dst):
    """Least-squares rotation, scale and shift taking src onto dst."""
    ms, md = src.mean(0), dst.mean(0)
    a, b = src - ms, dst - md
    cov = b.T @ a / len(a)
    U, S, Vt = np.linalg.svd(cov)
    R = U @ Vt
    scale = S.sum() / (a ** 2).sum() * len(a)
    return math.degrees(math.atan2(R[1, 0], R[0, 0])), scale, md - scale * (R @ ms)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('run')
    ap.add_argument('--before')
    a = ap.parse_args()
    t, xy, path = load(a.run)
    step = 0.004
    start = [json.load(open(a.before))['xy'][-1]] if a.before else []
    cmd = np.array(_table_path(start + path, step))
    idx, dist = nearest(cmd, xy, t)
    sharp = turn_sharpness(cmd, idx)
    good = dist < 0.06
    print(f'tracked {len(xy)} positions; matched {good.sum()}')
    for name, m in (('all', good), ('straight', good & (sharp < 0.1)), ('sharp turns', good & (sharp > 1.0))):
        if m.sum():
            print(f'  {name:12s} n={m.sum():5d}  median off-path {np.median(dist[m]):.4f} r   90th pct {np.percentile(dist[m], 90):.4f} r')
    # speed: path distance covered per second over matched points
    s = np.concatenate([[0], np.cumsum(np.hypot(*np.diff(cmd, axis=0).T))])
    sp = np.diff(s[idx[good]]) / np.diff(t[good])
    sp = sp[(sp > 0) & (sp < 1)]
    print(f'  speed along path: median {np.median(sp):.4f} r/s')
    # which lag explains the tracking best
    for lag in (0.0, 0.01, 0.02, 0.025, 0.03, 0.04, 0.05):
        lagged = np.array(_trail([tuple(p) for p in cmd], lag)) if lag else cmd
        _, d2 = nearest(lagged, xy[good], t[good])
        print(f'  lag {lag:.3f}: median off-path {np.median(d2):.4f}  90th {np.percentile(d2, 90):.4f}')
    rot, scale, shift = similarity(xy[good], cmd[idx[good]])
    print(f'  tracked -> commanded: rotate {rot:+.2f} deg, scale {scale:.4f}, shift ({shift[0]:+.4f}, {shift[1]:+.4f})')


if __name__ == '__main__':
    main()
