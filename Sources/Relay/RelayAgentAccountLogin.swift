import AppKit
import Foundation

/// The provider's sign-in page in a login pane's output. The pane is
/// untrusted text: only an https URL whose host and path are one of the
/// providers' own sign-in endpoints is offered, and it is shown only in
/// Relay's sign-in window.
enum RelayAgentLoginURL {
    /// Each sign-in host with the exact paths of its authorization or device
    /// page (Claude's subscription and Console logins, Codex's browser and
    /// device logins).
    static let endpoints: [String: Set<String>] = [
        "claude.com": ["/cai/oauth/authorize"], "claude.ai": ["/oauth/authorize"],
        "platform.claude.com": ["/oauth/authorize"], "console.anthropic.com": ["/oauth/authorize"],
        "auth.openai.com": ["/oauth/authorize", "/codex/device"],
    ]
    static let codexDevice = "https://auth.openai.com/codex/device"
    private static let urlCharacters = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~:/?#[]@!$&'()*+,;=%")

    /// The last sign-in URL in `text`. A URL the terminal wrapped at the
    /// pane's width continues on the following lines when the line it is on
    /// ends at that width and the next line is URL characters only.
    static func find(in text: String) -> URL? {
        let lines = text.components(separatedBy: "\n").map { $0.replacingOccurrences(of: "\r", with: "") }
        let width = lines.map(\.count).max() ?? 0
        var found: URL?
        for (index, line) in lines.enumerated() {
            guard let start = line.range(of: "https://") else { continue }
            var candidate = String(line[start.lowerBound...].prefix { !$0.isWhitespace })
            var next = index + 1
            var current = line
            while current.count >= width, width >= 20, next < lines.count {
                let continuation = lines[next].trimmingCharacters(in: .whitespaces)
                guard !continuation.isEmpty, !continuation.contains(" "),
                      continuation.unicodeScalars.allSatisfy(urlCharacters.contains) else { break }
                candidate += continuation
                current = lines[next]
                next += 1
            }
            if let url = signInURL(candidate) { found = url }
        }
        return found
    }

    static func signInURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: ".,;)>]\"'"))
        guard trimmed.count <= 4096, trimmed.unicodeScalars.allSatisfy(urlCharacters.contains),
              let components = URLComponents(string: trimmed), components.scheme == "https",
              components.user == nil, components.password == nil, components.port == nil,
              let host = components.host?.lowercased(), endpoints[host]?.contains(components.path) == true,
              let url = components.url
        else { return nil }
        return url
    }

    /// Codex's device login as its pane shows it: the device page, then
    /// "Enter this one-time code" and the code alone on a following line.
    /// The URL and the code come from that one block, the last one shown.
    static func deviceLogin(in text: String) -> (url: URL, code: String)? {
        let lines = text.components(separatedBy: "\n").map { $0.replacingOccurrences(of: "\r", with: "")
            .trimmingCharacters(in: .whitespaces) }
        guard let page = lines.lastIndex(where: { $0 == codexDevice }), let url = URL(string: codexDevice) else { return nil }
        let after = lines[(page + 1)...].prefix(8)
        guard let prompt = after.firstIndex(where: { $0.contains("one-time code") }),
              let code = lines[(prompt + 1)...].prefix(3).first(where: { !$0.isEmpty }),
              code.range(of: "^[A-Z0-9]{4}-[A-Z0-9]{4,5}$", options: .regularExpression) != nil else { return nil }
        return (url, code)
    }
}

/// One login started from Settings: the pane it runs in, the sign-in page
/// once the provider prints it, and the outcome from the provider's own
/// status report after the command exits.
struct RelayAgentLoginState: Equatable {
    enum Phase: Equatable { case running, finished(String), failed(String) }
    let account: RelayAgentAccount
    let host: String
    let paneID: UUID
    /// Whether this is a sign-in again, and the identity it replaces.
    var replacing = false
    var replacedKey: String? = nil
    var replacedIdentity: String? = nil
    var signIn: URL?
    /// The device code a Codex login prints, for the sign-in window.
    var deviceCode: String? = nil
    /// What the slot is meant for, for the checklist and the outcome.
    var expected = RelayAgentAccountExpectation()
    /// Relay opened the sign-in window (once by itself; again on request).
    var opened = false
    /// The hand-off ID of a local Claude login's helper.
    var signInID: String? = nil
    /// The user chose the system browser (Codex without device codes).
    var systemBrowser = false
    /// Claude's paste-back code was typed into the login pane.
    var codeSent = false
    /// The provider CLI the login runs, and the login a pasted code is
    /// bound to once its pane showed Claude's paste prompt.
    var executable = ""
    var binding: RelayAgentSignInBinding? = nil
    /// Why a local Claude login's page never reached Relay.
    var handoffError: String? = nil
    var phase: Phase = .running
}

@MainActor final class RelayAgentLoginMonitor: ObservableObject {
    static let shared = RelayAgentLoginMonitor()
    /// Keyed by host and "provider:label".
    @Published private(set) var logins: [String: RelayAgentLoginState] = [:]

    static func key(host: String, account: RelayAgentAccount) -> String {
        host + "\u{1f}" + account.provider + ":" + account.label
    }

    func state(host: String, account: RelayAgentAccount) -> RelayAgentLoginState? {
        logins[Self.key(host: host, account: account)]
    }

    /// One sign-in window per login, and the login's pane for the code
    /// hand-off.
    private var windows: [String: RelayAgentSignInWindow] = [:]
    private var panes: [String: PaneModel] = [:]

    /// Opens (or reopens) the login's page in the sign-in window; with the
    /// system browser chosen, in the default browser.
    func openSignIn(host: String, account: RelayAgentAccount) {
        let key = Self.key(host: host, account: account)
        guard let state = logins[key], state.phase == .running, let url = state.signIn,
              RelayAgentLoginURL.signInURL(url.absoluteString) != nil else { return }
        logins[key]?.opened = true
        if state.systemBrowser {
            NSWorkspace.shared.open(url)
            return
        }
        let window = windows[key] ?? RelayAgentSignInWindow()
        windows[key] = window
        window.open(url, workspace: state.expected.workspace.isEmpty ? nil : state.expected.workspace, code: state.deviceCode)
    }

    /// Closes every sign-in window and deletes the window's website data, so
    /// the next sign-in starts signed out at every provider. Logins still
    /// running keep running; "Show the sign-in again" opens a fresh window.
    func signOutOfSignInWindow() async -> String {
        for window in windows.values { window.close() }
        windows.removeAll()
        guard await RelayAgentSignInWindow.clearStore() else {
            return "Relay's sign-in window could not be fully signed out; some of its website data remains. Try again with no sign-in running."
        }
        return "Signed out of Relay's sign-in window: its cookies and site data were deleted. Your accounts' own CLI logins are unchanged."
    }

    /// Types the code Claude's page showed into this login's own pane, only
    /// while Claude's login is waiting for it there. The code is not kept.
    /// Returns why nothing was typed, or nil.
    func sendCode(_ text: String, host: String, account: RelayAgentAccount) async -> String? {
        let key = Self.key(host: host, account: account)
        guard account.provider == "claude", let state = logins[key], state.phase == .running, let pane = panes[key],
              pane.id == state.paneID else { return "This login is no longer running; nothing was typed." }
        guard let code = RelayAgentSignIn.claudeCode(text) else {
            return "That is not one code from Claude's sign-in page; nothing was typed."
        }
        guard let binding = state.binding else {
            return "Claude's login has not asked for a code in its pane yet; nothing was typed."
        }
        if let refusal = await RelayAgentSignInDelivery.deliver(code, binding: binding, executable: state.executable,
                                                                port: pane.runtime) {
            return refusal + "; nothing was typed."
        }
        logins[key]?.codeSent = true
        return nil
    }

    /// Opens a pane on `profile` running the provider's own login for
    /// `account`, then follows it until the command exits and reports the
    /// provider's status. With `replacing`, the provider's own logout runs
    /// first, so an account that is logged in can take another identity.
    /// Returns why no login was started, or nil.
    /// Codex uses its device-code login (it ignores BROWSER on macOS) unless
    /// `systemBrowser`; a local Claude login hands its page to Relay.
    func start(_ account: RelayAgentAccount, on profile: ConnectionProfile, in workspace: WorkspaceModel,
               replacing: Bool = false, systemBrowser: Bool = false) async -> String? {
        let directory = RelayAgentAccountDirectory.shared
        let host = RelayAgentAccountDirectory.hostKey(profile)
        let name = account.provider == "codex" ? "Codex" : "Claude"
        let hostName = profile.kind == .local ? "This Mac" : profile.name
        if state(host: host, account: account)?.phase == .running { return "A \(name) login for \(account.label) is already open." }
        if directory.executable(for: profile, provider: account.provider) == nil {
            _ = try? await directory.refresh(profile)
        }
        let executable = directory.executable(for: profile, provider: account.provider)
        if executable == "" { return "\(name) is not installed on \(hostName)." }
        let local = profile.kind == .local
        var signInID: String?
        if account.provider == "claude" && local {
            do {
                try RelayAgentSignIn.installHelper()
                signInID = try RelayAgentSignIn.issue()
            } catch { return error.localizedDescription }
        }
        let deviceCode = account.provider == "codex" ? !systemBrowser : !local
        let command = account.loginCommand(executable: executable, remote: deviceCode, replacing: replacing, signInID: signInID)
        let retire = { [signInID] in if let signInID { RelayAgentSignIn.retire(signInID) } }
        guard !command.isEmpty else {
            retire()
            return "This account's directory or \(name)'s path on \(hostName) is not valid."
        }
        do {
            if !account.isDefaultDirectory { try await directory.prepare(profile, account: account) }
        } catch {
            retire()
            return error.localizedDescription
        }
        let source = workspace.panes.values.first { $0.profile.connectionKey == profile.connectionKey }?.id ?? workspace.activePaneID
        guard let pane = await workspace.openTab(running: command, profile: profile, besidePane: source) else {
            retire()
            return "Relay could not open a login pane on \(hostName): its shell prompt was not ready. Nothing was run."
        }
        let key = Self.key(host: host, account: account)
        var state = RelayAgentLoginState(account: account, host: host, paneID: pane.id)
        state.replacing = replacing
        state.signInID = signInID
        state.systemBrowser = systemBrowser
        state.executable = executable ?? ""
        state.expected = directory.status(for: profile, account: account)?.expectation ?? .init()
        if replacing {
            let status = directory.status(for: profile, account: account), usage = directory.usage(for: profile, account: account)
            state.replacedKey = status?.identityKey ?? usage?.identityKey
            state.replacedIdentity = RelayAgentAccountSummary.identity(status: status, usage: usage)
        }
        windows[key]?.close()
        logins[key] = state
        panes[key] = pane
        Task { await follow(pane, key: key, account: account, profile: profile, workspace: workspace) }
        return nil
    }

    /// The command has exited once the shell's prompt is back and empty
    /// after it was seen busy. A command that never showed as busy within
    /// ten seconds is taken as finished when the prompt is empty.
    private func follow(_ pane: PaneModel, key: String, account: RelayAgentAccount,
                        profile: ConnectionProfile, workspace: WorkspaceModel) async {
        var busySeen = false
        var ticks = 0
        var closed = false
        while ticks < 3_600 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            ticks += 1
            guard workspace.panes[pane.id] === pane, pane.connectionState == .connected, logins[key]?.paneID == pane.id else {
                closed = true
                break
            }
            let viewport = pane.runtime.sidePanelViewportText()
            if let id = logins[key]?.signInID {
                // A helper-backed login takes only its own private hand-off,
                // never a URL from the pane; an unclaimed one ends after two
                // minutes.
                if logins[key]?.signIn == nil, logins[key]?.handoffError == nil {
                    if let url = RelayAgentSignIn.takeURL(id: id) {
                        logins[key]?.signIn = url
                    } else if ticks == 240 {
                        RelayAgentSignIn.retire(id)
                        logins[key]?.handoffError = "Claude did not hand its sign-in page to Relay within two minutes, " +
                            "so nothing was opened. Close the login pane and sign in again."
                    }
                }
            } else if account.provider == "codex", logins[key]?.systemBrowser == false {
                // The device page and its code, from one block of the pane.
                if let device = viewport.flatMap(RelayAgentLoginURL.deviceLogin) {
                    logins[key]?.signIn = device.url
                    logins[key]?.deviceCode = device.code
                }
            } else if logins[key]?.signIn == nil, let url = viewport.flatMap(RelayAgentLoginURL.find) {
                logins[key]?.signIn = url
            }
            // A pasted code is bound to the login process Relay started in
            // this pane: the provider CLI that is the foreground job of the
            // pane's own shell while Claude's paste prompt shows (pid and
            // start, with the pane's transport and shell command).
            if account.provider == "claude", logins[key]?.binding == nil, RelayAgentSignIn.awaitsCode(viewport),
               let executable = logins[key]?.executable,
               let binding = await RelayAgentSignInDelivery.bind(pane.runtime, executable: executable),
               logins[key]?.paneID == pane.id {
                logins[key]?.binding = binding
            }
            // Opened once by itself; a device login waits for its code.
            if let state = logins[key], state.signIn != nil, !state.opened, !state.systemBrowser,
               account.provider != "codex" || state.deviceCode != nil {
                openSignIn(host: state.host, account: account)
            }
            let idle = pane.kind == .shell && pane.runtime.assistantShellPromptIsEmpty()
            if !idle { busySeen = true } else if busySeen || ticks >= 20 { break }
        }
        if let id = logins[key]?.signInID { RelayAgentSignIn.retire(id) }
        guard logins[key]?.paneID == pane.id else { return }
        defer {
            // The provider's fresh check has answered: the window is done.
            windows.removeValue(forKey: key)?.close()
            panes[key] = nil
        }
        let directory = RelayAgentAccountDirectory.shared
        // Only this check counts: the cached status annotated by this probe,
        // and for Codex the identity from a usage reading taken after it.
        let checkStarted = Date()
        _ = try? await directory.refresh(profile, probe: true)
        let status = directory.status(for: profile, account: account)
        var freshUsage: RelayAgentAccountUsage?
        if account.provider == "codex", Self.freshCheck(status, since: checkStarted)?.loggedIn == "yes" {
            freshUsage = (try? await directory.refreshUsage(profile, provider: "codex"))?
                .first { $0.provider == account.provider && $0.label == account.label }
        }
        // Every other slot of the provider on this host, by workspace.
        let others = directory.accounts(for: profile, provider: account.provider).filter { $0 != account }
            .reduce(into: [String: String]()) { result, other in
                if let key = directory.workspace(for: profile, account: other)?.key { result[other.label] = key }
            }
        logins[key]?.phase = Self.outcome(status: status, checkStarted: checkStarted, freshUsage: freshUsage,
                                          provider: account.provider, replacing: logins[key]?.replacing ?? false,
                                          replacedKey: logins[key]?.replacedKey, paneClosed: closed,
                                          expected: logins[key]?.expected ?? .init(), others: others)
    }

    /// `status` when it is the answer to a provider check started at or
    /// after `since` that did not fail; nil otherwise.
    static func freshCheck(_ status: RelayAgentAccountStatus?, since: Date) -> RelayAgentAccountStatus? {
        guard let status, let checked = status.checkedAt, checked >= since, !status.checkFailed else { return nil }
        return status
    }

    /// The login's outcome from the provider's own fresh check only. A
    /// failed or stale check never counts as signed in, and a sign-in again
    /// compares only an identity read after the login (Claude: the fresh
    /// status; Codex: a usage reading taken after the check).
    /// The resulting workspace is compared with the slot's expectation and
    /// with `others` (label → workspace key of the provider's other slots
    /// on the host); either difference is a failed sign-in to redo, and an
    /// expectation the provider's report cannot confirm is unverified.
    static func outcome(status: RelayAgentAccountStatus?, checkStarted: Date, freshUsage: RelayAgentAccountUsage?,
                        provider: String, replacing: Bool, replacedKey: String?, paneClosed: Bool,
                        expected: RelayAgentAccountExpectation = .init(),
                        others: [String: String] = [:]) -> RelayAgentLoginState.Phase {
        guard let fresh = freshCheck(status, since: checkStarted) else {
            return .failed("The provider's status check did not answer, so Relay could not verify the login. Refresh status to check again.")
        }
        switch fresh.loggedIn {
        case "yes":
            let usage = provider == "codex" ? freshUsage : nil
            let identityKey = provider == "codex" ? usage?.identityKey : fresh.identityKey
            let identity = RelayAgentAccountSummary.identity(status: fresh, usage: usage)
            if replacing {
                guard let identityKey else {
                    return .failed("Logged in, but Relay could not verify which account (" + identity + "). Refresh status to check again.")
                }
                if identityKey == replacedKey {
                    return .failed("Signed in again as the same account (" + identity + "); choose the other account on the sign-in page.")
                }
            }
            let current = RelayAgentAccountIdentity.current(status: fresh, usage: usage)
            if let text = RelayAgentAccountIdentity.mismatch(expected, current: current) {
                return .failed(text + ". Sign in again and choose " +
                    (expected.workspace.isEmpty ? "the expected workspace" : expected.workspace) + " on the page.")
            }
            if let key = current?.key, let other = others.filter({ $0.value == key }).keys.sorted().first {
                return .failed("Signed in to \(current?.title ?? "a workspace"), the same workspace as \(other). Sign in again and choose another workspace.")
            }
            // A sign-in whose expected workspace or plan could not be checked
            // is never reported as verified.
            if let text = RelayAgentAccountIdentity.unverified(expected, current: current) {
                return .failed(text + ". Refresh status to check again.")
            }
            if let current, current.name != nil || current.key != nil {
                return .finished("Signed in to " + current.title + (current.email.map { " as " + $0 } ?? "") + ".")
            }
            return .finished(identity == "logged in" ? "Logged in." : "Logged in as " + identity + ".")
        case "no":
            return .failed(paneClosed ? "The login pane closed before the login completed." : "The login did not complete.")
        default:
            return .failed("The provider did not report whether the login completed.")
        }
    }
}
