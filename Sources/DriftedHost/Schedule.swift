import DriftedKit
import Foundation

/// drifted-host's daily routine (docs/schedule.md): the weather picture early in the morning, the playlist from
/// mid-morning, and holiday seasons that mix their own patterns into the playlist and colour the lamp.
/// Turning the table off at night is left to whatever drives the power switch (Apple Home, say).
/// Saved in the state dir as schedule.json; what it has done today is in schedule-state.json.
struct ScheduleConfig: Codable, Equatable {
    struct Location: Codable, Equatable { var latitude: Double; var longitude: Double }

    /// A date range (inclusive) whose patterns join the playlist and whose colours go on the lamp.
    struct Season: Codable, Equatable {
        var name: String
        /// "MM-DD" (every year) or "YYYY-MM-DD" (that year only); both ends in the same form. An MM-DD range
        /// may wrap the new year ("12-20" to "01-06").
        var start: String
        var end: String
        /// Pattern ids stored on the table. They play only in season.
        var ids: [UInt16] = []
        /// Share of the playlist's picks that come from `ids`: 0.5 is every other pattern, 1 only these.
        var weight = 0.5
        /// "#rrggbb". One is a fixed colour; with more, the lamp moves to the next with each pattern.
        var colors: [String] = []

        enum CodingKeys: String, CodingKey { case name, start, end, ids, weight, colors }

        init(name: String, start: String, end: String, ids: [UInt16] = [], weight: Double = 0.5, colors: [String] = []) {
            self.name = name; self.start = start; self.end = end; self.ids = ids; self.weight = weight; self.colors = colors
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            start = try c.decode(String.self, forKey: .start)
            end = try c.decode(String.self, forKey: .end)
            ids = try c.decodeIfPresent([UInt16].self, forKey: .ids) ?? []
            weight = try c.decodeIfPresent(Double.self, forKey: .weight) ?? 0.5
            colors = try c.decodeIfPresent([String].self, forKey: .colors) ?? []
        }

        /// Whether `date` (local calendar day) falls in the season.
        func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
            ScheduleRules.season(start: start, end: end, contains: date, calendar: calendar)
        }

        func validate() throws {
            guard !name.isEmpty else { throw HTTPError(400, "a season needs a name") }
            guard let s = ScheduleRules.parseDay(start), let e = ScheduleRules.parseDay(end), (s.year == nil) == (e.year == nil)
            else { throw HTTPError(400, "season \(name): start and end must both be MM-DD or both YYYY-MM-DD") }
            guard (0...1).contains(weight) else { throw HTTPError(400, "season \(name): weight must be 0-1") }
            for c in colors where ScheduleRules.parseColor(c) == nil { throw HTTPError(400, "season \(name): colour \(c) isn't #rrggbb") }
        }
    }

    var enabled = false
    /// Local "HH:mm"; nil skips the step.
    var weatherAt: String? = "04:15"
    var playlistAt: String? = "09:00"
    var location: Location?
    var units = Locale.current.measurementSystem == .us ? "fahrenheit" : "celsius"
    var seasons: [Season] = []

    enum CodingKeys: String, CodingKey { case enabled, weatherAt, playlistAt, location, units, seasons }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ScheduleConfig()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        weatherAt = c.contains(.weatherAt) ? try c.decodeIfPresent(String.self, forKey: .weatherAt) : d.weatherAt
        playlistAt = c.contains(.playlistAt) ? try c.decodeIfPresent(String.self, forKey: .playlistAt) : d.playlistAt
        location = try c.decodeIfPresent(Location.self, forKey: .location)
        units = try c.decodeIfPresent(String.self, forKey: .units) ?? d.units
        seasons = try c.decodeIfPresent([Season].self, forKey: .seasons) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(weatherAt, forKey: .weatherAt)     // null, not missing, when a step is off
        try c.encode(playlistAt, forKey: .playlistAt)
        try c.encode(location, forKey: .location)
        try c.encode(units, forKey: .units)
        try c.encode(seasons, forKey: .seasons)
    }

    var fahrenheit: Bool { units == "fahrenheit" }
    var weatherMinute: Int? { weatherAt.flatMap(ScheduleRules.parseTime) }
    var playlistMinute: Int? { playlistAt.flatMap(ScheduleRules.parseTime) }

    func activeSeasons(on date: Date) -> [Season] { seasons.filter { $0.contains(date) } }

    /// Every id any season lists: with the playlist's ids empty ("every stored pattern"), these are left out
    /// of the everyday mix so holiday patterns play only in their season.
    var seasonIds: Set<UInt16> { Set(seasons.flatMap(\.ids)) }

    func validate() throws {
        for (key, t) in [("weatherAt", weatherAt), ("playlistAt", playlistAt)] {
            if let t, ScheduleRules.parseTime(t) == nil { throw HTTPError(400, "\(key) must be HH:mm (24-hour), or null to skip it") }
        }
        if let l = location, !((-90...90).contains(l.latitude) && (-180...180).contains(l.longitude)) {
            throw HTTPError(400, "location: latitude -90…90, longitude -180…180")
        }
        guard ["fahrenheit", "celsius"].contains(units) else { throw HTTPError(400, "units must be fahrenheit or celsius") }
        for s in seasons { try s.validate() }
    }

    static func load(_ file: URL) -> ScheduleConfig {
        (try? JSONDecoder().decode(ScheduleConfig.self, from: Data(contentsOf: file))) ?? ScheduleConfig()
    }

    func save(_ file: URL) {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(self).write(to: file, options: .atomic)
    }
}

/// The routine's timing and date rules, kept apart from the host so they can be checked offline.
public enum ScheduleRules {
    // MARK: When to run a step that's due

    /// A weather step at minute `m` of the day, scheduled for `weatherAt`: on time (up to 5 minutes late, a tick
    /// or a short sleep) it runs. Later, after the Mac slept or the host restarted, it still runs while at
    /// least 30 minutes remain before the playlist step, so the picture is done before the playlist takes over;
    /// with no playlist step (or one before the weather), it catches up for 4 hours. Otherwise it's skipped.
    public static func weatherCatchUp(minute m: Int, weatherAt w: Int, playlistAt p: Int?) -> Bool {
        m - w <= 5 || m < weatherGiveUp(weatherAt: w, playlistAt: p)
    }

    /// A missed playlist step still runs up to 3 hours late; later than that it waits for tomorrow, so a Mac
    /// that wakes in the evening doesn't start the table after it was turned off for the night.
    public static func playlistCatchUp(minute m: Int, playlistAt p: Int) -> Bool { m - p < 180 }

    /// When the weather step stops retrying (minutes into the day).
    public static func weatherGiveUp(weatherAt w: Int, playlistAt p: Int?) -> Int { p.map { $0 > w ? $0 - 30 : w + 240 } ?? w + 240 }

    // MARK: Parsing

    public static func parseTime(_ s: String) -> Int? {
        let parts = s.split(separator: ":")
        guard parts.count == 2, parts[1].count == 2, let h = Int(parts[0]), let m = Int(parts[1]),
              (0..<24).contains(h), (0..<60).contains(m) else { return nil }
        return h * 60 + m
    }

    public static func parseDay(_ s: String) -> (year: Int?, month: Int, day: Int)? {
        let parts = s.split(separator: "-").map { Int($0) }
        guard parts.allSatisfy({ $0 != nil }) else { return nil }
        let n = parts.compactMap { $0 }
        let (y, m, d): (Int?, Int, Int)
        switch n.count {
        case 2: (y, m, d) = (nil, n[0], n[1])
        case 3: (y, m, d) = (n[0], n[1], n[2])
        default: return nil
        }
        guard (1...12).contains(m), (1...31).contains(d) else { return nil }
        return (y, m, d)
    }

    public static func parseColor(_ s: String) -> (UInt8, UInt8, UInt8)? {
        let hex = s.hasPrefix("#") ? String(s.dropFirst()) : s
        guard hex.count == 6, let v = UInt32(hex, radix: 16) else { return nil }
        return (UInt8(v >> 16), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF))
    }

    /// Whether `date`'s local day falls between `start` and `end` (inclusive): both "MM-DD" (every year, may wrap
    /// the new year) or both "YYYY-MM-DD".
    public static func season(start: String, end: String, contains date: Date, calendar: Calendar = .current) -> Bool {
        let d = calendar.dateComponents([.year, .month, .day], from: date)
        guard let s = parseDay(start), let e = parseDay(end), (s.year == nil) == (e.year == nil),
              let y = d.year, let m = d.month, let day = d.day else { return false }
        if let sy = s.year, let ey = e.year {
            let key = y * 10000 + m * 100 + day
            return sy * 10000 + s.month * 100 + s.day <= key && key <= ey * 10000 + e.month * 100 + e.day
        }
        let md = m * 100 + day, sm = s.month * 100 + s.day, em = e.month * 100 + e.day
        return sm <= em ? (sm <= md && md <= em) : (md >= sm || md <= em)
    }
}

/// What the routine has done (schedule-state.json), so a restart doesn't run a step twice.
struct ScheduleState: Codable {
    /// The lamp as it was before a season coloured it, to put back afterwards.
    struct Lamp: Codable {
        var colorName: String
        var color: String
        var shifting: Bool
        var shiftSeconds: UInt16
        var breathing: Bool
    }
    struct Weather: Codable {
        var at: Date
        var source: String
        var raw: String
        var condition: String
        var high: Int
        var result: String
    }

    /// Local days ("yyyy-MM-dd") each step last ran, or was skipped.
    var weatherDay: String?
    var playlistDay: String?
    /// The day the routine last turned the table on. Later steps that day leave a table that's been turned
    /// off alone.
    var wokeDay: String?
    var lastWeather: Weather?
    var lamp: Lamp?
    /// The season whose colours are on the lamp.
    var lampSeason: String?
    var colorIndex = 0

    static func load(_ file: URL) -> ScheduleState {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode(ScheduleState.self, from: Data(contentsOf: file))) ?? ScheduleState()
    }

    func save(_ file: URL) {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]; enc.dateEncodingStrategy = .iso8601
        try? enc.encode(self).write(to: file, options: .atomic)
    }
}

/// PUT /schedule: any of the config's fields; a null weatherAt or playlistAt turns that step off.
struct ScheduleInput: Decodable {
    var enabled: Bool?
    var weatherAt: String??
    var playlistAt: String??
    var location: ScheduleConfig.Location??
    var units: String?
    var seasons: [ScheduleConfig.Season]?

    enum CodingKeys: String, CodingKey { case enabled, weatherAt, playlistAt, location, units, seasons }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled)
        if c.contains(.weatherAt) { weatherAt = .some(try c.decodeIfPresent(String.self, forKey: .weatherAt)) }
        if c.contains(.playlistAt) { playlistAt = .some(try c.decodeIfPresent(String.self, forKey: .playlistAt)) }
        if c.contains(.location) { location = .some(try c.decodeIfPresent(ScheduleConfig.Location.self, forKey: .location)) }
        units = try c.decodeIfPresent(String.self, forKey: .units)
        seasons = try c.decodeIfPresent([ScheduleConfig.Season].self, forKey: .seasons)
    }
}

extension Daemon {
    var scheduleFile: URL { config.stateDir.appendingPathComponent("schedule.json") }
    var scheduleStateFile: URL { config.stateDir.appendingPathComponent("schedule-state.json") }

    static func dayString(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    static func minuteOfDay(_ d: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return c.hour! * 60 + c.minute!
    }

    func saveScheduleState() { scheduleState.save(scheduleStateFile) }

    /// Runs every few seconds.
    func scheduleTick(now: Date = Date()) {
        syncSeasonLamp(now: now)
        guard schedule.enabled, scheduleWeatherTask == nil else { return }
        let today = Self.dayString(now), m = Self.minuteOfDay(now)
        if let w = schedule.weatherMinute, m >= w, scheduleState.weatherDay != today {
            if ScheduleRules.weatherCatchUp(minute: m, weatherAt: w, playlistAt: schedule.playlistMinute) {
                if m - w > 5 { log("schedule: the \(schedule.weatherAt!) weather didn't run (asleep or restarted); running it now") }
                runScheduledWeather()
                return
            }
            scheduleState.weatherDay = today
            saveScheduleState()
            log("schedule: missed the \(schedule.weatherAt!) weather and it's too close to the playlist (or too late); skipping it today")
        }
        if let p = schedule.playlistMinute, m >= p, scheduleState.playlistDay != today {
            scheduleState.playlistDay = today
            saveScheduleState()
            if ScheduleRules.playlistCatchUp(minute: m, playlistAt: p) {
                log("schedule: \(schedule.playlistAt!) playlist\(m - p > 5 ? " (late: the Mac was asleep or the host restarted)" : "")")
                _ = playlistStep()
            } else {
                log("schedule: missed the \(schedule.playlistAt!) playlist by more than 3 hours; skipping it today")
            }
        }
    }

    // MARK: Weather

    func scheduleForecast() async throws -> Forecast {
        guard let loc = schedule.location else { throw HTTPError(409, "set the schedule's location first (PUT /schedule {\"location\": {\"latitude\": …, \"longitude\": …}})") }
        return try await Forecast.today(latitude: loc.latitude, longitude: loc.longitude, fahrenheit: schedule.fahrenheit) { self.log($0) }
    }

    /// Fetches the forecast and shows the picture, holding the playlist so it stays until the playlist step.
    func weatherStep(dryRun: Bool = false) async throws -> (Forecast, SandPattern, Job?) {
        let forecast = try await scheduleForecast()
        let pattern = WeatherPicture.pattern(forecast.condition, temperature: forecast.high)
        let secs = Int(TableTwin.simulate(PatternValidator.validate(pattern).pattern).drawSeconds)
        let unit = schedule.fahrenheit ? "F" : "C"
        log("schedule: weather from \(forecast.source): \(forecast.raw), high \(forecast.high)°\(unit) → \(forecast.condition.rawValue)"
            + (dryRun ? " (dry run)" : "; drawing it, about \(secs / 60) min"))
        guard !dryRun else { return (forecast, pattern, nil) }
        syncSeasonLamp(force: true)
        return (forecast, pattern, try show(pattern, hold: "weather"))
    }

    /// The scheduled weather: retries every 5 minutes until it's drawn or it's too close to the playlist step.
    /// If it never works, the table is woken anyway and the playlist starts.
    func runScheduledWeather() {
        scheduleWeatherTask = Task { @MainActor in
            defer { self.scheduleWeatherTask = nil }
            let day = Self.dayString(Date())
            let giveUp = ScheduleRules.weatherGiveUp(weatherAt: self.schedule.weatherMinute ?? 0, playlistAt: self.schedule.playlistMinute)
            var attempt = 1
            while true {
                var forecast: Forecast?
                do {
                    let (f, _, job) = try await self.weatherStep()
                    forecast = f
                    let done = await self.wait(job!, timeout: 3600)
                    guard done.state == .done else { throw ForecastError(done.error ?? "the drawing didn't start within an hour") }
                    self.scheduleState.weatherDay = day
                    self.scheduleState.wokeDay = day
                    self.scheduleState.lastWeather = .init(at: Date(), source: f.source, raw: f.raw, condition: f.condition.rawValue,
                                                           high: f.high, result: "drawn")
                    self.saveScheduleState()
                    return
                } catch {
                    let m = Self.minuteOfDay(Date())
                    let again = self.schedule.enabled && Self.dayString(Date()) == day && m + 5 < giveUp
                    self.log("schedule: weather attempt \(attempt) failed: \(error.localizedDescription)"
                             + (again ? "; trying again in 5 minutes" : ""))
                    if let f = forecast {
                        self.scheduleState.lastWeather = .init(at: Date(), source: f.source, raw: f.raw, condition: f.condition.rawValue,
                                                               high: f.high, result: "failed: \(error.localizedDescription)")
                    }
                    guard again else { break }
                }
                attempt += 1
                try? await Task.sleep(nanoseconds: 300_000_000_000)
            }
            guard self.schedule.enabled, Self.dayString(Date()) == day else { return }
            self.scheduleState.weatherDay = day
            self.saveScheduleState()
            self.scheduleWake("no weather picture this morning")
        }
    }

    // MARK: Playlist

    /// The playlist step: end the hold and start the next pattern. Returns what it did.
    @discardableResult
    func playlistStep() -> String {
        let today = Self.dayString(Date())
        syncSeasonLamp(force: true)
        if liveRunning { log("schedule: a live session is running; leaving it"); return "a live session is running; left it alone" }
        if playlist.pausedBy != nil {
            playlist.pausedBy = nil
            playlist.save()
            emit("playlist", playlistJSON())
        }
        if !switches.power {
            if scheduleState.wokeDay != today { return scheduleWake("the playlist step") }
            log("schedule: the table was turned off after this morning's wake-up; leaving it off")
            return "the table was turned off after this morning's wake-up; left it off"
        }
        guard playlist.active else {
            log("schedule: the playlist is off; leaving the drawing on the sand")
            return "the playlist is off; nothing to do"
        }
        scheduleState.wokeDay = today
        saveScheduleState()
        playlistAdvance("schedule")
        return "started the playlist's next pattern"
    }

    /// The day's first step turns the table on (the weather does that by drawing). With the playlist on, the
    /// next pattern starts.
    @discardableResult
    func scheduleWake(_ why: String) -> String {
        scheduleState.wokeDay = Self.dayString(Date())
        saveScheduleState()
        if playlist.pausedBy != nil { playlist.pausedBy = nil; playlist.save() }
        if !switches.power {
            log("schedule: \(why); turning the table on" + (playlist.active ? " and starting the playlist" : ""))
            setPower(true)
            return "turned the table on"
        }
        if playlist.active {
            playlistAdvance("schedule: \(why)")
            return "started the playlist's next pattern"
        }
        return "the table is on; the playlist is off"
    }

    // MARK: Seasons

    /// The ids in season today that are on the table, and the share of picks they get.
    func seasonPool(now: Date = Date()) -> (ids: [UInt16], weight: Double) {
        guard schedule.enabled else { return ([], 0) }
        let active = schedule.activeSeasons(on: now)
        let stored = table.storedPatternIds
        var ids: [UInt16] = []
        for s in active { for id in s.ids where stored.contains(id) && !ids.contains(id) { ids.append(id) } }
        return (ids, active.filter { !$0.ids.isEmpty }.map(\.weight).max() ?? 0)
    }

    /// Puts the first active season's colours on the lamp (moving to the next colour per pattern when it has
    /// several), and the user's own lamp back when the season ends. Waits while the lamp switch is off.
    func syncSeasonLamp(now: Date = Date(), force: Bool = false, advance: Bool = false) {
        let season = schedule.enabled ? schedule.activeSeasons(on: now).first(where: { !$0.colors.isEmpty }) : nil
        guard season != nil || scheduleState.lampSeason != nil else { return }
        guard switches.lamp, table.status == .ready, !liveRunning, let state = table.tableState else { return }
        if let season {
            if scheduleState.lampSeason != season.name {
                if scheduleState.lamp == nil {
                    scheduleState.lamp = .init(colorName: state.colorName, color: state.color, shifting: state.shifting,
                                               shiftSeconds: state.shiftSeconds, breathing: state.breathing)
                }
                scheduleState.lampSeason = season.name
                scheduleState.colorIndex = 0
                log("schedule: \(season.name) season; lamp \(season.colors.joined(separator: " / "))"
                    + " (yours, \(scheduleState.lamp!.color)\(scheduleState.lamp!.shifting ? " shifting" : ""), comes back after it)")
            } else if advance, season.colors.count > 1 {
                scheduleState.colorIndex = (scheduleState.colorIndex + 1) % season.colors.count
            } else if !force {
                return
            }
            saveScheduleState()
            sendLampColor(season.colors[scheduleState.colorIndex % season.colors.count])
        } else {
            if let saved = scheduleState.lamp {
                log("schedule: \(scheduleState.lampSeason!) season over; lamp back to \(saved.color)\(saved.shifting ? " (shifting)" : "")")
                restoreLamp(saved)
            }
            scheduleState.lampSeason = nil
            scheduleState.lamp = nil
            saveScheduleState()
        }
    }

    private func sendLampColor(_ hex: String) {
        guard let (r, g, b) = ScheduleRules.parseColor(hex) else { return }
        let level = max(0.01, switches.lampLevel)
        _ = command("season lamp", [Command.previewColor(r: r, g: g, b: b), Command.selectColor("Temp"),
                                    Command.lightMode(shifting: false, breathing: false, brightness: level),
                                    Command.brightness(level)])
    }

    private func restoreLamp(_ saved: ScheduleState.Lamp) {
        let level = max(0.01, switches.lampLevel)
        var packets: [Packet] = []
        if saved.colorName == "Temp" || saved.colorName.isEmpty, let (r, g, b) = ScheduleRules.parseColor(saved.color) {
            packets += [Command.previewColor(r: r, g: g, b: b), Command.selectColor("Temp")]
        } else {
            packets.append(Command.selectColor(saved.colorName))
        }
        packets += [Command.lightMode(shifting: saved.shifting, shiftTime: saved.shiftSeconds, breathing: saved.breathing, brightness: level),
                    Command.brightness(level)]
        _ = command("lamp restore", packets)
    }

    /// A colour set through /settings during a season is what comes back after it.
    func scheduleNoteLightSettings(_ s: SettingsInput) {
        guard scheduleState.lampSeason != nil, var saved = scheduleState.lamp,
              s.color != nil || s.shifting != nil || s.breathing != nil else { return }
        if let c = s.color { saved.colorName = "Temp"; saved.color = c.hasPrefix("#") ? c : "#" + c }
        saved.shifting = s.shifting ?? false
        saved.breathing = s.breathing ?? false
        if let t = s.shiftSeconds { saved.shiftSeconds = UInt16(clamping: t) }
        scheduleState.lamp = saved
        saveScheduleState()
    }

    // MARK: API

    func setSchedule(_ input: ScheduleInput) throws {
        var next = schedule
        if let v = input.enabled { next.enabled = v }
        if let v = input.weatherAt { next.weatherAt = v }
        if let v = input.playlistAt { next.playlistAt = v }
        if let v = input.location { next.location = v }
        if let v = input.units { next.units = v }
        if let v = input.seasons { next.seasons = v }
        try next.validate()
        let timingChanged = next.enabled != schedule.enabled || next.weatherAt != schedule.weatherAt || next.playlistAt != schedule.playlistAt
        schedule = next
        schedule.save(scheduleFile)
        // Turning the routine on (or moving a time) mid-day doesn't run steps whose time has already passed.
        if timingChanged && schedule.enabled {
            let now = Date(), today = Self.dayString(now), m = Self.minuteOfDay(now)
            if let w = schedule.weatherMinute, m > w { scheduleState.weatherDay = today }
            if let p = schedule.playlistMinute, m > p { scheduleState.playlistDay = today }
            saveScheduleState()
        }
        log("schedule: \(schedule.enabled ? "on" : "off"); weather \(schedule.weatherAt ?? "off"), playlist \(schedule.playlistAt ?? "off"), "
            + "\(schedule.location == nil ? "no location" : "location set"), \(schedule.units), \(schedule.seasons.count) seasons")
        emit("schedule", scheduleJSON())
    }

    func scheduleJSON() -> [String: Any] {
        let enc = JSONEncoder()
        var out = (try? JSONSerialization.jsonObject(with: enc.encode(schedule))) as? [String: Any] ?? [:]
        let now = Date(), today = Self.dayString(now)
        var status: [String: Any] = [
            "weatherSource": Forecast.weatherKitAvailable ? "weatherkit" : "open-meteo",
            "activeSeasons": schedule.activeSeasons(on: now).map(\.name),
            "lampSeason": scheduleState.lampSeason ?? NSNull(),
            "today": ["weather": scheduleWeatherTask != nil ? "running" : scheduleState.weatherDay == today ? "done" : "pending",
                      "playlist": scheduleState.playlistDay == today ? "done" : "pending"],
        ]
        if let w = scheduleState.lastWeather {
            status["lastWeather"] = ["at": ISO8601DateFormatter().string(from: w.at), "source": w.source, "raw": w.raw,
                                     "condition": w.condition, "high": w.high, "result": w.result]
        }
        out["status"] = status
        return out
    }

    func scheduleRun(step: String, dryRun: Bool) async throws -> [String: Any] {
        switch step {
        case "weather":
            guard scheduleWeatherTask == nil else { throw HTTPError(409, "the scheduled weather is running now") }
            let (forecast, pattern, job) = try await weatherStep(dryRun: dryRun)
            let report = PatternValidator.validate(pattern)
            var out: [String: Any] = ["forecast": forecast.json,
                                      "drawing": ["name": pattern.name, "points": report.stats.points,
                                                  "estimatedSeconds": Int(TableTwin.simulate(report.pattern).drawSeconds)]]
            if let job { out["job"] = jobJSON(job) }
            return out
        case "playlist":
            guard !dryRun else { throw HTTPError(400, "dryRun applies to the weather step only") }
            return ["result": playlistStep()]
        default:
            throw HTTPError(400, "step must be weather or playlist")
        }
    }
}
