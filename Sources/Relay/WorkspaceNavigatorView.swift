import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// What the navigator is dragging, recorded when the drag starts so drop
/// targets can show the move's refusal reason while hovering.
@MainActor final class WorkspaceNavigatorDragState: ObservableObject {
    static let shared = WorkspaceNavigatorDragState()
    enum Item: Equatable { case tab(UUID), workspace(UUID) }
    @Published var item: Item?
    /// A cancelled drag never clears `item`; the button being up ends it.
    var isDragging: Bool { item != nil && NSEvent.pressedMouseButtons & 1 != 0 }
}

/// One flat list of workspaces (search, pinned, hidden) with their tabs
/// and panes. Every drop is an object-preserving move of the ownership API.
@MainActor struct WorkspaceNavigator: View {
    nonisolated static let searchPlaceholder = "Search workspaces, tabs and panes"
    @ObservedObject var workspace: WorkspaceModel
    // Attention order follows pane phases (throttled), alerts and drags.
    @ObservedObject private var activityIndex: WorkspaceActivityIndex
    @ObservedObject private var inbox = AgentIntelligenceStore.shared
    @ObservedObject private var drag = WorkspaceNavigatorDragState.shared
    @ObservedObject private var hold: WorkspaceNavigatorHold
    @State private var query = ""
    @State private var failure: String?
    @State private var showingHidden = false
    @State private var renaming: WorkspaceRecord?
    @State private var pointerInside = false

    init(workspace: WorkspaceModel) {
        self.workspace = workspace
        activityIndex = workspace.activityIndex
        hold = workspace.navigatorHoldState
    }

    var body: some View {
        let _ = activityIndex.revision
        let sort = workspace.navigatorSort
        let lists = workspace.navigatorWorkspaces(matching: query, sort: sort)
        // Each workspace's tabs as drawn, also what a hold keeps.
        let rails = Dictionary(uniqueKeysWithValues: (lists.shown + lists.hidden).map {
            ($0.id, workspace.railTabs(inWorkspace: $0.id, sort: sort))
        })
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                // The clear button sits beside the text, not over it.
                HStack(spacing: 2) {
                    TextField(Self.searchPlaceholder, text: $query)
                        .textFieldStyle(.plain)
                        .font(RelayTheme.font(size: 11))
                        .accessibilityIdentifier("relay.navigator.search")
                    if !query.isEmpty {
                        Button { query = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(RelayTheme.textFaint)
                                .frame(width: 18, height: 18)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Clear search")
                        .accessibilityLabel("Clear search")
                        .accessibilityIdentifier("relay.navigator.search-clear")
                    }
                }
                .padding(.leading, 6)
                .padding(.trailing, 2)
                .frame(height: 22)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(RelayTheme.line))
                Menu {
                    Picker("Sort", selection: Binding(
                        get: { workspace.navigationState.navigatorSortMode },
                        set: { workspace.setNavigatorSortMode($0) }
                    )) {
                        Text("Attention, then recent").tag(WorkspaceNavigationState.NavigatorSort.attention)
                        Text("Manual").tag(WorkspaceNavigationState.NavigatorSort.manual)
                    }
                    .pickerStyle(.inline)
                } label: {
                    Image(systemName: "arrow.up.arrow.down").frame(width: 22, height: 22)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Sort workspaces")
                .accessibilityIdentifier("relay.navigator.sort")
                Button {
                    let id = workspace.createWorkspace(named: "New workspace")
                    renaming = workspace.ownership.workspace(id)
                } label: { Image(systemName: "plus").frame(width: 22, height: 22) }
                .buttonStyle(.plain)
                .help("New workspace")
                .accessibilityIdentifier("relay.navigator.new-workspace")
            }
            .padding(.horizontal, 10)
            // Same metadata and predicate as the fleet board and Go to pane.
            let fleet = RelayWorkOverviewIndex.PaneCounts(RelayWorkOverviewIndex.paneFacts(workspace))
            RelayFleetCountsButton(counts: fleet) {
                workspace.presentFleetBoard(filter: .initial(for: fleet))
            }
            .padding(.horizontal, 6)
            if workspace.isFocusing {
                WorkspaceFocusBar(workspace: workspace, inbox: .shared)
            }
            if let failure {
                Button { self.failure = nil } label: {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .font(RelayTheme.font(size: 10.5, weight: .medium))
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .accessibilityIdentifier("relay.navigator.failure")
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if query.isEmpty {
                        AttentionInboxSection(workspace: workspace, identifier: "relay.navigator.attention-inbox")
                            .padding(.horizontal, 8)
                    }
                    let pinned = lists.shown.filter { $0.favourite && !$0.isInbox }
                    if !pinned.isEmpty {
                        NavigatorSectionHeader(title: "Pinned")
                        ForEach(pinned) { record in
                            WorkspaceNavigatorRow(record: record, workspace: workspace, hold: hold, query: query,
                                                  tabs: rails[record.id] ?? [],
                                                  failure: $failure, renaming: $renaming)
                        }
                        NavigatorSectionHeader(title: "Workspaces")
                    }
                    ForEach(lists.shown.filter { !$0.favourite || $0.isInbox }) { record in
                        WorkspaceNavigatorRow(record: record, workspace: workspace, hold: hold, query: query,
                                              tabs: rails[record.id] ?? [],
                                              failure: $failure, renaming: $renaming)
                    }
                    if !lists.hidden.isEmpty {
                        Button { showingHidden.toggle() } label: {
                            Label("Hidden (\(lists.hidden.count))", systemImage: showingHidden ? "chevron.down" : "chevron.right")
                                .font(RelayTheme.font(size: 10.5, weight: .medium))
                                .foregroundStyle(RelayTheme.textMuted)
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                        if showingHidden {
                            ForEach(lists.hidden) { record in
                                WorkspaceNavigatorRow(record: record, workspace: workspace, hold: hold, query: query,
                                                      tabs: rails[record.id] ?? [],
                                                      failure: $failure, renaming: $renaming)
                            }
                        }
                    }
                }
                .padding(.bottom, 8)
            }
            Button { workspace.presentWorkspaceMigration() } label: {
                Label(workspace.migrationPlan?.staged == true ? "Migration plan ready — review"
                      : workspace.migrationPreview == nil ? "Migration…" : "Migration preview open",
                      systemImage: "arrow.triangle.branch")
                    .font(RelayTheme.font(size: 11, weight: workspace.migrationPlan?.staged == true ? .semibold : .regular))
                    .foregroundStyle(workspace.migrationPlan?.staged == true ? RelayTheme.accent : Color.primary)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("relay.navigator.migration")
        }
        // Rows stay put while the pointer is anywhere on the navigator (the
        // search field and Sort included) or a drag runs. The hold keeps the
        // rows as this body drew them; SwiftUI takes this closure afresh
        // with each body, so `lists` and `rails` are the latest drawn.
        .contentShape(Rectangle())
        .onHover { inside in
            pointerInside = inside
            if inside { workspace.holdNavigatorOrder(drawn: lists.shown + lists.hidden, drawnTabs: rails) }
            workspace.settleNavigatorHold(pointerInside: inside, dragging: drag.isDragging)
        }
        .onChange(of: drag.item) { _, _ in
            workspace.settleNavigatorHold(pointerInside: pointerInside, dragging: drag.isDragging)
        }
        // After the pointer leaves (or a drag is cancelled outside, which
        // sends no event here), the hold ends once the grace period passes.
        .task(id: hold.ranks != nil && !pointerInside) {
            while workspace.navigatorHold != nil, !pointerInside, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                workspace.settleNavigatorHold(pointerInside: pointerInside, dragging: drag.isDragging)
            }
        }
        // Hidden with the pointer on it (the navigator shortcut, full screen):
        // no exit arrives, so nothing would end the hold.
        .onDisappear {
            pointerInside = false
            workspace.releaseNavigatorOrder()
        }
        .sheet(item: $renaming) { record in
            WorkspaceRenameSheet(name: record.name) { workspace.renameWorkspace(record.id, to: $0) }
        }
    }
}

/// Shown while focusing: what is in focus, how many panes outside it wait
/// or failed, and the way out.
private struct WorkspaceFocusBar: View {
    @ObservedObject var workspace: WorkspaceModel
    @ObservedObject var inbox: AgentIntelligenceStore

    var body: some View {
        let focused = workspace.focusedWorkspaceIDs()
        let held = workspace.attentionOutsideFocus(inbox: inbox)
        HStack(spacing: 6) {
            Label(focused.count == 1
                  ? "Focus · " + (focused.first.flatMap { workspace.ownership.workspace($0)?.name } ?? "1 workspace")
                  : "Focus · \(focused.count) workspaces", systemImage: "scope")
                .font(RelayTheme.font(size: 10.5, weight: .semibold))
                .foregroundStyle(RelayTheme.accent)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if held > 0 {
                Text("\(held) waiting outside")
                    .font(RelayTheme.font(size: 10.5, weight: .medium))
                    .foregroundStyle(RelayTheme.coral)
                    .lineLimit(1)
                    .accessibilityIdentifier("relay.navigator.focus-held")
            }
            let others = workspace.workspacesOutsideFocus()
            if !others.isEmpty {
                Menu {
                    ForEach(others) { record in
                        Button(record.name) { workspace.addToFocus(record.id) }
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Add a workspace to focus")
                .accessibilityIdentifier("relay.navigator.focus-add")
            }
            Button("End focus") { workspace.endFocus() }
                .buttonStyle(.plain)
                .font(RelayTheme.font(size: 10.5, weight: .medium))
                .foregroundStyle(RelayTheme.textMuted)
                .accessibilityIdentifier("relay.navigator.end-focus")
        }
        .padding(.horizontal, 12)
        .help("Other workspaces are hidden and raise no alerts until focus ends or Relay quits.")
        .accessibilityIdentifier("relay.navigator.focus")
    }
}

/// A workspace row's pin control: shown when pinned or under the pointer,
/// and always hit-testable, so a hidden one ignores its click.
@MainActor enum WorkspaceNavigatorPin {
    static func shown(favourite: Bool, hovering: Bool) -> Bool { favourite || hovering }

    static func accessibilityLabel(_ record: WorkspaceRecord) -> String {
        (record.favourite ? "Unpin " : "Pin ") + record.name
    }

    static func toggle(_ record: WorkspaceRecord, shown: Bool, in workspace: WorkspaceModel) {
        guard shown, !record.isInbox else { return }
        workspace.setWorkspaceFavourite(record.id, !record.favourite)
    }
}

@MainActor private struct WorkspaceNavigatorRow: View {
    let record: WorkspaceRecord
    @ObservedObject var workspace: WorkspaceModel
    @ObservedObject var hold: WorkspaceNavigatorHold
    let query: String
    /// In navigator order; the parent sorts them, so a re-sort redraws the row.
    let tabs: [TabModel]
    @Binding var failure: String?
    @Binding var renaming: WorkspaceRecord?
    @State private var targeted = false
    @State private var refusal: String?
    @State private var hovering = false

    /// Kept by ID in the model, so pinning or hiding the workspace (which
    /// moves the row to another list) does not re-expand it; `hold` redraws
    /// the row when it changes.
    private var expanded: Bool { workspace.isNavigatorWorkspaceExpanded(record.id) }

    var body: some View {
        let tabs = workspace.navigatorTabs(self.tabs, of: record, matching: query)
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Button { workspace.setNavigatorWorkspaceExpanded(record.id, !expanded) } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 8)).frame(width: 14, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(expanded ? "Collapse" : "Expand") \(record.name)")
                Button { workspace.selectWorkspace(record.id, origin: .user) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: record.isInbox ? "tray" : "square.stack")
                            .font(.system(size: 10)).foregroundStyle(RelayTheme.textMuted)
                        Text(record.name).font(RelayTheme.font(size: 11.5, weight: .semibold)).lineLimit(1)
                        Spacer(minLength: 3)
                        Text("\(workspace.tabs(inWorkspace: record.id).count)")
                            .font(RelayTheme.font(size: 9)).foregroundStyle(RelayTheme.textFaint)
                    }
                    .frame(height: 28)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // Pinned shows always, unpinned only under the pointer. Hover
                // only fades it: switching its hit testing with hover
                // swallowed clicks on the name beside it.
                if !record.isInbox {
                    let shown = WorkspaceNavigatorPin.shown(favourite: record.favourite, hovering: hovering)
                    Button { WorkspaceNavigatorPin.toggle(record, shown: shown, in: workspace) } label: {
                        Image(systemName: record.favourite ? "pin.fill" : "pin")
                            .font(.system(size: 9))
                            .foregroundStyle(record.favourite ? RelayTheme.textMuted : RelayTheme.textFaint)
                            .frame(width: 14, height: 28)
                    }
                    .buttonStyle(.plain)
                    .opacity(shown ? 1 : 0)
                    .help(record.favourite ? "Unpin" : "Pin to top")
                    .accessibilityLabel(WorkspaceNavigatorPin.accessibilityLabel(record))
                    // Hidden, it ignores a press, so it is not offered; the
                    // context menu pins too.
                    .accessibilityHidden(!shown)
                }
            }
            .padding(.horizontal, 8)
            .navigatorRowFill(rowFill)
            .onHover { hovering = $0 }
            .overlay(alignment: .bottomLeading) { refusalCaption }
            .onDrag {
                WorkspaceNavigatorDragState.shared.item = .workspace(record.id)
                return WorkspaceDragPayload.provider(record.id, type: WorkspaceDragPayload.group)
            }
            .onDrop(of: [WorkspaceDragPayload.pane, WorkspaceDragPayload.tab, WorkspaceDragPayload.group],
                    delegate: WorkspaceNavigatorDropDelegate(workspace: workspace, targeted: $targeted, refusal: $refusal,
                                                             failure: $failure) { item in
                switch item {
                case let .pane(id): .paneOnWorkspace(paneID: id, workspaceID: record.id)
                case let .tab(id): .tabOnWorkspace(tabID: id, workspaceID: record.id, index: nil)
                case let .workspace(id): .workspaceBefore(workspaceID: id, targetID: record.id)
                }
            })
            .contextMenu {
                Button("Rename…") { renaming = record }
                if !record.isInbox {
                    Button(record.favourite ? "Unpin" : "Pin to top") {
                        workspace.setWorkspaceFavourite(record.id, !record.favourite)
                    }
                }
                if !record.isInbox {
                    Button(record.hidden == true ? "Show workspace" : "Hide workspace") {
                        workspace.setWorkspaceHidden(record.id, record.hidden != true)
                    }
                }
                Divider()
                if workspace.focusedWorkspaceIDs().contains(record.id) {
                    Button("Remove from focus") { workspace.removeFromFocus(record.id) }
                } else {
                    Button("Focus on this workspace") { workspace.focus(on: record.id) }
                }
                Button("Copy Workspace ID") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(record.id.uuidString.lowercased(), forType: .string)
                }
                Divider()
                Toggle("Auto-link agent panes in this workspace", isOn: Binding(
                    get: { RelayAutoLinker.shared.isEnabled(.workspace(record.id)) },
                    set: { _ in RelayAutoLinker.shared.toggle(.workspace(record.id), workspace: workspace) }))
                Toggle("Allow agents to broadcast in this workspace", isOn: Binding(
                    get: { RelayAutoLinker.shared.allowsBroadcast(.workspace(record.id)) },
                    set: { _ in RelayAutoLinker.shared.toggleBroadcast(.workspace(record.id)) }))
            }
            .accessibilityIdentifier("relay.navigator.workspace.\(record.id.uuidString.lowercased())")
            if expanded {
                ForEach(tabs) { tab in
                    WorkspaceNavigatorTab(tab: tab, workspace: workspace, hold: hold, failure: $failure)
                }
            }
        }
    }

    private var rowFill: NavigatorRowFill {
        NavigatorRowFill(selected: record.id == workspace.selectedWorkspaceID, targeted: targeted, refused: refusal != nil)
    }

    @ViewBuilder private var refusalCaption: some View {
        if targeted, let refusal {
            Text(refusal).font(RelayTheme.font(size: 9)).foregroundStyle(.orange).lineLimit(1)
                .padding(.leading, 30).offset(y: 9)
        }
    }
}

@MainActor private struct WorkspaceNavigatorTab: View {
    @ObservedObject var tab: TabModel
    @ObservedObject var workspace: WorkspaceModel
    @ObservedObject var hold: WorkspaceNavigatorHold
    @Binding var failure: String?
    @State private var targeted = false
    @State private var refusal: String?

    /// `hold` redraws the row when it changes.
    private var expanded: Bool { workspace.isNavigatorTabExpanded(tab.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 2) {
                Button { workspace.setNavigatorTabExpanded(tab.id, !expanded) } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 8)).frame(width: 14, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(expanded ? "Collapse" : "Expand") \(tab.name) panes")
                Button { workspace.selectTab(tab.id, origin: .user) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "rectangle.split.2x1").font(.system(size: 9)).foregroundStyle(RelayTheme.textMuted)
                        Text(workspace.tabDisplayName(tab, fallback: tab.name)).font(RelayTheme.font(size: 11)).lineLimit(1)
                        Text(hosts).font(RelayTheme.font(size: 8)).foregroundStyle(RelayTheme.textFaint).lineLimit(1)
                        Spacer(minLength: 3)
                        if workspace.isTabPinned(tab.id) {
                            Image(systemName: "pin.fill").font(.system(size: 8)).foregroundStyle(RelayTheme.textMuted)
                                .accessibilityLabel("Pinned")
                        }
                        Text("\(tab.allPaneIDs.count)").font(RelayTheme.font(size: 9)).foregroundStyle(RelayTheme.textFaint)
                    }
                    .frame(height: 28)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.leading, 22)
            .padding(.trailing, 8)
            .navigatorRowFill(rowFill)
            .overlay(alignment: .bottomLeading) {
                if targeted, let refusal {
                    Text(refusal).font(RelayTheme.font(size: 9)).foregroundStyle(.orange).lineLimit(1)
                        .padding(.leading, 42).offset(y: 9)
                }
            }
            .onDrag {
                WorkspaceNavigatorDragState.shared.item = .tab(tab.id)
                return WorkspaceDragPayload.provider(tab.id, type: WorkspaceDragPayload.tab)
            }
            .onDrop(of: [WorkspaceDragPayload.pane, WorkspaceDragPayload.tab],
                    delegate: WorkspaceNavigatorDropDelegate(workspace: workspace, targeted: $targeted, refusal: $refusal,
                                                             failure: $failure) { item in
                switch item {
                case let .pane(id): .paneOnTab(paneID: id, tabID: tab.id)
                case let .tab(id): .tabBeforeTab(tabID: id, targetTabID: tab.id)
                case .workspace: nil
                }
            })
            .contextMenu {
                Button(workspace.isTabPinned(tab.id) ? "Unpin tab" : "Pin tab") { workspace.toggleTabPin(tab.id) }
                Toggle("Auto-link agent panes in this tab", isOn: Binding(
                    get: { RelayAutoLinker.shared.isEnabled(.tab(tab.id)) },
                    set: { _ in RelayAutoLinker.shared.toggle(.tab(tab.id), workspace: workspace) }))
                Toggle("Allow agents to broadcast in this tab", isOn: Binding(
                    get: { RelayAutoLinker.shared.allowsBroadcast(.tab(tab.id)) },
                    set: { _ in RelayAutoLinker.shared.toggleBroadcast(.tab(tab.id)) }))
            }
            .accessibilityIdentifier("relay.navigator.tab.\(tab.id.uuidString.lowercased())")
            if expanded {
                ForEach(tab.allPaneIDs, id: \.self) { id in
                    if let pane = workspace.panes[id] {
                        HStack(spacing: 6) {
                            Image(systemName: pane.contentKind == .editor ? "doc.text" : "terminal").font(.system(size: 9))
                            Text(pane.displayName).font(RelayTheme.font(size: 10.5)).lineLimit(1)
                            Spacer(minLength: 3)
                            Text(pane.profile.kind == .local ? "This Mac" : pane.profile.host)
                                .font(RelayTheme.font(size: 8)).foregroundStyle(RelayTheme.textFaint).lineLimit(1)
                        }
                        .padding(.leading, 50)
                        .padding(.trailing, 8)
                        .frame(height: 22)
                        .contentShape(Rectangle())
                        .onTapGesture { workspace.revealPane(id, origin: .user) }
                        .onDrag { WorkspaceDragPayload.paneProvider(id) }
                        .help("Drag onto a tab or workspace to move this pane. It keeps its process, conversation and draft.")
                        .accessibilityIdentifier("relay.navigator.pane.\(id.uuidString.lowercased())")
                    }
                }
            }
        }
    }

    private var hosts: String {
        Set(tab.allPaneIDs.compactMap { workspace.panes[$0] }.map { $0.profile.kind == .local ? "This Mac" : $0.profile.host })
            .sorted().joined(separator: ", ")
    }

    private var rowFill: NavigatorRowFill {
        NavigatorRowFill(selected: tab.id == workspace.selectedTabID, targeted: targeted, refused: refusal != nil)
    }
}

/// A row's fill. A valid drop target is stronger than the selection and
/// outlined, so a drop onto the selected row still shows.
enum NavigatorRowFill: Equatable {
    case none, selected, dropTarget, refused

    init(selected: Bool, targeted: Bool, refused: Bool) {
        if targeted { self = refused ? .refused : .dropTarget } else { self = selected ? .selected : .none }
    }

    var color: Color {
        switch self {
        case .none: .clear
        case .selected: RelayTheme.accent.opacity(0.16)
        case .dropTarget: RelayTheme.accent.opacity(0.34)
        case .refused: Color.orange.opacity(0.16)
        }
    }

    var outlined: Bool { self == .dropTarget }
}

extension View {
    func navigatorRowFill(_ fill: NavigatorRowFill) -> some View {
        background(fill.color, in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                if fill.outlined { RoundedRectangle(cornerRadius: 6).strokeBorder(RelayTheme.accent, lineWidth: 1) }
            }
    }
}

/// "Pinned" and "Workspaces" above their parts of the list.
@MainActor private struct NavigatorSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(RelayTheme.font(.caption).weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Resolves the dragged item, shows the refusal while hovering, and performs
/// the one atomic move on release.
@MainActor private struct WorkspaceNavigatorDropDelegate: DropDelegate {
    enum Dragged { case pane(UUID), tab(UUID), workspace(UUID) }

    let workspace: WorkspaceModel
    @Binding var targeted: Bool
    @Binding var refusal: String?
    @Binding var failure: String?
    let resolve: (Dragged) -> WorkspaceNavigatorDrop?

    private func drop(_ info: DropInfo) -> WorkspaceNavigatorDrop? {
        if info.hasItemsConforming(to: [WorkspaceDragPayload.pane]), let id = PaneDragCoordinator.shared.paneID {
            return resolve(.pane(id))
        }
        switch WorkspaceNavigatorDragState.shared.item {
        case let .tab(id)? where info.hasItemsConforming(to: [WorkspaceDragPayload.tab]): return resolve(.tab(id))
        case let .workspace(id)? where info.hasItemsConforming(to: [WorkspaceDragPayload.group]): return resolve(.workspace(id))
        default: return nil
        }
    }

    func validateDrop(info: DropInfo) -> Bool { drop(info) != nil }

    func dropEntered(info: DropInfo) { _ = dropUpdated(info: info) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard let drop = drop(info) else { return DropProposal(operation: .forbidden) }
        targeted = true
        refusal = workspace.canDrop(drop)?.localizedDescription
        return DropProposal(operation: refusal == nil ? .move : .forbidden)
    }

    func dropExited(info _: DropInfo) {
        targeted = false
        refusal = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            targeted = false
            refusal = nil
            WorkspaceNavigatorDragState.shared.item = nil
            PaneDragCoordinator.shared.paneID = nil
        }
        guard let drop = drop(info) else { return false }
        do {
            try workspace.performDrop(drop)
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
        return true
    }
}

@MainActor private struct WorkspaceRenameSheet: View {
    @State var name: String
    let commit: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename workspace").font(RelayTheme.font(size: 13, weight: .semibold))
            TextField("Name", text: $name).textFieldStyle(.roundedBorder).frame(width: 280)
                .onSubmit { commit(name); dismiss() }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Rename") { commit(name); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
    }
}

/// In-app migration review. The plan is data the user chooses from Relay's
/// plan folder (or an agent stages there); the preview lists every tab's old
/// and new workspace and each pane move. Agents may also apply the exact open
/// preview (by ID and checksum) or undo a recorded migration over MCP.
@MainActor struct WorkspaceMigrationSheet: View {
    @ObservedObject var workspace: WorkspaceModel
    var inbox = WorkspaceMigrationPlanInbox.shared
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    @State private var confirmingApply = false
    @State private var confirmingUndo: UUID?
    @State private var plans: [WorkspaceMigrationPlanInbox.Entry] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Workspace migration").font(RelayTheme.font(size: 14, weight: .semibold))
                Spacer()
                if let name = workspace.migrationPlan?.name {
                    Text(name).font(RelayTheme.font(size: 10.5)).foregroundStyle(RelayTheme.textMuted).lineLimit(1)
                }
                Button("Choose file…", action: choosePlan).accessibilityIdentifier("relay.migration.choose-plan")
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    .font(RelayTheme.font(size: 11))
            }
            if let preview = workspace.migrationPreview {
                previewList(preview)
            } else {
                planList
            }
            let applied = workspace.ownership.migrations.filter { $0.undoneAt == nil }
            if !applied.isEmpty {
                Divider()
                ForEach(applied) { record in
                    HStack {
                        Text("Applied \(record.appliedAt.formatted(date: .abbreviated, time: .shortened)) · \(record.forward.count) tabs, \(record.paneMoves.count) pane moves")
                            .font(RelayTheme.font(size: 11))
                        Spacer()
                        Button("Undo migration…") { confirmingUndo = record.id }
                            .accessibilityIdentifier("relay.migration.undo")
                    }
                }
            }
            HStack {
                if workspace.migrationPreview != nil {
                    Button("Discard preview") { workspace.dismissMigrationPreview() }
                }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                // No Return shortcut: a sheet an agent staged must not apply on a stray keypress.
                Button("Apply…") { confirmingApply = true }
                    .disabled(workspace.migrationPreview.map { !$0.refusals.isEmpty } ?? true)
                    .accessibilityIdentifier("relay.migration.apply")
            }
        }
        .padding(18)
        .frame(width: 760, height: 560)
        .onAppear { plans = inbox.list() }
        .onChange(of: workspace.migrationPreview) { _, _ in plans = inbox.list() }
        .confirmationDialog("Apply this workspace migration?", isPresented: $confirmingApply) {
            Button("Apply") {
                guard let preview = workspace.migrationPreview else { return }
                do { try workspace.applyWorkspaceMigration(preview); error = nil }
                catch { self.error = error.localizedDescription }
            }
        } message: {
            Text("Tabs are re-filed and the listed panes move as they are, keeping their processes, conversations and drafts. You can undo it afterwards.")
        }
        .confirmationDialog("Undo this workspace migration?", isPresented: Binding(
            get: { confirmingUndo != nil }, set: { if !$0 { confirmingUndo = nil } })) {
            Button("Undo migration") {
                guard let id = confirmingUndo else { return }
                confirmingUndo = nil
                do { try workspace.undoWorkspaceMigration(id); error = nil }
                catch { self.error = error.localizedDescription }
            }
        } message: {
            Text("Tabs and moved panes go back where they were, unless you moved them again since. Tabs created afterwards stay where they are. Panes keep their processes, conversations and drafts.")
        }
    }

    private func previewList(_ preview: WorkspaceMigrationPreview) -> some View {
        List {
            Section("Tabs (\(preview.rows.count))") {
                ForEach(preview.rows, id: \.tabID) { row in
                    HStack(spacing: 8) {
                        Text(row.title).font(RelayTheme.font(size: 11, weight: .medium)).frame(width: 190, alignment: .leading).lineLimit(1)
                        Text(([row.legacySessionName] + row.groupPath).joined(separator: " · "))
                            .font(RelayTheme.font(size: 10)).foregroundStyle(RelayTheme.textMuted).lineLimit(1)
                        Spacer()
                        Image(systemName: "arrow.right").font(.system(size: 9))
                        Text(row.workspaceName).font(RelayTheme.font(size: 11, weight: .semibold)).lineLimit(1)
                        Text(row.source.rawValue).font(RelayTheme.font(size: 9)).foregroundStyle(RelayTheme.textFaint)
                        if row.layersDisagree {
                            // Owned by one workspace, shown in another group today.
                            Label("Sidebar disagrees", systemImage: "exclamationmark.triangle.fill")
                                .font(RelayTheme.font(size: 9, weight: .semibold)).foregroundStyle(.orange)
                                .help("This tab's workspace and its sidebar group disagree. Apply moves both to the target.")
                        }
                    }
                }
            }
            Section("Pane moves (\(preview.paneMoves.count))") {
                ForEach(preview.paneMoves, id: \.paneID) { move in
                    HStack(spacing: 8) {
                        Text(workspace.panes[move.paneID]?.displayName ?? move.paneID.uuidString.prefix(8).lowercased())
                            .font(RelayTheme.font(size: 11, weight: .medium))
                        Spacer()
                        Text(tabName(move.fromTabID)).font(RelayTheme.font(size: 10)).foregroundStyle(RelayTheme.textMuted)
                        Image(systemName: "arrow.right").font(.system(size: 9))
                        Text(tabName(move.toTabID)).font(RelayTheme.font(size: 11, weight: .semibold))
                    }
                }
                ForEach(preview.refusals.sorted { $0.key.uuidString < $1.key.uuidString }, id: \.key) { paneID, refusal in
                    Label("\(paneID.uuidString.prefix(8).lowercased()): \(refusal.localizedDescription)", systemImage: "xmark.octagon")
                        .foregroundStyle(.orange).font(RelayTheme.font(size: 10.5))
                }
            }
            Section("Workspaces (\(preview.workspaces.count))") {
                ForEach(preview.workspaces, id: \.id) { item in
                    Text("\(item.name)\(item.isNew ? " · new" : "") · \(item.tabIDs.count) tabs").font(RelayTheme.font(size: 10.5))
                }
                if !preview.retiredGroups.isEmpty {
                    Text("Retired groups (kept in the receipt for Undo): " + preview.retiredGroups.map(\.name).joined(separator: ", "))
                        .font(RelayTheme.font(size: 10.5)).foregroundStyle(RelayTheme.textMuted)
                }
                ForEach(preview.collisions, id: \.name) { collision in
                    Text("Merged by name: \(collision.name) ← " + collision.sources.joined(separator: ", "))
                        .font(RelayTheme.font(size: 10.5)).foregroundStyle(.orange)
                }
            }
        }
    }

    private func tabName(_ id: UUID) -> String {
        workspace.tabs.first { $0.id == id }.map { workspace.tabDisplayName($0, fallback: $0.name) } ?? id.uuidString.prefix(8).lowercased()
    }

    private var planList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Plans in \(inbox.directory.path). Choose one to preview it. Nothing changes until you press Apply.")
                .font(RelayTheme.font(size: 11)).foregroundStyle(RelayTheme.textMuted).textSelection(.enabled)
            List(plans) { plan in
                Button { preview(plan) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(plan.name).font(RelayTheme.font(size: 11, weight: .medium)).lineLimit(1)
                            if let description = plan.description {
                                Text(description).font(RelayTheme.font(size: 10)).foregroundStyle(RelayTheme.textMuted).lineLimit(2)
                            }
                        }
                        Spacer()
                        Text(plan.modified.formatted(date: .abbreviated, time: .shortened))
                            .font(RelayTheme.font(size: 10)).foregroundStyle(RelayTheme.textFaint)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("relay.migration.plan.\(plan.name)")
            }
            .overlay {
                if plans.isEmpty {
                    Text("No plans yet. Choose a file, or ask an agent to stage one.")
                        .font(RelayTheme.font(size: 11)).foregroundStyle(RelayTheme.textFaint)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func preview(_ plan: WorkspaceMigrationPlanInbox.Entry) {
        do {
            try workspace.previewWorkspaceMigration(plan: inbox.read(plan.name), name: plan.name)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func choosePlan() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.directoryURL = inbox.directory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try WorkspaceMigrationPlanInbox.read(url)
            _ = try WorkspaceMigrationPlan.parse(data)
            let copy = try inbox.importPlan(data, from: url)
            try workspace.previewWorkspaceMigration(plan: data, name: copy.lastPathComponent)
            plans = inbox.list()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
