import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension Notification.Name {
    static let relaySaveWorkspaceView = Notification.Name("relay.workspace.save-view")
    static let relayChooseWorkspaceView = Notification.Name("relay.workspace.choose-view")
    static let relayChoosePaneStack = Notification.Name("relay.workspace.choose-stack")
}

private extension UTType {
    static let relayOrganizationTab = WorkspaceDragPayload.tab
    static let relayOrganizationGroup = WorkspaceDragPayload.group
}

private func workspaceGroupChoices(_ nodes: [WorkspaceOutlineNode]) -> [WorkspaceGroup] {
    nodes.flatMap { node -> [WorkspaceGroup] in
        switch node {
        case let .group(group, children): [group] + workspaceGroupChoices(children)
        case let .ungrouped(children): workspaceGroupChoices(children)
        case .tab: []
        }
    }
}

private struct WorkspaceGroupMenuChoice: Identifiable {
    let id: UUID
    let title: String
    let ancestors: Set<WorkspaceNavigationTarget>
}

private enum WorkspaceNamingRequest: Identifiable {
    case newGroup(UUID?, WorkspaceGroupKind)
    case renameGroup(UUID)
    case saveView
    case renameView(UUID)

    var id: String {
        switch self {
        case let .newGroup(parent, kind): "new-\(parent?.uuidString ?? "root")-\(kind.rawValue)"
        case let .renameGroup(id): "group-\(id)"
        case .saveView: "save-view"
        case let .renameView(id): "view-\(id)"
        }
    }
}

/// The Workspaces navigator lists workspace records, which own tabs. The
/// Connections tool keeps the host and worker controls, separately.
@MainActor struct WorkspaceSidebar<Connections: View>: View {
    @ObservedObject var workspace: WorkspaceModel
    @ObservedObject private var organization: WorkspaceOrganizationController
    @State private var showingConnections = false
    let connections: Connections

    init(workspace: WorkspaceModel, @ViewBuilder connections: () -> Connections) {
        self.workspace = workspace
        self.organization = workspace.organization
        self.connections = connections()
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Navigator", selection: $showingConnections) {
                Text("Workspaces").tag(false)
                Text("Connections").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)
            .accessibilityIdentifier("relay.navigator.mode")
            if showingConnections {
                connections
            } else {
                WorkspaceNavigator(workspace: workspace)
            }
        }
        .background(RelayTheme.sidebar)
    }
}

@MainActor struct WorkspaceNavigationHeader<Tabs: View>: View {
    @ObservedObject var workspace: WorkspaceModel
    @ObservedObject private var organization: WorkspaceOrganizationController
    let tabs: Tabs

    init(workspace: WorkspaceModel, @ViewBuilder tabs: () -> Tabs) {
        self.workspace = workspace
        self.organization = workspace.organization
        self.tabs = tabs()
    }

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceNavigationBar(workspace: workspace, organization: organization)
            tabs
        }
    }
}

@MainActor struct WorkspaceNavigationContent<Content: View>: View {
    @ObservedObject var workspace: WorkspaceModel
    @ObservedObject private var organization: WorkspaceOrganizationController
    let content: Content

    init(workspace: WorkspaceModel, @ViewBuilder content: () -> Content) {
        self.workspace = workspace
        self.organization = workspace.organization
        self.content = content()
    }

    var body: some View {
        content
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: organization.current) { _, _ in workspace.networkVisible = false }
    }
}

@MainActor private struct WorkspaceNavigationBar: View {
    @ObservedObject var workspace: WorkspaceModel
    @ObservedObject var organization: WorkspaceOrganizationController
    @State private var naming: WorkspaceNamingRequest?
    @State private var choosingView = false
    @State private var choosingStack = false

    var body: some View {
        HStack(spacing: 6) {
            navigationButton("Back", symbol: "chevron.left", id: "back", enabled: organization.canGoBack) {
                organization.goBack()
            }
            navigationButton("Forward", symbol: "chevron.right", id: "forward", enabled: organization.canGoForward) {
                organization.goForward()
            }
            // No workspace › tab breadcrumb: the switcher and the selected
            // tab directly below already name both.
            Spacer(minLength: 6)
            WorkspacePinnedMenu(workspace: workspace)
            Menu {
                Button("Save current view…") { naming = .saveView }
                Divider()
                ForEach(organization.savedViews) { view in
                    Button(view.name) { organization.applyView(view.id) }
                }
                if !organization.savedViews.isEmpty {
                    Divider()
                    Button("Manage saved views…") { choosingView = true }
                }
            } label: {
                Label("Saved views", systemImage: "bookmark")
                    .font(RelayTheme.font(size: 11))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityIdentifier("relay.workspace.saved-views")
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(RelayTheme.sidebar)
        .overlay(alignment: .bottom) { Rectangle().fill(RelayTheme.line.opacity(0.4)).frame(height: 1) }
        .sheet(item: $naming) { request in WorkspaceNamingSheet(request: request, organization: organization) }
        .sheet(isPresented: $choosingView) { WorkspaceSavedViewPicker(organization: organization) }
        .sheet(isPresented: $choosingStack) { WorkspaceStackTargetPicker(workspace: workspace) }
        .onReceive(NotificationCenter.default.publisher(for: .relaySaveWorkspaceView)) { _ in naming = .saveView }
        .onReceive(NotificationCenter.default.publisher(for: .relayChooseWorkspaceView)) { _ in choosingView = true }
        .onReceive(NotificationCenter.default.publisher(for: .relayChoosePaneStack)) { _ in choosingStack = true }
    }

    private func navigationButton(_ title: String, symbol: String, id: String, enabled: Bool = true,
                                  action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .medium)).frame(width: 24, height: 25)
        }
        .buttonStyle(.plain)
        .foregroundStyle(RelayTheme.textMuted)
        .disabled(!enabled)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityIdentifier("relay.workspace.\(id)")
    }
}

@MainActor private struct WorkspaceGroupNavigator: View {
    @ObservedObject var workspace: WorkspaceModel
    @ObservedObject var organization: WorkspaceOrganizationController
    @State private var naming: WorkspaceNamingRequest?
    @State private var moveFailure: String?

    var body: some View {
        let outline = organization.outline()
        // Every row has a move menu. Resolve its destinations once for this
        // tree, rather than rebuilding the whole outline for every row on
        // terminal title, activity, focus and selection updates.
        let groupChoices = workspaceGroupChoices(outline).map { group in
            let path = organization.breadcrumb(for: .group(group.id)).dropFirst()
            return WorkspaceGroupMenuChoice(id: group.id,
                title: path.map { organization.title(for: $0) }.joined(separator: " › "),
                ancestors: Set(path))
        }
        VStack(spacing: 6) {
            HStack {
                Button { organization.navigate(to: .all) } label: {
                    Label("All workspaces", systemImage: "square.grid.2x2")
                        .font(RelayTheme.font(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("relay.navigator.overview")
                Spacer()
                Menu {
                    Button("New project…") { naming = .newGroup(nil, .project) }
                    Button("New task…") { naming = .newGroup(nil, .task) }
                } label: { Image(systemName: "plus").frame(width: 22, height: 24) }
                .menuStyle(.borderlessButton).fixedSize()
                .accessibilityLabel("Create workspace")
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 5)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(outline) { node in
                        WorkspaceOutlineRow(node: node, depth: 0, workspace: workspace,
                                            organization: organization, groupChoices: groupChoices,
                                            naming: $naming, failure: $moveFailure)
                    }
                    Color.clear.frame(height: 28)
                        .overlay(alignment: .leading) { Text("Drop here to ungroup").font(RelayTheme.font(size: 10)).foregroundStyle(RelayTheme.textFaint) }
                        .modifier(WorkspaceOrganizationDrop(organization: organization, groupID: nil, failure: $moveFailure))
                    if !organization.savedViews.isEmpty {
                        Divider().padding(.vertical, 10)
                        Text("Saved views").font(RelayTheme.font(size: 10, weight: .semibold)).foregroundStyle(RelayTheme.textMuted).padding(.horizontal, 7)
                        ForEach(organization.savedViews) { view in
                            Button { organization.applyView(view.id) } label: {
                                Label(view.name, systemImage: "bookmark").font(RelayTheme.font(size: 11)).lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(7)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Rename…") { naming = .renameView(view.id) }
                                Button("Delete saved view", role: .destructive) { organization.deleteView(view.id) }
                            }
                        }
                    }
                }
                .padding(.horizontal, 6)
            }
        }
        .foregroundStyle(RelayTheme.text)
        .sheet(item: $naming) { WorkspaceNamingSheet(request: $0, organization: organization) }
        .alert("Could not move workspace", isPresented: Binding(get: { moveFailure != nil }, set: { if !$0 { moveFailure = nil } })) {
            Button("OK") { moveFailure = nil }
        } message: { Text(moveFailure ?? "") }
        .accessibilityIdentifier("relay.navigator.workspaces")
    }
}

@MainActor private struct WorkspaceOutlineRow: View {
    let node: WorkspaceOutlineNode
    let depth: Int
    @ObservedObject var workspace: WorkspaceModel
    @ObservedObject var organization: WorkspaceOrganizationController
    let groupChoices: [WorkspaceGroupMenuChoice]
    @Binding var naming: WorkspaceNamingRequest?
    @Binding var failure: String?

    var body: some View {
        switch node {
        case let .group(group, children):
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 3) {
                    Button { organization.setCollapsed(group.id, !group.collapsed) } label: {
                        Image(systemName: group.collapsed ? "chevron.right" : "chevron.down")
                            .font(.system(size: 9, weight: .semibold)).frame(width: 18, height: 26)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(group.collapsed ? "Expand" : "Collapse") \(group.name)")
                    Button { organization.navigate(to: .group(group.id)) } label: {
                        Label(group.name, systemImage: group.kind == .task ? "checklist" : "folder")
                            .font(RelayTheme.font(size: 11.5, weight: .medium)).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading).frame(height: 27)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.leading, CGFloat(depth) * 13)
                .padding(.trailing, 7)
                .background(organization.current == .group(group.id) ? RelayTheme.accent.opacity(0.14) : .clear,
                            in: RoundedRectangle(cornerRadius: 5))
                .onDrag { WorkspaceDragPayload.provider(group.id, type: .relayOrganizationGroup) }
                .modifier(WorkspaceOrganizationDrop(organization: organization, groupID: group.id, failure: $failure))
                .contextMenu {
                    Button("Open workspace") { organization.navigate(to: .group(group.id)) }
                    Button("New project inside…") { naming = .newGroup(group.id, .project) }
                    Button("New task inside…") { naming = .newGroup(group.id, .task) }
                    Button("Rename…") { naming = .renameGroup(group.id) }
                    Menu("Move inside") {
                        Button("Top level") {
                            do { try organization.moveGroup(group.id, toParent: nil, at: organization.children(of: nil).count) }
                            catch { failure = error.localizedDescription }
                        }
                        ForEach(groupChoices.filter {
                            !$0.ancestors.contains(.group(group.id))
                        }) { destination in
                            Button(destination.title) {
                                do { try organization.moveGroup(group.id, toParent: destination.id, at: organization.children(of: destination.id).count) }
                                catch { failure = error.localizedDescription }
                            }
                        }
                    }
                    Button("Sort by name") { organization.sortChildren(of: group.id, by: .name, recursive: true) }
                    Button("Sort by host, then name") { organization.sortChildren(of: group.id, by: .host, recursive: true) }
                    Divider()
                    Button("Ungroup") { organization.deleteGroup(group.id) }
                }
                .accessibilityIdentifier("relay.navigator.group.\(group.id.uuidString.lowercased())")
                if !group.collapsed {
                    ForEach(children) { child in
                        AnyView(WorkspaceOutlineRow(node: child, depth: depth + 1, workspace: workspace,
                                                   organization: organization, groupChoices: groupChoices,
                                                   naming: $naming, failure: $failure))
                    }
                }
            }
        case let .ungrouped(children):
            VStack(alignment: .leading, spacing: 2) {
                Text("Ungrouped").font(RelayTheme.font(size: 10, weight: .medium)).foregroundStyle(RelayTheme.textMuted).padding(7)
                ForEach(children) { child in
                    AnyView(WorkspaceOutlineRow(node: child, depth: depth, workspace: workspace,
                                               organization: organization, groupChoices: groupChoices,
                                               naming: $naming, failure: $failure))
                }
            }
        case let .tab(id):
            if let tab = workspace.tabs.first(where: { $0.id == id }) {
                WorkspaceNavigatorTabRow(tab: tab, workspace: workspace, organization: organization,
                                         groupChoices: groupChoices, depth: depth, failure: $failure)
            }
        }
    }
}

@MainActor private struct WorkspaceNavigatorTabRow: View {
    @ObservedObject var tab: TabModel
    @ObservedObject var workspace: WorkspaceModel
    @ObservedObject var organization: WorkspaceOrganizationController
    let groupChoices: [WorkspaceGroupMenuChoice]
    let depth: Int
    @Binding var failure: String?
    @State private var dropTargeted = false
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
        HStack(spacing: 2) {
            Button { expanded.toggle() } label: {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8)).frame(width: 16, height: 27)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(expanded ? "Collapse" : "Expand") \(tab.name) panes")
            .padding(.leading, 8 + CGFloat(depth) * 13)
        Button { organization.navigate(to: .tab(tab.id)) } label: {
            HStack(spacing: 7) {
                Image(systemName: "rectangle.split.2x1").font(.system(size: 10)).foregroundStyle(RelayTheme.textMuted)
                Text(tab.name).font(RelayTheme.font(size: 11)).lineLimit(1)
                Text(workspaceTabHosts(tab, workspace: workspace)).font(RelayTheme.font(size: 8)).foregroundStyle(RelayTheme.textFaint).lineLimit(1)
                Spacer(minLength: 3)
                Text("\(tab.allPaneIDs.count)").font(RelayTheme.font(size: 9)).foregroundStyle(RelayTheme.textFaint)
            }
            .padding(.leading, 3)
            .padding(.trailing, 8)
            .frame(height: 27)
            .contentShape(Rectangle())
            .background(organization.current == .tab(tab.id) ? RelayTheme.accent.opacity(0.14) : .clear,
                        in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .onDrag { WorkspaceDragPayload.provider(tab.id, type: .relayOrganizationTab) }
        .contextMenu {
            Button(workspace.isTabPinned(tab.id) ? "Unpin tab" : "Pin tab") { workspace.toggleTabPin(tab.id) }
            Menu("Move to workspace") {
                ForEach(groupChoices) { group in
                    Button(group.title) {
                        organization.placeTab(tab.id, inGroup: group.id, at: organization.children(of: group.id).count)
                    }
                }
                Divider()
                Button("Ungroup") { organization.placeTab(tab.id, inGroup: nil, at: 0) }
            }
        }
        .overlay(alignment: .top) { if dropTargeted { Rectangle().fill(RelayTheme.accent).frame(height: 2) } }
        .onDrop(of: [UTType.relayOrganizationTab, WorkspaceDragPayload.pane], isTargeted: $dropTargeted) { providers in
            if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(WorkspaceDragPayload.pane.identifier) }) {
                _ = provider.loadDataRepresentation(forTypeIdentifier: WorkspaceDragPayload.pane.identifier) { data, _ in
                    guard let data, let text = String(data: data, encoding: .utf8), let id = UUID(uuidString: text) else { return }
                    Task { @MainActor in
                        do { try workspace.movePane(id, toTab: tab.id, beside: nil, placement: .trailing) }
                        catch { failure = error.localizedDescription }
                    }
                }
                return true
            }
            guard let provider = providers.first else { return false }
            _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.relayOrganizationTab.identifier) { data, _ in
                guard let data, let text = String(data: data, encoding: .utf8), let id = UUID(uuidString: text) else { return }
                Task { @MainActor in
                    let group = organization.group(containingTab: tab.id)?.id
                    let nodes = group == nil ? organization.outline() : organization.children(of: group)
                    let siblings = nodes.flatMap { node -> [UUID] in
                        if case let .tab(value) = node { return [value] }
                        if case let .ungrouped(children) = node {
                            return children.compactMap { if case let .tab(value) = $0 { value } else { nil } }
                        }
                        return []
                    }.filter { $0 != id }
                    organization.placeTab(id, inGroup: group, at: siblings.firstIndex(of: tab.id) ?? siblings.count)
                }
            }
            return true
        }
        .accessibilityLabel(organization.accessibilityLabel(for: .tab(tab.id)))
        .accessibilityIdentifier("relay.navigator.tab.\(tab.id.uuidString.lowercased())")
        }
        if expanded {
            ForEach(tab.allPaneIDs, id: \.self) { id in
                if let pane = workspace.panes[id] {
                    WorkspaceNavigatorPaneRow(pane: pane, workspace: workspace, depth: depth + 1, failure: $failure)
                }
            }
        }
        }
    }
}

@MainActor private struct WorkspaceOrganizationDrop: ViewModifier {
    let organization: WorkspaceOrganizationController
    let groupID: UUID?
    @Binding var failure: String?
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .overlay { if targeted { RoundedRectangle(cornerRadius: 5).strokeBorder(RelayTheme.accent, lineWidth: 1.5).allowsHitTesting(false) } }
            .onDrop(of: [UTType.relayOrganizationTab, .relayOrganizationGroup, WorkspaceDragPayload.pane], isTargeted: $targeted) { providers in
                if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(WorkspaceDragPayload.pane.identifier) }) {
                    _ = provider.loadDataRepresentation(forTypeIdentifier: WorkspaceDragPayload.pane.identifier) { data, _ in
                        guard let data, let text = String(data: data, encoding: .utf8), let id = UUID(uuidString: text) else { return }
                        Task { @MainActor in
                            do { try organization.movePane(id, toGroup: groupID) }
                            catch { failure = error.localizedDescription }
                        }
                    }
                    return true
                }
                if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.relayOrganizationGroup.identifier) }) {
                    _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.relayOrganizationGroup.identifier) { data, _ in
                        guard let data, let text = String(data: data, encoding: .utf8), let id = UUID(uuidString: text) else { return }
                        Task { @MainActor in
                            do { try organization.moveGroup(id, toParent: groupID, at: organization.children(of: groupID).count) }
                            catch { failure = error.localizedDescription }
                        }
                    }
                    return true
                }
                if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.relayOrganizationTab.identifier) }) {
                    _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.relayOrganizationTab.identifier) { data, _ in
                        guard let data, let text = String(data: data, encoding: .utf8), let id = UUID(uuidString: text) else { return }
                        Task { @MainActor in organization.placeTab(id, inGroup: groupID, at: organization.children(of: groupID).count) }
                    }
                    return true
                }
                return false
            }
    }
}

/// Miniatures read model metadata and split ratios. They never mount terminals,
/// start background panes, or load a research conversation for a preview.
@MainActor private struct WorkspaceOverview: View {
    @ObservedObject var workspace: WorkspaceModel
    @ObservedObject var organization: WorkspaceOrganizationController
    @State private var naming: WorkspaceNamingRequest?
    @State private var moveFailure: String?
    private let columns = [GridItem(.adaptive(minimum: 265, maximum: 430), spacing: 16, alignment: .top)]

    private var groupID: UUID? {
        if case let .group(id) = organization.current { return id }
        return nil
    }
    private var nodes: [WorkspaceOutlineNode] { groupID == nil ? organization.outline() : organization.children(of: groupID) }
    private var directTabs: [UUID] { nodes.compactMap { if case let .tab(id) = $0 { id } else { nil } } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(organization.title(for: organization.current)).font(RelayTheme.font(size: 26, weight: .semibold))
                        let paneCount = organization.paneIDs(in: organization.current).count
                        Text("\(paneCount) \(paneCount == 1 ? "pane" : "panes")")
                            .font(RelayTheme.font(size: 12)).foregroundStyle(RelayTheme.textMuted)
                    }
                    Spacer()
                    Menu {
                        Button("New project…") { naming = .newGroup(groupID, .project) }
                        Button("New task…") { naming = .newGroup(groupID, .task) }
                    } label: { Label("New workspace", systemImage: "plus").font(RelayTheme.font(size: 11)) }
                    .menuStyle(.borderlessButton).fixedSize()
                }
                if nodes.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("No tabs in this workspace").font(RelayTheme.font(size: 15, weight: .medium))
                        Text("Move a tab here from the navigator, or create a workspace inside it.")
                            .font(RelayTheme.font(size: 12)).foregroundStyle(RelayTheme.textMuted)
                    }
                    .padding(.vertical, 32)
                    .frame(maxWidth: .infinity, minHeight: 170, alignment: .leading)
                    .modifier(WorkspaceOrganizationDrop(organization: organization, groupID: groupID, failure: $moveFailure))
                }
                if !directTabs.isEmpty { tabGrid(directTabs) }
                ForEach(nodes) { node in
                    switch node {
                    case let .group(group, children):
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Button { organization.navigate(to: .group(group.id)) } label: {
                                    Label(group.name, systemImage: group.kind == .task ? "checklist" : "folder")
                                        .font(RelayTheme.font(size: 14, weight: .semibold))
                                }
                                .buttonStyle(.plain)
                                Spacer()
                                Button { organization.navigate(to: .group(group.id)) } label: {
                                    Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 11))
                                }
                                .buttonStyle(.plain).help("Open \(group.name)")
                                .accessibilityLabel("Open \(group.name)")
                            }
                            let ids = tabIDs(children)
                            if ids.isEmpty {
                                Text("Drop a tab here").font(RelayTheme.font(size: 11)).foregroundStyle(RelayTheme.textFaint)
                                    .frame(maxWidth: .infinity, minHeight: 55, alignment: .leading)
                            } else { tabGrid(ids) }
                        }
                        .modifier(WorkspaceOrganizationDrop(organization: organization, groupID: group.id, failure: $moveFailure))
                        .accessibilityIdentifier("relay.overview.group.\(group.id.uuidString.lowercased())")
                    case let .ungrouped(children):
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Ungrouped").font(RelayTheme.font(size: 14, weight: .semibold))
                            tabGrid(tabIDs(children))
                        }
                    case .tab: EmptyView()
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(RelayTheme.canvas)
        .foregroundStyle(RelayTheme.text)
        .sheet(item: $naming) { WorkspaceNamingSheet(request: $0, organization: organization) }
        .alert("Could not move workspace", isPresented: Binding(get: { moveFailure != nil }, set: { if !$0 { moveFailure = nil } })) {
            Button("OK") { moveFailure = nil }
        } message: { Text(moveFailure ?? "") }
        .accessibilityIdentifier("relay.workspace.overview")
    }

    private func tabGrid(_ ids: [UUID]) -> some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
            ForEach(ids, id: \.self) { id in
                if let tab = workspace.tabs.first(where: { $0.id == id }) {
                    WorkspaceOverviewTab(tab: tab, workspace: workspace, organization: organization)
                }
            }
        }
    }

    private func tabIDs(_ children: [WorkspaceOutlineNode]) -> [UUID] {
        children.flatMap { node -> [UUID] in
            switch node {
            case let .tab(id): [id]
            case let .group(_, children), let .ungrouped(children): tabIDs(children)
            }
        }
    }
}

@MainActor private struct WorkspaceOverviewTab: View {
    @ObservedObject var tab: TabModel
    @ObservedObject var workspace: WorkspaceModel
    @ObservedObject var organization: WorkspaceOrganizationController
    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { organization.navigate(to: .tab(tab.id)) } label: {
                HStack {
                    Text(tab.name).font(RelayTheme.font(size: 12, weight: .semibold)).lineLimit(1)
                    Spacer()
                    Text("\(tab.allPaneIDs.count)").font(RelayTheme.font(size: 10)).foregroundStyle(RelayTheme.textMuted)
                }
                .padding(.horizontal, 11).frame(height: 35).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    WorkspaceLayoutMiniature(node: tab.layout, tab: tab, workspace: workspace, organization: organization)
                    ForEach(tab.floatingPanes.filter { !$0.isMinimized }) { floating in
                        if let pane = workspace.panes[floating.paneID] {
                            let width = max(tab.canvasSize.width, CGFloat(floating.originX + floating.width), 800)
                            let height = max(tab.canvasSize.height, CGFloat(floating.originY + floating.height), 500)
                            WorkspaceOverviewPane(pane: pane, workspace: workspace, stackCount: 1) { organization.navigate(to: .pane(pane.id)) }
                                .frame(width: max(35, CGFloat(floating.width) / width * geometry.size.width),
                                       height: max(28, CGFloat(floating.height) / height * geometry.size.height))
                                .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(RelayTheme.accent.opacity(0.6)) }
                                .offset(x: max(0, CGFloat(floating.originX) / width * geometry.size.width),
                                        y: max(0, CGFloat(floating.originY) / height * geometry.size.height))
                        }
                    }
                }
                .clipped()
            }
            .frame(height: 154)
            .padding(5)
            if !tab.stacks.isEmpty || !tab.floatingPanes.isEmpty {
                HStack(spacing: 10) {
                    if !tab.stacks.isEmpty {
                        Menu {
                            ForEach(tab.stacks) { stack in
                                ForEach(stack.members, id: \.self) { id in
                                    if let pane = workspace.panes[id] {
                                        Button(pane.customName ?? pane.title) { organization.navigate(to: .pane(id)) }
                                    }
                                }
                                Divider()
                            }
                        } label: { Label("\(tab.stacks.count) stacks", systemImage: "square.stack") }
                        .menuStyle(.borderlessButton).fixedSize()
                    }
                    if !tab.floatingPanes.isEmpty {
                        Menu {
                            ForEach(tab.floatingPanes) { floating in
                                if let pane = workspace.panes[floating.paneID] {
                                    Button(pane.customName ?? pane.title) { organization.navigate(to: .pane(pane.id)) }
                                }
                            }
                        } label: { Label("\(tab.floatingPanes.count) floating", systemImage: "macwindow.on.rectangle") }
                        .menuStyle(.borderlessButton).fixedSize()
                    }
                    Spacer()
                }
                .font(RelayTheme.font(size: 9)).foregroundStyle(RelayTheme.textMuted)
                .padding(.horizontal, 11).padding(.vertical, 7)
            }
        }
        .background(RelayTheme.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(hovered ? RelayTheme.accent.opacity(0.65) : RelayTheme.line.opacity(0.65)) }
        .onHover { hovered = $0 }
        .onDrag { WorkspaceDragPayload.provider(tab.id, type: .relayOrganizationTab) }
        .contextMenu {
            Button("Open tab") { organization.navigate(to: .tab(tab.id)) }
            Button(workspace.isTabPinned(tab.id) ? "Unpin tab" : "Pin tab") { workspace.toggleTabPin(tab.id) }
            Menu("Move to workspace") {
                ForEach(workspaceGroupChoices(organization.outline())) { group in
                    Button(group.name) { organization.placeTab(tab.id, inGroup: group.id, at: organization.children(of: group.id).count) }
                }
                Divider()
                Button("Ungroup") { organization.placeTab(tab.id, inGroup: nil, at: 0) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(organization.accessibilityLabel(for: .tab(tab.id)))
        .accessibilityIdentifier("relay.overview.tab.\(tab.id.uuidString.lowercased())")
    }
}

@MainActor private struct WorkspaceLayoutMiniature: View {
    let node: PaneLayout
    @ObservedObject var tab: TabModel
    @ObservedObject var workspace: WorkspaceModel
    @ObservedObject var organization: WorkspaceOrganizationController

    var body: some View {
        switch node {
        case let .pane(id):
            if let pane = workspace.panes[id] {
                WorkspaceOverviewPane(pane: pane, workspace: workspace, stackCount: tab.stack(containing: id)?.members.count ?? 1) {
                    organization.navigate(to: .pane(id))
                }
            }
        case let .split(id, axis, first, second):
            GeometryReader { geometry in
                let ratio = min(0.95, max(0.05, tab.splitRatios[id] ?? 0.5))
                if axis == .horizontal {
                    HStack(spacing: 3) {
                        AnyView(WorkspaceLayoutMiniature(node: first, tab: tab, workspace: workspace, organization: organization))
                            .frame(width: max(0, (geometry.size.width - 3) * ratio))
                        AnyView(WorkspaceLayoutMiniature(node: second, tab: tab, workspace: workspace, organization: organization))
                    }
                } else {
                    VStack(spacing: 3) {
                        AnyView(WorkspaceLayoutMiniature(node: first, tab: tab, workspace: workspace, organization: organization))
                            .frame(height: max(0, (geometry.size.height - 3) * ratio))
                        AnyView(WorkspaceLayoutMiniature(node: second, tab: tab, workspace: workspace, organization: organization))
                    }
                }
            }
        }
    }
}

@MainActor private struct WorkspaceOverviewPane: View {
    @ObservedObject var pane: PaneModel
    @ObservedObject var workspace: WorkspaceModel
    let stackCount: Int
    let open: () -> Void

    private var host: String { pane.profile.kind == .local ? "This Mac" : pane.profile.host }
    private var connected: Bool { if case .connected = pane.connectionState { true } else { false } }

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Circle().fill(connected ? RelayTheme.mint : RelayTheme.textFaint).frame(width: 4, height: 4)
                    Text(pane.customName ?? pane.title).font(RelayTheme.font(size: 10, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 0)
                    if stackCount > 1 { Image(systemName: "square.stack").font(.system(size: 8)) }
                }
                Text(host).font(RelayTheme.font(size: 9)).foregroundStyle(RelayTheme.textMuted).lineLimit(1)
                Spacer(minLength: 0)
                if let directory = pane.directory {
                    Text(directory).font(.system(size: 8, design: .monospaced)).foregroundStyle(RelayTheme.textFaint).lineLimit(1).truncationMode(.middle)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RelayTheme.canvas.opacity(0.8), in: RoundedRectangle(cornerRadius: 4))
            .clipped()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onDrag { WorkspaceDragPayload.paneProvider(pane.id) }
        .contextMenu {
            Button("Show pane", action: open)
            Button(workspace.isPanePinned(pane.id) ? "Unpin pane" : "Pin pane") { workspace.togglePanePin(pane.id) }
        }
        .help("Open \(pane.customName ?? pane.title) on \(host)")
        .accessibilityLabel("\(pane.customName ?? pane.title), \(host)\(stackCount > 1 ? ", stack of \(stackCount) panes" : "")")
        .accessibilityIdentifier("relay.overview.pane.\(pane.id.uuidString.lowercased())")
    }
}

@MainActor struct WorkspacePaneStackChrome<Content: View>: View {
    @ObservedObject var tab: TabModel
    @ObservedObject var workspace: WorkspaceModel
    let paneID: UUID
    let content: Content
    var inbox: AgentIntelligenceStore = .shared
    @State private var failure: String?

    init(tab: TabModel, workspace: WorkspaceModel, paneID: UUID, inbox: AgentIntelligenceStore = .shared,
         @ViewBuilder content: () -> Content) {
        self.tab = tab; self.workspace = workspace; self.paneID = paneID; self.inbox = inbox; self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            if let stack = tab.stack(containing: paneID) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(Array(stack.members.enumerated()), id: \.element) { index, id in
                            if let pane = workspace.panes[id] {
                                Button { workspace.organization.navigate(to: .pane(id)) } label: {
                                    HStack(spacing: 4) {
                                        if let status = pane.headerStatus {
                                            Image(systemName: status.role.symbol).imageScale(.small)
                                                .foregroundStyle(status.role == .neutral ? RelayTheme.textFaint : status.role.color)
                                        }
                                        Text(pane.customName ?? pane.title).font(RelayTheme.font(size: 10, weight: id == stack.selected ? .semibold : .regular))
                                            .lineLimit(1)
                                        RelayFinishedDot(paneIDs: [id], inbox: inbox)
                                    }
                                    .frame(maxWidth: 175).padding(.horizontal, 9).frame(height: 26)
                                        .background(id == stack.selected ? RelayTheme.accent.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 4))
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(id == stack.selected ? RelayTheme.text : RelayTheme.textMuted)
                                .onDrag { WorkspaceDragPayload.paneProvider(id) }
                                .help(pane.statusTooltip)
                                .accessibilityLabel("\(pane.statusTooltip), stack tab \(index + 1) of \(stack.members.count)")
                                .accessibilityAddTraits(id == stack.selected ? .isSelected : [])
                                .accessibilityIdentifier("relay.stack.member.\(id.uuidString.lowercased())")
                                .contextMenu {
                                    Button("Show pane") { workspace.organization.navigate(to: .pane(id)) }
                                    Button(workspace.isPanePinned(id) ? "Unpin pane" : "Pin pane") { workspace.togglePanePin(id) }
                                    Button("Unstack to the right") {
                                        do { try workspace.unstackPane(id, placement: .trailing) }
                                        catch { failure = error.localizedDescription }
                                    }
                                    Button("Move left") { workspace.moveStackMember(id, toIndex: index - 1) }.disabled(index == 0)
                                    Button("Move right") { workspace.moveStackMember(id, toIndex: index + 1) }.disabled(index == stack.members.count - 1)
                                    Divider()
                                    Button("Close pane") { workspace.selectPane(id, origin: .programmatic); workspace.closeActivePane() }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                }
                .frame(height: 30).background(RelayTheme.sidebar)
                .accessibilityIdentifier("relay.stack.\(stack.id.uuidString.lowercased())")
            }
            content
        }
        .alert("Could not change pane layout", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK") { failure = nil }
        } message: { Text(failure ?? "") }
    }
}

@MainActor private struct WorkspaceNamingSheet: View {
    let request: WorkspaceNamingRequest
    @ObservedObject var organization: WorkspaceOrganizationController

    var body: some View {
        switch request {
        case let .newGroup(parent, kind):
            WorkspaceNameSheet(title: kind == .task ? "New task" : "New project", initial: "", action: "Create") {
                organization.createGroup(name: $0, kind: kind, parentID: parent)
            }
        case let .renameGroup(id):
            WorkspaceNameSheet(title: "Rename workspace", initial: organization.group(id: id)?.name ?? "", action: "Rename") {
                organization.renameGroup(id, to: $0)
            }
        case .saveView:
            WorkspaceNameSheet(title: "Save current view", initial: organization.title(for: organization.current), action: "Save") {
                organization.saveView(name: $0)
            }
        case let .renameView(id):
            WorkspaceNameSheet(title: "Rename saved view", initial: organization.savedViews.first { $0.id == id }?.name ?? "", action: "Rename") {
                organization.renameView(id, to: $0)
            }
        }
    }
}

@MainActor private struct WorkspaceNameSheet: View {
    let title: String
    let action: String
    let submit: (String) -> Void
    @State private var name: String
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    init(title: String, initial: String, action: String, submit: @escaping (String) -> Void) {
        self.title = title; self.action = action; self.submit = submit; _name = State(initialValue: initial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.headline)
            TextField("Name", text: $name).textFieldStyle(.roundedBorder).focused($focused)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(action) { submit(name.trimmingCharacters(in: .whitespacesAndNewlines)); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22).frame(width: 350).onAppear { focused = true }
    }
}

@MainActor private struct WorkspaceSavedViewPicker: View {
    @ObservedObject var organization: WorkspaceOrganizationController
    @State private var naming: WorkspaceNamingRequest?
    @State private var selectedViewID: UUID?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Saved views").font(.headline)
            if organization.savedViews.isEmpty {
                Text("Save a view to return to its workspace, pane stacks and zoom.").foregroundStyle(.secondary).padding(.vertical, 20)
            } else {
                List(organization.savedViews, selection: $selectedViewID) { view in
                    HStack {
                        Label(view.name, systemImage: "bookmark").frame(maxWidth: .infinity, alignment: .leading)
                        Button { naming = .renameView(view.id) } label: { Image(systemName: "pencil") }.buttonStyle(.borderless).help("Rename view")
                        Button(role: .destructive) { organization.deleteView(view.id) } label: { Image(systemName: "trash") }.buttonStyle(.borderless).help("Delete saved view")
                    }
                    .padding(.vertical, 4)
                    .tag(view.id)
                    .onTapGesture(count: 2) { organization.applyView(view.id); dismiss() }
                }
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Open view") {
                    guard let selectedViewID else { return }
                    organization.applyView(selectedViewID); dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedViewID == nil || !organization.savedViews.contains { $0.id == selectedViewID })
            }
        }
        .padding(20).frame(width: 400, height: 310)
        .sheet(item: $naming) { WorkspaceNamingSheet(request: $0, organization: organization) }
    }
}

@MainActor private struct WorkspaceStackTargetPicker: View {
    @ObservedObject var workspace: WorkspaceModel
    let sourcePaneID: UUID?
    @State private var selectedTargetID: UUID?
    @State private var failure: String?
    @Environment(\.dismiss) private var dismiss

    init(workspace: WorkspaceModel) {
        self.workspace = workspace
        sourcePaneID = workspace.activePaneID
    }

    private var candidates: [PaneModel] {
        guard let sourcePaneID, let current = workspace.tabs.first(where: { $0.allPaneIDs.contains(sourcePaneID) }) else { return [] }
        return workspace.tabs.filter { $0.sessionID == current.sessionID }
            .flatMap { $0.layout.paneIDs }.filter { $0 != sourcePaneID }
            .compactMap { workspace.panes[$0] }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Stack active pane with…").font(.headline)
            if candidates.isEmpty {
                Text("Open another tiled pane in this connection session to create a stack.").foregroundStyle(.secondary).padding(.vertical, 20)
            } else {
                List(candidates, selection: $selectedTargetID) { pane in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(pane.customName ?? pane.title)
                        Text(location(for: pane)).font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                    .tag(pane.id)
                }
            }
            if let failure { Text(failure).font(.caption).foregroundStyle(.orange) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Stack panes") {
                    guard let sourcePaneID, let selectedTargetID else { return }
                    do { try workspace.stackPane(sourcePaneID, onto: selectedTargetID); dismiss() }
                    catch { failure = error.localizedDescription }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(sourcePaneID == nil || selectedTargetID == nil || !candidates.contains { $0.id == selectedTargetID })
            }
        }
        .padding(20).frame(width: 420, height: 350)
    }

    private func location(for pane: PaneModel) -> String {
        let host = pane.profile.kind == .local ? "This Mac" : pane.profile.host
        guard let tab = workspace.tabs.first(where: { $0.layout.paneIDs.contains(pane.id) }),
              let index = tab.layout.paneIDs.firstIndex(of: pane.id) else { return host }
        return "\(tab.name), pane \(index + 1), \(host)"
    }
}
