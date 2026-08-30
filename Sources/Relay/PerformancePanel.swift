import Darwin
import SwiftUI

struct RelayLivePerformanceSnapshot: Equatable, Sendable {
    var cpuPercent = 0.0
    var memoryBytes: UInt64 = 0
    var outputBytesPerSecond = 0.0
    var inputBytesPerSecond = 0.0
    var terminalBatchesPerSecond = 0.0
    var maximumPendingBytes = 0
    var overloadedSamples: UInt64 = 0
    var mainThreadStalls: UInt64 = 0
    var maximumMainThreadStallMilliseconds = 0.0
    var delayedKeyEvents: UInt64 = 0
    var maximumKeyDispatchMilliseconds = 0.0
    var sshNodeCount = 0
    var remotePaneCount = 0
    var connectedPaneCount = 0
    var recoveringPaneCount = 0
    var terminalClientCount = 0
    var terminalClientCountIsComplete = false
    var smoothedRTTMilliseconds: Double?
    var heartbeatLossRate = 0.0
    var activeHost = "This Mac"
    var activeSession = "Local"
    var activeConnectionState = "Connected"
}

private struct RelayProcessUsageSample {
    let cpuSeconds: Double
    let residentBytes: UInt64
}

private enum RelayProcessUsage {
    static func sample() -> RelayProcessUsageSample {
        var usage = rusage()
        _ = getrusage(RUSAGE_SELF, &usage)
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
        let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000

        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return RelayProcessUsageSample(
            cpuSeconds: user + system,
            residentBytes: result == KERN_SUCCESS ? info.phys_footprint : 0
        )
    }
}

/// Sampling exists only for the lifetime of the visible panel. It reads
/// counters Relay already owns and never opens another SSH connection.
@MainActor
final class RelayPerformancePanelMonitor: ObservableObject {
    @Published private(set) var current = RelayLivePerformanceSnapshot()
    @Published private(set) var cpuHistory: [Double] = []
    @Published private(set) var throughputHistory: [Double] = []

    private weak var workspace: WorkspaceModel?
    private var task: Task<Void, Never>?
    private var previousCounters: RelayPerformanceCounterSnapshot?
    private var previousProcess: RelayProcessUsageSample?

    init(workspace: WorkspaceModel) {
        self.workspace = workspace
    }

    deinit { task?.cancel() }

    func start() {
        guard task == nil else { return }
        sample()
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                self.sample()
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        previousCounters = nil
        previousProcess = nil
    }

    private func sample() {
        guard let workspace else { return }
        let counters = RelayPerformance.shared.snapshot()
        let process = RelayProcessUsage.sample()
        let diagnostics = RelayDiagnostics.shared.snapshot().health.values
        let remotePanes = workspace.panes.values.filter {
            $0.profile.kind == .ssh && $0.profile.backend == .relay
        }

        var next = RelayLivePerformanceSnapshot()
        if let previousCounters, let previousProcess {
            let elapsedNanoseconds = counters.capturedAtNanoseconds &- previousCounters.capturedAtNanoseconds
            let elapsed = max(0.001, Double(elapsedNanoseconds) / 1_000_000_000)
            next.cpuPercent = max(0, (process.cpuSeconds - previousProcess.cpuSeconds) / elapsed * 100)
            next.outputBytesPerSecond = Double(counters.terminalOutputBytes &- previousCounters.terminalOutputBytes) / elapsed
            next.inputBytesPerSecond = Double(counters.terminalInputBytes &- previousCounters.terminalInputBytes) / elapsed
            next.terminalBatchesPerSecond = Double(counters.terminalBatches &- previousCounters.terminalBatches) / elapsed
        }
        next.memoryBytes = process.residentBytes
        next.maximumPendingBytes = counters.maximumPendingBytes
        next.overloadedSamples = counters.overloadedSamples
        next.mainThreadStalls = counters.mainThreadStalls
        next.maximumMainThreadStallMilliseconds = counters.maximumMainThreadStallMilliseconds
        next.delayedKeyEvents = counters.delayedKeyEvents
        next.maximumKeyDispatchMilliseconds = counters.maximumKeyDispatchMilliseconds
        next.sshNodeCount = RelayNodeTransportPool.shared.cachedNodeCount
        next.remotePaneCount = remotePanes.count
        next.connectedPaneCount = remotePanes.count { pane in
            if case .connected = pane.connectionState { return true }
            return false
        }
        next.recoveringPaneCount = remotePanes.count { pane in
            switch pane.connectionState {
            case .connecting, .reconnecting, .waitingForNetwork: true
            case .connected, .disconnected: false
            }
        }
        let connectedPanes = remotePanes.filter { pane in
            if case .connected = pane.connectionState { return true }
            return false
        }
        let reportedClients = connectedPanes.compactMap(\.remoteClientCount)
        next.terminalClientCountIsComplete = reportedClients.count == connectedPanes.count
        next.terminalClientCount = reportedClients.reduce(0, +) +
            (connectedPanes.count - reportedClients.count)

        let health = Array(diagnostics)
        let latency = health.compactMap(\.smoothedRTTMilliseconds)
        next.smoothedRTTMilliseconds = latency.isEmpty ? nil : latency.reduce(0, +) / Double(latency.count)
        let sent = health.reduce(0) { $0 + $1.heartbeatsSent }
        let timeouts = health.reduce(0) { $0 + $1.heartbeatTimeouts }
        next.heartbeatLossRate = sent > 0 ? Double(timeouts) / Double(sent) : 0

        if let pane = workspace.activePane {
            next.activeHost = pane.profile.kind == .ssh ? pane.profile.host : "This Mac"
            next.activeSession = pane.profile.kind == .ssh
                ? String(pane.id.uuidString.lowercased().prefix(8))
                : "Local"
            next.activeConnectionState = pane.connectionState.label
        }

        previousCounters = counters
        previousProcess = process
        current = next
        append(next.cpuPercent, to: &cpuHistory)
        append(next.outputBytesPerSecond + next.inputBytesPerSecond, to: &throughputHistory)
    }

    private func append(_ value: Double, to history: inout [Double]) {
        history.append(value)
        if history.count > 60 { history.removeFirst(history.count - 60) }
    }
}

struct RelayPerformancePanel: View {
    let close: () -> Void
    @StateObject private var monitor: RelayPerformancePanelMonitor
    @State private var settledOffset: CGSize = .zero
    @State private var collapsed = false

    init(workspace: WorkspaceModel, close: @escaping () -> Void) {
        self.close = close
        _monitor = StateObject(wrappedValue: RelayPerformancePanelMonitor(workspace: workspace))
    }

    var body: some View {
        SmoothFloatingPanelDrag(settledOffset: $settledOffset, headerHeight: 42) {
            VStack(spacing: 0) {
                titleBar
                if !collapsed {
                    Rectangle().fill(RelayTheme.line.opacity(0.7)).frame(height: 1)
                    content
                }
            }
            .frame(width: 440, height: collapsed ? 42 : 425)
            .background(RelayTheme.sidebar)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(RelayTheme.line.opacity(0.85), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(0.34), radius: 22, y: 10)
        }
        .onAppear { monitor.start() }
        .onDisappear { monitor.stop() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Relay performance")
    }

    private var titleBar: some View {
        HStack(spacing: 9) {
            Image(systemName: "waveform.path.ecg.rectangle")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(RelayTheme.accent)
            Text("Performance")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(RelayTheme.text)
            Text("live")
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(RelayTheme.textFaint)
            Spacer()
            Button { collapsed.toggle() } label: {
                Image(systemName: collapsed ? "chevron.down" : "chevron.up")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(RelayTheme.textMuted)
            .focusEffectDisabled()
            .help(collapsed ? "Expand performance" : "Collapse performance")
            .accessibilityLabel(collapsed ? "Expand performance" : "Collapse performance")
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(RelayTheme.textMuted)
            .focusEffectDisabled()
            .help("Close performance")
            .accessibilityLabel("Close performance")
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
        .background(RelayTheme.surface.opacity(0.7))
        .contentShape(Rectangle())
    }

    private var content: some View {
        let value = monitor.current
        return VStack(spacing: 12) {
            HStack(spacing: 10) {
                PerformanceMetricCard(
                    label: "CPU",
                    value: String(format: "%.1f%%", value.cpuPercent),
                    detail: value.cpuPercent < 3 ? "idle-friendly" : "active",
                    history: monitor.cpuHistory,
                    color: value.cpuPercent < 20 ? RelayTheme.accent : RelayTheme.coral
                )
                PerformanceMetricCard(
                    label: "Memory",
                    value: Self.bytes(value.memoryBytes),
                    detail: "physical footprint",
                    history: [],
                    color: RelayTheme.blue
                )
                PerformanceMetricCard(
                    label: "Traffic",
                    value: Self.rate(value.outputBytesPerSecond + value.inputBytesPerSecond),
                    detail: "\(Self.rate(value.outputBytesPerSecond)) down",
                    history: monitor.throughputHistory,
                    color: RelayTheme.mint
                )
            }

            VStack(spacing: 0) {
                PerformanceStatusRow(
                    symbol: "network",
                    label: "Transport",
                    value: "\(value.sshNodeCount) SSH · \(value.remotePaneCount) panes"
                )
                divider
                PerformanceStatusRow(
                    symbol: "point.3.connected.trianglepath.dotted",
                    label: "Sessions",
                    value: "\(value.connectedPaneCount) connected · \(value.recoveringPaneCount) recovering"
                )
                divider
                PerformanceStatusRow(
                    symbol: "person.2",
                    label: "Terminal clients",
                    value: value.terminalClientCount == 0
                        ? "—"
                        : value.terminalClientCountIsComplete
                            ? String(value.terminalClientCount)
                            : "\(value.terminalClientCount)+ local"
                )
                divider
                PerformanceStatusRow(
                    symbol: "timer",
                    label: "Round trip",
                    value: value.smoothedRTTMilliseconds.map { String(format: "%.1f ms · %.1f%% loss", $0, value.heartbeatLossRate * 100) } ?? "measuring"
                )
                divider
                PerformanceStatusRow(
                    symbol: "rectangle.stack",
                    label: "Terminal batches",
                    value: String(format: "%.0f/s · queue peak %@", value.terminalBatchesPerSecond, Self.bytes(UInt64(value.maximumPendingBytes)))
                )
                divider
                PerformanceStatusRow(
                    symbol: "keyboard",
                    label: "UI responsiveness",
                    value: value.mainThreadStalls == 0 && value.delayedKeyEvents == 0
                        ? "no stalls"
                        : String(
                            format: "%llu stalls · %.0f ms key peak",
                            value.mainThreadStalls,
                            value.maximumKeyDispatchMilliseconds
                        )
                )
            }
            .background(RelayTheme.surface.opacity(0.62), in: RoundedRectangle(cornerRadius: 11, style: .continuous))

            HStack(spacing: 8) {
                Circle()
                    .fill(value.activeConnectionState == "Connected" ? RelayTheme.mint : RelayTheme.coral)
                    .frame(width: 6, height: 6)
                Text(value.activeHost)
                    .foregroundStyle(RelayTheme.text)
                Text("· \(value.activeSession) · \(value.activeConnectionState)")
                    .foregroundStyle(RelayTheme.textMuted)
                Spacer()
                if value.overloadedSamples > 0 {
                    Text("\(value.overloadedSamples) pressure samples")
                        .foregroundStyle(RelayTheme.coral)
                } else {
                    Text("No queue pressure")
                        .foregroundStyle(RelayTheme.textFaint)
                }
            }
            .font(.system(size: 10.5, weight: .medium))

            Text("Sampling stops when this panel closes.")
                .font(.system(size: 9.5))
                .foregroundStyle(RelayTheme.textFaint)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
    }

    private var divider: some View {
        Rectangle().fill(RelayTheme.line.opacity(0.52)).frame(height: 1)
    }

    private static func bytes(_ bytes: UInt64) -> String {
        if bytes >= 1 << 30 { return String(format: "%.1f GB", Double(bytes) / Double(1 << 30)) }
        if bytes >= 1 << 20 { return String(format: "%.1f MB", Double(bytes) / Double(1 << 20)) }
        if bytes >= 1 << 10 { return String(format: "%.0f KB", Double(bytes) / Double(1 << 10)) }
        return "\(bytes) B"
    }

    private static func rate(_ value: Double) -> String {
        bytes(value.isFinite ? UInt64(max(0, value)) : 0) + "/s"
    }
}

private struct PerformanceStatusRow: View {
    let symbol: String
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(RelayTheme.textFaint)
                .frame(width: 16)
            Text(label)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(RelayTheme.textMuted)
            Spacer()
            Text(value)
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(RelayTheme.text)
        }
        .padding(.horizontal, 11)
        .frame(height: 34)
    }
}

private struct PerformanceMetricCard: View {
    let label: String
    let value: String
    let detail: String
    let history: [Double]
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(RelayTheme.textFaint)
            Text(value)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(RelayTheme.text)
            if history.count > 1 {
                PerformanceSparkline(values: history, color: color)
                    .frame(height: 20)
            } else {
                Rectangle().fill(color.opacity(0.18)).frame(height: 1).padding(.vertical, 9.5)
            }
            Text(detail)
                .font(.system(size: 9))
                .foregroundStyle(RelayTheme.textFaint)
                .lineLimit(1)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RelayTheme.surface.opacity(0.68), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}

private struct PerformanceSparkline: View {
    let values: [Double]
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            Path { path in
                guard values.count > 1 else { return }
                let maximum = max(values.max() ?? 1, 1)
                for (index, value) in values.enumerated() {
                    let x = geometry.size.width * CGFloat(index) / CGFloat(values.count - 1)
                    let y = geometry.size.height * (1 - CGFloat(max(0, value) / maximum))
                    if index == 0 { path.move(to: CGPoint(x: x, y: y)) }
                    else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(color, style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}
