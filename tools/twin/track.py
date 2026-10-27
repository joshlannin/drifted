"""Find the ball in a run's video and write where it really went, in table radii.

    python3 track.py RUN_DIR [--reg REG.json]        writes RUN_DIR/ball.csv (t, x, y, score)

Each frame is straightened onto the twin's grid with the run's registration, then the ball is the strongest
small bright spot (its specular highlight) that is moving: each frame is compared with one about a second
earlier, so fixed glints on the sand or rim drop out. It is searched near where it was last seen, but
re-acquired anywhere if something much stronger turns up. Frames without a clear ball get no position.
"""
import argparse
import csv
import json
import os

import cv2
import numpy as np

from sand import Sand, Params, _blur
from photo import rim_of, rectify, apply_warp


def spot_map(top):
    """Highlight detector: small bright spots stand out, wide bright areas (lit sand) don't."""
    return _blur(top, 1) - _blur(top, 6)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('run')
    ap.add_argument('--reg')
    ap.add_argument('--every', type=int, default=1, help='use every Nth frame')
    a = ap.parse_args()
    reg = json.load(open(a.reg or os.path.join(a.run, 'reg.json')))
    sim = Sand(Params())
    n, ext = sim.p.n, sim.p.extent
    cap = cv2.VideoCapture(os.path.join(a.run, 'video.mp4'))
    fps = cap.get(cv2.CAP_PROP_FPS) or 5
    ok, frame = cap.read()
    centre, M = rim_of(frame, reg)
    # one remap for every frame: precompute where each grid cell samples the frame
    sc, tn, mir = reg['scale'], reg['turn'], reg['mirror']
    probe_x = rectify(np.tile(np.arange(frame.shape[1], dtype=np.float32), (frame.shape[0], 1)), centre, M,
                      sim.X, sim.Y, sc, tn, mir)
    probe_y = rectify(np.tile(np.arange(frame.shape[0], dtype=np.float32)[:, None], (1, frame.shape[1])), centre, M,
                      sim.X, sim.Y, sc, tn, mir)
    mx, my = apply_warp(probe_x, reg.get('warp')), apply_warp(probe_y, reg.get('warp'))
    inside = sim.R < 0.995                       # the rim lip has highlights of its own
    out, last, i, history = [], None, 0, []
    lag_frames = max(1, int(round(fps)))              # compare with the frame about a second earlier
    while ok:
        g = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY).astype(np.float32)
        top = cv2.remap(g, mx, my, cv2.INTER_LINEAR)
        history.append(top)
        if len(history) > lag_frames + 1:
            history.pop(0)
        if i % a.every == 0:
            spot = spot_map(top)
            if len(history) > lag_frames:
                moving = _blur(np.abs(top - history[0]), 3)
                spot = spot + 0.5 * moving
            s = np.where(inside, spot, -1e9)
            k_all = int(np.argmax(s))
            if last is not None:                      # the ball moves at most ~0.03 r per frame at 5 fps
                win = np.hypot(sim.X - last[0], sim.Y - last[1]) < 0.12
                sw = np.where(win, s, -1e9)
                if sw.max() * 1.5 >= s.flat[k_all]:
                    s = sw
            k = int(np.argmax(s))
            r, c = divmod(k, n)
            val = float(s.flat[k])
            # sub-cell refinement: brightness-weighted centroid around the peak
            r0, r1, c0, c1 = max(r - 3, 0), min(r + 4, n), max(c - 3, 0), min(c + 4, n)
            w = np.clip(s[r0:r1, c0:c1], 0, None)
            if w.sum() > 0:
                rr, cc = np.mgrid[r0:r1, c0:c1]
                r, c = (rr * w).sum() / w.sum(), (cc * w).sum() / w.sum()
            x, y = (c + 0.5) * 2 * ext / n - ext, ext - (r + 0.5) * 2 * ext / n
            good = val > 25
            out.append((i / fps, x if good else '', y if good else '', round(val, 1)))
            if good:
                last = (x, y)
        ok, frame = cap.read()
        i += 1
    with open(os.path.join(a.run, 'ball.csv'), 'w', newline='') as f:
        wr = csv.writer(f)
        wr.writerow(['t', 'x', 'y', 'score'])
        wr.writerows(out)
    found = sum(1 for o in out if o[1] != '')
    print(f'{len(out)} frames, ball found in {found}')


if __name__ == '__main__':
    main()
