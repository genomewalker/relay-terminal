import Foundation

/// Local presentation: how tabs are organized into project, task and session
/// groups, saved views, and navigation history. Nothing here touches panes,
/// runtimes, `TabModel.sessionID` or a pane's remote birth hierarchy.

enum WorkspaceGroupKind: String, Codable, CaseIterable, Sendable {
    case session, project, task
}

enum WorkspaceSortOrder: String, CaseIterable, Sendable {
    case name, host
}

struct WorkspaceGroup: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var parentID: UUID?
    var order: Double
    var name: String
    var kind: WorkspaceGroupKind
    var collapsed: Bool
}

/// Where a tab is shown. `groupID == nil` means explicitly ungrouped.
struct WorkspaceTabPlacement: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var groupID: UUID?
    var order: Double
}

enum WorkspaceNavigationTarget: Codable, Hashable, Sendable {
    case all
    case group(UUID)
    case tab(UUID)
    case pane(UUID)
}

struct WorkspaceSavedView: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var target: WorkspaceNavigationTarget
    /// Stack ID (lowercased UUID string, so it merges deterministically) to shown member.
    var stackSelections: [String: UUID]
    var collapsedGroupIDs: [UUID]
    var zoomedPaneID: UUID?
}

struct WorkspaceOrganizationSnapshot: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 2

    var schemaVersion: Int
    var groups: [WorkspaceGroup]
    var placements: [WorkspaceTabPlacement]
    var savedViews: [WorkspaceSavedView]

    static let empty = WorkspaceOrganizationSnapshot(schemaVersion: currentSchemaVersion, groups: [], placements: [], savedViews: [])
}

indirect enum WorkspaceOutlineNode: Identifiable, Equatable {
    case group(WorkspaceGroup, children: [WorkspaceOutlineNode])
    case ungrouped(children: [WorkspaceOutlineNode])
    case tab(UUID)

    var id: String {
        switch self {
        case .group(let group, _): "group:" + group.id.uuidString
        case .ungrouped: "ungrouped"
        case .tab(let id): "tab:" + id.uuidString
        }
    }

    var children: [WorkspaceOutlineNode] {
        switch self {
        case .group(_, let children), .ungrouped(let children): children
        case .tab: []
        }
    }
}

enum WorkspaceOrganizationError: Error, LocalizedError, Equatable {
    case unknownGroup, cycle

    var errorDescription: String? {
        switch self {
        case .unknownGroup: "That group no longer exists."
        case .cycle: "A group cannot be moved inside itself."
        }
    }
}

@MainActor
final class WorkspaceOrganizationController: ObservableObject {
    static let historyLimit = 50

    @Published private(set) var groups: [WorkspaceGroup] = []
    @Published private(set) var placements: [WorkspaceTabPlacement] = []
    @Published private(set) var savedViews: [WorkspaceSavedView] = []
    @Published private(set) var current: WorkspaceNavigationTarget = .all
    @Published private(set) var backStack: [WorkspaceNavigationTarget] = []
    @Published private(set) var forwardStack: [WorkspaceNavigationTarget] = []

    weak var workspace: WorkspaceModel?
    /// Called after an edit that must be persisted.
    var onChange: (() -> Void)?
    private var applying = false

    init(workspace: WorkspaceModel? = nil) { self.workspace = workspace }

    var canGoBack: Bool { backStack.contains(where: isLive) }
    var canGoForward: Bool { forwardStack.contains(where: isLive) }

    // MARK: Snapshot

    var snapshot: WorkspaceOrganizationSnapshot {
        WorkspaceOrganizationSnapshot(schemaVersion: WorkspaceOrganizationSnapshot.currentSchemaVersion,
                                      groups: groups, placements: placements, savedViews: savedViews)
    }

    func load(_ snapshot: WorkspaceOrganizationSnapshot) {
        groups = snapshot.groups
        placements = snapshot.placements
        savedViews = snapshot.savedViews
        if !isLive(current) { current = .all }
    }

    /// One session group per existing session, with `group.id == sessionID`,
    /// in navigator order. Deterministic, so concurrent migrations merge.
    nonisolated static func migrated(sessionIDs: [UUID], name: (UUID) -> String) -> WorkspaceOrganizationSnapshot {
        WorkspaceOrganizationSnapshot(schemaVersion: WorkspaceOrganizationSnapshot.currentSchemaVersion,
            groups: sessionIDs.enumerated().map { index, id in
                WorkspaceGroup(id: id, parentID: nil, order: Double(index), name: name(id), kind: .session, collapsed: false)
            }, placements: [], savedViews: [])
    }

    // MARK: Outline

    private var tabIDs: [UUID] { workspace?.tabs.map(\.id) ?? [] }

    private func tab(_ id: UUID) -> TabModel? { workspace?.tabs.first { $0.id == id } }

    /// Groups whose parent chain reaches the root without a cycle or a
    /// missing parent; others are shown at the root.
    private func effectiveParent(_ group: WorkspaceGroup) -> UUID? {
        var seen: Set<UUID> = [group.id]
        var parent = group.parentID
        while let id = parent {
            guard !seen.contains(id), let next = groups.first(where: { $0.id == id }) else { return nil }
            seen.insert(id)
            parent = next.parentID
        }
        return group.parentID
    }

    /// The group a tab is shown in; nil means Ungrouped.
    private func groupID(forTab tab: TabModel) -> UUID? {
        if let placement = placements.first(where: { $0.id == tab.id }) {
            return placement.groupID.flatMap { id in groups.contains(where: { $0.id == id }) ? id : nil }
        }
        // Unplaced tabs show in their session's group, explicit or implicit.
        return tab.sessionID
    }

    private func hasExplicitSessionGroup(_ sessionID: UUID) -> Bool { groups.contains { $0.id == sessionID } }

    /// Sessions whose tabs have no explicit group yet appear as implicit
    /// session groups. They become records only when edited.
    private var implicitSessionGroups: [WorkspaceGroup] {
        guard let workspace else { return [] }
        var result: [WorkspaceGroup] = []
        for (index, sessionID) in workspace.navigationSessionIDs.enumerated() where !hasExplicitSessionGroup(sessionID) {
            let placedElsewhere = workspace.tabs.filter { $0.sessionID == sessionID }
                .allSatisfy { tab in placements.contains(where: { $0.id == tab.id }) }
            if placedElsewhere { continue }
            result.append(WorkspaceGroup(id: sessionID, parentID: nil, order: 1_000_000 + Double(index),
                name: workspace.navigationSessionName(sessionID), kind: .session, collapsed: false))
        }
        return result
    }

    private var allGroups: [WorkspaceGroup] { groups + implicitSessionGroups }

    func group(id: UUID) -> WorkspaceGroup? { allGroups.first { $0.id == id } }

    func group(containingTab tabID: UUID) -> WorkspaceGroup? {
        guard let tab = tab(tabID), let id = groupID(forTab: tab) else { return nil }
        return group(id: id)
    }

    private func orderedTabs(inGroup groupID: UUID?) -> [UUID] {
        guard let workspace else { return [] }
        let members = workspace.tabs.filter { self.groupID(forTab: $0) == groupID }
        let navigation = Dictionary(uniqueKeysWithValues: workspace.navigationSessionIDs.flatMap { session in
            workspace.orderedTabs(in: session).map(\.id)
        }.enumerated().map { ($1, Double($0)) })
        func key(_ tab: TabModel) -> Double {
            placements.first(where: { $0.id == tab.id })?.order ?? (1_000_000 + (navigation[tab.id] ?? 0))
        }
        return members.sorted { key($0) < key($1) }.map(\.id)
    }

    func children(of groupID: UUID?) -> [WorkspaceOutlineNode] {
        let all = allGroups
        let subgroups = all.filter { group in
            let parent = group.parentID == nil ? nil : effectiveParent(group)
            return parent == groupID && group.id != groupID
        }.sorted { $0.order < $1.order }
        var nodes = subgroups.map { WorkspaceOutlineNode.group($0, children: children(of: $0.id)) }
        if let groupID {
            nodes += orderedTabs(inGroup: groupID).map(WorkspaceOutlineNode.tab)
        }
        return nodes
    }

    func outline() -> [WorkspaceOutlineNode] {
        var nodes = children(of: nil)
        let ungrouped = orderedTabs(inGroup: nil)
        if !ungrouped.isEmpty { nodes.append(.ungrouped(children: ungrouped.map(WorkspaceOutlineNode.tab))) }
        return nodes
    }

    private func descendantTabIDs(_ groupID: UUID) -> [UUID] {
        children(of: groupID).flatMap { node -> [UUID] in
            switch node {
            case .tab(let id): [id]
            case .group(let group, _): descendantTabIDs(group.id)
            case .ungrouped(let children): children.compactMap { if case .tab(let id) = $0 { id } else { nil } }
            }
        }
    }

    func paneIDs(in target: WorkspaceNavigationTarget) -> [UUID] {
        switch target {
        case .all: return workspace?.tabs.flatMap(\.allPaneIDs) ?? []
        case .group(let id): return descendantTabIDs(id).flatMap { tab($0)?.allPaneIDs ?? [] }
        case .tab(let id): return tab(id)?.allPaneIDs ?? []
        case .pane(let id): return isLive(.pane(id)) ? [id] : []
        }
    }

    func parent(of target: WorkspaceNavigationTarget) -> WorkspaceNavigationTarget {
        switch target {
        case .all: return .all
        case .group(let id):
            guard let group = group(id: id), let parent = effectiveParent(group) else { return .all }
            return .group(parent)
        case .tab(let id):
            return group(containingTab: id).map { .group($0.id) } ?? .all
        case .pane(let id):
            return workspace?.tabID(containingPane: id).map { .tab($0) } ?? .all
        }
    }

    func breadcrumb(for target: WorkspaceNavigationTarget) -> [WorkspaceNavigationTarget] {
        var trail = [target]
        var node = target
        while node != .all, trail.count < 64 {
            node = parent(of: node)
            trail.insert(node, at: 0)
        }
        return trail
    }

    func title(for target: WorkspaceNavigationTarget) -> String {
        switch target {
        case .all: return "All workspaces"
        case .group(let id): return group(id: id)?.name ?? "Group"
        case .tab(let id):
            guard let workspace, let tab = tab(id) else { return "Tab" }
            return workspace.tabDisplayName(tab, fallback: tab.name)
        case .pane(let id):
            guard let pane = workspace?.panes[id] else { return "Pane" }
            return pane.customName ?? pane.profile.name
        }
    }

    func accessibilityLabel(for target: WorkspaceNavigationTarget) -> String {
        let count = paneIDs(in: target).count
        let panes = count == 1 ? "1 pane" : "\(count) panes"
        switch target {
        case .all:
            return "All workspaces, \(panes)"
        case .group(let id):
            guard let group = group(id: id) else { return title(for: target) }
            return "\(group.name), \(group.kind.rawValue) group, \(panes)\(group.collapsed ? ", collapsed" : "")"
        case .tab(let id):
            let stacks = tab(id)?.stacks.count ?? 0
            return "\(title(for: target)), tab, \(panes)" + (stacks > 0 ? ", \(stacks) stacked" : "")
        case .pane(let id):
            guard let pane = workspace?.panes[id] else { return title(for: target) }
            let location = pane.profile.kind == .ssh ? "remote \(pane.profile.host)" : "local"
            var label = "\(title(for: target)), \(location)"
            if let tab = workspace?.tabs.first(where: { $0.allPaneIDs.contains(id) }), let stack = tab.stack(containing: id),
               let index = stack.members.firstIndex(of: id) {
                label += ", \(index + 1) of \(stack.members.count) in stack"
            }
            return label
        }
    }

    // MARK: Navigation

    func isLive(_ target: WorkspaceNavigationTarget) -> Bool {
        switch target {
        case .all: return true
        case .group(let id): return group(id: id) != nil
        case .tab(let id): return tab(id) != nil
        case .pane(let id): return workspace?.tabID(containingPane: id) != nil
        }
    }

    private func sameTab(_ a: WorkspaceNavigationTarget, _ b: WorkspaceNavigationTarget) -> Bool {
        func tabID(_ target: WorkspaceNavigationTarget) -> UUID? {
            switch target {
            case .tab(let id): id
            case .pane(let id): workspace?.tabID(containingPane: id)
            default: nil
            }
        }
        guard let left = tabID(a) else { return false }
        return left == tabID(b)
    }

    private func record(_ target: WorkspaceNavigationTarget) {
        guard target != current else { return }
        // Moving focus within one tab replaces the entry instead of filling history.
        if !sameTab(current, target) {
            backStack.append(current)
            if backStack.count > Self.historyLimit { backStack.removeFirst(backStack.count - Self.historyLimit) }
            forwardStack.removeAll()
        }
        current = target
    }

    private func apply(_ target: WorkspaceNavigationTarget) {
        guard let workspace else { return }
        applying = true
        defer { applying = false }
        switch target {
        case .tab(let id): workspace.selectTab(id)
        case .pane(let id): workspace.revealPane(id)
        case .all, .group: break
        }
    }

    func navigate(to target: WorkspaceNavigationTarget) {
        guard isLive(target) else { return }
        record(target)
        apply(target)
    }

    /// Called by `WorkspaceModel` on every explicit tab or pane selection,
    /// including the already-selected ID, so selection always leaves the overview.
    func noteSelection(_ target: WorkspaceNavigationTarget) {
        guard !applying else { return }
        record(target)
    }

    func goBack() {
        while let target = backStack.popLast() {
            guard isLive(target) else { continue }
            forwardStack.append(current)
            current = target
            apply(target)
            return
        }
    }

    func goForward() {
        while let target = forwardStack.popLast() {
            guard isLive(target) else { continue }
            backStack.append(current)
            current = target
            apply(target)
            return
        }
    }

    func goUp() { navigate(to: parent(of: current)) }

    /// Drops navigation entries that no longer exist, after closes.
    func pruneNavigation() {
        backStack.removeAll { !isLive($0) }
        forwardStack.removeAll { !isLive($0) }
        if !isLive(current) { current = .all }
    }

    // MARK: Editing

    private func changed() { onChange?() }

    /// Turns an implicit session group into a record before it is edited.
    private func materialize(_ id: UUID) -> Int? {
        if let index = groups.firstIndex(where: { $0.id == id }) { return index }
        guard let implicit = implicitSessionGroups.first(where: { $0.id == id }) else { return nil }
        groups.append(implicit)
        return groups.count - 1
    }

    private func nextOrder(parent: UUID?) -> Double {
        (groups.filter { $0.parentID == parent }.map(\.order).max() ?? -1) + 1
    }

    @discardableResult
    func createGroup(name: String, kind: WorkspaceGroupKind, parentID: UUID?) -> UUID {
        let id = UUID()
        let parent = parentID.flatMap { materialize($0) != nil ? $0 : nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        groups.append(WorkspaceGroup(id: id, parentID: parent, order: nextOrder(parent: parent),
            name: trimmed.isEmpty ? "New group" : String(trimmed.prefix(120)), kind: kind, collapsed: false))
        changed()
        return id
    }

    func renameGroup(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = materialize(id) else { return }
        groups[index].name = String(trimmed.prefix(120))
        changed()
    }

    func setCollapsed(_ id: UUID, _ collapsed: Bool) {
        guard let index = materialize(id), groups[index].collapsed != collapsed else { return }
        groups[index].collapsed = collapsed
        changed()
    }

    func moveGroup(_ id: UUID, toParent parentID: UUID?, at index: Int) throws {
        guard materialize(id) != nil else { throw WorkspaceOrganizationError.unknownGroup }
        if let parentID {
            guard materialize(parentID) != nil else { throw WorkspaceOrganizationError.unknownGroup }
            var node: UUID? = parentID
            var seen: Set<UUID> = []
            while let current = node, seen.insert(current).inserted {
                if current == id { throw WorkspaceOrganizationError.cycle }
                node = groups.first(where: { $0.id == current })?.parentID
            }
        }
        var siblings = groups.filter { $0.parentID == parentID && $0.id != id }.sorted { $0.order < $1.order }.map(\.id)
        siblings.insert(id, at: max(0, min(index, siblings.count)))
        for (order, sibling) in siblings.enumerated() {
            if let position = groups.firstIndex(where: { $0.id == sibling }) {
                groups[position].order = Double(order)
                if sibling == id { groups[position].parentID = parentID }
            }
        }
        changed()
    }

    /// Ungroups: subgroups and tabs move to the deleted group's parent.
    func deleteGroup(_ id: UUID) {
        guard let index = materialize(id) else { return }
        let parent = groups[index].parentID
        let tabs = orderedTabs(inGroup: id)
        for position in groups.indices where groups[position].parentID == id {
            groups[position].parentID = parent
        }
        groups.remove(at: index)
        let base = (placements.filter { $0.groupID == parent }.map(\.order).max() ?? -1) + 1
        for (offset, tabID) in tabs.enumerated() {
            setPlacement(tabID, group: parent, order: base + Double(offset))
        }
        if current == .group(id) { current = parent.map { .group($0) } ?? .all }
        backStack.removeAll { $0 == .group(id) }
        forwardStack.removeAll { $0 == .group(id) }
        changed()
    }

    private func setPlacement(_ tabID: UUID, group: UUID?, order: Double) {
        if let index = placements.firstIndex(where: { $0.id == tabID }) {
            placements[index].groupID = group
            placements[index].order = order
        } else {
            placements.append(WorkspaceTabPlacement(id: tabID, groupID: group, order: order))
        }
    }

    /// Shows a tab in a group (nil = Ungrouped). Changes presentation only.
    func placeTab(_ tabID: UUID, inGroup groupID: UUID?, at index: Int) {
        guard tab(tabID) != nil else { return }
        if let groupID, materialize(groupID) == nil { return }
        var ordered = orderedTabs(inGroup: groupID).filter { $0 != tabID }
        ordered.insert(tabID, at: max(0, min(index, ordered.count)))
        for (order, id) in ordered.enumerated() { setPlacement(id, group: groupID, order: Double(order)) }
        changed()
    }

    /// A pane dropped on a project becomes a presentation tab in that project.
    /// It keeps its canonical session and the same pane and runtime objects.
    func movePane(_ paneID: UUID, toGroup groupID: UUID?) throws {
        if let groupID, group(id: groupID) == nil { throw WorkspaceOrganizationError.unknownGroup }
        guard let workspace else { throw WorkspaceLayoutError.unknownPane }
        let tabID = try workspace.movePaneToNewTab(paneID)
        placeTab(tabID, inGroup: groupID, at: orderedTabs(inGroup: groupID).count)
    }

    /// Sorts presentation records once, so later manual drags remain authoritative.
    func sortChildren(of groupID: UUID?, by order: WorkspaceSortOrder, recursive: Bool = false) {
        if let groupID, group(id: groupID) == nil { return }
        func ordered(_ left: String, _ right: String) -> ComparisonResult {
            left.compare(right, options: [.numeric, .caseInsensitive, .diacriticInsensitive], locale: .current)
        }
        func host(_ id: UUID) -> String {
            let names = tab(id)?.allPaneIDs.compactMap { workspace?.panes[$0] }.map {
                $0.profile.kind == .local ? "This Mac" : $0.profile.host
            } ?? []
            return Set(names).sorted().joined(separator: ", ")
        }
        func apply(_ parentID: UUID?) {
            let childGroups = children(of: parentID).compactMap { node -> WorkspaceGroup? in
                if case .group(let value, _) = node { return value }; return nil
            }.sorted {
                let result = ordered($0.name, $1.name)
                return result == .orderedSame ? $0.id.uuidString < $1.id.uuidString : result == .orderedAscending
            }
            for (index, child) in childGroups.enumerated() {
                if let position = materialize(child.id) { groups[position].order = Double(index) }
            }
            let tabs = orderedTabs(inGroup: parentID).sorted { left, right in
                if order == .host {
                    let result = ordered(host(left), host(right))
                    if result != .orderedSame { return result == .orderedAscending }
                }
                let result = ordered(title(for: .tab(left)), title(for: .tab(right)))
                return result == .orderedSame ? left.uuidString < right.uuidString : result == .orderedAscending
            }
            for (index, id) in tabs.enumerated() { setPlacement(id, group: parentID, order: Double(index)) }
            if recursive { childGroups.forEach { apply($0.id) } }
        }
        apply(groupID)
        changed()
    }

    /// Forgets placements of tabs that no longer exist.
    func pruneClosedTabs() {
        let live = Set(tabIDs)
        let kept = placements.filter { live.contains($0.id) }
        if kept != placements {
            placements = kept
            changed()
        }
        pruneNavigation()
    }

    // MARK: Saved views (presentation only)

    @discardableResult
    func saveView(name: String) -> UUID {
        let id = UUID()
        var selections: [String: UUID] = [:]
        for tab in workspace?.tabs ?? [] {
            for stack in tab.stacks { selections[stack.id.uuidString.lowercased()] = stack.selected }
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        savedViews.append(WorkspaceSavedView(id: id, name: trimmed.isEmpty ? title(for: current) : String(trimmed.prefix(120)),
            target: current, stackSelections: selections, collapsedGroupIDs: groups.filter(\.collapsed).map(\.id),
            zoomedPaneID: workspace?.zoomedPaneID))
        changed()
        return id
    }

    func applyView(_ id: UUID) {
        guard let view = savedViews.first(where: { $0.id == id }), let workspace else { return }
        let collapsed = Set(view.collapsedGroupIDs)
        for index in groups.indices { groups[index].collapsed = collapsed.contains(groups[index].id) }
        for (key, paneID) in view.stackSelections {
            guard let stackID = UUID(uuidString: key) else { continue }
            if workspace.tabs.contains(where: { $0.stack(id: stackID)?.members.contains(paneID) == true }) {
                workspace.selectStackMember(paneID)
            }
        }
        navigate(to: isLive(view.target) ? view.target : .all)
        if let zoomed = view.zoomedPaneID, workspace.selectedTab?.layout.paneIDs.contains(zoomed) == true {
            workspace.zoomedPaneID = zoomed
        }
        changed()
    }

    func renameView(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = savedViews.firstIndex(where: { $0.id == id }) else { return }
        savedViews[index].name = String(trimmed.prefix(120))
        changed()
    }

    func deleteView(_ id: UUID) {
        savedViews.removeAll { $0.id == id }
        changed()
    }
}
