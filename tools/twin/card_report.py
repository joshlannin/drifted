"""Report on a recorded test-card run: photo against twin, quadrant by quadrant.

    python3 card_report.py RUN_DIR OUT.png [--before PREV.json ...] [--set name=value ...]

Top row: the photo, straightened. Bottom row: the twin, lit to match. Prints R^2 for each quadrant.
"""
import argparse
import json
import os

import cv2
import numpy as np

from sand import Params
from photo import find_rim, register, top_down, fit_render, bandpass
from compare import simulate, tone

# test-card areas in table radii: (x0, x1, y0, y1)
AREAS = {
    'spacing ladder': (-0.8, -0.02, -0.08, 0.82),
    'corners and circles': (0.0, 0.9, 0.02, 0.8),
    'crossings and retrace': (-0.82, -0.08, -0.82, -0.04),
    'patch test': (0.0, 0.84, -0.84, 0.02),
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('run'); ap.add_argument('out')
    ap.add_argument('--before', nargs='*', default=[])
    ap.add_argument('--set', nargs='*', default=[])
    a = ap.parse_args()
    kw = {k: float(v) for k, v in (kv.split('=') for kv in a.set)}
    sim = simulate(a.before + [os.path.join(a.run, 'path.json')], Params(**kw))
    img = cv2.imread(os.path.join(a.run, 'after.jpg'))
    centre, M, _ = find_rim(img)
    reg_path = os.path.join(a.run, 'reg.json')
    reg = json.load(open(reg_path)) if os.path.exists(reg_path) else register(img, sim, centre, M)
    json.dump(reg, open(reg_path, 'w'))
    top = top_down(img, sim, reg)
    pred, w, r2 = fit_render(sim, top)
    m = sim.R < 0.97
    ph, tw = tone(top, m), tone(pred, m)
    P, T = bandpass(top), bandpass(pred)
    n, ext = sim.p.n, sim.p.extent
    tiles, report = [], {'overall_r2': round(r2, 3), 'corr': round(reg['corr'], 3)}
    for name, (x0, x1, y0, y1) in AREAS.items():
        j0, j1 = int((x0 + ext) / (2 * ext) * n), int((x1 + ext) / (2 * ext) * n)
        i0, i1 = int((ext - y1) / (2 * ext) * n), int((ext - y0) / (2 * ext) * n)
        p, t = P[i0:i1, j0:j1].ravel(), T[i0:i1, j0:j1].ravel()
        report[name] = round(float(np.corrcoef(p, t)[0, 1]) ** 2, 3)
        col = np.concatenate([ph[i0:i1, j0:j1], tw[i0:i1, j0:j1]], 0)
        col = cv2.resize(col, (300, int(300 * col.shape[0] / col.shape[1])))
        tiles.append(col)
    hmax = max(t.shape[0] for t in tiles)
    tiles = [np.pad(t, ((0, hmax - t.shape[0]), (0, 8)), constant_values=0.08) for t in tiles]
    cv2.imwrite(a.out, (np.concatenate(tiles, 1) * 255).astype(np.uint8))
    print(json.dumps(report))


if __name__ == '__main__':
    main()
