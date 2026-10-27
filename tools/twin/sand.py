"""Digital twin of the sand: a heightfield the ball ploughs through, and a renderer lit like the table.

Units are table radii throughout (the unit disc the patterns use), heights included, so slopes are real.
Only numpy is needed.

    sim = Sand(Params())
    sim.draw(xy)                 # list of (x, y) in path order; call again to draw over it
    img = sim.render()           # grey image, 0..1, +y up
"""
import math
from dataclasses import dataclass, field, asdict

import numpy as np


@dataclass
class Params:
    # defaults fitted to photos of 7 recorded runs, rain and birthday held out (2026-10-26)
    n: int = 620                 # grid cells across the table
    extent: float = 1.16         # half-width of the grid in table radii
    rim: float = 1.12            # sand ends here; the ball reaches 1.0, the sand goes a little further
    depth: float = 0.03          # sand depth at rest
    noise: float = 0.0012        # height noise of untouched sand
    ball: float = 0.034          # ball radius
    sink: float = 0.5            # fraction of the ball radius below the rest surface
    spread: float = 0.845        # how far beside the groove the displaced sand lands (ball radii past the edge)
    ahead: float = 1.0           # share of displaced sand pushed forward (it's ploughed again next step)
    repose: float = 39.0         # angle of repose, degrees
    lag: float = 0.021           # ball trails the magnet by this distance (corner cutting)
    leak: float = 0.0            # >0: bow-wave model. The ball carries the sand it cuts in a heap in front
    #                              and sheds this fraction of the heap into side ridges each step; the rest
    #                              is dumped ahead where the ball turns sharply. 0: the plough model (ahead).
    step: float = 0.0            # stamp spacing; 0 means one grid cell
    subcell: int = 0             # >0: place each stamp to 1/subcell of a grid cell instead of the nearest cell
    cone: float = 1.0            # forward share is weighted by cos(angle off the heading) ** cone
    ride: float = 0.0            # >0: the ball's depth follows the sand under it (1: sinks sink*ball below the
    #                              local surface; 0: always to the same absolute floor)
    firm: float = 0.0            # degrees added to the angle of repose where the ball has packed the sand (its
    #                              cut surface) and nothing loose has landed on it since
    sided: float = 0.75          # 1: sand cut on one side of the ball's track lands on that side only (it
    #                              isn't carried across the ball into an older groove beside it). 0: either side.
    skew: float = 0.0            # where in the deposit band the sand piles highest: 0 the middle, 1 right at
    #                              the groove's edge (a sharp lip that falls away outward)
    seed: int = 1

    def to_dict(self):
        return asdict(self)


class Sand:
    def __init__(self, p: Params, h=None):
        self.p = p
        self.dx = 2 * p.extent / p.n
        c = (np.arange(p.n) + 0.5) * self.dx - p.extent
        self.X, self.Y = np.meshgrid(c, -c)            # row 0 is the top (+y)
        self.R = np.hypot(self.X, self.Y)
        self.inside = self.R <= p.rim
        if h is None:
            rng = np.random.default_rng(p.seed)
            h = p.depth + p.noise * _blur(rng.standard_normal((p.n, p.n)), 2)
        self.h = np.where(self.inside, h, p.depth)
        self.ballpos = None
        self.load, self.heading = 0.0, None             # bow-wave heap and the direction it's being pushed
        self.packed = np.zeros_like(self.h) if p.firm else None
        # ball profile and deposit weights on a window around the stamp
        b = p.ball / self.dx
        self.w = int(math.ceil(b * (2.2 + p.spread)))
        self._kernels = {}
        self._use_kernel(0.0, 0.0)

    def _use_kernel(self, ox, oy):
        """Ball profile and deposit weights on a window around a stamp whose centre sits (ox, oy) from the
        window's centre cell."""
        key = (ox, oy)
        if key not in self._kernels:
            p = self.p
            k = np.arange(-self.w, self.w + 1)
            kx, ky = np.meshgrid(k * self.dx - ox, -k * self.dx - oy)
            kd = np.hypot(kx, ky)
            core = kd < p.ball
            cap = np.where(core, p.ball - np.sqrt(np.maximum(p.ball ** 2 - kd ** 2, 0)), 0)
            band = (kd >= p.ball) & (kd <= p.ball * (1 + p.spread))
            edge, peak = p.ball * (1 + p.spread), p.ball * (1 + p.spread * (1 - p.skew) / 2)
            rise = (kd - p.ball) / (peak - p.ball) if peak > p.ball + 1e-9 else np.ones_like(kd)
            band_w = np.where(band, np.minimum(rise, (edge - kd) / (edge - peak + 1e-9)), 0)
            self._kernels[key] = (kx, ky, kd, core, cap, band, np.clip(band_w, 0, None))
        self.kx, self.ky, self.kd, self.core, self.cap, self.band, self.band_w = self._kernels[key]

    # ------------------------------------------------------------------ drawing

    def draw(self, xy, relax_every=40, on_step=None):
        """on_step(sim, x, y), if given, is called after every stamp (for rendering frames as it draws)."""
        p = self.p
        step = p.step or self.dx
        if self.ballpos is not None:                  # the ball travels from wherever it stopped
            xy = [self.ballpos] + list(xy)
        pts = _table_path(xy, step)
        if p.lag > 0:
            pts = _trail(pts, p.lag)
        floor = p.depth - p.sink * p.ball            # ball bottom height
        prev = self.ballpos
        lo = hi = None
        for i, (x, y) in enumerate(pts):
            self._stamp(x, y, prev, floor)
            prev = (x, y)
            if relax_every and i % relax_every == relax_every - 1:
                self.relax(1, region=(x, y, 0.15))
            if on_step:
                on_step(self, x, y)
        self.ballpos = prev
        if p.leak > 0 and prev is not None:
            self._dump(*prev)
        self.relax(4)
        return self

    def _window(self, x, y):
        p, w = self.p, self.w
        ci = int(round((p.extent - y) / self.dx - 0.5))
        cj = int(round((x + p.extent) / self.dx - 0.5))
        if ci - w < 0 or cj - w < 0 or ci + w >= p.n or cj + w >= p.n:
            return None, None
        return (slice(ci - w, ci + w + 1), slice(cj - w, cj + w + 1)), self.inside[ci - w:ci + w + 1, cj - w:cj + w + 1]

    def _dump(self, x, y):
        """Leave the bow-wave heap in front of the ball (where it turns or stops)."""
        sl, ins = self._window(x, y)
        if sl is None or self.load <= 0 or self.heading is None:
            self.load = 0.0
            return
        ux, uy = self.heading
        along = (self.kx * ux + self.ky * uy) / (self.kd + 1e-12)
        wgt = self.band_w * np.clip(along, 0, None) ** 2 * ins
        if wgt.sum() > 0:
            self.h[sl] += self.load * wgt / wgt.sum()
        self.load = 0.0

    def _stamp(self, x, y, prev, floor):
        p, w = self.p, self.w
        ci = int(round((p.extent - y) / self.dx - 0.5))
        cj = int(round((x + p.extent) / self.dx - 0.5))
        if ci - w < 0 or cj - w < 0 or ci + w >= p.n or cj + w >= p.n:
            return
        if p.subcell:
            q = p.subcell
            ox = round((x - ((cj + 0.5) * self.dx - p.extent)) / self.dx * q) / q * self.dx
            oy = round((y - (p.extent - (ci + 0.5) * self.dx)) / self.dx * q) / q * self.dx
            self._use_kernel(ox, oy)
        win = self.h[ci - w:ci + w + 1, cj - w:cj + w + 1]
        # where the window centre really is (sub-cell)
        if p.ride:
            local = win[self.core].mean() - p.sink * p.ball
            floor = (1 - p.ride) * floor + p.ride * local
        surf = floor + self.cap
        cut = np.where(self.core, np.maximum(win - surf, 0), 0)
        moved = cut.sum()
        if moved <= 0 and p.leak <= 0:
            return
        win -= cut
        if self.packed is not None:
            pk = self.packed[ci - w:ci + w + 1, cj - w:cj + w + 1]
            pk[cut > 0] = 1.0
        if p.leak > 0:
            return self._bow(win, moved, x, y, prev, ci, cj)
        if prev is not None and (x, y) != prev:
            dxm, dym = x - prev[0], y - prev[1]
            L = math.hypot(dxm, dym)
            ux, uy = dxm / L, dym / L
            along = (self.kx * ux + self.ky * uy) / (self.kd + 1e-12)
            wgt = self.band_w * ((1 - self.p.ahead) * (1 - along ** 2) + self.p.ahead * np.clip(along, 0, None) ** self.p.cone)
        else:
            wgt = self.band_w
        wgt = wgt * self.inside[ci - w:ci + w + 1, cj - w:cj + w + 1]
        s = wgt.sum()
        if s <= 0:
            return
        if p.sided > 0 and prev is not None and (x, y) != prev:
            left = 0.5 * (1 + np.tanh((self.ky * ux - self.kx * uy) / (0.15 * p.ball)))
            cut_l = (cut * left).sum()
            add = (1 - p.sided) * moved * wgt / s
            for part, side in ((cut_l, left), (moved - cut_l, 1 - left)):
                ws = wgt * side
                if ws.sum() > 0:
                    add += p.sided * part * ws / ws.sum()
                else:
                    add += p.sided * part * wgt / s
        else:
            add = moved * wgt / s
        win += add
        if self.packed is not None:
            pk[add > 1e-4 * p.ball] = 0.0

    def _bow(self, win, moved, x, y, prev, ci, cj):
        p, w = self.p, self.w
        if prev is None or (x, y) == prev:
            self.load += moved
            return
        dxm, dym = x - prev[0], y - prev[1]
        L = math.hypot(dxm, dym)
        ux, uy = dxm / L, dym / L
        if self.heading is not None and ux * self.heading[0] + uy * self.heading[1] < 0.3:
            self._dump(*prev)                                # sharp turn: the heap stays behind
        self.heading = (ux, uy)
        self.load += moved
        along = (self.kx * ux + self.ky * uy) / (self.kd + 1e-12)
        wgt = self.band_w * (1 - along ** 2) * self.inside[ci - w:ci + w + 1, cj - w:cj + w + 1]
        s = wgt.sum()
        if s > 0:
            shed = p.leak * self.load
            win += shed * wgt / s
            self.load -= shed

    def relax(self, iters=3, region=None):
        """Avalanche: wherever the slope to a neighbour beats the angle of repose, move sand downhill."""
        p = self.p
        if region is not None:
            x, y, rad = region
            i0 = max(int((p.extent - y - rad) / self.dx), 1); i1 = min(int((p.extent - y + rad) / self.dx), p.n - 1)
            j0 = max(int((x + p.extent - rad) / self.dx), 1); j1 = min(int((x + p.extent + rad) / self.dx), p.n - 1)
        else:
            i0, i1, j0, j1 = 1, p.n - 1, 1, p.n - 1
        h = self.h[i0 - 1:i1 + 1, j0 - 1:j1 + 1]
        m = self.inside[i0 - 1:i1 + 1, j0 - 1:j1 + 1]
        lim = math.tan(math.radians(p.repose)) * self.dx
        pk = self.packed[i0 - 1:i1 + 1, j0 - 1:j1 + 1] if self.packed is not None else None
        for _ in range(iters):
            for axis, sgn in ((0, 1), (1, 1)):
                d = np.diff(h, axis=axis)                      # h[k+1] - h[k]
                mm = (m[1:, :] & m[:-1, :]) if axis == 0 else (m[:, 1:] & m[:, :-1])
                if pk is not None:                             # the higher cell's packing sets the limit
                    a, b = (pk[:-1, :], pk[1:, :]) if axis == 0 else (pk[:, :-1], pk[:, 1:])
                    lim = np.tan(np.radians(p.repose + p.firm * np.where(d > 0, b, a))) * self.dx
                excess = np.where(mm, np.sign(d) * np.maximum(np.abs(d) - lim, 0) * 0.25, 0)
                if axis == 0:
                    h[:-1, :] += excess
                    h[1:, :] -= excess
                else:
                    h[:, :-1] += excess
                    h[:, 1:] -= excess

    # ------------------------------------------------------------------ rendering

    def features(self, light_height=0.05, lights=72, shadows=(0.4,)):
        """Per-pixel lighting terms; render() mixes them, calibrate fits the mix to a photo."""
        p = self.p
        gy, gx = np.gradient(self.h, self.dx)
        gy = -gy                                          # rows run downwards
        nrm = np.sqrt(1 + gx ** 2 + gy ** 2)
        nx, ny, nz = -gx / nrm, -gy / nrm, 1 / nrm
        ring = np.zeros_like(self.h)
        for k in range(lights):
            a = 2 * math.pi * k / lights
            lx, ly, lz = p.rim * 1.01 * math.cos(a) - self.X, p.rim * 1.01 * math.sin(a) - self.Y, light_height
            d = np.sqrt(lx ** 2 + ly ** 2 + lz ** 2)
            ring += np.clip((nx * lx + ny * ly + nz * lz) / d, 0, None) / d
        ring /= lights
        cavity = self.h - _blur(self.h, max(1, int(round(self.p.ball / self.dx))))
        f = {'ring': ring, 'nz': nz, 'cavity': cavity / self.p.ball, 'slope': 1 - nz}
        if shadows:
            for tan_e in shadows:
                f[f'shadow{tan_e:g}'] = self._shadowed_ring(nx, ny, nz, tan_e)
        return f

    def _shadowed_ring(self, nx, ny, nz, tan_e, azimuths=24, step=2):
        """Light from all round the rim at elevation atan(tan_e), with ridges casting shadows across the
        sand. Each azimuth is treated as a distant light; a cell is lit if nothing along the way to the
        light rises above the light's line of sight."""
        h = self.h
        reach = int(0.06 / tan_e / self.dx)               # shadows longer than berms can cast don't matter
        cz = tan_e / math.hypot(1, tan_e)
        out = np.zeros_like(h)
        for k in range(azimuths):
            a = 2 * math.pi * k / azimuths
            ux, uy = math.cos(a), math.sin(a)
            cx = math.cos(math.atan(tan_e))
            lam = np.clip(nx * ux * cx + ny * uy * cx + nz * cz, 0, None)
            lit = np.ones(h.shape, bool)
            for d in range(step, reach + 1, step):
                di, dj = -int(round(d * uy)), int(round(d * ux))   # rows run downwards
                ahead = np.roll(np.roll(h, -di, 0), -dj, 1)
                lit &= ahead <= h + d * self.dx * tan_e
            out += lam * lit
        return out / azimuths

    def render(self, weights=None):
        f = self.features()
        w = weights or {'ring': 1.0, 'nz': 0.0, 'cavity': 0.6, 'slope': -1.5}
        img = sum(w.get(k, 0) * f[k] for k in f)
        img = (img - np.percentile(img[self.inside], 1)) / (np.ptp(np.percentile(img[self.inside], [1, 99])) + 1e-9)
        return np.where(self.inside, np.clip(img, 0, 1), 0.08)


# ---------------------------------------------------------------------- helpers

def _table_path(xy, step):
    """The path as the table moves it: radius clamped to 1 (as the host does), and straight lines in
    (theta, rho) between points, so a long move between two points is a spiral, not a chord."""
    pol, prev = [], None
    for x, y in xy:
        t, r = math.atan2(y, x), min(1.0, math.hypot(x, y))
        if prev is not None:
            t = prev + (t - prev + math.pi) % (2 * math.pi) - math.pi
        pol.append((t, r))
        prev = t
    out = [(pol[0][1] * math.cos(pol[0][0]), pol[0][1] * math.sin(pol[0][0]))]
    for (t0, r0), (t1, r1) in zip(pol, pol[1:]):
        L = math.hypot(r1 - r0, max(r0, r1) * (t1 - t0))
        n = max(1, int(math.ceil(L / step)))
        for i in range(1, n + 1):
            t, r = t0 + (t1 - t0) * i / n, r0 + (r1 - r0) * i / n
            out.append((r * math.cos(t), r * math.sin(t)))
    return out


def _densify(xy, step):
    out = [tuple(xy[0])]
    for a, b in zip(xy, xy[1:]):
        L = math.dist(a, b)
        n = max(1, int(L / step))
        for i in range(1, n + 1):
            out.append((a[0] + (b[0] - a[0]) * i / n, a[1] + (b[1] - a[1]) * i / n))
    return out


def _trail(pts, lag):
    """Ball pulled along behind the magnet on a string of length lag: it cuts corners."""
    bx, by = pts[0]
    out = [(bx, by)]
    for x, y in pts[1:]:
        d = math.hypot(x - bx, y - by)
        if d > lag:
            f = (d - lag) / d
            bx, by = bx + (x - bx) * f, by + (y - by) * f
        out.append((bx, by))
    return out


def _blur(a, r):
    """Box blur, three passes (close to Gaussian), edge-padded."""
    for _ in range(3):
        for axis in (0, 1):
            pad = [(0, 0), (0, 0)]
            pad[axis] = (r + 1, r)
            c = np.cumsum(np.pad(a, pad, mode='edge'), axis=axis)
            if axis == 0:
                a = (c[2 * r + 1:, :] - c[:-2 * r - 1, :]) / (2 * r + 1)
            else:
                a = (c[:, 2 * r + 1:] - c[:, :-2 * r - 1]) / (2 * r + 1)
    return a
