import SwiftUI

/// Motion and geometry for showing and hiding the navigator, from the
/// 2026-11-22 sidebar design handoff: one pinned toggle, a 300 ms curve that
/// moves the navigator edge, tab strip and panes together, and a selected
/// tab that joins the panes below it.
enum RelaySidebarMotion {
    /// The toggle keeps one place and one icon in both states.
    static let toggleSymbol = "sidebar.left"
    static let duration: TimeInterval = 0.3
    /// Travel at equal 5% steps of the duration; half of it by 60 ms.
    static let samples: [Double] = [0, 0.029, 0.156, 0.352, 0.5, 0.607, 0.688, 0.753, 0.802, 0.844, 0.878,
                                    0.906, 0.93, 0.948, 0.964, 0.977, 0.984, 0.992, 0.997, 1, 1]
    /// The handoff's 14 px at a 60 px header, scaled to Relay's 36 pt row.
    static let tabRadius: CGFloat = 8
    /// The panes' coordinate space, for the selected tab's distance to their edge.
    static let panelSpace = "relay.sidebar.panel"

    /// Travel fraction at a time fraction, linear between samples.
    static func fraction(at progress: Double) -> Double {
        guard progress.isFinite else { return 1 }
        let position = min(max(progress, 0), 1) * Double(samples.count - 1)
        let index = min(Int(position), samples.count - 2)
        let within = position - Double(index)
        return samples[index] + (samples[index + 1] - samples[index]) * within
    }

    static func animation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : Animation(Curve())
    }

    /// The navigator fades with its reveal.
    static func navigatorOpacity(reveal: CGFloat, full: CGFloat) -> Double {
        guard full > 0 else { return 0 }
        return Double(min(max(reveal / full, 0), 1))
    }

    /// A tab's facing corner may take at most half the horizontal space
    /// between it and the panes' edge, so both reach zero at alignment.
    static func facingRadius(_ radius: CGFloat, gap: CGFloat) -> CGFloat {
        guard gap.isFinite else { return radius }
        return max(0, min(radius, gap / 2))
    }

    struct Curve: CustomAnimation {
        func animate<V: VectorArithmetic>(value: V, time: TimeInterval, context: inout AnimationContext<V>) -> V? {
            guard time < RelaySidebarMotion.duration else { return nil }
            return value.scaled(by: RelaySidebarMotion.fraction(at: time / RelaySidebarMotion.duration))
        }
    }
}

/// Where the navigator's edge is drawn and the width the panes are laid out
/// for. The edge follows each toggle at once (animated); the panes' width
/// changes only when that toggle's motion ends, so a terminal is resized once
/// per toggle, never on every frame.
struct RelaySidebarLayoutState: Equatable {
    private(set) var revealWidth: CGFloat
    private(set) var heldWidth: CGFloat
    /// The navigator stays in the hierarchy while it is visible or closing.
    private(set) var mounted: Bool
    private(set) var generation = 0

    init(target: CGFloat) {
        revealWidth = target
        heldWidth = target
        mounted = target > 0
    }

    /// Start moving toward `target`; returns the motion's generation.
    mutating func begin(_ target: CGFloat) -> Int {
        generation += 1
        revealWidth = target
        if target > 0 { mounted = true }
        return generation
    }

    /// End a motion. A completion from a superseded motion (`generation`
    /// older than the latest) is ignored; `nil` ends without motion.
    mutating func finish(_ target: CGFloat, generation finished: Int?) {
        if let finished, finished != generation { return }
        revealWidth = target
        heldWidth = target
        mounted = target > 0
    }
}

/// The selected tab's fill: rounded top corners and concave lower flares
/// that run into the panes below. Flares are drawn outside the tab's rect.
struct RelayJoinedTabShape: Shape {
    var radius: CGFloat
    var leadingFlare: CGFloat
    var trailingFlare: CGFloat

    func path(in rect: CGRect) -> Path {
        let top = max(0, min(radius, rect.width / 2, rect.height))
        let leading = max(0, min(leadingFlare, rect.height - top))
        let trailing = max(0, min(trailingFlare, rect.height - top))
        var path = Path()
        path.move(to: CGPoint(x: rect.minX - leading, y: rect.maxY))
        path.addArc(center: CGPoint(x: rect.minX - leading, y: rect.maxY - leading), radius: leading,
                    startAngle: .degrees(90), endAngle: .degrees(0), clockwise: true)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + top))
        path.addArc(center: CGPoint(x: rect.minX + top, y: rect.minY + top), radius: top,
                    startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        path.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY))
        path.addArc(center: CGPoint(x: rect.maxX - top, y: rect.minY + top), radius: top,
                    startAngle: .degrees(270), endAngle: .degrees(360), clockwise: false)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - trailing))
        path.addArc(center: CGPoint(x: rect.maxX + trailing, y: rect.maxY - trailing), radius: trailing,
                    startAngle: .degrees(180), endAngle: .degrees(90), clockwise: true)
        path.closeSubpath()
        return path
    }
}
