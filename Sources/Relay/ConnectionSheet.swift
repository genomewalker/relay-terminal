import SwiftUI

struct ConnectionSheet: View {
    @ObservedObject var workspace: WorkspaceModel
    @State private var saveProfile = true

    private var profile: Binding<ConnectionProfile> { $workspace.draftProfile }
    private var isValid: Bool {
        workspace.draftProfile.kind == .local || !workspace.draftProfile.host.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Open a session")
                        .font(.system(size: 19, weight: .semibold))
                    Text("The terminal runs there. The workspace stays here.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(RelayTheme.textMuted)
                }
                Spacer()
                Image(systemName: "terminal")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(RelayTheme.textMuted)
            }
            .padding(22)

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
                            .font(.system(size: 10.5))
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
            .padding(.horizontal, 10)

            Divider().overlay(RelayTheme.line.opacity(0.45))

            HStack {
                Text("Uses ~/.ssh/config, keys, agents, ProxyJump, and known_hosts.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(RelayTheme.textMuted)
                Spacer()
                Button("Cancel") { workspace.isConnectionSheetPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Connect") { workspace.connectDraft(saveProfile: saveProfile) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
                    .buttonStyle(.borderedProminent)
                    .tint(RelayTheme.accent)
                    .foregroundStyle(RelayTheme.canvas)
            }
            .padding(16)
        }
        .frame(width: 520, height: workspace.draftProfile.kind == .ssh ? 470 : 340)
        .background(RelayTheme.sidebar)
        .preferredColorScheme(.dark)
    }
}
