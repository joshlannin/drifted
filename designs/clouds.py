#!/usr/bin/env python3
"""Floating clouds.

Wavy "wind" lines sweep back and forth across the table. When a line reaches a cloud it
flows around the cloud's scalloped outline instead of through it, so the clouds appear as
smooth, untouched sand floating in a textured sky. One continuous path, no joins.

Usage: python3 designs/clouds.py [OUT.txt] [--spacing 0.085] [--seed 3]
Writes HoMedics Drift .txt (theta millidegrees, rho 0..100000).
"""
import argparse
import math
import random

STEP = 0.005  # path sampling, in table radii
RIM = 0.975   # stay just inside the edge


class Cloud:
    def __init__(self, cx, cy, w, h, lobes, phase):
        self.cx, self.cy, self.w, self.h = cx, cy, w, h
        self.lobes, self.phase = lobes, phase

    def radius(self, phi):
        """Distance from the cloud centre to its edge at angle phi (star-shaped)."""
        s = math.sin(phi)
        a = self.w / 2
        b = self.h * (0.55 if s >= 0 else 0.30)  # puffy top, flatter bottom
        base = a * b / math.hypot(b * math.cos(phi), a * math.sin(phi))
        if s > 0:  # scalloped puffs on top, fading toward the sides
            puff = 0.24 * abs(math.sin(self.lobes * phi + self.phase)) ** 0.7 * s ** 0.4
        else:      # gentle ripples underneath
            puff = 0.05 * abs(math.sin(3 * phi + self.phase))
        return base * (1 + puff)

    def angle(self, x, y):
        return math.atan2(y - self.cy, x - self.cx)

    def contains(self, x, y):
        return math.hypot(x - self.cx, y - self.cy) < self.radius(self.angle(x, y))

    def edge(self, phi):
        r = self.radius(phi)
        return self.cx + r * math.cos(phi), self.cy + r * math.sin(phi)

    def arc(self, phi_in, phi_out, over_top):
        """Boundary points from phi_in to phi_out, going over the top or under the bottom."""
        ccw = (phi_out - phi_in) % (2 * math.pi)
        target = math.pi / 2 if over_top else -math.pi / 2
        passes = (target - phi_in) % (2 * math.pi) <= ccw
        delta = ccw if passes else ccw - 2 * math.pi
        n = max(2, int(abs(delta) * (self.w / 2) * 1.4 / STEP))
        return [self.edge(phi_in + delta * i / n) for i in range(1, n + 1)]


def wind_y(x, y0, phase, clouds):
    """A gently wavy line that also bulges away from nearby clouds, like air flowing past."""
    y = y0 + 0.018 * math.sin(2.6 * x + phase)  # one long, soft swell
    for c in clouds:
        q = ((x - c.cx) / (c.w / 2)) ** 2 + ((y0 - c.cy) / (c.h / 1.6)) ** 2
        y += math.copysign(0.035 * math.exp(-max(0.0, q - 1) * 1.2), y0 - c.cy)
    return y


def rim_arc(p, q, r=None):
    r = r or RIM
    a0, a1 = math.atan2(p[1], p[0]), math.atan2(q[1], q[0])
    d = (a1 - a0 + math.pi) % (2 * math.pi) - math.pi  # short way round
    n = max(1, int(abs(d) * r / STEP))
    return [(r * math.cos(a0 + d * i / n), r * math.sin(a0 + d * i / n)) for i in range(1, n + 1)]


def build(spacing, seed):
    rng = random.Random(seed)
    clouds = [
        Cloud(-0.28, 0.30, 0.95, 0.42, 4, rng.uniform(0, 1)),
        Cloud(0.40, -0.12, 0.70, 0.32, 3, rng.uniform(0, 1)),
        Cloud(-0.22, -0.52, 0.52, 0.24, 3, rng.uniform(0, 1)),
        Cloud(0.42, 0.56, 0.36, 0.17, 2, rng.uniform(0, 1)),
    ]
    path = []
    y0 = -0.93
    row = 0
    while y0 < 0.94:
        half = math.sqrt(max(0.0, 1 - y0 ** 2))
        xs = [-half + i * STEP for i in range(int(2 * half / STEP) + 1)]
        if row % 2:
            xs.reverse()
        phase = row * 0.25  # neighbouring lines swell almost together, like a breeze
        # Keep only the part of the wavy line inside the rim, so rim turns join cleanly.
        xs = [x for x in xs if math.hypot(x, wind_y(x, y0, phase, clouds)) <= RIM]
        line = []
        inside = None  # (cloud, phi_in)
        for x in xs:
            y = wind_y(x, y0, phase, clouds)
            hit = next((c for c in clouds if c.contains(x, y)), None)
            if inside is None and hit is not None:
                inside = (hit, hit.angle(x, y))
            elif inside is not None and hit is not inside[0]:
                c, phi_in = inside
                line += c.arc(phi_in, c.angle(x, y), over_top=y0 >= c.cy)
                inside = None
                line.append((x, y))
            elif inside is None:
                line.append((x, y))
        if line:
            if path:
                path += rim_arc(path[-1], line[0])
            path += line
        y0 += spacing
        row += 1
    return path


def write_drift(path, out):
    with open(out, "w") as f:
        for x, y in path:
            rho = min(1.0, math.hypot(x, y))
            theta = round(math.degrees(math.atan2(y, x)) * 1000) % 360000
            f.write(f"{theta},{round(rho * 100000)}\n")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("out", nargs="?", default="clouds.txt")
    ap.add_argument("--spacing", type=float, default=0.1, help="gap between wind lines (table radii)")
    ap.add_argument("--seed", type=int, default=3, help="varies the puff shapes")
    args = ap.parse_args()
    pts = build(args.spacing, args.seed)
    write_drift(pts, args.out)
    length = sum(math.dist(a, b) for a, b in zip(pts, pts[1:]))
    print(f"{args.out}: {len(pts)} points, {math.ceil(len(pts) / 40)} pages, {length:.1f} radii of travel")
