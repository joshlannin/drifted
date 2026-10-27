import DriftedKit
import Foundation
import SwiftUI

/// Everything the user is designing. Produces a single continuous `Pattern`.
@MainActor
final class Studio: ObservableObject {
    enum Source: String, CaseIterable, Identifiable {
        case draw = "Draw", generate = "Generate", file = "Import"
        var id: String { rawValue }
    }

    enum GeneratorKind: String, CaseIterable, Identifiable {
        case rose = "Rose", spirograph = "Spirograph", spiral = "Spiral"
        var id: String { rawValue }
    }

    @Published var source: Source = Source(rawValue: UserDefaults.standard.string(forKey: "source") ?? "") ?? .draw {
        didSet { UserDefaults.standard.set(source.rawValue, forKey: "source") }
    }

    // Draw
    /// Strokes in unit-disc coordinates (x right, y up).
    @Published var strokes: [[CGPoint]] = []
    @Published var symmetry = 1
    @Published var mirror = false

    // Generate
    @Published var generator: GeneratorKind = .rose
    @Published var petals = 5.0
    @Published var roseLoops = 1.0
    @Published var precession = 0.0
    @Published var spiralTurns = 20.0
    @Published var spiroR = 5.0
    @Published var spiror = 3.0
    @Published var spirod = 4.0
    @Published var spiroLoops = 3.0

    // Import
    @Published var imported: SandPattern?

    // Output
    @Published var wipeFirst = false
    @Published var rotationDegrees = 0.0
    /// Flip left↔right. The table's angle direction is unverified; if text draws backwards, turn this on.
    @Published var mirrorOutput = UserDefaults.standard.bool(forKey: "mirrorOutput") {
        didSet { UserDefaults.standard.set(mirrorOutput, forKey: "mirrorOutput") }
    }
    /// Ball diameter as a fraction of the table radius (preview + wipe spacing).
    @Published var ballDiameter = 0.06

    var pattern: SandPattern {
        var p: SandPattern
        switch source {
        case .draw: p = drawnPattern
        case .generate: p = generatedPattern
        case .file: p = imported ?? SandPattern(name: "Empty", points: [])
        }
        if rotationDegrees != 0 { p = p.rotated(by: rotationDegrees * .pi / 180) }
        if mirrorOutput { p = SandPattern(name: p.name, points: p.points.map { PolarPoint(theta: .pi - $0.theta, rho: $0.rho) }) }
        if wipeFirst, !p.points.isEmpty {
            p = SandPattern(name: p.name, points: wipe.points + p.points)
        }
        return p
    }

    /// Edge-to-centre spiral with line spacing equal to the ball width.
    var wipe: SandPattern { Generators.spiral(turns: max(4, 1 / ballDiameter), outward: false) }

    var expandedStrokes: [[CGPoint]] {
        guard symmetry > 1 || mirror else { return strokes }
        var out: [[CGPoint]] = []
        for stroke in strokes {
            for k in 0..<max(1, symmetry) {
                let a = Double(k) * 2 * .pi / Double(max(1, symmetry))
                out.append(stroke.map { rotate($0, a) })
                if mirror { out.append(stroke.reversed().map { rotate(CGPoint(x: $0.x, y: -$0.y), a) }) }
            }
        }
        return out
    }

    private func rotate(_ p: CGPoint, _ a: Double) -> CGPoint {
        let c = CGFloat(cos(a)), s = CGFloat(sin(a))
        return CGPoint(x: p.x * c - p.y * s, y: p.x * s + p.y * c)
    }

    var drawnPattern: SandPattern {
        SandPattern.fromStrokes(expandedStrokes.map { $0.map { (x: Double($0.x), y: Double($0.y)) } }, name: "Drawing")
    }

    var generatedPattern: SandPattern {
        switch generator {
        case .rose: return Generators.rose(petals: petals, loops: roseLoops, precession: precession)
        case .spirograph: return Generators.spirograph(R: spiroR, r: spiror, d: spirod, loops: spiroLoops)
        case .spiral: return Generators.spiral(turns: spiralTurns, outward: true)
        }
    }

    /// Segments the ball must travel that the user didn't draw (stroke → next stroke).
    var connectorSegments: [(CGPoint, CGPoint)] {
        let s = expandedStrokes.filter { !$0.isEmpty }
        return zip(s, s.dropFirst()).compactMap { a, b in (a.last!, b.first!) }
    }

    func importFile(_ url: URL, watch: Bool = false) throws {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        imported = try SandPattern.load(url: url)
        source = .file
        watchTimer?.invalidate()
        guard watch else { return }
        // Reload when the file changes, so a script (or Claude) can iterate on a design live.
        var lastModified = modificationDate(url)
        watchTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                let m = self?.modificationDate(url)
                guard let self, let m, m != lastModified else { return }
                lastModified = m
                if let p = try? SandPattern.load(url: url) { self.imported = p }
            }
        }
    }

    private var watchTimer: Timer?

    private func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
