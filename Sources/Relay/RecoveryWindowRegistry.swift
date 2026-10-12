import AppKit
import SwiftUI

struct RecoveryWindowOrigin: Codable, Sendable {
    let id: UUID
    let name: String
    let lastActive: Date
}

/// Windows share a workspace; ownership routes focus, never starts a second worker.
@MainActor
final class RecoveryWindowRegistry {
    static let shared = RecoveryWindowRegistry()
    private let key = "relay.recovery.window-origins.v1"
    private var windows: [UUID: NSWindow] = [:]
    private var origins: [String: RecoveryWindowOrigin] = [:]
    private var controllers: [NSWindowController] = []
    private let defaults: UserDefaults

    init(defaults: UserDefaults = RelayStateProfile.defaults) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key),
           let saved = try? JSONDecoder().decode([String: RecoveryWindowOrigin].self, from: data) {
            origins = saved
        }
    }

    @discardableResult
    func register(_ window: NSWindow) -> UUID {
        if let existing = windows.first(where: { $0.value === window }) { return existing.key }
        let id = UUID()
        windows[id] = window
        let applicationName = RelayStateProfile.configuration.isIsolated
            ? "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Relay") · Isolated"
            : "Relay"
        window.title = "\(applicationName) · Window \(windows.count) · \(id.uuidString.prefix(6))"
        return id
    }

    func origin(for sessionID: UUID) -> RecoveryWindowOrigin? { origins[sessionID.uuidString] }

    func record(sessionID: UUID, replacing: Bool = false, window: NSWindow? = nil) {
        guard let target = window ?? NSApp?.keyWindow,
              target.identifier == .relayWorkspaceWindow else { return }
        let id = register(target)
        if !replacing, let previous = origins[sessionID.uuidString],
           previous.id != id { return }
        origins[sessionID.uuidString] = RecoveryWindowOrigin(id: id, name: target.title, lastActive: Date())
        if let data = try? JSONEncoder().encode(origins) { defaults.set(data, forKey: key) }
    }

    func liveWindow(for sessionID: UUID) -> NSWindow? {
        guard let origin = origin(for: sessionID), let window = windows[origin.id],
              NSApp?.windows.contains(where: { $0 === window }) == true, window.isVisible || window.isMiniaturized else { return nil }
        return window
    }

    func focus(sessionID: UUID) -> Bool {
        guard let window = liveWindow(for: sessionID) else { return false }
        window.deminiaturize(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp?.activate(ignoringOtherApps: true)
        return true
    }

    func openWindow(workspace: WorkspaceModel) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.identifier = .relayWorkspaceWindow
        register(window)
        window.contentView = NSHostingView(rootView: WorkspaceView(workspace: workspace)
            .frame(minWidth: 880, minHeight: 560)
            .background(RelayWorkspaceWindowMarker().frame(width: 0, height: 0))
            .relaySurface())
        window.isReleasedWhenClosed = false
        let controller = NSWindowController(window: window)
        controllers.append(controller)
        window.center()
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        return window
    }
}
