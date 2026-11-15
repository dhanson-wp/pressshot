import Cocoa

/// Countdown shown before a delayed screenshot and before a recording starts.
///
/// The caller owns the clock: it calls `tick(to:)` once a second and removes
/// the window at zero. Everything here finishes inside that time, including
/// the fade-out, so nothing of the countdown is left on screen when the
/// capture begins.
final class CountdownView: NSView {
    /// Larger than the disc so the ripple has room to spread.
    static let preferredSize = NSSize(width: 220, height: 220)

    private static let discRadius: CGFloat = 62
    private static let ringRadius: CGFloat = 54
    private static let exitDuration: CFTimeInterval = 0.22

    private let total: Int
    private(set) var remaining: Int

    private let stage = CALayer()
    private let disc = CAShapeLayer()
    private let track = CAShapeLayer()
    private let ring = CAShapeLayer()
    private var digit: CATextLayer?
    private var hasStarted = false
    private let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    init(seconds: Int) {
        total = max(seconds, 1)
        remaining = total
        super.init(frame: NSRect(origin: .zero, size: Self.preferredSize))
        wantsLayer = true
        buildLayers()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - Layers

    private var center: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }

    private func circlePath(radius: CGFloat) -> CGPath {
        CGPath(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                 width: radius * 2, height: radius * 2), transform: nil)
    }

    private func buildLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        // Everything sits on one layer so the whole countdown can scale and
        // fade around its centre.
        stage.frame = bounds
        layer?.addSublayer(stage)

        disc.frame = bounds
        disc.path = circlePath(radius: Self.discRadius)
        disc.fillColor = NSColor.black.withAlphaComponent(0.74).cgColor
        disc.strokeColor = NSColor.white.withAlphaComponent(0.14).cgColor
        disc.lineWidth = 1
        disc.shadowColor = NSColor.black.cgColor
        disc.shadowOpacity = 0.35
        disc.shadowRadius = 14
        disc.shadowOffset = CGSize(width: 0, height: -3)
        stage.addSublayer(disc)

        // Starts at 12 o'clock and runs clockwise.
        let arc = CGMutablePath()
        arc.addArc(center: center, radius: Self.ringRadius,
                   startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)

        track.frame = bounds
        track.path = arc
        track.fillColor = nil
        track.strokeColor = NSColor.white.withAlphaComponent(0.16).cgColor
        track.lineWidth = 5
        stage.addSublayer(track)

        ring.frame = bounds
        ring.path = arc
        ring.fillColor = nil
        ring.strokeColor = NSColor.white.cgColor
        ring.lineWidth = 5
        ring.lineCap = .round
        stage.addSublayer(ring)

        CATransaction.commit()
    }

    private static let digitFont: NSFont = {
        let base = NSFont.systemFont(ofSize: 58, weight: .bold)
        guard let rounded = base.fontDescriptor.withDesign(.rounded) else { return base }
        return NSFont(descriptor: rounded, size: 58) ?? base
    }()

    private func makeDigit() -> CATextLayer {
        let font = Self.digitFont
        let string = NSAttributedString(string: "\(remaining)", attributes: [
            .font: font,
            .foregroundColor: NSColor.white,
        ])
        let size = string.size()
        let text = CATextLayer()
        text.string = string
        text.alignmentMode = .center
        text.bounds = CGRect(x: 0, y: 0, width: ceil(size.width), height: ceil(size.height))
        // The line box leaves room for descenders that digits don't have, so
        // centre the digit's own height (baseline to cap height) instead.
        let opticalOffset = (abs(font.descender) + font.capHeight - font.ascender) / 2
        text.position = CGPoint(x: center.x, y: center.y - opticalOffset)
        // Extra resolution keeps the digit sharp while it is scaled up.
        text.contentsScale = (window?.backingScaleFactor ?? 2) * 2
        return text
    }

    // MARK: - Animation

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !hasStarted else { return }
        hasStarted = true
        let scale = window?.backingScaleFactor ?? 2
        for shape in [disc, track, ring] { shape.contentsScale = scale }
        start()
    }

    private func start() {
        let now = CACurrentMediaTime()
        let duration = CFTimeInterval(total)

        // The ring empties steadily over the whole countdown.
        let drain = CABasicAnimation(keyPath: "strokeStart")
        drain.fromValue = 0
        drain.toValue = 1
        drain.duration = duration
        drain.timingFunction = CAMediaTimingFunction(name: .linear)
        ring.strokeStart = 1
        ring.add(drain, forKey: "drain")

        let fadeIn = CABasicAnimation(keyPath: "opacity")
        fadeIn.fromValue = 0
        fadeIn.toValue = 1
        fadeIn.duration = 0.18
        stage.add(fadeIn, forKey: "fadeIn")
        if !reduceMotion {
            stage.add(spring(from: 0.7, to: 1), forKey: "popIn")
        }

        // Leave just before the caller removes the window.
        let exit = CAAnimationGroup()
        let fadeOut = CABasicAnimation(keyPath: "opacity")
        fadeOut.toValue = 0
        exit.animations = [fadeOut]
        if !reduceMotion {
            let shrink = CABasicAnimation(keyPath: "transform.scale")
            shrink.toValue = 0.86
            exit.animations?.append(shrink)
        }
        exit.beginTime = now + duration - Self.exitDuration
        exit.duration = Self.exitDuration
        exit.timingFunction = CAMediaTimingFunction(name: .easeIn)
        exit.fillMode = .forwards
        exit.isRemovedOnCompletion = false
        stage.add(exit, forKey: "exit")

        showDigit()
    }

    /// Moves the countdown on to `value` seconds remaining.
    func tick(to value: Int) {
        guard value != remaining else { return }
        remaining = value
        guard hasStarted else { return }
        showDigit()
    }

    private func showDigit() {
        if let old = digit {
            // The outgoing digit grows and dissolves as the next one lands.
            let leave = CAAnimationGroup()
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            leave.animations = [fade]
            if !reduceMotion {
                let grow = CABasicAnimation(keyPath: "transform.scale")
                grow.fromValue = 1
                grow.toValue = 1.7
                leave.animations?.append(grow)
            }
            leave.duration = 0.28
            leave.timingFunction = CAMediaTimingFunction(name: .easeOut)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            CATransaction.setCompletionBlock { old.removeFromSuperlayer() }
            old.opacity = 0
            old.add(leave, forKey: "leave")
            CATransaction.commit()
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let next = makeDigit()
        stage.addSublayer(next)
        digit = next
        CATransaction.commit()

        let appear = CABasicAnimation(keyPath: "opacity")
        appear.fromValue = 0
        appear.toValue = 1
        appear.duration = 0.14
        next.add(appear, forKey: "appear")
        if !reduceMotion {
            next.add(spring(from: 0.55, to: 1), forKey: "land")
            ripple()
        }
    }

    /// A ring that spreads out from the disc on every tick.
    private func ripple() {
        let wave = CAShapeLayer()
        wave.frame = stage.bounds
        wave.path = circlePath(radius: Self.discRadius)
        wave.fillColor = nil
        wave.strokeColor = NSColor.white.cgColor
        wave.lineWidth = 2
        wave.contentsScale = window?.backingScaleFactor ?? 2
        wave.opacity = 0

        let spread = CABasicAnimation(keyPath: "transform.scale")
        spread.fromValue = 1
        spread.toValue = 1.6
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.5
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [spread, fade]
        group.duration = 0.75
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { wave.removeFromSuperlayer() }
        stage.insertSublayer(wave, below: disc)
        wave.add(group, forKey: "ripple")
        CATransaction.commit()
    }

    private func spring(from: CGFloat, to: CGFloat) -> CASpringAnimation {
        let spring = CASpringAnimation(keyPath: "transform.scale")
        spring.fromValue = from
        spring.toValue = to
        spring.mass = 1
        spring.stiffness = 260
        spring.damping = 14
        spring.duration = spring.settlingDuration
        return spring
    }
}
