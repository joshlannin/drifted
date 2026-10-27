import Foundation

/// One framed message: `7B len ackCmd data… checksum`. See docs/protocol.md.
public struct Packet: Equatable, CustomStringConvertible {
    public static let frame: UInt8 = 0x7B
    static let ackBit: UInt8 = 0x80

    /// Command byte without the ack bit.
    public var command: UInt8
    public var ack: Bool
    /// Everything between the ackCmd byte and the checksum (usually starts with the action byte).
    public var data: [UInt8]

    public init(command: UInt8, data: [UInt8] = [], ack: Bool = false) {
        self.command = command & ~Self.ackBit
        self.data = data
        self.ack = ack
    }

    public var action: UInt8? { data.first }
    /// Arguments after the action byte.
    public var arguments: ArraySlice<UInt8> { data.dropFirst() }

    var ackCommand: UInt8 { ack ? command | Self.ackBit : command }

    public func encoded() -> [UInt8] {
        precondition(data.count <= 251, "packet too long")
        var bytes: [UInt8] = [Self.frame, UInt8(data.count + 4), ackCommand]
        bytes += data
        bytes.append(Self.checksum(bytes))
        return bytes
    }

    static func checksum<S: Sequence>(_ bytes: S) -> UInt8 where S.Element == UInt8 {
        bytes.reduce(0) { $0 &+ $1 }
    }

    public var description: String { encoded().hex }
}

extension Sequence where Element == UInt8 {
    public var hex: String { map { String(format: "%02x", $0) }.joined(separator: " ") }
}

/// Reassembles packets from the notification byte stream.
public struct PacketParser {
    private var buffer: [UInt8] = []
    public private(set) var droppedBytes = 0
    public private(set) var checksumFailures = 0

    public init() {}

    public mutating func feed<S: Sequence>(_ bytes: S) -> [Packet] where S.Element == UInt8 {
        buffer.append(contentsOf: bytes)
        var packets: [Packet] = []
        while true {
            if let start = buffer.firstIndex(of: Packet.frame), start > 0 {
                droppedBytes += start
                buffer.removeFirst(start)
            } else if buffer.first != Packet.frame {
                droppedBytes += buffer.count
                buffer.removeAll()
            }
            guard buffer.count >= 2 else { break }
            let length = Int(buffer[1])
            guard length >= 4 else {
                buffer.removeFirst()
                droppedBytes += 1
                continue
            }
            guard buffer.count >= length else { break }
            let raw = Array(buffer[0..<length])
            if let packet = Self.decode(raw) {
                buffer.removeFirst(length)
                packets.append(packet)
            } else {
                // Bad checksum: resync on the next frame byte, like a lost byte would require.
                checksumFailures += 1
                buffer.removeFirst()
                droppedBytes += 1
            }
        }
        return packets
    }

    static func decode(_ raw: [UInt8]) -> Packet? {
        let body = raw.dropLast()
        let checksum = raw[raw.count - 1]
        let ackCmd = raw[2]
        var stripped = Array(body)
        stripped[2] = ackCmd & ~Packet.ackBit
        // The app accepts the checksum computed with or without the ack bit.
        guard Packet.checksum(body) == checksum || Packet.checksum(stripped) == checksum else { return nil }
        return Packet(command: ackCmd, data: Array(raw[3..<(raw.count - 1)]), ack: ackCmd & Packet.ackBit != 0)
    }
}
