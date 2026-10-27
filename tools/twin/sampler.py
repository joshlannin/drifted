"""Texture sampler for calibrating the sand twin: four textures the designs lean on, one per quadrant.

    python3 sampler.py OUT.json

  top left      tight spiral, 0.035 apart (the fine sweep used behind text)
  top right     wavy rows 0.05 apart (wind, rain and the panel backgrounds)
  bottom left   a five-petal rose through its centre (long curved strokes crossing each other)
  bottom right  rings 0.07 apart with two bold radial hands (the clock face)
Moves between quadrants run round the rim. Stdlib only.
"""
import json
import math
import sys

from testcard import Path, TAU


def spiral(p, cx, cy, r_out, spacing):
    turns = r_out / spacing
    n = int(turns * 240)
    a0 = math.atan2(p.pts[-1][1] - cy, p.pts[-1][0] - cx)
    p.line(cx + r_out * math.cos(a0), cy + r_out * math.sin(a0))
    for i in range(1, n + 1):
        t = i / n
        r, a = r_out * (1 - t), a0 - TAU * turns * t
        p.pts.append((cx + r * math.cos(a), cy + r * math.sin(a)))
    return p


def wavy_rows(p, x0, x1, y0, y1, spacing, amp=0.02, wave=0.18, R=0.9):
    y, k = y1, 0
    while y >= y0:
        h = math.sqrt(max(R * R - y * y, 0))
        lo, hi = max(x0, -h), min(x1, h)
        xs = [lo + (hi - lo) * i / 60 for i in range(61)]
        if k % 2:
            xs.reverse()
        for x in xs:
            p.line(x, y + amp * math.sin(TAU * x / wave + k))
        y -= spacing
        k += 1
    return p


def rose(p, cx, cy, r, k=5):
    n = 900
    for i in range(n + 1):
        t = math.pi * i / n
        rr = r * math.cos(k * t)
        p.line(cx + rr * math.cos(t + math.pi / 2), cy + rr * math.sin(t + math.pi / 2))
    return p


def clock(p, cx, cy, spacing=0.07, r_out=0.33):
    radii = [r_out - spacing * i for i in range(int(r_out / spacing))]
    a12 = math.pi / 2
    for r in radii:
        p.line(cx + r * math.cos(a12), cy + r * math.sin(a12))
        p.arc(cx, cy, r, a12, a12 - TAU)
    p.line(cx, cy)
    for frac, length in ((10 / 60, 0.3), ((4 + 10 / 60) / 12, 0.18)):
        a = a12 - frac * TAU
        ux, uy, nx, ny = math.cos(a), math.sin(a), -math.sin(a), math.cos(a)
        for o in (0, 0.025, -0.025, 0):
            p.line(cx + o * nx, cy + o * ny).line(cx + length * ux + o * nx, cy + length * uy + o * ny)
        p.line(cx, cy)
    return p


def sampler():
    p = Path(0.95 * math.cos(math.radians(135)), 0.95 * math.sin(math.radians(135)))
    spiral(p, -0.42, 0.42, 0.34, 0.035)
    p.rim_to(math.radians(60))
    wavy_rows(p, 0.04, 0.9, 0.04, 0.86, 0.05)
    p.rim_to(math.radians(200))
    rose(p, -0.42, -0.42, 0.33)
    p.rim_to(math.radians(-45))
    clock(p, 0.42, -0.42)
    p.rim_to(math.radians(-45))
    return p


if __name__ == '__main__':
    pts = [(round(x, 4), round(y, 4)) for x, y in sampler().pts]
    L = sum(math.dist(a, b) for a, b in zip(pts, pts[1:]))
    json.dump({'name': 'twin texture sampler', 'xy': pts}, open(sys.argv[1], 'w'))
    print(f'{len(pts)} points, {L:.0f} r, about {L / 0.115 / 60:.0f} min, max r {max(math.hypot(*q) for q in pts):.3f}')
