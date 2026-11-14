import AppKit
import SwiftUI
import WebKit

/// How a browser opened from a pane reaches a URL. Local and remote panes
/// behave the same: internet addresses load directly, and "localhost" means
/// the pane's own host. For a remote pane that host's ports are carried over
/// its relayd connection to a Mac loopback port, and pages opened from it
/// can never reach services on the Mac's own loopback.
enum RelayBrowserRouting {
    enum Route: Equatable {
        case load(URL)
        /// The host port must be carried to the Mac before loading.
        case tunnel(hostPort: Int)
        case blocked(String)
    }

    static let maxTunnels = 8

    static func port(_ url: URL) -> Int {
        url.port ?? (["https", "wss"].contains(url.scheme?.lowercased() ?? "") ? 443 : 80)
    }

    static func isLoopback(_ url: URL) -> Bool {
        WorkspaceBrowserAddress.isLoopback(url.host) || url.host == "0.0.0.0"
    }

    /// `tunnels` maps a host port to the Mac port carrying it.
    static func route(_ url: URL, remote: Bool, tunnels: [Int: Int]) -> Route {
        guard WorkspaceBrowserAddress.parse(url.absoluteString) != nil else {
            return .blocked("Only HTTP and HTTPS addresses without embedded credentials open here")
        }
        guard remote, isLoopback(url) else { return .load(url) }
        let port = port(url)
        if let mac = tunnels[port] { return .load(mapped(url, to: mac)) }
        // A page served through a tunnel links to its own Mac-side origin.
        if tunnels.values.contains(port) { return .load(mapped(url, to: port)) }
        guard tunnels.count < maxTunnels else {
            return .blocked("At most \(maxTunnels) host ports can be open in one browser; close it to start over")
        }
        return .tunnel(hostPort: port)
    }

    static func mapped(_ url: URL, to port: Int) -> URL {
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        parts.host = "127.0.0.1"
        parts.port = port
        return parts.url!
    }

    /// The Mac port to try first: the same number keeps absolute links and
    /// WebSockets working; privileged ports always get any free port.
    static func preferredMacPort(hostPort: Int) -> UInt16? {
        (1024...65535).contains(hostPort) ? UInt16(hostPort) : nil
    }

    /// WebKit content rules for a remote pane's browser: block every Mac
    /// loopback address except the Mac ports that carry this host's ports.
    /// (WebKit's rule regexes have no alternation, hence one rule per form.)
    static func macGuardRules(macPorts: [Int]) -> String {
        var rules: [[String: Any]] = [
            "^[a-z]+://localhost[:/]", "^[a-z]+://[^/]*\\.localhost[:/]", "^[a-z]+://127\\.",
            "^[a-z]+://\\[::1\\]", "^[a-z]+://\\[::\\][:/]", "^[a-z]+://\\[::ffff:127\\.", "^[a-z]+://\\[::ffff:7f", "^[a-z]+://0\\.0\\.0\\.0[:/]",
        ].map { ["trigger": ["url-filter": $0], "action": ["type": "block"]] }
        for port in macPorts.sorted() {
            rules.append(["trigger": ["url-filter": "^[a-z]+://127\\.0\\.0\\.1:\(port)/"], "action": ["type": "ignore-previous-rules"]])
            rules.append(["trigger": ["url-filter": "^[a-z]+://localhost:\(port)/"], "action": ["type": "ignore-previous-rules"]])
        }
        return String(data: try! JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys]), encoding: .utf8)!
    }
}

/// One browser per host. No cookies or storage are kept after Relay quits.
@MainActor final class RelayBrowserSession: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    let profile: ConnectionProfile
    let webView: WKWebView
    @Published var address = ""
    @Published private(set) var error: String?
    @Published private(set) var busy = false
    @Published private(set) var revision = 0
    /// A host port a page (not the user) asked for; opened only on confirm.
    @Published private(set) var confirm: URL?
    private var directory: String
    private var tunnels: [Int: RHttpgdRelayBridge] = [:]
    private var opening: [Int: Task<Void, Never>] = [:]
    private var rules: WKContentRuleList?
    private var guarded = false
    private var pending: URL?
    private var generation = UUID()
    private var guardSequence = 0
    private var observations: [NSKeyValueObservation] = []

    var remote: Bool { profile.kind != .local }
    /// A page waiting for its port to be carried or for the Mac guard.
    var hasPendingLoad: Bool { pending != nil || !opening.isEmpty }
    var hostLabel: String { remote ? profile.host : "This Mac" }
    var portMap: [Int: Int] { tunnels.mapValues { Int($0.endpoint.port) } }
    var tunnelSummary: String {
        portMap.sorted { $0.key < $1.key }
            .map { $0.key == $0.value ? ":\($0.key)" : ":\($0.key)→Mac :\($0.value)" }
            .joined(separator: " ")
    }
    /// Safari can open what this browser shows, except a host port carried by it.
    var canOpenElsewhere: Bool {
        guard let url = webView.url, url.scheme?.hasPrefix("http") == true else { return false }
        return !remote || !RelayBrowserRouting.isLoopback(url)
    }

    init(profile: ConnectionProfile, directory: String?, store: WKWebsiteDataStore? = nil) {
        self.profile = profile
        self.directory = directory.flatMap { $0.hasPrefix("/") ? $0 : nil } ?? "/"
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store ?? WKWebsiteDataStore(forIdentifier: Self.storeIdentifier(profile))
        configuration.userContentController = WKUserContentController()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        observations = [
            webView.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.revision += 1 } },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.revision += 1 } },
            webView.observe(\.isLoading, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.revision += 1 } },
            webView.observe(\.url, options: [.new]) { [weak self] view, _ in
                Task { @MainActor in self?.address = view.url?.absoluteString ?? ""; self?.revision += 1 }
            },
        ]
        if remote { updateGuard() }
    }

    /// Logins and site data are kept per host: everything opened for This Mac
    /// shares one store, and each remote host has its own, so a remote host's
    /// pages never see This Mac's sign-ins or another host's.
    static let localStore = UUID(uuidString: "5E1A7B0C-0000-4000-8000-000000000001")!
    static func storeIdentifier(_ profile: ConnectionProfile) -> UUID {
        profile.kind == .local ? localStore : profile.id
    }

    func update(directory: String?) {
        if let directory, directory.hasPrefix("/") { self.directory = directory }
    }

    /// A URL the user chose: a pane click or the address bar.
    func open(_ url: URL) {
        address = url.absoluteString
        go(url, byUser: true)
    }

    func confirmPort() {
        guard let url = confirm else { return }
        confirm = nil
        go(url, byUser: true)
    }
    func declinePort() { confirm = nil }

    func navigate() {
        guard let url = WorkspaceBrowserAddress.parse(address) else {
            error = "Enter an HTTP or HTTPS address without embedded credentials."
            return
        }
        go(url, byUser: true)
    }

    func openElsewhere() {
        guard canOpenElsewhere, let url = webView.url else { return }
        NSWorkspace.shared.open(url)
    }

    /// Closing the panel ends its page and every carried port.
    func close() {
        generation = UUID()
        opening.values.forEach { $0.cancel() }; opening = [:]
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
        tunnels.values.forEach { $0.close() }; tunnels = [:]
        pending = nil
        confirm = nil
        busy = false
        error = nil
        address = ""
        if remote { updateGuard() }
    }

    private func go(_ url: URL, byUser: Bool) {
        switch RelayBrowserRouting.route(url, remote: remote, tunnels: portMap) {
        case .load(let target): load(target)
        case .tunnel(let port) where byUser: carry(port, then: url)
        case .tunnel: confirm = url
        case .blocked(let message): error = message
        }
    }

    private func load(_ url: URL) {
        error = nil
        // Nothing loads in a remote pane's browser before the Mac guard is in place.
        guard !remote || guarded else { pending = url; return }
        webView.load(URLRequest(url: url))
    }

    private func carry(_ port: Int, then url: URL) {
        guard profile.kind == .ssh, profile.backend == .relay else {
            error = "\(hostLabel) has no Relay connection, so its localhost can't be opened here."
            return
        }
        pending = url
        guard opening[port] == nil else { return }
        busy = true
        let token = generation
        opening[port] = Task { [weak self] in
            guard let self else { return }
            do {
                var bridge: RHttpgdRelayBridge
                if let same = RelayBrowserRouting.preferredMacPort(hostPort: port),
                   let opened = try? await RHttpgdRelayBridge.open(profile: profile, remotePort: port, directory: directory, localPort: same) {
                    bridge = opened
                } else {
                    bridge = try await RHttpgdRelayBridge.open(profile: profile, remotePort: port, directory: directory)
                }
                guard token == generation, !Task.isCancelled else { bridge.close(); return }
                tunnels[port] = bridge
                opening[port] = nil
                busy = !opening.isEmpty
                updateGuard()
            } catch {
                guard token == generation else { return }
                opening[port] = nil
                busy = !opening.isEmpty
                self.error = "Could not open \(hostLabel) localhost:\(port): \(error.localizedDescription)"
            }
        }
    }

    /// Adds the new rule list before removing the old one, so there is never
    /// a moment without the guard.
    private func updateGuard() {
        let ports = Array(portMap.values)
        let token = generation
        guardSequence += 1
        let sequence = guardSequence
        let identifier = "relay-browser-mac-guard-" + ports.sorted().map(String.init).joined(separator: "-")
        Task { [weak self] in
            let compiled = try? await WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: identifier, encodedContentRuleList: RelayBrowserRouting.macGuardRules(macPorts: ports))
            // A later update supersedes this one, whichever compiles first.
            guard let self, token == generation, sequence == guardSequence else { return }
            guard let compiled else {
                error = "The browser's network guard could not be set up, so nothing will load from \(hostLabel)."
                return
            }
            let controller = webView.configuration.userContentController
            controller.add(compiled)
            if let old = rules { controller.remove(old) }
            rules = compiled
            guarded = true
            if let next = pending { pending = nil; go(next, byUser: true) }
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if url.absoluteString == "about:blank" { decisionHandler(.allow); return }
        guard !navigationAction.shouldPerformDownload else {
            error = "Downloads aren't saved from this browser."
            decisionHandler(.cancel); return
        }
        let mainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        switch RelayBrowserRouting.route(url, remote: remote, tunnels: portMap) {
        case .load(let target) where target == url:
            decisionHandler(remote && !guarded ? .cancel : .allow)
        case .load(let target):
            decisionHandler(.cancel)
            if mainFrame { load(target) }
        case .tunnel(let port):
            decisionHandler(.cancel)
            // Only the user, or a page on a host port the user opened, opens
            // another host port; anything else asks first.
            let source = navigationAction.sourceFrame.request.url
            let fromCarried = source.map { RelayBrowserRouting.isLoopback($0) && portMap.values.contains(RelayBrowserRouting.port($0)) } ?? false
            if mainFrame { fromCarried ? carry(port, then: url) : (confirm = url) }
        case .blocked(let message):
            decisionHandler(.cancel)
            if mainFrame { error = message }
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        let disposition = (navigationResponse.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition")?.lowercased() ?? ""
        decisionHandler(navigationResponse.canShowMIMEType && !disposition.hasPrefix("attachment") ? .allow : .cancel)
    }

    /// Links that ask for a new window open in this one.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { webView.load(URLRequest(url: url)) } // through the policy above
        return nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { self.error = error.localizedDescription }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { self.error = error.localizedDescription }
    }
}

/// One floating browser panel per host, opened from any pane on that host.
@MainActor final class RelayBrowserController: NSObject, NSWindowDelegate {
    static let shared = RelayBrowserController()
    private var panels: [String: (session: RelayBrowserSession, panel: NSPanel)] = [:]

    static func key(_ profile: ConnectionProfile) -> String {
        profile.kind == .local ? "local" : profile.id.uuidString
    }

    func open(_ url: URL?, profile: ConnectionProfile, directory: String?, near window: NSWindow?, takeFocus: Bool = true) {
        let key = Self.key(profile)
        let entry = panels[key].flatMap { $0.session.profile == profile ? $0 : nil } ?? make(profile: profile, directory: directory)
        panels[key] = entry
        entry.session.update(directory: directory)
        if !entry.panel.isVisible {
            if let frame = window?.frame {
                entry.panel.setFrame(NSRect(x: frame.midX - 460, y: frame.midY - 340, width: 920, height: 680), display: false)
            } else {
                entry.panel.center()
            }
        }
        if takeFocus { entry.panel.makeKeyAndOrderFront(nil) } else { entry.panel.orderFront(nil) }
        if let url { entry.session.open(url) }
    }

    /// The session of a panel that is open now; a closed panel's page is gone.
    func existing(_ key: String) -> RelayBrowserSession? {
        panels[key].flatMap { $0.panel.isVisible ? $0.session : nil }
    }

    func windowWillClose(_ notification: Notification) {
        guard let panel = notification.object as? NSPanel else { return }
        panels.values.first { $0.panel === panel }?.session.close()
    }

    private func make(profile: ConnectionProfile, directory: String?) -> (session: RelayBrowserSession, panel: NSPanel) {
        let session = RelayBrowserSession(profile: profile, directory: directory)
        let panel = RelayQuickLookPanel(contentRect: NSRect(x: 0, y: 0, width: 920, height: 680),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered, defer: true)
        panel.title = "Browser · " + session.hostLabel
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 420, height: 300)
        panel.delegate = self
        RelayTheme.configureAppearance(panel)
        panel.contentView = NSHostingView(rootView: RelayBrowserView(session: session) { [weak panel] in panel?.close() })
        return (session, panel)
    }
}

private struct RelayBrowserSurface: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

struct RelayBrowserView: View {
    @ObservedObject var session: RelayBrowserSession
    let close: () -> Void

    var body: some View {
        let _ = session.revision
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { session.webView.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!session.webView.canGoBack).help("Back")
                Button { session.webView.goForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!session.webView.canGoForward).help("Forward")
                Button {
                    if session.webView.isLoading { session.webView.stopLoading() } else { session.webView.reload() }
                } label: { Image(systemName: session.webView.isLoading ? "xmark" : "arrow.clockwise") }
                    .help(session.webView.isLoading ? "Stop" : "Reload")
                TextField("Address", text: $session.address)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(RelayTheme.text)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(RelayTheme.canvas, in: RoundedRectangle(cornerRadius: 6))
                    .onSubmit { session.navigate() }
                if session.busy { ProgressView().controlSize(.small) }
                Label(session.hostLabel, systemImage: session.remote ? "server.rack" : "desktopcomputer")
                    .font(.system(size: 11)).foregroundStyle(RelayTheme.textMuted)
                    .help(session.remote
                          ? "localhost is \(session.hostLabel)'s, carried over Relay. Pages here can't reach services on this Mac."
                          : "localhost is this Mac")
                Button { session.openElsewhere() } label: { Image(systemName: "safari") }
                    .disabled(!session.canOpenElsewhere).help("Open in the default browser")
                Button(action: close) { Image(systemName: "xmark.circle") }.help("Close")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(RelayTheme.textMuted)
            .padding(.leading, 76).padding(.trailing, 12).padding(.vertical, 8)
            .background(RelayTheme.surface)
            if let url = session.confirm {
                HStack(spacing: 8) {
                    Text("This page wants \(session.hostLabel) localhost:\(RelayBrowserRouting.port(url)).")
                        .font(.caption).foregroundStyle(RelayTheme.text)
                    Spacer()
                    Button("Open Port") { session.confirmPort() }
                    Button("Don't Open") { session.declinePort() }
                }
                .buttonStyle(.borderless).font(.caption)
                .padding(.horizontal, 12).padding(.vertical, 4)
                .background(RelayTheme.surface)
            }
            if let error = session.error {
                Text(error).font(.caption).foregroundStyle(RelayTheme.warning)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 4)
                    .background(RelayTheme.surface)
                    .textSelection(.enabled)
            } else if !session.tunnelSummary.isEmpty {
                Text(session.hostLabel + " ports " + session.tunnelSummary)
                    .font(.caption).foregroundStyle(RelayTheme.textFaint)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 3)
                    .background(RelayTheme.surface)
            }
            Divider().overlay(RelayTheme.line)
            RelayBrowserSurface(webView: session.webView)
        }
        .background(RelayTheme.canvas)
    }
}
