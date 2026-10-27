import CoreBluetooth
import Foundation

public enum DriftError: LocalizedError {
    case bluetoothUnavailable(String)
    case notConnected
    case timeout(String)
    case uploadFailed(String)
    case noStorage

    public var errorDescription: String? {
        switch self {
        case .bluetoothUnavailable(let s): return "Bluetooth unavailable: \(s)"
        case .notConnected: return "Not connected to a table"
        case .timeout(let s): return "Timed out waiting for \(s)"
        case .uploadFailed(let s): return "Upload failed: \(s)"
        case .noStorage: return "Table reports not enough storage space"
        }
    }
}

/// CoreBluetooth client for a HoMedics Drift table. All state lives on the main actor;
/// CoreBluetooth is created on the main queue so delegate callbacks arrive there too.
@MainActor
public final class DriftTable: NSObject, ObservableObject {
    public static let serviceUUID = CBUUID(string: "FFE0")
    public static let writeUUID = CBUUID(string: "FFE9")
    public static let notifyUUID = CBUUID(string: "FFE4")

    public enum Status: Equatable {
        case starting, bluetoothOff, idle, scanning, connecting, handshaking, ready
        case disconnected(String?)
    }

    public struct Discovered: Identifiable, Equatable {
        public let id: UUID
        public let name: String
        public let rssi: Int
    }

    public struct LogLine: Identifiable {
        public let id = UUID()
        public let date = Date()
        public let text: String
    }

    @Published public private(set) var status: Status = .starting
    @Published public private(set) var discovered: [Discovered] = []
    @Published public private(set) var tableState: TableState?
    /// Most recent 0x37 alarm (the table repeats fatal ones about every second).
    @Published public private(set) var lastAlarm: TableAlarm?
    @Published public private(set) var storedPatternIds: Set<UInt16> = []
    @Published public private(set) var log: [LogLine] = []
    @Published public private(set) var connectedName: String?

    /// Show every BLE device while scanning, not just ones that look like a Drift.
    public var scanAll = false
    /// Mirror log lines somewhere else (the CLI prints them).
    public var logHandler: ((String) -> Void)?
    /// Log raw packets in both directions.
    public var logPackets = true

    private var central: CBCentralManager!
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var parser = PacketParser()

    private var poweredOnWaiters: [CheckedContinuation<Void, Error>] = []
    private var readyToWriteWaiters: [CheckedContinuation<Void, Never>] = []
    private var writeResponseWaiters: [CheckedContinuation<Void, Error>] = []
    private var writeTail: Task<Void, Never> = Task {}

    private var messageSeq = 0
    private var recent: [(seq: Int, message: TableMessage)] = []
    private var waiters: [Int: (match: (TableMessage) -> Any?, cont: CheckedContinuation<Any, Error>)] = [:]
    private var nextWaiterId = 0

    public override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: Logging

    func note(_ text: String) {
        log.append(LogLine(text: text))
        if log.count > 2000 { log.removeFirst(log.count - 2000) }
        logHandler?(text)
    }

    // MARK: Scanning / connection

    public func waitForPoweredOn() async throws {
        switch central.state {
        case .poweredOn: return
        case .unauthorized: throw DriftError.bluetoothUnavailable("permission denied")
        case .unsupported: throw DriftError.bluetoothUnavailable("unsupported")
        default: try await withCheckedThrowingContinuation { poweredOnWaiters.append($0) }
        }
    }

    public func startScan() {
        guard central.state == .poweredOn else { return }
        discovered = []
        status = .scanning
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        note("Scanning…")
    }

    public func stopScan() {
        central.stopScan()
        if status == .scanning { status = .idle }
    }

    public func connect(_ id: UUID) {
        guard let p = peripherals[id] ?? central.retrievePeripherals(withIdentifiers: [id]).first else {
            note("Unknown device \(id)")
            return
        }
        central.stopScan()
        peripheral = p
        peripherals[id] = p
        p.delegate = self
        status = .connecting
        connectedName = p.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        note("Connecting to \(p.name ?? id.uuidString)…")
        central.connect(p)
    }

    public func disconnect() {
        if let p = peripheral { central.cancelPeripheralConnection(p) }
    }

    /// Waits for the table's init dump to finish (0x4F/1). Returns false on timeout.
    @discardableResult
    public func waitUntilReady(timeout: TimeInterval = 60) async -> Bool {
        if status == .ready { return true }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if status == .ready { return true }
            if case .disconnected = status { return false }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return status == .ready
    }

    // MARK: Sending

    /// Sends one packet. Writes are serialised so concurrent auto-acks never interleave with pages.
    public func send(_ packet: Packet) async throws {
        let previous = writeTail
        let task = Task { @MainActor in
            _ = await previous.value
            try await self.write(packet)
        }
        writeTail = Task { _ = try? await task.value }
        try await task.value
    }

    private func write(_ packet: Packet) async throws {
        guard let p = peripheral, p.state == .connected, let c = writeChar else { throw DriftError.notConnected }
        let bytes = packet.encoded()
        if logPackets { note("> \(bytes.hex)") }
        let type: CBCharacteristicWriteType = c.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        let maxLen = max(20, p.maximumWriteValueLength(for: type))
        var offset = 0
        while offset < bytes.count {
            let chunk = Data(bytes[offset..<min(bytes.count, offset + maxLen)])
            offset += chunk.count
            if type == .withoutResponse {
                while !p.canSendWriteWithoutResponse {
                    await withCheckedContinuation { readyToWriteWaiters.append($0) }
                }
                p.writeValue(chunk, for: c, type: .withoutResponse)
            } else {
                try await withCheckedThrowingContinuation { cont in
                    writeResponseWaiters.append(cont)
                    p.writeValue(chunk, for: c, type: .withResponse)
                }
            }
        }
    }

    // MARK: Receiving

    /// Marker for `waitFor(after:)`, so a reply that arrives before we start waiting isn't missed.
    public func mark() -> Int { messageSeq }

    public func waitFor<T>(after mark: Int, timeout: TimeInterval, what: String,
                           _ match: @escaping (TableMessage) -> T?) async throws -> T {
        for entry in recent where entry.seq > mark {
            if let hit = match(entry.message) { return hit }
        }
        let id = nextWaiterId
        nextWaiterId += 1
        let value = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Any, Error>) in
            waiters[id] = ({ match($0) }, cont)
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                MainActor.assumeIsolated {
                    if let w = self?.waiters.removeValue(forKey: id) { w.cont.resume(throwing: DriftError.timeout(what)) }
                }
            }
        }
        return value as! T
    }

    private func handle(_ packet: Packet) {
        if logPackets { note("< \(packet.encoded().hex)") }
        let message = TableMessage(packet)
        messageSeq += 1
        recent.append((messageSeq, message))
        if recent.count > 256 { recent.removeFirst(recent.count - 256) }

        switch message {
        case .waitingForConnection:
            status = .handshaking
            note("Table is waiting for connection confirm")
        case .initComplete:
            status = .ready
            note("Table init data complete — ready")
        case .state(let s):
            tableState = s
        case .storedPatterns(_, let ids):
            storedPatternIds.formUnion(ids)
        case .other(let p) where p.command == 0x33 && p.action == 1:
            storedPatternIds = []
        case .alarm(let kind, let codes):
            let alarm = TableAlarm(kind: kind, codes: codes, at: Date())
            if lastAlarm.map({ $0.kind != kind || $0.codes != codes || alarm.at.timeIntervalSince($0.at) > 30 }) ?? true {
                note("Table \(alarm)")
            }
            lastAlarm = alarm
        default: break
        }

        for (id, w) in waiters {
            if let hit = w.match(message) {
                waiters.removeValue(forKey: id)
                w.cont.resume(returning: hit)
            }
        }

        // Ack-bit packets are the table acknowledging *our* command (e.g. `b2 02` after we send the
        // time). Replying to them in kind makes an endless time-request loop, and ignoring them makes
        // the table resend 4× and restart the handshake (both observed on hardware).
        if packet.ack {
            if message != .confirm { Task { try? await self.send(Command.confirmData) } }
        } else if let reply = message.reply {
            Task { try? await self.send(reply) }
        }
    }

    // MARK: High level

    public func play(_ id: UInt16) async throws { try await send(Command.drawPattern(id)) }

    /// Picks an unused id (≥ 50000 unless told otherwise), avoiding ids the table reported.
    public func freePatternId(startingAt start: UInt16 = 50000) -> UInt16 {
        var id = start
        while storedPatternIds.contains(id), id < .max { id += 1 }
        return id
    }

    /// Uploads a pattern (sequence and recovery rules: docs/protocol.md, docs/failure-modes.md).
    /// Pages go 100 ms apart: at 1 ms the table drops its session after End and restarts the handshake.
    public func upload(_ points: [WirePoint], id: UInt16, pageDelay: TimeInterval = 0.1,
                       progress: @escaping (Double) -> Void = { _ in }) async throws {
        if !(await waitUntilReady(timeout: 60)) {
            note("Warning: table never reported init complete; trying anyway")
        }
        let per = Command.pointsPerPage
        let pages = stride(from: 0, to: points.count, by: per).map { points[$0..<min(points.count, $0 + per)] }
        guard !pages.isEmpty else { throw DriftError.uploadFailed("pattern is empty") }
        note("Uploading pattern \(id): \(points.count) points, \(pages.count) pages")

        let start = mark()
        func failure(_ m: TableMessage) -> Error? {
            switch m {
            case .uploadFailed(let x) where x == id: return DriftError.uploadFailed("table rejected pattern \(id)")
            case .noStorage(let x) where x == id: return DriftError.noStorage
            default: return nil
            }
        }

        // The table occasionally ignores a Start sent right after another upload (seen on hardware,
        // 5th upload in a row), so resend it a few times before giving up.
        for attempt in 1...3 {
            let startMark = attempt == 1 ? start : mark()
            try await send(Command.startUpload(patternId: id, pageCount: pages.count))
            do {
                let started: Error? = try await waitFor(after: startMark, timeout: 4, what: "upload start") { m -> Error?? in
                    if case .uploadStarted(let x) = m, x == id { return .some(nil) }
                    return failure(m).map { .some($0) }
                }
                if let started { throw started }
                break
            } catch DriftError.timeout where attempt < 3 {
                note("No upload start for \(id), resending Start (attempt \(attempt + 1))")
            }
        }

        var pending = Array(pages.indices)
        var delay = pageDelay
        var sent = 0
        let total = Double(pages.count)
        for attempt in 1...6 {
            for i in pending {
                for entry in recent where entry.seq > start { if let e = failure(entry.message) { throw e } }
                try await send(Command.page(index: i + 1, points: pages[i]))
                sent += 1
                progress(min(0.99, Double(sent) / total))
                if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1e9)) }
            }
            try await Task.sleep(nanoseconds: 100_000_000)
            let endMark = mark()
            try await send(Command.endUpload(patternId: id, pageCount: pages.count))
            // nil = complete. Only 0x34/3 means stored: if the *last* page(s) were dropped, the table
            // answers 0x34/1 with an empty list and deletes the file 5 s later (docs/failure-modes.md).
            // Treating that empty list as success left unplayable "stored" ids.
            let result: Result<[Int]?, Error> = try await waitFor(after: endMark, timeout: 15, what: "upload completion") { m in
                switch m {
                case .uploadComplete(let x) where x == id: return .success(nil)
                case .uploadMissingPages(let missing): return .success(missing)
                default: return failure(m).map { .failure($0) }
                }
            }
            guard let missing = try result.get() else {
                progress(1)
                note("Pattern \(id) stored on table")
                return
            }
            if missing.isEmpty {
                // Trailing pages lost; we don't know how many, so resend a growing tail.
                let tail = min(pages.count, 3 * attempt)
                note("Table lost the last page(s), resending last \(tail) (attempt \(attempt))")
                pending = Array(pages.indices.suffix(tail))
            } else {
                note("Table missing \(missing.count) page(s), resending (attempt \(attempt))")
                pending = missing.map { $0 - 1 }.filter { pages.indices.contains($0) }
            }
            delay = 0.2
        }
        throw DriftError.uploadFailed("pages still missing after retries")
    }
}

// MARK: - CoreBluetooth delegates

extension DriftTable: CBCentralManagerDelegate, CBPeripheralDelegate {
    nonisolated public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            switch central.state {
            case .poweredOn:
                if status == .starting || status == .bluetoothOff { status = .idle }
                poweredOnWaiters.forEach { $0.resume() }
                poweredOnWaiters = []
            case .unauthorized:
                status = .bluetoothOff
                poweredOnWaiters.forEach { $0.resume(throwing: DriftError.bluetoothUnavailable("permission denied")) }
                poweredOnWaiters = []
            default:
                status = .bluetoothOff
            }
        }
    }

    nonisolated public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                           advertisementData: [String: Any], rssi RSSI: NSNumber) {
        MainActor.assumeIsolated {
            let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""
            let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
            let looksLikeDrift = name.trimmingCharacters(in: .whitespaces).hasPrefix("KS") || services.contains(Self.serviceUUID)
            guard scanAll || looksLikeDrift else { return }
            peripherals[peripheral.identifier] = peripheral
            let entry = Discovered(id: peripheral.identifier, name: name.isEmpty ? "(unnamed)" : name, rssi: RSSI.intValue)
            if let i = discovered.firstIndex(where: { $0.id == entry.id }) {
                discovered[i] = entry
            } else {
                discovered.append(entry)
                note("Found \(entry.name) [\(entry.id.uuidString)] rssi \(entry.rssi)")
            }
        }
    }

    nonisolated public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            note("Connected; discovering services")
            peripheral.discoverServices([Self.serviceUUID])
        }
    }

    nonisolated public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            status = .disconnected(error?.localizedDescription)
            note("Failed to connect: \(error?.localizedDescription ?? "unknown")")
        }
    }

    nonisolated public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            status = .disconnected(error?.localizedDescription)
            writeChar = nil
            parser = PacketParser()
            note("Disconnected\(error.map { ": \($0.localizedDescription)" } ?? "")")
            for (_, w) in waiters { w.cont.resume(throwing: DriftError.notConnected) }
            waiters = [:]
            writeResponseWaiters.forEach { $0.resume(throwing: DriftError.notConnected) }
            writeResponseWaiters = []
            readyToWriteWaiters.forEach { $0.resume() }
            readyToWriteWaiters = []
        }
    }

    nonisolated public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
                note("Drift service FFE0 not found")
                central.cancelPeripheralConnection(peripheral)
                return
            }
            peripheral.discoverCharacteristics([Self.writeUUID, Self.notifyUUID], for: service)
        }
    }

    nonisolated public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated {
            for c in service.characteristics ?? [] {
                if c.uuid == Self.writeUUID { writeChar = c }
                if c.uuid == Self.notifyUUID { peripheral.setNotifyValue(true, for: c) }
            }
            if writeChar == nil { note("Write characteristic FFE9 not found") }
        }
    }

    nonisolated public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            if let error {
                note("Notify failed: \(error.localizedDescription)")
                return
            }
            status = .handshaking
            let maxLen = peripheral.maximumWriteValueLength(for: .withoutResponse)
            note("Subscribed; max write \(maxLen) bytes. Waiting for table handshake…")
        }
    }

    nonisolated public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            guard let data = characteristic.value else { return }
            for packet in parser.feed(data) { handle(packet) }
        }
    }

    nonisolated public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            guard !writeResponseWaiters.isEmpty else { return }
            let w = writeResponseWaiters.removeFirst()
            if let error { w.resume(throwing: error) } else { w.resume() }
        }
    }

    nonisolated public func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            let ws = readyToWriteWaiters
            readyToWriteWaiters = []
            ws.forEach { $0.resume() }
        }
    }
}
