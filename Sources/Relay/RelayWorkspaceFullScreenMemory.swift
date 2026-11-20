import AppKit

/// Remembers whether the workspace window was in full screen, so a relaunch
/// (the preserving update quits and reopens Relay) brings it back that way.
/// On 2026-11-20 every preserving update reopened the window at its default
/// size, out of full screen. AppKit window restoration does not cover this:
/// Relay builds its own window, and "Close windows when quitting" is often on.
@MainActor
final class RelayWorkspaceFullScreenMemory {
    static let shared = RelayWorkspaceFullScreenMemory()
    static let key = "relay.workspace-window.full-screen.v1"

    private let defaults: UserDefaults
    /// Only the first workspace window of a launch is restored; later
    /// windows open as the user asks.
    private(set) var restoreConsidered = false
    /// Leaving full screen while Relay quits is not the user's choice.
    private(set) var terminating = false
    private var observers: [ObjectIdentifier: [NSObjectProtocol]] = [:]

    init(defaults: UserDefaults = RelayStateProfile.defaults) {
        self.defaults = defaults
    }

    var savedFullScreen: Bool { defaults.bool(forKey: Self.key) }

    /// The window entered (true) or left (false) full screen.
    func windowDidChangeFullScreen(_ fullScreen: Bool) {
        guard !terminating else { return }
        defaults.set(fullScreen, forKey: Self.key)
    }

    func applicationWillTerminate() { terminating = true }

    /// Whether this newly configured window should enter full screen now.
    /// True once per launch, for a window not already in full screen.
    func shouldRestore(windowIsFullScreen: Bool) -> Bool {
        guard !restoreConsidered else { return false }
        restoreConsidered = true
        return savedFullScreen && !windowIsFullScreen
    }

    func attach(_ window: NSWindow) {
        let id = ObjectIdentifier(window)
        guard observers[id] == nil else { return }
        let center = NotificationCenter.default
        observers[id] = [
            center.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main) { _ in
                MainActor.assumeIsolated { self.windowDidChangeFullScreen(true) }
            },
            center.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) { _ in
                MainActor.assumeIsolated { self.windowDidChangeFullScreen(false) }
            },
            center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.observers.removeValue(forKey: id)?.forEach { center.removeObserver($0) }
                }
            },
        ]
        if observers.count == 1 {
            observers[ObjectIdentifier(self)] = [
                center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
                    MainActor.assumeIsolated { self.applicationWillTerminate() }
                },
            ]
        }
        guard shouldRestore(windowIsFullScreen: window.styleMask.contains(.fullScreen)) else { return }
        // Let the window finish appearing before the full-screen transition.
        DispatchQueue.main.async { [weak window] in
            guard let window, window.isVisible, !window.styleMask.contains(.fullScreen) else { return }
            window.toggleFullScreen(nil)
        }
    }
}
