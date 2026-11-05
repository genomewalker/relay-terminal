import Foundation
import Testing
@testable import Relay

@Suite("Agent account identity and usage display")
@MainActor
struct RelayAgentAccountDisplayTests {
    let dandy = ConnectionProfile(name: "dandy-07", kind: .ssh, host: "dandy-07")

    func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    func status(_ label: String, provider: String = "claude", loggedIn: String = "yes", exists: Bool = true,
                email: String? = nil, plan: String? = nil, key: String? = nil, root: String? = nil) throws -> RelayAgentAccountStatus {
        var fields = [#""provider":"\#(provider)""#, #""label":"\#(label)""#, #""dir":"~/.\#(provider)-\#(label)""#,
                      #""root":"\#(root ?? "/h/.\(provider)-\(label)")""#, #""default":false"#, #""exists":\#(exists)"#,
                      #""logged_in":"\#(loggedIn)""#]
        if let email { fields.append(#""email":"\#(email)""#) }
        if let plan { fields.append(#""plan":"\#(plan)""#) }
        if let key { fields.append(#""identity_key":"\#(key)""#) }
        return try decode(RelayAgentAccountStatus.self, "{" + fields.joined(separator: ",") + "}")
    }

    func usage(_ label: String, provider: String = "codex", windows: [(Int?, Double, String?)], status: String = "ok",
               reason: String? = nil, email: String? = nil, key: String? = nil) throws -> RelayAgentAccountUsage {
        let rows = windows.map { minutes, used, reset in
            #"{"name":"primary","used_percent":\#(used)"# + (minutes.map { #","window_minutes":\#($0)"# } ?? "") +
                (reset.map { #","resets_at":"\#($0)""# } ?? "") + "}"
        }
        var json = #"{"provider":"\#(provider)","label":"\#(label)","status":"\#(status)","read_at":"\#(ISO8601DateFormatter().string(from: Date()))","windows":[\#(rows.joined(separator: ","))]"#
        if let reason { json += #","reason":"\#(reason)""# }
        if let email { json += #","email":"\#(email)","plan":"pro""# }
        if let key { json += #","identity_key":"\#(key)""# }
        return try decode(RelayAgentAccountUsage.self, json + "}")
    }

    @Test("Usage windows are labelled from their length, never the provider's window name")
    func windowLabels() throws {
        let labels = try usage("work", windows: [(10080, 0, nil), (300, 4, nil), (1440, 1, nil), (43200, 2, nil),
                                                 (120, 3, nil), (45, 5, nil), (nil, 6, nil)]).orderedWindows.map(\.displayName)
        #expect(labels == ["45-minute", "2-hour", "5-hour", "daily", "weekly", "30-day", "usage window"])
        #expect(!labels.contains("primary"))
    }

    @Test("An account without a directory is 'not set up', not unknown usage")
    func notSetUp() throws {
        let missing = try usage("personal", windows: [], status: "unknown", reason: "account directory does not exist")
        #expect(missing.summary() == "not set up")
        #expect(RelayAgentAccountSummary.line(status: nil, usage: missing) == "not set up")
        #expect(RelayAgentAccountSummary.line(status: try status("personal", loggedIn: "no", exists: false), usage: nil) == "not set up")
        let failed = try usage("work", windows: [], status: "unknown", reason: "codex did not answer in time")
        #expect(failed.summary() == "usage unknown")
    }

    @Test("The account line is identity · 5-hour % · weekly % · resets, leaving out unreported windows")
    func summaryLine() throws {
        let now = ISO8601DateFormatter().date(from: "2026-10-17T20:00:00Z")!
        let soon = "2026-10-17T22:30:00Z", later = "2026-10-21T23:59:00Z"
        let claude = try status("work", email: "ana@example.org", plan: "max")
        let both = try usage("work", provider: "claude", windows: [(10080, 50, later), (300, 4.4, soon)])
        let line = RelayAgentAccountSummary.line(status: claude, usage: both, now: now)
        #expect(line.hasPrefix("ana@example.org (max) · 5-hour 4% · weekly 50% · resets "), "\(line)")
        #expect(line.contains(", weekly "))
        // Codex Pro reports only the weekly window; its identity comes with usage.
        let codex = try usage("work", windows: [(10080, 0, later)], email: "ana@example.org")
        let codexLine = RelayAgentAccountSummary.line(status: try status("work", provider: "codex"), usage: codex, now: now)
        #expect(codexLine.hasPrefix("ana@example.org (pro) · weekly 0% · resets weekly "), "\(codexLine)")
        #expect(!codexLine.contains("5-hour"))
        #expect(RelayAgentAccountSummary.line(status: try status("work", loggedIn: "no"), usage: nil) == "not logged in · usage unknown")
    }

    @Test("Two labels logged in as one identity are reported")
    func sameIdentity() {
        let accounts = RelayAgentAccount.defaults.filter { $0.provider == "codex" } + [.init(provider: "codex", label: "client", dir: "~/.codex-client")]
        let keys = ["work": "k1", "personal": "k1", "client": "k2"]
        #expect(RelayAgentAccountSummary.sameIdentityWarnings(accounts: accounts) { keys[$0.label] } ==
                ["personal is logged in as the same Codex account as work"])
        #expect(RelayAgentAccountSummary.sameIdentityWarnings(accounts: accounts) { _ in nil }.isEmpty)
    }

    @Test("Readings belong to the host they came from and identities combine per host")
    func readingsAreHostBound() throws {
        let directory = RelayAgentAccountDirectory()
        let work = RelayAgentAccount(provider: "codex", label: "work", dir: "")
        let personal = RelayAgentAccount(provider: "codex", label: "personal", dir: "~/.codex-personal")
        directory.store([try usage("work", windows: [(10080, 7, nil)], key: "same"),
                         try usage("personal", windows: [(10080, 7, nil)], key: "same")], fromHost: "local")
        #expect(directory.usage(for: .local, account: work)?.host == "local")
        #expect(directory.usage(for: dandy, account: work) == nil)
        #expect(directory.suggestion(for: dandy, provider: "codex") == nil)
        #expect(directory.sameIdentityWarnings(for: .local, provider: "codex") == ["personal is logged in as the same Codex account as work"])
        #expect(directory.sameIdentityWarnings(for: dandy, provider: "codex").isEmpty)
        directory.store([try usage("personal", windows: [(10080, 9, nil)], key: "other")], fromHost: "dandy-07")
        #expect(directory.usage(for: .local, account: personal)?.windows?.first?.usedPercent == 7)
        #expect(directory.usage(for: dandy, account: personal)?.host == "dandy-07")
    }

    @Test("An unprobed list never overwrites the last probe; a failed fresh probe never inherits an old login")
    func probeProvenance() throws {
        let directory = RelayAgentAccountDirectory()
        var probed = try status("work", email: "ana@example.org", plan: "max", key: "k")
        probed.probe = "ok"
        directory.record([probed], executables: ["claude": "/b/claude", "codex": ""], fromHost: "local", probeRequested: true)
        #expect(directory.statuses["local"]?.first?.checkedAt != nil)
        // A usage, prepare or menu refresh answers without probing.
        directory.record([try status("work", loggedIn: "unknown")], executables: nil, fromHost: "local", probeRequested: false)
        let kept = try #require(directory.statuses["local"]?.first)
        #expect(kept.loggedIn == "yes" && kept.email == "ana@example.org" && kept.plan == "max" && kept.identityKey == "k" && !kept.checkFailed)
        #expect(directory.executable(for: .local, provider: "codex") == "" && directory.executable(for: .local, provider: "claude") == "/b/claude")
        #expect(directory.executable(for: dandy, provider: "claude") == nil)
        // Codex's unprobed answer sees only that auth.json exists; it never overrides the probe.
        var codexProbed = try status("work", provider: "codex")
        codexProbed.method = "chatgpt"
        codexProbed.probe = "ok"
        var codexFile = try status("work", provider: "codex")
        codexFile.method = "file"
        directory.record([codexProbed], executables: nil, fromHost: "dandy-07", probeRequested: true)
        directory.record([codexFile], executables: nil, fromHost: "dandy-07", probeRequested: false)
        #expect(directory.statuses["dandy-07"]?.first?.method == "chatgpt")
        // A fresh probe that fails (timeout, error) is a failed check, not the old login.
        var failed = try status("work", loggedIn: "unknown")
        failed.probe = "failed"
        directory.record([failed], executables: nil, fromHost: "local", probeRequested: true)
        var now = try #require(directory.statuses["local"]?.first)
        #expect(now.loggedIn == "unknown" && now.checkFailed && now.email == nil && now.identityKey == nil)
        #expect(RelayAgentAccountSummary.identity(status: now, usage: nil) == "login check failed")
        // ...and a later unprobed answer does not bring the old login back.
        directory.record([try status("work", loggedIn: "unknown")], executables: nil, fromHost: "local", probeRequested: false)
        now = try #require(directory.statuses["local"]?.first)
        #expect(now.loggedIn == "unknown" && now.checkFailed && now.email == nil)
        // A failed probe of a Codex file login keeps the file's yes but no identity, marked failed.
        var codexFailed = try status("work", provider: "codex", email: "x@example.org", key: "old")
        codexFailed.method = "file"
        codexFailed.probe = "failed"
        directory.record([codexFailed], executables: nil, fromHost: "dandy-07", probeRequested: true)
        now = try #require(directory.statuses["dandy-07"]?.first)
        #expect(now.loggedIn == "yes" && now.checkFailed && now.identityKey == nil && now.email == nil)
        // A relayd without the probe field: a requested probe left unknown is failed.
        directory.record([try status("work", loggedIn: "unknown")], executables: nil, fromHost: "old-host", probeRequested: true)
        #expect(directory.statuses["old-host"]?.first?.checkFailed == true)
        // A later successful probe replaces it.
        directory.record([probed], executables: nil, fromHost: "local", probeRequested: true)
        #expect(directory.statuses["local"]?.first?.loggedIn == "yes" && directory.statuses["local"]?.first?.checkFailed == false)
        // Never across another directory or a removed one.
        directory.record([try status("work", loggedIn: "unknown", root: "/h/elsewhere")], executables: nil, fromHost: "local", probeRequested: false)
        #expect(directory.statuses["local"]?.first?.loggedIn == "unknown")
        directory.record([probed], executables: nil, fromHost: "local", probeRequested: true)
        directory.record([try status("work", loggedIn: "unknown", exists: false)], executables: nil, fromHost: "local", probeRequested: false)
        #expect(directory.statuses["local"]?.first?.email == nil)
    }

    @Test("After a failed check the summary says so and an earlier identity is only last known")
    func failedCheckSummary() throws {
        let now = Date()
        var failed = try status("work", provider: "codex", loggedIn: "unknown")
        failed.probe = "failed"
        let checked = failed.probed(at: now)
        let old = try usage("work", windows: [(10080, 7, nil)], email: "previous@example.org", key: "previous")
        let line = RelayAgentAccountSummary.line(status: checked, usage: old, now: now)
        #expect(line.hasPrefix("login check failed (last known previous@example.org (pro)) · weekly 7%"), "\(line)")
        #expect(line.contains("last reading"))
        #expect(RelayAgentAccountSummary.identity(status: checked, usage: nil) == "login check failed")
        // A failed check also takes the account out of same-identity warnings.
        let directory = RelayAgentAccountDirectory()
        directory.store([old, try usage("personal", windows: [(10080, 7, nil)], email: "previous@example.org", key: "previous")], fromHost: "local")
        #expect(directory.sameIdentityWarnings(for: .local, provider: "codex").count == 1)
        directory.record([failed], executables: nil, fromHost: "local", probeRequested: true)
        #expect(directory.sameIdentityWarnings(for: .local, provider: "codex").isEmpty)
    }

    @Test("A login counts as done only from a fresh, successful provider check")
    func loginOutcomeNeedsAFreshCheck() throws {
        let started = Date()
        func checked(_ loggedIn: String, probe: String, provider: String = "claude", key: String? = nil, at: Date) throws -> RelayAgentAccountStatus {
            var row = try status("work", provider: provider, loggedIn: loggedIn, email: key.map { _ in "new@example.org" }, plan: key.map { _ in "max" }, key: key)
            row.probe = probe
            return row.probed(at: at)
        }
        func outcome(_ status: RelayAgentAccountStatus?, provider: String = "claude", usage: RelayAgentAccountUsage? = nil,
                     replacing: Bool = false, replaced: String? = nil) -> RelayAgentLoginState.Phase {
            RelayAgentLoginMonitor.outcome(status: status, checkStarted: started, freshUsage: usage, provider: provider,
                                           replacing: replacing, replacedKey: replaced, paneClosed: false)
        }
        func failed(_ phase: RelayAgentLoginState.Phase) -> Bool { if case .failed = phase { return true }; return false }
        // A credential file says yes, but the provider's check failed: not signed in.
        var fileOnly = try status("work", provider: "codex", loggedIn: "yes")
        fileOnly.method = "file"
        fileOnly.probe = "failed"
        #expect(failed(outcome(fileOnly.probed(at: started), provider: "codex")))
        // A check from before this login does not count, nor does an unchecked row.
        #expect(failed(outcome(try checked("yes", probe: "ok", key: "k", at: started.addingTimeInterval(-5)))))
        #expect(failed(outcome(try status("work", loggedIn: "yes"))))
        #expect(failed(outcome(nil)))
        #expect(outcome(try checked("yes", probe: "ok", key: "k", at: started)) == .finished("Logged in as new@example.org (max)."))
        #expect(failed(outcome(try checked("no", probe: "ok", at: started))))
        // Signing in again: the fresh identity must differ from the replaced one.
        #expect(failed(outcome(try checked("yes", probe: "ok", key: "old", at: started), replacing: true, replaced: "old")))
        #expect(outcome(try checked("yes", probe: "ok", key: "new", at: started), replacing: true, replaced: "old") == .finished("Logged in as new@example.org (max)."))
        // Codex: identity only from a usage reading taken after the check; none means unverified.
        let codex = try checked("yes", probe: "ok", provider: "codex", at: started)
        #expect(failed(outcome(codex, provider: "codex", replacing: true, replaced: "old")))
        let freshOld = try usage("work", windows: [(10080, 1, nil)], email: "old@example.org", key: "old")
        #expect(failed(outcome(codex, provider: "codex", usage: freshOld, replacing: true, replaced: "old")))
        let freshNew = try usage("work", windows: [(10080, 1, nil)], email: "new@example.org", key: "new")
        #expect(outcome(codex, provider: "codex", usage: freshNew, replacing: true, replaced: "old") == .finished("Logged in as new@example.org (pro)."))
        #expect(outcome(codex, provider: "codex") == .finished("Logged in."))
    }

    @Test("A selected host that disappears is shown as missing, never as This Mac")
    func missingHostIsNotLocal() {
        let other = ConnectionProfile(name: "other", kind: .ssh, host: "other", usesSSHConfig: true)
        let hosts = [ConnectionProfile.local, other]
        let gone = "config:relay-review-gone"
        let shown = RelayAgentAccountsSettingsView.host(gone, in: hosts)
        #expect(shown.kind == .ssh && shown.host.isEmpty && shown.name == "relay-review-gone (missing)")
        #expect(!RelayAgentAccountsSettingsView.isAvailable(gone, in: hosts))
        #expect(!RelayAgentAccountsSettingsView.isAvailable(gone, in: [.local]))
        #expect(RelayAgentAccountDirectory.hostKey(shown) != "local")
        // Only no choice or This Mac's own key is This Mac.
        #expect(RelayAgentAccountsSettingsView.host(nil, in: hosts).kind == .local)
        #expect(RelayAgentAccountsSettingsView.host("local", in: [.local]).kind == .local)
        #expect(RelayAgentAccountsSettingsView.isAvailable(nil, in: []) && RelayAgentAccountsSettingsView.isAvailable("local", in: hosts))
        let present = RelayAgentAccountsSettingsView.selectionKey(other)
        #expect(RelayAgentAccountsSettingsView.host(present, in: hosts).host == "other" && RelayAgentAccountsSettingsView.isAvailable(present, in: hosts))
    }

    @Test("Only a provider sign-in URL in the login pane is offered, joined across wrapped lines")
    func signInURL() {
        let url = "https://claude.ai/oauth/authorize?code=true&client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e&response_type=code&redirect_uri=https%3A%2F%2Fconsole.anthropic.com%2Foauth%2Fcode%2Fcallback&scope=user%3Ainference&state=abc"
        var chunks: [String] = []
        var rest = Substring(url)
        while !rest.isEmpty { chunks.append(String(rest.prefix(80))); rest = rest.dropFirst(80) }
        let pane = (["$ env -u CLAUDE_CONFIG_DIR '/b/claude' auth login", "Browser didn't open? Use the url below to sign in:", ""] + chunks +
                    ["", "Paste code here if prompted >"]).joined(separator: "\n")
        #expect(RelayAgentLoginURL.find(in: pane)?.absoluteString == url)
        let device = "Follow these steps to sign in with ChatGPT using device code authorization:\n\n1. Open this link in your browser\n   https://auth.openai.com/codex/device\n\n2. Enter this one-time code\n   ABCD-12345\n"
        #expect(RelayAgentLoginURL.find(in: device)?.absoluteString == "https://auth.openai.com/codex/device")
        for hostile in ["http://claude.ai/oauth", "https://claude.ai.evil.example/oauth", "https://evil.example/?https://claude.ai",
                        "https://user@claude.ai/x", "https://claude.ai:8443/x", "javascript:alert(1)", "https://chatgpt.com.evil/x"] {
            #expect(RelayAgentLoginURL.find(in: "open " + hostile + " now") == nil, "\(hostile)")
        }
    }

    @Test("Only an installed Relay repairs This Mac's launchers when it starts")
    func startRepairGate() {
        let environment = ["HOME": "/Users/ana"]
        #expect(RelayAgentAccountDirectory.repairsLaunchersAtStart(bundlePath: "/Applications/Relay.app", environment: environment, isolated: false))
        #expect(RelayAgentAccountDirectory.repairsLaunchersAtStart(bundlePath: "/Users/ana/Applications/Relay.app", environment: environment, isolated: false))
        for path in ["/private/tmp/relay-build-1622/Relay.app", "/Applications/Old/Relay.app", "/Users/ana/dev/Relay.app",
                     "/Applications/relayd"] {
            #expect(!RelayAgentAccountDirectory.repairsLaunchersAtStart(bundlePath: path, environment: environment, isolated: false), "\(path)")
        }
        #expect(!RelayAgentAccountDirectory.repairsLaunchersAtStart(bundlePath: "/Applications/Relay.app", environment: environment, isolated: true))
        #expect(!RelayAgentAccountDirectory.repairsLaunchersAtStart(bundlePath: "/Applications/Relay.app",
            environment: environment.merging(["RELAY_TESTING": "1"]) { $1 }, isolated: false))
    }

    @Test("Launcher states read as plain status")
    func launcherStates() throws {
        let launchers = try decode([RelayAgentLauncherStatus].self, #"""
        [{"provider":"claude","path":"/h/.local/share/relay/shims/claude","state":"installed","mode":"0700"},
         {"provider":"codex","path":"/h/.local/share/relay/shims/codex","state":"foreign"},
         {"provider":"claude","path":"/h/.local/share/relay/shims/claude","state":"unavailable","detail":"relayd is not installed at ~/.local/bin/relayd on this host"}]
        """#)
        #expect(launchers.map(\.usable) == [true, false, false])
        #expect(launchers[0].summary == "Claude launcher installed")
        #expect(launchers[1].summary == "Codex launcher is not Relay's; left unchanged")
        #expect(launchers[2].summary == "Claude launcher unavailable (relayd is not installed at ~/.local/bin/relayd on this host)")
    }
}
