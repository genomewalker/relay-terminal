import AppKit

/// The order in which programmatic navigation unhides Relay and replaces the
/// selected tab.
///
/// Relay 0.5.169 was killed with EXC_GUARD (Relay-2026-11-24-120951.ips) when
/// `select_pane` reached a hidden Relay: the tab switch and
/// `NSApp.activate(ignoringOtherApps:)` ran in one main-thread turn, so the
/// unhide's presentation change and the replacement of the selected tab's
/// SwiftUI tree were laid out in the same display cycle. Releasing the old
/// tree's accessibility nodes posted AppKit's "element destroyed" notification
/// on mach port 0 (main thread: NSHostingView.layout, AccessibilityNode
/// teardown, _AXUIElementPostNotificationWithInfo). An accessibility client
/// (Grammarly, ChatGPT and Claude run here) keeps that tree alive.
///
/// A hidden Relay is therefore unhidden first, and the pane is revealed only
/// after AppKit reports `didUnhide` and the unhide's layout has run. A visible
/// Relay is unchanged: the caller reveals and activates as before.
@MainActor
enum NavigationUnhideOrdering {
    struct Application {
        var isHidden: @MainActor () -> Bool
        var unhide: @MainActor () -> Void
        /// Calls `then` once, after the application has been unhidden.
        var afterUnhide: @MainActor (_ then: @escaping @MainActor @Sendable () -> Void) -> Void
    }

    /// Returns false and does nothing when the application is visible; the
    /// caller then reveals and activates in its usual order. When it is
    /// hidden, waits for the unhide before running `reveal` and returns true.
    static func deferIfHidden(_ application: Application, reveal: @escaping @MainActor @Sendable () -> Void) -> Bool {
        guard application.isHidden() else { return false }
        // Observe before unhiding: AppKit may post didUnhide inside unhide().
        application.afterUnhide(reveal)
        application.unhide()
        return true
    }

    /// Runs its action once, whichever of its triggers comes first.
    @MainActor final class Once {
        private var action: (@MainActor () -> Void)?
        /// A notification observer removed when the action runs.
        var observer: NSObjectProtocol?
        init(_ action: @escaping @MainActor () -> Void) { self.action = action }
        func fire() {
            guard let action else { return }
            self.action = nil
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            action()
        }
    }

    /// How long after didUnhide the reveal waits, so the unhide's layout pass
    /// has finished, and how long it waits at most for didUnhide.
    static let settle: DispatchTimeInterval = .milliseconds(50)
    static let fallback: DispatchTimeInterval = .seconds(1)

    static var application: Application {
        Application(
            isHidden: { !RelayLaunchMode.isRunningTests && (NSApp?.isHidden ?? false) },
            unhide: { NSApp?.unhide(nil) },
            afterUnhide: { then in
                let once = Once {
                    DispatchQueue.main.asyncAfter(deadline: .now() + settle) { MainActor.assumeIsolated { then() } }
                }
                once.observer = NotificationCenter.default.addObserver(
                    forName: NSApplication.didUnhideNotification, object: nil, queue: .main
                ) { _ in MainActor.assumeIsolated { once.fire() } }
                // A selection is never lost if didUnhide does not arrive.
                DispatchQueue.main.asyncAfter(deadline: .now() + fallback) { MainActor.assumeIsolated { once.fire() } }
            }
        )
    }
}
