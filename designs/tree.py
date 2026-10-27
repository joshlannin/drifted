#!/usr/bin/env python3
"""Fractal tree: a trunk rising from the rim that splits in two, again and again, into a wide crown.

The ball never lifts, so a branching shape has to be one line. Each branch is drawn out to its tip
and back along the same groove, and the sand doesn't show a retraced groove as a second line, so
every way back is invisible and the whole tree is one path from its root.

On cleared sand the tree stands out best, so by default the drawing starts with a clear: a spiral
from the centre out to the rim that ends exactly at the root, where the trunk begins. The spiral's
fine rings stay visible behind the tree. --no-clear draws only the tree.

Usage: python3 designs/tree.py [OUT] [--depth 8] [--no-clear]
OUT ending in .json is an `xy` drawing for driftd's /show; otherwise it's HoMedics Drift .txt.
About 16 minutes to draw with the clear, 6 without.
"""
import argparse
import json
import math

STEP = 0.01     # path sampling, table radii
R = 0.97        # the root sits on the rim here, and the crown stays inside it
CLEAR = 0.045   # spacing of the clearing spiral (rings this close stay distinct)
SPREAD = 24     # degrees each branch turns away from its parent
SHRINK = 0.71   # each branch is this much shorter than its parent
TRUNK = 0.5     # trunk length before scaling to fit


def clear():
    """Spiral from the centre out to the rim, ending at the bottom, where the trunk starts."""
    turns = R / CLEAR
    n = int(turns * 240)
    end = -math.pi / 2
    return [(R * i / n * math.cos(end - 2 * math.pi * turns * (1 - i / n)),
             R * i / n * math.sin(end - 2 * math.pi * turns * (1 - i / n))) for i in range(n + 1)]


def tree(depth):
    pts = [(0.0, -R)]

    def line(x0, y0, x1, y1):
        n = max(1, int(math.dist((x0, y0), (x1, y1)) / STEP))
        pts.extend((x0 + (x1 - x0) * i / n, y0 + (y1 - y0) * i / n) for i in range(1, n + 1))

    def branch(x, y, heading, length, d):
        tx, ty = x + length * math.cos(heading), y + length * math.sin(heading)
        line(x, y, tx, ty)
        if d > 1:
            for turn in (SPREAD, -SPREAD):
                branch(tx, ty, heading + math.radians(turn), length * SHRINK, d - 1)
        line(tx, ty, x, y)

    branch(0.0, -R, math.pi / 2, TRUNK, depth)
    # scale about the root until the crown fits inside the rim
    lo, hi = 0.0, 1.0
    for _ in range(30):
        s = (lo + hi) / 2
        if max(math.hypot(x * s, -R + (y + R) * s) for x, y in pts) <= R:
            lo = s
        else:
            hi = s
    return [(x * lo, -R + (y + R) * lo) for x, y in pts]


def write(pts, out, name):
    with open(out, "w") as f:
        if out.endswith(".json"):
            json.dump({"name": name, "xy": [[round(x, 4), round(y, 4)] for x, y in pts]}, f)
        else:
            for x, y in pts:
                theta = round(math.degrees(math.atan2(y, x)) * 1000) % 360000
                f.write(f"{theta},{round(min(1.0, math.hypot(x, y)) * 100000)}\n")


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("out", nargs="?", default="tree.txt")
    ap.add_argument("--depth", type=int, default=8, help="levels of branching (each doubles the tips)")
    ap.add_argument("--no-clear", action="store_true", help="draw only the tree, over whatever is there")
    a = ap.parse_args()
    pts = tree(a.depth) if a.no_clear else clear() + tree(a.depth)[1:]
    write(pts, a.out, "fractal-tree")
    length = sum(math.dist(p, q) for p, q in zip(pts, pts[1:]))
    print(f"{a.out}: {len(pts)} points, {length:.1f} radii, about {length / 0.108 / 60:.0f} min to draw")
