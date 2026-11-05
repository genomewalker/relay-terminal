import AppKit
import SwiftUI

extension Notification.Name {
    static let relayStartAgentWithAccount = Notification.Name("relay.start-agent-with-account")
}

/// A provider × account choice from a pane's menu.
struct RelayStartAgentRequest: Sendable {
    enum Action: Sendable { case here, newTab, nativeTab, makeWorkspaceDefault, move, forceReview }
    let paneID: UUID
    let account: RelayAgentAccount
    let action: Action
}

extension WorkspaceModel {
    func handleStartAgentRequest(_ request: RelayStartAgentRequest) {
        guard let pane = panes[request.paneID] else { return }
        let account = request.account
        switch request.action {
        case .here:
            Task {
                if let refusal = await startAgent(account, inPane: request.paneID) {
                    operationError = "Relay did not start \(account.provider) (\(account.label)): " + refusal
                }
            }
        case .newTab:
            Task {
                if let refusal = await startAgentInNewTab(account, besidePane: request.paneID) {
                    operationError = "Relay opened no agent: " + refusal
                }
            }
        case .nativeTab:
            Task {
                if let refusal = await startNativeAgentInNewTab(account, besidePane: request.paneID) {
                    operationError = refusal
                }
            }
        case .makeWorkspaceDefault:
            guard let workspace = accountWorkspaceID(containingPane: request.paneID) else { return }
            RelayAgentAccountRouting.shared.setWorkspace(workspace, provider: account.provider, label: account.label)
            RelayAgentAccountDirectory.shared.objectWillChange.send()
        case .move:
            Task {
                let outcome = await RelayAgentAccountMove.shared.move(pane, in: self, to: account, origin: .user, inputGranted: true)
                if outcome.state != "verified" { operationError = outcome.message }
            }
        case .forceReview:
            // The view handler presents a user-owned review sheet. There is
            // deliberately no direct force dispatch from this model method.
            break
        }
    }
}

private struct RelayForceReviewRequest: Identifiable {
    let id = UUID()
    let request: RelayStartAgentRequest
}

struct RelayStartAgentRequestHandler: ViewModifier {
    let workspace: WorkspaceModel
    @State private var forceReview: RelayForceReviewRequest?

    func body(content: Content) -> some View {
        content
            .onAppear { RelayAgentAccountDirectory.shared.workspace = workspace }
            .onReceive(NotificationCenter.default.publisher(for: .relayStartAgentWithAccount)) { note in
                guard let request = note.object as? RelayStartAgentRequest else { return }
                if case .forceReview = request.action {
                    guard RelayAccountForceFeature.enabled, forceReview == nil else { return }
                    forceReview = RelayForceReviewRequest(request: request)
                } else { workspace.handleStartAgentRequest(request) }
            }
            .sheet(item: $forceReview) { [workspace] entry in
                if let pane = workspace.panes[entry.request.paneID] {
                    let profile = pane.profile
                    let context = RelayExecutionContext(profile: profile, directory: "/")
                    RelayAccountForcePicker(pane: pane, target: entry.request.account, context: context,
                        permits: { [weak workspace, weak pane] in
                            guard let workspace, let pane else { return false }
                            return workspace.panes[pane.id] === pane && pane.profile == profile && pane.connectionState == .connected
                        }, close: { forceReview = nil })
                } else { Text("The pane is no longer available.").padding() }
            }
    }
}

/// Pane menus: start an agent in an account (rule default marked, the
/// account with more headroom marked "suggested" but never preselected),
/// and the user-only "Move to account".
struct RelayAgentAccountMenus: View {
    @ObservedObject var pane: PaneModel
    @ObservedObject private var directory = RelayAgentAccountDirectory.shared

    /// The pane header and the sidebar both show these menus, and Miko uses
    /// the same `agentAccountChoice`. Without the workspace model no default
    /// is marked, rather than one derived without the workspace rule.
    static func choice(_ provider: String, pane paneID: UUID, in workspace: WorkspaceModel?) -> RelayAgentAccountChoice? {
        workspace?.agentAccountChoice(provider, forPane: paneID)
    }

    private func choice(_ provider: String) -> RelayAgentAccountChoice? {
        Self.choice(provider, pane: pane.id, in: directory.workspace)
    }

    private func title(_ account: RelayAgentAccount, chosen: RelayAgentAccountChoice?) -> String {
        var text = (account.provider == "codex" ? "Codex · " : "Claude · ") + account.label
        if chosen?.account == account { text += " (default: \(chosen?.source.rawValue ?? ""))" }
        if directory.suggestion(for: pane.profile, provider: account.provider) == account.label { text += " · suggested" }
        return text + " — " + directory.summary(for: pane.profile, account: account)
    }

    var body: some View {
        Group {
            if RelayNativeRegistry.shared.binding(for: pane) != nil {
                Button("Open native conversation") { pane.nativeConversationVisible = true }
            }
            if pane.contentKind == .terminal {
                Button("Start agent…") {
                    let id = pane.id
                    directory.workspace?.revealPane(id)
                    // Opened after the context menu has closed.
                    Task { @MainActor in RelayAgentPickerPresenter.shared.paneID = id }
                }
                Menu("New native conversation") {
                    ForEach(RelayAgentAccount.providers, id: \.self) { provider in
                        Section(provider == "codex" ? "Codex" : "Claude") {
                            ForEach(directory.accounts(for: pane.profile, provider: provider), id: \.self) { account in
                                Button(account.label) { post(account, .nativeTab) }
                            }
                        }
                    }
                }
                Menu("Use by default in this workspace") {
                    ForEach(RelayAgentAccount.providers, id: \.self) { provider in
                        let chosen = choice(provider)
                        Section(provider == "codex" ? "Codex" : "Claude") {
                            ForEach(directory.accounts(for: pane.profile, provider: provider), id: \.self) { account in
                                Button(account.label) { post(account, .makeWorkspaceDefault) }
                                    .disabled(!RelayAgentPickerRow.canMakeDefault(account, choice: chosen))
                            }
                        }
                    }
                }
            }
            if pane.kind == .claude || pane.kind == .codex {
                let provider = pane.kind == .codex ? "codex" : "claude"
                let current = pane.agentAccount?.recorded
                Menu("Move to account") {
                    ForEach(directory.accounts(for: pane.profile, provider: provider).filter { $0 != current }, id: \.self) { account in
                        Button(title(account, chosen: nil)) { post(account, .move) }
                    }
                }
                .help("Exits the idle agent and resumes the same conversation in another account. Needs an empty prompt and shared conversation history.")
                if RelayAccountForceFeature.enabled {
                    Menu("Review processes before moving") {
                        ForEach(directory.accounts(for: pane.profile, provider: provider).filter { $0 != current }, id: \.self) { account in
                            Button(title(account, chosen: nil)) { post(account, .forceReview) }
                        }
                    }
                }
            }
        }
        .task {
            _ = try? await directory.refresh(pane.profile)
            try? await directory.refreshUsageIfStale(pane.profile)
        }
    }

    private func post(_ account: RelayAgentAccount, _ action: RelayStartAgentRequest.Action) {
        NotificationCenter.default.post(name: .relayStartAgentWithAccount,
            object: RelayStartAgentRequest(paneID: pane.id, account: account, action: action))
    }
}

/// One provider in the start-agent popover: its accounts as short labels and
/// the one a click on Start uses unless another is picked. Free of views so
/// it can be tested.
struct RelayAgentPickerRow: Equatable {
    let provider: String
    let accounts: [RelayAgentAccount]
    let preselected: RelayAgentAccount

    var title: String { provider == "codex" ? "Codex" : "Claude" }

    /// One row per provider that has accounts, in `RelayAgentAccount.providers`
    /// order. The routing rule's account is preselected when the host has it,
    /// else the account on the provider's default directory, else the first.
    static func rows(accounts: [RelayAgentAccount], choices: [String: RelayAgentAccountChoice]) -> [RelayAgentPickerRow] {
        RelayAgentAccount.providers.compactMap { provider in
            let own = accounts.filter { $0.provider == provider }
            guard let first = own.first else { return nil }
            let chosen = choices[provider].map(\.account).flatMap { own.contains($0) ? $0 : nil }
            return RelayAgentPickerRow(provider: provider, accounts: own,
                                       preselected: chosen ?? own.first(where: \.isDefaultDirectory) ?? first)
        }
    }

    /// Hover text for an account: its directory, then identity and usage.
    static func help(_ account: RelayAgentAccount, summary: String, suggested: Bool) -> String {
        var lines = [account.displayDirectory]
        if !summary.isEmpty { lines.append(summary) }
        if suggested { lines.append("Most headroom now") }
        return lines.joined(separator: "\n")
    }

    /// The row Return starts: the pane's current agent, else the first row.
    static func returnRow(_ rows: [RelayAgentPickerRow], paneKind: AgentKind) -> String? {
        let current = paneKind == .codex ? "codex" : paneKind == .claude ? "claude" : nil
        return rows.first { $0.provider == current }?.provider ?? rows.first?.provider
    }

    /// Only a shell pane can take the agent in place; otherwise a new tab.
    static func action(paneKind: AgentKind, newTab: Bool) -> RelayStartAgentRequest.Action {
        paneKind == .shell && !newTab ? .here : .newTab
    }

    /// A workspace default needs a workspace and is not set twice.
    static func canMakeDefault(_ account: RelayAgentAccount, choice: RelayAgentAccountChoice?) -> Bool {
        choice != nil && !(choice?.account == account && choice?.source == .workspace)
    }
}

/// The pane whose start-agent popover is open, so the pane menus can open it
/// on the pane's header.
@MainActor
final class RelayAgentPickerPresenter: ObservableObject {
    static let shared = RelayAgentPickerPresenter()
    @Published var paneID: UUID?
}

/// The pane header's start-agent button and its popover.
struct RelayAgentPickerButton: View {
    @ObservedObject var pane: PaneModel
    @ObservedObject private var presenter = RelayAgentPickerPresenter.shared

    var body: some View {
        Button {
            presenter.paneID = presenter.paneID == pane.id ? nil : pane.id
        } label: {
            Image(systemName: "sparkles")
                .font(RelayTheme.font(size: 9.5, weight: .medium))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(RelayTheme.textMuted)
        .focusEffectDisabled()
        .help("Start agent")
        .accessibilityLabel("Start agent")
        .popover(isPresented: Binding(get: { presenter.paneID == pane.id },
                                      set: { if !$0, presenter.paneID == pane.id { presenter.paneID = nil } }),
                 arrowEdge: .bottom) {
            RelayAgentPicker(pane: pane) { presenter.paneID = nil }
        }
    }
}

/// Start an agent: a row per provider with its accounts as short labels, the
/// default preselected, the directory and usage on hover.
struct RelayAgentPicker: View {
    @ObservedObject var pane: PaneModel
    let dismiss: () -> Void
    @ObservedObject private var directory = RelayAgentAccountDirectory.shared
    @State private var picked: [String: RelayAgentAccount] = [:]
    @State private var newTab = false

    var body: some View {
        let choices = RelayAgentAccount.providers.reduce(into: [String: RelayAgentAccountChoice]()) { result, provider in
            result[provider] = RelayAgentAccountMenus.choice(provider, pane: pane.id, in: directory.workspace)
        }
        let rows = RelayAgentPickerRow.rows(accounts: directory.accounts(for: pane.profile), choices: choices)
        let returnRow = RelayAgentPickerRow.returnRow(rows, paneKind: pane.kind)
        VStack(alignment: .leading, spacing: RelayTheme.spacing(8)) {
            ForEach(rows, id: \.provider) { row in
                let account = picked[row.provider] ?? row.preselected
                HStack(spacing: RelayTheme.spacing(6)) {
                    Label(row.title, systemImage: row.provider == "codex" ? AgentKind.codex.symbol : AgentKind.claude.symbol)
                        .font(RelayTheme.font(size: 11.5, weight: .medium))
                        .frame(width: 70, alignment: .leading)
                    ForEach(row.accounts, id: \.self) { candidate in
                        let selected = candidate == account
                        Button(candidate.label) { picked[row.provider] = candidate }
                            .buttonStyle(.plain)
                            .font(RelayTheme.font(size: 11, weight: .medium))
                            .padding(.horizontal, RelayTheme.spacing(7))
                            .padding(.vertical, RelayTheme.spacing(2))
                            .background(Capsule().fill(selected ? RelayTheme.accent.opacity(0.2) : Color.clear))
                            .overlay(Capsule().stroke(selected ? RelayTheme.accent : RelayTheme.textFaint.opacity(0.5), lineWidth: 0.5))
                            .help(RelayAgentPickerRow.help(candidate, summary: directory.summary(for: pane.profile, account: candidate),
                                                           suggested: directory.suggestion(for: pane.profile, provider: row.provider) == candidate.label))
                            .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                    Spacer(minLength: RelayTheme.spacing(8))
                    if row.provider == returnRow {
                        Button("Start") { start(account) }.keyboardShortcut(.defaultAction)
                    } else {
                        Button("Start") { start(account) }
                    }
                }
            }
            Toggle("In a new tab", isOn: Binding(get: { newTab || pane.kind != .shell }, set: { newTab = $0 }))
                .toggleStyle(.checkbox)
                .font(RelayTheme.font(size: 11, weight: .medium))
                .disabled(pane.kind != .shell)
                .help(pane.kind == .shell ? "Start in this pane, or in a new tab beside it" : "An agent is running here, so it starts in a new tab")
        }
        .padding(RelayTheme.spacing(12))
        .frame(minWidth: 260)
        .task {
            _ = try? await directory.refresh(pane.profile)
            try? await directory.refreshUsageIfStale(pane.profile)
        }
    }

    private func start(_ account: RelayAgentAccount) {
        NotificationCenter.default.post(name: .relayStartAgentWithAccount, object: RelayStartAgentRequest(
            paneID: pane.id, account: account, action: RelayAgentPickerRow.action(paneKind: pane.kind, newTab: newTab)))
        dismiss()
    }
}

/// The account label on an agent pane's header; coral when the running agent
/// reports a different account than the one the pane was started in.
struct RelayAgentAccountBadge: View {
    @ObservedObject var pane: PaneModel
    @ObservedObject private var moves = RelayAgentAccountMove.shared

    var body: some View {
        if pane.kind == .claude || pane.kind == .codex, let state = pane.agentAccount, let label = state.displayLabel {
            Text(label)
                .font(RelayTheme.font(size: 9.5, weight: .medium))
                .padding(.horizontal, RelayTheme.spacing(5))
                .padding(.vertical, RelayTheme.spacing(1))
                .foregroundStyle(state.mismatch ? RelayTheme.coral : RelayTheme.textMuted)
                .overlay(Capsule().stroke(state.mismatch ? RelayTheme.coral : RelayTheme.textFaint.opacity(0.5), lineWidth: 0.5))
                .lineLimit(1)
                .fixedSize()
                .help((state.mismatchDescription ?? "Agent account: \(label)" +
                      (state.recorded.map { " (\($0.displayDirectory))" } ?? "")) +
                      (moves.statuses[pane.id].map { "\n" + $0 } ?? ""))
                .accessibilityLabel(state.mismatch ? "Agent account mismatch" : "Agent account \(label)")
        }
    }
}

/// Settings › Agent Accounts: per host, each provider account with its
/// directory, login state and usage; the label/directory mapping; shared
/// history and MCP server choices for sync; the provider's own login in a
/// new pane; and the routing rules that pick a new agent's account.
struct RelayAgentAccountsSettingsView: View {
    @ObservedObject var workspace: WorkspaceModel
    @ObservedObject private var directory = RelayAgentAccountDirectory.shared
    @ObservedObject private var logins = RelayAgentLoginMonitor.shared
    /// The chosen host's `selectionKey`. SSH-config profiles get new ids on
    /// every refresh of the SSH config, so a choice is never kept by id.
    @State private var hostSelection: String?
    @State private var edits: [RelayAgentAccount] = []
    @State private var extras: [String: RelayAgentAccountSyncSettings] = [:]
    @State private var previews = RelayAgentAccountPreviewCache()
    @State private var message: String?
    /// The logged-in account the user asked to sign in again, awaiting confirmation.
    @State private var resignIn: RelayAgentAccount?
    /// The account the user asked to remove, awaiting confirmation.
    @State private var removing: RelayAgentAccount?
    /// The slot whose label, expectation and model defaults are being edited.
    @State private var editing: RelayAgentAccountEditDraft?
    /// A change on the host is running; other changes wait for it.
    @State private var busy = false
    /// Status and usage are being read. Reading never blocks other actions,
    /// and relayd bounds every provider check, so this always ends.
    @State private var checking = false
    /// A code from Claude's sign-in page, held only until it is sent.
    @State private var signInCode = ""
    /// Unsaved mapping edits are never replaced by a status refresh.
    @State private var dirty = false
    /// Changes with the host shown; a completion from an earlier one is ignored.
    @State private var scope = 0

    private var hosts: [ConnectionProfile] { Self.hosts(workspace.profileStore) }

    private var host: ConnectionProfile { Self.host(hostSelection, in: hosts) }

    static func hosts(_ store: ProfileStore) -> [ConnectionProfile] {
        [.local] + store.connectableHosts.filter { $0.kind == .ssh && $0.backend == .relay }
    }

    static func selectionKey(_ profile: ConnectionProfile) -> String {
        profile.kind == .local ? "local" : profile.connectionKey
    }

    /// The chosen host. Only no choice or This Mac's own key is This Mac: a
    /// remote choice that is no longer listed (its alias removed or renamed)
    /// is a missing host, never This Mac, so no account action can land on
    /// the Mac by accident.
    static func host(_ selection: String?, in hosts: [ConnectionProfile]) -> ConnectionProfile {
        guard let selection, selection != selectionKey(.local) else { return .local }
        return hosts.first { selectionKey($0) == selection } ?? missingHost(selection)
    }

    static func isAvailable(_ selection: String?, in hosts: [ConnectionProfile]) -> Bool {
        guard let selection, selection != selectionKey(.local) else { return true }
        return hosts.contains { selectionKey($0) == selection }
    }

    /// A stand-in for a missing remote host: it names the old choice and has
    /// no address, so it cannot reach any host if it were ever used.
    static func missingHost(_ selection: String) -> ConnectionProfile {
        var name = selection
        if name.hasPrefix("config:") { name = String(name.dropFirst("config:".count)) }
        else if name.hasPrefix("ssh:") { name = String(name.dropFirst("ssh:".count)) }
        return ConnectionProfile(id: UUID(), name: name + " (missing)", kind: .ssh, host: "",
                                 backend: .relay, usesSSHConfig: false)
    }

    private var hostAvailable: Bool { Self.isAvailable(hostSelection, in: hosts) }
    /// Changes when the choice or its availability changes; either reloads the view.
    private var hostScopeID: String { (hostSelection ?? "local") + (hostAvailable ? "" : "\u{1f}missing") }
    /// Routing rules are read live: relay_update_settings can change them.
    private var rules: RelayAgentAccountRules { RelayAgentAccountRouting.shared.rules }
    private var hostKey: String { RelayAgentAccountDirectory.hostKey(host) }
    private var actionsDisabled: Bool { busy || !hostAvailable }
    private var hostName: String { host.kind == .local ? "This Mac" : host.name }

    /// Relay's managed claude/codex launchers on the host and their repair.
    private var launcherSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Agent launchers").font(RelayTheme.font(size: 12, weight: .semibold))
            if directory.launchersUnsupported.contains(hostKey) {
                Text("Launcher state needs a Relay helper update on \(hostName).")
                    .font(RelayTheme.font(size: 11)).foregroundStyle(RelayTheme.textMuted)
            } else if let launchers = directory.launchers[hostKey] {
                ForEach(launchers, id: \.provider) { launcher in
                    Text(launcher.summary)
                        .font(RelayTheme.font(size: 11))
                        .foregroundStyle(launcher.usable ? RelayTheme.textMuted : RelayTheme.coral)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("Launcher state unknown.").font(RelayTheme.font(size: 11)).foregroundStyle(RelayTheme.textFaint)
            }
            Button("Repair launcher") {
                let profile = host
                run(scope) {
                    guard let launchers = try await directory.refreshLaunchers(profile, repair: true) else {
                        return "Launcher repair needs a Relay helper update on \(profile.kind == .local ? "This Mac" : profile.name)."
                    }
                    return launchers.map(\.summary).joined(separator: "\n")
                }
            }
            .disabled(actionsDisabled || directory.launchersUnsupported.contains(hostKey))
            .help("Installs Relay's claude and codex launchers where they are missing and updates Relay's own out-of-date ones. A launcher Relay did not write is never changed.")
        }
    }

    /// Relay's own sign-in window remembers provider sign-ins; this forgets
    /// them.
    private var signInWindowSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Sign-in window").font(RelayTheme.font(size: 12, weight: .semibold))
            Text("Relay's sign-in window keeps its own website data, separate from your browsers, so a provider can remember you between logins.")
                .font(RelayTheme.font(size: 11)).foregroundStyle(RelayTheme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            Button("Sign out of the sign-in window") {
                run(scope) { await logins.signOutOfSignInWindow() }
            }
            .disabled(busy)
            .help("Closes any sign-in window and deletes its cookies and site data, so the next sign-in starts signed out at Claude and OpenAI. Your accounts' CLI logins and your browsers are not touched.")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Claude and Codex accounts are selected by CLAUDE_CONFIG_DIR and CODEX_HOME. Relay never reads or copies credentials; logging in runs the provider's own login in a new pane. Usage comes only from each CLI's own report.")
                .font(RelayTheme.font(size: 11))
                .foregroundStyle(RelayTheme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            Picker("Host", selection: Binding(get: { hostSelection ?? Self.selectionKey(.local) }, set: { hostSelection = $0 })) {
                ForEach(hosts, id: \.connectionKey) { profile in
                    Text(profile.kind == .local ? "This Mac" : profile.name).tag(Self.selectionKey(profile))
                }
                if !hostAvailable, let hostSelection {
                    Text(host.name).tag(hostSelection)
                }
            }
            .frame(maxWidth: 320)
            .disabled(busy)
            if !hostAvailable {
                Text("\(host.name.replacingOccurrences(of: " (missing)", with: "")) is no longer in your hosts (removed or renamed in the SSH config). Choose a host; nothing can be changed here until then.")
                    .font(RelayTheme.font(size: 11)).foregroundStyle(RelayTheme.coral)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if hostAvailable {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(RelayAgentAccount.providers, id: \.self) { provider in
                        Text(rules.effectiveSummary(provider: provider, hostKey: hostKey, hostName: hostName,
                                                    accounts: directory.accounts(for: host)) { account in
                            directory.workspace(for: host, account: account)?.title
                        })
                        .font(RelayTheme.font(size: 11.5, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            ForEach(RelayAgentAccount.providers, id: \.self) { provider in
                Text(provider == "codex" ? "Codex" : "Claude").font(RelayTheme.font(size: 12, weight: .semibold))
                if directory.executable(for: host, provider: provider) == "" {
                    Text("\(provider == "codex" ? "Codex" : "Claude") is not installed on \(hostName).")
                        .font(RelayTheme.font(size: 11)).foregroundStyle(RelayTheme.coral)
                }
                let findings = directory.findings(for: host, provider: provider)
                ForEach(edits.indices.filter { edits[$0].provider == provider }, id: \.self) { index in
                    row(index, findings: findings[edits[index].label] ?? [])
                }
                Button("Add \(provider == "codex" ? "Codex" : "Claude") account") {
                    dirty = true
                    edits.append(.init(provider: provider, label: "account\(edits.count + 1)", dir: "~/.\(provider)-account\(edits.count + 1)"))
                }
                .buttonStyle(.link)
            }
            HStack {
                Button("Save mapping") {
                    // Everything the save uses is captured at the click.
                    let profile = host, accounts = edits, settings = extras, started = scope
                    run(started) {
                        try await directory.configure(profile, accounts: accounts, settings: settings)
                        if Self.saveClearsDirty(started: started, current: scope, saved: accounts, savedSettings: settings,
                                                shown: edits, shownSettings: extras) { dirty = false }
                        return "Saved."
                    }
                }
                .disabled(actionsDisabled || edits.contains { !$0.isValid })
                Button("Refresh status and usage") { check() }
                    .disabled(!hostAvailable || checking)
                if busy || checking { ProgressView().controlSize(.small) }
            }
            if let message {
                Text(message)
                    .font(RelayTheme.font(size: 11, design: .monospaced))
                    .foregroundStyle(RelayTheme.textMuted)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            launcherSection
            Divider()
            signInWindowSection
            Divider()
            routing
        }
        .confirmationDialog(removing.map { "Remove \($0.label)?" } ?? "", isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible, presenting: removing) { account in
            Button("Sign out and remove", role: .destructive) { remove(account) }
            Button("Cancel", role: .cancel) {}
        } message: { account in
            Text("\(account.provider == "codex" ? "Codex" : "Claude")'s own logout signs \(account.label) out on \(hostName). Its folder \(account.displayDirectory) is then moved to ~/.local/share/relay/retired-accounts-<date>/ (nothing is deleted, and nothing a link in it points to is touched), and the slot is forgotten. Refused while an agent uses this account.")
        }
        .sheet(item: $editing) { draft in
            RelayAgentAccountEditSheet(draft: draft, hostName: hostName,
                                       current: directory.workspace(for: host, account: draft.account)) { result in
                editing = nil
                if let result { save(result) }
            }
        }
        .confirmationDialog(resignIn.map { "Sign \($0.label) in again?" } ?? "", isPresented: Binding(
            get: { resignIn != nil }, set: { if !$0 { resignIn = nil } }), titleVisibility: .visible, presenting: resignIn) { account in
            Button("Sign out and sign in again", role: .destructive) { login(account, replacing: true) }
            Button("Cancel", role: .cancel) {}
        } message: { account in
            Text("\(account.provider == "codex" ? "Codex" : "Claude")'s own logout signs \(account.label) (\(directory.summary(for: host, account: account).components(separatedBy: " · ").first ?? "")) out on \(hostName), then its sign-in opens in a new pane. Only this account's directory (\(account.displayDirectory)) is affected.")
        }
        .task(id: hostScopeID) {
            scope += 1
            dirty = false
            previews.reset()
            guard hostAvailable else {
                edits = []
                extras = [:]
                message = nil
                return
            }
            load()
            // Opening the page always asks the providers: only their status
            // commands know about a keychain login.
            check(launchers: true)
        }
        .onChange(of: directory.statuses[hostKey]) { _, statuses in
            if !dirty, let statuses, !statuses.isEmpty { load() }
        }
    }

    private func load() {
        edits = directory.accounts(for: host)
        previews.retain(edits, host: hostKey)
        extras = Dictionary(uniqueKeysWithValues: edits.map { ($0.provider + ":" + $0.label, directory.settings(for: host, account: $0)) })
    }

    @ViewBuilder private func row(_ index: Int, findings: [RelayAgentAccountIdentity.Finding]) -> some View {
        let account = edits[index]
        let key = account.provider + ":" + account.label
        let status = directory.statuses[hostKey]?.first { $0.provider == account.provider && $0.label == account.label }
        let usage = directory.usage(for: host, account: account)
        let current = RelayAgentAccountIdentity.current(status: status, usage: usage)
        let signedIn = status?.loggedIn == "yes"
        let loginRunning = logins.state(host: hostKey, account: account)?.phase == .running
        let canSignIn = !actionsDisabled && account.isValid && !dirty &&
            directory.executable(for: host, provider: account.provider) != "" && !loginRunning
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if status == nil {
                    // A new slot: its label and folder are typed, then saved.
                    TextField("label", text: Binding(get: { edits[index].label },
                        set: { dirty = true; edits[index] = .init(provider: account.provider, label: $0, dir: edits[index].dir) }))
                        .frame(width: 110)
                    TextField("~/.\(account.provider) (default)", text: Binding(get: { edits[index].dir },
                        set: { dirty = true; edits[index] = .init(provider: account.provider, label: edits[index].label, dir: $0) }))
                        .font(RelayTheme.font(size: 11, design: .monospaced))
                        .frame(width: 200)
                } else {
                    Text(account.label).font(RelayTheme.font(size: 12, weight: .semibold)).frame(width: 90, alignment: .leading)
                    Text(headline(status, current: current))
                        .font(RelayTheme.font(size: 12, weight: current != nil ? .medium : .regular))
                        .foregroundStyle(signedIn ? RelayTheme.text : RelayTheme.textFaint)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Button(signedIn ? "Sign in again…" : "Sign in") {
                    if signedIn { resignIn = account } else { login(account) }
                }
                .help(signedIn
                      ? "Signs this account out with the provider's own logout, then opens its sign-in, so it can use another workspace."
                      : "Opens the provider's own sign-in for this account; Relay shows what to choose on the page.")
                .disabled(!canSignIn)
                if status != nil {
                    Button("Edit…") {
                        editing = RelayAgentAccountEditDraft(account: account, status: status)
                    }
                    .disabled(actionsDisabled || dirty)
                    .help("Rename the slot, set the workspace and plan it is for, and the model and effort its new agents use.")
                    if !account.isDefaultDirectory {
                        Button("Remove…") {
                            if let refusal = inUseRefusal(account) { message = refusal } else { removing = account }
                        }
                        .disabled(actionsDisabled || dirty)
                        .help("Signs the account out, moves its folder to ~/.local/share/relay/retired-accounts-<date>/ and forgets the slot.")
                    }
                }
                if !account.isDefaultDirectory, status?.exists == false {
                    Button("Create folder") {
                        let profile = host
                        run(scope) {
                            try await directory.prepare(profile, account: account)
                            try await directory.refresh(profile, probe: true)
                            return "Created \(account.displayDirectory) on \(profile.kind == .local ? "This Mac" : profile.name)."
                        }
                    }
                    .disabled(actionsDisabled || dirty || !account.isValid)
                    .help("Creates this account's directory on the host (mode 0700), ready for syncing shared configuration and signing in.")
                }
                if status == nil {
                    Button(role: .destructive) { dirty = true; edits.remove(at: index) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.plain)
                        .help("Drops this unsaved slot.")
                }
            }
            if status != nil {
                Text(details(account, status: status, current: current))
                    .font(RelayTheme.font(size: 10.5))
                    .foregroundStyle(RelayTheme.textFaint)
                    .textSelection(.enabled)
                usageLine(status: status, usage: usage)
                if let reason = unavailableReason(status) {
                    Text("Status unavailable: " + reason)
                        .font(RelayTheme.font(size: 10.5)).foregroundStyle(RelayTheme.coral)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(findings, id: \.text) { finding in
                    HStack(spacing: 8) {
                        Image(systemName: finding.isUnverified ? "questionmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(RelayTheme.coral)
                        Text(finding.text + ".")
                            .font(RelayTheme.font(size: 11)).foregroundStyle(RelayTheme.coral)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Sign in again") { login(account, replacing: true) }
                            .disabled(!canSignIn)
                            .help("Signs this account out and opens its sign-in at once, with the workspace to choose.")
                    }
                }
            }
            if let login = logins.state(host: hostKey, account: account) {
                loginProgress(login)
            }
            if !account.isDefaultDirectory, status != nil {
                DisclosureGroup("Folder \(account.displayDirectory): shared history, MCP servers and sync") {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Share conversation history with the main account (links \(account.provider == "codex" ? "sessions and archived_sessions" : "projects") only; needed to move a conversation between these accounts)",
                       isOn: Binding(get: { extras[key]?.shareHistory ?? false },
                                     set: { dirty = true; extras[key, default: .init()].shareHistory = $0 }))
                    .font(RelayTheme.font(size: 10.5))
                        mcpServers(account, key: key)
                        syncButton(account)
                    }
                }
                .font(RelayTheme.font(size: 10.5))
            }
            if !account.isValid {
                Text("Labels use 1-24 lowercase letters, digits, '-' or '_'; directories are ~/name or an absolute path, or empty for the default.")
                    .font(RelayTheme.font(size: 10))
                    .foregroundStyle(RelayTheme.coral)
            }
        }
    }

    /// The MCP servers a sync copies, with the environment and header key
    /// names (never values) each would bring; excluded servers are not copied.
    @ViewBuilder private func mcpServers(_ account: RelayAgentAccount, key: String) -> some View {
        if let preview = previews.preview(host: hostKey, account: account) {
            if preview.servers.isEmpty {
                Text("No MCP servers in the main config.").font(RelayTheme.font(size: 10.5)).foregroundStyle(RelayTheme.textFaint)
            }
            ForEach(preview.servers) { server in
                let keys = (server.envKeys ?? []) + (server.headerKeys ?? []).map { "header " + $0 }
                Toggle("Copy MCP server \(server.name)" + (keys.isEmpty ? " (no env keys)" : " — copies keys: " + keys.joined(separator: ", ")),
                       isOn: Binding(get: { !(extras[key]?.mcpExclude.contains(server.name) ?? false) },
                                     set: { keep in
                                         dirty = true
                                         var excluded = Set(extras[key]?.mcpExclude ?? [])
                                         if keep { excluded.remove(server.name) } else { excluded.insert(server.name) }
                                         extras[key, default: .init()].mcpExclude = excluded.sorted()
                                     }))
                    .font(RelayTheme.font(size: 10.5))
            }
        } else {
            Button("Review MCP servers before syncing") {
                let host = host, hostKey = hostKey, generation = previews.generation
                run(scope) {
                    let preview = try await directory.mcpPreview(host, account: account)
                    previews.store(preview, host: hostKey, account: account, generation: generation)
                    return nil
                }
            }
            .buttonStyle(.link)
            .font(RelayTheme.font(size: 10.5))
        }
    }

    /// Precedence: an explicit pick, then workspace, host and global rules,
    /// then the account on the default directory.
    private var routing: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Default account for new agents").font(RelayTheme.font(size: 12, weight: .semibold))
            Text("An explicit pick wins, then the workspace rule, then the host rule, then the global rule. Usage only marks a suggestion; it never changes the default.")
                .font(RelayTheme.font(size: 11)).foregroundStyle(RelayTheme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(RelayAgentAccount.providers, id: \.self) { provider in
                HStack {
                    Text(provider == "codex" ? "Codex" : "Claude").frame(width: 60, alignment: .leading)
                    rulePicker("All hosts", provider: provider, value: rules.global[provider]) { label in
                        RelayAgentAccountRouting.shared.setGlobal(provider: provider, label: label)
                    }
                    rulePicker(host.kind == .local ? "This Mac" : host.name, provider: provider, value: rules.hosts[hostKey]?[provider]) { label in
                        RelayAgentAccountRouting.shared.setHost(hostKey, provider: provider, label: label)
                    }
                    .disabled(!hostAvailable)
                }
            }
            ForEach(workspace.ownership.orderedWorkspaces) { record in
                HStack {
                    Text(record.name).lineLimit(1).frame(width: 160, alignment: .leading)
                    ForEach(RelayAgentAccount.providers, id: \.self) { provider in
                        rulePicker(provider == "codex" ? "Codex" : "Claude", provider: provider,
                                   value: rules.workspaces[RelayAgentAccountRules.workspaceKey(record.id)]?[provider]) { label in
                            RelayAgentAccountRouting.shared.setWorkspace(record.id, provider: provider, label: label)
                        }
                    }
                }
            }
        }
    }

    private func rulePicker(_ title: String, provider: String, value: String?, set: @escaping (String?) -> Void) -> some View {
        let labels = Array(Set(edits.filter { $0.provider == provider }.map(\.label) + (value.map { [$0] } ?? []))).sorted()
        return Picker(title, selection: Binding(get: { value ?? "" }, set: { label in
            set(label.isEmpty ? nil : label)
            directory.objectWillChange.send()
        })) {
            Text("No rule").tag("")
            ForEach(labels, id: \.self) { Text($0).tag($0) }
        }
        .frame(maxWidth: 220)
    }

    /// "AEGIS-micro · Team" when the provider reports the workspace, else
    /// the login state.
    private func headline(_ status: RelayAgentAccountStatus?, current: RelayAgentAccountWorkspace?) -> String {
        guard let status else { return checking ? "checking…" : "status unknown" }
        if !status.exists { return "not set up" }
        if let current { return current.title }
        switch status.loggedIn {
        case "yes": return "signed in" + (status.method.map { " · " + ($0 == "api_key" ? "API key" : $0) } ?? "")
        case "no": return "not signed in"
        default: return checking ? "checking…" : (status.checkFailed ? "status unavailable" : "status unknown")
        }
    }

    /// email · folder · expected workspace · model and effort.
    private func details(_ account: RelayAgentAccount, status: RelayAgentAccountStatus?,
                         current: RelayAgentAccountWorkspace?) -> String {
        var parts: [String] = []
        if let email = current?.email { parts.append(email) }
        parts.append(account.displayDirectory)
        if let expected = status?.expectation, !expected.workspace.isEmpty || !expected.plan.isEmpty {
            parts.append("for " + [expected.workspace, RelayAgentAccountIdentity.planName(expected.plan) ?? ""]
                .filter { !$0.isEmpty }.joined(separator: " · "))
        }
        let defaults = [status?.model, status?.effort.map { "effort " + $0 }].compactMap { $0 }
        parts.append(defaults.isEmpty ? "provider's default model" : "new agents: " + defaults.joined(separator: ", "))
        if let error = status?.defaultsError { parts.append("model defaults unusable: " + error) }
        return parts.joined(separator: " · ")
    }

    /// 5-hour and weekly use side by side, each with its reset.
    @ViewBuilder private func usageLine(status: RelayAgentAccountStatus?, usage: RelayAgentAccountUsage?) -> some View {
        if status?.exists != false {
            if let usage, usage.status == "ok" {
                HStack(spacing: 16) {
                    ForEach(usage.orderedWindows, id: \.name) { window in
                        HStack(spacing: 4) {
                            Text(window.displayName).foregroundStyle(RelayTheme.textMuted)
                            Text("\(Int(window.usedPercent.rounded()))%")
                                .foregroundStyle(window.usedPercent >= 90 ? RelayTheme.coral : RelayTheme.text)
                            if let reset = Self.resetText(window.resetsAt) {
                                Text("resets " + reset).foregroundStyle(RelayTheme.textFaint)
                            }
                        }
                    }
                    Text("read " + RelayAgentAccountUsage.age(usage.readDate, now: Date())).foregroundStyle(RelayTheme.textFaint)
                }
                .font(RelayTheme.font(size: 10.5))
            } else if let usage, !usage.notSetUp {
                Text("Usage unavailable: " + (usage.reason ?? "the provider did not report it"))
                    .font(RelayTheme.font(size: 10.5)).foregroundStyle(RelayTheme.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    static func resetText(_ value: String?) -> String? {
        guard let value, let date = ISO8601DateFormatter().date(from: value) else { return nil }
        let format = DateFormatter()
        format.dateFormat = date.timeIntervalSinceNow < 86_400 ? "HH:mm" : "EEE HH:mm"
        return format.string(from: date)
    }

    /// Why the provider's own check gave no answer, from relayd.
    private func unavailableReason(_ status: RelayAgentAccountStatus?) -> String? {
        guard let status, status.checkFailed else { return nil }
        return status.probeReason ?? "the provider's status command did not answer"
    }

    private func syncButton(_ account: RelayAgentAccount) -> some View {
        Button("Sync shared config") {
            // The host, account and the preview reviewed on that host
            // are captured at the click.
            guard let reviewed = previews.preview(host: hostKey, account: account)?.fingerprint else { return }
            let profile = host, key = hostKey
            run(scope) {
                defer { previews.remove(host: key, account: account) }
                return "\(account.label): " + (try await directory.sync(profile, account: account, previewFingerprint: reviewed)).summary
            }
        }
        .disabled(actionsDisabled || dirty || account.isDefaultDirectory || !account.isValid ||
                  previews.preview(host: hostKey, account: account)?.fingerprint == nil)
        .help("Links CLAUDE.md, settings, skills, agents, commands and plugins (Codex: AGENTS.md, prompts, skills, config) from the main directory and merges the MCP servers you keep. Credentials are never shared. Review the MCP servers first; each sync needs a fresh review. Refused while an agent runs in this account.")
    }

    /// Why `account` cannot be removed now: an agent pane on this host was
    /// started in it. relayd also refuses while any process uses it.
    private func inUseRefusal(_ account: RelayAgentAccount) -> String? {
        let agents = workspace.panes.values.filter { $0.kind == .claude || $0.kind == .codex }
            .map { (host: RelayAgentAccountDirectory.hostKey($0.profile), recorded: $0.agentAccount?.recorded) }
        return Self.inUseRefusal(account, hostKey: hostKey, hostName: hostName, agents: agents)
    }

    /// `agents`: each agent pane's host and recorded account.
    static func inUseRefusal(_ account: RelayAgentAccount, hostKey: String, hostName: String,
                             agents: [(host: String, recorded: RelayAgentAccount?)]) -> String? {
        let count = agents.filter { agent in
            agent.host == hostKey && agent.recorded.map { $0.provider == account.provider && $0.label == account.label } == true
        }.count
        guard count > 0 else { return nil }
        return "\(account.label) is in use by \(count) agent pane\(count == 1 ? "" : "s") on \(hostName). Stop \(count == 1 ? "it" : "them") before removing the account; nothing was changed."
    }

    private func remove(_ account: RelayAgentAccount) {
        if let refusal = inUseRefusal(account) { message = refusal; return }
        let profile = host, key = hostKey
        run(scope) {
            let (movedTo, recreated) = try await directory.remove(profile, account: account, origin: .user)
            let (next, stale) = RelayAgentAccountRouting.shared.rules.removing(provider: account.provider, label: account.label, host: key)
            RelayAgentAccountRouting.shared.update { $0 = next }
            directory.objectWillChange.send()
            return "Removed \(account.label)." + (movedTo.map { " Its folder is now " + $0 + "." } ?? "") +
                (recreated.map { " Something created " + $0 + " again during the removal; it was left as it is and is not an account." } ?? "") +
                (stale.isEmpty ? "" : " Rules still naming \(account.label): " + stale.joined(separator: ", ") + " (they apply to other hosts too; change them below).")
        }
    }

    /// Applies an edit: rename first, so the expectation and defaults land
    /// on the slot's new label.
    private func save(_ result: RelayAgentAccountEditDraft) {
        let profile = host, key = hostKey
        run(scope) {
            var account = result.account
            var notes: [String] = []
            if result.label != account.label {
                try await directory.rename(profile, account: account, to: result.label)
                let (next, stale) = RelayAgentAccountRouting.shared.rules.renaming(provider: account.provider, from: account.label,
                                                                                   to: result.label, host: key)
                RelayAgentAccountRouting.shared.update { $0 = next }
                for pane in workspace.panes.values where RelayAgentAccountDirectory.hostKey(pane.profile) == key {
                    pane.relabelAgentAccount(provider: account.provider, from: account.label, to: result.label)
                }
                if !stale.isEmpty {
                    notes.append("Rules still naming \(account.label): " + stale.joined(separator: ", ") + " (they apply to other hosts too).")
                }
                account = .init(provider: account.provider, label: result.label, dir: account.dir)
            }
            if result.expected != result.original.expected {
                try await directory.setExpectation(profile, account: account, result.expected)
            }
            if result.model != result.original.model || result.effort != result.original.effort {
                try await directory.setDefaults(profile, account: account, model: result.model, effort: result.effort)
            }
            directory.objectWillChange.send()
            return (["Saved \(account.label)."] + notes).joined(separator: " ")
        }
    }

    /// Reads status and usage without blocking other actions. relayd bounds
    /// every provider check and Relay's request has its own time limit, so
    /// the spinner always stops.
    private func check(launchers: Bool = false) {
        guard hostAvailable, !checking else { return }
        let profile = host, started = scope
        checking = true
        Task { @MainActor in
            defer { checking = false }
            var failures: [String] = []
            do { try await directory.refresh(profile, probe: true) } catch { failures.append(error.localizedDescription) }
            do { try await directory.refreshUsage(profile) } catch { failures.append("Usage: " + error.localizedDescription) }
            if launchers { _ = try? await directory.refreshLaunchers(profile) }
            if !failures.isEmpty, started == scope { message = "Status unavailable: " + failures.joined(separator: "\n") }
        }
    }

    /// The login pane's progress: the provider's sign-in page to open in the
    /// Mac's browser, then the outcome the provider's status reports.
    @ViewBuilder private func loginProgress(_ login: RelayAgentLoginState) -> some View {
        HStack(spacing: 8) {
            switch login.phase {
            case .running:
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 3) {
                    Text(login.signIn == nil ? "Sign-in running in its pane; waiting for the provider's page…" : loginHint(login.account))
                        .font(RelayTheme.font(size: 10.5)).foregroundStyle(RelayTheme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    if let error = login.handoffError {
                        Text(error).font(RelayTheme.font(size: 10.5)).foregroundStyle(RelayTheme.coral)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(Array(RelayAgentAccountIdentity.checklist(provider: login.account.provider, expected: login.expected,
                                                                       deviceCode: login.deviceCode).enumerated()), id: \.offset) { item in
                        Text("\(item.offset + 1). " + item.element)
                            .font(RelayTheme.font(size: 11, weight: .medium))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 10) {
                        if let code = login.deviceCode {
                            Text(code).font(RelayTheme.font(size: 12, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                            Button("Copy code") { Self.copy(code) }.buttonStyle(.link)
                        }
                        if let url = login.signIn {
                            Button(login.opened ? "Show the sign-in again" : "Show sign-in") {
                                logins.openSignIn(host: login.host, account: login.account)
                            }
                            .buttonStyle(.link)
                            Button("Copy link") { Self.copy(url.absoluteString) }.buttonStyle(.link)
                        }
                    }
                    .font(RelayTheme.font(size: 10.5))
                    // Claude on a remote host: its page shows a code that
                    // its login in the pane waits for (once the pane shows
                    // Claude's paste prompt and Relay bound to that login).
                    if login.account.provider == "claude", host.kind != .local, login.signIn != nil, login.binding != nil,
                       !login.codeSent {
                        HStack(spacing: 8) {
                            SecureField("Code from the page", text: $signInCode)
                                .frame(width: 240)
                            Button("Send to login pane") {
                                let code = signInCode, account = login.account, key = login.host
                                signInCode = ""
                                Task { @MainActor in
                                    if let refusal = await logins.sendCode(code, host: key, account: account) { message = refusal }
                                }
                            }
                            .disabled(signInCode.isEmpty)
                            .help("Types only this code into this login's pane, while Claude's login there is waiting for it. The code is not kept.")
                        }
                        .font(RelayTheme.font(size: 10.5))
                    }
                }
            case .finished(let text):
                Text(text).font(RelayTheme.font(size: 10.5)).foregroundStyle(RelayTheme.mint)
            case .failed(let text):
                Text(text).font(RelayTheme.font(size: 10.5)).foregroundStyle(RelayTheme.coral)
                if login.account.provider == "codex", !login.systemBrowser {
                    Button("Sign in with your default browser (outside Relay)") {
                        self.login(login.account, replacing: login.replacing, systemBrowser: true)
                    }
                        .buttonStyle(.link).font(RelayTheme.font(size: 10.5))
                        .help("For a workspace that does not allow Codex device codes: runs Codex's browser login, which opens the page in your default browser, outside Relay.")
                        .disabled(actionsDisabled)
                }
            }
        }
    }

    private func loginHint(_ account: RelayAgentAccount) -> String {
        if account.provider == "codex" {
            return "Relay shows Codex's sign-in page in its sign-in window; enter the code there. On the page:"
        }
        guard host.kind != .local else { return "Relay shows Claude's sign-in page in its sign-in window; the pane finishes by itself. On the page:" }
        return "Relay shows Claude's sign-in page in its sign-in window; copy the code it shows into the field below. On the page:"
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Creates the directory through relayd, then opens a pane on the host
    /// running the provider's own login with only the account variable set,
    /// and follows it to the provider's own status report.
    private func login(_ account: RelayAgentAccount, replacing: Bool = false, systemBrowser: Bool = false) {
        let profile = host
        run(scope) {
            await logins.start(account, on: profile, in: workspace, replacing: replacing, systemBrowser: systemBrowser)
        }
    }

    /// A completed save clears the dirty state only while the same host is
    /// shown and its edits are still exactly the ones saved.
    static func saveClearsDirty(started: Int, current: Int, saved: [RelayAgentAccount],
                                savedSettings: [String: RelayAgentAccountSyncSettings], shown: [RelayAgentAccount],
                                shownSettings: [String: RelayAgentAccountSyncSettings]) -> Bool {
        started == current && saved == shown && savedSettings == shownSettings
    }

    /// Runs one action started while `started` was the shown host's scope.
    /// Its message is dropped if the view has moved on since.
    private func run(_ started: Int, _ work: @escaping @MainActor () async throws -> String?) {
        guard hostAvailable else {
            message = "The selected host is no longer available; nothing was done."
            return
        }
        busy = true
        Task { @MainActor in
            defer { busy = false }
            let text: String?
            do { text = try await work() } catch { text = error.localizedDescription }
            if let text, started == scope { message = text }
        }
    }
}

/// One slot's editable settings: its label, the workspace and plan it is
/// for, and the model and effort its new agents start with. None of them
/// touches the slot's login or folder.
struct RelayAgentAccountEditDraft: Identifiable, Equatable {
    struct Values: Equatable {
        var label: String
        var expected: RelayAgentAccountExpectation
        var model: String
        var effort: String
    }
    let account: RelayAgentAccount
    let original: Values
    var label: String
    var expected: RelayAgentAccountExpectation
    var model: String
    var effort: String

    var id: String { account.provider + ":" + account.label }

    init(account: RelayAgentAccount, status: RelayAgentAccountStatus?) {
        self.account = account
        original = .init(label: account.label, expected: status?.expectation ?? .init(),
                         model: status?.model ?? "", effort: status?.effort ?? "")
        label = original.label
        expected = original.expected
        model = original.model
        effort = original.effort
    }

    static func efforts(_ provider: String) -> [String] {
        provider == "codex" ? ["minimal", "low", "medium", "high", "xhigh"] : ["low", "medium", "high", "xhigh", "max"]
    }

    /// relayd's model name rule.
    static func validModel(_ model: String) -> Bool {
        model.isEmpty || model.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:/\[\]-]{0,79}$"#, options: .regularExpression) != nil
    }

    var problem: String? {
        if !RelayAgentAccount.validLabel(label) { return "Labels use 1-24 lowercase letters, digits, '-' or '_'." }
        if !expected.isValid { return "An expected workspace is at most 64 characters and a plan at most 32." }
        if !Self.validModel(model) { return "A model name uses letters, digits and . _ : / - (at most 80)." }
        return nil
    }
}

struct RelayAgentAccountEditSheet: View {
    @State var draft: RelayAgentAccountEditDraft
    let hostName: String
    let current: RelayAgentAccountWorkspace?
    let done: (RelayAgentAccountEditDraft?) -> Void

    var body: some View {
        let name = draft.account.provider == "codex" ? "Codex" : "Claude"
        VStack(alignment: .leading, spacing: 12) {
            Text("\(name) · \(draft.account.label) on \(hostName)").font(RelayTheme.font(size: 13, weight: .semibold))
            Form {
                TextField("Label", text: $draft.label)
                Section("This slot is for") {
                    TextField("Workspace", text: $draft.expected.workspace, prompt: Text(name == "Claude" ? "e.g. AEGIS-micro" : "e.g. AEGIS-micro (shown on the sign-in page)"))
                    TextField("Plan", text: $draft.expected.plan, prompt: Text(name == "Claude" ? "e.g. team or max" : "e.g. team or pro"))
                    if let key = current?.key {
                        Toggle("Pin the workspace it is signed in to now (\(current?.title ?? ""))", isOn: Binding(
                            get: { draft.expected.key == key }, set: { draft.expected.key = $0 ? key : "" }))
                    } else if !draft.expected.key.isEmpty {
                        Toggle("Keep the pinned workspace", isOn: Binding(
                            get: { !draft.expected.key.isEmpty }, set: { if !$0 { draft.expected.key = "" } }))
                    }
                    Text(name == "Codex"
                         ? "Codex reports the plan and a workspace id, not the workspace's name: Relay checks the plan and a pinned workspace, and shows the name on the sign-in checklist."
                         : "After every sign-in Relay compares the workspace and plan Claude reports with these.")
                        .font(RelayTheme.font(size: 10.5)).foregroundStyle(RelayTheme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Section("New agents in this account") {
                    TextField("Model", text: $draft.model, prompt: Text("provider's default"))
                    Picker("Effort", selection: $draft.effort) {
                        Text("Provider's default").tag("")
                        ForEach(RelayAgentAccountEditDraft.efforts(draft.account.provider), id: \.self) { Text($0).tag($0) }
                    }
                    Text("Used when a launch names no model or effort of its own; continued and resumed conversations keep theirs.")
                        .font(RelayTheme.font(size: 10.5)).foregroundStyle(RelayTheme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)
            if let problem = draft.problem {
                Text(problem).font(RelayTheme.font(size: 11)).foregroundStyle(RelayTheme.coral)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { done(nil) }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { done(draft) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.problem != nil || draft.original == .init(label: draft.label, expected: draft.expected,
                                                                                model: draft.model, effort: draft.effort))
            }
        }
        .padding(18)
        .frame(width: 460)
    }
}
