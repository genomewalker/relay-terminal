import AppKit
import WebKit
import SwiftUI

/// Sign-ins happen inside Relay. A local Claude login gets Relay's helper as
/// its BROWSER: the helper writes the sign-in URL to a private file that
/// Relay picks up, and opens nothing. Codex on macOS ignores BROWSER, so it
/// uses its device-code login everywhere; Relay reads the page and code
/// from the login pane. Codes are handed over once and never stored or
/// logged.
enum RelayAgentSignIn {
    /// The hand-off folder on This Mac: owner-only, beside relayd's own
    /// ~/.relay state, with no space in its path (BROWSER is one program path).
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".relay/signin", isDirectory: true)
    }

    static let helperName = "relay-signin-browser"
    /// The helper as typed into the login pane's shell on This Mac.
    static let helperCommand = "\"$HOME\"/.relay/signin/" + helperName

    /// The provider CLI calls this as its browser with one URL argument. It
    /// accepts only an ID Relay issued (a UUID with Relay's `<id>.issued`
    /// marker beside it), writes only into this user's 0700 hand-off folder,
    /// and creates `<id>.<16 random characters>` exclusively: O_CREAT |
    /// O_EXCL on a name no one can predict, so an existing file or link is
    /// never followed or reused, 0600 by its umask. Nothing is opened.
    static let helperScript = """
    #!/bin/sh
    # Relay sign-in hand-off: the provider CLI runs this as its browser. The
    # sign-in URL goes to Relay through a private file; nothing is opened here.
    umask 077
    case "$RELAY_SIGNIN_ID" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
    *) exit 1 ;;
    esac
    dir="$HOME/.relay/signin"
    [ -d "$dir" ] && [ ! -L "$dir" ] && [ -O "$dir" ] || exit 1
    [ "$(/usr/bin/stat -f %Lp "$dir")" = 700 ] || exit 1
    issued="$dir/$RELAY_SIGNIN_ID.issued"
    [ -f "$issued" ] && [ ! -L "$issued" ] && [ -O "$issued" ] || exit 1
    [ "$#" -eq 1 ] && [ -n "$1" ] && [ "${#1}" -le 4096 ] || exit 1
    file=$(/usr/bin/mktemp -u "$dir/$RELAY_SIGNIN_ID.XXXXXXXXXXXXXXXX") || exit 1
    case "$file" in "$dir/$RELAY_SIGNIN_ID".*) ;; *) exit 1 ;; esac
    set -C
    printf '%s\\n' "$1" > "$file" || exit 1

    """

    static func validID(_ id: String) -> Bool {
        id.range(of: "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", options: .regularExpression) != nil
    }

    private static let lock = NSLock()
    // All access is serialized by `lock`.
    nonisolated(unsafe) private static var issued: Set<String> = []
    nonisolated(unsafe) private static var consumed: Set<String> = []

    /// A new hand-off ID, with its `<id>.issued` marker (0600) in the
    /// installed folder: the helper accepts only such IDs, and Relay takes
    /// hand-offs only for IDs it issued, each at most once.
    static func issue(in directory: URL = directory) throws -> String {
        let id = UUID().uuidString.lowercased()
        let marker = directory.appendingPathComponent(id + ".issued").path
        let descriptor = open(marker, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw failure("The sign-in hand-off could not be prepared") }
        close(descriptor)
        lock.lock(); defer { lock.unlock() }
        issued.insert(id)
        return id
    }

    /// Ends an ID: its marker and any hand-off are removed, and it is never
    /// taken.
    static func retire(_ id: String, in directory: URL = directory) {
        lock.lock()
        issued.remove(id)
        consumed.insert(id)
        lock.unlock()
        discard(id: id, in: directory)
    }

    /// Creates the owner-only folder and writes the helper (0700) when it is
    /// missing or differs. The folder, its parent and the helper must be
    /// this user's own and not links. Hand-offs and markers left by earlier
    /// runs are removed.
    static func installHelper(in directory: URL = directory) throws {
        let manager = FileManager.default
        let parent = directory.deletingLastPathComponent()
        if !exists(parent) {
            try manager.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        guard ownDirectory(parent) else { throw failure("The folder \(parent.path) is not this user's own folder") }
        if !exists(directory) {
            try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        guard ownDirectory(directory) else { throw failure("The sign-in folder is not this user's own folder") }
        guard chmod(directory.path, 0o700) == 0 else { throw failure("The sign-in folder cannot be made private") }
        let helper = directory.appendingPathComponent(helperName)
        if exists(helper) {
            var info = stat()
            guard lstat(helper.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else {
                throw failure("The sign-in helper is not this user's own regular file")
            }
        }
        if (try? String(contentsOf: helper, encoding: .utf8)) != helperScript {
            try Data(helperScript.utf8).write(to: helper, options: .atomic)
        }
        guard chmod(helper.path, 0o700) == 0 else { throw failure("The sign-in helper cannot be made private") }
        for name in (try? manager.contentsOfDirectory(atPath: directory.path)) ?? [] where name != helperName {
            let id = String(name.prefix(36))
            lock.lock()
            let current = issued.contains(id)
            lock.unlock()
            if !current { unlink(directory.appendingPathComponent(name).path) }
        }
    }

    /// The hand-off files of `id`: `<id>.` and 16 random characters.
    private static func handoffs(_ id: String, in directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter {
            $0.hasPrefix(id + ".") && $0.dropFirst(id.count + 1).count == 16 &&
                $0.dropFirst(id.count + 1).allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
        }
    }

    /// The URL the helper handed over for `id`, at most once: only for an ID
    /// Relay issued and has not consumed or retired. The folder must still be
    /// this user's 0700 folder, and hold exactly one hand-off for the ID; it
    /// is opened without following links and must be this user's own 0600
    /// regular file with one link. The ID counts as consumed before the URL
    /// is read, whether or not the file can then be removed. Only an
    /// allowlisted https sign-in page is returned.
    static func takeURL(id: String, in directory: URL = directory) -> URL? {
        guard validID(id) else { return nil }
        lock.lock()
        let current = issued.contains(id) && !consumed.contains(id)
        lock.unlock()
        guard current else { return nil }
        var folder = stat()
        guard lstat(directory.path, &folder) == 0, folder.st_mode & S_IFMT == S_IFDIR,
              folder.st_uid == getuid(), folder.st_mode & 0o777 == 0o700 else { return nil }
        let names = handoffs(id, in: directory)
        guard !names.isEmpty else { return nil }
        lock.lock()
        consumed.insert(id)
        issued.remove(id)
        lock.unlock()
        let paths = names.map { directory.appendingPathComponent($0).path }
        defer { paths.forEach { unlink($0) } }
        guard paths.count == 1 else { return nil }
        let descriptor = open(paths[0], O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var file = stat()
        var bytes = [UInt8](repeating: 0, count: 4098)
        guard fstat(descriptor, &file) == 0, file.st_mode & S_IFMT == S_IFREG, file.st_uid == getuid(),
              file.st_mode & 0o777 == 0o600, file.st_nlink == 1, file.st_size <= 4097 else { return nil }
        let count = read(descriptor, &bytes, bytes.count)
        guard count > 0, count <= 4097, let text = String(bytes: bytes[0..<count], encoding: .utf8) else { return nil }
        return RelayAgentLoginURL.signInURL(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Removes a login's marker and hand-off files, if any are left.
    static func discard(id: String, in directory: URL = directory) {
        guard validID(id) else { return }
        unlink(directory.appendingPathComponent(id + ".issued").path)
        handoffs(id, in: directory).forEach { unlink(directory.appendingPathComponent($0).path) }
    }

    /// The code Claude's sign-in page shows for pasting back: "code#state".
    /// CR and LF are removed first; what is left must be exactly one such
    /// value. `redact` removes every value this accepts.
    static func claudeCode(_ text: String) -> String? {
        let value = text.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
            .trimmingCharacters(in: .whitespaces)
        return validClaudeCode(value) ? value : nil
    }

    static let codePattern = "[A-Za-z0-9_-]{8,512}#[A-Za-z0-9_-]{1,512}"

    static func validClaudeCode(_ code: String) -> Bool {
        code.range(of: "^" + codePattern + "$", options: .regularExpression) != nil
    }

    /// Claude's own paste prompt, exactly as its login prints it.
    static let pastePrompt = "Paste code here if prompted >"

    /// Claude's login is waiting for a code: its prompt, with nothing typed,
    /// is the last non-empty line.
    static func awaitsCode(_ viewport: String?) -> Bool {
        guard let viewport else { return false }
        let last = viewport.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty } ?? ""
        return last == pastePrompt
    }

    /// Text with sign-in codes removed: device codes, OAuth `code=` and
    /// `state=` values and every "code#state" value Relay would accept.
    /// Diagnostics and messages use this.
    static func redact(_ text: String) -> String {
        var result = text
        // The last pattern starts only where a run of its characters starts,
        // and takes the run possessively: unanchored, a long run without "#"
        // (a hash, base64) was retried from every position, quadratic time.
        for pattern in [#"(?<![A-Z0-9-])[A-Z0-9]{4}-[A-Z0-9]{4,5}(?![A-Z0-9-])"#,
                        #"(?<=[?&#](code|state)=)[^&#\s]+"#,
                        #"(?<![A-Za-z0-9_-])[A-Za-z0-9_-]{8,}+#[A-Za-z0-9_-]+"#] {
            result = result.replacingOccurrences(of: pattern, with: "[redacted]", options: .regularExpression)
        }
        return result
    }

    private static func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    private static func ownDirectory(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR && info.st_uid == getuid()
    }

    private static func failure(_ text: String) -> NSError {
        NSError(domain: "RelayAgentSignIn", code: 1, userInfo: [NSLocalizedDescriptionKey: text + "; nothing was changed."])
    }
}

/// The login pane as the code hand-off sees it at one moment.
struct RelayAgentSignInPaneState: Equatable, Sendable {
    let paneID: UUID
    let hostID: UUID
    let connected: Bool
    let inputLeaseHeld: Bool
    /// The transport incarnation producing the pane's output.
    let producer: UUID
    /// Commands the pane's shell has started, and whether its own prompt
    /// is showing (from its semantic prompt marks).
    let execution: UInt64
    let shellPromptShown: Bool
    let viewport: String?
}

/// The login a code hand-off is bound to, captured when its pane first
/// showed Claude's paste prompt: the pane, its transport incarnation and
/// shell command, and the provider process itself (pid and start).
struct RelayAgentSignInBinding: Equatable, Sendable {
    let paneID: UUID
    let hostID: UUID
    let producer: UUID
    let execution: UInt64
    let processID: Int
    let processStart: String
}

/// Where a code hand-off reads the pane and the host's processes and
/// types; TerminalRuntime in Relay, a fixture in tests.
@MainActor protocol RelayAgentSignInPort: AnyObject {
    func signInPaneState() -> RelayAgentSignInPaneState?
    /// The host's process inventory rows (relayd's process_list).
    func signInProcesses() async throws -> [[String: Any]]
    func sendSignInInput(_ data: Data) -> Bool
}

enum RelayAgentSignInDelivery {
    private static let shells: Set<String> = ["bash", "zsh", "fish", "sh", "dash", "ksh"]

    /// The provider process of the login running in `paneID`: exactly one
    /// process named `executable` (or "claude"), a child of the pane's Relay
    /// shell, leading its own process group (the shell's foreground job).
    static func loginProcess(_ rows: [[String: Any]], paneID: UUID, executable: String) -> (pid: Int, start: String)? {
        let pane = paneID.uuidString.lowercased()
        func name(_ row: [String: Any]) -> String { ((row["name"] as? String ?? "") as NSString).lastPathComponent }
        let shell = rows.filter {
            ($0["pane_id"] as? String)?.lowercased() == pane && ($0["relationship"] as? String) == "Relay terminal" &&
                shells.contains(name($0))
        }
        guard shell.count == 1, let shellPID = shell[0]["pid"] as? Int else { return nil }
        let names: Set<String> = ["claude", (executable as NSString).lastPathComponent]
        let login = rows.filter {
            ($0["pane_id"] as? String)?.lowercased() == pane && $0["parent_pid"] as? Int == shellPID &&
                names.contains(name($0)) && $0["group_pid"] as? Int == $0["pid"] as? Int
        }
        guard login.count == 1, let pid = login[0]["pid"] as? Int, pid > 1,
              let start = login[0]["start"] as? String, !start.isEmpty else { return nil }
        return (pid, start)
    }

    /// Captures the binding while Claude's prompt is showing in the pane.
    @MainActor static func bind(_ port: RelayAgentSignInPort, executable: String) async -> RelayAgentSignInBinding? {
        guard let before = port.signInPaneState(), before.connected, !before.shellPromptShown,
              RelayAgentSignIn.awaitsCode(before.viewport),
              let rows = try? await port.signInProcesses(),
              let process = loginProcess(rows, paneID: before.paneID, executable: executable),
              let after = port.signInPaneState(), after.paneID == before.paneID, after.hostID == before.hostID,
              after.producer == before.producer, after.execution == before.execution else { return nil }
        return RelayAgentSignInBinding(paneID: before.paneID, hostID: before.hostID, producer: before.producer,
                                       execution: before.execution, processID: process.pid, processStart: process.start)
    }

    /// Why the pane cannot take the code now, or nil.
    static func refusal(_ state: RelayAgentSignInPaneState?, binding: RelayAgentSignInBinding) -> String? {
        guard let state, state.paneID == binding.paneID, state.hostID == binding.hostID else {
            return "The login pane is gone"
        }
        guard state.connected, state.producer == binding.producer else { return "The login pane's connection changed" }
        guard state.execution == binding.execution, !state.shellPromptShown else { return "The login has ended" }
        guard !state.inputLeaseHeld else { return "Another input operation holds the login pane" }
        guard RelayAgentSignIn.awaitsCode(state.viewport) else { return "The login is not waiting for a code" }
        return nil
    }

    /// Types `code` and Return into the bound login: only while the pane,
    /// its transport and shell command are the ones captured, Claude's
    /// prompt is showing with nothing typed, and the captured provider
    /// process is still the shell's foreground login. The pane is checked
    /// again after the host's answer, just before typing. Returns why
    /// nothing was typed, or nil.
    @MainActor static func deliver(_ code: String, binding: RelayAgentSignInBinding, executable: String,
                        port: RelayAgentSignInPort) async -> String? {
        guard RelayAgentSignIn.validClaudeCode(code) else { return "That is not a code from Claude's sign-in page" }
        if let refusal = refusal(port.signInPaneState(), binding: binding) { return refusal }
        guard let rows = try? await port.signInProcesses() else { return "The login process could not be checked" }
        guard let process = loginProcess(rows, paneID: binding.paneID, executable: executable),
              process.pid == binding.processID, process.start == binding.processStart else {
            return "The login process has ended or changed"
        }
        if let refusal = refusal(port.signInPaneState(), binding: binding) { return refusal }
        return port.sendSignInInput(Data((code + "\r").utf8)) ? nil : "The login pane did not accept input"
    }
}

/// Which pages the sign-in window loads. Every navigation, top-level or
/// in a frame, must be https on one of the providers' sign-in hosts, or
/// the exact loopback callback (http, localhost or 127.0.0.1, its port and
/// path) that this sign-in's own URL names as its redirect_uri. Anything
/// else is cancelled and offered as "Open in browser".
enum RelayAgentSignInNavigation {
    static let hosts: Set<String> = ["claude.ai", "claude.com", "platform.claude.com", "console.anthropic.com", "auth.openai.com"]

    /// The CLI's own loopback callback for this sign-in, if it names one.
    static func callback(for signIn: URL) -> URLComponents? {
        guard let value = URLComponents(url: signIn, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "redirect_uri" })?.value,
              let callback = URLComponents(string: value), callback.scheme == "http",
              ["localhost", "127.0.0.1"].contains(callback.host ?? ""), let port = callback.port, port > 0,
              callback.user == nil, callback.password == nil, !callback.path.isEmpty else { return nil }
        return callback
    }

    /// Hosts allowed only inside a frame of a provider's page, never as the
    /// page itself: the challenge frames providers embed. Exact hosts; one is
    /// added only after a blocked navigation showed it (see `blockedHost`).
    static let frameHosts: Set<String> = ["challenges.cloudflare.com"]

    /// `subframe`: the navigation targets a frame inside the page, not the
    /// page itself.
    static func allows(_ url: URL, callback: URLComponents?, subframe: Bool = false) -> Bool {
        guard let target = URLComponents(url: url, resolvingAgainstBaseURL: false),
              target.user == nil, target.password == nil else { return false }
        if url.absoluteString == "about:blank" || url.absoluteString == "about:srcdoc" { return true }
        if target.scheme == "https", target.port == nil, let host = target.host?.lowercased(),
           hosts.contains(host) || (subframe && frameHosts.contains(host)) {
            return true
        }
        guard let callback else { return false }
        return target.scheme == "http" && target.host == callback.host && target.port == callback.port &&
            target.path == callback.path
    }

    /// Only the host name of a refused navigation, for the diagnostic log:
    /// never its path, query or fragment, which can carry codes.
    static func blockedHost(_ url: URL) -> String {
        guard let host = URLComponents(url: url, resolvingAgainstBaseURL: false)?.host?.lowercased(), host.count <= 253,
              host.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }) else {
            return url.scheme.map { $0.count <= 16 && $0.allSatisfy(\.isLetter) ? $0 + ":" : "unknown" } ?? "unknown"
        }
        return host
    }
}

/// The sign-in window: Relay's own web view, in Relay, with a website data
/// store only Relay uses (kept, so a provider remembers its sign-in between
/// logins). Relay adds no scripts and reads no form, page or cookie: the
/// provider's page completes the CLI's login itself (its loopback callback
/// on This Mac), or shows the code a remote login waits for, which the user
/// types into Relay's field. Passkeys need the system browser: "Open in
/// browser" opens the page there, only when clicked.
@MainActor final class RelayAgentSignInWindow: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    /// Relay's sign-in website data, separate from every other web view.
    static let dataStoreID = UUID(uuidString: "6f3a2d1e-5b4c-4e8f-9a07-52c1d0e3b9a4")!

    /// The page Relay refused, and what "Open in browser" opens for it (the
    /// whole page when a frame was refused).
    @Published private(set) var blocked: URL?
    private var offer: URL?
    private var window: NSWindow?
    private var webView: WKWebView?
    private var callback: URLComponents?
    private(set) var isOpen = false
    /// Called when the user closes the window before the login finished.
    var onClose: (() -> Void)?

    /// Opens `url` (already allowlisted) in the sign-in window.
    func open(_ url: URL, workspace: String?, code: String?) {
        close()
        guard RelayAgentLoginURL.signInURL(url.absoluteString) != nil else { return }
        callback = RelayAgentSignInNavigation.callback(for: url)
        blocked = nil
        offer = nil
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: Self.dataStoreID)
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 720),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Relay sign-in"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: RelayAgentSignInWindowView(
            model: self, webView: webView, workspace: workspace, code: code))
        if let anchor = NSApp.keyWindow ?? NSApp.mainWindow {
            window.setFrameTopLeftPoint(NSPoint(x: anchor.frame.midX - 260, y: anchor.frame.maxY - 40))
        } else {
            window.center()
        }
        self.window = window
        self.webView = webView
        isOpen = true
        window.makeKeyAndOrderFront(nil)
        webView.load(URLRequest(url: url))
    }

    func close() {
        isOpen = false
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView = nil
        window?.delegate = nil
        window?.close()
        window = nil
    }

    /// Opens the blocked page, or else the current one, in the default
    /// browser: only from the user's click.
    func openInBrowser() {
        guard let url = offer ?? webView?.url, url.scheme == "https" else { return }
        NSWorkspace.shared.open(url)
    }

    /// Records which host was refused (host name only), so a live sign-in
    /// shows which challenge host a provider really uses.
    private static func logBlocked(_ url: URL, kind: String) {
        RelayDiagnostics.shared.record(category: "agent-sign-in", name: "navigation-blocked",
                                       details: ["host": RelayAgentSignInNavigation.blockedHost(url), "target": kind])
    }

    func windowWillClose(_ notification: Notification) {
        guard isOpen else { return }
        isOpen = false
        webView = nil
        window = nil
        onClose?()
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { return decisionHandler(.cancel) }
        let subframe = navigationAction.targetFrame.map { !$0.isMainFrame } ?? false
        if navigationAction.targetFrame != nil, RelayAgentSignInNavigation.allows(url, callback: callback, subframe: subframe) {
            return decisionHandler(.allow)
        }
        Self.logBlocked(url, kind: subframe ? "frame" : "page")
        // A frame's page is offered as the whole page it sits in.
        blocked = url
        offer = navigationAction.targetFrame?.isMainFrame == false ? webView.url : url
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        // Nothing is downloaded or saved.
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // No second window: a new-window link is offered for the browser.
        if let url = navigationAction.request.url { Self.logBlocked(url, kind: "new-window") }
        blocked = navigationAction.request.url
        offer = navigationAction.request.url
        return nil
    }
}

extension RelayAgentSignInWindow {
    /// Signs Relay's sign-in window out of every provider by deleting its
    /// website data store (cookies, storage and caches). The CLIs' own logins
    /// and every other browser are not touched. Callers close the windows
    /// first; while a page still uses the store its data is removed in place.
    /// Returns whether the store is empty afterwards. Tests pass their own
    /// store.
    static func clearStore(_ identifier: UUID = dataStoreID) async -> Bool {
        do {
            try await WKWebsiteDataStore.remove(forIdentifier: identifier)
        } catch {
            await WKWebsiteDataStore(forIdentifier: identifier)
                .removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        }
        let store = WKWebsiteDataStore(forIdentifier: identifier)
        let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        let cookies = await store.httpCookieStore.allCookies()
        return records.isEmpty && cookies.isEmpty
    }
}

/// The window's content: what to choose, a device code, a blocked page,
/// the browser button, and the provider's page.
struct RelayAgentSignInWindowView: View {
    @ObservedObject var model: RelayAgentSignInWindow
    let webView: WKWebView
    let workspace: String?
    let code: String?

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Choose workspace: " + (workspace ?? "the one this slot is for"))
                    .font(RelayTheme.font(size: 12, weight: .semibold))
                if let code {
                    HStack(spacing: 8) {
                        Text("Code").foregroundStyle(RelayTheme.textMuted)
                        Text(code).font(RelayTheme.font(size: 13, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(code, forType: .string)
                        }
                    }
                    .font(RelayTheme.font(size: 11.5))
                }
                if let blocked = model.blocked {
                    Text("Relay's sign-in window does not open \(blocked.host ?? "this page").")
                        .font(RelayTheme.font(size: 11)).foregroundStyle(RelayTheme.coral)
                }
                HStack {
                    Spacer()
                    Button("Open in browser") { model.openInBrowser() }
                        .help("Opens this sign-in in your default browser, outside Relay: for passkeys, or a page Relay's window does not open.")
                }
                .font(RelayTheme.font(size: 11))
            }
            .padding(10)
            Divider()
            RelayAgentSignInWebView(webView: webView)
        }
    }
}

struct RelayAgentSignInWebView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
