import SwiftUI

struct PaneMessagingLinkView: View {
    @ObservedObject var workspace: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<UUID> = []
    @State private var allTabs = false
    @State private var query = ""
    @State private var saving = false
    @State private var saved: RelayPaneMessaging.Link?
    @State private var failure: String?
    @State private var startingTabID: UUID?

    private var candidates: [PaneModel] {
        workspace.tabs.filter { allTabs || $0.id == startingTabID }.flatMap(\.allPaneIDs)
            .compactMap { workspace.panes[$0] }.filter { pane in
                pane.contentKind == .terminal && (query.isEmpty ||
                    [pane.displayName, detail(pane), pane.kind.label]
                        .joined(separator: " ").localizedCaseInsensitiveContains(query))
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Link panes", systemImage: "link").font(RelayTheme.font(size: 16, weight: .semibold))
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark").frame(width: 28, height: 28) }
                    .buttonStyle(.plain).help("Close linking").accessibilityLabel("Close linking")
                    .keyboardShortcut(.cancelAction).disabled(saving)
            }
            Text("Connect two agents so they can message each other.")
                .font(RelayTheme.font(size: 12)).foregroundStyle(RelayTheme.textMuted)
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(RelayTheme.textMuted)
                TextField("Find a pane, tab, or folder", text: $query)
                    .accessibilityIdentifier("relay.linking.search")
                Toggle("All tabs", isOn: $allTabs).toggleStyle(.switch)
                    .disabled(saving)
                    .onChange(of: allTabs) { _, enabled in
                        if !enabled {
                            selected.formIntersection(Set(workspace.tabs.first { $0.id == startingTabID }?.allPaneIDs ?? []))
                            saved = nil
                        }
                    }
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(candidates) { pane in
                        Button {
                            if selected.contains(pane.id) { selected.remove(pane.id) }
                            else if selected.count < 2 { selected.insert(pane.id) }
                            saved = nil; failure = nil
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: pane.kind.symbol)
                                    .font(.system(size: 17, weight: .medium)).frame(width: 28)
                                    .foregroundStyle(RelayTheme.textMuted)
                                Image(systemName: selected.contains(pane.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selected.contains(pane.id) ? RelayTheme.blue : RelayTheme.textFaint)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(pane.displayName).font(RelayTheme.font(size: 12, weight: .medium))
                                    Text(detail(pane)).font(RelayTheme.font(size: 11)).foregroundStyle(RelayTheme.textMuted)
                                        .lineLimit(1).truncationMode(.middle)
                                }
                                Spacer()
                                Text(pane.kind.label).font(RelayTheme.font(size: 11)).foregroundStyle(RelayTheme.textMuted)
                            }.padding(.vertical, 11).padding(.horizontal, 6).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(saving || (!selected.contains(pane.id) && selected.count == 2))
                        .accessibilityLabel(pane.displayName + (selected.contains(pane.id) ? ", selected" : ", not selected"))
                        .accessibilityIdentifier("relay.linking.pane." + pane.id.uuidString.lowercased())
                        Divider()
                    }
                    if candidates.isEmpty { Text("No matching panes.").foregroundStyle(RelayTheme.textMuted).padding(20) }
                }
            }
            if let saved {
                Label(saved.transport == "unavailable" ? "Link saved" : "Linked", systemImage: saved.transport == "unavailable" ? "link" : "checkmark.circle.fill")
                    .foregroundStyle(RelayTheme.mint)
                if saved.transport == "unavailable" {
                    Text("Messaging unavailable").font(RelayTheme.font(size: 12, weight: .medium)).foregroundStyle(.orange)
                    ForEach(saved.members.filter { $0.unavailable != nil }, id: \.paneID) { member in
                        Text((workspace.panes[member.paneID]?.displayName ?? member.name) + ": no verified messaging endpoint.")
                            .font(RelayTheme.font(size: 11)).foregroundStyle(RelayTheme.textMuted)
                    }
                    DisclosureGroup("Details") {
                        ForEach((saved.resolutionErrors ?? [:]).keys.sorted(), id: \.self) { key in
                            Text(saved.resolutionErrors?[key] ?? "").font(RelayTheme.font(size: 11)).textSelection(.enabled)
                        }
                    }
                } else {
                    Text("Both agents are ready to exchange messages.")
                        .font(RelayTheme.font(size: 11)).foregroundStyle(RelayTheme.textMuted)
                }
            }
            if let failure { Text(failure).font(RelayTheme.font(size: 12)).foregroundStyle(.orange).textSelection(.enabled) }
            HStack {
                Text("\(selected.count) of 2 panes selected").font(RelayTheme.font(size: 11)).foregroundStyle(RelayTheme.textMuted)
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button { save() } label: {
                    Label(saved == nil ? "Link panes" : "Refresh link", systemImage: saved == nil ? "link" : "arrow.clockwise")
                }
                    .buttonStyle(RelayPrimaryButtonStyle()).disabled(selected.count != 2 || saving)
                    .accessibilityIdentifier("relay.linking.save")
            }
        }
        .padding(20).frame(width: 520, height: allTabs ? 460 : 340)
        .background(RelayTheme.canvas)
        .task { await prepare() }
    }

    private func prepare() async {
        startingTabID = workspace.selectedTabID
        let ids = workspace.selectedTab?.allPaneIDs.filter { workspace.panes[$0]?.contentKind == .terminal } ?? []
        if ids.count == 2 { selected = Set(ids) }
        else if let active = workspace.activePaneID, ids.contains(active) { selected = [active] }
        let expected = selected
        guard expected.count == 2 else { return }
        do {
            let records = try await RelayPaneMessaging.shared.savedLinks(workspace: workspace)
            guard !Task.isCancelled, selected == expected, !saving else { return }
            for record in records where record["authority"] as? String == "relayd" {
                let link = try JSONDecoder().decode(RelayPaneMessaging.Link.self,
                    from: JSONSerialization.data(withJSONObject: record))
                if Set(link.members.map(\.paneID)) == expected { saved = link; return }
            }
        } catch {
            if !Task.isCancelled { failure = "The saved link could not be read. You can save this pair again." }
        }
    }

    private func detail(_ pane: PaneModel) -> String {
        let tab = workspace.tabs.first { $0.allPaneIDs.contains(pane.id) }
        return [tab.map { workspace.tabDisplayName($0, fallback: "Tab") },
                pane.profile.kind == .ssh ? pane.profile.host : "This Mac", pane.directory]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func save() {
        let ids = Array(selected)
        saving = true; failure = nil
        Task { @MainActor in
            defer { saving = false }
            do { saved = try await RelayPaneMessaging.shared.connect(panes: ids, workspace: workspace) }
            catch { failure = error.localizedDescription }
        }
    }
}
