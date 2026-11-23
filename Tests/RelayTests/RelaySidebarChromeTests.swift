import CoreGraphics
import Testing
@testable import Relay

struct RelaySidebarChromeTests {
    @Test func navigatorToggleKeepsOneIcon() {
        // The icon used to flip between sidebar.left and sidebar.right.
        #expect(RelaySidebarMotion.toggleSymbol == "sidebar.left")
    }

    @Test func motionFollowsTheHandoffCurve() {
        #expect(RelaySidebarMotion.duration == 0.3)
        #expect(RelaySidebarMotion.samples.count == 21)
        #expect(RelaySidebarMotion.fraction(at: 0) == 0)
        // Half the travel by 60 ms of 300 ms.
        #expect(abs(RelaySidebarMotion.fraction(at: 0.2) - 0.5) < 1e-9)
        #expect(RelaySidebarMotion.fraction(at: 1) == 1)
        #expect(RelaySidebarMotion.fraction(at: -1) == 0)
        #expect(RelaySidebarMotion.fraction(at: 2) == 1)
        // Between samples it interpolates linearly.
        #expect(abs(RelaySidebarMotion.fraction(at: 0.025) - 0.0145) < 1e-9)
        var previous = 0.0
        for step in 0...300 {
            let value = RelaySidebarMotion.fraction(at: Double(step) / 300)
            #expect(value >= previous)
            previous = value
        }
    }

    @Test func reducedMotionHasNoAnimation() {
        #expect(RelaySidebarMotion.animation(reduceMotion: false) != nil)
        #expect(RelaySidebarMotion.animation(reduceMotion: true) == nil)
    }

    @Test func panesResizeOncePerToggleAfterTheMotion() {
        var state = RelaySidebarLayoutState(target: 0)
        let opening = state.begin(261)
        // The edge moves at once; the panes keep their width while it moves.
        #expect(state.revealWidth == 261 && state.heldWidth == 0 && state.mounted)
        state.finish(261, generation: opening)
        #expect(state.heldWidth == 261)

        let closing = state.begin(0)
        // Closing keeps the navigator drawn until the motion ends.
        #expect(state.revealWidth == 0 && state.heldWidth == 261 && state.mounted)
        state.finish(0, generation: closing)
        #expect(state.heldWidth == 0 && !state.mounted)
    }

    @Test func overlaysSlideWithTheEdgeAndSettleAtRest() {
        // The R workspace panel is laid out for heldWidth and drawn at
        // heldWidth + slideOffset, which is the navigator's moving edge.
        var state = RelaySidebarLayoutState(target: 0)
        #expect(state.slideOffset == 0)
        let opening = state.begin(261)
        #expect(state.heldWidth + state.slideOffset == state.revealWidth)
        #expect(state.slideOffset == 261)
        state.finish(261, generation: opening)
        #expect(state.slideOffset == 0)
        let closing = state.begin(0)
        #expect(state.slideOffset == -261)
        state.finish(0, generation: closing)
        #expect(state.slideOffset == 0)
    }

    @Test func aReversalIgnoresTheSupersededCompletion() {
        var state = RelaySidebarLayoutState(target: 0)
        let opening = state.begin(261)
        let closing = state.begin(0)
        // The opening's completion arrives after the reversal began.
        state.finish(0, generation: opening)
        #expect(state.heldWidth == 0 && state.mounted, "the closing motion is still drawing the navigator")
        state.finish(0, generation: closing)
        #expect(state.heldWidth == 0 && !state.mounted)
    }

    @Test func noMotionCommitsAtOnce() {
        var state = RelaySidebarLayoutState(target: 261)
        #expect(state.revealWidth == 261 && state.heldWidth == 261 && state.mounted)
        state.finish(245, generation: nil) // compact interface, Reduce Motion
        #expect(state.revealWidth == 245 && state.heldWidth == 245)
        state.finish(0, generation: nil)
        #expect(state.heldWidth == 0 && !state.mounted)
    }

    @Test func facingCornerTakesAtMostHalfTheGap() {
        #expect(RelaySidebarMotion.facingRadius(8, gap: 100) == 8)
        #expect(RelaySidebarMotion.facingRadius(8, gap: 10) == 5)
        #expect(RelaySidebarMotion.facingRadius(8, gap: 0) == 0)
        #expect(RelaySidebarMotion.facingRadius(8, gap: -4) == 0)
        #expect(RelaySidebarMotion.facingRadius(8, gap: .infinity) == 8)
    }

    @Test func joinedTabFlaresReachThePanes() {
        let rect = CGRect(x: 20, y: 0, width: 158, height: 33)
        let shape = RelayJoinedTabShape(radius: 8, leadingFlare: 8, trailingFlare: 8).path(in: rect)
        let bounds = shape.boundingRect
        // Flares extend one radius beyond each side along the bottom edge.
        #expect(abs(bounds.minX - 12) < 0.01 && abs(bounds.maxX - 186) < 0.01)
        #expect(abs(bounds.maxY - 33) < 0.01 && abs(bounds.minY) < 0.01)
        // The flare is concave: just outside the tab near the bottom is filled,
        // a point one radius out and up is not.
        #expect(shape.contains(CGPoint(x: 19, y: 32.5)))
        #expect(!shape.contains(CGPoint(x: 13, y: 26)))
        // Rounded top: the very corner is outside.
        #expect(!shape.contains(CGPoint(x: 20.5, y: 0.5)))
        #expect(shape.contains(CGPoint(x: 99, y: 16)))
        let flat = RelayJoinedTabShape(radius: 8, leadingFlare: 0, trailingFlare: 8).path(in: rect)
        #expect(abs(flat.boundingRect.minX - 20) < 0.01)
    }
}
