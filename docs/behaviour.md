# Measured behaviour

What a gen-1 16" Drift actually does, measured on a real table
(controller `A_11_V0.7.12`, driver `B_11_V0.3.3`, speed setting 75). Useful for planning drawings, live
streaming and timeouts.

## Timing

| What | Measured |
|---|---|
| Upload | about 0.15 s per 40-point page at 100 ms pacing; a 4-page segment in about 0.9 s, also while another pattern draws |
| First upload of a connection | often loses a burst of pages and needs one resend |
| Play while another pattern draws | switches; the state shows the new id about 0.6 s later |
| Pattern finishes (random and loop off) | goes idle (pattern 0, status 0) within 0.5 s |
| Finish → next pattern drawing | about 1 s by the 2 Hz state broadcast; the ball itself pauses only about 0.1 s |
| Draw speed | roughly constant linear speed, about 0.12 table radii per second. Time scales with path length: a spiral chunk 4π long at mean rho 0.3 took 31 s, at mean rho 0.7 took 69 s |
| Move to a new pattern's start | one interpolated (theta, rho) move, which traces an arc; about 14 s from the rim at theta 0 to (π, 0.25). Progress doesn't advance during it. |
| Full-table clearing spiral (20 turns) | about 9.5 minutes |

## Motion

- **Overwriting an id replaces it.** No delete needed, but the overwrite isn't atomic (Start truncates the file).
- **Chained patterns join smoothly** if the next one starts where the last ended.
- **Theta zero and direction:** theta increases counter-clockwise as seen from above. Where theta zero
  points relative to the table's front isn't measured yet; drawings may appear rotated.
- **Homing** runs at power-on, not on every play.
- The ball is about 0.07 table radii across. A clearing spiral at 0.05 spacing smooths the sand but leaves
  faint concentric ridges.

## Storage

- Room for 800 pattern ids.
- Create, overwrite and delete churn doesn't leak space.
- Uploads need free space for the pattern plus about 1 MiB.
- A gen-1 table ships with about 97 stock patterns (ids 1–52, then sparse up to about 834).

## Live streaming

Chaining short patterns gives near-real-time control on stock firmware:

- Two slots, overwritten in place, are enough. One draws while the other holds the next segment. The table
  refuses uploads to the drawing id, so the other slot is always free.
- 12 × 28 s segments streamed for 5.5 minutes with no errors; the next segment was ready at least 22 s early.
- An interrupt (overwrite the free slot, play it at once) cut in 1.3 s after it was requested.
- Segments of 10 s or more leave comfortable headroom. 7.6 s segments left only 1.2 s to spare.
- A fresh id per segment plus deletes also works, and storage stays flat, but the joins are slower.

## Lighting

- Light mode (`0x11/4`) persists across disconnects: shifting through the palette, breathing, brightness.
- The palette holds named colours (stock `c0`..`c3`). `0x14/15` writes a colour into it as "Temp"
  (it replaced slot 0 on our unit) and `0x14/13` selects one by name.
- In shifting mode the colour cycles through the palette while idle.

## Connection

- One central at a time. While a host holds the connection, the official app can't connect.
- The session resets after about 2 s without host frames; drawing is unaffected.
- Disconnecting doesn't stop a drawing.
