"""Hands Clock variants for the twin: a ringed face with bold hour and minute hands, updated every 5 minutes.

    python3 clockhub.py VARIANT HH:MM [HH:MM]     path for the face at the first time, or the update between two
                                                  times; prints length and drawing time, writes JSON to stdout

The test card showed that patching (re-raking the rings across the old hand) hides most of a hand but leaves a
fan of scars where the hands meet at the centre. The variants differ only in the hub:

  centre   hands run to the centre (the design as first proposed; the baseline)
  ring     hands start on the innermost ring, which doubles as a hub circle the ball parks on
  spiral   hands start at the edge of a small spiral hub that is re-raked after every update
  spokes   the spiral hub, plus twelve hour spokes that every patch turns on (see Spokes)

Every update ends where the next one starts (the park position), so the table never makes an undesigned move.
Stdlib only.
"""
import json
import math
import sys

from testcard import Path, TAU

SPACING = 0.09
HOUR_R1, MIN_R1 = 0.5, 0.84
HOUR_W, MIN_W = 0.035, 0.03
SPEED = 0.108                                         # r/s, measured from the table videos


def clock_angle(frac):
    """0 = 12 o'clock, increasing clockwise."""
    return math.pi / 2 - frac * TAU


def minute_angle(t):
    return clock_angle((t % 60) / 60)


def hour_angle(t):
    """The hour hand moves in 15-minute steps (7.5 degrees), so it is patched four times an hour."""
    q = (t // 15) * 15
    return clock_angle((q / 60 % 12) / 12)


def near(a, b):
    """b unwrapped to within half a turn of a."""
    return a + (b - a + math.pi) % TAU - math.pi


class Variant:
    def __init__(self, name):
        name, _, fine = name.partition('-')            # e.g. spiral-fine: rings 0.06 apart instead of 0.09
        self.name, self.label = name, name + ('-' + fine if fine else '')
        spacing = 0.06 if fine else SPACING
        inner = {'centre': 0.07, 'ring': 0.07, 'spiral': 0.22}[name]
        self.radii = [r for r in (0.97 - spacing * i for i in range(20)) if r >= inner - 1e-9]
        self.r0 = {'centre': 0.0, 'ring': 0.07, 'spiral': 0.16}[name]     # where the hands start

    def pt(self, r, a):
        return r * math.cos(a), r * math.sin(a)

    def hour(self, t):
        return hour_angle(t)

    def park(self, t):
        """Where the ball rests between updates."""
        if self.name == 'ring':
            return self.pt(self.r0, minute_angle(t))
        return (0.0, 0.0)

    # ------------------------------------------------------------ pieces

    def to_hub(self, p, a):
        """From the hand-start circle at the current angle round to angle a (on the hub, never across the face)."""
        x, y = p.pts[-1]
        if self.r0 == 0:
            p.line(0, 0)
            return
        a0 = math.atan2(y, x)
        p.line(*self.pt(self.r0, a0))
        p.arc(0, 0, self.r0, a0, near(a0, a))

    def patch(self, p, a_new, a_old, r_max, w):
        """Ring arcs from the new angle back past the old hand and back again, stepping outward along the new
        angle, then in again along it to the hub. Leaves only the new hand's radial line."""
        a_old = near(a_new, a_old)
        d = 1 if a_old > a_new else -1
        for r in (r for r in reversed(self.radii) if r <= r_max):
            over = 0.12 + (w + 0.04) / r
            p.line(*self.pt(r, a_new))
            p.arc(0, 0, r, a_new, a_old + d * over)
            p.arc(0, 0, r, a_old + d * over, a_new)
        p.line(*self.pt(self.r0, a_new))
        return a_new, a_old + d * (0.12 + (w + 0.04) / max(self.radii[-1], 0.07))

    bold = 1                                          # offset passes each side of a hand's centre line

    def hand(self, p, a, r1, w):
        """Out and back along the centre line and at small offsets each side, ending on the hub at angle a."""
        r0 = self.r0
        ux, uy, nx, ny = math.cos(a), math.sin(a), -math.sin(a), math.cos(a)
        offs = [k * w for k in range(1, self.bold + 1)]
        for o in [0] + offs + [-o for o in offs] + [0]:
            p.line(r0 * ux + o * nx, r0 * uy + o * ny)
            p.line(r1 * ux + o * nx, r1 * uy + o * ny)
        p.line(r0 * ux, r0 * uy)

    def rake_hub(self, p):
        """Spiral from the hub edge in to the centre, clockwise, 0.035 apart."""
        if self.name != 'spiral':
            return
        x, y = p.pts[-1]
        a0 = math.atan2(y, x)
        turns = self.r0 / 0.035
        n = int(turns * 120)
        for i in range(1, n + 1):
            f = i / n
            p.pts.append(self.pt(self.r0 * (1 - f), a0 - TAU * turns * f))

    # ------------------------------------------------------------ paths

    def face(self, t, start=(0.0, 0.97)):
        """The whole face from any sand: rings from the outside in, joined along 12 o'clock, then the hands."""
        p = Path(*start)
        a12 = math.pi / 2
        for r in self.radii:
            p.line(*self.pt(r, a12))
            p.arc(0, 0, r, a12, a12 - TAU)
        if self.name == 'spiral':
            p.line(*self.pt(self.r0, a12))
            self.rake_hub(p)
            p.line(*self.pt(self.r0, self.hour(t)))
        else:
            p.line(*self.pt(self.r0, a12))
            self.to_hub(p, self.hour(t))
        self.hand(p, self.hour(t), HOUR_R1, HOUR_W)
        self.to_hub(p, minute_angle(t))
        self.hand(p, minute_angle(t), MIN_R1, MIN_W)
        if self.name == 'spiral':
            self.rake_hub(p)
        return p.pts

    def update(self, t_old, t_new):
        p = Path(*self.park(t_old))
        am_old, am_new = minute_angle(t_old), minute_angle(t_new)
        ah_old, ah_new = self.hour(t_old), self.hour(t_new)
        if self.name == 'spiral':
            p.line(*self.pt(self.r0, am_new))
        else:
            self.to_hub(p, am_new)
        lo, hi = sorted(self.patch(p, am_new, am_old, 2, MIN_W))
        # the minute patch cuts the hour hand if it lies in the patched sector
        ah = near((lo + hi) / 2, ah_old)
        cut = lo - 0.15 < ah < hi + 0.15
        if ah_new != ah_old:
            self.to_hub(p, ah_new)
            self.patch(p, ah_new, ah_old, HOUR_R1 + 0.1, HOUR_W)
        if ah_new != ah_old or cut:
            self.to_hub(p, ah_new)
            self.hand(p, ah_new, HOUR_R1, HOUR_W)
        self.to_hub(p, am_new)
        self.hand(p, am_new, MIN_R1, MIN_W)
        self.rake_hub(p)
        return p.pts


class Spokes(Variant):
    """Spiral hub, plus twelve spokes as hour marks that every patch turns on.

    An out-and-back patch arc leaves a small heap where it reverses, and those heaps line up into a radial scar
    behind each old hand. Here the patch is a single pass per ring, turning onto the next ring along a spoke:
    from the new hand's spoke back over the old hand to the spoke beyond it, so every turn sits on a spoke.
    The old hand's spoke is then redrawn as a thin groove. The hour hand jumps on the hour, onto a spoke."""

    bold = 2                                          # hands twice as wide, so they stand out from the spokes

    def __init__(self, name='spokes'):
        super().__init__('spiral')
        self.name = 'spiral'                              # hub behaviour: rake_hub, park at the centre
        self.label = 'spokes'

    def hour(self, t):
        return clock_angle((t // 60 % 12) / 12)

    def spoke(self, p, a):
        """Thin hour mark, out from the hub edge and back."""
        self.to_hub(p, a)
        p.line(*self.pt(self.radii[0], a))
        p.line(*self.pt(self.r0, a))

    def patch(self, p, a_new, a_old, r_max, w):
        a_old = near(a_new, a_old)
        a_far = a_old + (a_old - a_new)                   # the spoke beyond the old hand
        rings = [r for r in reversed(self.radii) if r <= r_max]
        a = a_new
        p.line(*self.pt(rings[0], a))
        for r in rings:
            p.line(*self.pt(r, a))                        # step out along a spoke
            b = a_far if a == a_new else a_new
            p.arc(0, 0, r, a, b)
            a = b
        p.line(*self.pt(self.r0, a))                      # back in along whichever spoke it ended on
        return sorted((a_new, a_far))

    def face(self, t, start=(0.0, 0.97)):
        p = Path(*start)
        a12 = math.pi / 2
        for r in self.radii:
            p.line(*self.pt(r, a12))
            p.arc(0, 0, r, a12, a12 - TAU)
        p.line(*self.pt(self.r0, a12))
        for k in range(12):
            self.spoke(p, clock_angle(k / 12))
        self.to_hub(p, self.hour(t))
        self.hand(p, self.hour(t), HOUR_R1, HOUR_W)
        self.to_hub(p, minute_angle(t))
        self.hand(p, minute_angle(t), MIN_R1, MIN_W)
        self.rake_hub(p)
        return p.pts

    def update(self, t_old, t_new):
        p = Path(*self.park(t_old))
        am_old, am_new = minute_angle(t_old), minute_angle(t_new)
        ah_old, ah_new = self.hour(t_old), self.hour(t_new)
        p.line(*self.pt(self.r0, am_new))
        lo, hi = self.patch(p, am_new, am_old, 2, MIN_W)
        ah = near((lo + hi) / 2, ah_old)
        cut = lo - 0.05 < ah < hi + 0.05
        if ah_new != ah_old:
            self.to_hub(p, ah_new)
            self.patch(p, ah_new, ah_old, HOUR_R1 + 0.1, HOUR_W)
            self.spoke(p, ah_old)
        if abs(near(am_old, ah_new) - am_old) > 0.01:     # the old minute hand's spoke, unless the hour hand covers it
            self.spoke(p, am_old)
        if ah_new != ah_old or cut:
            self.to_hub(p, ah_new)
            self.hand(p, ah_new, HOUR_R1, HOUR_W)
        self.to_hub(p, am_new)
        self.hand(p, am_new, MIN_R1, MIN_W)
        self.rake_hub(p)
        return p.pts


def variant(name):
    return Spokes() if name == 'spokes' else Variant(name)


def length(pts):
    return sum(math.dist(a, b) for a, b in zip(pts, pts[1:]))


def parse(hhmm):
    h, m = hhmm.split(':')
    return int(h) * 60 + int(m)


if __name__ == '__main__':
    v = variant(sys.argv[1])
    times = [parse(s) for s in sys.argv[2:]]
    pts = v.face(times[0]) if len(times) == 1 else v.update(*times)
    L = length(pts)
    print(f'{len(pts)} points, {L:.1f} r, about {L / SPEED:.0f} s', file=sys.stderr)
    json.dump({'name': f'hands clock ({v.name} hub)', 'xy': [(round(x, 4), round(y, 4)) for x, y in pts]}, sys.stdout)
