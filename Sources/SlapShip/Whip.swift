import AppKit
import QuartzCore

/// Draws a braided leather bullwhip as a shaded tube and plays the lash.
/// The pose is rebuilt every display frame: a wave rolls from the handle to the tip,
/// so the cracker arrives last, the way a real whip cracks.
final class WhipRenderer: NSObject {
    private struct Frame { var grip: CGPoint; var c1: CGPoint; var c2: CGPoint; var tip: CGPoint }

    /// Normalized keyframes (0...1 of the screen, origin bottom-left). Handle comes in from the bottom-right corner.
    private enum Keys {
        static let butt = CGPoint(x: 1.05, y: -0.08)
        static let frames: [Frame] = [
            Frame(grip: .init(x: 0.94, y: 0.17), c1: .init(x: 0.88, y: 0.48), c2: .init(x: 1.06, y: 0.78), tip: .init(x: 0.97, y: 0.96)),
            Frame(grip: .init(x: 0.87, y: 0.18), c1: .init(x: 0.76, y: 0.58), c2: .init(x: 0.55, y: 0.98), tip: .init(x: 0.34, y: 0.86)),
            Frame(grip: .init(x: 0.82, y: 0.12), c1: .init(x: 0.64, y: 0.42), c2: .init(x: 0.36, y: 0.58), tip: .init(x: 0.13, y: 0.42)),
            Frame(grip: .init(x: 0.84, y: 0.13), c1: .init(x: 0.70, y: 0.30), c2: .init(x: 0.46, y: 0.40), tip: .init(x: 0.24, y: 0.47)),
            Frame(grip: .init(x: 0.88, y: 0.10), c1: .init(x: 0.76, y: 0.20), c2: .init(x: 0.60, y: 0.22), tip: .init(x: 0.42, y: 0.20)),
        ]
        static let crackFrame = 2
        /// How far the tip lags behind the handle, as a share of the lash.
        static let lag: CGFloat = 0.16
        /// Key times, with the crack frame placed so the tip lands on it exactly at `crackAt`.
        static let times: [CGFloat] = {
            let t = CGFloat(WhipOverlay.crackAt / WhipOverlay.duration)
            return [0, 0.17, (t - lag) / (1 - lag), 0.6, 1]
        }()
    }

    static func crackPoint(_ size: CGSize) -> CGPoint { point(Keys.frames[Keys.crackFrame].tip, size) }

    private static let samples = 96
    /// Where the leather thong ends and the hemp fall starts.
    private static let fallStart: CGFloat = 0.88
    /// Light comes from the top-left of the screen.
    private static let light = CGVector(dx: -0.55, dy: 0.83)
    private static let fadeTime: CFTimeInterval = 0.35

    private static var live: [WhipRenderer] = []

    private let size: CGSize
    private let scale: CGFloat
    private let start = CACurrentMediaTime()
    private let root = CALayer()
    private let shadow = CAShapeLayer()
    private let ghosts = [CAShapeLayer(), CAShapeLayer()]
    private let rim = CAShapeLayer(), outline = CAShapeLayer(), base = CAShapeLayer()
    private let core = CAShapeLayer(), mid = CAShapeLayer(), braid = CAShapeLayer(), shine = CAShapeLayer()
    private let fall = CAShapeLayer(), cracker = CAShapeLayer()
    private let handleBase = CAShapeLayer(), handleMid = CAShapeLayer(), handleWrap = CAShapeLayer()
    private let handleShine = CAShapeLayer(), knot = CAShapeLayer()
    private let fibers: [(angle: CGFloat, length: CGFloat, phase: CGFloat)]
    private var link: CADisplayLink?

    static func play(in scene: CALayer, view: NSView, size: CGSize) {
        let whip = WhipRenderer(size: size)
        scene.addSublayer(whip.root)
        whip.render(t: 0)
        let link = view.displayLink(target: whip, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        whip.link = link
        live.append(whip)
    }

    private init(size: CGSize) {
        self.size = size
        scale = max(size.width, size.height) / 1500
        fibers = (0..<7).map { i in
            (angle: CGFloat(i - 3) * 0.22 + .random(in: -0.08...0.08),
             length: .random(in: 9...20),
             phase: .random(in: 0...(2 * .pi)))
        }
        super.init()
        setUpLayers()
    }

    private func setUpLayers() {
        root.frame = CGRect(origin: .zero, size: size)

        // One soft shadow for the whole whip, cast down-right onto the screen.
        shadow.fillColor = nil
        shadow.shadowColor = NSColor.black.cgColor
        shadow.shadowOpacity = 0.42
        shadow.shadowRadius = 9 * scale
        shadow.shadowOffset = CGSize(width: 12 * scale, height: -18 * scale)
        root.addSublayer(shadow)

        for (i, ghost) in ghosts.enumerated() {
            ghost.fillColor = Self.rgb(0.45, 0.25, 0.11, i == 0 ? 0.22 : 0.1)
            root.addSublayer(ghost)
        }

        // Handle: darker, thicker leather, diamond-plaited.
        handleBase.fillColor = Self.rgb(0.13, 0.06, 0.025)
        handleMid.fillColor = Self.rgb(0.30, 0.15, 0.07)
        handleWrap.strokeColor = Self.rgb(0.07, 0.03, 0.01, 0.65)
        handleWrap.fillColor = nil
        handleWrap.lineWidth = 1.4 * scale
        handleWrap.lineCap = .round
        handleShine.fillColor = Self.rgb(0.80, 0.60, 0.42, 0.5)
        knot.fillColor = Self.rgb(0.22, 0.11, 0.05)
        knot.strokeColor = Self.rgb(0.07, 0.03, 0.01)
        knot.lineWidth = 1.5 * scale
        knot.shadowColor = NSColor.black.cgColor
        knot.shadowOpacity = 0.35
        knot.shadowRadius = 2 * scale
        knot.shadowOffset = CGSize(width: 1 * scale, height: -2 * scale)

        // Thong: a pale rim keeps it visible on dark screens, the outline on light ones.
        rim.fillColor = Self.rgb(1, 0.95, 0.85, 0.16)
        outline.fillColor = Self.rgb(0.12, 0.06, 0.025)
        base.fillColor = Self.rgb(0.45, 0.25, 0.11)
        core.fillColor = Self.rgb(0.10, 0.05, 0.02, 0.35)
        mid.fillColor = Self.rgb(0.66, 0.41, 0.20)
        braid.strokeColor = Self.rgb(0.15, 0.07, 0.03, 0.6)
        braid.fillColor = nil
        braid.lineCap = .round
        braid.lineJoin = .round
        shine.fillColor = Self.rgb(1, 0.86, 0.64, 0.7)

        fall.strokeColor = Self.rgb(0.80, 0.72, 0.55)
        fall.fillColor = nil
        fall.lineWidth = 2.4 * scale
        fall.lineCap = .round
        cracker.strokeColor = Self.rgb(0.96, 0.93, 0.84, 0.9)
        cracker.fillColor = nil
        cracker.lineWidth = 1.1 * scale
        cracker.lineCap = .round

        for layer in [handleBase, handleMid, handleWrap, handleShine,
                      rim, outline, base, core, mid, braid, shine, fall, cracker, knot] {
            root.addSublayer(layer)
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        let elapsed = CACurrentMediaTime() - start
        let total = WhipOverlay.duration
        if elapsed > total + Self.fadeTime {
            link.invalidate()
            root.removeFromSuperlayer()
            Self.live.removeAll { $0 === self }
            return
        }
        render(t: min(CGFloat(elapsed / total), 1))
        if elapsed > total {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            root.opacity = Float(1 - (elapsed - total) / Self.fadeTime)
            CATransaction.commit()
        }
    }

    // MARK: Pose

    private struct Spine { var points: [CGPoint]; var normals: [CGPoint] }

    /// Keyframe pose at `tau`, Catmull-Rom through the frames so velocity stays smooth.
    private func frame(at tau: CGFloat) -> Frame {
        let f = Keys.frames, times = Keys.times
        var k = 0
        while k < times.count - 2 && tau > times[k + 1] { k += 1 }
        let u = max(0, min(1, (tau - times[k]) / (times[k + 1] - times[k])))
        let p0 = f[max(k - 1, 0)], p1 = f[k], p2 = f[k + 1], p3 = f[min(k + 2, f.count - 1)]
        func cr(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) -> CGPoint {
            let u2 = u * u, u3 = u2 * u
            func axis(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat) -> CGFloat {
                0.5 * (2 * b + (c - a) * u + (2 * a - 5 * b + 4 * c - d) * u2 + (3 * b - a - 3 * c + d) * u3)
            }
            return CGPoint(x: axis(a.x, b.x, c.x, d.x), y: axis(a.y, b.y, c.y, d.y))
        }
        return Frame(grip: cr(p0.grip, p1.grip, p2.grip, p3.grip), c1: cr(p0.c1, p1.c1, p2.c1, p3.c1),
                     c2: cr(p0.c2, p1.c2, p2.c2, p3.c2), tip: cr(p0.tip, p1.tip, p2.tip, p3.tip))
    }

    /// The lash centerline at time `t`. Each point along the lash runs a little behind the one before it.
    private func spine(t: CGFloat) -> Spine {
        let n = Self.samples
        var points = (0...n).map { i -> CGPoint in
            let s = CGFloat(i) / CGFloat(n)
            let tau = max(0, min(1, (t - Keys.lag * s) / (1 - Keys.lag)))
            let f = frame(at: tau)
            let m = 1 - s
            let a = m * m * m, b = 3 * m * m * s, c = 3 * m * s * s, d = s * s * s
            return Self.point(CGPoint(x: a * f.grip.x + b * f.c1.x + c * f.c2.x + d * f.tip.x,
                                      y: a * f.grip.y + b * f.c1.y + c * f.c2.y + d * f.tip.y), size)
        }
        // A small ripple travelling toward the tip, dying out once the lash has landed.
        let normals0 = Self.normals(points)
        let amp = 14 * scale * max(0, 1 - t * 1.3)
        for i in points.indices {
            let s = CGFloat(i) / CGFloat(n)
            let r = amp * s * sin(2 * .pi * (s * 1.6 - t * 3.2))
            points[i] = CGPoint(x: points[i].x + normals0[i].x * r, y: points[i].y + normals0[i].y * r)
        }
        return Spine(points: points, normals: Self.normals(points))
    }

    private static func normals(_ p: [CGPoint]) -> [CGPoint] {
        p.indices.map { i in
            let a = p[max(i - 1, 0)], b = p[min(i + 1, p.count - 1)]
            let dx = b.x - a.x, dy = b.y - a.y
            let len = max(sqrt(dx * dx + dy * dy), 0.0001)
            return CGPoint(x: -dy / len, y: dx / len)
        }
    }

    /// Thong thickness at `s`, tapering from the grip toward the fall.
    private func width(_ s: CGFloat) -> CGFloat {
        scale * (15 * pow(max(1 - s / Self.fallStart, 0), 1.2) + 2.6)
    }

    // MARK: Drawing

    private func render(t: CGFloat) {
        let lash = spine(t: t)
        let end = Int(CGFloat(Self.samples) * Self.fallStart)
        let widths = (0...end).map { width(CGFloat($0) / CGFloat(Self.samples)) }
        let lit = (0...end).map { i in lash.normals[i].x * Self.light.dx + lash.normals[i].y * Self.light.dy }

        let grip = lash.points[0]
        let butt = Self.point(Keys.butt, size)
        let handle = Self.line(from: butt, to: grip, count: 12)
        let handleWidths = (0..<handle.points.count).map { i in scale * (36 - 9 * CGFloat(i) / 11) }
        let handleLit = handle.normals.map { $0.x * Self.light.dx + $0.y * Self.light.dy }

        func thong(_ f: CGFloat, extra: CGFloat = 0, shift: CGFloat = 0) -> CGPath {
            ribbon(lash, upTo: end, width: { widths[$0] * f + extra * self.scale }, offset: { shift * widths[$0] * lit[$0] })
        }
        func handleRibbon(_ f: CGFloat, shift: CGFloat = 0) -> CGPath {
            ribbon(handle, upTo: handle.points.count - 1, width: { handleWidths[$0] * f }, offset: { shift * handleWidths[$0] * handleLit[$0] })
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let silhouette = CGMutablePath()
        silhouette.addPath(thong(1, extra: 2.5))
        silhouette.addPath(handleRibbon(1))
        shadow.shadowPath = silhouette

        for (i, ghost) in ghosts.enumerated() {
            let past = spine(t: max(0, t - 0.035 * CGFloat(i + 1)))
            ghost.path = ribbon(past, upTo: end, width: { widths[$0] * 1.1 }, offset: { _ in 0 })
            ghost.isHidden = t <= 0 || t >= 1
        }

        handleBase.path = handleRibbon(1)
        handleMid.path = handleRibbon(0.62, shift: 0.12)
        handleShine.path = handleRibbon(0.16, shift: 0.3)
        handleWrap.path = plait(handle, upTo: handle.points.count - 1, widths: handleWidths, spacing: 13 * scale, diamonds: true)

        rim.path = thong(1, extra: 6)
        outline.path = thong(1, extra: 2.5)
        base.path = thong(1)
        core.path = thong(0.3, shift: -0.3)
        mid.path = thong(0.6, shift: 0.14)
        braid.path = plait(lash, upTo: end, widths: widths, spacing: nil, diamonds: false)
        braid.lineWidth = 1.1 * scale
        shine.path = thong(0.17, shift: 0.3)

        let fallPath = CGMutablePath()
        fallPath.addLines(between: Array(lash.points[end...]))
        fall.path = fallPath
        cracker.path = crackerPath(lash, t: t)

        let swell = 11 * scale
        knot.path = CGPath(ellipseIn: CGRect(x: grip.x - swell, y: grip.y - swell, width: 2 * swell, height: 2 * swell), transform: nil)

        CATransaction.commit()
    }

    /// Closed outline of a strip that follows the spine, `offset` slides it along the normal.
    private func ribbon(_ spine: Spine, upTo end: Int, width: (Int) -> CGFloat, offset: (Int) -> CGFloat) -> CGPath {
        var left: [CGPoint] = [], right: [CGPoint] = []
        for i in 0...end {
            let p = spine.points[i], n = spine.normals[i]
            let half = width(i) / 2, o = offset(i)
            left.append(CGPoint(x: p.x + n.x * (o + half), y: p.y + n.y * (o + half)))
            right.append(CGPoint(x: p.x + n.x * (o - half), y: p.y + n.y * (o - half)))
        }
        let path = CGMutablePath()
        path.addLines(between: left + right.reversed())
        path.closeSubpath()
        // Round caps so the strip ends don't look cut.
        for i in [0, end] {
            let r = width(i) / 2, o = offset(i), p = spine.points[i], n = spine.normals[i]
            let c = CGPoint(x: p.x + n.x * o, y: p.y + n.y * o)
            path.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        }
        return path
    }

    /// Plaited leather: chevrons along the thong, diamonds on the handle.
    private func plait(_ spine: Spine, upTo end: Int, widths: [CGFloat], spacing: CGFloat?, diamonds: Bool) -> CGPath {
        let path = CGMutablePath()
        func edge(_ i: Int, _ side: CGFloat) -> CGPoint {
            let p = spine.points[i], n = spine.normals[i], h = widths[i] * 0.42 * side
            return CGPoint(x: p.x + n.x * h, y: p.y + n.y * h)
        }
        var i = 0
        while i < end {
            let step = spacing ?? max(widths[i] * 0.9, 4 * scale)
            var j = i, run: CGFloat = 0
            while j < end && run < step {
                let a = spine.points[j], b = spine.points[j + 1]
                run += hypot(b.x - a.x, b.y - a.y)
                j += 1
            }
            if diamonds {
                path.move(to: edge(i, 1)); path.addLine(to: edge(j, -1))
                path.move(to: edge(i, -1)); path.addLine(to: edge(j, 1))
            } else {
                let c = spine.points[j]
                path.move(to: edge(i, 1)); path.addLine(to: c); path.addLine(to: edge(i, -1))
            }
            i = max(j, i + 1)
        }
        return path
    }

    /// Frayed hemp fibers flaring out of the tip, they spread wider as the tip snaps.
    private func crackerPath(_ spine: Spine, t: CGFloat) -> CGPath {
        let n = spine.points.count
        let tip = spine.points[n - 1], prev = spine.points[n - 4]
        let heading = atan2(tip.y - prev.y, tip.x - prev.x)
        let crack = CGFloat(WhipOverlay.crackAt / WhipOverlay.duration)
        let flare = 1 + 1.4 * max(0, 1 - abs(t - crack) * 6)
        let path = CGMutablePath()
        for f in fibers {
            let a = heading + f.angle * flare + 0.08 * sin(f.phase + t * 40)
            let len = f.length * scale
            let mid = CGPoint(x: tip.x + cos(a - 0.1) * len * 0.5, y: tip.y + sin(a - 0.1) * len * 0.5)
            path.move(to: tip)
            path.addQuadCurve(to: CGPoint(x: tip.x + cos(a) * len, y: tip.y + sin(a) * len), control: mid)
        }
        return path
    }

    // MARK: Helpers

    private static func line(from a: CGPoint, to b: CGPoint, count: Int) -> Spine {
        let points = (0..<count).map { i -> CGPoint in
            let u = CGFloat(i) / CGFloat(count - 1)
            return CGPoint(x: a.x + (b.x - a.x) * u, y: a.y + (b.y - a.y) * u)
        }
        return Spine(points: points, normals: normals(points))
    }

    private static func point(_ p: CGPoint, _ size: CGSize) -> CGPoint {
        CGPoint(x: p.x * size.width, y: p.y * size.height)
    }

    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
        NSColor(calibratedRed: r, green: g, blue: b, alpha: a).cgColor
    }
}
