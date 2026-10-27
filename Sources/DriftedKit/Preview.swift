import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Pictures of a drawing from the digital twin (`TableTwin`), before anything is sent. CoreGraphics + ImageIO
/// only, so it works on macOS and iOS.
///
/// - `.sand`: how the table should look afterwards. Grooves are as wide as the ball, so lines closer than
///   about 0.07 table radii merge, just as they do on the table.
/// - `.path`: a thin diagram of the route, with a green dot at the start and a red dot at the end. Use it to
///   check stroke order and the connecting moves.
/// - `gif`: an animation of the ball drawing it (sand style), compressed to a few seconds.
public enum PatternPreview {
    public enum Style: String, Sendable { case sand, path }

    public static func png(_ pattern: SandPattern, size: Int = 512, style: Style = .path, from start: PolarPoint? = nil,
                           lineWidth: CGFloat = 1.5) -> Data? {
        let run = TableTwin.simulate(pattern, from: start)
        guard let canvas = Canvas(size: size) else { return nil }
        canvas.background()
        switch style {
        case .sand:
            canvas.grooves(run.samples[...])
            if let end = run.samples.last { canvas.ball(at: end) }
        case .path:
            canvas.route(run.samples, lineWidth: lineWidth)
        }
        guard let image = canvas.ctx.makeImage() else { return nil }
        return encode([image], type: UTType.png, delays: [])
    }

    /// Animated GIF of the ball drawing the pattern in sand style: `frames` frames over about `seconds`, then a
    /// two-second hold on the finished drawing.
    public static func gif(_ pattern: SandPattern, size: Int = 384, frames: Int = 60, seconds: Double = 6,
                           from start: PolarPoint? = nil) -> Data? {
        let run = TableTwin.simulate(pattern, from: start)
        guard let total = run.samples.last?.t, let canvas = Canvas(size: size) else { return nil }
        let frames = max(2, min(frames, 300))
        canvas.background()
        var images: [CGImage] = []
        var done = 0
        for k in 1...frames {
            let until = total * Double(k) / Double(frames)
            var end = done
            while end < run.samples.count && run.samples[end].t <= until { end += 1 }
            if end > done { canvas.grooves(run.samples[max(0, done - 1)..<end]) }
            done = end
            guard let sand = canvas.ctx.makeImage(), let frame = Canvas(size: size) else { return nil }
            frame.ctx.draw(sand, in: CGRect(x: 0, y: 0, width: size, height: size))
            if done > 0 { frame.ball(at: run.samples[done - 1]) }
            guard let image = frame.ctx.makeImage() else { return nil }
            images.append(image)
        }
        let delay = seconds / Double(frames)
        return encode(images, type: UTType.gif, delays: Array(repeating: delay, count: frames - 1) + [2])
    }

    private static func encode(_ images: [CGImage], type: UTType, delays: [Double]) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, images.count, nil) else { return nil }
        if type == .gif {
            CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        }
        for (i, image) in images.enumerated() {
            let props: CFDictionary? = type == .gif
                ? [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delays[i]]] as CFDictionary : nil
            CGImageDestinationAddImage(dest, image, props)
        }
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    /// A square bitmap with the table disc in the middle; table coordinates (unit disc, +y up) map onto it.
    private final class Canvas {
        let ctx: CGContext
        let size: CGFloat
        let radius: CGFloat
        let centre: CGPoint

        init?(size: Int) {
            guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            self.ctx = ctx
            self.size = CGFloat(size)
            radius = CGFloat(size) / 2 - 4
            centre = CGPoint(x: CGFloat(size) / 2, y: CGFloat(size) / 2)
        }

        func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: centre.x + CGFloat(x) * radius, y: centre.y + CGFloat(y) * radius) }

        func background() {
            ctx.setFillColor(CGColor(red: 0.16, green: 0.16, blue: 0.18, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
            ctx.setFillColor(CGColor(red: 0.93, green: 0.88, blue: 0.78, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: centre.x - radius, y: centre.y - radius, width: 2 * radius, height: 2 * radius))
        }

        /// Ball-width grooves: a shaded trough with a lighter floor, drawn in path order so later grooves cut
        /// through earlier ones. Stroked in chunks: CoreGraphics garbles single very long wide strokes.
        func grooves(_ samples: ArraySlice<TableTwin.Sample>) {
            var start = samples.startIndex
            while start < samples.endIndex - 1 {
                let end = min(start + 1500, samples.endIndex)
                groovesChunk(samples[start..<end])
                start = end - 1
            }
        }

        private func groovesChunk(_ samples: ArraySlice<TableTwin.Sample>) {
            guard let first = samples.first else { return }
            let width = CGFloat(TableTwin.ballDiameter) * radius
            ctx.saveGState()
            ctx.addEllipse(in: CGRect(x: centre.x - radius, y: centre.y - radius, width: 2 * radius, height: 2 * radius))
            ctx.clip()
            ctx.setLineJoin(.round); ctx.setLineCap(.round)
            for (color, w) in [(CGColor(red: 0.74, green: 0.67, blue: 0.56, alpha: 1), width),
                               (CGColor(red: 0.84, green: 0.78, blue: 0.67, alpha: 1), width * 0.45)] {
                ctx.setStrokeColor(color); ctx.setLineWidth(w)
                ctx.move(to: pt(first.x, first.y))
                for s in samples.dropFirst() { ctx.addLine(to: pt(s.x, s.y)) }
                ctx.strokePath()
            }
            ctx.restoreGState()
        }

        func ball(at s: TableTwin.Sample) {
            let d = CGFloat(TableTwin.ballDiameter) * radius, q = pt(s.x, s.y)
            ctx.setFillColor(CGColor(red: 0.55, green: 0.57, blue: 0.6, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: q.x - d / 2, y: q.y - d / 2, width: d, height: d))
            ctx.setFillColor(CGColor(red: 0.85, green: 0.86, blue: 0.88, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: q.x - d / 5, y: q.y + d / 12, width: d / 3, height: d / 3))
        }

        /// Thin route diagram: the move to the start dashed, the drawing solid, start green and end red.
        func route(_ samples: [TableTwin.Sample], lineWidth: CGFloat) {
            guard let first = samples.first else { return }
            ctx.setLineJoin(.round); ctx.setLineCap(.round); ctx.setLineWidth(lineWidth)
            let transit = samples.prefix { !$0.drawing }
            if transit.count > 1 {
                ctx.setStrokeColor(CGColor(red: 0.3, green: 0.4, blue: 0.75, alpha: 1))
                ctx.setLineDash(phase: 0, lengths: [4, 4])
                ctx.move(to: pt(first.x, first.y))
                for s in transit.dropFirst() { ctx.addLine(to: pt(s.x, s.y)) }
                ctx.strokePath()
                ctx.setLineDash(phase: 0, lengths: [])
            }
            let drawn = samples.drop { !$0.drawing }
            guard let start = drawn.first, let end = drawn.last else { return }
            ctx.setStrokeColor(CGColor(red: 0.45, green: 0.37, blue: 0.27, alpha: 1))
            ctx.move(to: pt(start.x, start.y))
            for s in drawn.dropFirst() { ctx.addLine(to: pt(s.x, s.y)) }
            ctx.strokePath()
            for (s, color) in [(start, CGColor(red: 0.1, green: 0.6, blue: 0.2, alpha: 1)),
                               (end, CGColor(red: 0.8, green: 0.15, blue: 0.1, alpha: 1))] {
                ctx.setFillColor(color)
                let q = pt(s.x, s.y); ctx.fillEllipse(in: CGRect(x: q.x - 4, y: q.y - 4, width: 8, height: 8))
            }
        }
    }
}
