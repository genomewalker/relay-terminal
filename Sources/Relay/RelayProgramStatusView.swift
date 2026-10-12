import SwiftUI

struct RelayProgramStatusBadge: View {
    @ObservedObject var pane: PaneModel
    @State private var showingDetails = false
    @FocusState private var detailsFocused: Bool

    private var records: [RelayProgramStatusRecord] { pane.programStatus.records }
    private var current: Bool { pane.connectionState == .connected && pane.programStatus.revision != nil }
    private var primary: RelayProgramStatusRecord? { records.min { priority($0.state) < priority($1.state) } }
    private func priority(_ state: String) -> Int {
        ["blocked": 0, "error": 1, "working": 2, "done": 3, "idle": 4][state] ?? 5
    }
    private func label(_ state: String) -> String {
        ["idle": "Idle", "working": "Working", "blocked": "Waiting", "done": "Done", "error": "Failed"][state] ?? "Unknown"
    }
    private func symbol(_ state: String) -> String {
        ["idle": "circle", "working": "circle.dotted", "blocked": "hand.raised", "done": "checkmark.circle", "error": "exclamationmark.circle"][state] ?? "questionmark.circle"
    }
    private func color(_ state: String) -> Color {
        if !current { return RelayTheme.textFaint }
        switch state {
        case "blocked": return .orange
        case "error": return .red
        case "done": return .green
        default: return RelayTheme.accent
        }
    }

    var body: some View {
        if let primary {
            Button { showingDetails.toggle() } label: {
                Label(current ? label(primary.state) : "Status stale", systemImage: symbol(primary.state))
                    .font(RelayTheme.font(size: 9.5, weight: .medium))
                    .foregroundStyle(color(primary.state))
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .onChange(of: showingDetails) { _, presented in
                if !presented {
                    detailsFocused = false
                    // Finish the popover's key dispatch before returning input
                    // ownership to the terminal beneath it.
                    DispatchQueue.main.async {
                        if !showingDetails { pane.runtime.focus() }
                    }
                }
            }
            .help("Program-reported status from this pane. Open to inspect all tasks.")
            .accessibilityLabel("Program reported " + (current ? label(primary.state) : "stale status"))
            .popover(isPresented: $showingDetails, arrowEdge: .leading) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Program status").font(.headline)
                        Spacer()
                        Button { showingDetails = false } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Close program status")
                        .keyboardShortcut(.cancelAction)
                    }
                    Text(pane.displayName + " · " + pane.profile.name)
                        .font(.caption).foregroundStyle(.secondary)
                    if !current {
                        Text("The connection is unavailable. These are the last reported states.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(records, id: \.id) { record in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Label(label(record.state), systemImage: symbol(record.state))
                                            .foregroundStyle(color(record.state))
                                        Spacer()
                                        if let progress = record.progress {
                                            Text(String(progress) + "%").monospacedDigit()
                                        }
                                    }.font(.caption)
                                    Text(record.title ?? record.id ?? record.app ?? "Program")
                                        .font(.callout.weight(.medium))
                                    if let app = record.app {
                                        Text(app).font(.caption).foregroundStyle(.secondary)
                                    }
                                    if let message = record.message, !message.isEmpty {
                                        Text(message).font(.caption).textSelection(.enabled)
                                    }
                                    if record.state == "blocked", let kind = record.kind {
                                        Text(["permission": "Approval requested", "question": "Answer requested", "auth": "Authentication requested"][kind] ?? "Input requested")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    if let progress = record.progress {
                                        ProgressView(value: Double(progress), total: 100)
                                    }
                                }
                                .padding(.leading, CGFloat(min((record.id ?? "").filter { $0 == "/" }.count, 7)) * 8)
                            }
                        }
                    }.frame(maxHeight: 320)
                    Text("Reported by programs in this pane. Requests require their normal controls.")
                        .font(.caption2).foregroundStyle(.secondary)
                }.padding(16).frame(width: 330)
                    .focusable()
                    .focused($detailsFocused)
                    .onAppear { detailsFocused = true }
                    .onExitCommand { showingDetails = false }
            }
        }
    }
}
