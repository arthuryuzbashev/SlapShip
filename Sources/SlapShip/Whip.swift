import AppKit
import QuartzCore

/// A black braided bullwhip on a rope simulation with gravity. The arm drives a choreographed
/// strike, then lets go and the lash falls. Everything is simulated up front and played back
/// so the crack lands on the sound.
final class WhipRenderer: NSObject {
    // MARK: Simulation

    /// The strike itself is choreographed (normalized 0...1 of the screen, origin bottom-left):
    /// a wave rolls from the handle to the tip, so the tip arrives last. The rope physics only
    /// gets pulled toward this shape while the arm drives it, before and after that gravity owns it.
    private struct Frame { var grip: CGPoint; var c1: CGPoint; var c2: CGPoint; var tip: CGPoint }

    private enum Strike {
        static let frames: [Frame] = [
            Frame(grip: .init(x: 0.94, y: 0.17), c1: .init(x: 0.88, y: 0.48), c2: .init(x: 1.06, y: 0.78), tip: .init(x: 0.97, y: 0.96)),
            Frame(grip: .init(x: 0.87, y: 0.18), c1: .init(x: 0.76, y: 0.58), c2: .init(x: 0.55, y: 0.98), tip: .init(x: 0.34, y: 0.86)),
            Frame(grip: .init(x: 0.82, y: 0.12), c1: .init(x: 0.64, y: 0.42), c2: .init(x: 0.36, y: 0.58), tip: .init(x: 0.13, y: 0.42)),
            Frame(grip: .init(x: 0.84, y: 0.13), c1: .init(x: 0.70, y: 0.30), c2: .init(x: 0.46, y: 0.40), tip: .init(x: 0.24, y: 0.47)),
        ]
        static let crackFrame = 2
        /// The arm comes in from the bottom-right corner before the strike starts.
        static let entry = CGPoint(x: 1.02, y: -0.12)
        static let lift: Double = 0.08
        static let duration: Double = 0.24
        /// How far the tip lags behind the handle, as a share of the lash.
        static let lag: CGFloat = 0.18
        /// Strike-local time of the crack.
        static let crack: Double = 0.12
        static let times: [CGFloat] = {
            let c = CGFloat(crack / duration)
            return [0, (c - lag) / (1 - lag) * 0.45, (c - lag) / (1 - lag), 1]
        }()
        /// Where the arm settles after the crack: the handle stands up straight and the lash
        /// arcs out of its top and hangs down beside it.
        static let rest = CGPoint(x: 0.8, y: 1.15)
        static let restAngle: CGFloat = 94
        static let settle: Double = 0.6
    }

    private static let links = 40
    private static let step: Double = 1.0 / 1200
    private static let iterations = 16
    /// Frames kept for playback, every `keepEvery` steps (240 per second).
    private static let keepEvery = 5
    private static let simLength: Double = 3.2
    /// How long the lash stays on screen after the crack, and the fade at the end.
    private static let linger: Double = 2.0
    private static let fadeTime: Double = 0.3
    /// Seconds from the lash until the whip is gone.
    static var lifetime: Double { WhipOverlay.crackAt + linger }

    private struct Pose { var points: [CGPoint]; var grip: CGPoint; var dir: CGPoint }

    /// The whole whip is drawn at this share of its screen-filling size, anchored to the bottom-right corner.
    private static let shrink: CGFloat = 0.45
    /// Moved left off the corner by this share of the screen width.
    private static let shift: CGFloat = 0.4

    private static func point(_ p: CGPoint, _ size: CGSize) -> CGPoint {
        CGPoint(x: size.width * (1 - shift - (1 - p.x) * shrink), y: size.height * p.y * shrink)
    }

    private static func lerp(_ a: CGPoint, _ b: CGPoint, _ u: CGFloat) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * u, y: a.y + (b.y - a.y) * u)
    }

    /// Keyframe pose at strike progress `tau`, Catmull-Rom through the frames so velocity stays smooth.
    private static func strikeFrame(at tau: CGFloat) -> Frame {
        let f = Strike.frames, times = Strike.times
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

    /// Choreographed lash centerline at strike-local time `t`, densely sampled.
    private static func strikeCurve(at t: Double, size: CGSize) -> [CGPoint] {
        let progress = CGFloat(t / Strike.duration)
        let n = links * 4
        return (0...n).map { i in
            let s = CGFloat(i) / CGFloat(n)
            let tau = max(0, min(1, (progress - Strike.lag * s) / (1 - Strike.lag)))
            let f = strikeFrame(at: tau)
            let m = 1 - s
            let a = m * m * m, b = 3 * m * m * s, c = 3 * m * s * s, d = s * s * s
            return point(CGPoint(x: a * f.grip.x + b * f.c1.x + c * f.c2.x + d * f.tip.x,
                                 y: a * f.grip.y + b * f.c1.y + c * f.c2.y + d * f.tip.y), size)
        }
    }

    /// One target per rope point, spaced exactly one link apart along the curve so the
    /// choreography never fights the rope's length (that fight shows up as zigzags).
    private static func strikeShape(at t: Double, size: CGSize, link: CGFloat) -> [CGPoint] {
        let curve = strikeCurve(at: t, size: size)
        var out = [curve[0]]
        var j = 0, carry: CGFloat = 0
        for _ in 1...links {
            var need = link
            while true {
                if j >= curve.count - 1 {
                    // Curve shorter than the rope: keep going straight past the end.
                    let d = direction(curve[curve.count - 2], curve[curve.count - 1])
                    let last = out[out.count - 1]
                    out.append(CGPoint(x: last.x + d.x * link, y: last.y + d.y * link))
                    break
                }
                let a = curve[j], b = curve[j + 1]
                let seg = hypot(b.x - a.x, b.y - a.y) - carry
                if seg >= need {
                    carry += need
                    let u = carry / max(hypot(b.x - a.x, b.y - a.y), 0.0001)
                    out.append(lerp(a, b, u))
                    break
                }
                need -= seg
                carry = 0
                j += 1
            }
        }
        return out
    }

    /// Resting shape of the held whip: the thong rises a little out of the handle, turns over in
    /// a round arc and hangs straight down.
    private static func hangShape(grip: CGPoint, heading: CGFloat, link: CGFloat) -> [CGPoint] {
        let rise = 3, arc = 10
        var turn = -.pi / 2 - heading
        while turn <= 0 { turn += 2 * .pi }
        while turn > 2 * .pi { turn -= 2 * .pi }
        var out = [grip], a = heading
        for i in 1...links {
            if i > rise && i <= rise + arc { a += turn / CGFloat(arc) }
            let last = out[out.count - 1]
            out.append(CGPoint(x: last.x + cos(a) * link, y: last.y + sin(a) * link))
        }
        return out
    }

    private static func length(_ p: [CGPoint]) -> CGFloat {
        zip(p, p.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
    }

    private static func direction(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        let len = max(hypot(b.x - a.x, b.y - a.y), 0.0001)
        return CGPoint(x: (b.x - a.x) / len, y: (b.y - a.y) / len)
    }

    /// Runs the whole lash up front. Returns the kept frames and the time of the crack.
    /// `from` is where an already shown whip is right now, a repeat strike starts from there.
    private static func simulate(size: CGSize, from: Pose? = nil) -> (frames: [Pose], peak: Double) {
        let h = size.height
        let rest = length(strikeCurve(at: Strike.crack, size: size)) / CGFloat(links)
        let gravity = 2.6 * h * shrink
        // Once it's hanging, true-to-scale gravity, so the lash drops instead of floating down.
        let hang = 2.6 * h
        // Heavier near the grip, light at the tip, so the tip whips around and the end drapes.
        let invMass: [CGFloat] = (0...links).map { i in
            let s = CGFloat(i) / CGFloat(links)
            return 1 / (pow(1 - 0.75 * s, 2) + 0.08)
        }

        let first = strikeShape(at: 0, size: size, link: rest)
        let entry = point(Strike.entry, size)
        let entryDir = CGPoint(x: -0.17, y: 0.98)
        let strikeStart = Strike.lift
        // The arm lets go of the choreography just after the crack, from there it's momentum and gravity.
        let release = strikeStart + Strike.crack + 0.03
        let restGrip = point(Strike.rest, size)
        let restAngle = Strike.restAngle * .pi / 180
        let floor = 0.015 * h

        // Start hanging straight down from the hand, below the screen.
        var p = from?.points ?? (0...links).map { CGPoint(x: entry.x, y: entry.y - rest * CGFloat($0)) }
        var prev = p
        var frames: [Pose] = []
        let steps = Int(simLength / step)
        let dt2 = CGFloat(step * step)

        for n in 0..<steps {
            let t = Double(n) * step
            var grip: CGPoint, dir: CGPoint, target: [CGPoint]? = nil, pull: CGFloat = 0
            if t < strikeStart {
                // Arm lifts in from the corner, dragging the hanging lash up with it.
                let u = CGFloat(t / strikeStart), e = 1 - (1 - u) * (1 - u)
                grip = lerp(from?.grip ?? entry, first[0], e)
                dir = direction(.zero, lerp(from?.dir ?? entryDir, direction(first[0], first[1]), e))
                if let from {
                    // Same whip again: the arm swings the hanging lash back into the wind-up.
                    target = zip(from.points, first).map { lerp($0, $1, e) }
                    pull = 0.1 * e
                }
            } else if t < release {
                let local = t - strikeStart
                let shape = strikeShape(at: local, size: size, link: rest)
                grip = shape[0]
                dir = direction(shape[0], shape[1])
                target = shape
                // Ease the arm's grip on the lash in, hold it through the crack, then let go.
                let fadeIn = min(1, local / 0.05), fadeOut = max(0, min(1, (release - t) / 0.03))
                pull = CGFloat(min(fadeIn, fadeOut)) * 0.1
            } else {
                let u = CGFloat(min(1, (t - release) / Strike.settle)), e = u * u * (3 - 2 * u)
                let last = strikeShape(at: release - strikeStart, size: size, link: rest)
                grip = lerp(last[0], restGrip, e)
                // Turn by angle, a straight blend of two near-opposite directions flips the handle.
                let from = atan2(last[1].y - last[0].y, last[1].x - last[0].x)
                var turn = restAngle - from
                while turn > .pi { turn -= 2 * .pi }
                while turn < -.pi { turn += 2 * .pi }
                let a = from + turn * e
                dir = CGPoint(x: cos(a), y: sin(a))
                // Herd the loose lash into the hanging pose: out of the top of the handle, over in a
                // round arc, then straight down. Gravity and momentum still move it,
                // this only keeps it from crumpling or flying around.
                let since = t - release
                target = hangShape(grip: grip, heading: a, link: rest)
                let ramp = CGFloat(max(0, min(1, (since - 0.08) / 0.5)))
                pull = ramp * ramp * (3 - 2 * ramp) * 0.03
            }

            // Air drag kicks in right after the crack so the lash doesn't flail around, it just
            // follows the arm up and hangs.
            let since = t - release
            // Past that it is heavily damped, the lash eases into its hang instead of springing
            // around it like jelly.
            let drag: CGFloat = since < 0.05 ? 0.9998 : since < 0.25 ? 0.997 : 0.988
            let grounded = t >= release
            for i in 1...links {
                var v = CGPoint(x: (p[i].x - prev[i].x) * drag, y: (p[i].y - prev[i].y) * drag)
                if grounded && p[i].y <= floor + 0.5 { v.x *= 0.9 }
                prev[i] = p[i]
                p[i] = CGPoint(x: p[i].x + v.x, y: p[i].y + v.y - (grounded ? hang : gravity) * dt2)
                if let target {
                    p[i] = lerp(p[i], target[i], pull)
                }
            }
            prev[0] = p[0]
            p[0] = grip

            // Leather is stiff: each point leans toward the line through its neighbours, more
            // near the handle. Once per step, so gravity still bends the lash. Also irons out buckling.
            for i in 2..<links {
                let s = CGFloat(i) / CGFloat(links)
                // After the crack the leather goes slack, it hangs instead of standing up.
                let k = grounded ? 0.02 * (1 - s) * (1 - s) + 0.005 : 0.2 * (1 - s) * (1 - s) + 0.08
                let mid = CGPoint(x: (p[i - 1].x + p[i + 1].x) / 2, y: (p[i - 1].y + p[i + 1].y) / 2)
                p[i] = lerp(p[i], mid, k)
            }

            for _ in 0..<iterations {
                // The thong leaves the handle along its axis, so a turn of the wrist turns the lash.
                p[1] = CGPoint(x: grip.x + dir.x * rest, y: grip.y + dir.y * rest)
                for i in 0..<links {
                    let w0 = i < 2 ? 0 : invMass[i], w1 = invMass[i + 1]
                    let dx = p[i + 1].x - p[i].x, dy = p[i + 1].y - p[i].y
                    let len = max(sqrt(dx * dx + dy * dy), 0.0001)
                    let c = (len - rest) / len / (w0 + w1)
                    p[i].x += dx * c * w0; p[i].y += dy * c * w0
                    p[i + 1].x -= dx * c * w1; p[i + 1].y -= dy * c * w1
                }
                // The first part of the thong is stiff, it bends out of the handle gradually
                // instead of folding at the grip.
                if !grounded {
                    for i in 2...15 {
                        let d = direction(p[i - 2], p[i - 1])
                        let target = CGPoint(x: p[i - 1].x + d.x * rest, y: p[i - 1].y + d.y * rest)
                        let u = 1 - CGFloat(i - 2) / 14
                        p[i] = lerp(p[i], target, 0.18 * u * u)
                    }
                }
                // The bottom edge of the screen is the floor the lash lands on.
                if grounded {
                    for i in 1...links where p[i].y < floor { p[i].y = floor }
                }
            }

            if n % keepEvery == 0 { frames.append(Pose(points: p, grip: grip, dir: dir)) }
        }
        return (frames, strikeStart + Strike.crack)
    }

    // MARK: Playback

    private static var live: [WhipRenderer] = []

    private let size: CGSize
    private let scale: CGFloat
    private var frames: [Pose]
    /// Simulation time shown at the first displayed frame.
    private var offset: Double
    private var peak: Double
    private var start = CACurrentMediaTime()
    private var link: CADisplayLink?
    /// Still on screen, so it can strike again.
    var isAlive: Bool { link != nil }

    private let root = CALayer()
    private let shadow = CAShapeLayer()
    private let ghosts = [CAShapeLayer(), CAShapeLayer()]
    private let rim = CAShapeLayer(), outline = CAShapeLayer(), base = CAShapeLayer()
    private let core = CAShapeLayer(), mid = CAShapeLayer(), braid = CAShapeLayer(), shine = CAShapeLayer()
    private let fall = CAShapeLayer(), cracker = CAShapeLayer()
    private let handleBase = CAShapeLayer(), handleMid = CAShapeLayer(), handleWrap = CAShapeLayer()
    private let handleShine = CAShapeLayer(), knot = CAShapeLayer(), knotShine = CAShapeLayer(), knotBands = CAShapeLayer()
    private let pommel = CAShapeLayer(), pommelShine = CAShapeLayer()
    private let fibers: [(angle: CGFloat, length: CGFloat, phase: CGFloat)]

    /// Starts the lash and returns the whip, where the tip cracks and when, on the media clock.
    static func play(in scene: CALayer, view: NSView, size: CGSize) -> (whip: WhipRenderer, tip: CGPoint, time: CFTimeInterval) {
        let whip = WhipRenderer(size: size)
        scene.addSublayer(whip.root)
        whip.render(at: whip.offset)
        let link = view.displayLink(target: whip, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        whip.link = link
        live.append(whip)
        return (whip, whip.pose(at: whip.peak).points.last ?? .zero, whip.start + WhipOverlay.crackAt)
    }

    /// Strikes again with this same whip, starting from wherever it is right now.
    func restrike() -> (tip: CGPoint, time: CFTimeInterval) {
        let now = CACurrentMediaTime()
        let sim = Self.simulate(size: size, from: pose(at: offset + now - start))
        frames = sim.frames
        peak = sim.peak
        offset = sim.peak - WhipOverlay.crackAt
        start = now
        render(at: offset)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.opacity = 1
        CATransaction.commit()
        return (pose(at: peak).points.last ?? .zero, start + WhipOverlay.crackAt)
    }

    private init(size: CGSize) {
        self.size = size
        scale = max(size.width, size.height) / 1500 * Self.shrink
        let sim = Self.simulate(size: size)
        frames = sim.frames
        peak = sim.peak
        offset = sim.peak - WhipOverlay.crackAt
        fibers = (0..<9).map { i in
            (angle: CGFloat(i - 4) * 0.2 + .random(in: -0.07...0.07),
             length: .random(in: 16...32),
             phase: .random(in: 0...(2 * .pi)))
        }
        super.init()
        setUpLayers()
    }

    private func pose(at t: Double) -> Pose {
        let x = max(0, t) / (Self.step * Double(Self.keepEvery))
        let i = min(Int(x), frames.count - 2), u = CGFloat(min(1, x - Double(i)))
        let a = frames[i], b = frames[i + 1]
        func mix(_ p: CGPoint, _ q: CGPoint) -> CGPoint { CGPoint(x: p.x + (q.x - p.x) * u, y: p.y + (q.y - p.y) * u) }
        return Pose(points: zip(a.points, b.points).map(mix), grip: mix(a.grip, b.grip), dir: mix(a.dir, b.dir))
    }

    @objc private func tick(_ link: CADisplayLink) {
        let elapsed = CACurrentMediaTime() - start
        let end = WhipOverlay.crackAt + Self.linger
        if elapsed > end {
            link.invalidate()
            self.link = nil
            root.removeFromSuperlayer()
            Self.live.removeAll { $0 === self }
            return
        }
        render(at: offset + elapsed)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.opacity = Float(max(0, min(1, (end - elapsed) / Self.fadeTime)))
        CATransaction.commit()
    }

    // MARK: Look

    private func setUpLayers() {
        root.frame = CGRect(origin: .zero, size: size)

        shadow.fillColor = nil
        shadow.shadowColor = NSColor.black.cgColor
        shadow.shadowOpacity = 0.5
        shadow.shadowRadius = 10 * scale
        shadow.shadowOffset = CGSize(width: 14 * scale, height: -22 * scale)
        root.addSublayer(shadow)

        for (i, ghost) in ghosts.enumerated() {
            ghost.fillColor = Self.gray(0.1, i == 0 ? 0.28 : 0.13)
            root.addSublayer(ghost)
        }

        // Black leather: almost no diffuse color, the shape comes from cool glossy highlights.
        handleBase.fillColor = Self.gray(0.03)
        handleMid.fillColor = Self.gray(0.11)
        handleWrap.strokeColor = Self.gray(0.42, 0.55)
        handleWrap.fillColor = nil
        handleWrap.lineCap = .round
        handleShine.fillColor = Self.rgb(0.82, 0.86, 0.95, 0.55)
        pommel.fillColor = Self.gray(0.05)
        pommel.strokeColor = Self.gray(0.0)
        pommelShine.fillColor = Self.rgb(0.85, 0.88, 0.96, 0.6)
        knot.fillColor = Self.gray(0.06)
        knot.strokeColor = Self.gray(0.0)
        knotShine.fillColor = Self.rgb(0.82, 0.86, 0.95, 0.5)
        knotBands.strokeColor = Self.gray(0.4, 0.6)
        knotBands.fillColor = nil
        knotBands.lineCap = .round

        rim.fillColor = Self.gray(1, 0.2)
        outline.fillColor = Self.gray(0)
        base.fillColor = Self.gray(0.06)
        core.fillColor = Self.gray(0, 0.6)
        mid.fillColor = Self.gray(0.17)
        braid.strokeColor = Self.gray(0.5, 0.45)
        braid.fillColor = nil
        braid.lineCap = .round
        braid.lineJoin = .round
        shine.fillColor = Self.rgb(0.86, 0.9, 1, 0.62)

        fall.strokeColor = Self.gray(0.16)
        fall.fillColor = nil
        fall.lineCap = .round
        cracker.strokeColor = Self.gray(0.93, 0.95)
        cracker.fillColor = nil
        cracker.lineCap = .round

        for layer in [handleBase, handleMid, handleWrap, handleShine, pommel, pommelShine,
                      rim, outline, base, core, mid, braid, shine, fall, cracker, knot, knotShine, knotBands] {
            root.addSublayer(layer)
        }
    }

    private struct Spine { var points: [CGPoint]; var normals: [CGPoint] }

    private static let fallStart: CGFloat = 0.86
    private static let light = CGPoint(x: -0.55, y: 0.83)

    private func width(_ s: CGFloat) -> CGFloat {
        scale * (19 * pow(max(1 - s / Self.fallStart, 0), 1.15) + 3.2)
    }

    private func render(at t: Double) {
        let pose = pose(at: t)
        let lash = Self.smooth(pose.points)
        let count = lash.points.count
        let end = Int(CGFloat(count - 1) * Self.fallStart)
        let widths = (0...end).map { width(CGFloat($0) / CGFloat(count - 1)) }
        let lit = (0...end).map { Self.dot(lash.normals[$0], Self.light) }

        // Handle: a rigid, slightly fatter-at-the-butt cylinder behind the grip.
        let handleLength = 0.2 * size.height * Self.shrink
        let butt = CGPoint(x: pose.grip.x - pose.dir.x * handleLength, y: pose.grip.y - pose.dir.y * handleLength)
        let handle = Self.line(from: butt, to: pose.grip, count: 12)
        let handleWidths = (0..<12).map { scale * (30 - 6 * CGFloat($0) / 11) }
        let handleLit = handle.normals.map { Self.dot($0, Self.light) }

        func thong(_ f: CGFloat, extra: CGFloat = 0, shift: CGFloat = 0) -> CGPath {
            ribbon(lash, upTo: end, width: { widths[$0] * f + extra * self.scale }, offset: { shift * widths[$0] * lit[$0] })
        }
        func handleRibbon(_ f: CGFloat, shift: CGFloat = 0) -> CGPath {
            ribbon(handle, upTo: 11, width: { handleWidths[$0] * f }, offset: { shift * handleWidths[$0] * handleLit[$0] })
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let silhouette = CGMutablePath()
        silhouette.addPath(thong(1, extra: 2.5))
        silhouette.addPath(handleRibbon(1))
        shadow.shadowPath = silhouette

        for (i, ghost) in ghosts.enumerated() {
            let past = Self.smooth(self.pose(at: t - 0.018 * Double(i + 1)).points)
            ghost.path = ribbon(past, upTo: end, width: { widths[$0] * 1.15 }, offset: { _ in 0 })
        }

        handleBase.path = handleRibbon(1)
        handleMid.path = handleRibbon(0.6, shift: 0.12)
        handleShine.path = handleRibbon(0.13, shift: 0.3)
        handleWrap.path = plait(handle, upTo: 11, widths: handleWidths, spacing: 14 * scale, diamonds: true)
        handleWrap.lineWidth = 1.4 * scale

        let pr = handleWidths[0] * 0.62
        pommel.path = CGPath(ellipseIn: CGRect(x: butt.x - pr, y: butt.y - pr, width: 2 * pr, height: 2 * pr), transform: nil)
        pommel.lineWidth = 1.5 * scale
        let ps = CGPoint(x: butt.x + Self.light.x * pr * 0.4, y: butt.y + Self.light.y * pr * 0.4)
        pommelShine.path = CGPath(ellipseIn: CGRect(x: ps.x - pr * 0.3, y: ps.y - pr * 0.3, width: pr * 0.6, height: pr * 0.6), transform: nil)

        rim.path = thong(1, extra: 5)
        outline.path = thong(1, extra: 2.5)
        base.path = thong(1)
        core.path = thong(0.32, shift: -0.3)
        mid.path = thong(0.55, shift: 0.15)
        braid.path = plait(lash, upTo: end, widths: widths, spacing: nil, diamonds: false)
        braid.lineWidth = 1.1 * scale
        shine.path = thong(0.14, shift: 0.3)

        let fallPath = CGMutablePath()
        fallPath.addLines(between: Array(lash.points[end...]))
        fall.path = fallPath
        fall.lineWidth = 3 * scale
        cracker.path = crackerPath(lash, t: t)
        cracker.lineWidth = 1.5 * scale

        // Turk's head knot where the thong leaves the handle.
        let kw = handleWidths[11] * 1.3, kl = kw * 0.85
        let knotSpine = Self.line(from: CGPoint(x: pose.grip.x - pose.dir.x * kl * 0.7, y: pose.grip.y - pose.dir.y * kl * 0.7),
                                  to: CGPoint(x: pose.grip.x + pose.dir.x * kl * 0.3, y: pose.grip.y + pose.dir.y * kl * 0.3), count: 5)
        let knotWidths = (0..<5).map { kw * (1 - 0.18 * abs(CGFloat($0) - 2) / 2) }
        let knotLit = Self.dot(knotSpine.normals[2], Self.light)
        knot.path = ribbon(knotSpine, upTo: 4, width: { knotWidths[$0] }, offset: { _ in 0 })
        knot.lineWidth = 1.5 * scale
        knotShine.path = ribbon(knotSpine, upTo: 4, width: { knotWidths[$0] * 0.16 }, offset: { knotWidths[$0] * 0.28 * knotLit })
        knotBands.path = plait(knotSpine, upTo: 4, widths: knotWidths, spacing: kl * 0.3, diamonds: true)
        knotBands.lineWidth = 1.4 * scale

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
                run += hypot(spine.points[j + 1].x - spine.points[j].x, spine.points[j + 1].y - spine.points[j].y)
                j += 1
            }
            if diamonds {
                path.move(to: edge(i, 1)); path.addLine(to: edge(j, -1))
                path.move(to: edge(i, -1)); path.addLine(to: edge(j, 1))
            } else {
                path.move(to: edge(i, 1)); path.addLine(to: spine.points[j]); path.addLine(to: edge(i, -1))
            }
            i = max(j, i + 1)
        }
        return path
    }

    /// Frayed fibers flaring out of the tip, they burst open at the crack.
    private func crackerPath(_ spine: Spine, t: Double) -> CGPath {
        let n = spine.points.count
        let tip = spine.points[n - 1], prev = spine.points[n - 5]
        let heading = atan2(tip.y - prev.y, tip.x - prev.x)
        let flare = 1 + 1.6 * CGFloat(max(0, 1 - abs(t - peak) * 7))
        let path = CGMutablePath()
        for f in fibers {
            let a = heading + f.angle * flare + 0.1 * sin(f.phase + CGFloat(t) * 40)
            let len = f.length * scale
            let mid = CGPoint(x: tip.x + cos(a - 0.12) * len * 0.5, y: tip.y + sin(a - 0.12) * len * 0.5)
            path.move(to: tip)
            path.addQuadCurve(to: CGPoint(x: tip.x + cos(a) * len, y: tip.y + sin(a) * len), control: mid)
        }
        return path
    }

    // MARK: Helpers

    /// Catmull-Rom through the simulated links, 3 points per link, so the lash bends smoothly.
    private static func smooth(_ p: [CGPoint]) -> Spine {
        var out: [CGPoint] = []
        for i in 0..<(p.count - 1) {
            let a = p[max(i - 1, 0)], b = p[i], c = p[i + 1], d = p[min(i + 2, p.count - 1)]
            for k in 0..<3 {
                let u = CGFloat(k) / 3, u2 = u * u, u3 = u2 * u
                func axis(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat) -> CGFloat {
                    0.5 * (2 * b + (c - a) * u + (2 * a - 5 * b + 4 * c - d) * u2 + (3 * b - a - 3 * c + d) * u3)
                }
                out.append(CGPoint(x: axis(a.x, b.x, c.x, d.x), y: axis(a.y, b.y, c.y, d.y)))
            }
        }
        out.append(p[p.count - 1])
        return Spine(points: out, normals: normals(out))
    }

    private static func normals(_ p: [CGPoint]) -> [CGPoint] {
        p.indices.map { i in
            let a = p[max(i - 1, 0)], b = p[min(i + 1, p.count - 1)]
            let dx = b.x - a.x, dy = b.y - a.y
            let len = max(sqrt(dx * dx + dy * dy), 0.0001)
            return CGPoint(x: -dy / len, y: dx / len)
        }
    }

    private static func line(from a: CGPoint, to b: CGPoint, count: Int) -> Spine {
        let points = (0..<count).map { i -> CGPoint in
            let u = CGFloat(i) / CGFloat(count - 1)
            return CGPoint(x: a.x + (b.x - a.x) * u, y: a.y + (b.y - a.y) * u)
        }
        return Spine(points: points, normals: normals(points))
    }

    private static func dot(_ a: CGPoint, _ b: CGPoint) -> CGFloat { a.x * b.x + a.y * b.y }

    private static func gray(_ w: CGFloat, _ a: CGFloat = 1) -> CGColor {
        NSColor(calibratedWhite: w, alpha: a).cgColor
    }

    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
        NSColor(calibratedRed: r, green: g, blue: b, alpha: a).cgColor
    }
}

