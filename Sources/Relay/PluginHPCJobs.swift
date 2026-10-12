import SwiftUI

struct PluginHPCDetail: Codable, Sendable {
    let id: String
    let name: String
    let state: String
    let account: String
    let partition: String
    let directory: String
    let stdout: String
    let stderr: String
    var scheduler: String? = nil

    var summary: String {
        "Job \(id): \(name)\n\(state) · \(partition) · account \(account)\nDirectory: \(directory)\nstdout: \(stdout)\nstderr: \(stderr)" + (scheduler.map { "\n\nScheduler fields\n" + $0 } ?? "")
    }
}

struct PluginHPCJob: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let partition: String
    let name: String
    let state: String
    let elapsed: String
    let nodes: String
    let reason: String
    var username: String? = nil
    var cpus: String? = nil

    static func filtered(_ jobs: [Self], query: String, state: String) -> [Self] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return jobs.filter { job in
            (state.isEmpty || job.state == state) && words.allSatisfy { word in
                [job.id, job.partition, job.name, job.state, job.reason, job.username ?? ""].contains { $0.localizedCaseInsensitiveContains(word) }
            }
        }
    }
}

struct PluginHPCJobsView: View {
    let jobs: [PluginHPCJob]
    let total: Int
    let truncated: Bool
    var inspectJob: ((String) -> Void)? = nil
    var inspectLog: ((String) -> Void)? = nil
    @State private var query = ""
    @State private var state = ""
    @State private var user = ""

    private var filtered: [PluginHPCJob] { PluginHPCJob.filtered(jobs, query: query, state: state).filter { user.isEmpty || $0.username == user } }

    var body: some View {
        VStack(alignment: .leading, spacing: RelayTheme.spacing(14)) {
            HStack {
                TextField("Search jobs", text: $query)
                    .accessibilityIdentifier("hpc-job-search")
                Picker("State", selection: $state) {
                    Text("All states").tag("")
                    ForEach(Set(jobs.map(\.state)).union(state.isEmpty ? [] : [state]).sorted(), id: \.self) { Text($0).tag($0) }
                }.frame(width: 190).accessibilityIdentifier("hpc-state-filter")
            }
            Picker("User", selection: $user) {
                Text("All loaded users").tag("")
                ForEach(Set(jobs.compactMap(\.username)).union(user.isEmpty ? [] : [user]).sorted(), id: \.self) { Text($0).tag($0) }
            }.frame(maxWidth: 240).accessibilityIdentifier("hpc-user-filter")
            DisclosureGroup("Queue breakdown") {
                PluginHPCQueueOverview(jobs: filtered)
            }.font(RelayTheme.font(size: 11))
            Text("\(filtered.count) shown · \(jobs.count) loaded · \(total) in queue")
                .font(RelayTheme.font(size: 11)).foregroundStyle(RelayTheme.textMuted).accessibilityIdentifier("hpc-job-count")
            if truncated {
                Text("Only the first 500 jobs were loaded. Search and state filters apply to those jobs, not the whole queue.")
                    .font(.caption).foregroundStyle(RelayTheme.coral)
            }
            if jobs.isEmpty {
                Text("No jobs in this queue.").padding(.vertical, RelayTheme.spacing(20))
            } else if filtered.isEmpty {
                Text("No loaded jobs match these filters.").padding(.vertical, RelayTheme.spacing(20))
            } else {
                HStack {
                    Text("Job / name").frame(maxWidth: .infinity, alignment: .leading)
                    Text("State").frame(width: 85, alignment: .leading)
                    Text("Elapsed").frame(width: 65, alignment: .trailing)
                }.font(RelayTheme.font(size: 10, weight: .medium)).foregroundStyle(RelayTheme.textMuted)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: RelayTheme.spacing(0)) {
                        ForEach(filtered) { job in
                            Button {
                                inspectJob?(job.id)
                            } label: {
                                HStack(spacing: RelayTheme.spacing(10)) {
                                    VStack(alignment: .leading, spacing: RelayTheme.spacing(3)) {
                                        Text(job.name).font(RelayTheme.font(size: 12, weight: .medium)).foregroundStyle(RelayTheme.text).lineLimit(1)
                                        Text("\(job.id) · \(job.username ?? "") · \(job.partition) · \(job.cpus ?? "?") CPUs")
                                            .font(RelayTheme.font(size: 10, design: .monospaced)).foregroundStyle(RelayTheme.textMuted).lineLimit(1)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                    Text(job.state).font(RelayTheme.font(size: 10, weight: .medium))
                                        .foregroundStyle(job.state == "RUNNING" ? RelayTheme.accent : RelayTheme.textMuted)
                                        .frame(width: 85, alignment: .leading)
                                    Text(job.elapsed).font(RelayTheme.font(size: 10, design: .monospaced)).foregroundStyle(RelayTheme.textMuted)
                                        .frame(width: 65, alignment: .trailing)
                                    if let inspectLog {
                                        Button { inspectLog(job.id) } label: { Image(systemName: "doc.text") }
                                            .accessibilityLabel("Logs for job \(job.id)")
                                    }
                                }.padding(.vertical, RelayTheme.spacing(8)).contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityLabel("Details for job \(job.id)")
                            Rectangle().fill(RelayTheme.line.opacity(0.55)).frame(height: 1)
                        }
                    }
                }
            }
        }
    }
}
