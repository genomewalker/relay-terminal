import SwiftUI

struct RelayHostRotationButton: View {
    @ObservedObject var workspace: WorkspaceModel
    @State private var presented = false
    var body: some View {
        RelayIconAction("Context management", symbol: "arrow.triangle.2.circlepath") { presented = true }
            .accessibilityIdentifier("relay.tools.context-management")
            .popover(isPresented: $presented) {
                if let pane = workspace.activePane, pane.contentKind == .terminal {
                    RelayHostRotationPanel(pane: pane).id(pane.id)
                } else {
                    Text("Select a terminal pane to manage its context.")
                        .padding(RelayTheme.spacing(18)).frame(width: 360)
                }
            }
    }
}

private struct RelayHostRotationPanel: View {
    @ObservedObject var pane: PaneModel
    @Environment(\.openSettings) private var openSettings
    @State private var status: RelayHostRotationRPC.Status?
    @State private var textStatus: RelayHostRotationTextRPC.Status?
    @State private var credentials: [RelayHostRotationTextRPC.CredentialRecord]?
    @State private var busy = false
    @State private var needsStatus = false
    @State private var error: String?

    private var hostName: String { pane.profile.kind == .local ? "This Mac" : pane.profile.host }
    private var canChange: Bool {
        !busy && !needsStatus && status != nil && status?.isUnsupported != true && pane.runtime.canConfigureHostRotation
    }
    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: RelayTheme.spacing(12)) {
            HStack {
                Text("Context management").font(.headline)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
            }
            Text(hostName).font(.caption).foregroundStyle(.secondary)
            if status != nil || textStatus != nil {
              // "last N min ago" needs its own clock; the panel otherwise
              // redraws only when the pane or a status read changes.
              TimelineView(.periodic(from: .now, by: 30)) { context in
                let summary = RelayContextManagementSummary(rotation: status, text: textStatus, credentials: credentials,
                                                            now: context.date)
                VStack(alignment: .leading, spacing: RelayTheme.spacing(4)) {
                    ForEach(Array([summary.handoffText, summary.enrollment, summary.completedTurns].enumerated()), id: \.offset) { _, check in
                        Label(check.text, systemImage: check.isOK ? "checkmark.circle.fill" :
                                (check.isUnknown ? "questionmark.circle" : "exclamationmark.circle"))
                            .font(.caption)
                            .foregroundStyle(check.isOK ? Color.green : (check.isUnknown ? Color.secondary : Color.orange))
                    }
                    if let next = summary.nextStep {
                        Text(next).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(summary.line)
                .accessibilityIdentifier("relay.context-management.summary")
              }
            }
            if let status {
                Text(status.title).font(.subheadline.weight(.semibold))
                if status.isUnsupported {
                    Text("Update this host's Relay helper to use context management.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    if let enrollment = status.enrollment, enrollment.valid(for: pane.id) {
                        Text(enrollment.client == "codex" ? "Codex" : "Claude Code")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(enrollment.cwd).font(.caption).textSelection(.enabled)
                            .lineLimit(2).truncationMode(.middle)
                    }
                    Text("The host monitors completed turns. Typing in the terminal pauses automatic management.")
                        .font(.caption).foregroundStyle(.secondary)
                    if status.lifecycle == "unavailable" {
                        Text("Native context rotation is not available for this session.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if status.refreshCapability != "supported" {
                        Text("Prompt-cache refresh is not verified for this session.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let milliseconds = status.nextEvaluationMS, milliseconds > 0 {
                        Text("Next check: \(Date(timeIntervalSince1970: Double(milliseconds) / 1000).formatted(date: .omitted, time: .standard))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let hint = status.preparation?.hint {
                        Text(hint).font(.caption).foregroundStyle(.orange)
                    }
                    if status.nativeRecoveryState != nil || status.state.contains("failed") ||
                        status.state.contains("unavailable") || status.state.contains("invalid") {
                        Text("Keep the original session open. Read status after recovery; a pending operation must finish before enrollment can change.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else if !busy {
                Text("Read the host's current status to continue.").font(.caption).foregroundStyle(.secondary)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    .accessibilityIdentifier("relay.context-management.error")
            }
            HStack {
                Button("Read status") { Task { await refresh() } }.disabled(busy)
                    .accessibilityIdentifier("relay.context-management.refresh")
                Spacer()
                if status?.enabled == true {
                    Button("Pause") { Task { await configure(enabled: false) } }.disabled(!canChange)
                        .accessibilityIdentifier("relay.context-management.disable")
                } else {
                    Button("Enable") { Task { await configure(enabled: true) } }.disabled(!canChange)
                        .accessibilityIdentifier("relay.context-management.enroll")
                }
            }
            if !pane.runtime.canConfigureHostRotation && pane.profile.backend == .relay {
                Text("Connect and take terminal control to change this setting.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            Button("Manage accounts in Settings…") {
                RelaySettingsNavigation.shared.showAccounts(profile: pane.profile)
                openSettings()
            }
            .accessibilityIdentifier("relay.context-management.open-account-settings")
            Text("Accounts are shared by every tab on this host. Session rotation controls apply to this session.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(RelayTheme.spacing(18))
        }
        .frame(width: 430).frame(maxHeight: 680)
        .task { await refresh() }
    }

    @MainActor private func refresh() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let result = try await pane.runtime.readHostRotationStatus()
            status = result; error = nil; needsStatus = false
        } catch {
            status = nil; self.error = error.localizedDescription
        }
        // Read-only host checks for the summary; a failure leaves them unknown.
        let accounts = RelayHostAccountsService(profile: pane.profile)
        if accounts.canManageAccounts {
            textStatus = try? await accounts.readHostRotationTextStatus()
            credentials = try? await accounts.readHostRotationCredentials()
        } else {
            textStatus = nil; credentials = nil
        }
    }

    @MainActor private func configure(enabled: Bool) async {
        guard canChange else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            status = try await pane.runtime.configureHostRotation(enabled: enabled)
            needsStatus = false
        } catch {
            // No retry or implicit reenrollment after an uncertain response.
            needsStatus = true
            self.error = error.localizedDescription
        }
    }
}
