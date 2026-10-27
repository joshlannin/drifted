import Foundation

/// A point as sent to the table: `t = milli-degrees / 6` (0…59999), `r = rho·100000 / 2` (0…50000).
public struct WirePoint: Equatable, Hashable, Sendable {
    public var t: UInt16
    public var r: UInt16
    public init(t: UInt16, r: UInt16) { self.t = t; self.r = r }
}

/// Polar point: `theta` in radians (may be unwrapped), `rho` 0 (center) … 1 (edge).
public struct PolarPoint: Equatable, Codable, Sendable {
    public var theta: Double
    public var rho: Double
    public init(theta: Double, rho: Double) { self.theta = theta; self.rho = rho }

    public var x: Double { rho * cos(theta) }
    public var y: Double { rho * sin(theta) }

    public init(x: Double, y: Double) {
        self.init(theta: atan2(y, x), rho: min(1, (x * x + y * y).squareRoot()))
    }
}

public struct SandPattern: Equatable, Sendable {
    public var name: String
    public var points: [PolarPoint]

    public init(name: String, points: [PolarPoint]) {
        self.name = name
        self.points = points
    }

    // MARK: Wire / file formats

    public var wirePoints: [WirePoint] {
        points.map { p in
            var milli = Int((p.theta * 180 / .pi * 1000).rounded()) % 360_000
            if milli < 0 { milli += 360_000 }
            let rho = Int((max(0, min(1, p.rho)) * 100_000).rounded())
            // Same integer division the app applies (Point(int,int): theta/6, rho/2).
            return WirePoint(t: UInt16(milli / 6), r: UInt16(rho / 2))
        }
    }

    public var pageCount: Int { (points.count + Command.pointsPerPage - 1) / Command.pointsPerPage }

    /// HoMedics `.txt` (as bundled in the app): `milliDegrees,rho100k` per line.
    public init(driftText: String, name: String) {
        let pts = driftText.split(whereSeparator: \.isNewline).compactMap { line -> PolarPoint? in
            let parts = line.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, let t = Double(parts[0]), let r = Double(parts[1]) else { return nil }
            return PolarPoint(theta: t / 1000 * .pi / 180, rho: r / 100_000)
        }
        self.init(name: name, points: pts)
    }

    public var driftText: String {
        points.map { p -> String in
            var milli = Int((p.theta * 180 / .pi * 1000).rounded()) % 360_000
            if milli < 0 { milli += 360_000 }
            return "\(milli),\(Int((max(0, min(1, p.rho)) * 100_000).rounded()))"
        }.joined(separator: "\n") + "\n"
    }

    /// Sisyphus / Dune Weaver `.thr`: `theta(rad) rho(0…1)` per line, `#` comments.
    /// Those tables interpolate linearly in (theta, rho), so we densify in polar space.
    public init(thr: String, name: String, maxStep: Double = 0.01) {
        let raw = thr.split(whereSeparator: \.isNewline).compactMap { line -> PolarPoint? in
            let s = line.trimmingCharacters(in: .whitespaces)
            guard !s.isEmpty, !s.hasPrefix("#") else { return nil }
            let parts = s.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "," })
            guard parts.count >= 2, let t = Double(parts[0]), let r = Double(parts[1]) else { return nil }
            return PolarPoint(theta: t, rho: r)
        }
        self.init(name: name, points: Self.densifyPolar(raw, maxStep: maxStep))
    }

    public static func load(url: URL) throws -> SandPattern {
        let text = try String(contentsOf: url, encoding: .utf8)
        let name = url.deletingPathExtension().lastPathComponent
        switch url.pathExtension.lowercased() {
        case "thr": return SandPattern(thr: text, name: name)
        default: return SandPattern(driftText: text, name: name)
        }
    }

    // MARK: Geometry

    /// Builds a pattern from cartesian strokes in the unit disc (x right, y up, |p| ≤ 1).
    /// Strokes are joined end-to-start (the ball can't lift) and resampled to ≤ `maxStep`.
    public static func fromStrokes(_ strokes: [[(x: Double, y: Double)]], name: String, maxStep: Double = 0.01) -> SandPattern {
        let path = strokes.flatMap { $0 }.map { p -> (x: Double, y: Double) in
            let d = (p.x * p.x + p.y * p.y).squareRoot()
            return d > 1 ? (p.x / d, p.y / d) : p
        }
        return SandPattern(name: name, points: unwrapped(densifyCartesian(path, maxStep: maxStep).map { PolarPoint(x: $0.x, y: $0.y) }))
    }

    /// Makes theta continuous: atan2 jumps by 2π where a path crosses the −x axis, which would otherwise
    /// read as a full turn (a client's "SL" drawing grew an extra loop this way, 2026-10-25).
    public static func unwrapped(_ pts: [PolarPoint]) -> [PolarPoint] {
        guard var prev = pts.first?.theta else { return pts }
        return pts.map { p in
            var t = p.theta
            while t - prev > .pi { t -= 2 * .pi }
            while t - prev < -.pi { t += 2 * .pi }
            prev = t
            return PolarPoint(theta: t, rho: p.rho)
        }
    }

    static func densifyCartesian(_ path: [(x: Double, y: Double)], maxStep: Double) -> [(x: Double, y: Double)] {
        guard var prev = path.first else { return [] }
        var out = [prev]
        for p in path.dropFirst() {
            let d = hypot(p.x - prev.x, p.y - prev.y)
            guard d > 1e-9 else { continue }
            let n = Int((d / maxStep).rounded(.up))
            for i in 1...n {
                let f = Double(i) / Double(n)
                out.append((prev.x + (p.x - prev.x) * f, prev.y + (p.y - prev.y) * f))
            }
            prev = p
        }
        return out
    }

    static func densifyPolar(_ pts: [PolarPoint], maxStep: Double) -> [PolarPoint] {
        guard var prev = pts.first else { return [] }
        var out = [prev]
        for p in pts.dropFirst() {
            // Arc-length estimate of a linear (theta, rho) segment.
            let d = hypot(p.rho - prev.rho, (p.theta - prev.theta) * max(p.rho, prev.rho))
            let n = max(1, Int((d / maxStep).rounded(.up)))
            for i in 1...n {
                let f = Double(i) / Double(n)
                out.append(PolarPoint(theta: prev.theta + (p.theta - prev.theta) * f, rho: prev.rho + (p.rho - prev.rho) * f))
            }
            prev = p
        }
        return out
    }

    /// Total travel length in table radii.
    public var length: Double {
        zip(points, points.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
    }

    public func appending(_ other: SandPattern) -> SandPattern {
        SandPattern(name: name, points: points + other.points)
    }

    public func rotated(by radians: Double) -> SandPattern {
        SandPattern(name: name, points: points.map { PolarPoint(theta: $0.theta + radians, rho: $0.rho) })
    }
}

// MARK: Generators

public enum Generators {
    /// Archimedean spiral; `turns` revolutions between rho 0 and 1. Good as a "wipe".
    public static func spiral(turns: Double = 40, outward: Bool = false) -> SandPattern {
        let pts = sampled(maxT: turns * 2 * .pi) { t in (t, t / (turns * 2 * .pi)) }
        return SandPattern(name: "Spiral", points: outward ? pts : pts.reversed())
    }

    /// Rose curve r = |cos(k·θ)|, optionally precessing a little each lobe.
    public static func rose(petals k: Double = 5, loops: Double = 1, precession: Double = 0) -> SandPattern {
        let maxT = loops * 2 * .pi
        let pts = sampled(maxT: maxT) { t in (t + precession * t, abs(cos(k * t))) }
        return SandPattern(name: "Rose \(Int(k))", points: pts)
    }

    /// Hypotrochoid (spirograph), normalised to fill the disc.
    public static func spirograph(R: Double = 5, r: Double = 3, d: Double = 4, loops: Double = 3) -> SandPattern {
        let scale = 1 / (abs(R - r) + d)
        var cart: [(x: Double, y: Double)] = []
        let steps = Int(loops * 4000)
        for i in 0...steps {
            let t = Double(i) / Double(steps) * loops * 2 * .pi
            cart.append(((R - r) * cos(t) + d * cos((R - r) / r * t), (R - r) * sin(t) - d * sin((R - r) / r * t)))
        }
        return SandPattern.fromStrokes([cart.map { ($0.x * scale, $0.y * scale) }], name: "Spirograph")
    }

    /// Samples a polar curve (theta(t), rho(t)) adaptively so steps stay ≤ maxStep.
    static func sampled(maxT: Double, maxStep: Double = 0.01, _ f: (Double) -> (Double, Double)) -> [PolarPoint] {
        var out: [PolarPoint] = []
        var t = 0.0
        var dt = 0.001
        let first = f(0)
        out.append(PolarPoint(theta: first.0, rho: first.1))
        while t < maxT {
            var next = min(maxT, t + dt)
            var (th, rh) = f(next)
            var p = PolarPoint(theta: th, rho: rh)
            // Shrink the step until the chord is short enough, then grow again.
            while hypot(p.x - out[out.count - 1].x, p.y - out[out.count - 1].y) > maxStep, next - t > 1e-7 {
                dt /= 2
                next = t + dt
                (th, rh) = f(next)
                p = PolarPoint(theta: th, rho: rh)
            }
            out.append(p)
            t = next
            dt *= 1.5
        }
        return out
    }
}
