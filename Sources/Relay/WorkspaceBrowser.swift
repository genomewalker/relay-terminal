import AppKit
import SwiftUI
import WebKit

/// Generic web content gets a fresh configuration: no editor scripts, handlers,
/// Relay scheme handlers, native objects, credentials, or shared persistent cookies.
@MainActor final class WorkspaceBrowserSession: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    let profile: ConnectionProfile
    let directory: String
    let webView: WKWebView
    @Published var address = ""
    @Published var portText = "8000"
    @Published private(set) var error: String?
    @Published private(set) var busy = false
    @Published private(set) var remotePort: Int?
    @Published private(set) var revision = 0
    private var bridge: RHttpgdRelayBridge?
    private var opening: Task<Void, Never>?
    private var generation = UUID()
    private var observations: [NSKeyValueObservation] = []

    var hostLabel: String { profile.kind == .local ? "This Mac" : profile.user + "@" + profile.host }
    var origin: String { WorkspaceBrowserAddress.origin(webView.url) }

    init(profile: ConnectionProfile, directory: String) {
        self.profile = profile
        self.directory = directory
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController = WKUserContentController()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        observations = [
            webView.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.revision += 1 } },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.revision += 1 } },
            webView.observe(\.url, options: [.new]) { [weak self] view, _ in
                Task { @MainActor in self?.address = view.url?.absoluteString ?? ""; self?.revision += 1 }
            },
        ]
    }

    func navigate() {
        guard let url = WorkspaceBrowserAddress.parse(address) else { error = "Enter an HTTP or HTTPS address without embedded credentials."; return }
        if profile.kind != .local && remotePort == nil { error = "Connect the remote localhost port explicitly first."; return }
        guard WorkspaceBrowserAddress.allows(url, remotePort: remotePort) else {
            error = "This browser is bound to \(hostLabel), localhost:\(remotePort ?? 0). Connect another port explicitly to change origin."
            return
        }
        error = nil
        webView.load(URLRequest(url: url))
    }

    func connectRemote() {
        guard profile.kind == .ssh, profile.backend == .relay,
              let port = Int(portText), (1024...65535).contains(port),
              directory.hasPrefix("/"), !directory.contains("\0") else {
            error = "Choose a Relay host, an absolute working directory and a port from 1024–65535."
            return
        }
        disconnect()
        let token = generation
        busy = true
        opening = Task { [weak self] in
            guard let self else { return }
            do {
                let rules = try await WKContentRuleListStore.default().compileContentRuleList(
                    forIdentifier: "relay-browser-loopback-\(port)", encodedContentRuleList: WorkspaceBrowserAddress.remoteRules(port: port))
                guard token == generation, !Task.isCancelled else { return }
                // Same local port is mandatory: absolute redirects and WebSockets
                // retain the service's original origin. An occupied port fails closed.
                let opened = try await RHttpgdRelayBridge.open(profile: profile, remotePort: port, directory: directory, localPort: UInt16(port))
                guard token == generation, !Task.isCancelled else { opened.close(); return }
                guard let rules else { opened.close(); throw RHttpgdError.tunnel("Browser network isolation could not be configured") }
                webView.configuration.userContentController.removeAllContentRuleLists()
                webView.configuration.userContentController.add(rules)
                bridge = opened
                remotePort = port
                busy = false
                address = "http://127.0.0.1:\(port)/"
                navigate()
            } catch {
                guard token == generation else { return }
                busy = false
                self.error = "Could not connect \(hostLabel):\(port): \(error.localizedDescription)"
            }
        }
    }

    func disconnect() {
        generation = UUID()
        opening?.cancel(); opening = nil
        webView.stopLoading()
        if remotePort != nil { webView.loadHTMLString("", baseURL: nil); address = "" }
        bridge?.close(); bridge = nil
        remotePort = nil
        busy = false
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        if navigationAction.request.url?.absoluteString == "about:blank" { decisionHandler(.allow); return }
        guard let url = navigationAction.request.url,
              !(profile.kind != .local && remotePort == nil),
              WorkspaceBrowserAddress.allows(url, remotePort: remotePort),
              !navigationAction.shouldPerformDownload else {
            error = "Navigation blocked. Only this browser’s HTTP/HTTPS origin is available; downloads and native links require an explicit file action."
            decisionHandler(.cancel); return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        // No implicit download or launch through the generic browser.
        let disposition = (navigationResponse.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")?.lowercased() ?? ""
        decisionHandler(navigationResponse.canShowMIMEType && !disposition.hasPrefix("attachment") ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, WorkspaceBrowserAddress.allows(url, remotePort: remotePort) {
            address = url.absoluteString; navigate()
        }
        return nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { self.error = error.localizedDescription }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        self.error = error.localizedDescription
    }
    deinit { bridge?.close(); opening?.cancel() }
}

@MainActor private final class WorkspaceBrowserStore: ObservableObject {
    var sessions: [UUID: WorkspaceBrowserSession] = [:]
    func session(id: UUID, pane: PaneModel) -> WorkspaceBrowserSession {
        if let existing = sessions[id], existing.profile == pane.profile { return existing }
        sessions[id]?.disconnect()
        let session = WorkspaceBrowserSession(profile: pane.profile, directory: pane.directory ?? "")
        sessions[id] = session
        return session
    }
}

struct WorkspaceBrowserLauncher: View {
    @ObservedObject var workspace: WorkspaceModel
    @StateObject private var store = WorkspaceBrowserStore()
    @State private var session: WorkspaceBrowserSession?
    @State private var presented = false
    var body: some View {
        Button {
            guard let pane = workspace.activePane, let id = workspace.selectedWorkspaceID else { return }
            session = store.session(id: id, pane: pane)
            presented = true
        } label: { Image(systemName: "globe").frame(width: 30, height: 30) }
        .buttonStyle(.plain)
        .help("Workspace browser · host-bound web pages")
        .accessibilityLabel("Open workspace browser")
        .disabled(workspace.activePane == nil || workspace.selectedWorkspaceID == nil)
        .sheet(isPresented: $presented, onDismiss: { session?.disconnect() }) {
            if let session { WorkspaceBrowserView(session: session) }
        }
    }
}

private struct WorkspaceBrowserSurface: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

private struct WorkspaceBrowserView: View {
    @ObservedObject var session: WorkspaceBrowserSession
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Label(session.hostLabel, systemImage: session.profile.kind == .local ? "desktopcomputer" : "server.rack")
                Text(session.directory).foregroundStyle(.secondary).lineLimit(1).textSelection(.enabled)
                Spacer()
                Button("Done") { session.disconnect(); dismiss() }
            }
            if session.profile.kind != .local {
                HStack {
                    Text("Remote localhost port")
                    TextField("8000", text: $session.portText).frame(width: 85)
                    Button(session.busy ? "Connecting…" : "Connect explicitly") { session.connectRemote() }.disabled(session.busy)
                    Button("Disconnect") { session.disconnect() }.disabled(session.remotePort == nil && !session.busy)
                    Text("Uses the same Mac loopback port; occupied ports fail safely.").font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button { session.webView.goBack() } label: { Image(systemName: "chevron.left") }.disabled(!session.webView.canGoBack).accessibilityLabel("Back")
                Button { session.webView.goForward() } label: { Image(systemName: "chevron.right") }.disabled(!session.webView.canGoForward).accessibilityLabel("Forward")
                Button { session.webView.reload() } label: { Image(systemName: "arrow.clockwise") }.disabled(session.webView.url == nil).accessibilityLabel("Reload")
                TextField("https://example.org", text: $session.address).onSubmit { session.navigate() }
                Button("Go") { session.navigate() }
            }
            Text("\(session.hostLabel) · \(session.origin)").font(.caption.monospaced()).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            if let error = session.error { Text(error).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading) }
            WorkspaceBrowserSurface(webView: session.webView)
        }
        .padding(12)
        .frame(minWidth: 850, minHeight: 600)
        .onDisappear { session.disconnect() }
    }
}
