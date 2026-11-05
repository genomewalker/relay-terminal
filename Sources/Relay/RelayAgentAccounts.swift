import Foundation

/// A provider account on one host: a label mapped to a Claude or Codex config
/// directory. The account is selected only by CLAUDE_CONFIG_DIR / CODEX_HOME;
/// Relay never reads, copies or moves provider credentials. `dir` is "" for
/// the provider default (~/.claude or ~/.codex with the variable unset), else
/// "~/name" or an absolute path. The default is not the same as setting the
/// variable to ~/.claude: Claude then moves its global .claude.json.
struct RelayAgentAccount: Codable, Equatable, Hashable, Sendable {
    let provider: String
    let label: String
    let dir: String

    static let providers = ["claude", "codex"]

    /// The main directories are "work"; "personal" uses its own directories.
    static let defaults: [RelayAgentAccount] = [
        .init(provider: "claude", label: "work", dir: ""),
        .init(provider: "claude", label: "personal", dir: "~/.claude-personal"),
        .init(provider: "codex", label: "work", dir: ""),
        .init(provider: "codex", label: "personal", dir: "~/.codex-personal"),
    ]

    var isDefaultDirectory: Bool { dir.isEmpty }
    var displayDirectory: String { dir.isEmpty ? "~/.\(provider)" : dir }
    var variable: String { Self.variable(provider) }

    static func variable(_ provider: String) -> String {
        provider == "codex" ? "CODEX_HOME" : "CLAUDE_CONFIG_DIR"
    }

    static func validLabel(_ label: String) -> Bool {
        label.range(of: #"^[a-z0-9][a-z0-9_-]{0,23}$"#, options: .regularExpression) != nil
    }

    /// Typed into a shell as "$HOME"/name or a bare absolute path, so only
    /// characters that need no quoting are accepted (matches relayd).
    static func validDirectory(_ dir: String) -> Bool {
        dir.isEmpty || (dir.range(of: #"^(~/|/)[A-Za-z0-9._/-]{1,240}$"#, options: .regularExpression) != nil &&
            !dir.contains("..") && !dir.contains("//") && !dir.hasSuffix("/"))
    }

    var isValid: Bool {
        Self.providers.contains(provider) && Self.validLabel(label) && Self.validDirectory(dir)
    }

    /// The shell prefix that selects this account: the variable's assignment,
    /// or for the default account `env -u` with it, so an override the pane's
    /// shell exported never selects another account. Both CLIs require an
    /// absolute directory; the shell expands "$HOME" on the pane's own host,
    /// so the Mac never guesses a remote home.
    var launchAssignment: String {
        guard isValid else { return "" }
        if dir.isEmpty { return "env -u " + variable }
        if dir.hasPrefix("~/") { return variable + "=\"$HOME\"/" + dir.dropFirst(2) }
        return variable + "=" + dir
    }

    /// Relay's managed launcher for `provider`, which relayd installs
    /// (RelaydManagement's install script, scripts/install-relayd.sh), as
    /// file_stat names it.
    static func managedShimPath(_ provider: String) -> String {
        "~/.local/share/relay/shims/" + provider
    }

    /// The same launcher as typed into the pane's shell: its own home, the
    /// exact file, never a name looked up in PATH.
    static func managedShimCommand(_ provider: String) -> String {
        "\"$HOME\"/.local/share/relay/shims/" + provider
    }

    /// `command`, which starts with the provider's name, run in this account
    /// through the exact managed launcher. Environment activators can reorder
    /// PATH after shell startup, and `env` bypasses Relay's codex shell
    /// function, so the program is never resolved through PATH. Empty when
    /// the account or the command does not qualify.
    func launchCommand(_ command: String) -> String {
        let assignment = launchAssignment
        guard !assignment.isEmpty, command == provider || command.hasPrefix(provider + " ") else { return "" }
        return assignment + " " + Self.managedShimCommand(provider) + command.dropFirst(provider.count)
    }

    /// The provider's own login flow in this account's directory, with only
    /// the account's variable set (or, for the default, unset). A login is
    /// not an agent launch: it runs the CLI that relayd resolved on the host
    /// (`executable`, absolute), never Relay's managed launcher, which would
    /// add hook settings and a launch record. `env` never runs a shell alias
    /// or function. A host whose relayd predates that report gives nil and
    /// the provider's name is used. On a remote host Codex uses its device
    /// code flow: its browser callback would reach only that host. Claude's
    /// own flow asks for the code in the pane when its callback cannot.
    /// With `replacing`, the provider's own logout runs first, so the login
    /// replaces the identity the account holds; the login runs only after a
    /// successful logout.
    /// With `signInID` (Claude on This Mac), Relay's sign-in helper is the
    /// login's BROWSER: it hands the page to Relay instead of opening one.
    /// Empty when the account or the executable does not qualify.
    func loginCommand(executable: String?, remote: Bool, replacing: Bool = false, signInID: String? = nil) -> String {
        let assignment = launchAssignment
        guard !assignment.isEmpty else { return "" }
        let program: String
        if let executable {
            guard Self.validExecutable(executable) else { return "" }
            program = "'" + executable + "'"
        } else {
            program = provider
        }
        let arguments = provider == "codex" ? (remote ? " login --device-auth" : " login") : " auth login"
        var environment = assignment.hasPrefix("env ") ? assignment : "env " + assignment
        if let signInID {
            guard provider == "claude", !remote, RelayAgentSignIn.validID(signInID) else { return "" }
            environment += " BROWSER=" + RelayAgentSignIn.helperCommand + " RELAY_SIGNIN_ID=" + signInID
        }
        let prefix = environment + " " + program
        let login = prefix + arguments
        guard replacing else { return login }
        return prefix + (provider == "codex" ? " logout" : " auth logout") + " && " + login
    }

    /// An absolute path relayd reported, typed only inside single quotes.
    static func validExecutable(_ path: String) -> Bool {
        path.hasPrefix("/") && path.count <= 1024 && !path.contains("'") &&
            !path.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f }
    }

    /// The directory as relayd's maintenance reader reports a running agent's
    /// account: "" for the default, "~/name" below the host home, else absolute.
    /// CODEX_HOME naming ~/.codex is Codex's default account; Claude's explicit
    /// ~/.claude is not (see `explicitClaudeDefault`). relayd compares resolved
    /// real paths when it can.
    func matches(observedDirectory observed: String) -> Bool {
        guard provider == "codex" else { return dir == observed }
        let main = "~/.codex"
        return (dir == main ? "" : dir) == (observed == main ? "" : observed)
    }

    /// Claude's default (CLAUDE_CONFIG_DIR unset) against CLAUDE_CONFIG_DIR
    /// naming ~/.claude: the same directory, but Claude then reads
    /// ~/.claude/.claude.json instead of ~/.claude.json.
    func explicitClaudeDefault(observedDirectory observed: String) -> Bool {
        provider == "claude" && Set([dir, observed]) == Set(["", "~/.claude"])
    }
}

/// What a pane's provider account is known to be. `recorded` is chosen when
/// Relay launched the agent and is part of the pane's agent identity;
/// `observed` is what the running process actually uses. Relay reports a
/// difference; it never switches the pane to either account to resolve it.
struct RelayPaneAgentAccountState: Codable, Equatable, Sendable {
    var recorded: RelayAgentAccount?
    var observedProvider: String?
    var observedDirectory: String?
    var observedLabel: String?
    /// relayd's resolved real-path comparison with the recorded account, when
    /// the host reports one; it decides over the textual comparison.
    var observedMatches: Bool?

    var label: String? { recorded?.label ?? observedLabel }

    /// A pane restored from its store: a saved inferred label may be a guess
    /// made before the host registry was read, so it is dropped until that
    /// registry is cached and the pane is relabelled from it.
    func restored(registryCached: Bool) -> Self {
        var state = self
        if !registryCached { state.observedLabel = nil }
        return state
    }

    /// The account as shown in the GUI and relay_list_panes' "accountDisplay": the
    /// recorded label, else the inferred label with the observed directory
    /// ("personal · default (~/.claude)", "default (~/.claude)",
    /// "~/.claude-team"). Display only; no decision reads it.
    var displayLabel: String? {
        if let recorded { return recorded.label }
        guard let directory = observedDirectory else { return observedLabel }
        let place = directory.isEmpty ? "default (~/.\(observedProvider ?? "claude"))" : directory
        return observedLabel.map { "\($0) · \(place)" } ?? place
    }

    var mismatch: Bool {
        guard let recorded, let observedDirectory, observedProvider == recorded.provider else { return false }
        if let observedMatches { return !observedMatches }
        return !recorded.matches(observedDirectory: observedDirectory)
    }

    var mismatchDescription: String? {
        guard mismatch, let recorded else { return nil }
        let observed = observedDirectory.map { $0.isEmpty ? "~/.\(recorded.provider) (default)" : $0 } ?? "unknown"
        let reason = observedDirectory.map { recorded.explicitClaudeDefault(observedDirectory: $0) } == true
            ? " (explicit ~/.claude uses a different .claude.json)" : ""
        return "This pane's \(recorded.provider == "codex" ? "Codex" : "Claude") account is \(recorded.label) " +
            "(\(recorded.displayDirectory)) but the running agent uses \(observed)\(reason). Relay will not restart or switch it."
    }
}

/// Per-pane account identity, persisted by pane ID like AgentStateStore so
/// restored, reconnected and recovered panes keep it.
final class RelayPaneAccountStore: @unchecked Sendable {
    static let shared = RelayPaneAccountStore()
    private let directory: URL
    private let enabled: Bool
    private let lock = NSLock()

    init(directory: URL? = nil) {
        let testing = ProcessInfo.processInfo.environment["RELAY_TESTING"] == "1" ||
            ProcessInfo.processInfo.processName.contains("RelayPackageTests") ||
            ProcessInfo.processInfo.processName.hasPrefix("swiftpm-testing")
        enabled = directory != nil || !testing
        self.directory = directory ?? RelayStateProfile.applicationSupportRoot
            .appendingPathComponent("Relay/AgentAccounts/Panes", isDirectory: true)
        if enabled { SecureFiles.createPrivateDirectory(at: self.directory) }
    }

    func load(paneID: UUID) -> RelayPaneAgentAccountState? {
        guard enabled else { return nil }
        let url = url(paneID)
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0, size <= 16 << 10,
              let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(RelayPaneAgentAccountState.self, from: data),
              state.recorded?.isValid ?? true else { return nil }
        return state
    }

    func save(_ state: RelayPaneAgentAccountState?, paneID: UUID) {
        guard enabled else { return }
        lock.lock(); defer { lock.unlock() }
        let url = url(paneID)
        guard let state, state.recorded != nil || state.observedDirectory != nil else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: url, options: .atomic)
        SecureFiles.restrictToOwner(url)
    }

    private func url(_ paneID: UUID) -> URL {
        directory.appendingPathComponent(paneID.uuidString.lowercased() + ".json")
    }
}

/// Where a new agent's default account came from, in precedence order.
enum RelayAgentAccountChoiceSource: String, Sendable {
    case explicit, workspace, host, global
    /// No rule applies: the account on the provider's default directory.
    case standard
}

struct RelayAgentAccountChoice: Equatable, Sendable {
    let account: RelayAgentAccount
    let source: RelayAgentAccountChoiceSource
}

/// Account routing rules: data mapping a workspace, a host or everything to an
/// account label per provider. A rule naming a label the host does not have
/// is skipped, never guessed at.
struct RelayAgentAccountRules: Codable, Equatable, Sendable {
    var version = 1
    /// provider → label
    var global: [String: String] = [:]
    /// host key (`RelayAgentAccountDirectory.hostKey`) → provider → label
    var hosts: [String: [String: String]] = [:]
    /// workspace ID (lowercased) → provider → label
    var workspaces: [String: [String: String]] = [:]

    static func workspaceKey(_ id: UUID) -> String { id.uuidString.lowercased() }

    /// The settings API's form: only an object with "version" decodes as
    /// rules; missing maps are empty.
    struct Wire: Decodable {
        let rules: RelayAgentAccountRules
        enum CodingKeys: String, CodingKey { case version, global, hosts, workspaces }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            var rules = RelayAgentAccountRules()
            rules.version = try c.decode(Int.self, forKey: .version)
            rules.global = try c.decodeIfPresent([String: String].self, forKey: .global) ?? [:]
            rules.hosts = try c.decodeIfPresent([String: [String: String]].self, forKey: .hosts) ?? [:]
            // Workspace IDs are kept lowercased, as Relay stores them.
            let workspaces = try c.decodeIfPresent([String: [String: String]].self, forKey: .workspaces) ?? [:]
            rules.workspaces = Dictionary(workspaces.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
            self.rules = rules
        }
    }

    /// Precedence: an explicit pick, then the workspace rule, then the host
    /// rule, then the global rule, then the default-directory account. Usage
    /// readings never take part: a suggestion is shown, never applied.
    func choose(provider: String, host: String, workspace: UUID?, explicit: String? = nil,
                accounts: [RelayAgentAccount]) -> RelayAgentAccountChoice? {
        let candidates = accounts.filter { $0.provider == provider && $0.isValid }
        func pick(_ label: String?, _ source: RelayAgentAccountChoiceSource) -> RelayAgentAccountChoice? {
            label.flatMap { label in candidates.first { $0.label == label } }.map { .init(account: $0, source: source) }
        }
        if let explicit { return pick(explicit, .explicit) }
        return pick(workspace.flatMap { workspaces[Self.workspaceKey($0)]?[provider] }, .workspace)
            ?? pick(hosts[host]?[provider], .host)
            ?? pick(global[provider], .global)
            ?? (candidates.first(where: \.isDefaultDirectory) ?? candidates.first).map { .init(account: $0, source: .standard) }
    }

    var isValid: Bool {
        let rows = [global] + Array(hosts.values) + Array(workspaces.values)
        return rows.allSatisfy { $0.allSatisfy { RelayAgentAccount.providers.contains($0.key) && RelayAgentAccount.validLabel($0.value) } } &&
            hosts.count <= 256 && workspaces.count <= 1024 && workspaces.keys.allSatisfy { UUID(uuidString: $0) != nil }
    }
}

/// Persists the routing rules beside Relay's per-pane account identities.
final class RelayAgentAccountRouting: @unchecked Sendable {
    static let shared = RelayAgentAccountRouting()
    private let url: URL?
    private let lock = NSLock()
    private var current: RelayAgentAccountRules

    init(url: URL? = nil) {
        let testing = ProcessInfo.processInfo.environment["RELAY_TESTING"] == "1" ||
            ProcessInfo.processInfo.processName.contains("RelayPackageTests") ||
            ProcessInfo.processInfo.processName.hasPrefix("swiftpm-testing")
        self.url = url ?? (testing ? nil : RelayStateProfile.applicationSupportRoot
            .appendingPathComponent("Relay/AgentAccounts/routing.json"))
        if let path = self.url, let data = try? Data(contentsOf: path), data.count <= 256 << 10,
           let decoded = try? JSONDecoder().decode(RelayAgentAccountRules.self, from: data), decoded.isValid {
            current = decoded
        } else {
            current = .init()
        }
    }

    var rules: RelayAgentAccountRules {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    @discardableResult
    func update(_ change: (inout RelayAgentAccountRules) -> Void) -> Bool {
        lock.lock()
        var next = current
        change(&next)
        guard next.isValid else { lock.unlock(); return false }
        current = next
        lock.unlock()
        guard let url, let data = try? JSONEncoder().encode(next) else { return true }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        SecureFiles.restrictToOwner(url)
        return true
    }

    func setWorkspace(_ workspace: UUID, provider: String, label: String?) {
        update { rules in
            var row = rules.workspaces[RelayAgentAccountRules.workspaceKey(workspace)] ?? [:]
            row[provider] = label
            rules.workspaces[RelayAgentAccountRules.workspaceKey(workspace)] = row.isEmpty ? nil : row
        }
    }

    func setHost(_ host: String, provider: String, label: String?) {
        update { rules in
            var row = rules.hosts[host] ?? [:]
            row[provider] = label
            rules.hosts[host] = row.isEmpty ? nil : row
        }
    }

    func setGlobal(provider: String, label: String?) {
        update { $0.global[provider] = label }
    }
}

/// One account's plan usage as the provider CLI itself reports it (Claude
/// Code's get_usage control request, Codex app-server rate limits). Nothing
/// is estimated: without a reading the status is "unknown".
struct RelayAgentAccountUsage: Decodable, Equatable, Sendable {
    let provider: String
    let label: String
    let status: String
    let reason: String?
    let source: String?
    let readAt: String
    let windows: [Window]?
    /// Who the provider says the account is (Codex reports it with usage).
    var email: String? = nil
    var plan: String? = nil
    var identityKey: String? = nil
    /// Equal for two accounts exactly when the provider reports the same
    /// workspace (Codex: its ChatGPT workspace account), whatever the email.
    var workspaceKey: String? = nil
    /// The host this reading was received from, set on receipt. A reading
    /// is shown only for that host.
    var host: String? = nil

    struct Window: Decodable, Equatable, Sendable {
        let name: String
        let usedPercent: Double
        let resetsAt: String?
        let windowMinutes: Int?

        enum CodingKeys: String, CodingKey {
            case name
            case usedPercent = "used_percent", resetsAt = "resets_at", windowMinutes = "window_minutes"
        }

        /// A plain label from the window's length; the provider's own
        /// window name ("primary", "seven_day") is never shown.
        var displayName: String {
            switch windowMinutes {
            case 300?: "5-hour"
            case 1440?: "daily"
            case 10080?: "weekly"
            case let minutes? where minutes > 0 && minutes % 10080 == 0: "\(minutes / 10080)-week"
            case let minutes? where minutes > 0 && minutes % 1440 == 0: "\(minutes / 1440)-day"
            case let minutes? where minutes > 0 && minutes % 60 == 0: "\(minutes / 60)-hour"
            case let minutes? where minutes > 0: "\(minutes)-minute"
            default: "usage window"
            }
        }
    }

    enum CodingKeys: String, CodingKey {
        case provider, label, status, reason, source, windows, email, plan
        case readAt = "read_at", identityKey = "identity_key", workspaceKey = "workspace_key"
    }

    var id: String { provider + ":" + label }

    /// The same reading under a slot's new label.
    func relabeled(_ newLabel: String) -> RelayAgentAccountUsage {
        var copy = RelayAgentAccountUsage(provider: provider, label: newLabel, status: status, reason: reason, source: source,
                                          readAt: readAt, windows: windows)
        copy.email = email; copy.plan = plan; copy.identityKey = identityKey
        copy.workspaceKey = workspaceKey; copy.host = host
        return copy
    }

    /// relayd's reason for an account whose directory does not exist.
    var notSetUp: Bool { status != "ok" && reason == "account directory does not exist" }

    /// Windows shortest first (5-hour before weekly).
    var orderedWindows: [Window] {
        (windows ?? []).sorted { ($0.windowMinutes ?? .max) < ($1.windowMinutes ?? .max) }
    }
    var readDate: Date? { ISO8601DateFormatter().date(from: readAt) }

    /// Remaining room in the tightest window, or nil without a reading.
    var headroom: Double? {
        guard status == "ok", let windows, !windows.isEmpty,
              windows.allSatisfy({ (0...100).contains($0.usedPercent) }) else { return nil }
        return 100 - (windows.map(\.usedPercent).max() ?? 100)
    }

    func summary(now: Date = Date()) -> String {
        if notSetUp { return "not set up" }
        guard headroom != nil else { return "usage unknown" }
        let windows = orderedWindows
        let time = DateFormatter(); time.dateStyle = .none; time.timeStyle = .short
        let parts = windows.map { window in
            "\(window.displayName) \(Int(window.usedPercent.rounded()))%" + (window.resetsAt
                .flatMap { ISO8601DateFormatter().date(from: $0) }.map { " (resets " + time.string(from: $0) + ")" } ?? "")
        }
        return parts.joined(separator: " · ") + " · read " + Self.age(readDate, now: now)
    }

    static func age(_ date: Date?, now: Date) -> String {
        guard let date else { return "at an unknown time" }
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(seconds / 60) min ago" }
        if seconds < 86400 { return "\(seconds / 3600) h ago" }
        return "\(seconds / 86400) d ago"
    }

    /// The account with clearly more headroom, shown as "suggested" only when
    /// every account of the provider has a recent reading. It is never
    /// applied: the rule-chosen default stays selected.
    static func suggestion(accounts: [RelayAgentAccount], usage: [String: RelayAgentAccountUsage],
                           now: Date = Date(), maximumAge: TimeInterval = 3600) -> String? {
        guard accounts.count >= 2 else { return nil }
        var rooms: [(label: String, headroom: Double)] = []
        for account in accounts {
            guard let reading = usage[account.provider + ":" + account.label], let room = reading.headroom,
                  let read = reading.readDate, now.timeIntervalSince(read) <= maximumAge else { return nil }
            rooms.append((account.label, room))
        }
        let sorted = rooms.sorted { $0.headroom > $1.headroom }
        guard sorted[0].headroom > sorted[1].headroom else { return nil }
        return sorted[0].label
    }
}

/// One line per account for Settings and the pane menus:
/// identity · 5-hour % · weekly % · resets, from the provider CLIs' own
/// reports. A window the provider did not report is left out.
enum RelayAgentAccountSummary {
    static func line(status: RelayAgentAccountStatus?, usage: RelayAgentAccountUsage?, now: Date = Date()) -> String {
        if status?.exists == false || usage?.notSetUp == true { return "not set up" }
        var parts = [identity(status: status, usage: usage)]
        guard let usage, usage.headroom != nil else { return (parts + ["usage unknown"]).joined(separator: " · ") }
        let windows = usage.orderedWindows
        parts += windows.map { "\($0.displayName) \(Int($0.usedPercent.rounded()))%" }
        let resets = windows.compactMap { window in
            window.resetsAt.flatMap { ISO8601DateFormatter().date(from: $0) }.map { reset(window, at: $0, now: now) }
        }
        if !resets.isEmpty { parts.append("resets " + resets.joined(separator: ", ")) }
        if status?.checkFailed == true {
            parts.append("last reading " + RelayAgentAccountUsage.age(usage.readDate, now: now))
        }
        return parts.joined(separator: " · ")
    }

    /// "workspace · plan (email)" when the provider reports the workspace,
    /// else "email (plan)", else the login state.
    static func identity(status: RelayAgentAccountStatus?, usage: RelayAgentAccountUsage?) -> String {
        // A failed fresh check is shown as such; an earlier reading's
        // identity is only "last known", never the current login.
        if status?.checkFailed == true {
            let known = usage?.email.map { $0 + (usage?.plan.map { " (\($0 == "api_key" ? "API key" : $0))" } ?? "") }
            return "login check failed" + (known.map { " (last known " + $0 + ")" } ?? "")
        }
        if let current = RelayAgentAccountIdentity.current(status: status, usage: usage), current.name != nil || current.key != nil {
            return current.title + (current.email.map { " (" + $0 + ")" } ?? "")
        }
        let email = status?.email ?? usage?.email
        let plan = (status?.plan ?? usage?.plan).map { $0 == "api_key" ? "API key" : $0 }
        if let email { return email + (plan.map { " (\($0))" } ?? "") }
        if let plan { return plan }
        switch status?.loggedIn {
        case "yes": return "logged in"
        case "no": return "not logged in"
        default: return status?.checkFailed == true ? "login check failed" : "login unknown"
        }
    }

    private static func reset(_ window: RelayAgentAccountUsage.Window, at date: Date, now: Date) -> String {
        let format = DateFormatter()
        format.dateFormat = date.timeIntervalSince(now) < 86_400 ? "HH:mm" : "EEE HH:mm"
        return (window.windowMinutes == 300 ? "" : window.displayName + " ") + format.string(from: date)
    }

    /// "personal is logged in as the same account as work" for each account
    /// the provider reports as the same user and organization as an earlier
    /// one of the same provider on the same host.
    static func sameIdentityWarnings(accounts: [RelayAgentAccount], key: (RelayAgentAccount) -> String?) -> [String] {
        var first: [String: String] = [:]
        var warnings: [String] = []
        for account in accounts {
            guard let identity = key(account), !identity.isEmpty else { continue }
            if let earlier = first[identity] {
                warnings.append("\(account.label) is logged in as the same \(account.provider == "codex" ? "Codex" : "Claude") account as \(earlier)")
            } else {
                first[identity] = account.label
            }
        }
        return warnings
    }
}

/// The managed claude/codex launcher on a host as relayd reports it.
struct RelayAgentLauncherStatus: Decodable, Equatable, Sendable {
    let provider: String
    let path: String
    let state: String
    let detail: String?
    let mode: String?

    /// Usable for a launch as it is.
    var usable: Bool { ["current", "installed", "repaired", "custom"].contains(state) }

    var summary: String {
        let name = provider == "codex" ? "Codex" : "Claude"
        let text: String = switch state {
        case "current", "installed", "repaired": "\(name) launcher \(state == "current" ? "installed" : state)"
        case "custom": "\(name) launcher installed with your cc-status settings"
        case "missing": "\(name) launcher missing"
        case "stale": "\(name) launcher out of date"
        case "foreign": "\(name) launcher is not Relay's; left unchanged"
        default: "\(name) launcher unavailable"
        }
        return text + (state == "custom" ? "" : detail.map { " (\($0))" } ?? "")
    }
}

/// MCP servers the sync would copy, with the names (never values) of their
/// environment and header keys.
struct RelayAgentAccountMCPPreview: Codable, Equatable, Sendable {
    let provider: String
    let label: String
    let servers: [Server]
    /// relayd's digest of the servers and key names shown; a sync given it
    /// refuses if the host's main configuration changed since the review.
    var fingerprint: String? = nil

    struct Server: Codable, Equatable, Sendable, Identifiable {
        let name: String
        let envKeys: [String]?
        let headerKeys: [String]?
        let excluded: Bool
        var id: String { name }

        enum CodingKeys: String, CodingKey {
            case name, excluded
            case envKeys = "env_keys", headerKeys = "header_keys"
        }
    }
}

/// The MCP previews the user reviewed, each scoped to the host and the exact
/// account (provider, label and directory) it describes. A host change or a
/// new account mapping drops them, and an answer requested before that is
/// never stored.
struct RelayAgentAccountPreviewCache: Equatable {
    private(set) var generation = 0
    private var entries: [String: RelayAgentAccountMCPPreview] = [:]

    private static func key(host: String, account: RelayAgentAccount) -> String {
        [host, account.provider, account.label, account.dir].joined(separator: "\u{0}")
    }

    func preview(host: String, account: RelayAgentAccount) -> RelayAgentAccountMCPPreview? {
        entries[Self.key(host: host, account: account)]
    }

    /// Stores an answer requested at `generation` for this host and account.
    @discardableResult
    mutating func store(_ preview: RelayAgentAccountMCPPreview, host: String, account: RelayAgentAccount, generation: Int) -> Bool {
        guard generation == self.generation, preview.provider == account.provider, preview.label == account.label else { return false }
        entries[Self.key(host: host, account: account)] = preview
        return true
    }

    /// Drops one account's preview: a sync used it, so the next sync needs a
    /// fresh review.
    mutating func remove(host: String, account: RelayAgentAccount) {
        entries[Self.key(host: host, account: account)] = nil
    }

    /// Drops every preview: another host is shown.
    mutating func reset() {
        entries = [:]
        generation += 1
    }

    /// Keeps only previews of `accounts` on `host`, the mapping now shown.
    mutating func retain(_ accounts: [RelayAgentAccount], host: String) {
        let keep = Set(accounts.map { Self.key(host: host, account: $0) })
        let kept = entries.filter { keep.contains($0.key) }
        if kept.count != entries.count {
            entries = kept
            generation += 1
        }
    }
}

/// Per-account sync settings kept in the host's account list.
struct RelayAgentAccountSyncSettings: Equatable, Sendable {
    var shareHistory = false
    var mcpExclude: [String] = []
}

/// Host-side account status as relayd reports it. Logged-in state comes from
/// the existence of the provider's credential file or the provider's own
/// non-secret status command; nothing secret is ever transferred.
struct RelayAgentAccountStatus: Decodable, Equatable, Sendable, Identifiable {
    let provider: String
    let label: String
    let dir: String
    let root: String
    let isDefault: Bool
    let exists: Bool
    var loggedIn: String
    var method: String?
    var email: String?
    var plan: String? = nil
    var identityKey: String? = nil
    /// relayd's "ok" or "failed" for a probe that was asked for; nil when
    /// none was (or relayd predates the field).
    var probe: String? = nil
    /// Why the check failed: the provider's first error line or how long it
    /// was given.
    var probeReason: String? = nil
    /// The organization Claude reports, and a key equal for two accounts
    /// exactly when they are in the same organization (Codex reports its
    /// workspace key with usage).
    var workspace: String? = nil
    var workspaceKey: String? = nil
    /// The workspace and plan the user means this slot for, and a pinned
    /// workspace key.
    var expectWorkspace: String? = nil
    var expectPlan: String? = nil
    var expectKey: String? = nil
    /// The model and effort new agents of this account start with.
    var model: String? = nil
    var effort: String? = nil
    var defaultsError: String? = nil
    /// When Relay asked the provider for this row (probe requested), and
    /// whether that check failed. Nil for an unprobed answer.
    var checkedAt: Date? = nil
    var checkFailed = false
    let links: [Link]?
    let shareHistory: Bool?
    let mcpExclude: [String]?

    var settings: RelayAgentAccountSyncSettings {
        .init(shareHistory: shareHistory ?? false, mcpExclude: mcpExclude ?? [])
    }

    struct Link: Decodable, Equatable, Sendable {
        let name: String
        let state: String
        let backup: String?
    }

    var id: String { provider + ":" + label }
    var account: RelayAgentAccount { .init(provider: provider, label: label, dir: isDefault ? "" : dir) }

    enum CodingKeys: String, CodingKey {
        case provider, label, dir, root, exists, method, email, links, plan, probe, workspace, model, effort
        case isDefault = "default", loggedIn = "logged_in", shareHistory = "share_history", mcpExclude = "mcp_exclude"
        case identityKey = "identity_key", probeReason = "probe_reason", workspaceKey = "workspace_key"
        case expectWorkspace = "expect_workspace", expectPlan = "expect_plan", expectKey = "expect_key"
        case defaultsError = "defaults_error"
    }

    var expectation: RelayAgentAccountExpectation {
        .init(workspace: expectWorkspace ?? "", plan: expectPlan ?? "", key: expectKey ?? "")
    }

    /// This row as the answer to a requested probe, at `now`. A probe that
    /// did not answer is a failed check: it keeps nothing from earlier.
    func probed(at now: Date) -> RelayAgentAccountStatus {
        var checked = self
        checked.checkedAt = now
        checked.checkFailed = exists && (probe == "failed" || (probe == nil && loggedIn == "unknown"))
        if checked.checkFailed {
            checked.email = nil
            checked.plan = nil
            checked.identityKey = nil
            checked.workspace = nil
            checked.workspaceKey = nil
        }
        return checked
    }

    /// Only list requests with `probe` run the providers' status commands;
    /// every other answer reports "unknown" where only a probe can tell
    /// (Claude's keychain login), or only "file" for a credential file that
    /// exists. An unprobed answer never overwrites the last probe's result
    /// (a failed check included) for the same, still existing directory.
    func keepingProbe(from earlier: RelayAgentAccountStatus?) -> RelayAgentAccountStatus {
        guard checkedAt == nil, exists, let earlier, earlier.checkedAt != nil, earlier.exists,
              earlier.provider == provider, earlier.label == label, earlier.root == root else { return self }
        var kept = self
        kept.loggedIn = earlier.loggedIn
        kept.method = earlier.method
        kept.email = earlier.email
        kept.plan = earlier.plan
        kept.identityKey = earlier.identityKey
        kept.workspace = earlier.workspace
        kept.workspaceKey = earlier.workspaceKey
        kept.probeReason = earlier.probeReason
        kept.probe = earlier.probe
        kept.checkedAt = earlier.checkedAt
        kept.checkFailed = earlier.checkFailed
        return kept
    }
}

struct RelayAgentAccountSyncResult: Decodable, Equatable, Sendable {
    let provider: String
    let label: String
    let links: [RelayAgentAccountStatus.Link]
    let mcp: String
    let mcpBackup: String?
    let mcpServers: Int
    let notes: [String]?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case provider, label, links, mcp, notes, error
        case mcpBackup = "mcp_backup", mcpServers = "mcp_servers"
    }

    var summary: String {
        let linked = links.filter { $0.state == "linked" || $0.state == "linked_after_backup" }.map(\.name)
        let held = links.filter { $0.state == "foreign_link" || $0.state == "unsupported_type" }.map(\.name)
        var parts = ["Linked: " + (linked.isEmpty ? "none" : linked.joined(separator: ", "))]
        if !held.isEmpty { parts.append("Left unchanged: " + held.joined(separator: ", ")) }
        // relayd's MergeSkipped: the account's file system has no atomic
        // exchange (NFS), so the file is never replaced; the notes say what to do.
        parts.append(mcp == "skipped_no_atomic_exchange"
            ? "MCP servers: not synced. This host's file system cannot replace the account's file safely while an agent may save it."
            : "MCP servers: \(mcp) (\(mcpServers))")
        if let mcpBackup { parts.append("Backup: " + mcpBackup) }
        parts += notes ?? []
        if let error { parts.append("Stopped: " + error) }
        return parts.joined(separator: "\n")
    }
}

/// Talks to relayd's `agent_accounts` host operation on This Mac or a remote
/// host over Relay's own node transport (never ssh), and caches each host's
/// label/directory mapping for launches.
@MainActor final class RelayAgentAccountDirectory: ObservableObject {
    static let shared = RelayAgentAccountDirectory()
    @Published private(set) var statuses: [String: [RelayAgentAccountStatus]] = [:]
    /// Cached usage readings per host, keyed "provider:label", with their read time.
    @Published private(set) var usage: [String: [String: RelayAgentAccountUsage]] = [:]
    /// The provider CLIs relayd resolves per host ("" = not installed). A
    /// host is absent until its relayd reports them.
    @Published private(set) var executables: [String: [String: String]] = [:]
    /// The managed launchers per host; absent until read.
    @Published private(set) var launchers: [String: [RelayAgentLauncherStatus]] = [:]
    /// Hosts whose relayd predates launcher reports.
    @Published private(set) var launchersUnsupported: Set<String> = []
    /// The workspace window, for per-workspace rules in menus without one.
    weak var workspace: WorkspaceModel?

    enum Failure: LocalizedError {
        case refused(String)
        case invalidResponse
        var errorDescription: String? {
            switch self {
            case .refused(let message): message
            case .invalidResponse: "The host's Relay helper returned an invalid account response. Update Relay on that host."
            }
        }
    }

    static func hostKey(_ profile: ConnectionProfile) -> String {
        profile.kind == .local ? "local" : (profile.host.isEmpty ? profile.name : profile.host)
    }

    /// The host's mapping when it was read, else the built-in defaults.
    func accounts(for profile: ConnectionProfile) -> [RelayAgentAccount] {
        let known = statuses[Self.hostKey(profile)]?.map(\.account) ?? []
        return known.isEmpty ? RelayAgentAccount.defaults : known
    }

    func accounts(for profile: ConnectionProfile, provider: String) -> [RelayAgentAccount] {
        accounts(for: profile).filter { $0.provider == provider }
    }

    /// The host's own registry for `provider`, or nil until it has been read.
    /// Never the built-in defaults: decisions that move an agent use this.
    func registeredAccounts(for profile: ConnectionProfile, provider: String) -> [RelayAgentAccount]? {
        statuses[Self.hostKey(profile)].map { $0.map(\.account).filter { $0.provider == provider } }
    }

    func account(for profile: ConnectionProfile, provider: String, label: String) -> RelayAgentAccount? {
        accounts(for: profile, provider: provider).first { $0.label == label }
    }

    /// The account a launch uses when none was picked: the workspace default
    /// for this provider and host, else the account on the default directory.
    func defaultAccount(for profile: ConnectionProfile, provider: String, workspace: UUID?) -> RelayAgentAccount? {
        choice(for: profile, provider: provider, workspace: workspace)?.account
    }

    /// The routing rules' account for a new agent and the rule that chose it.
    func choice(for profile: ConnectionProfile, provider: String, workspace: UUID?,
                explicit: String? = nil) -> RelayAgentAccountChoice? {
        RelayAgentAccountRouting.shared.rules.choose(provider: provider, host: Self.hostKey(profile),
            workspace: workspace, explicit: explicit, accounts: accounts(for: profile))
    }

    func usage(for profile: ConnectionProfile, account: RelayAgentAccount) -> RelayAgentAccountUsage? {
        hostReadings(Self.hostKey(profile))[account.provider + ":" + account.label]
    }

    /// The readings received from `key`; one tagged with another host is
    /// never shown for this one.
    private func hostReadings(_ key: String) -> [String: RelayAgentAccountUsage] {
        (usage[key] ?? [:]).filter { $0.value.host == key }
    }

    /// Stores readings received from the host `key`, tagging each with it.
    @discardableResult
    func store(_ readings: [RelayAgentAccountUsage], fromHost key: String) -> [RelayAgentAccountUsage] {
        var cached = usage[key] ?? [:]
        var tagged: [RelayAgentAccountUsage] = []
        for var reading in readings {
            reading.host = key
            cached[reading.id] = reading
            tagged.append(reading)
        }
        usage[key] = cached
        return tagged
    }

    func status(for profile: ConnectionProfile, account: RelayAgentAccount) -> RelayAgentAccountStatus? {
        statuses[Self.hostKey(profile)]?.first { $0.provider == account.provider && $0.label == account.label }
    }

    /// identity · 5-hour % · weekly % · resets for one account on `profile`.
    func summary(for profile: ConnectionProfile, account: RelayAgentAccount) -> String {
        RelayAgentAccountSummary.line(status: status(for: profile, account: account), usage: usage(for: profile, account: account))
    }

    /// Accounts of `provider` on `profile` that the provider reports as the
    /// same user: Claude's status command or Codex's account/read.
    func sameIdentityWarnings(for profile: ConnectionProfile, provider: String) -> [String] {
        RelayAgentAccountSummary.sameIdentityWarnings(accounts: accounts(for: profile, provider: provider)) { account in
            // After a failed check nothing about this account's identity is current.
            guard self.status(for: profile, account: account)?.checkFailed != true else { return nil }
            return self.status(for: profile, account: account)?.identityKey ?? self.usage(for: profile, account: account)?.identityKey
        }
    }

    /// The workspace an account is signed in to now, or nil.
    func workspace(for profile: ConnectionProfile, account: RelayAgentAccount) -> RelayAgentAccountWorkspace? {
        RelayAgentAccountIdentity.current(status: status(for: profile, account: account), usage: usage(for: profile, account: account))
    }

    /// Per label of `provider` on `profile`: a mismatch with the slot's
    /// expected workspace or plan, and a duplicate workspace.
    func findings(for profile: ConnectionProfile, provider: String) -> [String: [RelayAgentAccountIdentity.Finding]] {
        RelayAgentAccountIdentity.findings(accounts(for: profile, provider: provider).map { account in
            (account.label, status(for: profile, account: account)?.expectation ?? .init(), workspace(for: profile, account: account))
        })
    }

    /// The provider CLI relayd resolved on the host: nil while unknown (or
    /// relayd predates the report), "" when it is not installed.
    func executable(for profile: ConnectionProfile, provider: String) -> String? {
        executables[Self.hostKey(profile)]?[provider]
    }

    /// The account with more headroom, for display only.
    func suggestion(for profile: ConnectionProfile, provider: String) -> String? {
        RelayAgentAccountUsage.suggestion(accounts: accounts(for: profile, provider: provider),
            usage: hostReadings(Self.hostKey(profile)))
    }

    func settings(for profile: ConnectionProfile, account: RelayAgentAccount) -> RelayAgentAccountSyncSettings {
        statuses[Self.hostKey(profile)]?.first { $0.provider == account.provider && $0.label == account.label }?.settings ?? .init()
    }

    /// The label of the account a running agent's directory belongs to, from
    /// the host's own registry only. Display only: until that host's registry
    /// is read there is no label, never one guessed from the built-in
    /// defaults (which name a different account than the host may).
    func label(for profile: ConnectionProfile, provider: String, observedDirectory: String) -> String? {
        Self.observedLabel(registry: statuses[Self.hostKey(profile)]?.map(\.account),
                           provider: provider, observedDirectory: observedDirectory)
    }

    /// `registry` nil (not read yet) or empty gives no label.
    nonisolated static func observedLabel(registry: [RelayAgentAccount]?, provider: String,
                                          observedDirectory: String) -> String? {
        guard let registry, !registry.isEmpty else { return nil }
        return registry.first { $0.provider == provider && $0.matches(observedDirectory: observedDirectory) }?.label
    }

    /// Panes whose running agent's account was observed, so a registry that
    /// arrives later re-derives their display label. Held weakly.
    private let observedPanes = NSHashTable<PaneModel>.weakObjects()

    func trackObservedPane(_ pane: PaneModel) {
        if !observedPanes.contains(pane) { observedPanes.add(pane) }
        loadRegistry(for: pane.profile)
    }

    /// Forgets a closed pane. When no tracked pane is left on its host, a
    /// read of that host still retrying makes no further attempt.
    func untrackObservedPane(_ pane: PaneModel) {
        observedPanes.remove(pane)
    }

    func tracksPane(onHost key: String) -> Bool {
        observedPanes.allObjects.contains { Self.hostKey($0.profile) == key }
    }

    /// Reads a remote host's account list. The app sets it at launch; until
    /// then, and in tests that leave it unset, nothing is fetched. Setting it
    /// loads the hosts of panes already tracked.
    var registryLoader: (@MainActor (ConnectionProfile) async throws -> Void)? {
        didSet { for pane in observedPanes.allObjects { loadRegistry(for: pane.profile) } }
    }
    /// Waits between failed reads of one host's list; the last repeats.
    var registryRetryDelays: [Duration] = [.seconds(5), .seconds(30), .seconds(120), .seconds(600)]
    /// The last failure reading each host's list, until a read succeeds.
    @Published private(set) var registryFailures: [String: String] = [:]
    private var registryLoads: [String: Task<Void, Never>] = [:]

    /// Reads a connected remote host's account list once, so its panes get
    /// their labels, and retries a failed read until one succeeds or no
    /// tracked pane is left on the host. Each failure is kept in
    /// `registryFailures` and logged.
    func loadRegistry(for profile: ConnectionProfile) {
        let key = Self.hostKey(profile)
        guard profile.kind != .local, profile.backend == .relay, statuses[key] == nil, registryLoads[key] == nil,
              let load = registryLoader else { return }
        registryLoads[key] = Task { [weak self] in
            var attempt = 0
            // The directory is held only while reading, never across a wait.
            while !Task.isCancelled,
                  let delay = await self?.readRegistry(key: key, profile: profile, load: load, attempt: attempt) {
                try? await Task.sleep(for: delay)
                attempt += 1
            }
            self?.registryLoads[key] = nil
        }
    }

    /// One read of a host's list: the wait before the next, or nil when the
    /// list is in, the read succeeded, or no tracked pane is on the host.
    private func readRegistry(key: String, profile: ConnectionProfile,
                              load: @MainActor (ConnectionProfile) async throws -> Void, attempt: Int) async -> Duration? {
        guard statuses[key] == nil, tracksPane(onHost: key) else { return nil }
        do {
            try await load(profile)
            registryFailures[key] = nil
            return nil
        } catch {
            registryFailures[key] = error.localizedDescription
            RelayDiagnostics.shared.record(category: "connection", name: "agent-accounts-read-failed", details: [
                "host": key, "attempt": String(attempt + 1), "error": String(error.localizedDescription.prefix(300)),
            ])
            return registryRetryDelays[min(attempt, registryRetryDelays.count - 1)]
        }
    }

    /// Re-derives the observed label of every pane on `key` that has an
    /// observed directory from the registry now cached for it, through the
    /// same path a probe uses. Display only; `recorded` keeps precedence and
    /// is never changed here.
    func relabelObservedPanes(_ panes: [PaneModel], hostKey key: String) {
        let registry = statuses[key]?.map(\.account)
        for pane in panes where Self.hostKey(pane.profile) == key {
            guard let state = pane.agentAccount, let provider = state.observedProvider,
                  let directory = state.observedDirectory else { continue }
            let label = state.observedMatches == true && state.recorded?.provider == provider
                ? state.recorded?.label
                : Self.observedLabel(registry: registry, provider: provider, observedDirectory: directory)
            pane.observeAgentAccount(provider: provider, directory: directory, label: label, matches: state.observedMatches)
        }
    }

    @discardableResult
    func refresh(_ profile: ConnectionProfile, probe: Bool = false) async throws -> [RelayAgentAccountStatus] {
        try await send(profile, ["action": "list", "probe": probe]).accounts
    }

    func configure(_ profile: ConnectionProfile, accounts: [RelayAgentAccount],
                   settings: [String: RelayAgentAccountSyncSettings] = [:]) async throws {
        guard accounts.allSatisfy(\.isValid) else { throw Failure.refused("Labels use 1-24 lowercase letters, digits, '-' or '_'; directories are ~/name or an absolute path.") }
        let rows: [[String: Any]] = accounts.map { account in
            var row: [String: Any] = ["provider": account.provider, "label": account.label, "dir": account.dir]
            // The slot's expectation stays with it.
            if let expected = status(for: profile, account: account)?.expectation, !expected.isEmpty {
                row["expect_workspace"] = expected.workspace
                row["expect_plan"] = expected.plan
                row["expect_key"] = expected.key
            }
            if !account.isDefaultDirectory, let extra = settings[account.provider + ":" + account.label] {
                if extra.shareHistory { row["share_history"] = true }
                if !extra.mcpExclude.isEmpty { row["mcp_exclude"] = extra.mcpExclude }
            }
            return row
        }
        try await send(profile, ["action": "configure", "accounts": rows])
    }

    /// Asks each account's own CLI for its plan usage; cached with read time.
    /// Returns the readings this call received.
    @discardableResult
    func refreshUsage(_ profile: ConnectionProfile, provider: String? = nil) async throws -> [RelayAgentAccountUsage] {
        var body: [String: Any] = ["action": "usage"]
        if let provider { body["provider"] = provider }
        let key = Self.hostKey(profile)
        return store(try await send(profile, body).usage ?? [], fromHost: key)
    }

    /// This Mac's launchers name the running app's relayd, so only an
    /// installed Relay (not a test, candidate or build-tree copy, whose path
    /// can disappear) repairs them when it starts. Settings can always.
    nonisolated static func repairsLaunchersAtStart(bundlePath: String, environment: [String: String], isolated: Bool) -> Bool {
        guard !isolated, environment["RELAY_TESTING"] != "1", environment["RELAY_HEADLESS_TESTING"] != "1",
              bundlePath.hasSuffix(".app") else { return false }
        let home = environment["HOME"].map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 } ?? NSHomeDirectory()
        return ["/Applications/", home + "/Applications/"].contains { prefix in
            bundlePath.hasPrefix(prefix) && !bundlePath.dropFirst(prefix.count).contains("/")
        }
    }

    /// Reads (or with `repair`, installs missing and fixes stale) the host's
    /// managed launchers. A relayd that predates this is recorded, not an error.
    @discardableResult
    func refreshLaunchers(_ profile: ConnectionProfile, repair: Bool = false) async throws -> [RelayAgentLauncherStatus]? {
        let key = Self.hostKey(profile)
        do {
            let response = try await send(profile, ["action": repair ? "repair_launchers" : "launchers"])
            launchersUnsupported.remove(key)
            launchers[key] = response.launchers ?? []
            return response.launchers
        } catch Failure.refused(let message) where message.contains("unsupported agent account action") {
            launchersUnsupported.insert(key)
            launchers[key] = nil
            return nil
        }
    }

    private var usageInFlight: Set<String> = []

    /// Menus refresh readings at most every ten minutes: each reading starts
    /// the provider's own CLI once per account.
    func refreshUsageIfStale(_ profile: ConnectionProfile, maximumAge: TimeInterval = 600) async throws {
        let key = Self.hostKey(profile)
        let readings = accounts(for: profile).map { usage[key]?[$0.provider + ":" + $0.label] }
        let fresh = readings.allSatisfy { $0?.readDate.map { Date().timeIntervalSince($0) < maximumAge } ?? false }
        guard !fresh, !usageInFlight.contains(key) else { return }
        usageInFlight.insert(key)
        defer { usageInFlight.remove(key) }
        try await refreshUsage(profile)
    }

    func mcpPreview(_ profile: ConnectionProfile, account: RelayAgentAccount) async throws -> RelayAgentAccountMCPPreview {
        guard let preview = try await send(profile, ["action": "mcp_preview", "provider": account.provider, "label": account.label]).mcpPreview
        else { throw Failure.invalidResponse }
        return preview
    }

    /// Why `provider` cannot be launched on the host through relayd's
    /// managed launcher, or nil when that file exists. Launches never fall
    /// back to a PATH lookup.
    func managedLauncherRefusal(_ profile: ConnectionProfile, provider: String) async -> String? {
        let path = RelayAgentAccount.managedShimPath(provider)
        let refusal = "Relay's \(provider) launcher (\(path)) is not installed on this host, so the agent would start outside Relay. Settings ▸ Agent Accounts ▸ Repair launcher installs it. Nothing was typed."
        guard RelayAgentAccount.providers.contains(provider),
              let payload = try? JSONSerialization.data(withJSONObject: [
                  "request_id": "rpc-" + UUID().uuidString.lowercased(), "operation": "file_stat", "path": path]),
              let data = try? await RelayNodeTransportPool.shared.request(profile: profile, payload: payload),
              data.count <= 1 << 16,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["error"] == nil,
              let result = object["result"] as? [String: Any], result["directory"] as? Bool == false
        else { return refusal }
        return nil
    }

    /// Stores a host's account list. The answer to a requested probe is
    /// recorded as checked now, failed checks included; an unprobed answer
    /// keeps the last probe's result (`keepingProbe`).
    func record(_ accounts: [RelayAgentAccountStatus], executables reported: [String: String]?, fromHost key: String,
                probeRequested: Bool, now: Date = Date()) {
        let earlier = statuses[key] ?? []
        statuses[key] = accounts.map { status in
            probeRequested ? status.probed(at: now)
                : status.keepingProbe(from: earlier.first { $0.provider == status.provider && $0.label == status.label })
        }
        if let reported { executables[key] = reported }
        // No pane keeps a label guessed before this host's registry arrived.
        relabelObservedPanes(observedPanes.allObjects, hostKey: key)
    }

    func prepare(_ profile: ConnectionProfile, account: RelayAgentAccount) async throws {
        try await send(profile, ["action": "prepare", "provider": account.provider, "label": account.label])
    }

    /// `previewFingerprint` (required): the MCP preview the user reviewed;
    /// relayd refuses the sync if the main configuration no longer matches it.
    func sync(_ profile: ConnectionProfile, account: RelayAgentAccount, previewFingerprint: String) async throws -> RelayAgentAccountSyncResult {
        guard !previewFingerprint.isEmpty else { throw Failure.refused("Review the account's MCP servers before syncing.") }
        let body: [String: Any] = ["action": "sync", "provider": account.provider, "label": account.label,
                                   "preview_fingerprint": previewFingerprint]
        guard let result = try await send(profile, body).sync
        else { throw Failure.invalidResponse }
        return result
    }

    /// Signs the account out with the provider's own logout, moves its
    /// folder to ~/.local/share/relay/retired-accounts-<date>/ and forgets
    /// the slot. Only the user's own Settings action removes; relayd refuses
    /// any other origin too, and the default folder, a linked folder and an
    /// account an agent uses. Returns where the folder went and the old path
    /// when something recreated it meanwhile (not registered). A refused
    /// removal can still have forgotten the slot (relayd keeps a folder set
    /// aside when its old path was recreated), so the list is read again.
    func remove(_ profile: ConnectionProfile, account: RelayAgentAccount,
                origin: RelayAgentAccountMoveOrigin) async throws -> (movedTo: String?, recreated: String?) {
        if let refusal = RelayAgentAccountMovePolicy.removalRefusal(origin) { throw Failure.refused(refusal) }
        guard !account.isDefaultDirectory else { throw Failure.refused("The account on the default folder cannot be removed.") }
        let response: Response
        do {
            response = try await send(profile, ["action": "remove", "provider": account.provider, "label": account.label,
                                                "origin": origin.rawValue])
        } catch {
            _ = try? await refresh(profile)
            throw error
        }
        dropUsage(host: Self.hostKey(profile), provider: account.provider, label: account.label)
        return (response.removed?.movedTo, response.removed?.recreated)
    }

    /// Changes a slot's label; its folder and login stay as they are.
    func rename(_ profile: ConnectionProfile, account: RelayAgentAccount, to label: String) async throws {
        guard RelayAgentAccount.validLabel(label) else { throw Failure.refused("Labels use 1-24 lowercase letters, digits, '-' or '_'.") }
        try await send(profile, ["action": "rename", "provider": account.provider, "label": account.label, "new_label": label])
        let key = Self.hostKey(profile)
        if var reading = usage[key]?[account.provider + ":" + account.label] {
            dropUsage(host: key, provider: account.provider, label: account.label)
            reading = reading.relabeled(label)
            usage[key, default: [:]][reading.id] = reading
        }
    }

    func setExpectation(_ profile: ConnectionProfile, account: RelayAgentAccount,
                        _ expected: RelayAgentAccountExpectation) async throws {
        guard expected.isValid else { throw Failure.refused("An expected workspace is at most 64 characters and a plan at most 32, without line breaks.") }
        try await send(profile, ["action": "set_expectation", "provider": account.provider, "label": account.label,
                                 "expect_workspace": expected.workspace, "expect_plan": expected.plan, "expect_key": expected.key])
    }

    /// The model and effort new agents of the account start with; empty
    /// values remove them.
    func setDefaults(_ profile: ConnectionProfile, account: RelayAgentAccount, model: String, effort: String) async throws {
        try await send(profile, ["action": "set_defaults", "provider": account.provider, "label": account.label,
                                 "model": model, "effort": effort])
    }

    private func dropUsage(host: String, provider: String, label: String) {
        usage[host]?[provider + ":" + label] = nil
    }

    private struct Removed: Decodable {
        let movedTo: String?
        let recreated: String?
        enum CodingKeys: String, CodingKey { case movedTo = "moved_to", recreated }
    }

    func mcpExactPreview(_ profile: ConnectionProfile, account: RelayAgentAccount) async throws -> RelayAgentAccountMCPPreview {
        guard let preview = try await send(profile, ["action": "mcp_preview_exact", "provider": account.provider, "label": account.label]).mcpPreview
        else { throw Failure.invalidResponse }
        return preview
    }

    func syncMCPOnly(_ profile: ConnectionProfile, account: RelayAgentAccount, reviewToken: String) async throws -> RelayAgentAccountSyncResult {
        guard !reviewToken.isEmpty else { throw Failure.refused("Review the MCP servers first.") }
        let body: [String: Any] = ["action": "mcp_sync_only", "provider": account.provider,
                                   "label": account.label, "preview_fingerprint": reviewToken]
        guard let result = try await send(profile, body).sync else { throw Failure.invalidResponse }
        return result
    }

    private struct Response: Decodable {
        let accounts: [RelayAgentAccountStatus]
        let removed: Removed?
        let sync: RelayAgentAccountSyncResult?
        let usage: [RelayAgentAccountUsage]?
        let mcpPreview: RelayAgentAccountMCPPreview?
        let executables: [String: String]?
        let launchers: [RelayAgentLauncherStatus]?

        enum CodingKeys: String, CodingKey {
            case accounts, sync, usage, executables, launchers, removed
            case mcpPreview = "mcp_preview"
        }
    }

    @discardableResult
    private func send(_ profile: ConnectionProfile, _ body: [String: Any]) async throws -> Response {
        let payload = try JSONSerialization.data(withJSONObject: [
            "request_id": "accounts-" + UUID().uuidString.lowercased(),
            "operation": "agent_accounts", "agent_accounts": body,
        ])
        let data = try await RelayNodeTransportPool.shared.request(profile: profile, payload: payload,
            requiredCapability: "agent_accounts_v1", timeoutSeconds: 60)
        guard data.count <= 1 << 20, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.invalidResponse
        }
        if let error = object["error"] as? String { throw Failure.refused(String(error.prefix(800))) }
        guard let result = object["result"], JSONSerialization.isValidJSONObject(result),
              let response = try? JSONDecoder().decode(Response.self, from: JSONSerialization.data(withJSONObject: result))
        else { throw Failure.invalidResponse }
        record(response.accounts, executables: response.executables, fromHost: Self.hostKey(profile),
               probeRequested: body["action"] as? String == "list" && body["probe"] as? Bool == true)
        return response
    }
}

extension WorkspaceModel {
    /// The legacy Relay session of a pane's tab, where new tabs open.
    func workspaceSessionID(containingPane paneID: UUID) -> UUID? {
        guard let tabID = tabID(containingPane: paneID) else { return nil }
        return tabs.first { $0.id == tabID }?.sessionID
    }

    /// The workspace of a pane for account rules: the current schema 3 owner
    /// of its tab. The pane header, the sidebar, Miko and "Use by default in
    /// this workspace" all derive it here. The pane's birth session
    /// (`remoteWorkspaceSessionID`, absent on some restored panes) is not used.
    func accountWorkspaceID(containingPane paneID: UUID) -> UUID? {
        tabID(containingPane: paneID).flatMap { workspaceID(forTab: $0) }
    }

    func defaultAgentAccount(_ provider: String, forPane paneID: UUID) -> RelayAgentAccount? {
        agentAccountChoice(provider, forPane: paneID)?.account
    }

    func agentAccountChoice(_ provider: String, forPane paneID: UUID) -> RelayAgentAccountChoice? {
        guard let pane = panes[paneID] else { return nil }
        return RelayAgentAccountDirectory.shared.choice(for: pane.profile, provider: provider,
            workspace: accountWorkspaceID(containingPane: paneID))
    }

    /// Starts `account.provider` in an existing shell pane whose prompt is
    /// verified empty, through Relay's exact managed launcher with the
    /// account's directory, and records the account as part of the pane's
    /// agent identity. Returns why nothing was typed, or nil once it was.
    @discardableResult
    func startAgent(_ account: RelayAgentAccount, inPane paneID: UUID) async -> String? {
        let shellRefusal = "the pane's shell prompt must be empty and owned by its shell. Nothing was typed."
        guard account.isValid, let pane = panes[paneID], pane.contentKind == .terminal, pane.kind == .shell,
              pane.profile.backend == .relay else { return shellRefusal }
        if let refusal = await RelayAgentAccountDirectory.shared.managedLauncherRefusal(pane.profile, provider: account.provider) {
            return refusal
        }
        guard panes[paneID] === pane, pane.kind == .shell,
              await pane.runtime.sendAssistantShellCommand(account.launchCommand(account.provider)) else { return shellRefusal }
        pane.recordAgentAccount(account)
        return nil
    }

    /// Opens a new tab on `profile` in the session of `sourcePane` and, once
    /// its shell prompt is verified empty, types `command`. Returns the pane.
    @discardableResult
    func openTab(running command: String, profile: ConnectionProfile, besidePane sourcePane: UUID?,
                 authorization: @escaping @MainActor () -> Bool = { true },
                 onSubmit: @MainActor () -> Void = {}) async -> PaneModel? {
        guard !command.isEmpty, !Task.isCancelled, authorization() else { return nil }
        let session = sourcePane.flatMap { workspaceSessionID(containingPane: $0) } ?? selectedTab?.sessionID
        onSubmit()
        guard let session else { newTab(profile: profile); return nil }
        let before = activePaneID
        newTab(inSession: session, profile: profile)
        guard activePaneID != before, let pane = activePane, pane.profile == profile, pane.kind == .shell else { return nil }
        for _ in 0..<160 {
            guard !Task.isCancelled, authorization() else { return nil }
            if pane.connectionState == .connected, pane.kind == .shell, pane.runtime.assistantShellPromptIsEmpty() { break }
            try? await Task.sleep(nanoseconds: 125_000_000)
        }
        guard !Task.isCancelled, authorization(), panes[pane.id] === pane,
              await pane.runtime.sendAssistantShellCommand(command, authorization: authorization) else { return nil }
        return pane
    }

    /// A new tab beside `sourcePane` running the provider in `account`.
    /// Returns why no agent was started, or nil.
    @discardableResult
    func startAgentInNewTab(_ account: RelayAgentAccount, besidePane sourcePane: UUID) async -> String? {
        let promptRefusal = "the new tab's shell prompt could not be verified empty in time. Nothing was typed."
        guard account.isValid, let profile = panes[sourcePane]?.profile else { return promptRefusal }
        if let refusal = await RelayAgentAccountDirectory.shared.managedLauncherRefusal(profile, provider: account.provider) {
            return refusal
        }
        guard let pane = await openTab(running: account.launchCommand(account.provider), profile: profile, besidePane: sourcePane)
        else { return promptRefusal }
        pane.recordAgentAccount(account)
        return nil
    }
}
