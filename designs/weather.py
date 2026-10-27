#!/usr/bin/env python3
"""Weather: an emblem for the day's conditions, under the forecast high in big digits.

    sunny   a sun with pointed rays; ripples spread from it across the table
    cloudy  two clouds floating in drifting wind lines
    rain    a cloud and raindrops, left smooth in slanting rain
    snow    a big snowflake and two small ones, in gently drifting lines

Shapes and the temperature sit on swept, smooth sand; everything else is textured. Background
lines flow around each shape instead of through it, which is what outlines the shape. The ball
never lifts, so the picture is one path, drawn in this order:

1. each shape: a tight spiral that sweeps it smooth, its outline (twice), then its detail;
2. the background, row by row. The rows also wipe out the moves between shapes, as long as those
   moves cross them, so shapes are ordered to make that happen;
3. the temperature panel across the top: swept smooth, then bold digits, each drawn three times
   side by side so it stands out from the sweep lines around it.

The drawing ends inside the panel. `--update` makes a short segment that re-sweeps just the
panel and writes a new number, leaving the rest of the picture alone.

Usage:
  python3 designs/weather.py sunny 72 [OUT]       full picture (about 15 minutes to draw)
  python3 designs/weather.py --update 75 [OUT]    temperature only (about 6 minutes)
Temperatures can be -99..199. OUT ending in .json is an `xy` drawing for driftd's /show;
otherwise it's HoMedics Drift .txt. --rotate turns the picture to match how the table sits.
Digits are 0.45 radii tall for one or two digits, a little less for three.
"""
import argparse
import json
import math

STEP = 0.01     # path sampling, in table radii
RIM = 0.96      # background rows reach this far out
BALL = 0.07     # groove width
SWEEP = 0.05    # spacing of the sweep rows above the number
SHAPE_SWEEP = 0.04  # spacing of the spiral that sweeps each shape smooth

# Temperature panel: the cap of the table above PANEL_Y.
PANEL_Y = 0.12
PANEL_RIM = 0.92  # the panel's sweep stops short of the wall, where swept sand piles up
TEXT_RIM = 0.88   # outer edge of the number's outermost groove
BASELINE = PANEL_Y + 0.08
CAP = 0.45      # digit height, shrunk if the number doesn't fit
BOLD = 0.03     # digits are drawn three times, this far either side of the stroke
GAP = 0.19      # between digits, centre to centre of the strokes (> BALL + 2 * BOLD)
BAND_SWEEP = 0.035  # finer sweep around the digits, so they stand out from it
DEGREE = 0.065  # radius of the degree ring


def arc(cx, cy, rx, ry, a0, a1, n=None):
    n = n or max(4, int(abs(a1 - a0) / 6))
    return [(cx + rx * math.cos(math.radians(a0 + (a1 - a0) * i / n)),
             cy + ry * math.sin(math.radians(a0 + (a1 - a0) * i / n))) for i in range(n + 1)]


def polar(c, r, phi):
    return (c[0] + r * math.cos(phi), c[1] + r * math.sin(phi))


def cross(u, v):
    return u[0] * v[1] - u[1] * v[0]


# ---------------------------------------------------------------------------------------------
# Shapes

class Shape:
    """A star-shaped region around `c` with edge radius(phi). The background flows around it."""

    def __init__(self, c, radius, snap=None, detail=None):
        self.c, self.radius = c, radius
        self.snap = snap or (lambda phi: phi)        # preferred exit angle near phi
        self.detail = detail or (lambda phi: [])     # drawn after sweeping; starts and ends at edge(phi)
        self.rmax = max(radius(2 * math.pi * i / 720) for i in range(720))

    def edge(self, phi, scale=1.0):
        return polar(self.c, scale * self.radius(phi), phi)

    def angle(self, p):
        return math.atan2(p[1] - self.c[1], p[0] - self.c[0])

    def contains(self, p):
        d = math.dist(p, self.c)
        return d < self.rmax and d < self.radius(self.angle(p))

    def walk(self, phi0, delta):
        n = max(2, int(abs(delta) * self.rmax / STEP))
        return [self.edge(phi0 + delta * i / n) for i in range(1, n + 1)]

    def around(self, a, b):
        """Edge points from where a row enters (a) to where it leaves (b), on the row's side."""
        phi_a, phi_b = self.angle(a), self.angle(b)
        ccw = cross((b[0] - a[0], b[1] - a[1]), (self.c[0] - a[0], self.c[1] - a[1])) > 0
        delta = (phi_b - phi_a) % (2 * math.pi)
        return self.walk(phi_a, delta if ccw else delta - 2 * math.pi)

    def draw(self, toward):
        """Sweep smooth from the centre out, trace the outline twice (once just inside it) so the
        shape stands out, then add the detail. Ends on the edge."""
        end = self.snap(math.atan2(toward[1] - self.c[1], toward[0] - self.c[0]))
        # Turns are packed closer where the edge is nearer the centre; size them for a typical radius.
        mean = sum(self.radius(2 * math.pi * i / 360) for i in range(360)) / 360
        total = 2 * math.pi * math.ceil((mean + self.rmax) / 2 / SHAPE_SWEEP)
        pts, t = [], 0.0
        while t < total:
            pts.append(self.edge(end - total + t, t / total))
            t += STEP / max(t / total * self.rmax, 0.03)
        pts += [self.edge(end)] + self.walk(end, 2 * math.pi)
        inset = [self.edge(end - 2 * math.pi * i / 720, 1 - BALL / 2 / self.radius(end - 2 * math.pi * i / 720))
                 for i in range(721)]
        return pts + inset + [self.edge(end)] + self.detail(end)


def sun(c, r_in=0.22, r_out=0.36, rays=12, disc=0.17):
    def radius(phi):
        u = (phi * rays / (2 * math.pi)) % 1
        return r_in + (r_out - r_in) * abs(2 * u - 1)   # tips at u = 0, valleys at u = 0.5

    def snap(phi):  # leave through a valley, so the way in to the disc is short
        return (math.floor(phi * rays / (2 * math.pi)) + 0.5) * 2 * math.pi / rays

    def detail(phi):
        n = int(2 * math.pi * disc / STEP)
        return [polar(c, disc, phi + 2 * math.pi * i / n) for i in range(n + 1)] + [polar(c, r_in, phi)]

    return Shape(c, radius, snap, detail)


def cloud(c, w, h, lobes=3, phase=1.0):
    def radius(phi):
        s = math.sin(phi)
        a, b = w / 2, h * (0.55 if s >= 0 else 0.30)    # puffy top, flatter bottom
        base = a * b / math.hypot(b * math.cos(phi), a * math.sin(phi))
        if s > 0:
            return base * (1 + 0.5 * abs(math.sin(lobes * phi + phase)) ** 0.7 * s ** 0.3)
        return base * (1 + 0.05 * abs(math.sin(3 * phi + phase)))

    return Shape(c, radius)


def drop(c, a=0.1, tip=0.26):
    """A raindrop: a round bottom of radius a, pointed tip `tip` above its centre."""
    cone = math.acos(a / tip)

    def radius(phi):
        off = abs((phi - math.pi / 2 + math.pi) % (2 * math.pi) - math.pi)   # angle from straight up
        return a / math.cos(off - cone) if off < cone else a

    return Shape(c, radius)


def flake(c, r, tilt=math.pi / 2, twigs=True):
    """Snowflake: a hexagon swept smooth, with an arm out to each corner and, on big flakes,
    a pair of twigs on each arm."""
    step = math.pi / 3
    length = 0.9 * r

    def radius(phi):  # hexagon with corners on the arms
        d = (phi - tilt) % step - step / 2   # angle from the nearest edge's midpoint
        return r * math.cos(step / 2) / math.cos(d)

    def snap(phi):  # leave along an arm
        return tilt + round((phi - tilt) / step) * step

    def arm(phi):
        tip = polar(c, length, phi)
        if not twigs:
            return [tip, c]
        b = polar(c, 0.5 * length, phi)
        twig = 0.32 * length
        return [b, polar(b, twig, phi + 0.8), b, polar(b, twig, phi - 0.8), b, tip, c]

    def detail(phi):
        pts = [c]
        for k in range(1, 7):
            pts += arm(phi + k * step)
        return pts[:-1] + [polar(c, r, phi)]   # the last arm runs on out to the corner

    return Shape(c, radius, snap, detail)


# ---------------------------------------------------------------------------------------------
# Frames: horizontal bands of the table (below the panel) that background rows are clipped to.
# Moves between rows run along the frame's edge.

def line(a, b):
    n = max(1, math.ceil(math.dist(a, b) / STEP))
    return [(a[0] + (b[0] - a[0]) * i / n, a[1] + (b[1] - a[1]) * i / n) for i in range(n + 1)]


def nearest(pts, p):
    return min(range(len(pts)), key=lambda i: math.dist(pts[i], p))


def rim_arc(a, b):
    """Round the rim from a to b, the short way."""
    a0 = math.atan2(a[1], a[0])
    d = (math.atan2(b[1], b[0]) - a0 + math.pi) % (2 * math.pi) - math.pi
    n = max(1, int(abs(d) * RIM / STEP))
    return [polar((0, 0), RIM, a0 + d * i / n) for i in range(1, n + 1)] + [b]


class Frame:
    """The part of the table between heights lo and hi (by default, everything below the panel)."""

    def __init__(self, lo=-1.0, hi=PANEL_Y):
        self.lo, self.hi = lo, hi
        self.contour = self._contour()

    def contains(self, p):
        return math.hypot(*p) <= RIM and self.lo <= p[1] < self.hi

    def _contour(self):
        """The edge, counter-clockwise: rim arcs joined by the top (and bottom) edges."""
        def rim(a0, a1):
            n = max(1, int(abs(a1 - a0) * RIM / STEP))
            return [polar((0, 0), RIM, a0 + (a1 - a0) * i / n) for i in range(n + 1)]
        hi = math.asin(self.hi / RIM)
        if self.lo <= -RIM:
            pts = rim(math.pi - hi, 2 * math.pi + hi)
            return pts + line(pts[-1], pts[0])[1:]
        lo = math.asin(self.lo / RIM)
        right, left = rim(lo, hi), rim(math.pi - hi, math.pi - lo)
        return right + line(right[-1], left[0])[1:] + left[1:] + line(left[-1], right[0])[1:-1]

    def link(self, a, b):
        """Points from a to b: along the edge (the short way) when both are on or just inside it,
        round the rim when both are on it, else straight."""
        c = self.contour
        i, j = nearest(c, a), nearest(c, b)
        if math.dist(c[i], a) <= 0.03 and math.dist(c[j], b) <= 0.1:
            n = len(c)
            fwd = [c[(i + k) % n] for k in range((j - i) % n + 1)]
            back = [c[(i - k) % n] for k in range((i - j) % n + 1)]
            return min(fwd, back, key=len) + [b]
        if abs(math.hypot(*a) - RIM) < 0.03 and abs(math.hypot(*b) - RIM) < 0.03:
            return rim_arc(a, b)
        return line(a, b)[1:]


# ---------------------------------------------------------------------------------------------
# Background rows

def parallel_rows(angle, spacing, wave=lambda s, k: 0.0):
    """Lines at `angle` degrees across the whole table, `spacing` apart, optionally wavy."""
    d = (math.cos(math.radians(angle)), math.sin(math.radians(angle)))
    n = (-d[1], d[0])
    rows, k, t = [], 0, -RIM + spacing / 2
    while t < RIM:
        s, row = -1.0, []
        while s <= 1.0:
            off = t + wave(s, k)
            row.append((d[0] * s + n[0] * off, d[1] * s + n[1] * off))
            s += STEP
        rows.append((row, False))
        t, k = t + spacing, k + 1
    return rows


def ring_rows(c, r0, spacing):
    rows, r = [], r0
    while r < math.hypot(*c) + RIM:
        n = int(2 * math.pi * r / STEP)
        rows.append(([polar(c, r, 2 * math.pi * i / n) for i in range(n + 1)], True))
        r += spacing
    return rows


def flow(row, closed, shapes, frame):
    """Split a row into runs inside the frame; where it crosses a shape, go round the edge instead."""
    if closed:
        out = next((i for i, p in enumerate(row) if not frame.contains(p)), None)
        if out is None:
            return [row]
        row = row[out:] + row[1:out + 1]
    runs, run, inside = [], [], None
    for p in row:
        if not frame.contains(p):
            if run:
                runs.append(run)
            run, inside = [], None
            continue
        hit = next((s for s in shapes if s.contains(p)), None)
        if inside is None and hit is not None:
            inside = (hit, run[-1] if run else p)
        elif inside is not None and hit is not inside[0]:
            run += inside[0].around(inside[1], p)
            inside = None
        if inside is None:
            run.append(p)
    if run:
        runs.append(run)
    return runs


def background(path, rows, shapes, frame):
    for row, closed in rows:
        runs = flow(row, closed, shapes, frame)
        if not runs:
            continue
        here = path[-1]
        if len(runs) == 1 and math.dist(runs[0][0], runs[0][-1]) < STEP * 1.5:  # a whole ring
            i = nearest(runs[0], here)
            runs = [runs[0][i:] + runs[0][1:i + 1]]
        elif math.dist(here, runs[-1][-1]) < math.dist(here, runs[0][0]):
            runs = [r[::-1] for r in runs[::-1]]
        for r in runs:
            path += frame.link(path[-1], r[0]) + r
    return path


# ---------------------------------------------------------------------------------------------
# Temperature

# Digits in a box 1 tall: (width, stroke).
DIGITS = {
    "0": (0.6, arc(.3, .5, .3, .5, -90, 270)),
    "1": (0.35, [(.03, .8), (.25, 1), (.25, 0)]),
    "2": (0.6, arc(.3, .72, .3, .28, 160, -40) + [(0, 0), (.6, 0)]),
    "3": (0.6, arc(.3, .75, .27, .25, 150, -90) + arc(.3, .26, .3, .26, 90, -150)),
    "4": (0.62, [(.08, 1), (0, .32), (.45, .32), (.45, 1), (.45, 0), (.45, .32), (.62, .32)]),  # open top
    "5": (0.6, [(.55, 1), (.08, 1), (.05, .55)] + arc(.3, .32, .3, .32, 140, -145)),
    "6": (0.6, arc(.32, .5, .3, .5, 60, 200) + arc(.3, .3, .3, .3, 180, 540)),
    "7": (0.6, [(0, 1), (.6, 1), (.2, 0)]),
    "8": (0.6, arc(.3, .27, .3, .27, -90, 90) + arc(.3, .77, .26, .23, -90, -450)
          + arc(.3, .27, .3, .27, 90, 270)),
    "9": (0.6, arc(.3, .7, .3, .3, 0, 360) + arc(.3, .5, .3, .5, 20, -120)),
}
MINUS = 0.4  # width of the minus bar, in digit heights


def traversals(stroke):
    """Ways to draw a stroke completely, retracing parts of it to start and end where needed."""
    n = len(stroke)
    if math.dist(stroke[0], stroke[-1]) < 1e-6:  # a loop: start anywhere, go once round
        return [stroke[k:] + stroke[1:k + 1] for k in range(0, n - 1, max(1, n // 40))]
    ways = []
    for k in range(0, n, max(1, n // 40)):
        ways.append(stroke[k:] + stroke[::-1][1:])                    # k, out to the end, back to the start
        ways.append(stroke[:k + 1][::-1] + stroke[1:])                # k, back to the start, out to the end
        ways.append(stroke[k:] + stroke[::-1][1:] + stroke[1:k + 1])  # k, both ways, back to k
    return ways + [w[::-1] for w in ways]


def length(pts):
    return sum(math.dist(a, b) for a, b in zip(pts, pts[1:]))


def offset(path, d):
    """The path shifted sideways by d (to the left of travel)."""
    out = []
    for i, p in enumerate(path):
        a, b = path[max(0, i - 1)], path[min(len(path) - 1, i + 1)]
        if math.dist(a, b) < 1e-9:  # a turning point where the stroke doubles back
            a, b = (a, p) if math.dist(a, p) > 1e-9 else (p, b)
        n = math.dist(a, b) or 1.0
        out.append((p[0] - (b[1] - a[1]) / n * d, p[1] + (b[0] - a[0]) / n * d))
    return out


def bold(path):
    """Draw the path, back along one side of it and out again along the other: a stroke about
    BALL + 2 * BOLD wide that stands out from the sweep lines around it."""
    path = densify(path)  # so the side flips only where the stroke doubles back, not along a segment
    return path + offset(path, BOLD)[::-1] + offset(path, -BOLD)


def best_traversal(stroke, last):
    """Start at the glyph's left edge if possible (the sweep row leading in comes from the left)
    and, unless it's the last glyph, leave to the right, so the move out stays off the glyph."""
    left, right = min(p[0] for p in stroke), max(p[0] for p in stroke)
    return min(traversals(stroke), key=lambda w: 2 * (w[0][0] - left)
               + (0 if last else 3 * (right - w[-1][0])) + 0.05 * length(w))


def number_width(text, cap):
    w = sum(DIGITS[ch][0] * cap if ch != "-" else MINUS * cap for ch in text) + GAP * len(text)
    return w + 2 * DEGREE


def temperature(value):
    """Strokes for the number and degree sign, centred in the panel, and the digit height."""
    text = str(int(value))
    cap = CAP
    while cap > 0.2:
        w = number_width(text, cap)
        top = BASELINE + cap + BALL / 2 + BOLD
        if math.hypot(w / 2, top) <= TEXT_RIM:  # top corners clear the rim
            break
        cap -= 0.01
    x, strokes = -w / 2, []
    for ch in text:
        cw, stroke = DIGITS[ch] if ch != "-" else (MINUS, [(0, 0.5), (MINUS, 0.5)])
        strokes.append([(x + px * cap, BASELINE + py * cap) for px, py in stroke])
        x += cw * cap + GAP
    ring_y = BASELINE + cap - DEGREE
    strokes.append(arc(x + DEGREE - GAP * 0.3, ring_y, DEGREE, DEGREE, 180, 540))
    return strokes, cap


def panel_bottom(x):
    return PANEL_Y + BALL / 2


def panel_rows(y_low):
    """Long rows across the panel, from the top down to y_low, ending on the left."""
    ys = [y_low + SWEEP * k for k in range(int((PANEL_RIM - SWEEP / 2 - y_low) / SWEEP) + 1)][::-1]
    path = []
    for i, y in enumerate(ys):
        x1 = math.sqrt(PANEL_RIM ** 2 - y ** 2)
        path += [(x1, y), (-x1, y)] if (len(ys) - i) % 2 else [(-x1, y), (x1, y)]
    return path


def sweep_strip(x_lo, x_hi, top, entry=None):
    """Rows BAND_SWEEP apart across the strip between x_lo and x_hi, over the band the number
    sits in, on the same grid in every strip so the rows line up. With an entry point, the last
    row (the one nearest it) runs in from the strip's left edge and stops there: just one more
    sweep line, so the way in barely shows. Rows below it go first, bottom up, then the rows
    above, top down."""
    bottom = panel_bottom(0)
    ey = bottom + BAND_SWEEP * round((entry[1] - bottom) / BAND_SWEEP) if entry else bottom
    k_lo = math.ceil((bottom - ey) / BAND_SWEEP - 1e-9)
    k_hi = math.floor((top - ey) / BAND_SWEEP + 1e-9)

    def row(k, rightward):
        y = ey + k * BAND_SWEEP
        x1 = min(x_hi, math.sqrt(max(0.0, PANEL_RIM ** 2 - y ** 2)))
        if x1 <= x_lo:
            return None
        return [(x_lo, y), (x1, y)] if rightward else [(x1, y), (x_lo, y)]

    above = [r for r in (row(k, k % 2 == 0) for k in range(k_hi, 0, -1)) if r]  # row 1 ends on the left
    below = [r for r in (row(k, (k - k_lo) % 2 == 0) for k in range(k_lo, 0)) if r]
    if below and above and (below[-1][-1][0] > below[-1][0][0]) != (above[0][0][0] > above[0][-1][0]):
        below = [r[::-1] for r in below]  # end on the side the top row starts
    first = row(0, True) or []
    return [p for r in below + above for p in r] + (first[:1] + [entry] if entry else first)


def panel(value):
    """Sweep the temperature panel smooth and write the number in it. Above the number, long rows.
    Around it, a strip per glyph, each swept just before the glyph is drawn, which also wipes out
    the move into the strip, so nothing joins the glyphs."""
    strokes, cap = temperature(value)
    top = BASELINE + cap + BOLD + 0.07
    edge = math.sqrt(PANEL_RIM ** 2 - PANEL_Y ** 2)
    margin = BALL + BOLD
    x_lo = min(p[0] for p in strokes[0]) - margin
    path = panel_rows(top) + sweep_strip(-edge, x_lo, top)  # the empty part, left of the number
    for i, stroke in enumerate(strokes):
        if i:
            x_lo = max(p[0] for p in strokes[i - 1]) + margin + 0.005
        x_hi = edge if i + 1 == len(strokes) else min(p[0] for p in strokes[i + 1]) - margin
        glyph = best_traversal(stroke, i + 1 == len(strokes))
        path += [(x_lo, path[-1][1])] + sweep_strip(x_lo, x_hi, top, glyph[0]) + bold(glyph)
    return path, cap


# ---------------------------------------------------------------------------------------------
# Scenes

def scene(name):
    """(shapes in drawing order, background passes: [(rows, frame)])."""
    if name == "sunny":
        s = sun((0, -0.42))
        return [s], [(ring_rows(s.c, 0.43, 0.085), Frame())]
    if name == "cloudy":
        sizes = [(0.42, 0.2), (1.0, 0.44)]
        shapes = [cloud((-0.55, -0.14), *sizes[0], 2, 0.6), cloud((0.08, -0.46), *sizes[1])]

        def wind(s, k):  # one long, soft swell, bulging away from the clouds like air flowing past
            y0 = -RIM + 0.0425 + 0.085 * k
            dy = 0.018 * math.sin(2.6 * s + 0.25 * k)
            for c, (w, h) in zip(shapes, sizes):
                q = ((s - c.c[0]) / (w / 2)) ** 2 + ((y0 - c.c[1]) / (h / 1.6)) ** 2
                dy += math.copysign(0.035 * math.exp(-max(0.0, q - 1) * 1.2), y0 - c.c[1])
            return dy
        return shapes, [(parallel_rows(0, 0.085, wind), Frame())]
    if name == "rain":
        # Rain falls below the cloud; above its base, a sky of gentle horizontal lines that flow
        # over and under the cloud. (Near-vertical rain lines would all have to go round the
        # cloud's ends, piling up there.)
        sky = cloud((0, -0.24), 0.85, 0.32)
        base = -0.38
        shapes = [sky, drop((-0.32, -0.7), tip=0.24), drop((0, -0.74), tip=0.24),
                  drop((0.32, -0.7), tip=0.24)]
        return shapes, [(parallel_rows(72, 0.08), Frame(hi=base)),
                        (parallel_rows(0, 0.085, lambda s, k: 0.015 * math.sin(2.4 * s + 0.3 * k)),
                         Frame(lo=base))]
    if name == "snow":
        shapes = [flake((-0.66, -0.22), 0.17, twigs=False), flake((0, -0.43), 0.42),
                  flake((0.66, -0.22), 0.17, twigs=False)]
        # Snow drifting down: wavy vertical lines, which also cross the moves between the flakes.
        return shapes, [(parallel_rows(90, 0.085, lambda s, k: 0.03 * math.sin(5 * s + 0.7 * k)), Frame())]
    raise SystemExit(f"unknown condition {name!r}: sunny, cloudy, rain or snow")


def build(condition, value):
    shapes, passes = scene(condition)
    rows = passes[0][0]
    path = []
    for i, s in enumerate(shapes):
        nxt = shapes[i + 1].c if i + 1 < len(shapes) else rows[0][0][0]
        if path:
            path += transit(path[-1], s.c, rows)
        path += s.draw(nxt)
    row, closed = rows[0]
    if not closed:
        path += out_to_rim(path[-1], row)
    for rows, frame in passes:
        path = background(path, rows, shapes, frame)
    text, cap = panel(value)
    return path + rim_arc(path[-1], text[0]) + text, cap


def transit(a, b, rows):
    """A move between shapes that the background will wipe out: square across the rows onto the
    nearest one, along it (the row is drawn right over it later), then square across again."""
    row, closed = rows[0]
    if closed:
        return line(a, b)[1:]
    d = (row[-1][0] - row[0][0], row[-1][1] - row[0][1])
    n = (-d[1] / math.hypot(*d), d[0] / math.hypot(*d))
    across = lambda p: p[0] * n[0] + p[1] * n[1]
    mid = (across(a) + across(b)) / 2
    t = min((across(r[len(r) // 2]) for r, _ in rows), key=lambda o: abs(o - mid))
    a1 = (a[0] + (t - across(a)) * n[0], a[1] + (t - across(a)) * n[1])
    b1 = (b[0] + (t - across(b)) * n[0], b[1] + (t - across(b)) * n[1])
    return line(a, a1)[1:] + line(a1, b1)[1:] + line(b1, b)[1:]


def out_to_rim(a, row):
    """From the last shape straight out to the rim, square to the background rows (so they wipe
    the move out) and toward the side where the first row is."""
    d = (row[-1][0] - row[0][0], row[-1][1] - row[0][1])
    n = math.hypot(*d)
    normal = (-d[1] / n, d[0] / n)
    mid = row[len(row) // 2]
    sign = 1 if mid[0] * normal[0] + mid[1] * normal[1] > 0 else -1
    u = (sign * normal[0], sign * normal[1])
    b = a[0] * u[0] + a[1] * u[1]                     # solve |a + t u| = RIM for t > 0
    t = -b + math.sqrt(b * b - (a[0] ** 2 + a[1] ** 2 - RIM ** 2))
    return line(a, (a[0] + t * u[0], a[1] + t * u[1]))[1:]


# ---------------------------------------------------------------------------------------------

def densify(path):
    out = [path[0]]
    for p in path[1:]:
        if math.dist(out[-1], p) > 1e-6:
            out += line(out[-1], p)[1:]
    return out


def write(path, out, rotate, name):
    a = math.radians(rotate)
    pts = [(x * math.cos(a) - y * math.sin(a), x * math.sin(a) + y * math.cos(a)) for x, y in path]
    with open(out, "w") as f:
        if out.endswith(".json"):
            json.dump({"name": name, "xy": [[round(x, 4), round(y, 4)] for x, y in pts]}, f)
        else:
            for x, y in pts:
                theta = round(math.degrees(math.atan2(y, x)) * 1000) % 360000
                f.write(f"{theta},{round(min(1.0, math.hypot(x, y)) * 100000)}\n")


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("spec", nargs="+", help="CONDITION TEMPERATURE [OUT], or TEMPERATURE [OUT] with --update")
    ap.add_argument("--update", action="store_true", help="redraw only the temperature")
    ap.add_argument("--rotate", type=float, default=0, help="turn the picture counter-clockwise (degrees)")
    args = ap.parse_args()
    spec = args.spec if args.update else args.spec[1:]
    args.condition = None if args.update else args.spec[0]
    args.temperature, args.out = int(spec[0]), (spec[1] if len(spec) > 1 else None)
    if not -99 <= args.temperature <= 199:
        raise SystemExit("temperature must be -99..199")
    if args.update:
        path, cap = panel(args.temperature)
        name = f"weather-temp-{args.temperature}"
    else:
        path, cap = build(args.condition, args.temperature)
        name = f"weather-{args.condition}-{args.temperature}"
    path = densify(path)
    out = args.out or f"{name}.txt"
    write(path, out, args.rotate, name)
    length = sum(math.dist(a, b) for a, b in zip(path, path[1:]))
    print(f"{out}: {len(path)} points, {length:.1f} radii, about {length / 0.115 / 60:.1f} min to draw"
          f" (digits {cap:.2f} tall)")
