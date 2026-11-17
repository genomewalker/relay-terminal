import AppKit
import SwiftUI

/// One agent action that touched a pane or tab the user was not looking at.
struct RelayActivityEntry: Identifiable, Equatable, Sendable {
    let id: UUID
    let at: Date
    let caller: String
    let summary: String
    let paneID: UUID?
    let tabID: UUID?
    var isRead: Bool
}

/// What an audited, successful caller request did, for the activity list.
/// An allow-list: requests not named here (reads, host operations, explicit
/// navigation such as show/select) produce no entry.
enum RelayActivityDescriber {
    struct Description: Equatable {
        let summary: String
        let paneID: UUID?
        let tabID: UUID?
        /// The caller's request ID, so a replayed request is recorded once.
        let requestID: String?
    }

    static func describe(method: String, path: String, request: Data, response: Data,
                         paneName: (UUID) -> String? = { _ in nil }) -> Description? {
        guard method == "POST" else { return nil }
        let input = (try? JSONSerialization.jsonObject(with: request)) as? [String: Any] ?? [:]
        let output = (try? JSONSerialization.jsonObject(with: response)) as? [String: Any] ?? [:]
        // A launch that created a pane but failed to start still left a pane behind.
        let status = output["status"] as? String ?? ""
        if ["failed", "unavailable", "expired", "refused"].contains(status) || status.hasPrefix("rejected") { return nil }
        if output["delivered"] as? Bool == false { return nil }
        func string(_ object: [String: Any], _ keys: String...) -> String? {
            for key in keys { if let value = object[key] as? String, !value.isEmpty { return value } }
            return nil
        }
        func uuid(_ object: [String: Any], _ keys: String...) -> UUID? {
            for key in keys { if let value = object[key] as? String, let id = UUID(uuidString: value) { return id } }
            return nil
        }
        let requestID = string(input, "requestID", "request_id", "messageID", "message_id")
        func named(_ id: UUID?) -> String {
            guard let id, let name = paneName(id)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return "a pane" }
            return "'\(String(name.prefix(60)))'"
        }
        func entry(_ summary: String, pane: UUID?, tab: UUID? = nil) -> Description? {
            guard pane != nil || tab != nil else { return nil }
            return Description(summary: summary, paneID: pane, tabID: tab, requestID: requestID)
        }
        let responsePane = uuid(output, "paneID", "pane_id")
        let responseTab = uuid(output, "tabID", "tab_id")

        let parts = path.split(separator: "/")
        if parts.count == 4, parts[0] == "api", parts[1] == "panes", let pane = UUID(uuidString: String(parts[2])) {
            switch parts[3] {
            case "message": return entry("Sent a message to \(named(pane))", pane: pane)
            case "input-direct": return entry("Sent a command to \(named(pane))", pane: pane)
            case "input-recover-shell": return entry("Recovered the shell in \(named(pane))", pane: pane)
            case "codex-resume": return entry("Resumed Codex in \(named(pane))", pane: pane)
            default: return nil
            }
        }
        switch path {
        case "/api/workspace/new-local-tab":
            return entry("Opened a new local tab", pane: responsePane, tab: responseTab)
        case "/api/workspace/new-stacked-pane":
            let host = string(input, "host") ?? "a host"
            return entry("Opened a stacked pane on \(host)", pane: responsePane, tab: responseTab)
        case "/api/workspace/stack-pane":
            let pane = responsePane ?? uuid(input, "paneID")
            return entry("Stacked \(named(pane))", pane: pane, tab: responseTab)
        case "/api/workspace/browser":
            let pane = responsePane ?? uuid(input, "paneID")
            return entry("Used the browser in \(named(pane))", pane: pane, tab: responseTab)
        case "/api/workspace/rename-pane":
            let pane = uuid(input, "paneID")
            let name = string(input, "name").map { "'\(String($0.prefix(60)))'" } ?? "a new name"
            return entry("Renamed a pane to \(name)", pane: pane)
        case "/api/workspace/tab-action":
            let action = string(input, "action") ?? "changed"
            let verb = ["rename": "Renamed", "close": "Closed", "move": "Moved"][action] ?? "Changed"
            return entry("\(verb) a tab", pane: nil, tab: responseTab ?? uuid(input, "tabID"))
        case "/api/workspace/launch-agent":
            let created = output["created"] as? [String: Any] ?? [:]
            let provider = string(input, "provider").map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "an agent"
            let host = string(input, "host") ?? "a host"
            let verb = status == "launch_failed" ? "Opened a pane but failed to launch" : "Launched"
            return entry("\(verb) \(provider) on \(host)", pane: uuid(created, "pane_id", "paneID"),
                         tab: uuid(created, "tab_id", "tabID"))
        case "/api/agent-accounts/move":
            let pane = uuid(input, "paneID") ?? responsePane
            let account = string(input, "account").map { " to account '\($0.prefix(60))'" } ?? ""
            return entry("Moving \(named(pane))\(account)", pane: pane)
        case "/api/recovery/attach":
            return entry("Reattached a recovered pane", pane: responsePane ?? uuid(input, "paneID", "pane_id"), tab: responseTab)
        case "/api/recovery/terminate":
            return entry("Terminated \(named(uuid(input, "paneID", "pane_id")))", pane: uuid(input, "paneID", "pane_id"))
        default:
            return nil
        }
    }
}

/// Where an entry's link goes now. A pane or tab closed since keeps its row.
enum RelayActivityTarget: Equatable {
    case pane(UUID)
    case tab(UUID)
    case gone

    static func resolve(_ entry: RelayActivityEntry, paneExists: (UUID) -> Bool, tabExists: (UUID) -> Bool) -> Self {
        if let pane = entry.paneID, paneExists(pane) { return .pane(pane) }
        if let tab = entry.tabID, tabExists(tab) { return .tab(tab) }
        return .gone
    }
}

/// The activity list: agent actions outside the user's focus, newest first,
/// bounded. Recording never changes focus, selection or first responder;
/// only clicking an entry (sidebar row, toast or banner) shows its pane.
@MainActor
final class RelayActivityLog: ObservableObject {
    static let shared = RelayActivityLog()
    static let limit = 200
    static let toastDuration: Duration = .seconds(6)

    @Published private(set) var entries: [RelayActivityEntry] = []
    /// The newest entry while its in-app toast is showing.
    @Published private(set) var toast: RelayActivityEntry?
    /// Called once per new entry; the notifier posts a banner while Relay is in the background.
    var onRecord: ((RelayActivityEntry) -> Void)?
    private var seen: [String] = []
    private var toastTask: Task<Void, Never>?

    var unreadCount: Int { entries.lazy.filter { !$0.isRead }.count }

    /// True when the user was not looking at the target: Relay in the
    /// background, or a target other than the focused pane (a tab-only
    /// target: other than the selected tab).
    nonisolated static func isOutsideFocus(paneID: UUID?, tabID: UUID?, focusedPane: UUID?, focusedTab: UUID?,
                                           appActive: Bool) -> Bool {
        if !appActive { return true }
        if let paneID { return paneID != focusedPane }
        if let tabID { return tabID != focusedTab }
        return false
    }

    /// Records an entry; nil for a repeat of the same caller request.
    @discardableResult
    func record(caller: String, summary: String, paneID: UUID?, tabID: UUID?,
                dedupeKey: String? = nil, at: Date = Date(), showToast: Bool = false) -> RelayActivityEntry? {
        if let dedupeKey {
            guard !seen.contains(dedupeKey) else { return nil }
            seen.append(dedupeKey)
            if seen.count > Self.limit * 2 { seen.removeFirst(seen.count - Self.limit * 2) }
        }
        let entry = RelayActivityEntry(id: UUID(), at: at, caller: String(caller.prefix(80)),
                                       summary: String(summary.prefix(200)), paneID: paneID, tabID: tabID, isRead: false)
        // Newest first by time; an out-of-order arrival is placed by its time.
        let index = entries.firstIndex { $0.at <= at } ?? entries.endIndex
        entries.insert(entry, at: index)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
        onRecord?(entry)
        if showToast { present(entry) }
        return entry
    }

    func markRead(_ id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }), !entries[index].isRead else { return }
        entries[index].isRead = true
    }

    func markAllRead() {
        guard entries.contains(where: { !$0.isRead }) else { return }
        for index in entries.indices { entries[index].isRead = true }
    }

    func clear() {
        entries.removeAll()
        dismissToast()
    }

    func dismissToast() {
        toastTask?.cancel()
        toastTask = nil
        toast = nil
    }

    private func present(_ entry: RelayActivityEntry) {
        toast = entry
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: Self.toastDuration)
            guard !Task.isCancelled, let self, self.toast?.id == entry.id else { return }
            self.toast = nil
        }
    }

    /// The user clicked an entry: the only path from activity to focus.
    func open(_ entry: RelayActivityEntry, in workspace: WorkspaceModel) {
        markRead(entry.id)
        if toast?.id == entry.id { dismissToast() }
        switch RelayActivityTarget.resolve(entry, paneExists: { workspace.panes[$0] != nil },
                                           tabExists: { id in workspace.tabs.contains { $0.id == id } }) {
        case .pane(let pane): workspace.revealPane(pane, origin: .user)
        case .tab(let tab): workspace.selectTab(tab, origin: .user)
        case .gone: break
        }
    }

    /// Called by the control server after a successful mutating caller
    /// request. Focus is the one captured before the request ran, so an
    /// action that moved focus to its own target is still listed.
    func observe(caller: String, method: String, path: String, request: Data, response: Data,
                 focusedPane: UUID?, focusedTab: UUID?, workspace: WorkspaceModel?) {
        guard let description = RelayActivityDescriber.describe(method: method, path: path, request: request, response: response,
                                                                paneName: { workspace?.panes[$0]?.displayName }) else { return }
        let appActive = NSApp?.isActive ?? false
        guard Self.isOutsideFocus(paneID: description.paneID, tabID: description.tabID, focusedPane: focusedPane,
                                  focusedTab: focusedTab, appActive: appActive) else { return }
        record(caller: caller, summary: description.summary, paneID: description.paneID, tabID: description.tabID,
               dedupeKey: description.requestID.map { path + "#" + $0 }, showToast: appActive)
    }
}

/// Sidebar section listing every activity entry, newest first.
struct RelayActivitySection: View {
    @ObservedObject var workspace: WorkspaceModel
    @ObservedObject var log: RelayActivityLog = .shared
    @State private var collapsed = false
    @State private var showingAll = false
    private let identifier = "relay.sidebar.activity"
    private static let pageSize = 8

    var body: some View {
        if !log.entries.isEmpty {
            let rows = showingAll ? log.entries : Array(log.entries.prefix(Self.pageSize))
            VStack(alignment: .leading, spacing: RelayTheme.spacing(2)) {
                HStack(spacing: RelayTheme.spacing(7)) {
                    Button { collapsed.toggle() } label: {
                        HStack(spacing: RelayTheme.spacing(7)) {
                            Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                                .font(RelayTheme.font(size: 8, weight: .semibold))
                                .frame(width: 10)
                            Text("Activity")
                                .font(RelayTheme.font(size: 11, weight: .medium))
                                .lineLimit(1)
                            let unread = log.unreadCount
                            if unread > 0 {
                                Text("\(unread)")
                                    .font(RelayTheme.font(size: 10, weight: .semibold))
                                    .foregroundStyle(RelayTheme.text)
                                    .padding(.horizontal, RelayTheme.spacing(6))
                                    .frame(minWidth: 18, minHeight: 16)
                                    .background(RelayTheme.accent.opacity(0.28), in: Capsule())
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(collapsed ? "Show agent activity" : "Hide agent activity")
                    .accessibilityIdentifier("\(identifier).toggle")
                    Button("Mark read") { log.markAllRead() }
                        .buttonStyle(RelayQuietButtonStyle())
                        .disabled(log.unreadCount == 0)
                        .accessibilityIdentifier("\(identifier).read")
                    Button("Clear") { log.clear() }
                        .buttonStyle(RelayQuietButtonStyle())
                        .accessibilityIdentifier("\(identifier).clear")
                }
                .foregroundStyle(RelayTheme.textMuted)
                .padding(.horizontal, RelayTheme.spacing(6))
                .frame(height: 26)
                if !collapsed {
                    ForEach(rows) { entry in
                        RelayActivityRow(entry: entry, workspace: workspace, log: log)
                    }
                    if log.entries.count > Self.pageSize {
                        Button(showingAll ? "Show fewer" : "Show \(log.entries.count - Self.pageSize) more") { showingAll.toggle() }
                            .buttonStyle(RelayQuietButtonStyle())
                            .accessibilityIdentifier("\(identifier).more")
                    }
                }
            }
            .padding(.bottom, RelayTheme.spacing(6))
            .accessibilityIdentifier(identifier)
        }
    }
}

private struct RelayActivityRow: View {
    let entry: RelayActivityEntry
    @ObservedObject var workspace: WorkspaceModel
    let log: RelayActivityLog

    var body: some View {
        let target = RelayActivityTarget.resolve(entry, paneExists: { workspace.panes[$0] != nil },
                                                 tabExists: { id in workspace.tabs.contains { $0.id == id } })
        let closed = target == .gone
        Button { log.open(entry, in: workspace) } label: {
            HStack(alignment: .firstTextBaseline, spacing: RelayTheme.spacing(7)) {
                Circle()
                    .fill(entry.isRead ? Color.clear : RelayTheme.blue)
                    .frame(width: 6, height: 6)
                VStack(alignment: .leading, spacing: RelayTheme.spacing(2)) {
                    Text(entry.summary)
                        .font(RelayTheme.font(size: 11.5, weight: entry.isRead ? .regular : .medium))
                        .foregroundStyle(RelayTheme.text)
                        .lineLimit(1)
                    Text(subtitle(closed: closed))
                        .font(RelayTheme.font(size: 10.5))
                        .foregroundStyle(RelayTheme.textMuted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, RelayTheme.spacing(8))
            .padding(.vertical, RelayTheme.spacing(5))
            .background(RelayTheme.surface.opacity(0.72), in: RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(7)))
            .opacity(closed ? 0.5 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(closed)
        .help("\(entry.summary) · \(subtitle(closed: closed))")
    }

    private func subtitle(closed: Bool) -> String {
        var parts = [entry.caller, entry.at.formatted(date: .omitted, time: .shortened)]
        if closed { parts.append("Closed") }
        return parts.joined(separator: " · ")
    }
}

/// The newest activity entry as a small, auto-dismissing card. It never
/// takes focus; clicking it shows the pane.
struct RelayActivityToast: View {
    @ObservedObject var workspace: WorkspaceModel
    @ObservedObject var log: RelayActivityLog = .shared

    var body: some View {
        if let entry = log.toast {
            HStack(spacing: RelayTheme.spacing(10)) {
                Button { log.open(entry, in: workspace) } label: {
                    HStack(spacing: RelayTheme.spacing(10)) {
                        Image(systemName: "arrow.up.forward.square")
                            .font(RelayTheme.font(size: 11, weight: .medium))
                            .foregroundStyle(RelayTheme.accent)
                        VStack(alignment: .leading, spacing: RelayTheme.spacing(1)) {
                            Text(entry.summary)
                                .font(RelayTheme.font(size: 11.5, weight: .medium))
                                .lineLimit(1)
                            Text("\(entry.caller) · Click to go there")
                                .font(RelayTheme.font(size: 11))
                                .foregroundStyle(RelayTheme.textMuted)
                                .lineLimit(1)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Shows the pane this agent action touched")
                Button { log.dismissToast() } label: {
                    Image(systemName: "xmark")
                        .font(RelayTheme.font(size: 9, weight: .semibold))
                        .foregroundStyle(RelayTheme.textFaint)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
            .foregroundStyle(RelayTheme.text)
            .padding(.horizontal, RelayTheme.spacing(14))
            .frame(maxWidth: 420, minHeight: 44)
            .background(RelayTheme.elevated, in: RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(8), style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(8), style: .continuous)
                    .stroke(RelayTheme.line.opacity(0.9))
            }
            .shadow(color: .black.opacity(0.28), radius: 14, y: 6)
            .padding(.top, RelayTheme.spacing(12))
            .padding(.trailing, RelayTheme.spacing(16))
            .transition(.opacity)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("relay.activity.toast")
        }
    }
}
