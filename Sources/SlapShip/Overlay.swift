import AppKit
import QuartzCore

/// Full-screen, click-through overlay that plays the whip. A slap while it's still on screen
/// strikes again with the same whip instead of bringing in a second one.
final class WhipOverlay {
    private final class Stage {
        let window: NSWindow, root: CALayer, scene: CALayer, whip: WhipRenderer, size: CGSize
        var badge: CALayer?
        var lashes = 0

        init(window: NSWindow, root: CALayer, scene: CALayer, whip: WhipRenderer, size: CGSize) {
            self.window = window; self.root = root; self.scene = scene; self.whip = whip; self.size = size
        }
    }

    private static var stage: Stage?

    static let duration: CFTimeInterval = 0.42
    /// Moment of the crack inside the lash, matches the sound's whoosh length.
    static let crackAt: CFTimeInterval = 0.2

    /// Plays the lash on the screen under the mouse. `pending` is shown in the badge.
    static func lash(force: Double, pending: Int) {
        if let stage, stage.whip.isAlive {
            hit(stage, crack: stage.whip.restrike(), force: force, pending: pending)
            return
        }
        stage?.window.orderOut(nil)
        stage = nil

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let screen else { return }

        let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        window.contentView = view
        window.orderFrontRegardless()

        guard let root = view.layer else { return }
        let size = screen.frame.size
        let scene = CALayer()
        scene.frame = root.bounds
        root.addSublayer(scene)

        let played = WhipRenderer.play(in: scene, view: view, size: size)
        let fresh = Stage(window: window, root: root, scene: scene, whip: played.whip, size: size)
        stage = fresh
        hit(fresh, crack: (played.tip, played.time), force: force, pending: pending)
    }

    private static func hit(_ s: Stage, crack: (tip: CGPoint, time: CFTimeInterval), force: Double, pending: Int) {
        addWelt(to: s.scene, size: s.size, force: force)
        addCrack(to: s.scene, at: crack.tip, begin: crack.time, force: force)
        addShake(to: s.scene, begin: crack.time, force: force)
        s.badge?.removeFromSuperlayer()
        s.badge = addBadge(to: s.root, size: s.size, pending: pending)

        // Only the latest lash closes the window, an earlier timer must not cut the new strike short.
        s.lashes += 1
        let lashes = s.lashes
        DispatchQueue.main.asyncAfter(deadline: .now() + max(1.9, WhipRenderer.lifetime + 0.1)) {
            guard stage === s, s.lashes == lashes else { return }
            s.window.orderOut(nil)
            stage = nil
        }
    }

    // MARK: Crack, shake, welt

    private static func addCrack(to scene: CALayer, at tip: CGPoint, begin: CFTimeInterval, force: Double) {
        let big = 1 + force

        // A real crack is a tiny sonic boom: a quick pop of light and a thin pressure ring, not a fireball.
        let flash = CAShapeLayer()
        let r: CGFloat = 7
        flash.path = CGPath(ellipseIn: CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r), transform: nil)
        flash.position = tip
        flash.fillColor = NSColor.white.cgColor
        flash.shadowColor = NSColor(calibratedRed: 1, green: 0.9, blue: 0.7, alpha: 1).cgColor
        flash.shadowOpacity = 0.9
        flash.shadowRadius = 8
        flash.opacity = 0
        scene.addSublayer(flash)
        animate(flash, begin: begin, scale: (0.3, 1.4 * big), opacity: [0, 0.9, 0], duration: 0.12)

        let ring = CAShapeLayer()
        let rr: CGFloat = 30
        ring.path = CGPath(ellipseIn: CGRect(x: -rr, y: -rr, width: 2 * rr, height: 2 * rr), transform: nil)
        ring.position = tip
        ring.fillColor = nil
        ring.strokeColor = NSColor(white: 1, alpha: 0.55).cgColor
        ring.lineWidth = 1.2
        ring.opacity = 0
        scene.addSublayer(ring)
        animate(ring, begin: begin, scale: (0.15, 1.6 * big), opacity: [0, 0.8, 0], duration: 0.3)

        // A few short streaks, the frayed cracker snapping.
        let sparks = CAShapeLayer()
        let path = CGMutablePath()
        for i in 0..<7 {
            let a = Double(i) / 7 * 2 * .pi + Double.random(in: -0.3...0.3)
            let inner = CGFloat.random(in: 6...10), outer = CGFloat.random(in: 18...30)
            path.move(to: CGPoint(x: cos(a) * inner, y: sin(a) * inner))
            path.addLine(to: CGPoint(x: cos(a) * outer, y: sin(a) * outer))
        }
        sparks.path = path
        sparks.position = tip
        sparks.strokeColor = NSColor(calibratedRed: 1, green: 0.95, blue: 0.85, alpha: 0.9).cgColor
        sparks.lineWidth = 1.3
        sparks.lineCap = .round
        sparks.opacity = 0
        scene.addSublayer(sparks)
        animate(sparks, begin: begin, scale: (0.6, 1.3 * big), opacity: [0, 1, 0], duration: 0.16)

        let word = CATextLayer()
        word.string = force > 0.6 ? "CRACK!!" : "CRACK!"
        word.font = NSFont.systemFont(ofSize: 10, weight: .black)
        word.fontSize = 44
        word.foregroundColor = NSColor.white.cgColor
        word.shadowColor = NSColor.black.cgColor
        word.shadowOpacity = 0.8
        word.shadowRadius = 6
        word.alignmentMode = .center
        word.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        word.bounds = CGRect(x: 0, y: 0, width: 300, height: 60)
        word.position = CGPoint(x: tip.x + 40, y: tip.y + 70)
        word.transform = CATransform3DMakeRotation(0.12, 0, 0, 1)
        word.opacity = 0
        scene.addSublayer(word)
        animate(word, begin: begin, scale: (0.6, 1.15), opacity: [0, 1, 1, 0], duration: 0.7)
    }

    private static func animate(_ layer: CALayer, begin: CFTimeInterval, scale: (CGFloat, CGFloat), opacity: [Float], duration: CFTimeInterval) {
        let s = CABasicAnimation(keyPath: "transform.scale")
        s.fromValue = scale.0
        s.toValue = scale.1
        s.timingFunction = CAMediaTimingFunction(name: .easeOut)
        let o = CAKeyframeAnimation(keyPath: "opacity")
        o.values = opacity
        let g = CAAnimationGroup()
        g.animations = [s, o]
        g.beginTime = begin
        g.duration = duration
        s.duration = duration
        o.duration = duration
        g.fillMode = .both
        g.isRemovedOnCompletion = false
        layer.add(g, forKey: "crack")
    }

    private static func addShake(to scene: CALayer, begin: CFTimeInterval, force: Double) {
        let amp = 6 + 14 * force
        let shake = CAKeyframeAnimation(keyPath: "position")
        let c = scene.position
        shake.values = [c, CGPoint(x: c.x - amp, y: c.y + amp * 0.4), CGPoint(x: c.x + amp * 0.8, y: c.y - amp * 0.5),
                        CGPoint(x: c.x - amp * 0.5, y: c.y + amp * 0.2), CGPoint(x: c.x + amp * 0.2, y: c.y), c]
        shake.beginTime = begin
        shake.duration = 0.28
        scene.add(shake, forKey: "shake")
    }

    /// Short red flash on the screen edges, like a sting.
    private static func addWelt(to scene: CALayer, size: CGSize, force: Double) {
        let welt = CAGradientLayer()
        welt.type = .radial
        welt.frame = CGRect(origin: .zero, size: size)
        welt.colors = [NSColor.clear.cgColor, NSColor.clear.cgColor, NSColor(calibratedRed: 0.85, green: 0.05, blue: 0.05, alpha: 0.55).cgColor]
        welt.locations = [0, 0.6, 1]
        welt.startPoint = CGPoint(x: 0.5, y: 0.5)
        welt.endPoint = CGPoint(x: 1, y: 1)
        welt.opacity = 0
        // Under the whip, also when it's added for a repeat strike.
        scene.insertSublayer(welt, at: 0)
        let o = CAKeyframeAnimation(keyPath: "opacity")
        o.values = [0, Float(0.5 + 0.5 * force), 0]
        o.keyTimes = [0, 0.15, 1]
        o.beginTime = CACurrentMediaTime() + crackAt
        o.duration = 0.6
        o.fillMode = .both
        o.isRemovedOnCompletion = false
        welt.add(o, forKey: "welt")
    }

    // MARK: Badge

    private static func addBadge(to root: CALayer, size: CGSize, pending: Int) -> CALayer {
        let text = "🩸 ×\(pending) for Claude"
        let font = NSFont.systemFont(ofSize: 17, weight: .bold)
        let width = (text as NSString).size(withAttributes: [.font: font]).width + 36

        let pill = CALayer()
        pill.bounds = CGRect(x: 0, y: 0, width: width, height: 40)
        pill.position = CGPoint(x: size.width - width / 2 - 24, y: size.height - 64)
        pill.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 0.88).cgColor
        pill.cornerRadius = 20
        pill.opacity = 0

        let label = CATextLayer()
        label.string = text
        label.font = font
        label.fontSize = 17
        label.foregroundColor = NSColor.white.cgColor
        label.alignmentMode = .center
        label.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        label.frame = CGRect(x: 0, y: 9, width: width, height: 24)
        pill.addSublayer(label)
        root.addSublayer(pill)

        let o = CAKeyframeAnimation(keyPath: "opacity")
        o.values = [0, 1, 1, 0]
        o.keyTimes = [0, 0.1, 0.8, 1]
        let s = CAKeyframeAnimation(keyPath: "transform.scale")
        s.values = [0.7, 1.12, 1, 1]
        s.keyTimes = [0, 0.1, 0.2, 1]
        let g = CAAnimationGroup()
        g.animations = [o, s]
        g.beginTime = CACurrentMediaTime() + crackAt
        g.duration = 1.6
        o.duration = 1.6
        s.duration = 1.6
        g.fillMode = .both
        g.isRemovedOnCompletion = false
        pill.add(g, forKey: "badge")
        return pill
    }
}
