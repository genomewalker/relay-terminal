import AppKit
import SwiftUI

struct RelayExecutionContext: Codable, Equatable, Sendable {
    let profile: ConnectionProfile
    let directory: String
    var host: String { profile.kind == .local ? "This Mac" : profile.host }
}

extension WorkspaceModel {
    /// Capture a live remote directory before dispatch. Explicit bindings remain
    /// immutable, and a tab/pane change while observing invalidates this capture.
    func captureExecutionContext(tabID: UUID) async throws -> RelayExecutionContext {
        guard let tab = tabs.first(where: { $0.id == tabID }),
              let initial = executionContext(tabID: tabID) else { throw RelayHostRPCError.invalidRequest }
        if tab.executionContext != nil || initial.profile.kind != .ssh || initial.profile.backend != .relay {
            return initial
        }
        func followedPaneID() -> UUID? {
            activePane.flatMap { tab.allPaneIDs.contains($0.id) ? $0.id : nil }
                ?? tab.allPaneIDs.first
        }
        guard let paneID = followedPaneID(), let pane = panes[paneID], pane.contentKind == .terminal else {
            return initial
        }
        let command = RelayHostExecution.daemonCommand(profile: initial.profile,
            arguments: ["files", "workspace", "--parent-session", paneID.uuidString.lowercased()])
        let observed = try await RelayHostExecution.capture(profile: initial.profile, command: command,
            timeout: 12, maximumBytes: 8192, directory: "/")
        struct Directory: Decodable { let path: String }
        guard observed.exitCode == 0,
              let directory = try? JSONDecoder().decode(Directory.self, from: observed.stdout),
              directory.path.hasPrefix("/"), !directory.path.contains("\0"), directory.path.utf8.count <= 4096,
              tabs.contains(where: { $0 === tab && $0.executionContext == nil }),
              followedPaneID() == paneID, panes[paneID] === pane, pane.profile == initial.profile else {
            throw RelayHostRPCError.invalidRequest
        }
        pane.directory = directory.path
        return RelayExecutionContext(profile: initial.profile, directory: directory.path)
    }

    func executionContext(tabID: UUID? = nil) -> RelayExecutionContext? {
        guard let tab = tabID.flatMap({ id in tabs.first { $0.id == id } }) ?? selectedTab else { return nil }
        if let bound = tab.executionContext { return bound }
        let pane = activePane.flatMap { tab.allPaneIDs.contains($0.id) ? $0 : nil }
            ?? tab.allPaneIDs.compactMap { panes[$0] }.first
        return pane.map { RelayExecutionContext(profile: $0.profile, directory: $0.directory ?? "/") }
    }

    func bindExecutionContext(_ context: RelayExecutionContext?, tabID: UUID) throws {
        guard let tab = tabs.first(where: { $0.id == tabID }),
              context == nil || (context!.directory.hasPrefix("/") && !context!.directory.contains("\0") && context!.directory.utf8.count <= 4096) else {
            throw RelayHostRPCError.invalidRequest
        }
        tab.executionContext = context
        objectWillChange.send()
        persistRPresentation()
    }
}

struct RelayExecutionContextButton: View {
    @ObservedObject var workspace: WorkspaceModel
    @State private var presenting = false
    @State private var host = "This Mac"
    @State private var directory = "/"
    @State private var followPane = true
    @State private var error: String?
    private var profiles: [ConnectionProfile] {
        [.local] + workspace.profileStore.connectableHosts.filter { $0.kind == .ssh && $0.backend == .relay }
    }
    private var contextHelp: String {
        guard let context = workspace.executionContext() else {
            return "Workspace execution context · select a workspace"
        }
        return "Workspace execution context · \(context.host) · \(context.directory)"
    }
    var body: some View {
        RelayIconAction(contextHelp, symbol: "scope") { presenting = true }
        .accessibilityLabel("Workspace execution context")
        .accessibilityIdentifier("relay.tools.execution-context")
        .popover(isPresented: $presenting) {
            VStack(alignment: .leading, spacing: RelayTheme.spacing(12)) {
                Text("Workspace execution context").font(.headline)
                Toggle("Follow the active pane", isOn: $followPane)
                Picker("Host", selection: $host) {
                    ForEach(profiles) { profile in
                        Text(profile.kind == .local ? "This Mac" : profile.host).tag(profile.kind == .local ? "This Mac" : profile.host)
                    }
                }.disabled(followPane)
                TextField("Absolute working directory", text: $directory).disabled(followPane)
                Text("Commands, files and images use this context. Running operations keep their captured host.")
                    .font(.caption).foregroundStyle(.secondary)
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
                HStack {
                    Button("Cancel") { presenting = false }
                    Spacer()
                    Button("Apply") {
                        do {
                            guard let tab = workspace.selectedTab else { return }
                            let profile = profiles.first { ($0.kind == .local ? "This Mac" : $0.host) == host }
                            guard followPane || profile != nil else { throw RelayHostRPCError.invalidRequest }
                            try workspace.bindExecutionContext(followPane ? nil : RelayExecutionContext(profile: profile!, directory: directory), tabID: tab.id)
                            presenting = false
                        } catch { self.error = error.localizedDescription }
                    }
                }
            }.padding(RelayTheme.spacing(18)).frame(width: 390)
            .onAppear {
                workspace.profileStore.refreshSSHConfig()
                let context = workspace.executionContext()
                host = context?.host ?? "This Mac"; directory = context?.directory ?? "/"
                followPane = workspace.selectedTab?.executionContext == nil
            }
            .onChange(of: host) { old, new in if old != new { directory = "/" } }
        }
    }
}
