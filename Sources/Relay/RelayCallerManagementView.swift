import SwiftUI
import AppKit

/// Native administration shares the HTTP server's store and never persists a
/// newly issued credential to disk, drafts or audit rows.
struct RelayCallerManagementView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var control = RelayCallerControl.shared
    @State private var label = ""
    @State private var thread = ""
    @State private var credential = ""
    @State private var issuedID = ""
    @State private var error: String?
    @State private var query = ""
    private var audit: [RelayCallerControl.Audit] {
        control.audit().reversed().filter {
            query.isEmpty || [control.label(for: $0.caller), $0.path, $0.operation ?? "", $0.outcome, $0.tabID ?? "", $0.paneID ?? "", $0.jobID ?? ""].joined(separator: " ").localizedCaseInsensitiveContains(query)
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Clients").font(.headline)
                Spacer()
                Button("Done") { credential = ""; dismiss() }
            }
            Text("Registered credentials identify a client. Thread labels are supplied by that client.")
                .font(RelayAgentDesign.meta).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.orange).font(RelayAgentDesign.meta) }
            if !control.available { Text("The client store could not be read. Changes are unavailable.").foregroundStyle(.orange) }
            List(control.summaries) { caller in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(caller.label).font(RelayAgentDesign.label)
                        Text(caller.id).font(RelayAgentDesign.mono).foregroundStyle(.secondary).textSelection(.enabled)
                        if let thread = caller.thread { Text("Claimed thread: " + thread).font(RelayAgentDesign.meta).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    Toggle("Paused", isOn: Binding(get: { caller.paused }, set: { value in
                        Task {
                            do { try await control.setPaused(id: caller.id, paused: value); error = nil }
                            catch { self.error = "The pause setting could not be applied to every communication server." }
                        }
                    })).toggleStyle(.switch).disabled(!control.available)
                        .accessibilityIdentifier("relay.callers.pause." + caller.id)
                }.padding(.vertical, 3)
            }.frame(minHeight: 100, maxHeight: 180)
            GroupBox("Individual credentials") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Create a credential for each client and update it before pausing shared access. Existing clients keep working until you pause them.")
                        .font(RelayAgentDesign.meta).foregroundStyle(.secondary)
                    HStack {
                        TextField("Client name", text: $label)
                        TextField("Thread label (optional)", text: $thread)
                        Button("Create credential") { create() }
                            .disabled(!control.available || !credential.isEmpty || label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || label.utf8.count > 120 || thread.utf8.count > 100)
                            .accessibilityIdentifier("relay.callers.create")
                    }
                    if !credential.isEmpty {
                        Text("Credential for " + issuedID).font(RelayAgentDesign.meta)
                        HStack {
                            SecureField("New credential", text: $credential).disabled(true)
                            Button("Copy credential") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(credential, forType: .string) }
                                .accessibilityIdentifier("relay.callers.copy")
                            Button("Dismiss credential") { credential = ""; issuedID = "" }
                        }
                        Text("Set RELAY_MCP_CALLER_TOKEN for this client's Relay MCP helper, or send X-Relay-Caller-Token with API requests. Copy it now; Relay stores only its hash.")
                            .font(RelayAgentDesign.meta).foregroundStyle(.secondary)
                    }
                }.padding(6)
            }
            HStack {
                Text("Recent activity").font(RelayAgentDesign.label)
                Spacer()
                TextField("Filter activity", text: $query).frame(width: 230)
            }
            List(audit, id: \.id) { entry in
                HStack(alignment: .top) {
                    Text(entry.at, format: .dateTime.hour().minute().second()).font(RelayAgentDesign.mono).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(control.label(for: entry.caller)).font(RelayAgentDesign.label)
                        Text([entry.path, entry.operation, entry.tabID.map { "Tab " + $0 }, entry.paneID.map { "Pane " + $0 }, entry.jobID.map { "Job " + $0 }].compactMap { $0 }.joined(separator: " · "))
                            .font(RelayAgentDesign.meta).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Spacer()
                    Text(entry.outcome).font(RelayAgentDesign.meta)
                }
            }.frame(minHeight: 120)
        }.padding(20).frame(width: 760, height: 650)
            .onDisappear { credential = ""; issuedID = "" }
            .task { await refreshClients() }
    }
    private func refreshClients() async {
        do { try await control.refreshDaemonPolicies() }
        catch { self.error = "Communication server client controls are unavailable." }
    }
    private func create() {
        Task {
        do {
            let result = try await control.register(label: label.trimmingCharacters(in: .whitespacesAndNewlines), thread: thread.isEmpty ? nil : thread)
            credential = result["caller_token"] ?? ""; issuedID = result["caller_id"] ?? ""
            label = ""; thread = ""; error = nil
        } catch { self.error = "The client credential could not be saved." }
        }
    }
}
