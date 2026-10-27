---
name: drifted-draw
description: Design and draw pictures, text or live sequences on a HoMedics Drift sand table with the drifted MCP tools. Use whenever the user asks to draw, write, show or animate something on their sand table, change its lights, or stream live content to it.
---

# Drawing on a Drift table

The table is a steel ball pulled through sand by a magnet. It never lifts, so **every point you send is drawn,
including moves between shapes**.

## Workflow

1. `get_status`: connection should be `ready`. If the tools are missing or failing, use the drifted-install skill.
2. Design the path as **one continuous line**:
   - `xy`: table radii. The table is the unit disc, centre (0, 0), +x right, +y up. Stay inside 0.9.
   - Plan the stroke order so connectors are short or look intentional (ligatures, retracing).
   - Point spacing 0.01–0.02 along curves. Text and icons read best at 0.5–0.7 radii tall.
3. Check it on the **digital twin** (no table time used): `preview_pattern` returns the sand as it will look
   afterwards and the route. **Look at both**: merged or unreadable areas in the sand, stray connectors in the
   route. Fix and preview again until it reads well. For long drawings, or if the user wants to see it first,
   `animate_pattern` saves a GIF of the ball drawing it; give them the path.
4. `show_pattern`. For text or small drawings over an existing pattern, pass `clear: "area"` (a few minutes
   extra). `clear: "full"` sweeps the whole table (about 10 minutes).
5. Tell the user how long it will take: `validate_pattern` returns `estimatedSeconds` (about 8 s per table
   radius of path, plus the clear).

## Live sequences

`live_start`, then `live_push` segments of 10–30 s each, keeping about two queued, each starting where the last
ended. Use `interrupt: true` only for things that must appear now. Finish with `live_stop`.

## Lights

`settings` with `color: "#rrggbb"`, `brightness` 0–1, `shifting: true` to cycle colours.

## Don't

- Fill areas, draw tiny detail, or scatter many separate shapes (every jump is drawn).
- Delete patterns the user didn't create.

More: docs/drawing-guide.md, docs/digital-twin.md and docs/behaviour.md in the repo.
