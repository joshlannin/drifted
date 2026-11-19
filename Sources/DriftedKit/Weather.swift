import Foundation

/// The weather picture from designs/weather.py, ported line for line so it draws the same path: an emblem for
/// the day's conditions under the forecast high in big digits. See weather.py for how the picture is built
/// (shapes swept smooth and outlined, background rows flowing round them, then the temperature panel).
/// partlycloudy, fog, heavyRain, thunderstorm, sleet, hail and clearNight are from afcragg78's Home
/// Assistant integration (https://github.com/afcragg78/ha-homedics-drift), MIT licensed.
///
/// Arithmetic follows the Python (its float `%`, `round`, `int` and `sum`), so the points match it to
/// rounding error. If you change one, change both.
public enum WeatherPicture {
    public enum Condition: String, CaseIterable, Codable, Sendable {
        case sunny, partlycloudy, cloudy, fog, rain
        case heavyRain = "heavy_rain"
        case thunderstorm, sleet, hail, snow
        case clearNight = "clear_night"

        /// From WeatherKit's `WeatherCondition.rawValue`. Unknown values give cloudy.
        public init(weatherKit raw: String) {
            switch raw {
            case "clear", "mostlyClear", "hot", "frigid": self = .sunny
            case "partlyCloudy": self = .partlycloudy
            case "mostlyCloudy", "cloudy", "breezy", "windy": self = .cloudy
            case "foggy", "haze", "smoky", "blowingDust": self = .fog
            case "drizzle", "rain", "sunShowers": self = .rain
            case "heavyRain": self = .heavyRain
            case "isolatedThunderstorms", "scatteredThunderstorms", "thunderstorms", "strongStorms",
                 "tropicalStorm", "hurricane": self = .thunderstorm
            case "sleet", "freezingRain", "freezingDrizzle", "wintryMix": self = .sleet
            case "hail": self = .hail
            case "snow", "heavySnow", "blizzard", "blowingSnow", "flurries", "sunFlurries": self = .snow
            default: self = .cloudy
            }
        }

        /// From a WMO weather code (Open-Meteo's `weather_code`). Unknown codes give cloudy.
        public init(wmo code: Int) {
            switch code {
            case 0, 1: self = .sunny
            case 2: self = .partlycloudy
            case 45, 48: self = .fog
            case 51, 53, 55, 61, 63, 80, 81: self = .rain
            case 65, 82: self = .heavyRain
            case 56, 57, 66, 67: self = .sleet
            case 71, 73, 75, 77, 85, 86: self = .snow
            case 95, 96, 99: self = .thunderstorm
            default: self = .cloudy
            }
        }
    }

    /// The full picture: `weather.py CONDITION TEMPERATURE`. Points in table radii (x right, y up), unrotated.
    public static func path(_ condition: Condition, temperature: Int) -> [(x: Double, y: Double)] {
        densify(build(condition, clampTemperature(temperature)).0).map { ($0.x, $0.y) }
    }

    /// Just the temperature panel: `weather.py --update TEMPERATURE`.
    public static func temperaturePath(_ temperature: Int) -> [(x: Double, y: Double)] {
        densify(panel(clampTemperature(temperature)).0).map { ($0.x, $0.y) }
    }

    /// The picture as a drawing, named like weather.py names it (weather-CONDITION-TEMPERATURE).
    public static func pattern(_ condition: Condition, temperature: Int) -> SandPattern {
        let t = clampTemperature(temperature)
        return SandPattern.fromStrokes([path(condition, temperature: t)], name: "weather-\(condition.rawValue)-\(t)")
    }

    /// Digit height for a temperature (0.45 for one or two digits, less for three).
    public static func digitHeight(_ temperature: Int) -> Double { temperatureStrokes(clampTemperature(temperature)).1 }

    public static func clampTemperature(_ t: Int) -> Int { min(199, max(-99, t)) }
}

// MARK: - The port

private let STEP = 0.01
private let RIM = 0.96
private let BALL = 0.07
private let SWEEP = 0.05
private let SHAPE_SWEEP = 0.04
private let PANEL_Y = 0.12
private let PANEL_RIM = 0.92
private let TEXT_RIM = 0.88
private let BASELINE = PANEL_Y + 0.08
private let CAP = 0.45
private let BOLD = 0.03
private let GAP = 0.19
private let BAND_SWEEP = 0.035
private let DEGREE = 0.065
private let MINUS = 0.4
private let TAU = 2 * Double.pi

private struct V { var x: Double; var y: Double; init(_ x: Double, _ y: Double) { self.x = x; self.y = y } }

/// Python's float `%`: the result takes the sign of `b`.
private func pymod(_ a: Double, _ b: Double) -> Double {
    var m = fmod(a, b)
    if m != 0, (b < 0) != (m < 0) { m += b }
    return m
}

/// Python's `int % int` (non-negative for positive b).
private func imod(_ a: Int, _ b: Int) -> Int { ((a % b) + b) % b }

/// Python 3.12+ `sum()` of floats (Neumaier compensated summation).
private func pysum<S: Sequence>(_ xs: S) -> Double where S.Element == Double {
    var f = 0.0, c = 0.0
    for x in xs {
        let t = f + x
        if abs(f) >= abs(x) { c += (f - t) + x } else { c += (x - t) + f }
        f = t
    }
    return c != 0 && c.isFinite ? f + c : f
}

/// Python's `round()` to an int: halves go to the even neighbour.
private func pyround(_ x: Double) -> Double { x.rounded(.toNearestOrEven) }

private func radians(_ d: Double) -> Double { d * (Double.pi / 180) }
private func dist(_ a: V, _ b: V) -> Double { hypot(a.x - b.x, a.y - b.y) }
private func norm(_ p: V) -> Double { hypot(p.x, p.y) }

private func arc(_ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double, _ a0: Double, _ a1: Double, _ n: Int? = nil) -> [V] {
    let n = n ?? max(4, Int(abs(a1 - a0) / 6))
    return (0...n).map { i in
        let a = radians(a0 + (a1 - a0) * Double(i) / Double(n))
        return V(cx + rx * cos(a), cy + ry * sin(a))
    }
}

private func polar(_ c: V, _ r: Double, _ phi: Double) -> V { V(c.x + r * cos(phi), c.y + r * sin(phi)) }
private func cross(_ u: V, _ v: V) -> Double { u.x * v.y - u.y * v.x }

// MARK: Shapes

private final class Shape {
    let c: V
    let radius: (Double) -> Double
    let snap: (Double) -> Double
    let detail: (Double) -> [V]
    let rmax: Double

    init(_ c: V, _ radius: @escaping (Double) -> Double, snap: ((Double) -> Double)? = nil, detail: ((Double) -> [V])? = nil) {
        self.c = c
        self.radius = radius
        self.snap = snap ?? { $0 }
        self.detail = detail ?? { _ in [] }
        rmax = (0..<720).map { radius(2 * Double.pi * Double($0) / 720) }.max()!
    }

    func edge(_ phi: Double, _ scale: Double = 1) -> V { polar(c, scale * radius(phi), phi) }
    func angle(_ p: V) -> Double { atan2(p.y - c.y, p.x - c.x) }

    func contains(_ p: V) -> Bool {
        let d = dist(p, c)
        return d < rmax && d < radius(angle(p))
    }

    func walk(_ phi0: Double, _ delta: Double) -> [V] {
        let n = max(2, Int(abs(delta) * rmax / STEP))
        return (1...n).map { edge(phi0 + delta * Double($0) / Double(n)) }
    }

    /// Edge points from where a row enters (a) to where it leaves (b), on the row's side.
    func around(_ a: V, _ b: V) -> [V] {
        let phiA = angle(a), phiB = angle(b)
        let ccw = cross(V(b.x - a.x, b.y - a.y), V(c.x - a.x, c.y - a.y)) > 0
        let delta = pymod(phiB - phiA, TAU)
        return walk(phiA, ccw ? delta : delta - TAU)
    }

    /// Sweep smooth from the centre out, trace the outline twice, then the detail. Ends on the edge.
    func draw(toward: V) -> [V] {
        let end = snap(atan2(toward.y - c.y, toward.x - c.x))
        let mean = pysum((0..<360).map { radius(2 * Double.pi * Double($0) / 360) }) / 360
        let total = 2 * Double.pi * ((mean + rmax) / 2 / SHAPE_SWEEP).rounded(.up)
        var pts: [V] = [], t = 0.0
        while t < total {
            pts.append(edge(end - total + t, t / total))
            t += STEP / max(t / total * rmax, 0.03)
        }
        pts += [edge(end)] + walk(end, TAU)
        let inset = (0...720).map { i -> V in
            let phi = end - 2 * Double.pi * Double(i) / 720
            return edge(phi, 1 - BALL / 2 / radius(phi))
        }
        return pts + inset + [edge(end)] + detail(end)
    }
}

private func sun(_ c: V, rIn: Double = 0.22, rOut: Double = 0.36, rays: Int = 12, disc: Double = 0.17) -> Shape {
    let rays = Double(rays)
    func radius(_ phi: Double) -> Double {
        let u = pymod(phi * rays / (2 * Double.pi), 1)
        return rIn + (rOut - rIn) * abs(2 * u - 1)
    }
    func snap(_ phi: Double) -> Double { ((phi * rays / (2 * Double.pi)).rounded(.down) + 0.5) * 2 * Double.pi / rays }
    func detail(_ phi: Double) -> [V] {
        let n = Int(2 * Double.pi * disc / STEP)
        return (0...n).map { polar(c, disc, phi + 2 * Double.pi * Double($0) / Double(n)) } + [polar(c, rIn, phi)]
    }
    return Shape(c, radius, snap: snap, detail: detail)
}

private func cloud(_ c: V, _ w: Double, _ h: Double, _ lobes: Double = 3, _ phase: Double = 1.0) -> Shape {
    Shape(c) { phi in
        let s = sin(phi)
        let a = w / 2, b = h * (s >= 0 ? 0.55 : 0.30)
        let base = a * b / hypot(b * cos(phi), a * sin(phi))
        if s > 0 { return base * (1 + 0.5 * pow(abs(sin(lobes * phi + phase)), 0.7) * pow(s, 0.3)) }
        return base * (1 + 0.05 * abs(sin(3 * phi + phase)))
    }
}

/// A raindrop: a round bottom of radius a, pointed tip `tip` above its centre.
private func drop(_ c: V, a: Double = 0.1, tip: Double = 0.26) -> Shape {
    let cone = acos(a / tip)
    return Shape(c) { phi in
        let off = abs(pymod(phi - Double.pi / 2 + Double.pi, TAU) - Double.pi)
        return off < cone ? a / cos(off - cone) : a
    }
}

private func flake(_ c: V, _ r: Double, tilt: Double = Double.pi / 2, twigs: Bool = true) -> Shape {
    let step = Double.pi / 3
    let length = 0.9 * r
    func radius(_ phi: Double) -> Double {
        let d = pymod(phi - tilt, step) - step / 2
        return r * cos(step / 2) / cos(d)
    }
    func snap(_ phi: Double) -> Double { tilt + pyround((phi - tilt) / step) * step }
    func arm(_ phi: Double) -> [V] {
        let tip = polar(c, length, phi)
        if !twigs { return [tip, c] }
        let b = polar(c, 0.5 * length, phi)
        let twig = 0.32 * length
        return [b, polar(b, twig, phi + 0.8), b, polar(b, twig, phi - 0.8), b, tip, c]
    }
    func detail(_ phi: Double) -> [V] {
        var pts = [c]
        for k in 1...6 { pts += arm(phi + Double(k) * step) }
        return pts.dropLast() + [polar(c, r, phi)]
    }
    return Shape(c, radius, snap: snap, detail: detail)
}

/// A lightning bolt: an oval swept smooth with a bold zigzag in it.
private func bolt(_ c: V, _ scale: Double = 1.0) -> Shape {
    let rx = 0.2 * scale, ry = 0.36 * scale
    let zigzag = [(0.07, 0.28), (-0.08, 0.01), (0.07, 0.03), (-0.06, -0.29)].map { V(c.x + $0.0 * scale, c.y + $0.1 * scale) }
    func radius(_ phi: Double) -> Double { rx * ry / hypot(ry * cos(phi), rx * sin(phi)) }
    func detail(_ phi: Double) -> [V] {
        let z = densify(zigzag)
        return [z[0]] + bold(z) + z.reversed() + [polar(c, radius(phi), phi)]
    }
    let exit = atan2(zigzag[0].y - c.y, zigzag[0].x - c.x)
    return Shape(c, radius, snap: { _ in exit }, detail: detail)
}

/// A crescent moon: one circle minus a second that bites into it.
private func crescent(_ c: V, scale: Double = 0.86, tilt: Double = 0.55) -> Shape {
    let ct = cos(tilt), st = sin(tilt)
    let outer = V(0.22 * scale * ct, 0.22 * scale * st), inner = V(0.4 * scale * ct, 0.4 * scale * st)
    let outerR = 0.34 * scale, innerR = 0.28 * scale
    func hits(_ o: V, _ r: Double, _ phi: Double) -> [Double] {
        let b = o.x * cos(phi) + o.y * sin(phi)
        let disc = b * b - (o.x * o.x + o.y * o.y - r * r)
        if disc < 1e-12 { return [] }
        return [b - disc.squareRoot(), b + disc.squareRoot()].filter { $0 > 1e-5 }
    }
    return Shape(c) { phi in
        let u = V(cos(phi), sin(phi))
        var found = hits(outer, outerR, phi).filter { dist(V($0 * u.x, $0 * u.y), inner) >= innerR - 1e-4 }
        found += hits(inner, innerR, phi).filter { dist(V($0 * u.x, $0 * u.y), outer) <= outerR + 1e-4 }
        return found.min() ?? outerR
    }
}

/// The sun with any ray that would reach into `cover` cut short just before it.
private func sunBehind(_ c: V, _ cover: Shape, rIn: Double = 0.15, rOut: Double = 0.32, rays: Int = 12, disc: Double = 0.13) -> Shape {
    let rays = Double(rays)
    func raw(_ phi: Double) -> Double {
        let u = pymod(phi * rays / (2 * Double.pi), 1)
        return rIn + (rOut - rIn) * abs(2 * u - 1)
    }
    func radius(_ phi: Double) -> Double {
        let base = raw(phi), u = V(cos(phi), sin(phi))
        func at(_ t: Double) -> V { V(c.x + u.x * t, c.y + u.y * t) }
        guard let hit = (1...24).lazy.map({ base * Double($0) / 24 }).first(where: { cover.contains(at($0)) }) else { return base }
        var lo = 0.0, hi = hit
        for _ in 0..<16 {
            let mid = (lo + hi) / 2
            if cover.contains(at(mid)) { hi = mid } else { lo = mid }
        }
        return max(0.05, lo - 0.02)
    }
    func snap(_ phi: Double) -> Double { ((phi * rays / (2 * Double.pi)).rounded(.down) + 0.5) * 2 * Double.pi / rays }
    func detail(_ phi: Double) -> [V] {
        let n = Int(2 * Double.pi * disc / STEP)
        return (0...n).map { polar(c, disc, phi + 2 * Double.pi * Double($0) / Double(n)) } + [polar(c, radius(phi), phi)]
    }
    return Shape(c, radius, snap: snap, detail: detail)
}

private func pebble(_ c: V, _ r: Double) -> Shape { Shape(c) { _ in r } }

private func bank(_ c: V, _ w: Double, _ h: Double, _ waves: Double = 3.0, _ phase: Double = 0.0) -> Shape {
    Shape(c) { phi in
        let a = w / 2, b = h / 2
        return a * b / hypot(b * cos(phi), a * sin(phi)) * (1 + 0.12 * sin(waves * phi + phase))
    }
}

// MARK: Frames

private func line(_ a: V, _ b: V) -> [V] {
    let n = max(1, Int((dist(a, b) / STEP).rounded(.up)))
    return (0...n).map { V(a.x + (b.x - a.x) * Double($0) / Double(n), a.y + (b.y - a.y) * Double($0) / Double(n)) }
}

private func nearest(_ pts: [V], _ p: V) -> Int {
    var best = 0, bestD = Double.infinity
    for (i, q) in pts.enumerated() { let d = dist(q, p); if d < bestD { best = i; bestD = d } }
    return best
}

/// Round the rim from a to b, the short way.
private func rimArc(_ a: V, _ b: V) -> [V] {
    let a0 = atan2(a.y, a.x)
    let d = pymod(atan2(b.y, b.x) - a0 + Double.pi, TAU) - Double.pi
    let n = max(1, Int(abs(d) * RIM / STEP))
    return (1...n).map { polar(V(0, 0), RIM, a0 + d * Double($0) / Double(n)) } + [b]
}

private struct Frame {
    let lo: Double, hi: Double
    let contour: [V]

    init(lo: Double = -1.0, hi: Double = PANEL_Y) {
        self.lo = lo; self.hi = hi
        func rim(_ a0: Double, _ a1: Double) -> [V] {
            let n = max(1, Int(abs(a1 - a0) * RIM / STEP))
            return (0...n).map { polar(V(0, 0), RIM, a0 + (a1 - a0) * Double($0) / Double(n)) }
        }
        let h = asin(hi / RIM)
        if lo <= -RIM {
            let pts = rim(Double.pi - h, 2 * Double.pi + h)
            contour = pts + line(pts.last!, pts[0]).dropFirst()
        } else {
            let l = asin(lo / RIM)
            let right = rim(l, h), left = rim(Double.pi - h, Double.pi - l)
            contour = right + line(right.last!, left[0]).dropFirst() + left.dropFirst()
                + line(left.last!, right[0]).dropFirst().dropLast()
        }
    }

    func contains(_ p: V) -> Bool { norm(p) <= RIM && lo <= p.y && p.y < hi }

    /// Along the edge (the short way) when both ends are on or just inside it, round the rim when both
    /// are on it, else straight.
    func link(_ a: V, _ b: V) -> [V] {
        let c = contour
        let i = nearest(c, a), j = nearest(c, b)
        if dist(c[i], a) <= 0.03 && dist(c[j], b) <= 0.1 {
            let n = c.count
            let fwd = (0...imod(j - i, n)).map { c[imod(i + $0, n)] }
            let back = (0...imod(i - j, n)).map { c[imod(i - $0, n)] }
            return (back.count < fwd.count ? back : fwd) + [b]
        }
        if abs(norm(a) - RIM) < 0.03 && abs(norm(b) - RIM) < 0.03 { return rimArc(a, b) }
        return Array(line(a, b).dropFirst())
    }
}

// MARK: Background rows

private typealias Row = (pts: [V], closed: Bool)

private func parallelRows(_ angle: Double, _ spacing: Double, _ wave: (Double, Int) -> Double = { _, _ in 0 }) -> [Row] {
    let d = V(cos(radians(angle)), sin(radians(angle)))
    let n = V(-d.y, d.x)
    var rows: [Row] = [], k = 0, t = -RIM + spacing / 2
    while t < RIM {
        var s = -1.0, row: [V] = []
        while s <= 1.0 {
            let off = t + wave(s, k)
            row.append(V(d.x * s + n.x * off, d.y * s + n.y * off))
            s += STEP
        }
        rows.append((row, false))
        t += spacing; k += 1
    }
    return rows
}

private func ringRows(_ c: V, _ r0: Double, _ spacing: Double) -> [Row] {
    var rows: [Row] = [], r = r0
    while r < norm(c) + RIM {
        let n = Int(2 * Double.pi * r / STEP)
        rows.append(((0...n).map { polar(c, r, 2 * Double.pi * Double($0) / Double(n)) }, true))
        r += spacing
    }
    return rows
}

/// Split a row into runs inside the frame; where it crosses a shape, go round the edge instead.
private func flow(_ row: [V], _ closed: Bool, _ shapes: [Shape], _ frame: Frame) -> [[V]] {
    var row = row
    if closed {
        guard let out = row.firstIndex(where: { !frame.contains($0) }) else { return [row] }
        row = Array(row[out...]) + Array(row[1..<min(out + 1, row.count)])
    }
    var runs: [[V]] = [], run: [V] = [], inside: (Shape, V)?
    for p in row {
        if !frame.contains(p) {
            if !run.isEmpty { runs.append(run) }
            run = []; inside = nil
            continue
        }
        let hit = shapes.first { $0.contains(p) }
        if inside == nil, let hit {
            inside = (hit, run.last ?? p)
        } else if let ins = inside, hit !== ins.0 {
            run += ins.0.around(ins.1, p)
            inside = nil
        }
        if inside == nil { run.append(p) }
    }
    if !run.isEmpty { runs.append(run) }
    return runs
}

private func background(_ path: [V], _ rows: [Row], _ shapes: [Shape], _ frame: Frame) -> [V] {
    var path = path
    for (row, closed) in rows {
        var runs = flow(row, closed, shapes, frame)
        if runs.isEmpty { continue }
        let here = path.last!
        if runs.count == 1 && dist(runs[0][0], runs[0].last!) < STEP * 1.5 {   // a whole ring
            let i = nearest(runs[0], here)
            runs = [Array(runs[0][i...]) + Array(runs[0][1..<(i + 1)])]
        } else if dist(here, runs.last!.last!) < dist(here, runs[0][0]) {
            runs = runs.reversed().map { $0.reversed() }
        }
        for r in runs { path += frame.link(path.last!, r[0]) + r }
    }
    return path
}

// MARK: Temperature

private let DIGITS: [Character: (Double, [V])] = {
    func p(_ pts: [(Double, Double)]) -> [V] { pts.map { V($0.0, $0.1) } }
    return [
        "0": (0.6, arc(0.3, 0.5, 0.3, 0.5, -90, 270)),
        "1": (0.35, p([(0.03, 0.8), (0.25, 1), (0.25, 0)])),
        "2": (0.6, arc(0.3, 0.72, 0.3, 0.28, 160, -40) + p([(0, 0), (0.6, 0)])),
        "3": (0.6, arc(0.3, 0.75, 0.27, 0.25, 150, -90) + arc(0.3, 0.26, 0.3, 0.26, 90, -150)),
        "4": (0.62, p([(0.08, 1), (0, 0.32), (0.45, 0.32), (0.45, 1), (0.45, 0), (0.45, 0.32), (0.62, 0.32)])),
        "5": (0.6, p([(0.55, 1), (0.08, 1), (0.05, 0.55)]) + arc(0.3, 0.32, 0.3, 0.32, 140, -145)),
        "6": (0.6, arc(0.32, 0.5, 0.3, 0.5, 60, 200) + arc(0.3, 0.3, 0.3, 0.3, 180, 540)),
        "7": (0.6, p([(0, 1), (0.6, 1), (0.2, 0)])),
        "8": (0.6, arc(0.3, 0.27, 0.3, 0.27, -90, 90) + arc(0.3, 0.77, 0.26, 0.23, -90, -450)
              + arc(0.3, 0.27, 0.3, 0.27, 90, 270)),
        "9": (0.6, arc(0.3, 0.7, 0.3, 0.3, 0, 360) + arc(0.3, 0.5, 0.3, 0.5, 20, -120)),
    ]
}()

/// Ways to draw a stroke completely, retracing parts of it to start and end where needed.
private func traversals(_ stroke: [V]) -> [[V]] {
    let n = stroke.count
    let rev = Array(stroke.reversed())
    if dist(stroke[0], stroke[n - 1]) < 1e-6 {   // a loop: start anywhere, go once round
        return stride(from: 0, to: n - 1, by: max(1, n / 40)).map { k in Array(stroke[k...]) + Array(stroke[1..<(k + 1)]) }
    }
    var ways: [[V]] = []
    for k in stride(from: 0, to: n, by: max(1, n / 40)) {
        ways.append(Array(stroke[k...]) + rev.dropFirst())
        ways.append(Array(stroke[...k].reversed()) + stroke.dropFirst())
        ways.append(Array(stroke[k...]) + rev.dropFirst() + Array(stroke[1..<(k + 1)]))
    }
    return ways + ways.map { $0.reversed() }
}

private func length(_ pts: [V]) -> Double { pysum(zip(pts, pts.dropFirst()).map { dist($0, $1) }) }

/// The path shifted sideways by d (to the left of travel).
private func offset(_ path: [V], _ d: Double) -> [V] {
    path.indices.map { i in
        let p = path[i]
        var a = path[max(0, i - 1)], b = path[min(path.count - 1, i + 1)]
        if dist(a, b) < 1e-9 { (a, b) = dist(a, p) > 1e-9 ? (a, p) : (p, b) }
        var n = dist(a, b)
        if n == 0 { n = 1.0 }
        return V(p.x - (b.y - a.y) / n * d, p.y + (b.x - a.x) / n * d)
    }
}

/// The path, back along one side of it and out again along the other.
private func bold(_ path: [V]) -> [V] {
    let path = densify(path)
    return path + offset(path, BOLD).reversed() + offset(path, -BOLD)
}

private func bestTraversal(_ stroke: [V], last: Bool) -> [V] {
    let left = stroke.map(\.x).min()!, right = stroke.map(\.x).max()!
    func key(_ w: [V]) -> Double { 2 * (w[0].x - left) + (last ? 0 : 3 * (right - w.last!.x)) + 0.05 * length(w) }
    var best: [V] = [], bestKey = Double.infinity
    for w in traversals(stroke) { let k = key(w); if k < bestKey { best = w; bestKey = k } }
    return best
}

private func numberWidth(_ text: String, _ cap: Double) -> Double {
    let w = pysum(text.map { $0 != "-" ? DIGITS[$0]!.0 * cap : MINUS * cap }) + GAP * Double(text.count)
    return w + 2 * DEGREE
}

/// Strokes for the number and degree sign, centred in the panel, and the digit height.
private func temperatureStrokes(_ value: Int) -> ([[V]], Double) {
    let text = String(value)
    var cap = CAP, w = 0.0
    while cap > 0.2 {
        w = numberWidth(text, cap)
        let top = BASELINE + cap + BALL / 2 + BOLD
        if hypot(w / 2, top) <= TEXT_RIM { break }
        cap -= 0.01
    }
    var x = -w / 2, strokes: [[V]] = []
    for ch in text {
        let (cw, stroke) = ch != "-" ? DIGITS[ch]! : (MINUS, [V(0, 0.5), V(MINUS, 0.5)])
        strokes.append(stroke.map { V(x + $0.x * cap, BASELINE + $0.y * cap) })
        x += cw * cap + GAP
    }
    let ringY = BASELINE + cap - DEGREE
    strokes.append(arc(x + DEGREE - GAP * 0.3, ringY, DEGREE, DEGREE, 180, 540))
    return (strokes, cap)
}

private func panelBottom() -> Double { PANEL_Y + BALL / 2 }

/// Long rows across the panel, from the top down to yLow, ending on the left.
private func panelRows(_ yLow: Double) -> [V] {
    let ys = (0..<(Int((PANEL_RIM - SWEEP / 2 - yLow) / SWEEP) + 1)).map { yLow + SWEEP * Double($0) }.reversed() as [Double]
    var path: [V] = []
    for (i, y) in ys.enumerated() {
        let x1 = (PANEL_RIM * PANEL_RIM - y * y).squareRoot()
        path += (ys.count - i) % 2 != 0 ? [V(x1, y), V(-x1, y)] : [V(-x1, y), V(x1, y)]
    }
    return path
}

/// Rows BAND_SWEEP apart across the strip between xLo and xHi, over the band the number sits in.
private func sweepStrip(_ xLo: Double, _ xHi: Double, _ top: Double, entry: V? = nil) -> [V] {
    let bottom = panelBottom()
    let ey = entry.map { bottom + BAND_SWEEP * pyround(($0.y - bottom) / BAND_SWEEP) } ?? bottom
    let kLo = Int(((bottom - ey) / BAND_SWEEP - 1e-9).rounded(.up))
    let kHi = Int(((top - ey) / BAND_SWEEP + 1e-9).rounded(.down))

    func row(_ k: Int, _ rightward: Bool) -> [V]? {
        let y = ey + Double(k) * BAND_SWEEP
        let x1 = min(xHi, max(0.0, PANEL_RIM * PANEL_RIM - y * y).squareRoot())
        if x1 <= xLo { return nil }
        return rightward ? [V(xLo, y), V(x1, y)] : [V(x1, y), V(xLo, y)]
    }
    let above = stride(from: kHi, to: 0, by: -1).compactMap { row($0, $0 % 2 == 0) }
    var below = (kLo < 0 ? Array(kLo..<0) : []).compactMap { row($0, ($0 - kLo) % 2 == 0) }
    if let b = below.last, let a = above.first, (b.last!.x > b[0].x) != (a[0].x > a.last!.x) {
        below = below.map { $0.reversed() }
    }
    let first = row(0, true) ?? []
    return (below + above).flatMap { $0 } + (entry.map { Array(first.prefix(1)) + [$0] } ?? first)
}

/// Sweep the temperature panel smooth and write the number in it.
private func panel(_ value: Int) -> ([V], Double) {
    let (strokes, cap) = temperatureStrokes(value)
    let top = BASELINE + cap + BOLD + 0.07
    let edge = (PANEL_RIM * PANEL_RIM - PANEL_Y * PANEL_Y).squareRoot()
    let margin = BALL + BOLD
    var xLo = strokes[0].map(\.x).min()! - margin
    var path = panelRows(top) + sweepStrip(-edge, xLo, top)
    for (i, stroke) in strokes.enumerated() {
        if i > 0 { xLo = strokes[i - 1].map(\.x).max()! + margin + 0.005 }
        let xHi = i + 1 == strokes.count ? edge : strokes[i + 1].map(\.x).min()! - margin
        let glyph = bestTraversal(stroke, last: i + 1 == strokes.count)
        path += [V(xLo, path.last!.y)] + sweepStrip(xLo, xHi, top, entry: glyph[0]) + bold(glyph)
    }
    return (path, cap)
}

// MARK: Scenes

private func scene(_ name: WeatherPicture.Condition) -> ([Shape], [([Row], Frame)]) {
    switch name {
    case .sunny:
        let s = sun(V(0, -0.42))
        return ([s], [(ringRows(s.c, 0.43, 0.085), Frame())])
    case .cloudy:
        let sizes = [(0.42, 0.2), (1.0, 0.44)]
        let shapes = [cloud(V(-0.55, -0.14), sizes[0].0, sizes[0].1, 2, 0.6), cloud(V(0.08, -0.46), sizes[1].0, sizes[1].1)]
        func wind(_ s: Double, _ k: Int) -> Double {
            let y0 = -RIM + 0.0425 + 0.085 * Double(k)
            var dy = 0.018 * sin(2.6 * s + 0.25 * Double(k))
            for (c, (w, h)) in zip(shapes, sizes) {
                let qx = (s - c.c.x) / (w / 2), qy = (y0 - c.c.y) / (h / 1.6)
                let q = qx * qx + qy * qy
                dy += copysign(0.035 * exp(-max(0.0, q - 1) * 1.2), y0 - c.c.y)
            }
            return dy
        }
        return (shapes, [(parallelRows(0, 0.085, wind), Frame())])
    case .rain:
        let sky = cloud(V(0, -0.24), 0.85, 0.32)
        let base = -0.38
        let shapes = [sky, drop(V(-0.32, -0.7), tip: 0.24), drop(V(0, -0.74), tip: 0.24), drop(V(0.32, -0.7), tip: 0.24)]
        return (shapes, [(parallelRows(72, 0.08), Frame(hi: base)),
                         (parallelRows(0, 0.085) { s, k in 0.015 * sin(2.4 * s + 0.3 * Double(k)) }, Frame(lo: base))])
    case .snow:
        let shapes = [flake(V(-0.66, -0.22), 0.17, twigs: false), flake(V(0, -0.43), 0.42),
                      flake(V(0.66, -0.22), 0.17, twigs: false)]
        return (shapes, [(parallelRows(90, 0.085) { s, k in 0.03 * sin(5 * s + 0.7 * Double(k)) }, Frame())])
    case .partlycloudy:
        let cover = cloud(V(0.26, -0.3), 0.76, 0.3, 3, 0.7)
        let day = sunBehind(V(-0.22, -0.42), cover)
        return ([day, cover], [(ringRows(day.c, day.rmax + 0.05, 0.09), Frame())])
    case .thunderstorm:
        let base = -0.29
        return ([cloud(V(0, -0.16), 0.88, 0.3), bolt(V(0, -0.6), 0.95)], [
            (parallelRows(110, 0.095), Frame(hi: base)),
            (parallelRows(0, 0.085) { s, k in 0.012 * sin(2.3 * s + 0.3 * Double(k)) }, Frame(lo: base))])
    case .heavyRain:
        let base = -0.34
        let drops = [-0.46, -0.23, 0, 0.23, 0.46].enumerated().map { i, x in drop(V(x, -0.58 - 0.06 * Double(i % 2)), tip: 0.16) }
        return ([cloud(V(0, -0.2), 0.9, 0.3)] + drops, [
            (parallelRows(74, 0.07), Frame(hi: base)), (parallelRows(0, 0.09), Frame(lo: base))])
    case .sleet:
        let base = -0.36
        let shapes = [cloud(V(0, -0.22), 0.8, 0.3), drop(V(-0.34, -0.62), tip: 0.2),
                      flake(V(-0.08, -0.66), 0.16, twigs: false), drop(V(0.2, -0.7), tip: 0.18),
                      flake(V(0.42, -0.58), 0.13, twigs: false)]
        return (shapes, [(parallelRows(78, 0.09), Frame(hi: base)), (parallelRows(0, 0.09), Frame(lo: base))])
    case .hail:
        let base = -0.36
        let stones = [pebble(V(-0.4, -0.6), 0.13), pebble(V(0, -0.7), 0.14), pebble(V(0.4, -0.6), 0.13)]
        return ([cloud(V(0, -0.22), 0.82, 0.3)] + stones, [
            (parallelRows(68, 0.1), Frame(hi: base)),
            (parallelRows(0, 0.09) { s, k in 0.01 * sin(2.2 * s + 0.3 * Double(k)) }, Frame(lo: base))])
    case .fog:
        let banks = [bank(V(0.04, -0.24), 0.9, 0.15, 2.4, 0.3), bank(V(-0.1, -0.46), 0.62, 0.14, 2.8, 1.2),
                     bank(V(0.02, -0.68), 0.98, 0.15, 2.2, 2.1)]
        return (banks, [(parallelRows(0, 0.058) { s, k in 0.026 * sin(3.3 * s + 0.55 * Double(k)) }, Frame())])
    case .clearNight:
        let stars = [sun(V(0.42, -0.24), rIn: 0.09, rOut: 0.22, rays: 5, disc: 0.04),
                     sun(V(0.4, -0.68), rIn: 0.08, rOut: 0.19, rays: 5, disc: 0.035)]
        return ([crescent(V(-0.3, -0.44), scale: 1.2, tilt: 0.3)] + stars, [
            (parallelRows(0, 0.072) { s, k in 0.01 * sin(2 * s + 0.3 * Double(k)) }, Frame())])
    }
}

private func build(_ condition: WeatherPicture.Condition, _ value: Int) -> ([V], Double) {
    let (shapes, passes) = scene(condition)
    let rows = passes[0].0
    var path: [V] = []
    for (i, s) in shapes.enumerated() {
        let nxt = i + 1 < shapes.count ? shapes[i + 1].c : rows[0].pts[0]
        if !path.isEmpty { path += transit(path.last!, s.c, rows) }
        path += s.draw(toward: nxt)
    }
    let (row, closed) = rows[0]
    if !closed { path += outToRim(path.last!, row) }
    for (rows, frame) in passes { path = background(path, rows, shapes, frame) }
    let (text, cap) = panel(value)
    return (path + rimArc(path.last!, text[0]) + text, cap)
}

/// A move between shapes that the background will wipe out: square across the rows onto the nearest one,
/// along it, then square across again.
private func transit(_ a: V, _ b: V, _ rows: [Row]) -> [V] {
    let (row, closed) = rows[0]
    if closed { return Array(line(a, b).dropFirst()) }
    let d = V(row.last!.x - row[0].x, row.last!.y - row[0].y)
    let n = V(-d.y / norm(d), d.x / norm(d))
    func across(_ p: V) -> Double { p.x * n.x + p.y * n.y }
    let mid = (across(a) + across(b)) / 2
    var t = 0.0, best = Double.infinity
    for r in rows {
        let o = across(r.pts[r.pts.count / 2])
        if abs(o - mid) < best { best = abs(o - mid); t = o }
    }
    let a1 = V(a.x + (t - across(a)) * n.x, a.y + (t - across(a)) * n.y)
    let b1 = V(b.x + (t - across(b)) * n.x, b.y + (t - across(b)) * n.y)
    return Array(line(a, a1).dropFirst()) + line(a1, b1).dropFirst() + line(b1, b).dropFirst()
}

/// From the last shape straight out to the rim, square to the background rows, toward the first row's side.
private func outToRim(_ a: V, _ row: [V]) -> [V] {
    let d = V(row.last!.x - row[0].x, row.last!.y - row[0].y)
    let n = norm(d)
    let normal = V(-d.y / n, d.x / n)
    let mid = row[row.count / 2]
    let sign: Double = mid.x * normal.x + mid.y * normal.y > 0 ? 1 : -1
    let u = V(sign * normal.x, sign * normal.y)
    let b = a.x * u.x + a.y * u.y
    let t = -b + (b * b - (a.x * a.x + a.y * a.y - RIM * RIM)).squareRoot()
    return Array(line(a, V(a.x + t * u.x, a.y + t * u.y)).dropFirst())
}

private func densify(_ path: [V]) -> [V] {
    var out = [path[0]]
    for p in path.dropFirst() where dist(out.last!, p) > 1e-6 { out += line(out.last!, p).dropFirst() }
    return out
}
