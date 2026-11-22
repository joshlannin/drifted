import DriftedHost
import DriftedKit
import Foundation

// Runnable protocol checks (XCTest / swift-testing need full Xcode; this runs with CLT).
// Usage: swift run DriftedKitChecks

var failures = 0
var current = ""

func expect(_ ok: @autoclosure () throws -> Bool, _ note: String = "", line: Int = #line) rethrows {
    if try !ok() {
        failures += 1
        print("  ✘ \(current) line \(line) \(note)")
    }
}

func check(_ name: String, _ body: () throws -> Void) {
    current = name
    let before = failures
    do { try body() } catch { failures += 1; print("  ✘ \(name) threw \(error)") }
    print("\(failures == before ? "✓" : "✘") \(name)")
}

check("xyAcrossNegativeXAxisStaysContinuous") {
    // A vertical line at x = -0.3 crosses the -x axis; theta must not jump by 2π there.
    let p = SandPattern.fromStrokes([[(x: -0.3, y: 0.2), (x: -0.3, y: -0.2)]], name: "t")
    let maxStep = zip(p.points, p.points.dropFirst()).map { abs($1.theta - $0.theta) }.max() ?? 0
    expect(maxStep < 0.2, "max theta step \(maxStep)")
    expect(PatternValidator.validate(p).issues.isEmpty)
}

check("specVectorsMatchDriftedKit") {
    // spec/vectors/protocol.json is the published test data; DriftedKit must agree with every entry.
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../spec/vectors/protocol.json").standardized
    let doc = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    func bytes(_ hex: String) -> [UInt8] { hex.split(separator: " ").map { UInt8($0, radix: 16)! } }
    var host: [String: [UInt8]] = [:]
    for e in doc["host_to_table"] as! [[String: Any]] { host[e["name"] as! String] = bytes(e["hex"] as! String) }
    var table: [String: [UInt8]] = [:]
    for e in doc["table_to_host"] as! [[String: Any]] { table[e["name"] as! String] = bytes(e["hex"] as! String) }

    var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
    let time = cal.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 13, minute: 45, second: 30))!
    let circle = (0...40).map { WirePoint(t: UInt16(($0 * 60000 / 40) % 60000), r: 25000) }
    let ours: [String: Packet] = [
        "confirm_data": Command.confirmData, "confirm_connection": Command.confirmConnection(true),
        "current_time": Command.currentTime(time, calendar: cal), "draw_pattern_50000": Command.drawPattern(50000),
        "play_pause": Command.playPause, "speed_max": Command.speed(1), "brightness_100": Command.brightness(1),
        "random_off": Command.randomMode(false), "color_white_store_temp": Command.previewColor(r: 255, g: 255, b: 255),
        "select_color_temp": Command.selectColor("Temp"),
        "light_fixed_full": Command.lightMode(shifting: false, breathing: false, brightness: 1),
        "start_upload_50000_2_pages": Command.startUpload(patternId: 50000, pageCount: 2),
        "page_1": Command.page(index: 1, points: circle[0..<40]), "page_2": Command.page(index: 2, points: circle[40...]),
        "end_upload_50000_2_pages": Command.endUpload(patternId: 50000, pageCount: 2),
        "delete_50000": Command.deletePatterns([50000]),
    ]
    for (name, packet) in ours { expect(packet.encoded() == host[name], name) }
    expect(ours.count == host.count, "every host vector is checked")

    func decode(_ name: String) -> TableMessage? {
        var parser = PacketParser()
        return parser.feed(table[name] ?? []).first.map(TableMessage.init)
    }
    expect(decode("waiting_for_confirm") == .waitingForConnection)
    expect(decode("asks_for_time") == .requestsTime)
    expect(decode("init_complete") == .initComplete)
    expect(decode("upload_started") == .uploadStarted(50000))
    expect(decode("upload_missing_pages") == .uploadMissingPages([1, 2]))
    expect(decode("upload_missing_none") == .uploadMissingPages([]))
    expect(decode("upload_stored") == .uploadComplete(50000))
    expect(decode("upload_failed") == .uploadFailed(50000))
    expect(decode("alarm_fatal_10_13") == .alarm(kind: 1, codes: [10, 13]))
    if case .state(let st)? = decode("running_state") {
        expect(st.patternId == 50000 && st.status == 1 && abs(st.progress - 0.25) < 1e-9 && st.colorName == "Temp")
        expect(st.controllerVersion == "A_11_V0.7.12" && st.driverVersion == "B_11_V0.3.3")
        expect(st.color == "#ffffff" && !st.shifting && !st.breathing && st.shiftSeconds == 0)
    } else { expect(false, "running_state didn't decode") }
}

check("confirmDataBytes") {
    expect(Command.confirmData.encoded() == [0x7B, 0x04, 0xD0, 0x4F])
}

check("confirmConnectionBytes") {
    expect(Command.confirmConnection(true).encoded() == [0x7B, 0x06, 0x50, 0x02, 0x01, 0xD4])
}

check("startUploadLayout") {
    // id 0x1234, 488 pages → 13 01 | 34 12 | e8 01 00 00
    let bytes = Command.startUpload(patternId: 0x1234, pageCount: 488).encoded()
    expect(Array(bytes[0...2]) == [0x7B, 11, 0x13])
    expect(Array(bytes[3...9]) == [0x01, 0x34, 0x12, 0xE8, 0x01, 0x00, 0x00])
    expect(bytes.last == bytes.dropLast().reduce(0, &+))
}

check("pageLayout") {
    let pts = [WirePoint(t: 0x0102, r: 0x0304), WirePoint(t: 59999, r: 50000)]
    let bytes = Command.page(index: 1, points: pts[...]).encoded()
    expect(bytes[1] == UInt8(4 + 4 + 8))
    expect(bytes[2] == 0x53)
    expect(Array(bytes[3...6]) == [0x01, 2, 0x01, 0x00])
    expect(Array(bytes[7...10]) == [0x02, 0x01, 0x04, 0x03])
    expect(Array(bytes[11...14]) == [0x5F, 0xEA, 0x50, 0xC3])
}

check("fullPageFitsInOnePacket") {
    let pts = Array(repeating: WirePoint(t: 1, r: 1), count: Command.pointsPerPage)
    expect(Command.page(index: 7, points: pts[...]).encoded().count == 168)
}

check("parserReassemblesSplitAndJoinedPackets") {
    let a = Packet(command: 0x34, data: [0x03, 0x50, 0xC3]).encoded()
    let b = Packet(command: 0x4F, data: [0x01]).encoded()
    var parser = PacketParser()
    expect(parser.feed([0x00] + a.prefix(3)) == [])
    let out = parser.feed(Array(a.dropFirst(3)) + b)
    expect(out.map { TableMessage($0) } == [.uploadComplete(50000), .initComplete])
    expect(parser.droppedBytes == 1)
}

check("parserAcceptsAckBitChecksumVariant") {
    // Checksum computed over the stripped command but sent with the ack bit set.
    var raw = Packet(command: 0x35, data: [0x01]).encoded()
    raw[2] |= 0x80
    var parser = PacketParser()
    expect(parser.feed(raw).count == 1)
}

check("messages") {
    expect(TableMessage(Packet(command: 0x34, data: [0x01, 2, 3, 0, 9, 0])) == .uploadMissingPages([3, 9]))
    expect(TableMessage(Packet(command: 0x50, data: [0x01])).reply == Command.confirmConnection(true))
    expect(TableMessage(Packet(command: 0x50, data: [], ack: true)) == .confirm)
    expect(TableMessage(Packet(command: 0x50, data: [], ack: true)).reply == nil)
    expect(TableMessage(Packet(command: 0x33, data: [3, 0, 2, 1, 0, 2, 0])) == .storedPatterns(page: 0, ids: [1, 2]))
    expect(TableMessage(Packet(command: 0x33, data: [3, 0, 2, 1, 0, 2, 0])).reply == Command.confirmData)
}

check("driftTextRoundTripAndWireConversion") {
    let text = "191413,100000\n359999,526\n0,0\n"
    let p = SandPattern(driftText: text, name: "t")
    expect(p.driftText == text)
    // Wire: (theta / 6, rho / 2)
    expect(p.wirePoints == [WirePoint(t: 31902, r: 50000), WirePoint(t: 59999, r: 263), WirePoint(t: 0, r: 0)])
}

check("largePatternPaging") {
    // 19,493 points → 488 pages of 40 (the last page holds 13).
    let p = SandPattern(name: "big", points: (0..<19493).map { PolarPoint(theta: Double($0) * 0.001, rho: 0.5) })
    expect(p.pageCount == 488)
    expect(p.wirePoints.count == 19493)
}

check("strokesAreDensified") {
    let p = SandPattern.fromStrokes([[(x: -1, y: 0), (x: 1, y: 0)]], name: "line", maxStep: 0.01)
    expect(p.points.count == 201)
    expect(abs(p.length - 2) < 1e-9)
}

check("twinTimesAndRendersADrawing") {
    // A straight line 1 radius long draws in 1 / radiiPerSecond seconds; the move to it is timed separately.
    let line = SandPattern.fromStrokes([[(x: 0, y: 0), (x: 1, y: 0)]], name: "line")
    let run = TableTwin.simulate(line, from: PolarPoint(theta: .pi / 2, rho: 1))
    expect(abs(run.drawSeconds - 1 / DrawTime.radiiPerSecond) < 0.5, "draw \(run.drawSeconds)")
    expect(run.transitSeconds > 0 && run.samples.first?.drawing == false)
    // A quarter turn at the rim is an arc (the table interpolates theta and rho), so it takes pi/2 radii, not a chord.
    let arc = TableTwin.simulate(SandPattern(name: "arc", points: [PolarPoint(theta: 0, rho: 1), PolarPoint(theta: .pi / 2, rho: 1)]))
    expect(abs(arc.drawSeconds * DrawTime.radiiPerSecond - .pi / 2) < 0.01, "arc \(arc.drawSeconds)")
    let spiral = Generators.spiral(turns: 5)
    expect(PatternPreview.png(spiral, size: 128, style: .sand) != nil)
    expect(PatternPreview.png(spiral, size: 128, style: .path) != nil)
    expect(PatternPreview.gif(spiral, size: 96, frames: 4) != nil)
}

check("generatorsStayInDiscWithSmallSteps") {
    for g in [Generators.spiral(turns: 10), Generators.rose(petals: 4), Generators.spirograph()] {
        expect(!g.points.isEmpty)
        expect(g.points.allSatisfy { $0.rho <= 1.0000001 })
        let maxStep = zip(g.points, g.points.dropFirst()).map { hypot($1.x - $0.x, $1.y - $0.y) }.max() ?? 0
        expect(maxStep <= 0.0105, "\(g.name)")
    }
}

check("weekdayAndMonthEncoding") {
    // Sunday 2026-10-25 13:45:30 → yy=26, month 9 (0-based), day 25, weekday 7.
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    let date = cal.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 13, minute: 45, second: 30))!
    expect(Array(Command.currentTime(date, calendar: cal).data) == [2, 26, 9, 25, 13, 45, 30, 7])
}

check("weatherPictureMatchesWeatherPy") {
    // Fingerprints from `python3 designs/weather.py` (designs/weather.py's densified path: points, length,
    // last point). The Swift port must keep drawing the same picture.
    let golden: [(WeatherPicture.Condition, Int, Int, Double, (Double, Double))] = [
        (.sunny, 72, 12787, 94.25203, (0.302041, 0.57657)),
        (.partlycloudy, 54, 16074, 108.713627, (0.306441, 0.57657)),
        (.snow, -12, 15438, 105.765237, (0.382791, 0.50657)),
        (.thunderstorm, 88, 15197, 100.476844, (0.302041, 0.57657)),
        (.hail, 147, 15681, 93.396647, (0.407791, 0.48657)),
    ]
    for (c, t, n, length, last) in golden {
        let p = WeatherPicture.path(c, temperature: t)
        let l = zip(p, p.dropFirst()).reduce(0.0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
        expect(p.count == n && abs(l - length) < 1e-5 && abs(p.last!.x - last.0) < 1e-6 && abs(p.last!.y - last.1) < 1e-6,
               "\(c.rawValue) \(t): \(p.count) points, length \(l)")
    }
    expect(WeatherPicture.temperaturePath(72).count == 4442)
    for c in WeatherPicture.Condition.allCases {
        let r = PatternValidator.validate(WeatherPicture.pattern(c, temperature: 72))
        let secs = TableTwin.simulate(r.pattern).drawSeconds
        expect(r.ok && secs > 600 && secs < 1200, "\(c.rawValue): ok \(r.ok), \(Int(secs)) s")
    }
}

check("weatherConditionsFromSources") {
    expect(WeatherPicture.Condition(weatherKit: "mostlyClear") == .sunny)
    expect(WeatherPicture.Condition(weatherKit: "partlyCloudy") == .partlycloudy)
    expect(WeatherPicture.Condition(weatherKit: "heavyRain") == .heavyRain)
    expect(WeatherPicture.Condition(weatherKit: "scatteredThunderstorms") == .thunderstorm)
    expect(WeatherPicture.Condition(weatherKit: "wintryMix") == .sleet)
    expect(WeatherPicture.Condition(weatherKit: "flurries") == .snow)
    expect(WeatherPicture.Condition(weatherKit: "somethingNew") == .cloudy)
    expect(WeatherPicture.Condition(wmo: 0) == .sunny && WeatherPicture.Condition(wmo: 2) == .partlycloudy)
    expect(WeatherPicture.Condition(wmo: 45) == .fog && WeatherPicture.Condition(wmo: 65) == .heavyRain)
    expect(WeatherPicture.Condition(wmo: 66) == .sleet && WeatherPicture.Condition(wmo: 75) == .snow)
    expect(WeatherPicture.Condition(wmo: 95) == .thunderstorm && WeatherPicture.Condition(wmo: 3) == .cloudy)
}

check("scheduleTimingAndSeasons") {
    let w = ScheduleRules.parseTime("04:15")!, p = ScheduleRules.parseTime("09:00")!
    expect(w == 255 && p == 540 && ScheduleRules.parseTime("9:00") == 540 && ScheduleRules.parseTime("24:00") == nil
           && ScheduleRules.parseTime("09:5") == nil)
    // Weather: on time, or late while 30 min remain before the playlist step.
    expect(ScheduleRules.weatherCatchUp(minute: w, weatherAt: w, playlistAt: p))
    expect(ScheduleRules.weatherCatchUp(minute: 7 * 60, weatherAt: w, playlistAt: p))
    expect(!ScheduleRules.weatherCatchUp(minute: 8 * 60 + 30, weatherAt: w, playlistAt: p))
    expect(ScheduleRules.weatherCatchUp(minute: 8 * 60 + 29, weatherAt: w, playlistAt: p))
    expect(!ScheduleRules.weatherCatchUp(minute: 10 * 60, weatherAt: w, playlistAt: nil))
    // Playlist: up to 3 hours late.
    expect(ScheduleRules.playlistCatchUp(minute: p + 179, playlistAt: p) && !ScheduleRules.playlistCatchUp(minute: p + 180, playlistAt: p))
    // A season's own playlist time wins (the earliest of several); the step stays off when playlistAt is off.
    expect(ScheduleRules.playlistTime("09:00", seasonTimes: []) == "09:00")
    expect(ScheduleRules.playlistTime("09:00", seasonTimes: ["07:30", "06:00", "bad"]) == "06:00")
    expect(ScheduleRules.playlistTime("09:00", seasonTimes: ["10:00"]) == "10:00")
    expect(ScheduleRules.playlistTime(nil, seasonTimes: ["06:00"]) == nil)
    expect(ScheduleRules.weatherTime("04:15", seasonsWantWeather: []) == "04:15")
    expect(ScheduleRules.weatherTime("04:15", seasonsWantWeather: [true, true]) == "04:15")
    expect(ScheduleRules.weatherTime("04:15", seasonsWantWeather: [true, false]) == nil)
    expect(ScheduleRules.weatherTime(nil, seasonsWantWeather: [true]) == nil)
    expect(ScheduleRules.weatherGiveUp(weatherAt: w, playlistAt: 6 * 60) == 5 * 60 + 30)

    var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "America/Denver")!
    func day(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date { cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))! }
    func inSeason(_ s: String, _ e: String, _ date: Date) -> Bool { ScheduleRules.season(start: s, end: e, contains: date, calendar: cal) }
    expect(inSeason("2026-12-04", "2026-12-12", day(2026, 12, 4, 0)) && inSeason("2026-12-04", "2026-12-12", day(2026, 12, 12, 23)))
    expect(!inSeason("2026-12-04", "2026-12-12", day(2026, 12, 13, 0)) && !inSeason("2026-12-04", "2026-12-12", day(2027, 12, 5)))
    expect(inSeason("12-01", "12-26", day(2030, 12, 25)) && !inSeason("12-01", "12-26", day(2030, 12, 27)))
    expect(inSeason("12-20", "01-06", day(2027, 1, 3)) && inSeason("12-20", "01-06", day(2026, 12, 31))
           && !inSeason("12-20", "01-06", day(2027, 1, 7)))
    expect(!inSeason("12-01", "2026-12-26", day(2026, 12, 5)), "mixed forms never match")
    expect(ScheduleRules.parseColor("#FFD27A")! == (255, 210, 122) && ScheduleRules.parseColor("#12345") == nil)
}

check("lampRules") {
    let mine = LampColor.fixed("#FFD27A"), orange = LampColor.fixed("#ff7518")
    let stock = LampColor(colorName: "c0", color: "#50ffb2"), other = LampColor(colorName: "c2", color: "#ff00ff")
    expect(mine.color == "#ffd27a" && mine.colorName == "Temp" && !mine.shifting)
    // The table echoes the colour it was given; a step or two of rounding still counts.
    expect(LampRules.shows(LampColor(colorName: "Temp", color: "#FFD27B"), mine))
    expect(!LampRules.shows(LampColor(colorName: "Temp", color: "#ffd290"), mine) && !LampRules.shows(stock, mine))
    expect(LampRules.shows(LampColor(colorName: "c1", color: "#123456", shifting: true), LampColor(colorName: "c0", color: "#50ffb2", shifting: true)))
    expect(!LampRules.shows(LampColor(colorName: "Temp", color: "#ffd27a", shifting: true), mine))
    // Nothing remembered yet: what the table shows is the user's, except while a season has the lamp.
    expect(LampRules.decide(table: stock, wanted: nil, inSeason: false) == .adopt)
    expect(LampRules.decide(table: orange, wanted: nil, inSeason: true) == .nothing)
    // The table lost the colour: put it back. In a season, that's the season's colour.
    expect(LampRules.decide(table: mine, wanted: mine, inSeason: false) == .nothing)
    expect(LampRules.decide(table: stock, wanted: mine, inSeason: false) == .restore)
    expect(LampRules.decide(table: stock, wanted: orange, inSeason: true) == .restore)
    // Something else, chosen somewhere else (the HoMedics app): follow it, but never in a season.
    expect(LampRules.decide(table: other, wanted: mine, inSeason: false) == .adopt)
    expect(LampRules.decide(table: LampColor.fixed("#102030"), wanted: mine, inSeason: false) == .adopt)
    expect(LampRules.decide(table: mine, wanted: orange, inSeason: true) == .nothing)
    expect(LampRules.decide(table: LampColor(colorName: "c0", color: "#50ffb2", shifting: true), wanted: mine, inSeason: false) == .adopt)
    // The stock colour is the user's own choice: nothing to restore.
    expect(LampRules.decide(table: stock, wanted: stock, inSeason: false) == .nothing)
}

check("tablePlaylists") {
    // 0x30/3: page 1, two playlists: "Demo" [4] and an empty one.
    let data: [UInt8] = [3, 1, 2] + Array("Demo".utf8) + [0, 1, 4, 0] + Array("id_1".utf8) + [0, 0]
    expect(TableMessage(Packet(command: 0x30, data: data))
           == .playlists(page: 1, [TablePlaylist(name: "Demo", ids: [4]), TablePlaylist(name: "id_1", ids: [])]))
    expect(TableMessage(Packet(command: 0x30, data: [1])) == .playlistsBegin)
    expect(TableMessage(Packet(command: 0x30, data: [2])) == .playlistsEnd)
    // Trailing bytes mean the layout guess is wrong: don't pretend to understand it.
    if case .playlists = TableMessage(Packet(command: 0x30, data: data + [9])) { expect(false, "trailing bytes accepted") }
    expect(TableMessage(Packet(command: 0x30, data: [3])).reply == Command.confirmData)

    expect(Command.createPlaylist("drifted_mix", ids: [1, 50100]).encoded()
           == [0x7B, 22, 0x10, 1] + Array("drifted_mix".utf8) + [0, 2, 1, 0, 0xB4, 0xC3]
              + [Packet.checksumForChecks([0x7B, 22, 0x10, 1] + Array("drifted_mix".utf8) + [0, 2, 1, 0, 0xB4, 0xC3])])
    expect(Command.replacePlaylist("a", name: "b", ids: [7]).data == [3, 0x61, 0, 0x62, 0, 1, 7, 0])
    expect(Command.selectPlaylist("drifted_mix").data == [8] + Array("drifted_mix".utf8) + [0])
    expect(Command.createPlaylist("x", ids: Array(1...20)).encoded().count < 200, "20 ids fit the table's 200-byte frame limit")
    expect(Command.isSafePlaylistName("drifted_mix") && !Command.isSafePlaylistName("Drifted Mix")
           && !Command.isSafePlaylistName(String(repeating: "a", count: 19)) && !Command.isSafePlaylistName(""))
}

check("relayFraming") {
    // type:u8, length:u16 little-endian, payload (relay/README.md, "Relay protocol").
    let write = RelayFrame(.tableWrite, Command.confirmData.encoded())
    expect(write.encoded() == [0x11, 0x04, 0x00, 0x7B, 0x04, 0xD0, 0x4F])
    expect(RelayFrame.hello(token: "0123456789abcdef").encoded() == [0x01, 0x11, 0x00, 0x00] + Array("0123456789abcdef".utf8))
    expect(RelayFrame.hello(token: "0123456789abcdef", observe: true).encoded()[3] == 1)
    expect(RelayFrame.command("select aa:bb:cc:dd:ee:ff").encoded().prefix(3) == [0x30, 24, 0])
    let big = RelayFrame(.tableData, Array(repeating: 0xAB, count: 300))
    expect(big.encoded().prefix(3) == [0x10, 0x2C, 0x01], "length is little-endian")

    // Frames split anywhere and joined together come back whole and in order.
    let stream = write.encoded() + big.encoded() + RelayFrame(.status, Array(#"{"link":"linked"}"#.utf8)).encoded()
    for cut in [1, 2, 3, 5, 7, 8, 100, stream.count - 1] {
        var p = RelayFrameParser()
        let frames = try p.feed(stream[0..<cut]) + p.feed(stream[cut...])
        expect(frames == [write, big, RelayFrame(.status, Array(#"{"link":"linked"}"#.utf8))], "cut at \(cut)")
    }
    var bytewise = RelayFrameParser(), got: [RelayFrame] = []
    for b in stream { got += try bytewise.feed([b]) }
    expect(got.count == 3 && got[1].payload.count == 300)
    // An empty payload is a valid frame.
    var p = RelayFrameParser()
    try expect(try p.feed([0x30, 0, 0]) == [RelayFrame(.command)])
    // A length over the limit means the stream is out of step: the connection is dropped, not resynced.
    var oversize = RelayFrameParser()
    expect((try? oversize.feed([0x10, 0x01, 0x10])) == nil, "4097-byte frame rejected")
    // Unknown types parse (and are ignored by the link), so the relay can add messages.
    var unknown = RelayFrameParser()
    try expect(try unknown.feed([0x7E, 1, 0, 9]).first?.kind == nil)
}

check("relayStatusAndScanIds") {
    let json = #"{"link":"linked","released":false,"table":{"name":"KS2106100812","address":"aa:bb:cc:dd:ee:ff","addrType":0},"rssi":-61,"wifiRssi":-48,"firmware":"0.1.0","gate":"open"}"#
    let frame = RelayFrame(.status, Array(json.utf8))
    let s = RelayStatus(json: frame.json!)
    expect(s?.linked == true && s?.rssi == -61 && s?.wifiRssi == -48 && s?.table?.name == "KS2106100812" && s?.gate == "open")
    expect(RelayStatus(json: ["link": "scanning", "table": NSNull(), "rssi": NSNull()])?.linked == false)
    expect(RelayStatus(json: ["rssi": -50]) == nil, "link is required")
    // Tables behind a relay get a stand-in id that maps back to the address (Choose table).
    let t = RelayTable(name: "KS2106100812", address: "AA:BB:CC:DD:EE:0F", addrType: 1, rssi: -70)
    expect(RelayTable.address(fromId: t.id) == "aa:bb:cc:dd:ee:0f")
    expect(t.id.uuidString.hasPrefix("D21F7000-0000-0000-0001-"))
    expect(RelayTable.address(fromId: UUID()) == nil, "a CoreBluetooth id isn't a relay table")
    expect(RelayEndpoint(token: "x").description.contains("first relay") && RelayEndpoint(host: "10.0.0.5", token: "x").description == "10.0.0.5:8766")
}

check("relayJobEncoding") {
    // MSG_JOB_BEGIN as relay/firmware/main/job.c reads it (relay/README.md, "Jobs").
    expect(RelayJob.crc32(Array("123456789".utf8)) == 0xCBF4_3926, "CRC-32 is zlib's")
    expect(RelayJob.crc32([UInt8]()) == 0)
    let points = (0..<45).map { WirePoint(t: UInt16($0 * 100), r: 20000) }
    let job = RelayJob([
        .init(.send(Command.power(true))),
        .init(.upload(points: points, ids: [50001, 50002])),
        .init(.expect(.drawing(7), timeout: 6), onFail: 4),
        .init(.end),
        .init(.play(nil)),
        .init(.expect(.packet(command: 0x30, action: 3, contains: [0x61, 0x00]), timeout: 20)),
        .init(.wait(1.5)),
    ], linger: 2)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let (begin, blob) = try job.encoded(id: 0x0102_0304, now: now, timeZone: TimeZone(secondsFromGMT: -7 * 3600)!)
    expect(blob.count == 180 && Array(blob[4..<8]) == [100, 0, 0x20, 0x4E], "points are t:u16, r:u16, as in a page")
    var r = begin[...]
    func take(_ n: Int) -> [UInt8] { defer { r = r.dropFirst(n) }; return Array(r.prefix(n)) }
    func u32(_ b: [UInt8]) -> UInt32 { UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24 }
    expect(take(4) == [4, 3, 2, 1], "job id, little-endian")
    expect(u32(take(4)) == 1_800_000_000 - 7 * 3600, "the table's clock is local time")
    expect(take(2) == [0xD0, 0x07], "linger in ms")
    expect(u32(take(4)) == 180 && u32(take(4)) == RelayJob.crc32(blob))
    expect(take(1) == [7])
    let power = Command.power(true).encoded()
    expect(take(4) == [1, 0xFF, UInt8(power.count), 0] && take(power.count) == power, "send: one table packet")
    expect(take(4) == [4, 0xFF, 13, 0] && take(13) == [45, 0, 0, 0, 0, 0, 0, 0, 2, 0x51, 0xC3, 0x52, 0xC3], "upload: points, offset, ids")
    expect(take(4) == [2, 4, 5, 0] && take(5) == [0x70, 0x17, 2, 7, 0], "expect drawing, with a step to carry on from")
    expect(take(4) == [6, 0xFF, 0, 0])
    expect(take(4) == [3, 0xFF, 2, 0] && take(2) == [0, 0], "play 0: the id the upload went into")
    expect(take(4) == [2, 0xFF, 8, 0] && take(8) == [0x20, 0x4E, 1, 0x30, 3, 2, 0x61, 0x00])
    expect(take(4) == [5, 0xFF, 2, 0] && take(2) == [0xDC, 0x05] && r.isEmpty)
    expect((try? RelayJob([.init(.end, onFail: 5)]).encoded(id: 1)) == nil, "a jump past the end is refused")
    // Jobs that toggle or step something aren't handed over twice if the relay loses them mid-way.
    expect(job.repeatable && RelayJob([.init(.send(Command.brightness(0)))]).repeatable && RelayJob().repeatable)
    expect(!RelayJob([.init(.send(Command.playPause))]).repeatable && !RelayJob([.init(.send(Command.next))]).repeatable
           && !RelayJob([.init(.send(Command.power(true))), .init(.send(Command.previous))]).repeatable)
    expect((try? RelayJob(Array(repeating: .init(.end), count: 33)).encoded(id: 1)) == nil, "at most 32 steps")

    let result = RelayJobResult(json: try JSONSerialization.jsonObject(with: Data(#"{"job":1,"ok":false,"error":"the table didn't start pattern 7","stage":"step","failedOp":2,"linkMs":4100,"readyMs":6000,"totalMs":52000,"rssi":-50,"links":2,"handshakes":2,"restarts":1,"tableBytes":640,"truncated":false,"ops":[[1,1,0,0,210],[1,1,50001,2,43800],[1,0,7,4,16000]]}"#.utf8)) as! [String: Any])
    expect(result?.failedAtStep == true && result?.failedStep == 2 && result?.readySeconds == 6 && result?.rssi == -50)
    expect(result?.steps.count == 3 && result?.steps[1].value == 50001 && result?.steps[1].count == 2 && result?.steps[2].ok == false)
    let status = RelayStatus(json: ["link": "linked", "job": ["id": 9, "state": "running", "progress": 40]])
    expect(status?.jobRunning == true && status?.jobId == 9 && status?.jobProgress == 40)
    expect(RelayStatus(json: ["link": "released", "job": ["id": 9, "state": "done"]])?.jobRunning == false)
}

print(failures == 0 ? "All checks passed" : "\(failures) check(s) failed")
exit(failures == 0 ? 0 : 1)
