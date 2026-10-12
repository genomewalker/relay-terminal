import SwiftUI

struct PluginHPCQueueOverview: View {
    let jobs: [PluginHPCJob]

    private var states: [(String, Int)] {
        Dictionary(grouping: jobs, by: \.state).map { ($0.key, $0.value.count) }
            .sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
    }
    private var allocations: [(String, Int)] {
        Dictionary(grouping: jobs.filter { $0.state == "RUNNING" }, by: { $0.username ?? "Unknown" })
            .map { ($0.key, $0.value.reduce(0) { $0 + (Int($1.cpus ?? "") ?? 0) }) }
            .sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
    }

    var body: some View {
        HStack(alignment: .top, spacing: RelayTheme.spacing(20)) {
            bars(title: "Jobs by state", values: states, color: RelayTheme.accent)
            bars(title: "Running CPUs by user", values: allocations, color: RelayTheme.accent)
        }.padding(RelayTheme.spacing(12)).background(RelayTheme.line.opacity(0.25), in: RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(8)))
    }

    private func bars(title: String, values: [(String, Int)], color: Color) -> some View {
        VStack(alignment: .leading, spacing: RelayTheme.spacing(6)) {
            Text(title).font(RelayTheme.font(size: 11, weight: .medium))
            if values.isEmpty { Text("No running allocations").font(.caption).foregroundStyle(RelayTheme.textMuted) }
            ForEach(Array(values.prefix(4).enumerated()), id: \.offset) { _, value in
                HStack(spacing: RelayTheme.spacing(6)) {
                    Text(value.0).lineLimit(1).frame(width: 78, alignment: .leading)
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(RelayTheme.textMuted.opacity(0.10))
                            Capsule().fill(color.opacity(0.55))
                                .frame(width: geometry.size.width * CGFloat(value.1) / CGFloat(max(1, values.first?.1 ?? 1)))
                        }
                    }.frame(height: 3)
                    Text("\(value.1)").monospacedDigit().frame(width: 36, alignment: .trailing)
                }.font(RelayTheme.font(size: 10)).foregroundStyle(RelayTheme.textMuted)
            }
            if values.count > 4 { Text("Top 4 of \(values.count)").font(RelayTheme.font(size: 9)).foregroundStyle(RelayTheme.textMuted) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
