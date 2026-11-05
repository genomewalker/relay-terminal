import SwiftUI

/// Presents only signalable direct children of the exact observed provider.
/// Choosing a row is not authorization: the host must then produce the full
/// immutable preview and the user must review and run that specific card.
struct RelayAccountForcePicker: View {
    private struct Process: Decodable, Identifiable {
        let pid, parentPID: Int
        let paneID: String?
        let name: String
        let canSignal: Bool
        var id: Int { pid }
        enum CodingKeys: String, CodingKey {
            case pid, name
            case parentPID = "parent_pid", paneID = "pane_id", canSignal = "can_signal"
        }
    }
    private struct Inventory: Decodable { let processes: [Process] }

    let pane: PaneModel
    let target: RelayAgentAccount
    let context: RelayExecutionContext
    let permits: @MainActor @Sendable () -> Bool
    let close: () -> Void
    @State private var candidates: [Process] = []
    @State private var observed: RelayAgentMaintenanceProbe?
    @State private var selected: RelayAccountForceSelection?
    @State private var destinationKey: String?
    @State private var destinationName = ""
    @State private var status = "Checking the pane and its processes"
    @State private var loading = true

    var body: some View {
        Group {
            if let selected, let destinationKey {
                let capturedPane = pane
                let capturedTarget = target
                let capturedContext = context
                let capturedPermits = permits
                RelayAccountForcePanel(pane: pane, context: context, selection: selected,
                    destination: destinationName, permits: permits, revalidateDestination: {
                        await Self.revalidate(pane: capturedPane, target: capturedTarget, context: capturedContext,
                                              selection: selected, key: destinationKey, permits: capturedPermits)
                    }, close: close)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Choose a process to review").font(.headline)
                    Text("Moving to \(target.label) requires Relay to check the same conversation and remaining work after any process stops.")
                    if loading { ProgressView() }
                    Text(status).foregroundStyle(.secondary)
                    if !candidates.isEmpty {
                        ScrollView {
                            VStack(alignment: .leading) {
                                ForEach(candidates) { process in
                                    Button("Review PID \(process.pid) · \(RelayAccountForcePreview.quoted(process.name))") {
                                        select(process)
                                    }
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(minHeight: 120, idealHeight: 240)
                    }
                    HStack { Spacer(); Button("Cancel", action: close) }
                }.padding(24).frame(minWidth: 520, idealWidth: 680)
                .task { await load() }
            }
        }
    }

    private func load() async {
        guard permits(), pane.profile == context.profile, target.isValid else { status = "The pane or permission changed."; loading = false; return }
        let revision = pane.agentInputRevision
        do {
            let accounts = try await RelayAgentAccountDirectory.shared.refresh(context.profile, probe: true)
            guard let destination = Self.checkedDestination(accounts, target: target),
                  let key = destination.workspaceKey, !key.isEmpty else {
                status = "The target account's current workspace could not be verified."; loading = false; return
            }
            let proof = try await RelayAgentAccountMove.shared.inspect(pane, target, nil)
            guard proof.valid(for: pane.id), proof.provider == target.provider, proof.moveCommand != nil,
                  let pid = proof.processID, pane.profile == context.profile,
                  pane.agentInputRevision == revision, permits() else {
                status = proof.moveError ?? "The target account or conversation could not be verified."; loading = false; return
            }
            let result = try await RelayHostFiles.request(context: context, fields: ["operation": "process_list"])
            let data = try JSONSerialization.data(withJSONObject: result)
            guard data.count <= 2 << 20, pane.profile == context.profile, pane.agentInputRevision == revision, permits() else {
                status = "The pane changed while Relay checked its processes."; loading = false; return
            }
            let inventory = try JSONDecoder().decode(Inventory.self, from: data)
            candidates = inventory.processes.filter {
                $0.parentPID == pid && $0.canSignal && UUID(uuidString: $0.paneID ?? "") == pane.id
            }.sorted { $0.pid < $1.pid }
            observed = proof
            destinationKey = key
            destinationName = target.label + " · " + (destination.workspace ?? "workspace #" + String(key.prefix(4)))
            status = candidates.isEmpty ? "No signalable direct child was found for this pane." : "Choose one child. Relay will show its full arguments before any signal."
        } catch { status = "Relay could not verify the pane and its processes." }
        loading = false
    }

    static func checkedDestination(_ accounts: [RelayAgentAccountStatus], target: RelayAgentAccount) -> RelayAgentAccountStatus? {
        guard let value = accounts.first(where: { $0.account == target }), value.exists,
              value.loggedIn == "yes", value.probe == "ok", let key = value.workspaceKey, !key.isEmpty else { return nil }
        if let expected = value.expectKey, !expected.isEmpty, expected != key { return nil }
        if let expected = value.expectWorkspace, !expected.isEmpty {
            guard let name = value.workspace,
                  name.compare(expected, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame else { return nil }
        }
        return value
    }

    @MainActor private static func revalidate(pane: PaneModel, target: RelayAgentAccount, context: RelayExecutionContext,
                                              selection: RelayAccountForceSelection, key: String,
                                              permits: @MainActor @Sendable () -> Bool) async -> Bool {
        guard permits(), pane.id == selection.paneID, pane.profile == context.profile else { return false }
        do {
            let accounts = try await RelayAgentAccountDirectory.shared.refresh(context.profile, probe: true)
            guard checkedDestination(accounts, target: target)?.workspaceKey == key else { return false }
            let proof = try await RelayAgentAccountMove.shared.inspect(pane, target, nil)
            return permits() && pane.profile == context.profile && proof.valid(for: pane.id) &&
                proof.provider == selection.provider && proof.sessionID == selection.sessionID &&
                proof.processID == selection.providerPID && proof.processStart.map(String.init) == selection.providerStart &&
                proof.moveCommand != nil && !Task.isCancelled
        } catch { return false }
    }

    private func select(_ process: Process) {
        guard permits(), let proof = observed, proof.valid(for: pane.id), let provider = proof.provider,
              let session = proof.sessionID, let pid = proof.processID, let start = proof.processStart,
              process.parentPID == pid, process.canSignal else { return }
        selected = RelayAccountForceSelection(paneID: pane.id, provider: provider, sessionID: session,
            providerPID: pid, providerStart: String(start), blockerPID: process.pid, blockerStart: "")
    }
}
