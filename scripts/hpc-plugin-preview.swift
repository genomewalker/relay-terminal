// Compile with Sources/Relay/PluginHPCJobs.swift to manually exercise the real
// native component without starting Relay or touching a saved workspace.
import SwiftUI

@main
struct HPCPluginPreview: App {
    var body: some Scene {
        WindowGroup("Relay HPC acceptance") {
            HPCPreviewContent().frame(minWidth: 720, minHeight: 480)
        }
    }
}

struct HPCPreviewContent: View {
    @State private var example = "normal"
    private var jobs: [PluginHPCJob] {
        if example == "empty" { return [] }
        let count: Int = example == "large" ? 500 : 3
        return (0..<count).map { index -> PluginHPCJob in
            let running = index % 2 == 0
            return PluginHPCJob(id: String(1200 + index), partition: running ? "batch" : "gpu",
                name: running ? "assembly 🧬" : "train model", state: running ? "RUNNING" : "PENDING",
                elapsed: "2:04", nodes: "1", reason: running ? "compute-node" : "(Resources)")
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("HPC jobs · isolated acceptance preview").font(.title2)
            Text("Synthetic data only. No Relay workspace, agents or remote jobs are changed.").foregroundStyle(.secondary)
            Picker("Example", selection: $example) {
                Text("Normal").tag("normal")
                Text("Empty").tag("empty")
                Text("Large queue").tag("large")
            }.pickerStyle(.segmented)
                PluginHPCJobsView(jobs: jobs, total: example == "large" ? 1500 : jobs.count, truncated: example == "large")
                    .id(example)
        }.padding(20)
    }
}
