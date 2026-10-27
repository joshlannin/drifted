import Foundation

/// "Clear first": a spiral sweep that smooths the sand before a drawing, so the drawing reads cleanly.
public enum Clearing {
    public enum Mode: String, Codable, Sendable {
        case none, area, full
    }

    /// Groove spacing between spiral turns, in table radii. The ball is about 0.07 radii across
    /// (16" table); a little less than that leaves no ridges between turns.
    public static var spacing = 0.05

    /// Returns `pattern` with a clearing spiral in front of it.
    /// `.area` clears a disc just covering the drawing; `.full` clears the whole table.
    /// The spiral is rotated so it ends next to the drawing's first point: outward (ending on the rim
    /// of the cleared disc) when the drawing starts in the outer half, inward (ending at the centre) otherwise.
    public static func prepend(_ mode: Mode, to pattern: SandPattern) -> SandPattern {
        guard mode != .none, let start = pattern.points.first else { return pattern }
        let maxRho = pattern.points.map(\.rho).max() ?? 1
        let radius = mode == .full ? 1.0 : min(1, maxRho + 0.08)
        let outward = start.rho > radius / 2
        let spiral = sweep(radius: radius, endTheta: start.theta, outward: outward)
        let joined = SandPattern.unwrapped(spiral + connector(from: spiral.last!, to: start) + pattern.points)
        return SandPattern(name: pattern.name, points: joined)
    }

    /// Archimedean spiral between rho 0 and `radius`, sampled every ~0.02 radii, ending at `endTheta`.
    static func sweep(radius: Double, endTheta: Double, outward: Bool) -> [PolarPoint] {
        let turns = max(1, (radius / spacing).rounded(.up))
        let totalTheta = turns * 2 * .pi
        var pts: [PolarPoint] = []
        var t = 0.0
        while t < totalTheta {
            let rho = radius * t / totalTheta
            pts.append(PolarPoint(theta: t, rho: rho))
            t += min(0.4, 0.02 / max(rho, 0.02))   // ~0.02 radii of arc per step, capped near the centre
        }
        pts.append(PolarPoint(theta: totalTheta, rho: radius))
        if !outward { pts = pts.reversed() }
        // Rotate so the end point lands on endTheta.
        let shift = endTheta - pts.last!.theta
        return pts.map { PolarPoint(theta: $0.theta + shift, rho: $0.rho) }
    }

    /// Straight line (in table space) from `a` to `b`, excluding both ends.
    static func connector(from a: PolarPoint, to b: PolarPoint) -> [PolarPoint] {
        let d = hypot(a.x - b.x, a.y - b.y)
        let n = Int(d / 0.02)
        guard n >= 2 else { return [] }
        return (1..<n).map { i in
            let f = Double(i) / Double(n)
            return PolarPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)
        }
    }
}
