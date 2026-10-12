import SwiftUI

struct PluginHPCAccountingView: View {
    let records: [[String]]
    let summary: String
    let inspect: (String) -> Void
    @State private var query = ""
    private var filtered: [[String]] {
        records.filter { $0.count == 19 && !$0[0].contains(".") && (query.isEmpty || [$0[0], $0[2], $0[3], $0[4]].contains { $0.localizedCaseInsensitiveContains(query) }) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: RelayTheme.spacing(10)) {
            HStack {
                Text("History · past 24 hours").font(RelayTheme.font(size: 13, weight: .medium))
                Spacer()
                TextField("Search jobs", text: $query).textFieldStyle(.roundedBorder).frame(width: 200)
            }
            HStack {
                Text("JOB").frame(width: 100, alignment: .leading)
                Text("NAME").frame(maxWidth: .infinity, alignment: .leading)
                Text("STATE").frame(width: 110, alignment: .leading)
                Text("ELAPSED").frame(width: 75, alignment: .trailing)
            }.font(RelayTheme.font(size: 10, weight: .medium)).foregroundStyle(RelayTheme.textMuted)
            ScrollView {
                LazyVStack(spacing: RelayTheme.spacing(0)) {
                    ForEach(Array(filtered.enumerated()), id: \.offset) { _, row in
                        Button { inspect(row[0]) } label: {
                            HStack(spacing: RelayTheme.spacing(8)) {
                                Text(row[0]).font(RelayTheme.font(size: 11, design: .monospaced)).frame(width: 100, alignment: .leading)
                                Text(row[2]).frame(maxWidth: .infinity, alignment: .leading)
                                Text(row[3]).foregroundStyle(RelayTheme.textMuted).frame(width: 110, alignment: .leading)
                                Text(PluginHPCStatisticsView.duration(row[5])).monospacedDigit().frame(width: 75, alignment: .trailing)
                            }.font(RelayTheme.font(size: 11)).lineLimit(1).padding(.vertical, RelayTheme.spacing(8))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        Rectangle().fill(RelayTheme.line).frame(height: 1)
                    }
                }
            }
            Text(summary).font(RelayTheme.font(size: 10)).foregroundStyle(RelayTheme.textMuted)
                .lineLimit(4).textSelection(.enabled)
        }
    }
}

struct PluginHPCStatisticsView: View {
    let records: [[String]]
    static func duration(_ value: String) -> String {
        guard let seconds = Int(value) else { return "—" }
        return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }
    var body: some View {
        LazyVStack(alignment: .leading, spacing: RelayTheme.spacing(12)) {
            ForEach(Array(records.filter { $0.count == 19 }.enumerated()), id: \.offset) { _, r in
                VStack(alignment: .leading, spacing: RelayTheme.spacing(6)) {
                    Text(r[0].contains(".") ? "Step \(r[0])" : "Allocation \(r[0])").font(RelayTheme.font(size: 12, weight: .medium))
                    ForEach(Array(Array(zip(["State", "Elapsed", "CPUs / nodes", "CPU used", "Allocated CPU time", "Requested memory", "Peak memory / task", "Exit code", "Start", "End", "Account", "Requested resources", "Allocated resources"], [r[3], Self.duration(r[5]), r[6] + " / " + r[7], r[8], Self.duration(r[9]), r[10], r[11], r[12], r[14], r[15], r[16], r[17], r[18]])).enumerated()), id: \.offset) { _, pair in
                        HStack(alignment: .top) {
                            Text(pair.0).foregroundStyle(RelayTheme.textMuted).frame(width: 125, alignment: .leading)
                            Text(pair.1.isEmpty ? "—" : pair.1).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                        }.font(RelayTheme.font(size: 11))
                    }
                }
                Rectangle().fill(RelayTheme.line).frame(height: 1)
            }
            Text("Peak memory is the maximum for one task. A blank measurement is unavailable, not zero.")
                .font(RelayTheme.font(size: 10)).foregroundStyle(RelayTheme.textMuted)
        }
    }
}

struct PluginHPCDetailView: View {
    let detail: PluginHPCDetail
    private var fields: [(String, String)] {
        guard let raw = detail.scheduler?.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else { return [] }
        return object.keys.sorted().map { key in
            let value = object[key]!
            let text: String
            if let string = value as? String { text = string }
            else if let bytes = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]) { text = String(decoding: bytes, as: UTF8.self) }
            else { text = String(describing: value) }
            return (key.replacingOccurrences(of: "_", with: " "), text)
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: RelayTheme.spacing(8)) {
            Text(detail.name).font(RelayTheme.font(size: 13, weight: .medium)).textSelection(.enabled)
            Text("\(detail.state) · \(detail.partition)").font(RelayTheme.font(size: 11)).foregroundStyle(RelayTheme.textMuted)
            ForEach(Array(fields.enumerated()), id: \.offset) { _, field in
                VStack(alignment: .leading, spacing: RelayTheme.spacing(2)) {
                    Text(field.0).foregroundStyle(RelayTheme.textMuted)
                    Text(field.1.isEmpty ? "—" : field.1).textSelection(.enabled)
                }.font(RelayTheme.font(size: 11))
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
