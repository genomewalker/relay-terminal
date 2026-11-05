import Foundation
import Testing
import WebKit
@testable import Relay

@Suite("Agent sign-in inside Relay: helper hand-off, allowlist and code redaction")
struct AgentSignInTests {
    func temporaryHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("relay-signin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    /// Runs the installed helper as the provider CLI would: `$BROWSER <url>`.
    func runHelper(home: URL, id: String, url: String) throws -> Int32 {
        let process = Process()
        process.executableURL = home.appendingPathComponent(".relay/signin/" + RelayAgentSignIn.helperName)
        process.arguments = [url]
        process.environment = ["HOME": home.path, "RELAY_SIGNIN_ID": id, "PATH": "/usr/bin:/bin"]
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    func mode(_ url: URL) throws -> Int? {
        try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
    }

    func handoffs(_ directory: URL, _ id: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix(id + ".") && !$0.hasSuffix(".issued") }
    }

    @Test("The helper hands an issued ID's URL to Relay once, in an exclusive 0600 file with an unpredictable name")
    func helperCapture() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let directory = home.appendingPathComponent(".relay/signin")
        try RelayAgentSignIn.installHelper(in: directory)
        #expect(try mode(directory) == 0o700)
        let id = try RelayAgentSignIn.issue(in: directory)
        #expect(try mode(directory.appendingPathComponent(id + ".issued")) == 0o600)
        let url = "https://claude.com/cai/oauth/authorize?code=true&client_id=x&redirect_uri=http%3A%2F%2Flocalhost%3A54545%2Fcallback&state=abc"
        #expect(try runHelper(home: home, id: id, url: url) == 0)
        let names = try handoffs(directory, id)
        #expect(names.count == 1 && names[0].count == id.count + 17)
        #expect(try mode(directory.appendingPathComponent(names[0])) == 0o600)
        #expect(RelayAgentSignIn.takeURL(id: id, in: directory)?.absoluteString == url)
        // Once only, and the file is gone.
        #expect(RelayAgentSignIn.takeURL(id: id, in: directory) == nil)
        #expect(try handoffs(directory, id).isEmpty)
        // An unexpected page is dropped, and its file removed.
        for hostile in ["http://claude.ai/login", "https://evil.example/claude.ai", "https://chatgpt.com/auth",
                        "https://auth.openai.com:8443/x", "https://user@claude.ai/x", "file:///etc/passwd",
                        "https://claude.com/blog", "https://auth.openai.com/oauth/authorize/../../x"] {
            let other = try RelayAgentSignIn.issue(in: directory)
            #expect(try runHelper(home: home, id: other, url: hostile) == 0)
            #expect(RelayAgentSignIn.takeURL(id: other, in: directory) == nil, "\(hostile)")
            #expect(try handoffs(directory, other).isEmpty)
        }
        // A malformed ID, or a well-formed one Relay did not issue, is refused.
        for bad in ["../x", "deadbeef", id.uppercased(), id + "0", UUID().uuidString.lowercased()] {
            #expect(try runHelper(home: home, id: bad, url: url) != 0, "\(bad)")
            #expect(RelayAgentSignIn.takeURL(id: bad, in: directory) == nil)
        }
        // A retired ID is refused by the helper too.
        let retired = try RelayAgentSignIn.issue(in: directory)
        RelayAgentSignIn.retire(retired, in: directory)
        #expect(try runHelper(home: home, id: retired, url: url) != 0)
        // The helper refuses a folder that is not private.
        let open = try RelayAgentSignIn.issue(in: directory)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        #expect(try runHelper(home: home, id: open, url: url) != 0)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        #expect(try handoffs(directory, open).isEmpty)
        // A link in the helper's place is never written through.
        let helper = directory.appendingPathComponent(RelayAgentSignIn.helperName)
        try FileManager.default.removeItem(at: helper)
        try FileManager.default.createSymbolicLink(at: helper, withDestinationURL: home.appendingPathComponent("elsewhere"))
        #expect(throws: (any Error).self) { try RelayAgentSignIn.installHelper(in: directory) }
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("elsewhere").path))
    }

    @Test("Relay takes only one private, single-link hand-off of an ID it issued, at most once")
    func consumer() throws {
        let home = try temporaryHome()
        let directory = home.appendingPathComponent(".relay/signin")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: home)
        }
        try RelayAgentSignIn.installHelper(in: directory)
        let url = "https://claude.com/cai/oauth/authorize?state=fixture"
        @discardableResult func place(_ id: String, mode: Int = 0o600, suffix: String = "AbCdEfGh12345678") throws -> URL {
            let file = directory.appendingPathComponent(id + "." + suffix)
            try Data((url + "\n").utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path)
            return file
        }
        // Not issued by Relay: ignored, and swept at the next install.
        let stranger = UUID().uuidString.lowercased()
        try place(stranger)
        #expect(RelayAgentSignIn.takeURL(id: stranger, in: directory) == nil)
        try RelayAgentSignIn.installHelper(in: directory)
        #expect(try handoffs(directory, stranger).isEmpty)
        // Readable by others: refused, consumed and removed.
        let readable = try RelayAgentSignIn.issue(in: directory)
        try place(readable, mode: 0o644)
        #expect(RelayAgentSignIn.takeURL(id: readable, in: directory) == nil)
        #expect(try handoffs(directory, readable).isEmpty)
        try place(readable)
        #expect(RelayAgentSignIn.takeURL(id: readable, in: directory) == nil)
        // A second link to the file: refused.
        let linked = try RelayAgentSignIn.issue(in: directory)
        try FileManager.default.linkItem(at: try place(linked), to: home.appendingPathComponent("second-link"))
        #expect(RelayAgentSignIn.takeURL(id: linked, in: directory) == nil)
        // A link in the hand-off's place is not followed.
        let symlinked = try RelayAgentSignIn.issue(in: directory)
        try Data((url + "\n").utf8).write(to: home.appendingPathComponent("target"))
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent(symlinked + ".AbCdEfGh12345678"),
                                                   withDestinationURL: home.appendingPathComponent("target"))
        #expect(RelayAgentSignIn.takeURL(id: symlinked, in: directory) == nil)
        #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent("target").path))
        // Two hand-offs for one ID: none is taken.
        let twice = try RelayAgentSignIn.issue(in: directory)
        try place(twice)
        try place(twice, suffix: "ZyXwVuTs87654321")
        #expect(RelayAgentSignIn.takeURL(id: twice, in: directory) == nil)
        // A folder that is not private: nothing is taken.
        let open = try RelayAgentSignIn.issue(in: directory)
        try place(open)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        #expect(RelayAgentSignIn.takeURL(id: open, in: directory) == nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        #expect(RelayAgentSignIn.takeURL(id: open, in: directory)?.absoluteString == url)
        // Removal fails: the URL is still returned at most once.
        let stuck = try RelayAgentSignIn.issue(in: directory)
        try place(stuck)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        let first = RelayAgentSignIn.takeURL(id: stuck, in: directory), second = RelayAgentSignIn.takeURL(id: stuck, in: directory)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let third = RelayAgentSignIn.takeURL(id: stuck, in: directory), fourth = RelayAgentSignIn.takeURL(id: stuck, in: directory)
        #expect([first, second, third, fourth].compactMap { $0 }.count <= 1)
        // Retired: never taken.
        let retired = try RelayAgentSignIn.issue(in: directory)
        try place(retired)
        RelayAgentSignIn.retire(retired, in: directory)
        #expect(try handoffs(directory, retired).isEmpty)
        #expect(RelayAgentSignIn.takeURL(id: retired, in: directory) == nil)
    }

    @Test("The sign-in window loads only the providers' https pages and this sign-in's own loopback callback")
    func navigationPolicy() throws {
        let local = try #require(URL(string: "https://claude.com/cai/oauth/authorize?code=true&redirect_uri=http%3A%2F%2Flocalhost%3A54545%2Fcallback&state=s"))
        let callback = RelayAgentSignInNavigation.callback(for: local)
        #expect(callback?.port == 54545 && callback?.path == "/callback")
        for allowed in ["https://claude.ai/login", "https://platform.claude.com/oauth/code/callback?code=x",
                        "https://auth.openai.com/u/login", "http://localhost:54545/callback?code=x&state=s", "about:blank"] {
            #expect(RelayAgentSignInNavigation.allows(try #require(URL(string: allowed)), callback: callback), "\(allowed)")
        }
        for refused in ["http://localhost:54546/callback", "http://localhost:54545/other", "http://127.0.0.1:54545/callback",
                        "https://accounts.google.com/o/oauth2", "http://claude.ai/login", "https://claude.ai:8443/x",
                        "https://user@claude.ai/", "https://claude.ai.evil.example/", "file:///etc/passwd", "javascript:alert(1)",
                        "https://chatgpt.com/"] {
            #expect(!RelayAgentSignInNavigation.allows(try #require(URL(string: refused)), callback: callback), "\(refused)")
        }
        // A remote sign-in (https code page) and a device page name no loopback callback.
        let remote = try #require(URL(string: "https://claude.com/cai/oauth/authorize?redirect_uri=https%3A%2F%2Fplatform.claude.com%2Foauth%2Fcode%2Fcallback"))
        #expect(RelayAgentSignInNavigation.callback(for: remote) == nil)
        #expect(!RelayAgentSignInNavigation.allows(try #require(URL(string: "http://localhost:54545/callback")), callback: nil))
        for hostile in ["http://localhost/callback", "http://evil.example:1/callback", "https://localhost:5/callback", "http://u@localhost:5/c"] {
            let url = try #require(URL(string: "https://claude.com/cai/oauth/authorize?redirect_uri=" +
                (hostile.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")))
            #expect(RelayAgentSignInNavigation.callback(for: url) == nil, "\(hostile)")
        }
    }

    @Test("Only the providers' exact sign-in pages are accepted")
    func allowlist() {
        for url in ["https://claude.com/cai/oauth/authorize?x=1", "https://claude.ai/oauth/authorize", "https://platform.claude.com/oauth/authorize",
                    "https://console.anthropic.com/oauth/authorize", "https://auth.openai.com/codex/device",
                    "https://auth.openai.com/oauth/authorize?client_id=x"] {
            #expect(RelayAgentLoginURL.signInURL(url) != nil, "\(url)")
        }
        for url in ["http://auth.openai.com/codex/device", "https://chatgpt.com/", "https://auth.openai.com.evil.test/",
                    "https://claude.ai:444/x", "javascript:alert(1)", "https://api.anthropic.com/api/oauth/x",
                    "https://claude.com/blog", "https://claude.ai/oauth/authorize/extra", "https://auth.openai.com/"] {
            #expect(RelayAgentLoginURL.signInURL(url) == nil, "\(url)")
        }
    }

    @Test("Codex's device page and code come from one block of the pane")
    func deviceBlock() {
        let pane = "Follow these steps to sign in with ChatGPT using device code authorization:\n\n1. Open this link in your browser and sign in\n   https://auth.openai.com/codex/device\n\n2. Enter this one-time code after you are signed in (expires in 15 minutes)\n   WXYZ-9K7Q2\n"
        let device = RelayAgentLoginURL.deviceLogin(in: pane)
        #expect(device?.url.absoluteString == "https://auth.openai.com/codex/device" && device?.code == "WXYZ-9K7Q2")
        #expect(RelayAgentLoginURL.deviceLogin(in: "Enter code ABCD-12345\nhttps://auth.openai.com/codex/device\n") == nil)
        #expect(RelayAgentLoginURL.deviceLogin(in: "https://auth.openai.com/codex/device\nEnter this one-time code\n   see ABCD-12345 below\n") == nil)
        #expect(RelayAgentLoginURL.deviceLogin(in: "https://evil.example/codex/device\n2. Enter this one-time code\nABCD-12345\n") == nil)
    }

    @Test("Sign-in codes are redacted from messages and diagnostics")
    func redaction() {
        let text = "Enter WXYZ-9K7Q2 at https://auth.openai.com/codex/device; callback http://localhost:5/callback?code=SECRETCODE123&state=STATE456 pasted AbCdEfGh123_-#StateValue99 and AbCdEfGh123_-#x"
        let redacted = RelayAgentSignIn.redact(text)
        for secret in ["WXYZ-9K7Q2", "SECRETCODE123", "STATE456", "AbCdEfGh123_-#StateValue99", "AbCdEfGh123_-#x"] {
            #expect(!redacted.contains(secret), "\(secret)")
        }
        #expect(redacted.contains("https://auth.openai.com/codex/device"))
        #expect(!RelayDiagnostics.redact("device code ABCD-12345").contains("ABCD-12345"))
        #expect(RelayAgentSignIn.redact("date 2026-10-18") == "date 2026-10-18")
        // Every value the paste accepts is one the redaction removes.
        for code in ["abcdefgh#y", "A-_b9876#Z-_", String(repeating: "a", count: 512) + "#" + String(repeating: "b", count: 512)] {
            #expect(RelayAgentSignIn.validClaudeCode(code))
            #expect(!RelayAgentSignIn.redact("x " + code + " y").contains(code), "\(code)")
        }
    }

    @Test("A pasted code is exactly one value of Claude's code shape, and the prompt is Claude's exact one")
    func codeShape() {
        #expect(RelayAgentSignIn.claudeCode("AbCdEfGh123_-#StateValue99\r\n") == "AbCdEfGh123_-#StateValue99")
        #expect(RelayAgentSignIn.claudeCode("AbCd\nEfGh123_-#State") == "AbCdEfGh123_-#State")
        for bad in ["", "short#x", "AbCdEfGh123_-", "code with space#x", "AbCdEfGh#x AbCdEfGh#y", "abcdefgh#x;ls",
                    String(repeating: "a", count: 513) + "#x", "abcdefgh#" + String(repeating: "b", count: 513)] {
            #expect(RelayAgentSignIn.claudeCode(bad) == nil, "\(bad)")
        }
        #expect(RelayAgentSignIn.awaitsCode("Browser didn't open? Use the url below\nhttps://claude.com/cai/oauth/authorize?x\n\nPaste code here if prompted > "))
        for text in ["Paste code here if prompted >\nLogin successful.\n$ ", "Paste code here if prompted > abc",
                     "$ echo 'Paste code here if prompted >'", "paste code here if prompted >", nil] {
            #expect(!RelayAgentSignIn.awaitsCode(text), "\(text ?? "nil")")
        }
    }

    @MainActor final class Port: RelayAgentSignInPort {
        var states: [RelayAgentSignInPaneState?]
        var rows: [[String: Any]]
        var afterProcesses: (() -> Void)?
        var sent: [Data] = []
        init(_ state: RelayAgentSignInPaneState?, rows: [[String: Any]]) { states = [state]; self.rows = rows }
        func signInPaneState() -> RelayAgentSignInPaneState? { states.count > 1 ? states.removeFirst() : states[0] }
        func signInProcesses() async throws -> [[String: Any]] { defer { afterProcesses?() }; return rows }
        func sendSignInInput(_ data: Data) -> Bool { sent.append(data); return true }
    }

    static let pane = UUID(), host = UUID(), producer = UUID()
    static func state(producer: UUID = producer, execution: UInt64 = 3, promptShown: Bool = false, lease: Bool = false,
                      connected: Bool = true, viewport: String = "Use the url below\n\nPaste code here if prompted > ") -> RelayAgentSignInPaneState {
        RelayAgentSignInPaneState(paneID: pane, hostID: host, connected: connected, inputLeaseHeld: lease, producer: producer,
                                  execution: execution, shellPromptShown: promptShown, viewport: viewport)
    }
    static func rows(loginStart: String = "100", loginGroup: Int = 41, extraLogin: Bool = false) -> [[String: Any]] {
        let id = pane.uuidString.lowercased()
        var rows: [[String: Any]] = [
            ["pid": 30, "parent_pid": 1, "group_pid": 30, "name": "relayd", "start": "1", "pane_id": id, "relationship": "Relay terminal"],
            ["pid": 40, "parent_pid": 30, "group_pid": 40, "name": "bash", "start": "2", "pane_id": id, "relationship": "Relay terminal"],
            ["pid": 41, "parent_pid": 40, "group_pid": loginGroup, "name": "claude", "start": loginStart, "pane_id": id, "relationship": "Relay terminal"],
            ["pid": 50, "parent_pid": 1, "group_pid": 50, "name": "claude", "start": "7", "pane_id": UUID().uuidString.lowercased(), "relationship": "Relay terminal"],
        ]
        if extraLogin {
            rows.append(["pid": 42, "parent_pid": 40, "group_pid": 42, "name": "claude", "start": "9", "pane_id": id, "relationship": "Relay terminal"])
        }
        return rows
    }

    @Test("A code is typed only into the bound login while it waits, rechecked just before typing")
    @MainActor func boundDelivery() async throws {
        let code = "AbCdEfGh123_-#StateValue99"
        let port = Port(Self.state(), rows: Self.rows())
        let binding = try #require(await RelayAgentSignInDelivery.bind(port, executable: "/usr/local/bin/claude"))
        #expect(binding.processID == 41 && binding.processStart == "100" && binding.execution == 3)
        #expect(await RelayAgentSignInDelivery.deliver(code, binding: binding, executable: "/usr/local/bin/claude", port: port) == nil)
        #expect(port.sent == [Data((code + "\r").utf8)])

        // Each change before the click types nothing.
        let cases: [(String, Port)] = [
            ("login exited", Port(Self.state(execution: 4, promptShown: true, viewport: "$ "), rows: Self.rows())),
            ("login process replaced", Port(Self.state(), rows: Self.rows(loginStart: "101"))),
            ("login process gone", Port(Self.state(), rows: Array(Self.rows().filter { $0["pid"] as? Int != 41 }))),
            ("not the foreground job", Port(Self.state(), rows: Self.rows(loginGroup: 40))),
            ("two logins", Port(Self.state(), rows: Self.rows(extraLogin: true))),
            ("transport changed", Port(Self.state(producer: UUID()), rows: Self.rows())),
            ("disconnected", Port(Self.state(connected: false), rows: Self.rows())),
            ("input lease held", Port(Self.state(lease: true), rows: Self.rows())),
            ("text typed at the prompt", Port(Self.state(viewport: "Paste code here if prompted > abc"), rows: Self.rows())),
            ("pane gone", Port(nil, rows: Self.rows())),
        ]
        for (name, port) in cases {
            #expect(await RelayAgentSignInDelivery.deliver(code, binding: binding, executable: "claude", port: port) != nil, "\(name)")
            #expect(port.sent.isEmpty, "\(name)")
        }
        // The pane changes while the host answers: the second check stops it.
        let racing = Port(Self.state(), rows: Self.rows())
        racing.afterProcesses = { racing.states = [Self.state(execution: 4, promptShown: true, viewport: "$ ")] }
        #expect(await RelayAgentSignInDelivery.deliver(code, binding: binding, executable: "claude", port: racing) != nil)
        #expect(racing.sent.isEmpty)
        // An invalid code is never typed.
        let valid = Port(Self.state(), rows: Self.rows())
        #expect(await RelayAgentSignInDelivery.deliver("AbCdEfGh\r#x", binding: binding, executable: "claude", port: valid) != nil)
        #expect(valid.sent.isEmpty)
        // No binding without Claude's prompt or with an ambiguous login.
        #expect(await RelayAgentSignInDelivery.bind(Port(Self.state(viewport: "$ "), rows: Self.rows()), executable: "claude") == nil)
        #expect(await RelayAgentSignInDelivery.bind(Port(Self.state(), rows: Self.rows(extraLogin: true)), executable: "claude") == nil)
    }

    @Test("A local Claude login names Relay's helper as its browser; nothing else does")
    func loginCommand() {
        let id = "0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0"
        let personal = RelayAgentAccount(provider: "claude", label: "personal", dir: "~/.claude-max")
        #expect(personal.loginCommand(executable: "/Users/a/.local/bin/claude", remote: false, signInID: id) ==
            #"env CLAUDE_CONFIG_DIR="$HOME"/.claude-max BROWSER="$HOME"/.relay/signin/relay-signin-browser RELAY_SIGNIN_ID=0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0 '/Users/a/.local/bin/claude' auth login"#)
        let work = RelayAgentAccount(provider: "claude", label: "work", dir: "")
        #expect(work.loginCommand(executable: "/b/claude", remote: false, replacing: true, signInID: id).hasPrefix(
            "env -u CLAUDE_CONFIG_DIR BROWSER=\"$HOME\"/.relay/signin/relay-signin-browser RELAY_SIGNIN_ID=\(id) '/b/claude' auth logout && "))
        #expect(personal.loginCommand(executable: "/b/claude", remote: true, signInID: id) == "")
        #expect(personal.loginCommand(executable: "/b/claude", remote: false, signInID: "x; rm -rf ~") == "")
        #expect(RelayAgentAccount(provider: "codex", label: "work", dir: "").loginCommand(executable: "/b/codex", remote: false, signInID: id) == "")
        // Codex signs in with its device code on This Mac too.
        #expect(RelayAgentAccount(provider: "codex", label: "work", dir: "").loginCommand(executable: "/b/codex", remote: true) ==
            "env -u CODEX_HOME '/b/codex' login --device-auth")
    }

    @Test("Signing out of the sign-in window deletes its cookies and site data")
    @MainActor func signOutClearsTheStore() async throws {
        // A store of the test's own, never Relay's sign-in store.
        let identifier = UUID()
        let store = WKWebsiteDataStore(forIdentifier: identifier)
        let cookie = try #require(HTTPCookie(properties: [.domain: "claude.ai", .path: "/", .name: "relay-test", .value: "1",
                                                          .secure: "TRUE", .expires: Date().addingTimeInterval(3600)]))
        await store.httpCookieStore.setCookie(cookie)
        #expect(await !store.httpCookieStore.allCookies().isEmpty)
        #expect(await RelayAgentSignInWindow.clearStore(identifier))
        #expect(await WKWebsiteDataStore(forIdentifier: identifier).httpCookieStore.allCookies().isEmpty)
        try? await WKWebsiteDataStore.remove(forIdentifier: identifier)
        #expect(identifier != RelayAgentSignInWindow.dataStoreID)
    }

    @Test("A challenge host is allowed only as a frame, never as the page")
    func challengeFrames() throws {
        let challenge = try #require(URL(string: "https://challenges.cloudflare.com/cdn-cgi/challenge-platform/h/b/turnstile/if/ov2/av0/rcv0/0/abc"))
        #expect(RelayAgentSignInNavigation.allows(challenge, callback: nil, subframe: true))
        #expect(!RelayAgentSignInNavigation.allows(challenge, callback: nil, subframe: false))
        #expect(!RelayAgentSignInNavigation.allows(challenge, callback: nil))
        for refused in ["http://challenges.cloudflare.com/x", "https://challenges.cloudflare.com:8443/x",
                        "https://challenges.cloudflare.com.example.com/x", "https://x.challenges.cloudflare.com/x",
                        "https://user@challenges.cloudflare.com/x", "https://www.google.com/recaptcha/api2/anchor",
                        "https://accounts.google.com/o/oauth2/auth"] {
            #expect(!RelayAgentSignInNavigation.allows(try #require(URL(string: refused)), callback: nil, subframe: true), "\(refused)")
        }
        // Provider pages stay allowed in frames too; identity providers stay blocked at the top.
        #expect(RelayAgentSignInNavigation.allows(try #require(URL(string: "https://claude.ai/login")), callback: nil, subframe: true))
        #expect(!RelayAgentSignInNavigation.allows(try #require(URL(string: "https://accounts.google.com/signin")), callback: nil))
        // The log names the host only.
        let blocked = try #require(URL(string: "https://Accounts.Google.com/o/oauth2/auth?code=SECRETCODE&state=s#frag"))
        #expect(RelayAgentSignInNavigation.blockedHost(blocked) == "accounts.google.com")
        #expect(RelayAgentSignInNavigation.blockedHost(try #require(URL(string: "data:text/html,secret"))) == "data:")
    }
}
