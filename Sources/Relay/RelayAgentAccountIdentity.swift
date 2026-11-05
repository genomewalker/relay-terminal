import Foundation

/// The workspace (organization) and plan a slot is meant for, and the
/// workspace key the user pinned after a sign-in they checked. Empty fields
/// expect nothing.
struct RelayAgentAccountExpectation: Equatable, Sendable {
    var workspace = ""
    var plan = ""
    var key = ""

    var isEmpty: Bool { workspace.isEmpty && plan.isEmpty && key.isEmpty }

    /// relayd's limits: up to 64 (workspace) or 32 (plan) printable
    /// characters without surrounding space; a key is 16 hex digits.
    var isValid: Bool {
        func text(_ value: String, _ limit: Int) -> Bool {
            value.utf8.count <= limit && value.trimmingCharacters(in: .whitespaces) == value &&
                !value.unicodeScalars.contains { $0.properties.generalCategory == .control || $0.properties.generalCategory == .format }
        }
        return text(workspace, 64) && text(plan, 32) &&
            (key.isEmpty || key.range(of: "^[0-9a-f]{16}$", options: .regularExpression) != nil)
    }
}

/// Who an account is signed in as, at workspace level, from the provider's
/// own reports: Claude's status (organization and plan), Codex's usage
/// session (plan and a hash of its workspace account). The email is only
/// secondary text; it never decides whether two slots are the same.
struct RelayAgentAccountWorkspace: Equatable, Sendable {
    let provider: String
    var name: String?
    var key: String?
    var plan: String?
    var email: String?

    /// "AEGIS-micro · Team" (Claude) or "Pro · workspace #1a2b" (Codex,
    /// which reports no workspace name).
    var title: String {
        let plan = RelayAgentAccountIdentity.planName(plan)
        if let name, !name.isEmpty { return name + (plan.map { " · " + $0 } ?? "") }
        let tag = key.map { "workspace #" + $0.prefix(4) }
        let parts = [plan, tag].compactMap { $0 }
        return parts.isEmpty ? "signed in" : parts.joined(separator: " · ")
    }
}

enum RelayAgentAccountIdentity {
    /// The provider's plan id as people say it.
    static func planName(_ plan: String?) -> String? {
        guard let plan, !plan.isEmpty else { return nil }
        switch plan.lowercased() {
        case "api_key": return "API key"
        case "max": return "Max"
        case "pro": return "Pro"
        case "plus": return "Plus"
        case "team": return "Team"
        case "business": return "Business"
        case "enterprise": return "Enterprise"
        case "free": return "Free"
        default: return plan
        }
    }

    /// The account's current workspace, or nil when it is not signed in or
    /// its last check failed (an earlier reading is never current).
    static func current(status: RelayAgentAccountStatus?, usage: RelayAgentAccountUsage?) -> RelayAgentAccountWorkspace? {
        guard let status, status.exists, !status.checkFailed, status.loggedIn != "no" else { return nil }
        let provider = status.provider
        let reported = RelayAgentAccountWorkspace(provider: provider,
            name: provider == "claude" ? status.workspace : nil,
            key: status.workspaceKey ?? (provider == "codex" ? usage?.workspaceKey : nil),
            plan: status.plan ?? usage?.plan,
            email: status.email ?? usage?.email)
        guard reported.name != nil || reported.key != nil || reported.plan != nil || status.loggedIn == "yes" else { return nil }
        return reported
    }

    /// Why the current workspace is not what the slot expects, or nil. Only
    /// what the provider reported is compared: Codex reports no workspace
    /// name, so for Codex only the plan and a pinned key are checked.
    static func mismatch(_ expected: RelayAgentAccountExpectation, current: RelayAgentAccountWorkspace?) -> String? {
        guard let current, !expected.isEmpty else { return nil }
        var reasons: [String] = []
        if !expected.key.isEmpty, let key = current.key, key != expected.key {
            reasons.append("it is not the workspace pinned for this slot")
        }
        if !expected.workspace.isEmpty, let name = current.name,
           name.compare(expected.workspace, options: [.caseInsensitive, .diacriticInsensitive]) != .orderedSame {
            reasons.append("expected workspace \(expected.workspace)")
        }
        if !expected.plan.isEmpty, let plan = current.plan, plan.lowercased() != expected.plan.lowercased(),
           planName(plan)?.lowercased() != expected.plan.lowercased() {
            reasons.append("expected plan \(planName(expected.plan) ?? expected.plan)")
        }
        guard !reasons.isEmpty else { return nil }
        return "Signed in to \(current.title); " + reasons.joined(separator: ", ")
    }

    /// What the slot expects that the provider's report could not confirm,
    /// or nil when every expected field was compared. A field the provider
    /// did not report is never a match: Codex's workspace key is optional,
    /// and Codex reports no workspace name, so for Codex an expected name is
    /// confirmed only by a matching pinned key.
    static func unverified(_ expected: RelayAgentAccountExpectation, current: RelayAgentAccountWorkspace?) -> String? {
        guard let current, !expected.isEmpty else { return nil }
        func missing(_ value: String?) -> Bool { value?.isEmpty ?? true }
        let pinnedMatch = !expected.key.isEmpty && current.key == expected.key
        var unchecked: [String] = []
        if !expected.key.isEmpty, missing(current.key) { unchecked.append("the workspace pinned for this slot") }
        if !expected.workspace.isEmpty, missing(current.name), !(current.provider == "codex" && pinnedMatch) {
            unchecked.append("workspace \(expected.workspace)")
        }
        if !expected.plan.isEmpty, missing(current.plan) { unchecked.append("plan \(planName(expected.plan) ?? expected.plan)") }
        guard !unchecked.isEmpty else { return nil }
        var text = "Signed in to \(current.title), but the provider did not report enough to verify " +
            unchecked.joined(separator: " or ")
        if current.provider == "codex", !expected.workspace.isEmpty, expected.key.isEmpty {
            text += " (Codex reports no workspace names: pin the workspace in Edit… once you have checked it)"
        }
        return text
    }

    enum Finding: Equatable, Sendable {
        /// The slot uses the same workspace as an earlier slot.
        case duplicate(of: String, title: String)
        case mismatch(String)
        /// Signed in, but what the slot expects could not be checked.
        case unverified(String)

        var text: String {
            switch self {
            case .duplicate(let other, let title): "Same workspace as \(other) (\(title)): both slots use one plan and one usage limit"
            case .mismatch(let text), .unverified(let text): text
            }
        }

        var isUnverified: Bool { if case .unverified = self { true } else { false } }
    }

    /// Per label: a mismatch with its expectation (or an expectation the
    /// provider's report could not confirm), and a duplicate of an
    /// earlier slot of the same provider on the same host. Workspaces are
    /// compared by the provider's organization/workspace key only: one
    /// email in two organizations is two workspaces, two emails in one
    /// organization are one.
    static func findings(_ slots: [(label: String, expected: RelayAgentAccountExpectation, current: RelayAgentAccountWorkspace?)])
        -> [String: [Finding]] {
        var first: [String: String] = [:]
        var result: [String: [Finding]] = [:]
        for slot in slots {
            if let text = mismatch(slot.expected, current: slot.current) {
                result[slot.label, default: []].append(.mismatch(text))
            } else if let text = unverified(slot.expected, current: slot.current) {
                result[slot.label, default: []].append(.unverified(text))
            }
            guard let current = slot.current, let key = current.key, !key.isEmpty else { continue }
            if let earlier = first[key] {
                result[slot.label, default: []].append(.duplicate(of: earlier, title: current.title))
            } else {
                first[key] = slot.label
            }
        }
        return result
    }

    /// The sign-in checklist for a slot: what to choose on the provider's
    /// page, from the slot's expectation.
    static func checklist(provider: String, expected: RelayAgentAccountExpectation, deviceCode: String?) -> [String] {
        var steps: [String] = []
        if let deviceCode { steps.append("Enter the code \(deviceCode) on the page.") }
        let plan = planName(expected.plan)
        if !expected.workspace.isEmpty {
            steps.append("Choose the workspace \(expected.workspace)" + (plan.map { " (\($0))" } ?? "") + ".")
        } else if let plan {
            steps.append("Choose the account with the \(plan) plan.")
        } else {
            steps.append("Choose the workspace this slot is for (set Expected workspace to have Relay check it).")
        }
        steps.append("Approve, then come back: Relay checks which workspace signed in.")
        return steps
    }

    /// A device code a login prints (Codex: "ABCD-12345"); the pane is
    /// untrusted text, so only this exact shape is taken.
    static func deviceCode(in text: String) -> String? {
        let pattern = #"(?<![A-Z0-9-])[A-Z0-9]{4}-[A-Z0-9]{4,5}(?![A-Z0-9-])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        // The last code shown is the current one.
        return regex.matches(in: text, range: range).last.flatMap { Range($0.range, in: text).map { String(text[$0]) } }
    }
}

extension RelayAgentAccountRules {
    /// "New Codex agents use: personal (Pro) on all hosts", from the rules
    /// alone (workspace rules are listed as overrides).
    func effectiveSummary(provider: String, hostKey: String, hostName: String, accounts: [RelayAgentAccount],
                          title: (RelayAgentAccount) -> String?) -> String {
        let name = provider == "codex" ? "Codex" : "Claude"
        guard let choice = choose(provider: provider, host: hostKey, workspace: nil, accounts: accounts) else {
            return "New \(name) agents on \(hostName): no account is set up."
        }
        let account = choice.account.label + (title(choice.account).map { " (\($0))" } ?? "")
        let scope = switch choice.source {
        case .global: "on all hosts"
        case .host: "on \(hostName) (host rule)"
        default: "on \(hostName) (no rule: the account on ~/.\(provider))"
        }
        let overrides = workspaces.values.filter { $0[provider] != nil }.count
        return "New \(name) agents use: \(account) \(scope)" +
            (overrides > 0 ? "; \(overrides) workspace\(overrides == 1 ? "" : "s") use\(overrides == 1 ? "s" : "") its own rule" : "")
    }

    /// The rules after a slot on `host` was renamed: the host's own rule
    /// follows the new label. Global and workspace rules apply to every
    /// host, so they are returned for the user to decide, never rewritten.
    func renaming(provider: String, from old: String, to new: String, host: String) -> (RelayAgentAccountRules, stale: [String]) {
        var next = self
        if next.hosts[host]?[provider] == old { next.hosts[host]?[provider] = new }
        var stale: [String] = []
        if global[provider] == old { stale.append("all hosts") }
        stale += workspaces.filter { $0.value[provider] == old }.map { "workspace " + $0.key.prefix(8) }.sorted()
        return (next, stale)
    }

    /// The rules after a slot on `host` was removed: the host rule naming
    /// it is dropped; global and workspace rules naming the label are
    /// reported (another host may have that label).
    func removing(provider: String, label: String, host: String) -> (RelayAgentAccountRules, stale: [String]) {
        var next = self
        if next.hosts[host]?[provider] == label {
            next.hosts[host]?[provider] = nil
            if next.hosts[host]?.isEmpty == true { next.hosts[host] = nil }
        }
        var stale: [String] = []
        if global[provider] == label { stale.append("all hosts") }
        stale += workspaces.filter { $0.value[provider] == label }.map { "workspace " + $0.key.prefix(8) }.sorted()
        return (next, stale)
    }
}
