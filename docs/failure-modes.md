# Failure modes

Every one of these was hit on real hardware (gen-1 16" table, controller `A_11_V0.7.12`). Most fail
silently, which is why they're worth knowing before you write a client.

| Symptom | Cause | What to do |
|---|---|---|
| Upload "succeeds", but playing the id raises alarm 10 (can't open pattern file) and the ball doesn't move | The last page(s) were lost. End got `0x34/1` with an **empty** missing list, which looks like success. The upload stays open, and 5 s later the table times it out, **deletes the file** and sends `0x34/5` that nobody is waiting for. | Treat only `0x34/3` as success. On an empty `0x34/1`, resend the final pages and send End again. |
| The table restarts the handshake right after End; nothing stored | Pages sent too fast (1 ms apart). | 100 ms between pages. |
| No `0x34/2` after Start | Start is silently ignored while a previous upload is unfinished. | Wait out or finish the previous upload; resend Start a few times with a 4 s wait. |
| `0x34/5` straight after Start | Start for the id that is currently drawing is rejected. A failed play leaves that id marked "drawing", so it stays blocked until another pattern plays. | Upload into a different id. Live streaming uses two alternating slots for this reason. |
| Upload fails partway; file gone | More than 5 s between upload messages, or the BLE session reset (2 s with no host frames). | Keep pages flowing; keep answering the state broadcast. |
| Alarm 13 (can't delete pattern file) appears and never goes away | Deleted an id that doesn't exist. | Only delete ids in the table's `0x33` list. |
| A fatal alarm repeats every second, long after the problem | Fatal alarms (codes 8–17) **latch until reboot**; nothing a host sends clears them. | Report only *new* codes as events. Use "progress frozen" as the real failure signal. |
| Playback looks stuck: progress frozen for many seconds | The ball is moving to the pattern's first point; progress doesn't advance during that move (about 14 s from the rim). | Use a generous stall timeout (30 s). |
| Right after starting the next pattern, progress reads 100% | The broadcast still shows the previous pattern's value for a moment. | Don't treat "100% right after play" as a failure signal. |
| Ball spins a full extra turn | Theta jumped by about 2π between consecutive points: often an xy path converted with `atan2` where it crosses the −x axis. | Unwrap theta (each step within ±π) before densifying. |
| Ball takes the long way round | Consecutive points more than about 45° apart in theta; the table unwraps only across 314°→46°. | Densify so steps stay small (e.g. ≤ 0.5 rad). |
| Colour comes out yellow instead of white | `0x14/15` sent without its leading `enable` byte. | `14 0f 01 rr gg bb`. |
| White light reverts to cycling colours on disconnect | `0x14/15` alone is a preview. | Follow it with `0x14/13 "Temp"` and `0x11/4` (shifting off). |
| A random stock pattern starts between your patterns | Random mode is on. | Turn random and loop off while you drive the table; restore them after. |

## Safe defaults for a new client

- Custom ids from 50000 up; overwrite in place rather than delete and recreate.
- 40 points per page, 100 ms apart; only `0x34/3` is success.
- Never send `0x15` (firmware update).
- Reply ConfirmData to every table message, including ack-bit ones.
