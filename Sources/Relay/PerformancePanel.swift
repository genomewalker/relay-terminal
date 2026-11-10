import Darwin
import SwiftUI

struct RelayLivePerformanceSnapshot: Equatable, Sendable {
    var wakeupsPerSecond = 0.0
    var idleWakeupsPerSecond = 0.0
    var wakeupsAvailable = false
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
    var supervisorWarningCount = 0
    var supervisorHighestStage = RelaySupervisorStage.observe
    var supervisorActionPaneID: UUID?
}

private struct RelayProcessUsageSample {
    let cpuSeconds: Double
    let interruptWakeups: UInt64
    let idleWakeups: UInt64
    let wakeupsAvailable: Bool
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
        var power = task_power_info_data_t()
        var powerCount = mach_msg_type_number_t(MemoryLayout<task_power_info_data_t>.size / MemoryLayout<integer_t>.size)
        let powerResult = withUnsafeMutablePointer(to: &power) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(powerCount)) {
                task_info(mach_task_self_, task_flavor_t(TASK_POWER_INFO), $0, &powerCount)
            }
        }
        return RelayProcessUsageSample(
            cpuSeconds: user + system,
            interruptWakeups: power.task_interrupt_wakeups,
            idleWakeups: power.task_platform_idle_wakeups,
            wakeupsAvailable: powerResult == KERN_SUCCESS,
            residentBytes: result == KERN_SUCCESS ? info.phys_footprint : 0
        )
    }
}

/// Sampling exists only for the lifetime of the visible panel. It reads
/// counters Relay already owns and never opens another SSH connection.
@MainActor
final class RelayPerformancePanelMonitor: ObservableObject {
    @Published private(set) var current = RelayLivePerformanceSnapshot()
    @Published private(set) var energyPeaks: [RelayEnergyPeak] = []
    @Published private(set) var recentEvents: [RelayDiagnosticEvent] = []
    @Published private(set) var peakCPU = 0.0
    @Published private(set) var activity = "Waiting for a sample"
    private var lastPeakDate = Date.distantPast
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
        let diagnosticSnapshot = RelayDiagnostics.shared.snapshot()
        let diagnostics = diagnosticSnapshot.health.values
        recentEvents = Array(diagnosticSnapshot.events.suffix(8).reversed())
        let remotePanes = workspace.panes.values.filter {
            $0.profile.kind == .ssh && $0.profile.backend == .relay
        }

        var next = RelayLivePerformanceSnapshot()
        if let previousCounters, let previousProcess {
            let elapsedNanoseconds = counters.capturedAtNanoseconds &- previousCounters.capturedAtNanoseconds
            let elapsed = max(0.001, Double(elapsedNanoseconds) / 1_000_000_000)
            next.wakeupsAvailable = process.wakeupsAvailable && previousProcess.wakeupsAvailable
            if next.wakeupsAvailable {
                next.wakeupsPerSecond = Double(process.interruptWakeups &- previousProcess.interruptWakeups) / elapsed
                next.idleWakeupsPerSecond = Double(process.idleWakeups &- previousProcess.idleWakeups) / elapsed
            }
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
            next.activeConnectionState = pane.connectionStatusLabel
        }
        let recommendations = workspace.supervisorRecommendations.values
        next.supervisorWarningCount = recommendations.count { $0.stage > .observe }
        next.supervisorHighestStage = recommendations.map(\.stage).max() ?? .observe
        next.supervisorActionPaneID = recommendations
            .filter { $0.stage.changesRuntimeState }
            .max { $0.stage < $1.stage }?.identity.paneID

        var observed: [String] = []
        if next.outputBytesPerSecond > 0 { observed.append("Receiving terminal output") }
        if next.inputBytesPerSecond > 0 { observed.append("Sending terminal input") }
        if next.recoveringPaneCount > 0 { observed.append("Reconnecting sessions") }
        if let event = recentEvents.first, Date().timeIntervalSince(event.timestamp) < 2 {
            observed.append(event.category + " · " + event.name)
        }
        activity = observed.isEmpty ? "No terminal traffic or recent diagnostic event" : observed.joined(separator: " · ")
        peakCPU = max(peakCPU, next.cpuPercent)
        if next.cpuPercent >= 20, Date().timeIntervalSince(lastPeakDate) >= 5 {
            lastPeakDate = Date()
            energyPeaks.insert(RelayEnergyPeak(date: lastPeakDate, cpu: next.cpuPercent,
                wakeups: next.wakeupsPerSecond, activity: activity), at: 0)
            if energyPeaks.count > 60 { energyPeaks.removeLast() }
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

struct RelayEnergyPeak: Identifiable {
    let id = UUID()
    let date: Date
    let cpu: Double
    let wakeups: Double
    let activity: String
}

struct RelayPerformancePanel: View {
    let close: () -> Void
    @StateObject private var monitor: RelayPerformancePanelMonitor
    @ObservedObject private var workspace: WorkspaceModel
    @State private var settledOffset: CGSize = .zero
    @State private var collapsed = false
    @State private var reviewReceipt: RelaySupervisorActionReceipt?
    @Binding private var section: String
    @StateObject private var activityPresentation = PluginToolPresentation()
    @StateObject private var activityChrome = WorkspaceChrome()

    init(workspace: WorkspaceModel, close: @escaping () -> Void) {
        self.close = close
        _section = Binding(get: { workspace.performancePanelSection }, set: { workspace.performancePanelSection = $0 })
        _monitor = StateObject(wrappedValue: RelayPerformancePanelMonitor(workspace: workspace))
        _workspace = ObservedObject(wrappedValue: workspace)
    }

    var body: some View {
        SmoothFloatingPanelDrag(settledOffset: $settledOffset, headerHeight: barHeight) {
            VStack(spacing: RelayTheme.spacing(0)) {
                titleBar
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                if !collapsed {
                    Rectangle().fill(RelayTheme.line.opacity(0.7)).frame(height: 1)
                    Picker("Monitoring", selection: $section) {
                        Text("Performance").tag("Performance")
                        Text("Energy").tag("Energy")
                        Text("Sessions").tag("Sessions")
                        Text("Agents").tag("Agents")
                        Text("Hosts").tag("Hosts")
                        Text("Control").tag("Control")
                    }.pickerStyle(.segmented).padding(RelayTheme.spacing(12))
                    ScrollView(.vertical) {
                        switch section {
                        case "Energy": energyContent
                        case "Sessions": RelaySessionMonitor(workspace: workspace)
                        case "Agents":
                            VStack(spacing: RelayTheme.spacing(8)) {
                                RelayPaneHealthOverview()
                                agentContent
                            }
                        case "Hosts": RelayHostsMonitor(workspace: workspace)
                        case "Control": RelayControlCenterView(workspace: workspace)
                        default: content
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: section == "Performance" || section == "Energy" ? 560 : 760, height: collapsed ? barHeight : 560)
            .background(RelayTheme.canvas)
            .clipShape(RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(8), style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(8), style: .continuous)
                    .stroke(RelayTheme.line.opacity(0.85), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(0.34), radius: 22, y: 10)
        }
        .onAppear { monitor.start() }
        .onDisappear { monitor.stop() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Relay monitoring")
        .alert(
            "Supervisor recommendation",
            isPresented: Binding(
                get: { reviewReceipt != nil },
                set: { if !$0 { reviewReceipt = nil } }
            ),
            presenting: reviewReceipt
        ) { receipt in
            Button("Approve action") {
                _ = workspace.approveAndExecuteSupervisorAction(receiptID: receipt.id)
                reviewReceipt = nil
            }
            Button("Not now", role: .cancel) {
                _ = workspace.resolveSupervisorAction(receiptID: receipt.id, approve: false)
                reviewReceipt = nil
            }
        } message: { receipt in
            Text("Relay will recheck the exact live session and execute \(Self.supervisorLabel(receipt.stage)) only when this build exposes that specific capability. Offline, replaced, expired, or unsupported targets fail closed.")
        }
    }

    @ViewBuilder private var agentContent: some View {
        if let pane = workspace.activePane {
            RelayPluginToolsView(workspace: workspace, presentation: activityPresentation,
                chrome: activityChrome, presentationStyle: .floating)
                .onAppear {
                    let context = workspace.executionContext()
                    activityPresentation.captureOnce(id: pane.id, profile: context?.profile ?? pane.profile,
                        directory: context?.directory ?? pane.directory)
                    activityPresentation.selection = "relay.agent-activity:main"
                }
        } else {
            Text("Select a terminal to inspect agent activity.").padding(RelayTheme.spacing(14))
        }
    }

    private var barHeight: CGFloat { RelayViewerMetrics.barHeight(compact: RelayPreferences.shared.compactInterface) }

    /// The shared viewer bar; also the panel's drag handle and collapsed height.
    private var titleBar: some View {
        RelayViewerBar(symbol: "waveform.path.ecg.rectangle", title: "Monitoring", detail: "Live",
                       detailMonospaced: false, close: close, closeLabel: "Close monitoring") {
            RelayViewerIconButton(title: collapsed ? "Expand monitoring" : "Collapse monitoring",
                                  symbol: collapsed ? "chevron.down" : "chevron.up") { collapsed.toggle() }
                .focusEffectDisabled()
                .help(collapsed ? "Expand monitoring" : "Collapse monitoring")
                .accessibilityIdentifier("relay.monitoring.collapse")
        }
        .contentShape(Rectangle())
    }

    private var energyContent: some View {
        let value = monitor.current
        return VStack(alignment: .leading, spacing: RelayTheme.spacing(12)) {
            HStack(spacing: RelayTheme.spacing(10)) {
                PerformanceMetricCard(label: "CPU", value: String(format: "%.1f%%", value.cpuPercent),
                    detail: String(format: "peak %.1f%%", monitor.peakCPU), history: monitor.cpuHistory, color: RelayTheme.accent)
                PerformanceMetricCard(label: "Wakeups / sec", value: value.wakeupsAvailable ? String(format: "%.1f", value.wakeupsPerSecond) : "Unavailable",
                    detail: String(format: "%.1f idle wakeups", value.idleWakeupsPerSecond), history: [], color: RelayTheme.blue)
            }
            Text("Memory \(Self.bytes(value.memoryBytes)) · Traffic \(Self.rate(value.outputBytesPerSecond + value.inputBytesPerSecond))")
                .font(RelayTheme.font(size: 11)).foregroundStyle(RelayTheme.textMuted)
            Text("Observed activity").font(RelayTheme.font(size: 12, weight: .semibold))
            Text(monitor.activity).font(RelayTheme.font(size: 11)).foregroundStyle(RelayTheme.textMuted)
            Text("Recent peaks · CPU ≥ 20%").font(RelayTheme.font(size: 12, weight: .semibold))
            if monitor.energyPeaks.isEmpty {
                Text("No peaks recorded yet").font(RelayTheme.font(size: 11)).foregroundStyle(RelayTheme.textFaint)
            }
            ForEach(monitor.energyPeaks.prefix(8)) { peak in
                VStack(alignment: .leading, spacing: RelayTheme.spacing(3)) {
                    Text("\(peak.date.formatted(date: .omitted, time: .standard)) · \(String(format: "%.1f%% CPU · %.1f wakeups/s", peak.cpu, peak.wakeups))")
                        .font(RelayTheme.font(size: 11, weight: .medium))
                    Text(peak.activity).font(RelayTheme.font(size: 10)).foregroundStyle(RelayTheme.textMuted)
                }
            }
            Text("Recent Relay events").font(RelayTheme.font(size: 12, weight: .semibold))
            ForEach(Array(monitor.recentEvents.enumerated()), id: \.offset) { _, event in
                Text("\(event.timestamp.formatted(date: .omitted, time: .standard)) · \(event.category) · \(event.name)")
                    .font(RelayTheme.font(size: 10)).foregroundStyle(RelayTheme.textMuted)
                if event.category == "terminal-input" || event.category == "terminal-clipboard" {
                    // Only expose renderer state and counts; never prompt text.
                    let keys: Set<String> = [
                        "pane_id", "kind", "remote", "reason", "shell_prompt",
                        "agent_prompt", "semantic_editing", "viewport_live",
                        "row", "column", "columns", "linefeeds", "carriage_returns",
                        "row_characters", "prefix", "characters", "cursor",
                        "shell_prefix_-1", "shell_prefix_0", "shell_prefix_1",
                        "agent_prefix_-1", "agent_prefix_0", "agent_prefix_1",
                        "source", "bytes", "succeeded", "first_responder", "window_key"
                    ]
                    let summary = event.details.keys.filter { keys.contains($0) }.sorted()
                        .map { "\($0)=\(event.details[$0] ?? "")" }.joined(separator: " · ")
                    if !summary.isEmpty {
                        Text(summary)
                            .font(RelayTheme.font(size: 10)).foregroundStyle(RelayTheme.textMuted)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("relay.monitoring.input-diagnostic")
                    }
                }
            }
            Text("Samples once per second while this panel is open. Activity is context, not proof of a spike’s cause. CPU and wakeups are energy indicators, not watts or macOS Energy Impact. Relay’s helpers are excluded.")
                .font(RelayTheme.font(size: 10)).foregroundStyle(RelayTheme.textFaint)
        }.padding(RelayTheme.spacing(14))
    }

    private var content: some View {
        let value = monitor.current
        return VStack(spacing: RelayTheme.spacing(12)) {
            HStack(spacing: RelayTheme.spacing(10)) {
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

            VStack(spacing: RelayTheme.spacing(0)) {
                PerformanceStatusRow(
                    symbol: "network",
                    label: "Transport",
                    value: "\(value.sshNodeCount) SSH · \(value.remotePaneCount) panes"
                )
                if let paneID = value.supervisorActionPaneID {
                    divider
                    Button {
                        reviewReceipt = workspace.proposeSupervisorAction(paneID: paneID)
                    } label: {
                        Label("Review supervisor recommendation", systemImage: "checkmark.shield")
                            .font(RelayTheme.font(size: 10.5, weight: .medium))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, RelayTheme.spacing(11))
                            .frame(height: 34)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(RelayTheme.accent)
                    .accessibilityIdentifier("relay.supervisor.review")
                }
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
                divider
                PerformanceStatusRow(
                    symbol: "shield.lefthalf.filled",
                    label: "Supervisor",
                    value: value.supervisorWarningCount == 0
                        ? "observing · no findings"
                        : "\(value.supervisorWarningCount) findings · \(Self.supervisorLabel(value.supervisorHighestStage))"
                )
            }
            .background(RelayTheme.surface.opacity(0.62), in: RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(8), style: .continuous))

            HStack(spacing: RelayTheme.spacing(8)) {
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
            .font(RelayTheme.font(size: 10.5, weight: .medium))

            Text("Sampling stops when this panel closes.")
                .font(RelayTheme.font(size: 11))
                .foregroundStyle(RelayTheme.textFaint)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(RelayTheme.spacing(14))
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

    private static func supervisorLabel(_ stage: RelaySupervisorStage) -> String {
        switch stage {
        case .observe: "observe"
        case .warn: "warn"
        case .stopNewWork: "stop new work"
        case .requestCheckpoint: "checkpoint"
        case .gracefulInterrupt: "interrupt proposed"
        case .terminateOrRestart: "restart proposed"
        }
    }
}

private struct PerformanceStatusRow: View {
    let symbol: String
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: RelayTheme.spacing(9)) {
            Image(systemName: symbol)
                .font(RelayTheme.font(size: 10.5, weight: .medium))
                .foregroundStyle(RelayTheme.textFaint)
                .frame(width: 16)
            Text(label)
                .font(RelayTheme.font(size: 11, weight: .medium))
                .foregroundStyle(RelayTheme.textMuted)
            Spacer()
            Text(value)
                .font(RelayTheme.font(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(RelayTheme.text)
        }
        .padding(.horizontal, RelayTheme.spacing(11))
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
        VStack(alignment: .leading, spacing: RelayTheme.spacing(5)) {
            Text(label)
                .font(RelayTheme.font(size: 11, weight: .medium))
                .foregroundStyle(RelayTheme.textFaint)
            Text(value)
                .font(RelayTheme.font(size: 17, weight: .medium, design: .default))
                .foregroundStyle(RelayTheme.text)
            if history.count > 1 {
                PerformanceSparkline(values: history, color: color)
                    .frame(height: 20)
            } else {
                Rectangle().fill(color.opacity(0.18)).frame(height: 1).padding(.vertical, RelayTheme.spacing(9.5))
            }
            Text(detail)
                .font(RelayTheme.font(size: 11))
                .foregroundStyle(RelayTheme.textFaint)
                .lineLimit(1)
        }
        .padding(RelayTheme.spacing(10))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.clear)
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
