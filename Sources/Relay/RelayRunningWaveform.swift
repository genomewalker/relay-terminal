import AppKit
import SwiftUI

/// The running status mark's waveform, animated by Core Animation.
///
/// SwiftUI's repeating symbol effect redraws its layer on the main thread
/// every frame and waits for the window server to take each new surface;
/// with several running agents on screen that kept the main thread busy
/// most of the time. Here the symbol's shape masks a dim base and a bright
/// fill that steps across the bars, the same "bars fill in turn" motion,
/// as one repeating layer animation the render server plays by itself.
struct RelayRunningWaveform: NSViewRepresentable {
    let color: Color
    let animating: Bool

    func makeNSView(context _: Context) -> RelayRunningWaveformView {
        RelayRunningWaveformView()
    }

    func updateNSView(_ view: RelayRunningWaveformView, context _: Context) {
        view.update(color: NSColor(color), animating: animating)
    }
}

final class RelayRunningWaveformView: NSView {
    static let symbolName = "waveform"
    static let animationKey = "relay.running.sweep"
    /// One step per bar of the waveform symbol, then a full beat.
    static let steps = 6
    static let period: CFTimeInterval = 1.2

    private let shape = CALayer()
    private let base = CALayer()
    private let fill = CALayer()
    private let mask = CALayer()
    private var color = NSColor.systemGreen
    private(set) var animating = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        fill.anchorPoint = CGPoint(x: 0, y: 0.5)
        shape.addSublayer(base)
        shape.addSublayer(fill)
        shape.mask = mask
        layer?.addSublayer(shape)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: NSSize { NSSize(width: RelayStatusMark.size, height: RelayStatusMark.size) }
    override var isFlipped: Bool { true }

    func update(color: NSColor, animating: Bool) {
        self.color = color
        self.animating = animating
        applyColors()
        applyAnimation()
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        shape.frame = bounds
        base.frame = shape.bounds
        fill.bounds = shape.bounds
        fill.position = CGPoint(x: 0, y: shape.bounds.midY)
        mask.frame = shape.bounds
        CATransaction.commit()
        applyMask()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        applyMask()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // A layer leaving and rejoining a window drops its animations.
        applyMask(); applyColors(); applyAnimation()
    }

    /// The symbol, resolved once per size and scale, as the shape's mask.
    private func applyMask() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        guard let image = NSImage(systemSymbolName: Self.symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return }
        var rect = CGRect(origin: .zero, size: image.size)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        mask.contents = image.cgImage(forProposedRect: &rect, context: nil, hints: [.ctm: AffineTransform(scale: scale)])
        mask.contentsScale = scale
        mask.contentsGravity = .center
        CATransaction.commit()
    }

    private func applyColors() {
        var cgColor = color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { cgColor = self.color.cgColor }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        fill.backgroundColor = cgColor
        base.backgroundColor = cgColor
        // Still: the whole symbol in full colour. Moving: a dim symbol the
        // sweep fills.
        base.opacity = animating ? 0.35 : 1
        fill.isHidden = !animating
        CATransaction.commit()
    }

    private func applyAnimation() {
        let running = fill.animation(forKey: Self.animationKey) != nil
        if animating, window != nil, !running {
            fill.add(Self.sweep(), forKey: Self.animationKey)
        } else if !animating || window == nil, running {
            fill.removeAnimation(forKey: Self.animationKey)
        }
    }

    /// Bars fill one after another, hold full for a beat, then start again.
    /// Discrete keyframes need one more key time than values (each value
    /// holds until the next time; the last time, 1, ends the cycle), or Core
    /// Animation rejects the animation and the fill stays at zero width.
    static func sweep() -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: "transform.scale.x")
        let fractions = (0...steps).map { Double($0) / Double(steps) }
        animation.values = fractions
        animation.keyTimes = (fractions.map { $0 * 0.8 } + [1]).map { NSNumber(value: $0) }
        animation.calculationMode = .discrete
        animation.duration = period
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        return animation
    }

    /// Only offscreen captures (`cacheDisplay` of a view outside any window)
    /// draw the still mark here: they draw views, not sublayers. In a window
    /// this drawing would become the view's own layer contents, a fully lit
    /// copy underneath the sweep that hides its motion.
    static func drawsStillCopy(inWindow: Bool) -> Bool { !inWindow }

    override func draw(_ dirtyRect: NSRect) {
        guard Self.drawsStillCopy(inWindow: window != nil) else { return }
        let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
            .applying(.init(paletteColors: [color]))
        guard let image = NSImage(systemSymbolName: Self.symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return }
        let size = image.size
        image.draw(in: NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                              width: size.width, height: size.height))
    }
}
