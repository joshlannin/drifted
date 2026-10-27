import Foundation

/// Running state broadcast by the table (`0x35/1`).
public struct TableState: Equatable {
    public var brightness: UInt8
    public var colorName: String
    public var speedRaw: UInt8
    public var playlistId: String
    public var patternId: UInt16
    /// 0…1
    public var progress: Double
    public var status: UInt8
    public var randomMode: Bool
    public var loopMode: Bool
    public var sleepEnabled: Bool
    public var controllerVersion: String?
    public var driverVersion: String?
    public var poweredOn: Bool?
}

/// Table → app messages we understand.
public enum TableMessage: Equatable {
    case waitingForConnection                  // 0x50/1
    case confirm                               // 0x50 (no action) / 0xD0
    case initComplete                          // 0x4F/1
    case requestsTime                          // 0x32/2
    case storedPatterns(page: UInt8, ids: [UInt16])   // 0x33/3
    case uploadMissingPages([Int])             // 0x34/1 (1-based)
    case uploadStarted(UInt16)                 // 0x34/2
    case uploadComplete(UInt16)                // 0x34/3
    case deleteComplete(UInt16)                // 0x34/4
    case uploadFailed(UInt16)                  // 0x34/5
    case noStorage(UInt16)                     // 0x34/6
    case state(TableState)                     // 0x35/1
    case alarm(kind: UInt8, codes: [UInt16])   // 0x37/1…3
    case other(Packet)

    public init(_ packet: Packet) {
        var r = ByteReader(packet.arguments)
        switch (packet.command, packet.action) {
        case (0x50, 1): self = .waitingForConnection
        case (0x50, nil): self = .confirm
        case (0x4F, 1): self = .initComplete
        case (0x32, 2): self = .requestsTime
        case (0x33, 3):
            let page = r.u8() ?? 0
            self = .storedPatterns(page: page, ids: r.u16Array() ?? [])
        case (0x34, 1): self = .uploadMissingPages((r.u16Array() ?? []).map(Int.init))
        case (0x34, 2): self = .uploadStarted(r.u16() ?? 0)
        case (0x34, 3): self = .uploadComplete(r.u16() ?? 0)
        case (0x34, 4): self = .deleteComplete(r.u16() ?? 0)
        case (0x34, 5): self = .uploadFailed(r.u16() ?? 0)
        case (0x34, 6): self = .noStorage(r.u16() ?? 0)
        case (0x35, 1):
            if let s = Self.parseState(&r) { self = .state(s) } else { self = .other(packet) }
        case (0x37, let kind?) where (1...3).contains(kind):
            self = .alarm(kind: kind, codes: r.u16Array() ?? [])
        default: self = .other(packet)
        }
    }

    private static func parseState(_ r: inout ByteReader) -> TableState? {
        guard let brightness = r.u8(), let colorName = r.string(), r.rgb() != nil,
              let speed = r.u8(), let playlist = r.string(), let pattern = r.u16(),
              let progress = r.u16() else { return nil }
        let status = r.u8() ?? 0xFF
        let random = r.bool() ?? false, loop = r.bool() ?? false, sleep = r.bool() ?? false
        _ = r.bool(); _ = r.bool(); _ = r.u16()  // breath, shifting, shift time
        let ctrl = r.string(); _ = r.bool(); _ = r.u8()
        let driver = r.string(); _ = r.bool(); _ = r.u8()
        return TableState(brightness: brightness, colorName: colorName, speedRaw: speed, playlistId: playlist,
                          patternId: pattern, progress: Double(progress) / 10000, status: status,
                          randomMode: random, loopMode: loop, sleepEnabled: sleep,
                          controllerVersion: ctrl, driverVersion: driver, poweredOn: r.bool())
    }

    /// The reply this message expects, if any (docs/protocol.md, Session).
    public var reply: Packet? {
        switch self {
        case .waitingForConnection: return Command.confirmConnection(true)
        case .requestsTime: return Command.currentTime()
        case .confirm: return nil
        case .other(let p):
            // Only ack command families the app knows (it drops unknown ones silently).
            return (0x30...0x38).contains(p.command) ? Command.confirmData : nil
        default: return Command.confirmData
        }
    }
}

/// A 0x37 alarm (codes: docs/protocol.md).
public struct TableAlarm: CustomStringConvertible, Sendable {
    public var kind: UInt8       // 1 fatal, 2 recoverable, 3 warning
    public var codes: [UInt16]
    public var at: Date
    public var isFatal: Bool { kind == 1 }

    public static let codeNames: [UInt16: String] = [
        1: "file queue full", 2: "setting coordinates failed", 3: "file download failed", 4: "SD card full",
        5: "file already open", 6: "too much file data lost", 8: "motor driver error", 9: "SD card init failed",
        10: "can't open pattern file", 11: "can't read pattern file", 12: "can't close pattern file",
        13: "can't delete pattern file", 14: "file seek failed", 15: "position reset failed", 16: "homing failed",
        17: "can't create received file", 19: "receive queue error",
    ]

    public var description: String {
        let level = ["alarm", "FATAL ERROR", "error", "warning"][Int(min(kind, 3))]
        return "\(level): " + codes.map { "\($0) \(Self.codeNames[$0] ?? "?")" }.joined(separator: ", ")
    }
}
