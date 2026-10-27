#!/usr/bin/env python3
"""Portrait: a sand drawing of a person, from a short description of their features in a photo.

A portrait in sand is an illustration, not a copy of the photo. The groove is about 0.07 radii wide, so the
table holds only about 25 grooves across, and sand can't show shades of grey. So a description (JSON) picks
the handful of features that make the person recognisable, gives each an outline in photo pixels, and says
how to draw it: a texture of rows, lines inside it, or both. docs/portraits.md explains how to write one;
designs/portraits/sunglasses.json is a worked example.

The ball never lifts, so the drawing is planned so that no move shows:
  1. the features, each drawn inside its own outline;
  2. the skin: rows across the face that bend round every feature instead of crossing it. Where a row bends
     it follows the feature's outline, so every feature gets a bold edge, and the rows rake away the moves
     made in step 1;
  3. the background: rows across the table that bend round the head the same way, tracing the silhouette;
  4. the big textured areas that border both skin and background (hair, ears, clothes), last, so their own
     rows wipe out anything that had to cross them.
Every move between pieces travels along grooves already drawn, or outlines that will be traced anyway (feature
edges, the silhouette, the rim), so it retraces a groove instead of cutting a new one across the sand.

Usage:
  python3 designs/portrait.py DESCRIPTION.json [OUT] [--preview PREVIEW.png]
  python3 designs/portrait.py --grid PHOTO.jpg GRID.png      the photo with a labelled pixel grid, for
                                                             reading off outline points
OUT ending in .json is an `xy` drawing for driftd's /show; otherwise it's HoMedics Drift .txt.
Needs numpy and opencv-python (pip install numpy opencv-python).
"""
import argparse
import heapq
import json
import math

import cv2
import numpy as np

TAU = 2 * math.pi
STEP = 0.008    # path sampling, table radii
RIM = 0.97      # the drawing stays inside this radius
GRID = 900      # resolution of the masks used to work out regions


# ---------------------------------------------------------------------- geometry

def catmull(pts, closed=True, n=12):
    """Smooth curve through the points."""
    P, out = list(pts), []
    m = len(P)
    for i in range(m if closed else m - 1):
        p0 = P[(i - 1) % m] if closed or i > 0 else P[0]
        p1, p2 = P[i], P[(i + 1) % m]
        p3 = P[(i + 2) % m] if closed or i + 2 < m else P[-1]
        for k in range(n):
            t = k / n
            out.append(tuple(0.5 * (2 * p1[j] + (p2[j] - p0[j]) * t
                                    + (2 * p0[j] - 5 * p1[j] + 4 * p2[j] - p3[j]) * t * t
                                    + (3 * p1[j] - p0[j] - 3 * p2[j] + p3[j]) * t ** 3) for j in (0, 1)))
    if not closed:
        out.append(tuple(P[-1]))
    return out


def rot(p, a):
    c, s = math.cos(a), math.sin(a)
    return (c * p[0] - s * p[1], s * p[0] + c * p[1])


def line(a, b):
    n = max(1, int(math.dist(a, b) / STEP))
    return [(a[0] + (b[0] - a[0]) * i / n, a[1] + (b[1] - a[1]) * i / n) for i in range(1, n + 1)]


class Poly:
    """Closed outline with arc-length positions, for travelling along it."""

    def __init__(self, pts):
        self.p = list(pts)
        self.s = [0.0]
        for a, b in zip(self.p, self.p[1:] + self.p[:1]):
            self.s.append(self.s[-1] + math.dist(a, b))
        self.L = self.s[-1]

    def hits(self, y, a=0.0):
        """Where the line at height y (in a frame turned by angle a) crosses the outline: (x, arc position)."""
        out, n = [], len(self.p)
        for i in range(n):
            p1, p2 = rot(self.p[i], -a), rot(self.p[(i + 1) % n], -a)
            if (p1[1] > y) != (p2[1] > y):
                t = (y - p1[1]) / (p2[1] - p1[1])
                out.append((p1[0] + t * (p2[0] - p1[0]), self.s[i] + t * (self.s[i + 1] - self.s[i])))
        return sorted(out)

    def at(self, s):
        s %= self.L
        lo, hi = 0, len(self.p)
        while hi - lo > 1:
            mid = (lo + hi) // 2
            lo, hi = (mid, hi) if self.s[mid] <= s else (lo, mid)
        a, b = self.p[lo], self.p[(lo + 1) % len(self.p)]
        seg = self.s[lo + 1] - self.s[lo]
        t = (s - self.s[lo]) / seg if seg else 0
        return (a[0] + t * (b[0] - a[0]), a[1] + t * (b[1] - a[1]))

    def travel(self, s0, s1):
        """Points along the outline from arc position s0 to s1, the shorter way round."""
        d = (s1 - s0) % self.L
        span, sgn = (d, 1) if d <= self.L / 2 else (self.L - d, -1)
        n = max(1, int(span / STEP))
        return [self.at(s0 + sgn * span * i / n) for i in range(1, n + 1)]


# ---------------------------------------------------------------------- rows

def textured(a, b, style, k):
    """A stretch of row from a to b (same height, in the row's own frame), straight or textured:
    wavy (flowing hair, background), zigzag (stubble), loops (curly hair)."""
    kind, amp, wave = style.get('kind', 'straight'), style.get('amp', 0.02), style.get('wave', 0.06)
    L = abs(b[0] - a[0])
    n = max(1, int(L / STEP))
    sgn = 1 if b[0] >= a[0] else -1
    out = []
    for i in range(1, n + 1):
        u = L * i / n
        x, y = a[0] + sgn * u, a[1]
        if kind == 'wavy':
            y += amp * math.sin(TAU * u / wave + k)
        elif kind == 'zigzag':
            y += amp * (4 * abs((u / wave + 0.25 * k) % 1 - 0.5) - 1)
        elif kind == 'loops':
            t = TAU * u / wave
            x, y = a[0] + sgn * (u - 0.8 * amp * math.sin(t)), a[1] - amp * math.cos(t)
        fade = min(1.0, u / (0.6 * wave), (L - u) / (0.6 * wave))   # meet the outlines cleanly
        out.append((x, a[1] + (y - a[1]) * fade))
    return out


def rows(domain, holes, style, from_top=True):
    """Rows across the domain at style['angle'] degrees, style['spacing'] apart, alternating direction.
    A row never crosses a hole: it follows the hole's outline round to the far side (the shorter way), and
    likewise follows the domain's own outline across any notch. Rows are joined along the domain outline."""
    a, spacing = math.radians(style.get('angle', 0)), style['spacing']
    ys_all = [rot(q, -a)[1] for q in domain.p]
    ys, y = [], max(ys_all) - spacing / 2
    while y > min(ys_all):
        ys.append(y)
        y -= spacing
    if not from_top:
        ys.reverse()
    path, prev_s = [], None
    for k, y in enumerate(ys):
        hd = domain.hits(y, a)
        if len(hd) < 2:
            continue
        right = k % 2 == 0
        first, last = (hd[0], hd[-1]) if right else (hd[-1], hd[0])
        path += domain.travel(prev_s, first[1]) if prev_s is not None else [rot((first[0], y), a)]
        obst = [(hd[i][0], hd[i + 1][0], domain, hd[i][1], hd[i + 1][1]) for i in range(1, len(hd) - 1, 2)]
        for h in holes:
            hh = h.hits(y, a)
            obst += [(hh[i][0], hh[i + 1][0], h, hh[i][1], hh[i + 1][1]) for i in range(0, len(hh) - 1, 2)]
        obst.sort(key=lambda o: o[0], reverse=not right)
        x = first[0]
        for x0, x1, poly, s0, s1 in obst:
            enter, leave, se, sl = (x0, x1, s0, s1) if right else (x1, x0, s1, s0)
            if (enter - x) * (1 if right else -1) < 0:
                continue                                # overlaps an obstacle already passed
            path += [rot(q, a) for q in textured((x, y), (enter, y), style, k)]
            path += poly.travel(se, sl)
            x = leave
        path += [rot(q, a) for q in textured((x, y), (last[0], y), style, k)]
        prev_s = last[1]
    return path


# ---------------------------------------------------------------------- regions and moves

def _px(p):
    return [int(round((p[0] + 1) / 2 * (GRID - 1))), int(round((1 - p[1]) / 2 * (GRID - 1)))]


def regions(include, exclude=()):
    """The area inside the include outlines (None: the whole table), within reach, outside every exclude
    outline. Returns one (outline, holes) per separate piece."""
    m = np.zeros((GRID, GRID), np.uint8)
    disc = np.zeros_like(m)
    cv2.circle(disc, tuple(_px((0, 0))), int(RIM / 2 * (GRID - 1)), 255, -1)
    if include is None:
        m = disc
    else:
        for poly in include:
            cv2.fillPoly(m, [np.array([_px(p) for p in poly.p], np.int32)], 255)
        m &= disc
    for poly in exclude:
        cv2.fillPoly(m, [np.array([_px(p) for p in poly.p], np.int32)], 0)
    m = cv2.morphologyEx(m, cv2.MORPH_OPEN, np.ones((5, 5), np.uint8))
    cs, hier = cv2.findContours(m, cv2.RETR_CCOMP, cv2.CHAIN_APPROX_NONE)
    if hier is None:
        return []

    def poly(c):
        pts = [(q[0][0] / (GRID - 1) * 2 - 1, 1 - q[0][1] / (GRID - 1) * 2) for q in c[::3]]
        k = len(pts)                                    # smooth the pixel staircase a little
        return Poly([tuple((pts[i - 1][j] + 2 * pts[i][j] + pts[(i + 1) % k][j]) / 4 for j in (0, 1))
                     for i in range(k)])

    out = []
    for i, c in enumerate(cs):
        if hier[0][i][3] != -1 or cv2.contourArea(c) < 40:
            continue
        holes, j = [], hier[0][i][2]
        while j != -1:
            if cv2.contourArea(cs[j]) >= 20:
                holes.append(poly(cs[j]))
            j = hier[0][j][0]
        out.append((poly(c), holes))
    return out


class Router:
    """Moves that travel only along grooves the drawing has already cut, or outlines it will trace anyway
    (feature edges, the silhouette, the rim): a move then retraces a groove instead of cutting a new one."""

    JOIN = 0.015        # grooves closer than this are treated as touching

    def __init__(self, polys):
        self.pts, self.adj, self.cell = [], [], {}
        for poly in polys:
            ring = []
            for a, b in zip(poly.p, poly.p[1:] + poly.p[:1]):
                n = max(1, int(math.dist(a, b) / 0.01))
                ring += [(a[0] + (b[0] - a[0]) * i / n, a[1] + (b[1] - a[1]) * i / n) for i in range(n)]
            self.add(ring + ring[:1])

    def _node(self, p, prev):
        i = len(self.pts)
        self.pts.append(p)
        self.adj.append([])
        key = (int(p[0] / self.JOIN), int(p[1] / self.JOIN))
        for dx in (-1, 0, 1):                           # join to anything already this close
            for dy in (-1, 0, 1):
                for j in self.cell.get((key[0] + dx, key[1] + dy), ()):
                    d = math.dist(p, self.pts[j])
                    if d < self.JOIN:
                        self.adj[i].append((j, d))
                        self.adj[j].append((i, d))
        self.cell.setdefault(key, []).append(i)
        if prev is not None:
            d = math.dist(p, self.pts[prev])
            self.adj[i].append((prev, d))
            self.adj[prev].append((i, d))
        return i

    def add(self, line_pts):
        """A groove (or an outline to come): its points, joined in order, every ~0.01 radii."""
        prev, last = None, None
        for p in line_pts:
            if last is not None and math.dist(p, last) < 0.01:
                continue
            prev, last = self._node(p, prev), p

    def snap(self, q):
        P = np.array(self.pts)
        d = np.hypot(P[:, 0] - q[0], P[:, 1] - q[1])
        i = int(np.argmin(d))
        return i, float(d[i])

    def route(self, a, b):
        if math.dist(a, b) < 0.05:
            return line(a, b)
        (i, da), (j, db) = self.snap(a), self.snap(b)
        if da + db >= math.dist(a, b):
            return line(a, b)
        dist, prev = self._search(i, j)
        if j in dist:
            return line(a, self.pts[i]) + self._walk(prev, i, j) + line(self.pts[j], b)
        # not connected: follow grooves from both ends and make the one unavoidable new line as short as
        # possible (it costs three times its length), so it crosses as little as it can
        dist_b, prev_b = self._search(j, None)
        ka, kb = list(dist), list(dist_b)
        A, B = np.array([self.pts[k] for k in ka]), np.array([self.pts[k] for k in kb])
        da_, db_ = np.array([dist[k] for k in ka]), np.array([dist_b[k] for k in kb])
        best = (1e9, None, None)
        for s in range(0, len(A), 512):
            gap = np.hypot(A[s:s + 512, None, 0] - B[None, :, 0], A[s:s + 512, None, 1] - B[None, :, 1])
            cost = da_[s:s + 512, None] + 3 * gap + db_[None, :]
            m = np.unravel_index(np.argmin(cost), cost.shape)
            if cost[m] < best[0]:
                best = (cost[m], ka[s + m[0]], kb[m[1]])
        _, u, v = best
        return (line(a, self.pts[i]) + self._walk(prev, i, u) + line(self.pts[u], self.pts[v])
                + self._walk(prev_b, j, v)[::-1][1:] + [self.pts[j]] + line(self.pts[j], b))

    def _search(self, i, stop):
        dist, prev, heap = {i: 0.0}, {}, [(0.0, i)]
        while heap:
            d, u = heapq.heappop(heap)
            if u == stop:
                break
            if d > dist.get(u, 1e9):
                continue
            for v, w in self.adj[u]:
                if d + w < dist.get(v, 1e9):
                    dist[v], prev[v] = d + w, u
                    heapq.heappush(heap, (d + w, v))
        return dist, prev

    def _walk(self, prev, i, j):
        """Points from node i to node j (excluding i), following the search's back-pointers."""
        chain = [j]
        while chain[-1] != i:
            chain.append(prev[chain[-1]])
        return [self.pts[u] for u in reversed(chain[:-1])]


def nearer_start(here, make):
    """Rows from the top or from the bottom, whichever begins nearer the ball."""
    a, b = make(True), make(False)
    if not a or not b:
        return a or b
    return a if math.dist(here, a[0]) <= math.dist(here, b[0]) else b


# ---------------------------------------------------------------------- the portrait

class Portrait:
    def __init__(self, spec):
        self.spec = spec
        c = spec['crop']
        self.cx, self.cy, self.r = c['cx'], c['cy'], c['radius']

    def T(self, p):
        """Photo pixel to table coordinates: the crop circle becomes the drawable disc."""
        return ((p[0] - self.cx) / self.r * RIM, -(p[1] - self.cy) / self.r * RIM)

    def poly(self, pts):
        return Poly(catmull([self.T(p) for p in pts]))

    def build(self):
        spec = self.spec
        path = [tuple(spec.get('start', (0.0, -RIM)))]
        head = self.poly(spec['head'])
        face = self.poly(spec['face']) if 'face' in spec else head
        zones = [(z, self.poly(z['outline'])) for z in spec['zones']]
        named = {z['name']: o for z, o in zones}
        disc = Poly([(RIM * math.cos(TAU * i / 360), RIM * math.sin(TAU * i / 360)) for i in range(360)])
        reach = lambda poly: Poly([(x * min(1, RIM / (math.hypot(x, y) or 1)), y * min(1, RIM / (math.hypot(x, y) or 1)))
                                   for x, y in poly.p])
        router = Router([disc, reach(head), reach(face)] + [reach(o) for _, o in zones])

        drawn = [0]                                     # how much of the path the router knows about

        def go(seg):
            if seg:
                router.add(path[max(0, drawn[0] - 1):])
                drawn[0] = len(path)
                path.extend(router.route(path[-1], seg[0]) + seg)

        def fill(include, exclude, style):
            for outline, holes in sorted(regions(include, exclude), key=lambda r: -r[0].L):
                go(nearer_start(path[-1], lambda top: rows(outline, holes, style, top)))

        def zone(z, outline):
            for style in z.get('fill', []):
                fill([outline], [named[h] for h in z.get('holes', [])], style)
            for k in range(z.get('outline_passes', 0)):    # a bold edge, round and round
                ring = outline.p if k % 2 == 0 else outline.p[::-1]
                s0 = min(range(len(ring)), key=lambda i: math.dist(ring[i], path[-1]))
                go(ring[s0:] + ring[:s0 + 1])
            for st in z.get('strokes', []):
                pts = catmull([self.T(p) for p in st['pts']], closed=st.get('closed', False))
                for k in range(st.get('passes', 1)):
                    go(pts if k % 2 == 0 else pts[::-1])

        for z, outline in zones:                                            # 1. features
            if not z.get('late'):
                zone(z, outline)
        fill([face], [o for z, o in zones if z.get('inside', True) and not z.get('within')], spec['skin'])  # 2.
        fill(None, [head] + [o for z, o in zones if not z.get('inside', True)], spec['background'])        # 3.
        for z, outline in zones:                                            # 4. big textured areas
            if z.get('late'):
                zone(z, outline)
        return [(x * RIM / r, y * RIM / r) if (r := math.hypot(x, y)) > RIM else (x, y) for x, y in path]


# ---------------------------------------------------------------------- output

def write(pts, out, name):
    with open(out, "w") as f:
        if out.endswith(".json"):
            json.dump({"name": name, "xy": [[round(x, 4), round(y, 4)] for x, y in pts]}, f)
        else:
            for x, y in pts:
                theta = round(math.degrees(math.atan2(y, x)) * 1000) % 360000
                f.write(f"{theta},{round(min(1.0, math.hypot(x, y)) * 100000)}\n")


def preview(pts, out, size=700):
    img = np.full((size, size, 3), 255, np.uint8)
    cv2.circle(img, (size // 2, size // 2), size // 2 - 2, (200, 200, 200), 1, cv2.LINE_AA)
    poly = np.array([((x + 1) / 2 * size, (1 - y) / 2 * size) for x, y in pts], np.int32)
    cv2.polylines(img, [poly], False, (60, 60, 60), 1, cv2.LINE_AA)
    cv2.imwrite(out, img)


def grid(photo, out):
    img = cv2.imread(photo)
    h, w = img.shape[:2]
    step = 50 if max(w, h) <= 800 else 100
    for x in range(0, w, step):
        cv2.line(img, (x, 0), (x, h), (0, 255, 255), 1 if x % (step * 5) else 3)
    for y in range(0, h, step):
        cv2.line(img, (0, y), (w, y), (0, 255, 255), 1 if y % (step * 5) else 3)
    scale = max(w, h) / 1000
    for x in range(0, w, step * 2):
        for y in range(0, h, step * 2):
            cv2.putText(img, f"{x},{y}", (x + 3, y + int(16 * scale)), cv2.FONT_HERSHEY_SIMPLEX,
                        0.45 * scale, (255, 0, 255), max(1, int(scale)))
    cv2.imwrite(out, img)


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("spec", nargs="?", help="feature description (JSON)")
    ap.add_argument("out", nargs="?")
    ap.add_argument("--preview", help="also draw the path as a PNG")
    ap.add_argument("--grid", nargs=2, metavar=("PHOTO", "OUT"), help="write the photo with a pixel grid")
    a = ap.parse_args()
    if a.grid:
        grid(*a.grid)
        raise SystemExit
    if not a.spec:
        ap.error("give a description, or --grid")
    spec = json.load(open(a.spec))
    pts = Portrait(spec).build()
    name = spec.get("name", "portrait")
    out = a.out or a.spec.rsplit(".", 1)[0] + ".txt"
    write(pts, out, name)
    if a.preview:
        preview(pts, a.preview)
    length = sum(math.dist(p, q) for p, q in zip(pts, pts[1:]))
    print(f"{out}: {len(pts)} points, {length:.0f} radii, about {length / 0.108 / 60:.0f} min to draw")
