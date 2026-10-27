"""Time-lapse videos from the twin: the sand forming as the ball draws, with the ball shown, in the table's colours.

    python3 video.py stills OUT.png VARIANT...          the face, the first update, and later hours, per variant
    python3 video.py render VARIANT OUT.mp4 [--until HH:MM] [--then HH:MM]
    python3 video.py render files OUT.mp4 DRAWING.json...   exactly what the table was sent, in order
    python3 video.py compose OUT.mp4 A.mp4 B.mp4 ...    side by side, kept in step update by update

The look comes from look/, fitted once to a webcam photo of a 16" table (no camera needed to use it): the
twin's lighting terms are mixed with the weights fitted to that photo, and the photo's own slow lighting and
colour are laid under them. render writes
a segments file next to the video (frame where each update starts) so compose can keep the variants in step.
"""
import argparse
import json
import math
import os
import subprocess

import cv2
import numpy as np

from sand import Sand, Params, _blur
from photo import rim_of, rectify, apply_warp, fit_render, top_down
import clockhub

CALIB = os.path.expanduser('~/Library/Application Support/Drifted/twin-look.npz')   # your own, if you calibrate
BUNDLED = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'look')          # ships with the repo
FPS = 30
START, UPDATE_EVERY = 10 * 60, 5


# ---------------------------------------------------------------------- look

def bundled_look():
    """The look fitted to a photo of a 16" table, as shipped: no camera or recorded runs needed."""
    weights = json.load(open(os.path.join(BUNDLED, 'weights.json')))
    slow = cv2.imread(os.path.join(BUNDLED, 'slow.png')).astype(np.float32)
    backdrop = cv2.imread(os.path.join(BUNDLED, 'backdrop.jpg')).astype(np.float32)
    return weights, slow, backdrop


def calibrate(ref='4-clock', recalibrate=False):
    """Lighting weights and the table's colour. Uses your own calibration if there is one, then the bundled
    look; with recalibrate, fits a new one from the recorded run whose name contains ref (needs runs)."""
    if os.path.exists(CALIB) and not recalibrate:
        d = np.load(CALIB, allow_pickle=True)
        return d['weights'].item(), d['slow'], d['backdrop']
    if os.path.isdir(BUNDLED) and not recalibrate:
        return bundled_look()
    from compare import load_xy
    from evaluate import RUNS, chain
    sim = Sand(Params())
    for name, run, photo in chain(RUNS):
        sim.draw(load_xy(os.path.join(run, 'path.json')))
        if ref in name:
            break
    img = cv2.imread(photo)
    reg = json.load(open(os.path.join(run, 'reg-refined.json')))
    _, weights, r2 = fit_render(sim, top_down(img, sim, reg))
    centre, M = rim_of(img, reg)
    chans = [apply_warp(rectify(img[..., c], centre, M, sim.X, sim.Y, reg['scale'], reg['turn'], reg['mirror']),
                        reg.get('warp')) for c in range(3)]
    backdrop = np.stack(chans, -1)
    slow = np.stack([_blur(c, 40) for c in chans], -1)
    np.savez(CALIB, weights=weights, slow=slow, backdrop=backdrop)
    print(f'calibrated on {name}: R2 {r2:.3f}')
    return weights, slow, backdrop


class Look:
    def __init__(self, sim):
        self.weights, self.slow, self.backdrop = calibrate()
        self.slow_grey = self.slow.mean(-1)
        self.sim = sim
        # sand inside the ball's reach comes from the twin, the rest (rim, frame) from the photo
        self.blend = np.clip((1.06 - sim.R) / 0.04, 0, 1)[..., None]
        self.dx = sim.dx

    def sand(self, h=None):
        """The table's look for heightfield h (default: the sim's own). Fewer lights and shadow directions
        than the fitted renderer, which makes a frame about four times quicker and looks the same."""
        sim = self.sim
        if h is not None:
            sim.h = h.astype(np.float64)
        f = sim.features(lights=24, shadows=())
        gy, gx = np.gradient(sim.h, sim.dx)
        nrm = np.sqrt(1 + gx ** 2 + gy ** 2)
        f['shadow0.4'] = sim._shadowed_ring(-gx / nrm, gy / nrm, 1 / nrm, 0.4, azimuths=12, step=3)
        g = sum(w * f[k] for k, w in self.weights.items() if k in f)
        detail = g - _blur(g, 40)                         # no fine blur: the photo's grooves are sharp too
        shade = 1 + detail / (self.slow_grey + 1e-6)
        rgb = self.slow * shade[..., None]
        out = self.blend * rgb + (1 - self.blend) * self.backdrop
        return np.clip(out, 0, 255).astype(np.uint8)

    def ball(self, img, x, y):
        """Steel ball: dark body, bright rim reflection of the ring light, small specular spot."""
        n = img.shape[0]
        px, py = (x + self.sim.p.extent) / self.dx, (self.sim.p.extent - y) / self.dx
        rad = self.sim.p.ball / self.dx
        s = 4                                          # draw supersampled, then shrink: smooth edges
        r0, c0 = int(py - rad - 3), int(px - rad - 3)
        size = int(2 * rad + 7)
        if r0 < 0 or c0 < 0 or r0 + size > n or c0 + size > n:
            return img
        yy, xx = np.mgrid[0:size * s, 0:size * s] / s
        dx, dy = xx - (px - c0), yy - (py - r0)
        d = np.hypot(dx, dy) / rad
        body = np.clip(1 - d, 0, None) > 0
        shade = 70 + 120 * np.clip(d, 0, 1) ** 6 + 90 * np.exp(-((dx + 0.35 * rad) ** 2 + (dy + 0.35 * rad) ** 2) / (0.06 * rad * rad))
        shadow = np.exp(-((dx - 0.25 * rad) ** 2 + (dy - 0.25 * rad) ** 2) / (0.9 * rad * rad))
        patch = img[r0:r0 + size, c0:c0 + size].astype(np.float32)
        big = cv2.resize(patch, (size * s, size * s), interpolation=cv2.INTER_LINEAR)
        big *= (1 - 0.45 * shadow * ~body)[..., None]
        big = np.where(body[..., None], np.clip(shade, 0, 255)[..., None] * np.array([1.0, 1.0, 1.02]), big)
        img = img.copy()
        img[r0:r0 + size, c0:c0 + size] = cv2.resize(big, (size, size), interpolation=cv2.INTER_AREA).astype(np.uint8)
        return img


_worker = None


def _shade(h):
    """Pool worker: render one heightfield snapshot."""
    global _worker
    if _worker is None:
        _worker = Look(Sand(Params()))
    return _worker.sand(h)


# ---------------------------------------------------------------------- timeline

def hhmm(t):
    return f'{t // 60 % 24:02d}:{t % 60:02d}'


def plan(variant, until):
    """(label, path, speed-up) for every drawing: the face, then an update every 5 minutes."""
    v = clockhub.variant(variant)
    steps = [(f'{hhmm(START)} face', v.face(START), 40)]
    t = START
    while t + UPDATE_EVERY <= until:
        speed = 10 if t == START else 60
        steps.append((hhmm(t + UPDATE_EVERY), v.update(t, t + UPDATE_EVERY), speed))
        t += UPDATE_EVERY
    return steps


class Writer:
    def __init__(self, path, size):
        self.p = subprocess.Popen(['ffmpeg', '-loglevel', 'error', '-y', '-f', 'rawvideo', '-pix_fmt', 'bgr24',
                                   '-s', f'{size[1]}x{size[0]}', '-r', str(FPS), '-i', '-', '-c:v', 'libx264',
                                   '-pix_fmt', 'yuv420p', '-crf', '20', '-preset', 'fast', path],
                                  stdin=subprocess.PIPE)
        self.frames = 0

    def write(self, img):
        self.p.stdin.write(np.ascontiguousarray(img).tobytes())
        self.frames += 1

    def close(self):
        self.p.stdin.close()
        self.p.wait()


def from_files(files):
    """(label, path, speed-up) for drawings saved as JSON: watch the first update closely, skim the rest."""
    steps, first = [], True
    for f in files:
        d = json.load(open(f))
        name = d.get('name', os.path.basename(f))
        if 'update' in os.path.basename(f) or name.startswith('clock 1'):
            speed, first = (10 if first else 60), False
        else:
            speed = 40
        steps.append((name, d['xy'], speed))
    return steps


def render(a):
    from multiprocessing import Pool
    sim = Sand(Params())
    look = Look(Sand(Params()))                         # its own grid: sand() swaps heightfields in
    out = Writer(a.out, (sim.p.n, sim.p.n))
    segments = []
    steps = from_files(a.files) if a.files else plan(a.variant, clockhub.parse(a.until))
    pool = Pool(a.workers)
    for label, xy, speed in steps:
        segments.append({'label': label, 'start': out.frames, 'speed': speed})
        per_frame = clockhub.SPEED * speed / FPS          # path length per video frame
        stamps = max(1, int(per_frame / sim.dx))
        resand = max(1, int(round(0.07 / per_frame)))     # re-render the sand at most every 0.07 r of travel
        snaps, frames = [], []

        def step(s, x, y, n=[0]):
            n[0] += 1
            if n[0] % stamps:
                return
            if not snaps or len(frames) % resand == 0:
                snaps.append(s.h.astype(np.float32))
            frames.append((len(snaps) - 1, x, y))

        sim.draw(xy, on_step=step)
        snaps.append(sim.h.astype(np.float32))
        imgs = pool.map(_shade, snaps, chunksize=4)
        for k, x, y in frames:
            out.write(look.ball(imgs[k], x, y))
        bx, by = sim.ballpos
        for _ in range(int(FPS * 0.4)):                   # a short rest between updates
            out.write(look.ball(imgs[-1], bx, by))
        segments[-1]['end'] = out.frames
        print(f'{label}: {segments[-1]["end"] - segments[-1]["start"]} frames', flush=True)
    if not a.files:                                       # the rest of the day, one still per hour
        v, t = clockhub.variant(a.variant), clockhub.parse(a.until)
        while t + UPDATE_EVERY <= clockhub.parse(a.then):
            sim.draw(v.update(t, t + UPDATE_EVERY))
            t += UPDATE_EVERY
            if t % 60 == 0:
                segments.append({'label': hhmm(t), 'start': out.frames, 'speed': 'hourly'})
                img, (bx, by) = look.sand(sim.h), sim.ballpos
                for _ in range(FPS):
                    out.write(look.ball(img, bx, by))
                segments[-1]['end'] = out.frames
                print(hhmm(t), flush=True)
    pool.close()
    out.close()
    json.dump(segments, open(a.out + '.segments.json', 'w'), indent=1)


def compose(a):
    caps = [cv2.VideoCapture(v) for v in a.videos]
    segs = [json.load(open(v + '.segments.json')) for v in a.videos]
    names = [json.load(open(v + '.segments.json')) and os.path.basename(v).split('.')[0] for v in a.videos]
    w, h = int(caps[0].get(cv2.CAP_PROP_FRAME_WIDTH)), int(caps[0].get(cv2.CAP_PROP_FRAME_HEIGHT))
    pad, top = 12, 64
    W = len(caps) * w + (len(caps) + 1) * pad
    out = Writer(a.out, (h + top + pad, W))
    last = [None] * len(caps)
    for k in range(min(len(s) for s in segs)):
        n = max(s[k]['end'] - s[k]['start'] for s in segs)
        for i in range(n):
            canvas = np.full((h + top + pad, W, 3), 24, np.uint8)
            for j, cap in enumerate(caps):
                if i < segs[j][k]['end'] - segs[j][k]['start']:
                    ok, f = cap.read()
                    if ok:
                        last[j] = f
                x0 = pad + j * (w + pad)
                canvas[top:top + h, x0:x0 + w] = last[j]
                cv2.putText(canvas, names[j], (x0 + 6, top - 14), cv2.FONT_HERSHEY_SIMPLEX, 0.9, (235, 235, 235), 2, cv2.LINE_AA)
            s = segs[0][k]
            txt = f'{s["label"]}   ' + (f'x{s["speed"]}' if s['speed'] != 'hourly' else 'hourly')
            cv2.putText(canvas, txt, (W - 330, top - 14), cv2.FONT_HERSHEY_SIMPLEX, 0.9, (150, 210, 255), 2, cv2.LINE_AA)
            out.write(canvas)
    out.close()


# ---------------------------------------------------------------------- stills

def stills(a):
    """Rows: variants. Columns: the face, after the first update, after 2 hours, after 12 hours."""
    marks = [START, START + 5, START + 120, START + 720]
    rows = []
    for variant in a.variants:
        v = clockhub.variant(variant)
        sim = Sand(Params())
        look = Look(sim)
        sim.draw(v.face(START))
        tiles, t = [look.sand()], START
        while t < marks[-1]:
            sim.draw(v.update(t, t + UPDATE_EVERY))
            t += UPDATE_EVERY
            if t in marks:
                tiles.append(look.sand())
        row = np.concatenate([cv2.resize(x, (420, 420), interpolation=cv2.INTER_AREA) for x in tiles], 1)
        cv2.putText(row, v.label, (10, 34), cv2.FONT_HERSHEY_SIMPLEX, 1.0, (255, 255, 255), 2, cv2.LINE_AA)
        rows.append(row)
        print(variant, 'done', flush=True)
    cv2.imwrite(a.out, np.concatenate(rows, 0))


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest='cmd', required=True)
    s = sub.add_parser('stills'); s.add_argument('out'); s.add_argument('variants', nargs='+')
    r = sub.add_parser('render'); r.add_argument('variant', help="a clockhub variant, or 'files'"); r.add_argument('out')
    r.add_argument('files', nargs='*', help="with variant 'files': drawings (JSON) in drawing order")
    r.add_argument('--workers', type=int, default=6); r.add_argument('--until', default='12:00')
    r.add_argument('--then', default='22:00', help='carry on to here, showing one still per hour')
    c = sub.add_parser('compose'); c.add_argument('out'); c.add_argument('videos', nargs='+')
    a = ap.parse_args()
    {'stills': stills, 'render': render, 'compose': compose}[a.cmd](a)


if __name__ == '__main__':
    main()
