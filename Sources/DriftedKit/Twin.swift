import Foundation

/// Digital twin of a gen-1 Bluetooth Drift: what the ball does with a pattern, when, and what it leaves in the sand.
///
/// Modelled (from measurements on a 16" table, docs/behaviour.md): the unit-disc geometry; the table's move
/// between consecutive points, which interpolates theta and rho together (so a long step traces an arc, not a
/// chord); the single interpolated move from the ball's position to the pattern's first point; constant linear
/// speed (`DrawTime.radiiPerSecond`); and a groove as wide as the ball.
///
/// Not modelled: sand physics (groove depth, ridges, how well a new groove erases an old one), whatever is
/// already in the sand unless a clear is prepended, and where theta zero points relative to the table's front.
public enum TableTwin {
    /// Ball diameter in table radii; also the width of the groove it leaves.
    public static var ballDiameter = 0.07

    public struct Sample: Sendable {
        public var t: Double          // seconds from the start of the move
        public var x: Double
        public var y: Double
        public var drawing: Bool      // false while moving to the first point
    }

    public struct Run: Sendable {
        public var samples: [Sample]
        public var transitSeconds: Double
        public var drawSeconds: Double
        public var totalSeconds: Double { transitSeconds + drawSeconds }
    }

    /// The ball's path in time order, sampled about every `step` table radii. `from` is where the ball sits
    /// before the pattern starts (unknown: pass nil and the move to the start is left out).
    public static func simulate(_ pattern: SandPattern, from start: PolarPoint? = nil, step: Double = 0.004) -> Run {
        var samples: [Sample] = []
        var t = 0.0
        var last: (x: Double, y: Double)?

        func move(_ a: PolarPoint, _ b: PolarPoint, drawing: Bool) {
            // The table drives theta and rho together, taking the short way round for small steps.
            var dt = (b.theta - a.theta).truncatingRemainder(dividingBy: 2 * .pi)
            if dt > .pi { dt -= 2 * .pi } else if dt < -.pi { dt += 2 * .pi }
            let dr = b.rho - a.rho
            let approx = abs(dr) + abs(dt) * max(a.rho, b.rho)
            let n = max(1, Int((approx / step).rounded(.up)))
            for i in 1...n {
                let f = Double(i) / Double(n)
                let p = PolarPoint(theta: a.theta + dt * f, rho: a.rho + dr * f)
                if let l = last { t += hypot(p.x - l.x, p.y - l.y) / DrawTime.radiiPerSecond }
                last = (p.x, p.y)
                samples.append(Sample(t: t, x: p.x, y: p.y, drawing: drawing))
            }
        }

        guard let first = pattern.points.first else { return Run(samples: [], transitSeconds: 0, drawSeconds: 0) }
        if let start {
            last = (start.x, start.y)
            samples.append(Sample(t: 0, x: start.x, y: start.y, drawing: false))
            move(start, first, drawing: false)
        } else {
            last = (first.x, first.y)
            samples.append(Sample(t: 0, x: first.x, y: first.y, drawing: true))
        }
        let transit = t
        var prev = first
        for p in pattern.points.dropFirst() { move(prev, p, drawing: true); prev = p }
        return Run(samples: samples, transitSeconds: transit, drawSeconds: t - transit)
    }
}
