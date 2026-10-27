import DriftedKit
import SwiftUI

/// Renders a pattern as grooves in sand (line width = ball diameter) and captures freehand strokes.
struct SandCanvas: View {
    let pattern: SandPattern
    /// 0…1 of the pattern to show (for the "play" preview).
    var progress: Double = 1
    var ballDiameter: Double
    var connectors: [(CGPoint, CGPoint)] = []
    var showPathLine = false
    var onStroke: ((CGPoint, _ began: Bool) -> Void)?

    @StateObject private var drag = DragTracker()

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let radius = side / 2 - 8
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let toView = { (x: Double, y: Double) in CGPoint(x: center.x + x * radius, y: center.y - y * radius) }

            Canvas { ctx, _ in
                let disc = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
                ctx.fill(disc, with: .color(Color(red: 0.86, green: 0.78, blue: 0.64)))
                ctx.clip(to: disc)

                let count = Int(Double(pattern.points.count) * progress)
                if count > 1 {
                    var path = Path()
                    let pts = pattern.points
                    path.move(to: toView(pts[0].x, pts[0].y))
                    for p in pts[1..<count] { path.addLine(to: toView(p.x, p.y)) }
                    let width = max(1, ballDiameter * radius)
                    // Groove shading: dark trough with a lighter ridge on one side.
                    ctx.stroke(path, with: .color(Color(red: 0.62, green: 0.52, blue: 0.38)),
                               style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
                    ctx.stroke(path.offsetBy(dx: -width * 0.18, dy: -width * 0.18),
                               with: .color(Color(red: 0.93, green: 0.87, blue: 0.75).opacity(0.55)),
                               style: StrokeStyle(lineWidth: width * 0.25, lineCap: .round, lineJoin: .round))
                    if showPathLine {
                        ctx.stroke(path, with: .color(.black.opacity(0.35)), lineWidth: 0.5)
                    }
                    let ball = toView(pts[count - 1].x, pts[count - 1].y)
                    ctx.fill(Path(ellipseIn: CGRect(x: ball.x - width / 2, y: ball.y - width / 2, width: width, height: width)),
                             with: .color(Color(white: 0.75)))
                }

                for (a, b) in connectors {
                    var seg = Path()
                    seg.move(to: toView(a.x, a.y))
                    seg.addLine(to: toView(b.x, b.y))
                    ctx.stroke(seg, with: .color(.orange.opacity(0.8)), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                }
                ctx.stroke(disc, with: .color(.black.opacity(0.25)), lineWidth: 2)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        guard let onStroke else { return }
                        var p = CGPoint(x: (g.location.x - center.x) / radius, y: (center.y - g.location.y) / radius)
                        let d = (p.x * p.x + p.y * p.y).squareRoot()
                        if d > 1 { p = CGPoint(x: p.x / d, y: p.y / d) }
                        onStroke(p, !drag.active)
                        drag.active = true
                    }
                    .onEnded { _ in drag.active = false }
            )
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

final class DragTracker: ObservableObject {
    var active = false
}
