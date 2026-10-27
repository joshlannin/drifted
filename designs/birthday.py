#!/usr/bin/env python3
"""Happy Birthday banner: bunting across the top, three lines of block text, a wavy flourish.

Text on a sand table has to be one continuous line. Every glyph below starts and ends on its
baseline and retraces its own strokes where it needs to move inside the letter, so letters
join along the baseline: each word sits on an underline that runs out to the rim. Rows
alternate direction (the ball doesn't care) and are joined along the rim.

Usage: python3 designs/birthday.py [OUT.txt] [--lines HAPPY BIRTHDAY SYDNEY]
Glyphs available: A B D E H I N P R S T Y (add more to GLYPHS).
"""
import argparse
import math

STEP = 0.005   # output sampling, table radii
RIM = 0.975    # stay just inside the edge
CAP = 0.27     # cap height, table radii
UNIT = 0.152   # width of a 1.0-wide glyph
GAP = 0.6      # space between letters, in glyph units (> ball width)


def arc(cx, cy, rx, ry, a0, a1, n=28):
    return [(cx + rx * math.cos(math.radians(a0 + (a1 - a0) * i / n)),
             cy + ry * math.sin(math.radians(a0 + (a1 - a0) * i / n))) for i in range(n + 1)]


def glyph_s():
    terminal = arc(.5, .26, .5, .26, -90, -150)
    body = arc(.5, .26, .5, .26, -90, 90) + arc(.5, .76, .45, .24, -90, -325)
    return .95, terminal + terminal[::-1] + body + body[::-1]


# Each glyph: (width, points in a 1-tall box). Starts and ends on the baseline (y = 0).
GLYPHS = {
    "A": lambda: (1.0, [(0, 0), (.5, 1), (1, 0), (.75, .5), (.25, .5), (.75, .5), (1, 0)]),
    "B": lambda: (.95, [(0, 0), (0, 1), (.45, 1)] + arc(.45, .75, .42, .25, 90, -90)
                  + [(0, .5), (.5, .5)] + arc(.5, .25, .45, .25, 90, -90) + [(0, 0)]),
    "D": lambda: (.95, [(0, 0), (0, 1), (.4, 1)] + arc(.4, .5, .55, .5, 90, -90) + [(0, 0)]),
    "E": lambda: (.8, [(0, 0), (0, 1), (.8, 1), (0, 1), (0, .5), (.65, .5), (0, .5), (0, 0), (.8, 0)]),
    "H": lambda: (1.0, [(0, 0), (0, 1), (0, .5), (1, .5), (1, 1), (1, 0)]),
    "I": lambda: (.5, [(.25, 0), (.25, 1), (0, 1), (.5, 1), (.25, 1), (.25, 0)]),
    "N": lambda: (1.0, [(0, 0), (0, 1), (1, 0), (1, 1), (1, 0)]),
    "P": lambda: (.9, [(0, 0), (0, 1), (.45, 1)] + arc(.45, .725, .45, .275, 90, -90) + [(0, .45), (0, 0)]),
    "R": lambda: (.95, [(0, 0), (0, 1), (.45, 1)] + arc(.45, .75, .45, .25, 90, -90)
                  + [(0, .5), (.35, .5), (.95, 0)]),
    "S": glyph_s,
    "T": lambda: (1.0, [(.5, 0), (.5, 1), (0, 1), (1, 1), (.5, 1), (.5, 0)]),
    "Y": lambda: (1.0, [(.5, 0), (.5, .5), (0, 1), (.5, .5), (1, 1), (.5, .5), (.5, 0)]),
}


def rim_x(y):
    return math.sqrt(max(0.0, RIM ** 2 - y ** 2))


def word(text, baseline, rtl):
    """Path for one underlined word, from rim to rim."""
    glyphs = [GLYPHS[ch]() for ch in text.upper()]
    total = sum(w for w, _ in glyphs) * UNIT + GAP * UNIT * (len(glyphs) - 1)
    x = -total / 2
    placed = []
    for w, pts in glyphs:
        placed.append([(x + px * UNIT, baseline + py * CAP) for px, py in pts])
        x += (w + GAP) * UNIT
    if rtl:
        placed = [g[::-1] for g in placed[::-1]]
    edge = rim_x(baseline)
    path = [(edge if rtl else -edge, baseline)]
    for g in placed:
        path += g  # the move to g[0] runs along the baseline (the underline)
    path.append((-edge if rtl else edge, baseline))
    return path


def bunting(y_mid=0.73, flags=7, drop=0.10):
    """Sagging string with triangular pennants, left to right."""
    half = 0.56
    sag = lambda x: y_mid + 0.25 * x * x
    pts = [(-half, sag(-half))]
    span = 2 * half / flags
    for i in range(flags):
        a = -half + i * span + span * 0.12
        b = -half + (i + 1) * span - span * 0.12
        m = (a + b) / 2
        # String a→b, down to the tip and back to a (a closed pennant), then retrace to b.
        pts += [(a, sag(a)), (b, sag(b)), (m, sag(m) - drop), (a, sag(a)), (b, sag(b))]
    pts.append((half, sag(half)))
    return pts


def flourish(y=-0.74, amp=0.035):
    half = rim_x(y) - 0.02
    n = 200
    return [(-half + 2 * half * i / n, y + amp * math.sin(9 * (-half + 2 * half * i / n))) for i in range(n + 1)]


def rim_arc(p, q):
    a0, a1 = math.atan2(p[1], p[0]), math.atan2(q[1], q[0])
    d = (a1 - a0 + math.pi) % (2 * math.pi) - math.pi
    return [(RIM * math.cos(a0 + d * i / 40), RIM * math.sin(a0 + d * i / 40)) for i in range(41)]


def join(parts):
    path = []
    for part in parts:
        if path:
            a, b = path[-1], part[0]
            # Hop between sections along the rim when both ends are out there.
            if math.hypot(*a) > RIM - 0.03 and math.hypot(*b) > RIM - 0.03:
                path += rim_arc(a, b)
        path += part
    return path


def densify(path):
    out = [path[0]]
    for p in path[1:]:
        a = out[-1]
        n = max(1, math.ceil(math.dist(a, p) / STEP))
        out += [(a[0] + (p[0] - a[0]) * i / n, a[1] + (p[1] - a[1]) * i / n) for i in range(1, n + 1)]
    return out


def build(lines):
    baselines = {1: [-0.13], 2: [0.06, -0.32], 3: [0.22, -0.13, -0.48]}[len(lines)]
    parts = [bunting()]
    for i, (text, base) in enumerate(zip(lines, baselines)):
        parts.append(word(text, base, rtl=(i % 2 == 0)))  # bunting ends on the right
    flo = flourish()
    # Bunting ends right; each row flips sides, so after an odd number of rows we're on the left.
    parts.append(flo if len(lines) % 2 == 1 else flo[::-1])
    return densify(join(parts))


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("out", nargs="?", default="birthday.txt")
    ap.add_argument("--lines", nargs="+", default=["HAPPY", "BIRTHDAY", "SYDNEY"])
    args = ap.parse_args()
    pts = build(args.lines)
    with open(args.out, "w") as f:
        for x, y in pts:
            theta = round(math.degrees(math.atan2(y, x)) * 1000) % 360000
            f.write(f"{theta},{round(min(1.0, math.hypot(x, y)) * 100000)}\n")
    length = sum(math.dist(a, b) for a, b in zip(pts, pts[1:]))
    print(f"{args.out}: {len(pts)} points, {math.ceil(len(pts) / 40)} pages, {length:.1f} radii of travel")
