"""Calibration test card for the sand twin: one drawing that measures what the twin needs to know.

    python3 testcard.py OUT.json

Four quadrants, each on a fine local sweep (the patch test brings its own rings):
  top left      spacing ladder: line pairs 0.04-0.12 apart, joined by hairpins (where do grooves merge?)
  top right     corners and circles: turns from 30 to 150 degrees, circles r 0.04-0.14 (ball lag, smallest shape)
  bottom left   crossings at 90, 45 and 20 degrees over parallel lines, and a retraced line (what erases?)
  bottom right  the patch test: a hand on rings, patched out twice (does the old hand leave a scar?)
Every move between them is part of the path, so the twin simulates those as well.
Stdlib only.
"""
import json
import math
import sys

STEP = 0.01
TAU = 2 * math.pi


class Path:
    def __init__(self, x, y):
        self.pts = [(x, y)]

    def line(self, x, y):
        x0, y0 = self.pts[-1]
        n = max(1, int(math.dist((x0, y0), (x, y)) / STEP))
        self.pts += [(x0 + (x - x0) * i / n, y0 + (y - y0) * i / n) for i in range(1, n + 1)]
        return self

    def arc(self, cx, cy, r, a0, a1):
        n = max(2, int(abs(a1 - a0) * r / STEP))
        self.pts += [(cx + r * math.cos(a0 + (a1 - a0) * i / n), cy + r * math.sin(a0 + (a1 - a0) * i / n))
                     for i in range(1, n + 1)]
        return self

    def rim_to(self, a, r=0.95):
        """Out to the rim, round it, and stop there: moves between sections stay at the edge."""
        x, y = self.pts[-1]
        a0 = math.atan2(y, x)
        self.line(r * math.cos(a0), r * math.sin(a0))
        d = (a - a0 + math.pi) % TAU - math.pi
        return self.arc(0, 0, r, a0, a0 + d)


def sweep(p, x0, x1, y0, y1, spacing=0.035, vertical=True, R=0.9, end_left=True):
    """Fine boustrophedon sweep of a box (clipped to the disc) so the test strokes sit on even sand.
    Rows run across the strokes drawn on top. Ends on the left (or right) edge, near where the strokes begin."""
    if vertical:
        n = int((x1 - x0) / spacing)
        xs = [x1 - i * spacing for i in range(n + 1)] if end_left else [x0 + i * spacing for i in range(n + 1)]
        for k, x in enumerate(xs):
            h = math.sqrt(max(R * R - x * x, 0))
            lo, hi = max(y0, -h), min(y1, h)
            a, b = (hi, lo) if k % 2 == 0 else (lo, hi)
            p.line(x, a).line(x, b)
    else:
        n = int((y1 - y0) / spacing)
        for k in range(n + 1):
            y = y1 - k * spacing
            h = math.sqrt(max(R * R - y * y, 0))
            lo, hi = max(x0, -h), min(x1, h)
            a, b = (lo, hi) if k % 2 == 0 else (hi, lo)
            p.line(a, y).line(b, y)
    return p


def ladder(p, R=0.86):
    y, x1 = 0.74, -0.1
    for s in (0.04, 0.05, 0.06, 0.08, 0.10, 0.12):
        x0 = -min(0.7, math.sqrt(R * R - y * y))
        p.line(x0, y).line(x1, y).arc(x1, y - s / 2, s / 2, math.pi / 2, -math.pi / 2).line(x0, y - s)
        y -= s + 0.06
    return p


def corners(p):
    # a zigzag whose turns get sharper: interior angles 150, 120, 90, 60, 30
    x, y, heading, L = 0.12, 0.66, 0.0, 0.11
    p.line(x, y)
    for k, interior in enumerate((150, 120, 90, 60, 30)):
        x, y = x + L * math.cos(heading), y + L * math.sin(heading)
        p.line(x, y)
        turn = math.radians(180 - interior)
        heading = (heading - turn) if k % 2 == 0 else (heading + turn)
    p.line(x + L * math.cos(heading), y + L * math.sin(heading))
    # circles of shrinking radius along a baseline
    bx, by = 0.1, 0.12
    p.line(bx, by)
    for r in (0.10, 0.07, 0.05, 0.035):
        p.arc(bx, by + r, r, -math.pi / 2, 3 * math.pi / 2)
        bx += 2 * r + 0.06
        p.line(bx, by)
    return p


def crossings(p):
    x0, x1 = -0.7, -0.2
    ys = [-0.18, -0.28, -0.38, -0.48, -0.58]
    p.line(x0, ys[0])
    for i, y in enumerate(ys):
        a, b = (x0, x1) if i % 2 == 0 else (x1, x0)
        p.line(a, y).line(b, y)
    # cross them: 90, 45 and 20 degrees
    for cx, ang in ((-0.72, 90), (-0.5, 45), (-0.3, 20)):
        t = math.radians(ang)
        h = min(0.26 / math.sin(t), 0.3)
        p.line(cx - h * math.cos(t), -0.38 - h * math.sin(t))
        p.line(cx + h * math.cos(t), -0.38 + h * math.sin(t))
    # a line drawn once, then retraced twice: does retracing change it?
    p.line(-0.62, -0.72).line(-0.22, -0.72).line(-0.62, -0.72).line(-0.22, -0.72)
    return p


def patch_test(p):
    cx, cy = 0.42, -0.4
    radii = [0.08 + 0.08 * i for i in range(4)]
    a12 = math.pi / 2
    for r in radii:                                   # rings, joined along 12 o'clock
        p.line(cx + r * math.cos(a12), cy + r * math.sin(a12))
        p.arc(cx, cy, r, a12, a12 - TAU)
    p.line(cx, cy)

    def hand(a, r1=0.34, w=0.025):
        ux, uy, nx, ny = math.cos(a), math.sin(a), -math.sin(a), math.cos(a)
        for o in (0, w, -w, 0):
            p.line(cx + o * nx, cy + o * ny).line(cx + r1 * ux + o * nx, cy + r1 * uy + o * ny)
        p.line(cx, cy)

    def patch(a_old, a_new, over=0.25):
        d = 1 if a_old > a_new else -1
        for r in radii:
            p.line(cx + r * math.cos(a_new), cy + r * math.sin(a_new))
            p.arc(cx, cy, r, a_new, a_old + d * over)
            p.arc(cx, cy, r, a_old + d * over, a_new)
        p.line(cx, cy)

    a = [a12 - math.radians(d) for d in (0, 50, 100)]
    hand(a[0])
    patch(a[0], a[1])
    hand(a[1])
    patch(a[1], a[2])
    hand(a[2])
    return p


def card():
    p = Path(0.95 * math.cos(math.radians(100)), 0.95 * math.sin(math.radians(100)))
    sweep(p, -0.76, -0.04, -0.06, 0.8)
    ladder(p)
    p.rim_to(math.radians(80))
    sweep(p, 0.04, 0.88, 0.04, 0.74, vertical=False)
    corners(p)
    p.rim_to(math.radians(185))
    sweep(p, -0.78, -0.12, -0.78, -0.08)
    crossings(p)
    p.rim_to(math.radians(-60))
    patch_test(p)
    p.rim_to(math.radians(-60))
    return p


if __name__ == '__main__':
    pts = card().pts
    pts = [(round(x, 4), round(y, 4)) for x, y in pts]
    L = sum(math.dist(a, b) for a, b in zip(pts, pts[1:]))
    json.dump({'name': 'twin test card', 'xy': pts}, open(sys.argv[1], 'w'))
    print(f'{len(pts)} points, {L:.0f} r of path, about {L / 0.115 / 60:.0f} min, max r {max(math.hypot(*q) for q in pts):.3f}')
