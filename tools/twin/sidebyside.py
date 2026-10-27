"""The twin next to the real table, drawing by drawing, for a series of recorded runs.

    python3 sidebyside.py RUNS_DIR OUT.mp4 --reg REG.json [--sheet OUT.png] [--hold 1.0]
    python3 sidebyside.py RUNS_DIR OUT.mp4 --reg REG.json --twin-video TWIN.mp4     the drawing itself, both sides moving

Replays every run in RUNS_DIR (in order) through the twin, and after each one shows the real after photo
(straightened onto the twin's grid) beside the twin's prediction, both in the table's colours, with the detail
R^2 between them. --reg is a registration from the same camera pose; each photo refines it. --sheet also
writes a contact sheet of every pair.

With --twin-video (made by video.py render files ... from the same drawings), the table's own recorded video is
straightened and resampled to the twin video's pace, drawing by drawing, so both sides move together.
"""
import argparse
import json
import os

import cv2
import numpy as np

from sand import Sand, Params
from photo import rim_of, rectify, apply_warp, refine, fit_render
from compare import load_xy
from video import Look, Writer, FPS


def colour_top(img, sim, reg):
    centre, M = rim_of(img, reg)
    return np.stack([apply_warp(rectify(img[..., c], centre, M, sim.X, sim.Y, reg['scale'], reg['turn'],
                                        reg['mirror']), reg.get('warp')) for c in range(3)], -1)


def drawn(run):
    """False if the table never drew this run (the upload failed): the twin must skip it too."""
    try:
        return json.load(open(os.path.join(run, 'show.json'))).get('state') != 'failed'
    except (OSError, ValueError):
        return True


def label(img, text, colour=(235, 235, 235)):
    cv2.putText(img, text, (12, 34), cv2.FONT_HERSHEY_SIMPLEX, 0.9, (0, 0, 0), 4, cv2.LINE_AA)
    cv2.putText(img, text, (12, 34), cv2.FONT_HERSHEY_SIMPLEX, 0.9, colour, 2, cv2.LINE_AA)
    return img


def motion(a):
    """Real video next to the twin video. Each drawing's recording is straightened (one remap per drawing, with
    the registration refined on its after photo) and sampled evenly to the twin segment's frame count."""
    base = json.load(open(a.reg))
    segs = json.load(open(a.twin_video + '.segments.json'))
    runs = [os.path.join(a.runs, n) for n in sorted(os.listdir(a.runs))
            if os.path.exists(os.path.join(a.runs, n, 'video.mp4')) and drawn(os.path.join(a.runs, n))]
    twin = cv2.VideoCapture(a.twin_video)
    sim = Sand(Params())
    n = sim.p.n
    out = Writer(a.out, (n + 48, 2 * n + 8))
    for run, seg in zip(runs, segs):
        sim.draw(load_xy(os.path.join(run, 'path.json')))
        reg = refine(cv2.imread(os.path.join(run, 'after.jpg')), sim, base)
        cap = cv2.VideoCapture(os.path.join(run, 'video.mp4'))
        frames = []
        ok, f = cap.read()
        centre, M = rim_of(f, reg)
        idx = [np.arange(f.shape[1], dtype=np.float32)[None, :].repeat(f.shape[0], 0),
               np.arange(f.shape[0], dtype=np.float32)[:, None].repeat(f.shape[1], 1)]
        mx, my = (apply_warp(rectify(c, centre, M, sim.X, sim.Y, reg['scale'], reg['turn'], reg['mirror']),
                             reg.get('warp')) for c in idx)
        while ok:
            frames.append(cv2.remap(f, mx, my, cv2.INTER_LINEAR))
            ok, f = cap.read()
        count = seg['end'] - seg['start']
        pick = np.linspace(0, len(frames) - 1, count).round().astype(int)
        title = os.path.basename(run).split('-', 2)[-1]
        speed = f"x{seg['speed']}"
        for k in pick:
            ok, t = twin.read()
            canvas = np.full((n + 48, 2 * n + 8, 3), 24, np.uint8)
            canvas[48:, :n] = frames[k]
            canvas[48:, n + 8:] = t
            cv2.putText(canvas, f'table   {title}', (10, 34), cv2.FONT_HERSHEY_SIMPLEX, 0.9, (235, 235, 235), 2, cv2.LINE_AA)
            cv2.putText(canvas, f'twin   {speed}', (n + 18, 34), cv2.FONT_HERSHEY_SIMPLEX, 0.9, (150, 210, 255), 2, cv2.LINE_AA)
            out.write(canvas)
        print(f'{title}: {len(frames)} video frames -> {count}', flush=True)
    out.close()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('runs'); ap.add_argument('out')
    ap.add_argument('--reg', required=True)
    ap.add_argument('--sheet')
    ap.add_argument('--hold', type=float, default=1.0, help='seconds per drawing')
    ap.add_argument('--twin-video')
    a = ap.parse_args()
    if a.twin_video:
        return motion(a)
    base = json.load(open(a.reg))
    sim = Sand(Params())
    look = Look(sim)
    pairs, scores = [], []
    for name in sorted(os.listdir(a.runs)):
        run = os.path.join(a.runs, name)
        if not os.path.exists(os.path.join(run, 'after.jpg')) or not drawn(run):
            continue
        sim.draw(load_xy(os.path.join(run, 'path.json')))
        img = cv2.imread(os.path.join(run, 'after.jpg'))
        reg = refine(img, sim, base)
        top = colour_top(img, sim, reg)
        _, _, r2 = fit_render(sim, top.mean(-1))
        scores.append((name, r2))
        print(f'{name:40s} R2 {r2:.3f}', flush=True)
        title = name.split('-', 2)[-1]
        real = label(np.clip(top, 0, 255).astype(np.uint8), f'table  {title}')
        twin = label(look.sand(), f'twin   R2 {r2:.2f}', (150, 210, 255))
        pairs.append(np.concatenate([real, np.full((real.shape[0], 8, 3), 24, np.uint8), twin], 1))
    out = Writer(a.out, pairs[0].shape[:2])
    for p in pairs:
        for _ in range(int(FPS * a.hold)):
            out.write(p)
    out.close()
    if a.sheet:
        small = [cv2.resize(p, (p.shape[1] // 2, p.shape[0] // 2), interpolation=cv2.INTER_AREA) for p in pairs]
        while len(small) % 2:
            small.append(np.zeros_like(small[0]))
        rows = [np.concatenate(small[i:i + 2], 1) for i in range(0, len(small), 2)]
        cv2.imwrite(a.sheet, np.concatenate(rows, 0))
    print(f'mean R2 {np.mean([r for _, r in scores]):.3f} over {len(scores)} drawings')


if __name__ == '__main__':
    main()
