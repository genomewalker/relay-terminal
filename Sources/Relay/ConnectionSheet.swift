import SwiftUI

struct ConnectionSheet: View {
    @ObservedObject var workspace: WorkspaceModel
    @State private var saveProfile = true

    private var profile: Binding<ConnectionProfile> { $workspace.draftProfile }
    private var isValid: Bool {
        workspace.draftProfile.kind == .local || !workspace.draftProfile.host.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: RelayTheme.spacing(0)) {
            HStack {
                VStack(alignment: .leading, spacing: RelayTheme.spacing(4)) {
                    Text("Open a session")
                        .font(RelayTheme.font(size: 13, weight: .medium))
                    Text("Choose where to open your terminal.")
                        .font(RelayTheme.font(size: 12.5))
                        .foregroundStyle(RelayTheme.textMuted)
                }
                Spacer()
                Image(systemName: "terminal")
                    .font(RelayTheme.font(size: 18, weight: .medium))
                    .foregroundStyle(RelayTheme.textMuted)
            }
            .padding(RelayTheme.spacing(20))

            Divider().overlay(RelayTheme.line.opacity(0.45))

            Form {
                Picker("Session", selection: profile.kind) {
                    Text("SSH host").tag(ConnectionKind.ssh)
                    Text("This Mac").tag(ConnectionKind.local)
                }
                .pickerStyle(.segmented)

                TextField("Name", text: profile.name, prompt: Text("HPC cluster"))

                if workspace.draftProfile.kind == .ssh {
                    TextField("Host", text: profile.host, prompt: Text("login.cluster.edu"))
                    TextField("User", text: profile.user, prompt: Text(NSUserName()))
                    TextField("Port", value: profile.port, format: .number)
                    Picker("Session", selection: profile.backend) {
                        ForEach(RemoteSessionBackend.allCases) { backend in
                            Text(backend.label).tag(backend)
                        }
                    }
                    TextField("Start command", text: profile.command, prompt: Text("Optional: cd /work && claude"))
                    if workspace.draftProfile.backend == .relay {
                        Text("The remote shell survives disconnects and reattaches to this native pane. Requires relayd in ~/.local/bin on the host.")
                            .font(RelayTheme.font(size: 11))
                            .foregroundStyle(RelayTheme.textMuted)
                    }
                    Toggle("Save this host", isOn: $saveProfile)
                } else {
                    Text("Relay will open your default login shell.")
                        .foregroundStyle(RelayTheme.textMuted)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, RelayTheme.spacing(10))

            Divider().overlay(RelayTheme.line.opacity(0.45))

            HStack {
                Text("Uses ~/.ssh/config, keys, agents, ProxyJump, and known_hosts.")
                    .font(RelayTheme.font(size: 11))
                    .foregroundStyle(RelayTheme.textMuted)
                Spacer()
                Button("Cancel") { workspace.isConnectionSheetPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Connect") { workspace.connectDraft(saveProfile: saveProfile) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
                    .buttonStyle(RelayPrimaryButtonStyle())
                    .tint(RelayTheme.accent)
                    .foregroundStyle(RelayTheme.canvas)
            }
            .padding(RelayTheme.spacing(16))
        }
        .frame(width: 520, height: workspace.draftProfile.kind == .ssh ? 520 : 340)
        .background(RelayTheme.surface)
        .relaySurface()
    }
}
