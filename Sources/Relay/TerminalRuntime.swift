import AppKit
import Foundation
import GhosttyTerminal
import SwiftUI

@MainActor
final class TerminalRuntime: NSObject {
    private weak var pane: PaneModel?
    private let io = TerminalIOBridge()
    private let activityCoalescer = TerminalActivityCoalescer()
    private var started = false

    private var session: InMemoryTerminalSession { io.session }
    private(set) lazy var view: RelayGhosttyView = makeView()

    private static let controller = TerminalController(
        configuration: RelayPreferences.shared.terminalConfiguration()
    )

    static func applyPreferences(_ preferences: RelayPreferences = .shared) {
        _ = controller.setTerminalConfiguration(preferences.terminalConfiguration())
    }

    init(pane: PaneModel) {
        self.pane = pane
    }

    func startIfNeeded() {
        guard !started, let pane else { return }
        started = true
        guard pane.profile.kind == .ssh, pane.profile.backend == .relay else { return }

        let remote = RelayRemoteTransport()
        let artifactPresentation = RelayPreferences.shared.artifactPresentation
        let artifactsEnabled = RelayPreferences.shared.showArtifactPreviews
        io.transport = remote
        let io = self.io
        remote.start(
            profile: pane.profile,
            sessionID: pane.id.uuidString.lowercased(),
            parentSessionID: pane.remoteParentSessionID,
            onOutput: { [weak self] data in
                io.receive(data)
                guard let text = String(data: data, encoding: .utf8) else { return }
                self?.activityCoalescer.ingest(text) { [weak self] batch in
                    Task { @MainActor [weak self] in self?.pane?.received(batch) }
                }
            },
            onStatus: { [weak self] status in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if status.state == "attached" {
                        self.pane?.connected()
                    } else if status.state == "reconnecting" {
                        self.pane?.connectionInterrupted(status.message ?? "Reconnecting")
                    } else if status.state == "exited" {
                        // Keep Ghostty as a renderer. Host-managed exits do not
                        // have exec lifecycle metadata, so forwarding finish()
                        // makes Ghostty present its generic "failed to launch"
                        // screen. Relay owns this lifecycle and renders a native
                        // ended-session overlay with an explicit restart action.
                        self.pane?.exited(exitCode: status.exitCode ?? 0)
                    } else if status.state == "error" {
                        let message = status.message ?? "Remote session error"
                        self.io.receive(Data("\r\n\u{001B}[38;2;255;139;120mRelay: \(message)\u{001B}[0m\r\n".utf8))
                        self.pane?.disconnected(message)
                    }
                }
            },
            onAgentEvent: { [weak self] data in
                Task { @MainActor [weak self] in self?.pane?.receivedAgentEvent(data) }
            },
            onArtifact: { [weak self] artifact in
                guard let self else { return }
                guard artifactsEnabled else { return }
                if artifactPresentation == .inline {
                    self.io.receiveInlineImageOrdered(
                        artifact.data,
                        imageID: Self.stableImageID(for: artifact.path)
                    )
                } else {
                    Task { @MainActor [weak self] in
                        self?.pane?.receivedArtifact(path: artifact.path, data: artifact.data)
                    }
                }
            },
            onDisconnect: { [weak self] message in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.io.receive(Data("\r\n\u{001B}[38;2;255;139;120mRelay connection: \(message)\u{001B}[0m\r\n".utf8))
                    self.pane?.disconnected(message)
                }
            }
        )
    }

    func stop() {
        io.transport?.detach()
        io.transport = nil
        started = false
    }

    func restart() {
        io.transport?.detach()
        io.transport = nil
        started = false
        pane?.reconnecting()
        startIfNeeded()
    }

    func focus() {
        _ = view.acquireProgrammaticFocus()
    }

    private func makeView() -> RelayGhosttyView {
        let terminal = RelayGhosttyView(frame: .zero)
        terminal.owner = self
        terminal.delegate = self
        if let pane, pane.profile.kind == .ssh, pane.profile.backend == .relay {
            terminal.configuration = TerminalSurfaceOptions(
                backend: .inMemory(session),
                context: .window,
                resizeThrottleMilliseconds: 16
            )
        } else {
            terminal.configuration = TerminalSurfaceOptions(
                backend: .exec,
                envVars: ["RELAY_PANE_ID": pane?.id.uuidString ?? ""],
                command: directCommand(),
                waitAfterCommand: true,
                context: .window
            )
        }
        // Ghostty creates a surface as soon as a controller is installed on
        // an attached view. Set the backend first so a remote pane never
        // transiently launches and tears down the default exec surface.
        terminal.controller = Self.controller
        terminal.setAccessibilityElement(true)
        terminal.setAccessibilityLabel("Terminal for \(pane?.profile.name ?? "session")")
        return terminal
    }

    private func directCommand() -> String? {
        guard let pane, pane.profile.kind == .ssh else { return nil }
        let profile = pane.profile
        var parts = ["/usr/bin/ssh", "-tt"]
        parts.append(contentsOf: profile.sshConnectionArguments.map(Self.shellQuote))
        if let command = profile.remoteCommand(forPane: pane.id) {
            parts.append(Self.shellQuote(command))
        }
        return parts.joined(separator: " ")
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    nonisolated private static func stableImageID(for path: String) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for byte in path.utf8 {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
        return hash == 0 ? 1 : hash
    }

    fileprivate func selectPane() {
        guard let pane else { return }
        NotificationCenter.default.post(name: .relaySelectPane, object: pane.id)
    }

    fileprivate func split(_ axis: SplitAxis) {
        selectPane()
        NotificationCenter.default.post(
            name: axis == .horizontal ? .relaySplitRight : .relaySplitDown,
            object: pane?.id
        )
    }

    fileprivate func closePane() {
        selectPane()
        NotificationCenter.default.post(name: .relayClosePane, object: pane?.id)
    }
}

private final class TerminalActivityCoalescer: @unchecked Sendable {
    private let lock = NSLock()
    private var pendingText = ""
    private var deliveryScheduled = false

    func ingest(_ text: String, deliver: @escaping @Sendable (String) -> Void) {
        lock.lock()
        pendingText.append(text)
        guard !deliveryScheduled else {
            lock.unlock()
            return
        }
        deliveryScheduled = true
        lock.unlock()

        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .milliseconds(80)) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let batch = self.pendingText
            self.pendingText.removeAll(keepingCapacity: true)
            self.deliveryScheduled = false
            self.lock.unlock()
            if !batch.isEmpty { deliver(batch) }
        }
    }
}

private final class TerminalIOBridge: @unchecked Sendable {
    var transport: RelayRemoteTransport?
    private let receiveLock = NSLock()
    lazy var session = InMemoryTerminalSession(
        write: { [weak self] data in self?.transport?.sendInput(data) },
        resize: { [weak self] viewport in
            self?.transport?.sendResize(
                columns: UInt16(viewport.columns),
                rows: UInt16(viewport.rows)
            )
        },
        suppressesPixelOnlyResizes: true
    )

    func receive(_ data: Data) {
        receiveLock.lock()
        defer { receiveLock.unlock() }
        session.receive(data)
    }

    func receiveInlineImageOrdered(_ data: Data, imageID: UInt32) {
        receiveLock.lock()
        defer { receiveLock.unlock() }
        for packet in KittyImageEncoder.packets(for: data, imageID: imageID) {
            session.receive(packet)
        }
    }
}

extension TerminalRuntime:
    TerminalSurfaceTitleDelegate,
    TerminalSurfaceCloseDelegate,
    TerminalSurfaceFocusDelegate,
    TerminalSurfacePwdDelegate
{
    func terminalDidChangeTitle(_ title: String) {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        pane?.title = title
    }

    func terminalDidClose(processAlive: Bool) {
        pane?.exited()
    }

    func terminalDidChangeFocus(_ focused: Bool) {
        if focused { selectPane() }
    }

    func terminalDidChangeWorkingDirectory(_ path: String) {
        pane?.directory = path
    }
}

@MainActor
final class RelayGhosttyView: TerminalView {
    weak var owner: TerminalRuntime?

    override func mouseDown(with event: NSEvent) {
        owner?.selectPane()
        super.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        owner?.selectPane()
        NSMenu.popUpContextMenu(relayContextMenu(), with: event, for: self)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        relayContextMenu()
    }

    private func relayContextMenu() -> NSMenu {
        let menu = NSMenu(title: "Terminal")
        menu.autoenablesItems = false
        menu.addItem(item("Copy", action: #selector(copyRelay), key: "c", enabled: true))
        menu.addItem(item(
            "Paste",
            action: #selector(pasteRelay),
            key: "v",
            enabled: NSPasteboard.general.string(forType: .string) != nil
        ))
        menu.addItem(item("Select All", action: #selector(selectAllRelay), key: "a", enabled: true))
        menu.addItem(.separator())
        menu.addItem(item("Split Right", action: #selector(splitRight), key: "d", enabled: true))
        menu.addItem(item("Split Down", action: #selector(splitDown), key: "D", enabled: true))
        menu.addItem(.separator())
        menu.addItem(item("Clear Scrollback", action: #selector(clearScrollback), enabled: true))
        menu.addItem(item(
            owner?.paneIsRemote == true ? "Detach Pane" : "Close Pane",
            action: #selector(closeRelayPane),
            key: "w",
            enabled: true
        ))
        return menu
    }

    private func item(
        _ title: String,
        action: Selector,
        key: String = "",
        enabled: Bool
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.isEnabled = enabled
        return item
    }

    @objc private func copyRelay() { _ = copySelectedTextToPasteboard() }
    @objc private func pasteRelay() { _ = performBindingAction("paste_from_clipboard") }
    @objc private func selectAllRelay() { _ = performBindingAction("select_all") }
    @objc private func clearScrollback() { _ = performBindingAction("clear_scrollback") }
    @objc private func splitRight() { owner?.split(.horizontal) }
    @objc private func splitDown() { owner?.split(.vertical) }
    @objc private func closeRelayPane() { owner?.closePane() }
}

private extension TerminalRuntime {
    var paneIsRemote: Bool {
        pane?.profile.kind == .ssh && pane?.profile.backend == .relay
    }
}

extension Notification.Name {
    static let relaySelectPane = Notification.Name("relay.select-pane")
    static let relaySplitRight = Notification.Name("relay.split-right")
    static let relaySplitDown = Notification.Name("relay.split-down")
    static let relayClosePane = Notification.Name("relay.close-pane")
    static let relayOpenRemoteFile = Notification.Name("relay.open-remote-file")
}

@MainActor
struct TerminalSurface: NSViewRepresentable, Equatable {
    let pane: PaneModel
    nonisolated let identity: UUID

    init(pane: PaneModel) {
        self.pane = pane
        self.identity = pane.id
    }

    nonisolated static func == (lhs: TerminalSurface, rhs: TerminalSurface) -> Bool {
        lhs.identity == rhs.identity
    }

    func makeNSView(context: Context) -> RelayGhosttyView {
        pane.runtime.startIfNeeded()
        return pane.runtime.view
    }

    func updateNSView(_ nsView: RelayGhosttyView, context: Context) {
        pane.runtime.startIfNeeded()
        nsView.fitToSize()
    }
}
