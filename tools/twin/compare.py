"""Compare the twin with a photo of the real table.

    python3 compare.py PATH.json PHOTO.jpg OUT.png [--before PREV.json ...] [--set name=value ...]

Writes OUT.png: the photo straightened to top-down | the twin lit to match | where they disagree.
Prints the registration and the detail R^2 (how much of the photo's groove pattern the twin explains).
"""
import argparse
import json

import cv2
import numpy as np

from sand import Sand, Params
from photo import find_rim, register, top_down, fit_render


def load_xy(path):
    d = json.load(open(path))
    return d['xy'] if isinstance(d, dict) else d


def simulate(paths, params):
    s = Sand(params)
    for pth in paths:
        s.draw(load_xy(pth))
    return s


def tone(a, m):
    lo, hi = np.percentile(a[m], [1, 99])
    return np.clip((a - lo) / (hi - lo + 1e-9), 0, 1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('path'); ap.add_argument('photo'); ap.add_argument('out')
    ap.add_argument('--before', nargs='*', default=[])
    ap.add_argument('--set', nargs='*', default=[])
    ap.add_argument('--reg', help='reuse a registration JSON instead of searching')
    a = ap.parse_args()
    kw = {}
    for kv in a.set:
        k, v = kv.split('=')
        kw[k] = type(getattr(Params, k))(v) if not isinstance(getattr(Params, k), bool) else v == 'true'
    sim = simulate(a.before + [a.path], Params(**kw))
    img = cv2.imread(a.photo)
    centre, M, clipped = find_rim(img)
    if a.reg:
        reg = json.load(open(a.reg))
    else:
        reg = register(img, sim, centre, M)
    top = top_down(img, sim, reg)
    pred, w, r2 = fit_render(sim, top)
    m = sim.R < 0.97
    left, mid = tone(top, m), tone(pred, m)
    diff = np.clip(0.5 + (mid - left), 0, 1)
    row = np.concatenate([np.where(m, x, 0.08) for x in (left, mid, diff)], 1)
    cv2.imwrite(a.out, (row * 255).astype(np.uint8))
    out = {'r2': round(r2, 4), 'rim_clipped': round(clipped, 3), **{k: (round(v, 4) if isinstance(v, float) else v) for k, v in reg.items() if k != 'warp'},
           'warp_rms': round(reg['warp']['rms'], 2) if reg.get('warp') else None,
           'weights': {k: round(v, 2) for k, v in w.items()}}
    print(json.dumps(out))
    json.dump(reg, open(a.out.rsplit('.', 1)[0] + '.reg.json', 'w'))


if __name__ == '__main__':
    main()
