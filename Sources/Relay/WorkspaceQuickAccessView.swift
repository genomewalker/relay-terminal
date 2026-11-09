import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct WorkspacePinnedMenu: View {
    @ObservedObject var workspace: WorkspaceModel

    private var tabs: [TabModel] {
        workspace.tabs.filter { workspace.isTabPinned($0.id) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var panes: [PaneModel] {
        workspace.pinnedPaneIDs.compactMap { workspace.panes[$0] }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    var body: some View {
        Menu {
            if tabs.isEmpty && panes.isEmpty { Text("No pinned tabs or panes") }
            if !tabs.isEmpty {
                Section("Tabs") {
                    ForEach(tabs) { tab in
                        Button { workspace.organization.navigate(to: .tab(tab.id)) } label: {
                            Label("\(tab.name) · \(workspaceTabHosts(tab, workspace: workspace))", systemImage: "rectangle.split.2x1")
                        }
                    }
                }
            }
            if !panes.isEmpty {
                Section("Panes") {
                    ForEach(panes) { pane in
                        Button { workspace.organization.navigate(to: .pane(pane.id)) } label: {
                            Label("\(pane.displayName) · \(pane.profile.kind == .local ? "This Mac" : pane.profile.host)", systemImage: "rectangle")
                        }
                    }
                }
            }
            Divider()
            if let tab = workspace.selectedTab {
                Button(workspace.isTabPinned(tab.id) ? "Unpin current tab" : "Pin current tab") {
                    workspace.toggleTabPin(tab.id)
                }
            }
            if let pane = workspace.activePane {
                Button(workspace.isPanePinned(pane.id) ? "Unpin current pane" : "Pin current pane") {
                    workspace.togglePanePin(pane.id)
                }
            }
        } label: { Label("Pinned", systemImage: "pin").labelStyle(.iconOnly).font(RelayTheme.font(size: 11)) }
        .menuStyle(.borderlessButton).fixedSize()
        .accessibilityIdentifier("relay.workspace.pinned")
        .help("Pinned tabs and panes from every workspace. Drop a tab or pane here to pin it.")
        .onDrop(of: [WorkspaceDragPayload.tab, WorkspaceDragPayload.pane], isTargeted: nil) { providers in
            if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(WorkspaceDragPayload.tab.identifier) }) {
                _ = provider.loadDataRepresentation(forTypeIdentifier: WorkspaceDragPayload.tab.identifier) { data, _ in
                    guard let data, let value = String(data: data, encoding: .utf8), let id = UUID(uuidString: value) else { return }
                    Task { @MainActor in
                        guard workspace.tabs.contains(where: { $0.id == id }), !workspace.isTabPinned(id) else { return }
                        workspace.toggleTabPin(id)
                    }
                }
                return true
            }
            if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(WorkspaceDragPayload.pane.identifier) }) {
                _ = provider.loadDataRepresentation(forTypeIdentifier: WorkspaceDragPayload.pane.identifier) { data, _ in
                    guard let data, let value = String(data: data, encoding: .utf8), let id = UUID(uuidString: value) else { return }
                    Task { @MainActor in
                        guard !workspace.isPanePinned(id) else { return }
                        workspace.togglePanePin(id)
                    }
                }
                return true
            }
            return false
        }
    }
}

@MainActor
func workspaceTabHosts(_ tab: TabModel, workspace: WorkspaceModel) -> String {
    Set(tab.allPaneIDs.compactMap { workspace.panes[$0] }.map {
        $0.profile.kind == .local ? "This Mac" : $0.profile.host
    }).sorted().joined(separator: ", ")
}

@MainActor
struct WorkspaceNavigatorPaneRow: View {
    @ObservedObject var pane: PaneModel
    @ObservedObject var workspace: WorkspaceModel
    let depth: Int
    @Binding var failure: String?
    @State private var targeted = false

    var body: some View {
        Button { workspace.organization.navigate(to: .pane(pane.id)) } label: {
            HStack(spacing: 6) {
                Image(systemName: workspace.isPanePinned(pane.id) ? "pin.fill" : "rectangle").font(.system(size: 8))
                Text(pane.displayName).font(RelayTheme.font(size: 10)).lineLimit(1)
                Spacer(minLength: 0)
                Text(pane.profile.kind == .local ? "This Mac" : pane.profile.host)
                    .font(RelayTheme.font(size: 8)).foregroundStyle(RelayTheme.textFaint).lineLimit(1)
            }
            .padding(.leading, 27 + CGFloat(depth) * 13).padding(.trailing, 8).frame(height: 25)
            .contentShape(Rectangle())
            .background(targeted ? RelayTheme.accent.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .foregroundStyle(RelayTheme.textMuted)
        .onDrag { WorkspaceDragPayload.paneProvider(pane.id) }
        .onDrop(of: [WorkspaceDragPayload.pane], isTargeted: $targeted) { providers in
            guard let provider = providers.first else { return false }
            let targetID = pane.id
            _ = provider.loadDataRepresentation(forTypeIdentifier: WorkspaceDragPayload.pane.identifier) { data, _ in
                guard let data, let text = String(data: data, encoding: .utf8), let id = UUID(uuidString: text), id != targetID else { return }
                Task { @MainActor in
                    do { try workspace.stackPane(id, onto: targetID) }
                    catch { failure = error.localizedDescription }
                }
            }
            return true
        }
        .contextMenu {
            Button("Show pane") { workspace.organization.navigate(to: .pane(pane.id)) }
            Button(workspace.isPanePinned(pane.id) ? "Unpin pane" : "Pin pane") { workspace.togglePanePin(pane.id) }
            Menu("Move to workspace") {
                ForEach(workspaceGroups(workspace.organization.outline())) { group in
                    Button(workspace.organization.breadcrumb(for: .group(group.id)).dropFirst().map { workspace.organization.title(for: $0) }.joined(separator: " › ")) {
                        do { try workspace.organization.movePane(pane.id, toGroup: group.id) }
                        catch { failure = error.localizedDescription }
                    }
                }
                Divider()
                Button("Ungroup") {
                    do { try workspace.organization.movePane(pane.id, toGroup: nil) }
                    catch { failure = error.localizedDescription }
                }
            }
        }
        .accessibilityLabel(workspace.organization.accessibilityLabel(for: .pane(pane.id)))
        .accessibilityIdentifier("relay.navigator.pane.\(pane.id.uuidString.lowercased())")
    }

    private func workspaceGroups(_ nodes: [WorkspaceOutlineNode]) -> [WorkspaceGroup] {
        nodes.flatMap { node -> [WorkspaceGroup] in
            switch node {
            case .group(let group, let children): [group] + workspaceGroups(children)
            case .ungrouped(let children): workspaceGroups(children)
            case .tab: []
            }
        }
    }
}
