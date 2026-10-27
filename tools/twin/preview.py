"""Preview a drawing on the sand twin: a still of the sand afterwards, or a time-lapse of the ball drawing it.
No table, camera or recorded runs needed.

    python3 preview.py DRAWING.json OUT.png                 the sand after drawing it
    python3 preview.py DRAWING.json OUT.mp4 [--speed 40]    time-lapse (OUT.gif works too)
    python3 preview.py BEFORE.json DRAWING.json OUT.png     drawings in order: later ones land on earlier sand

DRAWING.json is a drawing as Drifted takes it: {"xy": [[x, y], ...]} in table radii, or {"points": [[theta,
rho], ...]}, or a bare list of [x, y]. The sand starts smooth; the ball starts at the first point unless
--start says where it was. Needs numpy and OpenCV (opencv-python), and ffmpeg for videos.
"""
import argparse
import json
import math
import os
import subprocess
import tempfile

import cv2
import numpy as np

from sand import Sand, Params
from video import Look, Writer, FPS, _shade
from clockhub import SPEED


def load(path):
    d = json.load(open(path))
    if isinstance(d, list):
        return d
    if 'xy' in d:
        return d['xy']
    return [[r * math.cos(t), r * math.sin(t)] for t, r in d['points']]


def length(xy):
    return sum(math.dist(a, b) for a, b in zip(xy, xy[1:]))


def still(sim, look, drawings, out):
    for xy in drawings:
        sim.draw(xy)
    img = look.sand()
    cv2.imwrite(out, look.ball(img, *sim.ballpos))


def video(sim, look, drawings, out, speed, workers):
    from multiprocessing import Pool
    mp4 = out if out.endswith('.mp4') else tempfile.mktemp(suffix='.mp4')
    w = Writer(mp4, (sim.p.n, sim.p.n))
    per_frame = SPEED * speed / FPS                      # path length per video frame
    stamps = max(1, int(per_frame / sim.dx))
    resand = max(1, int(round(0.07 / per_frame)))         # re-render the sand at most every 0.07 r of travel
    snaps, frames = [], []

    def step(s, x, y, n=[0]):
        n[0] += 1
        if n[0] % stamps:
            return
        if not snaps or len(frames) % resand == 0:
            snaps.append(s.h.astype(np.float32))
        frames.append((len(snaps) - 1, x, y))

    for xy in drawings:
        sim.draw(xy, on_step=step)
    snaps.append(sim.h.astype(np.float32))
    with Pool(workers) as pool:
        imgs = pool.map(_shade, snaps, chunksize=4)
    for k, x, y in frames:
        w.write(look.ball(imgs[k], x, y))
    for _ in range(FPS):                                  # hold the finished sand for a second
        w.write(look.ball(imgs[-1], *sim.ballpos))
    w.close()
    if mp4 != out:
        subprocess.run(['ffmpeg', '-loglevel', 'error', '-y', '-i', mp4, '-vf',
                        'fps=12,scale=480:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=96[p];[b][p]paletteuse',
                        out], check=True)
        os.remove(mp4)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('drawings', nargs='+', help='drawing JSON files, in drawing order')
    ap.add_argument('out', help='.png or .jpg for a still; .mp4 or .gif for a time-lapse')
    ap.add_argument('--start', help='where the ball is before the first drawing, as x,y (default: its first point)')
    ap.add_argument('--speed', type=float, default=40, help='time-lapse speed-up (default 40)')
    ap.add_argument('--workers', type=int, default=os.cpu_count() or 4)
    a = ap.parse_args()

    drawings = [load(f) for f in a.drawings]
    sim = Sand(Params())
    if a.start:
        sim.ballpos = tuple(float(v) for v in a.start.split(','))
    look = Look(Sand(Params()))                            # its own grid: sand() swaps heightfields in
    if a.out.lower().endswith(('.mp4', '.gif')):
        video(sim, look, drawings, a.out, a.speed, a.workers)
    else:
        look.sim = sim
        still(sim, look, drawings, a.out)
    L = length(drawings[-1])
    print(f'{a.out}: last drawing {L:.1f} table radii, about {L / SPEED / 60:.0f} min on the table')


if __name__ == '__main__':
    main()
