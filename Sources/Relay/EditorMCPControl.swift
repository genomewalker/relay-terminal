import AppKit

/// Approval and replay receipts for edits to an already-open editor.
@MainActor final class EditorMCPControl {
    private var receipts: [UUID: [String: Any]] = [:]
    private var fingerprints: [UUID: String] = [:]
    private var pending = false
    private let present: PeerNetworkApproval.Presenter

    init(present: PeerNetworkApproval.Presenter? = nil) {
        self.present = present ?? { alert, completion in
            guard let window = NSApp.keyWindow ?? NSApp.mainWindow ??
                    NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }),
                  window.attachedSheet == nil else { return false }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            alert.beginSheetModal(for: window, completionHandler: completion)
            return true
        }
    }

    func receipt(_ id: UUID) -> [String: Any]? { receipts[id] }

    func propose(id: UUID, fingerprint: String, path: String, preview: String, saving: Bool,
                 apply: @escaping @MainActor () async throws -> [String: Any]) throws -> [String: Any] {
        if let old = fingerprints[id] {
            guard old == fingerprint else { throw PluginError.invalid("Conflicting editor request ID") }
            return receipts[id]!
        }
        guard !pending, receipts.count < 128 else {
            throw PluginError.invalid("An editor approval is pending or receipt limit reached")
        }
        pending = true
        fingerprints[id] = fingerprint
        receipts[id] = ["requestID": id.uuidString.lowercased(), "status": "pending", "path": path]
        let deadline = Date().addingTimeInterval(120)
        let alert = RelayTheme.alert()
        alert.messageText = saving ? "Allow MCP to save this file?" : "Allow MCP to edit this file?"
        alert.informativeText = path + (saving ? "\nContents to save:" : "\nReplacement text (empty deletes the range):")
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 260))
        scroll.hasVerticalScroller = true
        let text = NSTextView(frame: scroll.bounds)
        text.isEditable = false
        text.string = preview
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.isVerticallyResizable = true
        text.textContainer?.widthTracksTextView = true
        scroll.documentView = text
        alert.accessoryView = scroll
        alert.addButton(withTitle: saving ? "Save" : "Apply edit")
        alert.addButton(withTitle: "Cancel")
        guard present(alert, { [weak self] response in
            guard let self else { return }
            guard response == .alertFirstButtonReturn, Date() < deadline else {
                self.pending = false
                self.receipts[id]?["status"] = Date() < deadline ? "denied" : "expired"
                return
            }
            self.receipts[id]?["status"] = "applying"
            Task { @MainActor in
                defer { self.pending = false }
                do {
                    var result = try await apply()
                    result["requestID"] = id.uuidString.lowercased()
                    self.receipts[id] = result
                } catch {
                    self.receipts[id]?["status"] = "error"
                    self.receipts[id]?["error"] = error.localizedDescription
                }
            }
        }) else {
            pending = false
            receipts[id]?["status"] = "unavailable"
            return receipts[id]!
        }
        return receipts[id]!
    }
}
