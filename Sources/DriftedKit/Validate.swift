import CryptoKit
import Foundation

/// Safety checks for a drawing before it goes to the table. `validate` repairs what it safely can
/// (clamping, densifying) and reports everything else; callers send `report.pattern`, never the input.
public enum PatternValidator {
    public struct Issue: Codable, Equatable, Sendable {
        public enum Severity: String, Codable, Sendable { case error, fixed, warning }
        public var severity: Severity
        public var message: String
    }

    public struct Report: Sendable {
        public var pattern: SandPattern
        public var issues: [Issue]
        public var stats: Stats
        public var ok: Bool { !issues.contains { $0.severity == .error } }
    }

    public struct Stats: Codable, Equatable, Sendable {
        public var points: Int
        public var pages: Int
        public var length: Double            // path length in table radii
        public var estimatedSeconds: Double  // drawing time at the reference speed, excluding the move to the start
        public var start: [Double]           // [theta, rho]
        public var end: [Double]
    }

    /// Largest theta step we let through. The table unwraps theta only across 314°→46°, so a bigger
    /// jump that crosses 0° is taken the long way round (docs/failure-modes.md).
    public static let maxThetaStep = 0.5          // radians (~29°)
    /// Table-side limits: u16 page index, and a sanity cap well below it.
    public static let maxPoints = 200_000

    public static func validate(_ input: SandPattern) -> Report {
        var issues: [Issue] = []
        var pts = input.points

        if pts.contains(where: { !$0.theta.isFinite || !$0.rho.isFinite }) {
            pts.removeAll { !$0.theta.isFinite || !$0.rho.isFinite }
            issues.append(Issue(severity: .fixed, message: "removed points with NaN or infinite coordinates"))
        }
        let outOfRange = pts.filter { $0.rho < 0 || $0.rho > 1 }.count
        if outOfRange > 0 {
            pts = pts.map { PolarPoint(theta: $0.theta, rho: min(1, max(0, $0.rho))) }
            issues.append(Issue(severity: .fixed, message: "clamped \(outOfRange) point(s) with rho outside 0…1"))
        }
        var deduped: [PolarPoint] = []
        for p in pts where deduped.last != p { deduped.append(p) }
        pts = deduped

        var dense: [PolarPoint] = []
        var split = 0
        for p in pts {
            if let prev = dense.last {
                let steps = Int((abs(p.theta - prev.theta) / maxThetaStep).rounded(.up))
                if steps > 1 {
                    split += 1
                    for i in 1..<steps {
                        let f = Double(i) / Double(steps)
                        dense.append(PolarPoint(theta: prev.theta + (p.theta - prev.theta) * f,
                                                rho: prev.rho + (p.rho - prev.rho) * f))
                    }
                }
            }
            dense.append(p)
        }
        if split > 0 {
            issues.append(Issue(severity: .fixed, message: "split \(split) step(s) larger than \(Int(maxThetaStep * 180 / .pi))° of theta"))
        }
        pts = dense

        if pts.count < 2 { issues.append(Issue(severity: .error, message: "needs at least 2 points")) }
        if pts.count > maxPoints { issues.append(Issue(severity: .error, message: "\(pts.count) points is over the \(maxPoints) limit")) }

        let pattern = SandPattern(name: input.name, points: pts)
        let length = pattern.length
        let stats = Stats(points: pts.count, pages: pattern.pageCount, length: length,
                          estimatedSeconds: DrawTime.estimate(length: length),
                          start: pts.first.map { [$0.theta, $0.rho] } ?? [], end: pts.last.map { [$0.theta, $0.rho] } ?? [])
        if stats.estimatedSeconds > 4 * 3600 {
            issues.append(Issue(severity: .warning, message: "estimated draw time is over 4 hours"))
        }
        return Report(pattern: pattern, issues: issues, stats: stats)
    }

    /// Stable content hash of what the table would store (wire points), for slot reuse.
    public static func contentHash(_ pattern: SandPattern) -> String {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(pattern.points.count * 4)
        for w in pattern.wirePoints { bytes += [UInt8(w.t & 0xFF), UInt8(w.t >> 8), UInt8(w.r & 0xFF), UInt8(w.r >> 8)] }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined().prefix(16).lowercased()
    }
}

/// Drawing-time model. Speed setting 75 on a 16" table measured about 0.115 table radii per second
/// (spiral chunks and precessing-rose segments, 2026-10-25); the table drives roughly constant
/// linear speed beyond 15 mm, so path length is the right input.
public enum DrawTime {
    public static var radiiPerSecond = 0.115

    public static func estimate(length: Double) -> Double { length / radiiPerSecond }

    /// Rough time for the table's own move from `from` to `to` (one interpolated (theta, rho) move).
    public static func transit(from: PolarPoint, to: PolarPoint) -> Double {
        let steps = 64
        let path = (0...steps).map { i -> PolarPoint in
            let f = Double(i) / Double(steps)
            return PolarPoint(theta: from.theta + (to.theta - from.theta) * f, rho: from.rho + (to.rho - from.rho) * f)
        }
        return SandPattern(name: "", points: path).length / radiiPerSecond
    }
}
