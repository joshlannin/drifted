import Foundation

/// Little-endian argument writer (see docs/protocol.md, Framing).
struct ByteWriter {
    var bytes: [UInt8] = []

    mutating func u8(_ v: UInt8) { bytes.append(v) }
    mutating func bool(_ v: Bool) { bytes.append(v ? 1 : 0) }
    mutating func u16(_ v: UInt16) { bytes += [UInt8(v & 0xFF), UInt8(v >> 8)] }
    mutating func u32(_ v: UInt32) { for shift in stride(from: 0, to: 32, by: 8) { bytes.append(UInt8((v >> UInt32(shift)) & 0xFF)) } }
    mutating func string(_ s: String) { bytes += Array(s.utf8) + [0] }
    mutating func u16Array(_ values: [UInt16]) {
        precondition(values.count <= 255)
        u8(UInt8(values.count))
        values.forEach { u16($0) }
    }
}

/// Little-endian argument reader (returns nil when out of bytes).
struct ByteReader {
    private let bytes: [UInt8]
    private var index: Int

    init<C: Collection>(_ bytes: C) where C.Element == UInt8 {
        self.bytes = Array(bytes)
        self.index = 0
    }

    mutating func u8() -> UInt8? {
        guard index < bytes.count else { return nil }
        defer { index += 1 }
        return bytes[index]
    }

    mutating func bool() -> Bool? { u8().map { $0 != 0 } }

    mutating func u16() -> UInt16? {
        guard index + 2 <= bytes.count else { return nil }
        defer { index += 2 }
        return UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8
    }

    mutating func string() -> String? {
        guard index <= bytes.count else { return nil }
        let end = bytes[index...].firstIndex(of: 0) ?? bytes.count
        defer { index = min(end + 1, bytes.count + 1) }
        return String(decoding: bytes[index..<end], as: UTF8.self)
    }

    mutating func rgb() -> (UInt8, UInt8, UInt8)? {
        guard let r = u8(), let g = u8(), let b = u8() else { return nil }
        return (r, g, b)
    }

    mutating func u16Array() -> [UInt16]? {
        guard let count = u8() else { return nil }
        var out: [UInt16] = []
        for _ in 0..<count {
            guard let v = u16() else { return nil }
            out.append(v)
        }
        return out
    }
}

/// Command bytes (CommandType) and builders for the app → table packets we use.
public enum Command {
    static let sendsData: UInt8 = 0x10
    static let lighting: UInt8 = 0x11
    static let hibernate: UInt8 = 0x12
    static let fileOps: UInt8 = 0x13
    static let userActions: UInt8 = 0x14
    static let fileData: UInt8 = 0x53
    static let connection: UInt8 = 0x50

    /// Points per upload page. Pages other than the last must hold exactly this many.
    public static let pointsPerPage = 40

    private static func make(_ cmd: UInt8, _ action: UInt8?, ack: Bool = false, _ args: (inout ByteWriter) -> Void = { _ in }) -> Packet {
        var w = ByteWriter()
        if let action { w.u8(action) }
        args(&w)
        return Packet(command: cmd, data: w.bytes, ack: ack)
    }

    /// Generic acknowledgement the app sends for nearly every table message: `7B 04 D0 4F`.
    public static let confirmData = make(connection, nil, ack: true)

    public static func confirmConnection(_ ok: Bool = true) -> Packet { make(connection, 2) { $0.bool(ok) } }

    public static func currentTime(_ date: Date = Date(), calendar: Calendar = .current) -> Packet {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .weekday], from: date)
        // year % 100, month 0-based, weekday Mon=1 … Sun=7.
        let weekday = ((c.weekday ?? 1) + 5) % 7 + 1
        return make(hibernate, 2) {
            $0.u8(UInt8((c.year ?? 2000) % 100))
            $0.u8(UInt8((c.month ?? 1) - 1))
            $0.u8(UInt8(c.day ?? 1))
            $0.u8(UInt8(c.hour ?? 0))
            $0.u8(UInt8(c.minute ?? 0))
            $0.u8(UInt8(c.second ?? 0))
            $0.u8(UInt8(weekday))
        }
    }

    public static func startUpload(patternId: UInt16, pageCount: Int) -> Packet {
        make(fileOps, 1) { $0.u16(patternId); $0.u32(UInt32(pageCount)) }
    }

    public static func endUpload(patternId: UInt16, pageCount: Int) -> Packet {
        make(fileOps, 2) { $0.u16(patternId); $0.u32(UInt32(pageCount)) }
    }

    public static func deletePatterns(_ ids: [UInt16]) -> Packet { make(fileOps, 3) { $0.u16Array(ids) } }

    /// `pageIndex` is 1-based on the wire.
    public static func page(index pageIndex: Int, points: ArraySlice<WirePoint>) -> Packet {
        precondition(points.count <= pointsPerPage)
        return make(fileData, 1) {
            $0.u8(UInt8(points.count))
            $0.u16(UInt16(pageIndex))
            for p in points { $0.u16(p.t); $0.u16(p.r) }
        }
    }

    public static func drawPattern(_ id: UInt16) -> Packet { make(userActions, 1) { $0.u16(id) } }
    public static let playPause = make(userActions, 3)
    public static let next = make(userActions, 4)
    public static let previous = make(userActions, 5)

    /// `fraction` 0…1 maps to the raw 30…75 range the app uses.
    public static func speed(_ fraction: Double) -> Packet {
        let raw = 30 + max(0, min(1, fraction)) * 45
        return make(userActions, 6) { $0.u8(UInt8(raw)) }
    }

    /// `fraction` 0…1 maps to 0…100.
    public static func brightness(_ fraction: Double) -> Packet {
        make(userActions, 7) { $0.u8(UInt8(max(0, min(1, fraction)) * 100)) }
    }

    /// Persistent light mode (0x11/4). `shiftTime` is seconds per palette colour when shifting.
    public static func lightMode(shifting: Bool, shiftTime: UInt16 = 0, breathing: Bool, brightness: Double) -> Packet {
        make(lighting, 4) {
            $0.bool(shifting); $0.u16(shiftTime); $0.bool(breathing)
            $0.u8(UInt8(max(0, min(1, brightness)) * 100))
        }
    }

    /// Shows a colour and stores it in the palette as "Temp" (0x14/15).
    public static func previewColor(r: UInt8, g: UInt8, b: UInt8) -> Packet {
        make(userActions, 15) { $0.bool(true); $0.u8(r); $0.u8(g); $0.u8(b) }
    }

    /// Selects a palette colour by name (0x14/13). `previewColor` then `selectColor("Temp")` = a fixed custom colour.
    public static func selectColor(_ name: String) -> Packet { make(userActions, 13) { $0.string(name) } }

    public static func randomMode(_ on: Bool) -> Packet { make(userActions, 10) { $0.bool(on) } }
    public static func loopMode(_ on: Bool) -> Packet { make(userActions, 11) { $0.bool(on) } }
    public static func power(_ on: Bool) -> Packet { make(userActions, 16) { $0.bool(on) } }
}
