import SwiftUI

struct RelayRecoveryView: View {
    @ObservedObject var workspace: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var busy: UUID?
    @State private var failure: String?

    private var entries: [ClosedPaneRecovery] {
        workspace.recoveryEntries.filter {
            query.isEmpty || "\($0.tab.name) \($0.pane.customName ?? "") \($0.pane.directory ?? "") \($0.pane.profile.name)"
                .localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Restore").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("Reopen a terminal, or resume its saved conversation in the original folder.")
                .foregroundStyle(.secondary)
            TextField("Search by tab, host, or folder", text: $query)
                .textFieldStyle(.roundedBorder)
            if let failure {
                Text(failure).foregroundStyle(.red).textSelection(.enabled)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !workspace.exitedRecoveryPanes.isEmpty {
                        Text("Exited terminals").font(.headline)
                        ForEach(workspace.exitedRecoveryPanes, id: \.id) { pane in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(pane.customName ?? pane.profile.name).font(.headline)
                                Text(pane.directory ?? "Folder unavailable").font(.caption).foregroundStyle(.secondary)
                                HStack {
                                    Button("Resume conversation") { workspace.requestResumeSavedConversation(pane.id) }
                                        .disabled(pane.profile.backend != .relay || workspace.recoveringConversationPaneIDs.contains(pane.id))
                                    Button("Open shell") {
                                        var profile = pane.profile
                                        profile.command = ""
                                        workspace.restartExitedPane(pane.id, profile: profile, directory: pane.directory)
                                    }.disabled(pane.profile.backend != .relay)
                                }
                            }
                        }
                    }
                    Text("Closed panes").font(.headline)
                    if entries.isEmpty {
                        Text("No closed panes match. Detached terminals are also available in Remote → Connect to host.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(entries) { entry in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(entry.pane.customName ?? entry.tab.name).font(.headline)
                                Spacer()
                                Text(entry.closedAt, style: .date).font(.caption).foregroundStyle(.secondary)
                            }
                            Text("\(entry.pane.profile.name) · \(entry.tab.name)").font(.caption)
                            Text(entry.pane.directory ?? "Folder unavailable")
                                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            HStack {
                                Button("Reopen pane") { workspace.reopenRecoveryEntry(entry); dismiss() }
                                if entry.pane.profile.backend == .relay && entry.pane.contentKind == .terminal {
                                    Button("Resume conversation") {
                                        busy = entry.id; failure = nil
                                        Task { @MainActor in
                                            defer { busy = nil }
                                            do { try await workspace.resumeRecoveryEntry(entry); dismiss() }
                                            catch { failure = error.localizedDescription }
                                        }
                                    }
                                }
                                if busy == entry.id { ProgressView().controlSize(.small) }
                            }.disabled(busy != nil)
                        }
                        Divider()
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(24)
        .frame(minWidth: 620, idealWidth: 720, minHeight: 460, idealHeight: 620)
    }
}
