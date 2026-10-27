"""Score the twin against every recorded run, in drawing order.

    python3 evaluate.py [--runs DIR] [--reg REG.json] [--set name=value ...] [--sheet OUT.png]
    python3 evaluate.py --fit OUT.json --hold rain birthday      tune the sand parameters on the other runs

Each run is simulated on top of the sand left by the runs before it (the chain starts at the first run), then
compared with that run's after photo. Prints detail R^2 per run. --reg gives a registration to use for runs
that don't have their own reg.json (same camera pose). --sheet writes photo | twin pairs for every run.
"""
import argparse
import json
import os

import cv2
import numpy as np

from sand import Sand, Params
from photo import top_down, fit_render, refine
from compare import load_xy, tone

RUNS = os.path.expanduser('~/Library/Application Support/Drifted/runs')

SPACE = {                       # name: (step, lo, hi)
    'ball': (0.003, 0.02, 0.05),
    'sink': (0.1, 0.2, 0.95),
    'spread': (0.25, 0.25, 2.5),
    'ahead': (0.1, 0.0, 1.0),
    'repose': (6.0, 20.0, 70.0),
    'lag': (0.008, 0.0, 0.06),
    'noise': (0.0006, 0.0, 0.004),
    'sided': (0.1, 0.0, 1.0),
}


def chain(runs_dir):
    """Recorded runs in drawing order: (name, path, photo or None)."""
    out = []
    for name in sorted(os.listdir(runs_dir)):
        run = os.path.join(runs_dir, name)
        if os.path.exists(os.path.join(run, 'path.json')):
            photo = os.path.join(run, 'after.jpg')
            out.append((name, run, photo if os.path.exists(photo) else None))
    return out


def score_chain(params, runs, tops, use):
    """Mean R^2 over the runs in use, with each run's straightened photo already in tops."""
    sim, r2s = Sand(params), {}
    for name, run, photo in runs:
        sim.draw(load_xy(os.path.join(run, 'path.json')))
        if name in tops and name in use:
            r2s[name] = fit_render(sim, tops[name])[2]
    return float(np.mean(list(r2s.values()))), r2s


def fit(a, base):
    from dataclasses import replace
    runs = chain(a.runs)
    tops, sim = {}, Sand(base)
    for name, run, photo in runs:                     # straighten each photo once, with its refined registration
        sim.draw(load_xy(os.path.join(run, 'path.json')))
        reg_path = os.path.join(run, 'reg-refined.json')
        if photo and os.path.exists(reg_path):
            tops[name] = top_down(cv2.imread(photo), sim, json.load(open(reg_path)))
    train = {n for n in tops if not any(h in n for h in a.hold)}
    held = set(tops) - train
    p = base
    best, _ = score_chain(p, runs, tops, train)
    print(f'start train {best:.4f}', flush=True)
    steps = {k: v[0] for k, v in SPACE.items()}
    for rnd in range(3):
        for k, (_, lo, hi) in SPACE.items():
            for sgn in (1, -1):
                while True:
                    v = min(hi, max(lo, getattr(p, k) + sgn * steps[k]))
                    if v == getattr(p, k):
                        break
                    q = replace(p, **{k: v})
                    s, _ = score_chain(q, runs, tops, train)
                    print(f'  {k}={v:.4g} train {s:.4f}', flush=True)
                    if s > best + 1e-4:
                        p, best = q, s
                    else:
                        break
        steps = {k: v / 2 for k, v in steps.items()}
        h, per = score_chain(p, runs, tops, held) if held else (float('nan'), {})
        print(f'round {rnd}: train {best:.4f}  held-out {h:.4f}', {k: round(getattr(p, k), 4) for k in SPACE}, flush=True)
        json.dump({'train': best, 'held_out': h, 'held_runs': sorted(held), 'params': p.to_dict()},
                  open(a.fit, 'w'), indent=1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--runs', default=RUNS)
    ap.add_argument('--reg')
    ap.add_argument('--set', nargs='*', default=[])
    ap.add_argument('--sheet')
    ap.add_argument('--only', nargs='*', help='score only runs whose name contains one of these')
    ap.add_argument('--fit', help='tune the sand parameters and write them here')
    ap.add_argument('--hold', nargs='*', default=[], help='with --fit: runs (name parts) kept out of the fit')
    a = ap.parse_args()
    kw = {k: float(v) if '.' in v else int(v) for k, v in (kv.split('=') for kv in a.set)}
    if a.fit:
        return fit(a, Params(**kw))
    sim = Sand(Params(**kw))
    rows, tiles = [], []
    for name in sorted(os.listdir(a.runs)):
        run = os.path.join(a.runs, name)
        if not os.path.exists(os.path.join(run, 'path.json')):
            continue
        sim.draw(load_xy(os.path.join(run, 'path.json')))
        photo = os.path.join(run, 'after.jpg')
        reg_path = os.path.join(run, 'reg.json')
        if not os.path.exists(photo) or a.only and not any(o in name for o in a.only):
            continue
        if not os.path.exists(reg_path) and not a.reg:
            print(f'{name}: no registration, skipped')
            continue
        reg = json.load(open(reg_path if os.path.exists(reg_path) else a.reg))
        img = cv2.imread(photo)
        reg = refine(img, sim, reg)
        json.dump(reg, open(os.path.join(run, 'reg-refined.json'), 'w'))
        top = top_down(img, sim, reg)
        pred, w, r2 = fit_render(sim, top)
        rows.append((name, r2))
        print(f'{name:40s} R2 {r2:.3f}', flush=True)
        if a.sheet:
            m = sim.R < 0.97
            pair = np.concatenate([np.where(m, tone(top, m), 0.08), np.where(m, tone(pred, m), 0.08)], 1)
            tiles.append(cv2.resize(pair, (520, 260)))
    if rows:
        print(f'mean R2 {np.mean([r for _, r in rows]):.3f} over {len(rows)} runs')
    if a.sheet and tiles:
        cols = 2
        while len(tiles) % cols:
            tiles.append(np.full_like(tiles[0], 0.08))
        sheet = np.concatenate([np.concatenate(tiles[i:i + cols], 1) for i in range(0, len(tiles), cols)], 0)
        cv2.imwrite(a.sheet, (sheet * 255).astype(np.uint8))


if __name__ == '__main__':
    main()
