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

print(failures == 0 ? "All checks passed" : "\(failures) check(s) failed")
exit(failures == 0 ? 0 : 1)
