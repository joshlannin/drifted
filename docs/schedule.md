# Daily routine

Drifted can run the table through the day by itself: a weather picture first thing, then the playlist, with
holiday seasons mixed in. It's off until you turn it on. Turning the table off at night isn't part of it: use
whatever drives the power switch (`POST /power/off`, e.g. an Apple Home scene through Homebridge). The morning
weather is what turns it back on.

| Time | What happens |
|---|---|
| `weatherAt` (e.g. 04:15) | Fetch today's forecast and draw the weather picture: an emblem for the conditions under the day's high (the same picture as [designs/weather.py](../designs/weather.py), about 15 minutes). Drawing turns the table on. The playlist holds, so the picture stays on the sand |
| `playlistAt` (e.g. 09:00) | End the hold and start the playlist's next pattern ([playlist](../spec/openapi.yaml)). A season can set its own time (below) |

With the playlist's `onTable` on, the playlist step writes the day's picks (at most 20) to the table as its
own playlist and starts it with loop on, so the table keeps going even if Drifted loses the connection; the
hold turns the table's loop off so the weather picture stays.

Set it with `PUT /schedule` or the MCP `schedule` tool. It's saved in the state dir as `schedule.json` (location
included, so it never goes in a repo); what ran today is in `schedule-state.json`. Each step is logged to the
host log.

```json
{
  "enabled": true,
  "weatherAt": "04:15",
  "playlistAt": "09:00",
  "location": {"latitude": 51.48, "longitude": 0.0},
  "units": "celsius",
  "seasons": [
    {"name": "Chanukah", "start": "2026-12-04", "end": "2026-12-12", "ids": [], "weight": 1, "colors": ["#ffb81c"], "playlistAt": "06:00", "weather": false},
    {"name": "Christmas", "start": "12-01", "end": "12-26", "ids": [], "weight": 0.5, "colors": ["#d0101c", "#0f8a3c"]}
  ]
}
```

`weatherAt` or `playlistAt` set to `null` skips that step. Times are local; the location is fixed coordinates
(no Location Services).

## Weather

- Source: WeatherKit when the app is built with a provisioning profile that has the WeatherKit capability
  (`DRIFTED_PROVISIONING_PROFILE`, see [scripts/build-host-app.sh](../scripts/build-host-app.sh)); otherwise,
  or if WeatherKit fails, [Open-Meteo](https://open-meteo.com) (free, no key). `GET /schedule` says which.
- It uses today's daily condition and high. WeatherKit conditions and Open-Meteo's WMO codes map onto the
  picture's conditions (`WeatherPicture.Condition`): breezy and windy draw as cloudy, drizzle as rain, freezing
  rain and wintry mix as sleet, haze and smoke as fog, any thunderstorm as thunderstorm.
- If fetching or drawing fails, it tries again every 5 minutes until 30 minutes before `playlistAt`. If it
  never works, the table is turned on and the playlist starts.
- `drifted weather CONDITION TEMPERATURE OUT.json` makes the picture offline, for previewing.

## Missed times

The Mac was asleep, or the host restarted, when a step was due:

- **Weather** still runs while at least 30 minutes remain before `playlistAt` (so it's finished before the
  playlist takes over); otherwise it's skipped for the day. With no playlist step, it catches up for 4 hours.
- **Playlist** still runs up to 3 hours late; later than that it waits for tomorrow, so a Mac that wakes in the
  evening doesn't start a table that was turned off for the night.
- Turning the routine on, or moving a time, doesn't run steps whose time has already passed today.

## Power

The day's first step turns the table on: the weather does it by drawing, and if the weather didn't run, the
playlist step does. After that, if someone turns the table off, the playlist step leaves it off (it ends the
hold, so turning the power back on starts the next pattern). A live session is left alone.

## Seasons

A season is a date range, inclusive, given as `MM-DD` (every year; may wrap the new year) or `YYYY-MM-DD` (that
year only).

- **Patterns.** `ids` are stored pattern ids. While the season lasts, they take `weight` of the playlist's
  picks: 0.5 is every other pattern (the default), 0.25 every fourth, 1 only seasonal ones. They're shuffled
  without repeats. When the playlist's own ids are empty ("every stored pattern"), ids that any season lists
  are left out of it, so holiday patterns only play in season. Overlapping seasons pool their ids and the
  larger weight applies.
- **Lamp.** `colors` go on the lamp as a fixed colour when the season starts; with several, the lamp moves to
  the next with each pattern. The first listed season with colours wins. When the season ends, your own lamp
  comes back: the colour and light mode Drifted remembers as yours (`/status` `lampColor`; see
  [behaviour.md](behaviour.md#lighting)), not whatever the table happened to show when the season began. A
  colour set through `/settings` during a season is what comes back. If the table loses its lamp setting during
  a season, the season's colour goes back on. Brightness isn't touched. While the lamp switch is off nothing
  is sent; the colour is applied when it's turned on. Through a relay that links on demand, Drifted sees the
  table move to its next pattern at the next check-in, so that is when a season with several colours steps.
- **Earlier start.** `playlistAt` on a season moves the playlist step on its days (e.g. `"06:00"`, so the
  holiday patterns are on by breakfast). With several, the earliest wins; the weather then has until 30
  minutes before it. It can't turn on a playlist step that's off. `GET /schedule` gives today's time as
  `status.playlistAtToday`.
- **No weather.** `"weather": false` on a season skips the weather picture on its days, so the day starts
  with the playlist step (which turns the table on). `GET /schedule` gives `status.weatherAtToday` (null when
  off).

## Testing

`POST /schedule/run {"step": "weather", "dryRun": true}` fetches the forecast and builds the picture without
drawing; without `dryRun` it draws it now. `{"step": "playlist"}` runs the playlist step now. Neither changes
what runs at the scheduled times.
