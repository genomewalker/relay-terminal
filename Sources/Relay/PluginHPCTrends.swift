import SwiftUI

struct PluginHPCCluster: Decodable, Sendable {
    let allocated: Int
    let idle: Int
    let other: Int
    let total: Int
    let nodes: Int
    let memoryMiB: Int
    let allocatedMemoryMiB: Int
    let gpus: Int
    let usedGPUs: Int
    enum CodingKeys: String, CodingKey {
        case allocated, idle, other, total, nodes
        case memoryMiB = "memory_mib"
        case allocatedMemoryMiB = "allocated_memory_mib"
        case gpus
        case usedGPUs = "used_gpus"
    }
}

struct PluginHPCResources: View {
    let cluster: PluginHPCCluster?
    let diagnostic: String?

    var body: some View {
        VStack(alignment: .leading, spacing: RelayTheme.spacing(10)) {
            if let cluster {
                HStack(spacing: RelayTheme.spacing(16)) {
                    Text("Cluster CPUs").fontWeight(.medium)
                    Text("\(cluster.allocated) allocated").foregroundStyle(RelayTheme.accent)
                    Text("\(cluster.idle) idle")
                    Text("\(cluster.other) other / unavailable")
                    Spacer()
                    Text("\(cluster.nodes) nodes · \(cluster.total) CPUs · \(cluster.memoryMiB / 1024) GiB configured RAM")
                }.font(RelayTheme.font(size: 11)).foregroundStyle(RelayTheme.textMuted)
                HStack(spacing: RelayTheme.spacing(20)) {
                    Text("RAM · \(cluster.allocatedMemoryMiB / 1024) GiB allocated / \(cluster.memoryMiB / 1024) GiB configured")
                    Text("GPUs · \(cluster.usedGPUs) allocated / \(cluster.gpus) configured")
                    Text("Allocation is a reservation, not measured hardware utilization.")
                }.font(RelayTheme.font(size: 10)).foregroundStyle(RelayTheme.textMuted)
                HStack(spacing: RelayTheme.spacing(24)) {
                    capacity("CPU", used: cluster.allocated, total: cluster.total)
                    capacity("RAM", used: cluster.allocatedMemoryMiB, total: cluster.memoryMiB)
                    capacity("GPU", used: cluster.usedGPUs, total: cluster.gpus)
                }
            } else { Text(diagnostic ?? "Cluster resources unavailable").font(.caption).foregroundStyle(RelayTheme.textMuted) }
        }.padding(RelayTheme.spacing(12)).background(RelayTheme.line.opacity(0.2), in: RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(8)))
    }

    private func capacity(_ label: String, used: Int, total: Int) -> some View {
        HStack(spacing: RelayTheme.spacing(8)) {
            Text(label).frame(width: 28, alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(RelayTheme.textMuted.opacity(0.12))
                    Capsule().fill(RelayTheme.accent.opacity(0.55))
                        .frame(width: geometry.size.width * min(1, CGFloat(max(0, used)) / CGFloat(max(1, total))))
                }
            }.frame(height: 3)
            Text(total > 0 ? "\(Int(Double(used) / Double(total) * 100))%" : "—")
                .monospacedDigit().frame(width: 32, alignment: .trailing)
        }.font(RelayTheme.font(size: 10)).foregroundStyle(RelayTheme.textMuted)
        .help("\(label): \(used) of \(total) allocated")
    }
}
