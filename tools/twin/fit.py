"""Fit the twin's sand parameters to photos of real drawings.

    python3 fit.py OUT.json RUN [RUN ...]       where RUN is PATH.json:PHOTO.jpg:REG.json

PATH may chain drawings, earlier first: before.json+after.json.

REG.json comes from compare.py (registration doesn't change while sand parameters are tuned). The score is the
mean detail R^2 over the runs; coordinate search, a few rounds, step halving.
"""
import json
import sys
import time
from dataclasses import replace

import cv2

from sand import Params
from photo import top_down, fit_render
from compare import simulate

SPACE = {                       # name: (step, lo, hi)
    'ball': (0.004, 0.02, 0.05),
    'sink': (0.1, 0.2, 0.95),
    'spread': (0.25, 0.25, 2.5),
    'ahead': (0.05, 0.0, 1.0),
    'repose': (4.0, 20.0, 70.0),
    'lag': (0.01, 0.0, 0.08),
}


def score(params, runs, cache):
    total, sims = 0.0, {}
    for path, photo, reg in runs:
        if path not in sims:                      # several photos of one drawing share a simulation
            sims[path] = simulate(path.split('+'), params)   # a+b: b drawn over a
        sim = sims[path]
        key = (photo, params.n, params.extent)
        if key not in cache:
            cache[key] = top_down(cv2.imread(photo), sim, json.load(open(reg)))
        _, _, r2 = fit_render(sim, cache[key])
        total += r2
    return total / len(runs)


def main():
    out, runs = sys.argv[1], [r.split(':') for r in sys.argv[2:]]
    p, cache = Params(ball=0.034, sink=0.45, spread=0.78125, ahead=0.97, repose=45.0, lag=0.025), {}
    best = score(p, runs, cache)
    print('start', round(best, 4), flush=True)
    steps = {k: v[0] for k, v in SPACE.items()}
    for rnd in range(4):
        for k, (_, lo, hi) in SPACE.items():
            for sgn in (1, -1):
                while True:
                    v = min(hi, max(lo, getattr(p, k) + sgn * steps[k]))
                    if v == getattr(p, k):
                        break
                    q = replace(p, **{k: v})
                    t = time.time()
                    s = score(q, runs, cache)
                    print(f'  {k}={v:.4g} {s:.4f} ({time.time() - t:.1f}s)', flush=True)
                    if s > best + 1e-4:
                        p, best = q, s
                    else:
                        break
        steps = {k: v / 2 for k, v in steps.items()}
        print('round', rnd, round(best, 4), {k: getattr(p, k) for k in SPACE}, flush=True)
        json.dump({'score': best, 'params': p.to_dict()}, open(out, 'w'), indent=1)


if __name__ == '__main__':
    main()
