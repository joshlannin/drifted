# Drawing guide

How to design something that looks good in the sand. Written for people and for AI assistants generating paths.

## The medium

- A steel ball, pulled by a magnet under the sand, traces **one continuous line**. It never lifts: every
  move you send, including the travel between shapes, leaves a groove.
- Coordinates: the table is the unit disc. `xy` uses table radii (centre (0, 0), rim at distance 1,
  +x right, +y up in the table's frame). Polar uses `theta` in radians (counter-clockwise) and `rho` 0..1.
- The table may be rotated relative to where you stand: theta zero isn't calibrated to the front yet.
- The groove is about 0.07 radii wide, so details smaller than about 0.05 radii blur together.
- Drawing speed is about 0.12 radii of path per second, so a path 3 radii long takes about 25 s.

## Designing a path

1. **Plan the order of strokes** so the connecting moves are short or look intentional: draw a letter
   bottom-to-top if the next one starts at the top; retrace an existing stroke to get somewhere; make a
   connector look like a ligature.
2. **Stay inside about 0.9 radii.** The rim is a wall, and the outer ring is where clearing spirals end.
3. **Point spacing:** 0.01–0.02 radii along curves; straight lines can be sparse (the host densifies).
   Keep consecutive points within about 30° of theta; validators split larger steps.
4. **Size:** text and icons read best at 0.5–0.7 radii tall. Two or three letters fit side by side.
5. **Preview on the digital twin before sending** ([digital-twin.md](digital-twin.md)). The sand view shows what
   will merge or be too small to read; the route view shows connectors you forgot about. Iterate there: it
   takes seconds, and the table takes minutes.

## Clearing first

Old patterns stay in the sand, and new lines drawn over them are hard to read. Sweep first:

- **area:** a spiral covering just the drawing's disc; a few minutes for a mid-sized drawing.
- **full:** the whole table, about 9.5 minutes.

The sweep ends next to the drawing's first point, so the joining groove is short. Text almost always wants
a clear; a pattern that fills the table usually doesn't.

## Live drawing

For things that change (weather, events, a story), stream short segments instead of one big pattern:

- Each segment should draw for 10–30 s.
- Start each segment where the previous one ended, or let the host add a straight connector.
- Keep about two segments queued. Use an interrupt only for things that must show up now; it abandons the
  current segment mid-line.

## What works well

- Spirals, roses, spirographs and other single continuous curves: the medium's natural vocabulary.
- Bold, simple glyphs and outlines; single-stroke ("Hershey"-style) fonts.
- Patterns built from repeated, slowly rotating motifs.
- Portraits, as illustrations rather than copies of a photo: see [portraits.md](portraits.md).

## What doesn't

- Filled areas (you can only hatch them, slowly).
- Fine detail or small text.
- Many separate shapes far apart: every jump between them is drawn.
