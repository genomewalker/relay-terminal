import SwiftUI

struct PaneHeaderLinkButton: View {
    @EnvironmentObject private var selection: PaneLinkSelection
    let paneID: UUID
    @State private var showingLinks = false
    private var links: [PaneLinkMembership] { selection.memberships(for: paneID) }
    private var selected: Bool { selection.paneIDs.contains(paneID) }
    private var saved: Bool { !links.isEmpty }
    private var unavailable: Bool { links.contains(where: \.unavailable) }

    var body: some View {
        Button {
            // The same two-click action applies even when this pane already
            // has saved collaborators. Saved relationships stay in the menu.
            selection.selectPairPane(paneID)
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 5)
                    .fill(selected ? RelayTheme.accent.opacity(0.17) : Color.clear)
                if selection.connecting && selected {
                    ProgressView().controlSize(.mini).scaleEffect(0.7)
                } else {
                    Image(systemName: "link").font(RelayTheme.font(size: 10, weight: saved || selected ? .semibold : .medium))
                }
            }
            .frame(width: 24, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? RelayTheme.accent : saved ? (unavailable ? RelayTheme.coral : RelayTheme.accent) : RelayTheme.textMuted)
        .focusEffectDisabled()
        .disabled(selection.connecting)
        .help(selected ? "Cancel linking this pane" : selection.pairMode ? "Link with " + (selection.orderedPair.first.map { selection.label(for: $0) } ?? "the selected pane") : "Link this pane with another pane · right-click for saved links")
        .accessibilityLabel("Link pane")
        .accessibilityValue(selected ? "Selected" : saved ? "\(links.count) saved " + (links.count == 1 ? "link" : "links") : "No saved links")
        .accessibilityIdentifier("relay.pane.link." + paneID.uuidString.lowercased())
        .contextMenu {
            Button("Link another pane") { selection.selectPairPane(paneID) }
            Button("View saved links") { showingLinks = true; selection.refreshLinks?() }
        }
        .popover(isPresented: $showingLinks, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Pane links").font(RelayTheme.font(size: 13, weight: .semibold))
                    Spacer()
                    Button("Refresh") { selection.refreshLinks?() }.disabled(selection.refreshingLinks)
                }
                if links.isEmpty { Text(selection.refreshingLinks ? "Loading saved links…" : "No saved links").foregroundStyle(.secondary) }
                ForEach(links) { link in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: link.unavailable ? "exclamationmark.circle" : "link")
                            .foregroundStyle(link.unavailable ? RelayTheme.coral : RelayTheme.accent)
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(link.paneIDs.filter { $0 != paneID }, id: \.self) { id in
                                Text(selection.label(for: id)).lineLimit(2)
                            }
                            Text(link.unavailable ? "Saved · pane unavailable" : "Saved link")
                                .font(RelayTheme.font(size: 10.5)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Remove link") { selection.removeLink?(link.id) }
                            .buttonStyle(.borderless).disabled(selection.removingLinkIDs.contains(link.id))
                            .help("Remove this saved relationship. Both panes keep running.")
                    }
                }
                if let error = selection.linkManagementError {
                    Text(error).foregroundStyle(RelayTheme.coral).fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                Button("Link another pane") { showingLinks = false; selection.selectPairPane(paneID) }
                Text("Saved links identify collaborators. Message delivery is checked separately.")
                    .font(RelayTheme.font(size: 10.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(RelayTheme.font(size: 11.5)).padding(16).frame(width: 350)
        }
    }
}

struct PaneLinkPairControls: View {
    @ObservedObject var workspace: WorkspaceModel
    @ObservedObject var selection: PaneLinkSelection
    @State private var choosingTarget = false
    private var names: String {
        (selection.active ? selection.orderedPair : selection.resultPaneIDs).map(selection.label(for:)).joined(separator: " ↔ ")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 9) {
                if !selection.active {
                    Label("Panes linked", systemImage: "checkmark.circle.fill").foregroundStyle(RelayTheme.accent)
                    Text(names).foregroundStyle(.secondary).lineLimit(1).help(names)
                } else if selection.connecting {
                    ProgressView().controlSize(.small)
                    Text("Linking " + names + "…").lineLimit(1).help(names)
                } else if selection.pairFailure != nil {
                    Label("Link needs attention", systemImage: "exclamationmark.circle").foregroundStyle(RelayTheme.coral)
                    Text(names).foregroundStyle(.secondary).lineLimit(1).help(names)
                    Button("Retry") { selection.retryPair() }.accessibilityIdentifier("relay.pane.link.retry")
                    Button("Choose another pane") { selection.chooseAnotherTarget(); choosingTarget = true }
                } else {
                    Label("Link with", systemImage: "link")
                    Text(names).fontWeight(.medium).lineLimit(1).help(names)
                    Button("Choose pane…") { choosingTarget = true }.accessibilityIdentifier("relay.pane.link.choose-target")
                    Text("or click another pane’s link icon").foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if let failure = selection.pairFailure {
                Text(failure).foregroundStyle(RelayTheme.coral).lineLimit(2).help(failure)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .popover(isPresented: $choosingTarget, arrowEdge: .bottom) {
            PaneLinkTargetPicker(workspace: workspace, selection: selection) { choosingTarget = false }
        }
        .onChange(of: selection.active) { _, active in if !active { choosingTarget = false } }
    }
}

private struct PaneLinkTargetPicker: View {
    @ObservedObject var workspace: WorkspaceModel
    @ObservedObject var selection: PaneLinkSelection
    let dismiss: () -> Void
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    private var targets: [PaneLinkTarget] {
        workspace.paneLinkTargets(excluding: selection.paneIDs).filter {
            query.isEmpty || ($0.name + " " + $0.context).localizedCaseInsensitiveContains(query)
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Choose a pane to link").font(RelayTheme.font(size: 13, weight: .semibold))
            TextField("Search panes, tabs or sessions", text: $query)
                .textFieldStyle(.roundedBorder).focused($searchFocused)
                .accessibilityIdentifier("relay.pane.link.target-search")
                .onSubmit { if let target = targets.first { choose(target.id) } }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if targets.isEmpty { Text("No matching panes").foregroundStyle(.secondary).padding(.vertical, 12) }
                    ForEach(targets) { target in
                        Button { choose(target.id) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(target.name).lineLimit(1)
                                Text(target.context).font(RelayTheme.font(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(8).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).accessibilityLabel("Link with " + target.name + ", " + target.context)
                        .accessibilityIdentifier("relay.pane.link.target." + target.id.uuidString.lowercased())
                    }
                }
            }.frame(maxHeight: 280)
            Text("Panes can be in any tab or session.").font(RelayTheme.font(size: 10.5)).foregroundStyle(.secondary)
        }.font(RelayTheme.font(size: 11.5)).padding(16).frame(width: 390)
        .onAppear { searchFocused = true }
        .onExitCommand { dismiss(); selection.cancel() }
    }
    private func choose(_ id: UUID) { dismiss(); selection.selectPairPane(id) }
}
