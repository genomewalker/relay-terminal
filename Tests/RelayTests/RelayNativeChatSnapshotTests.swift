import AppKit
import SwiftUI
import Testing
@testable import Relay

/// Seeded transcripts for the two native chat surfaces: the CLI conversation timeline
/// ("View CLI conversation") and the native harness conversation. Renders go to
/// RELAY_SNAPSHOT_DIR when set; RELAY_SNAPSHOT_TAG names the run (for example "before").
@MainActor enum RelayNativeChatFixture {
    static let host = ConnectionProfile(name: "dandy-07", kind: .ssh, host: "dandy-07.ux-chat.invalid")

    /// Tab-separated columns as samtools/awk print them; 60 lines.
    static let longOutput: String = {
        var lines = ["sample\tdamage_5p\tmapq30\treads"]
        for index in 1...59 {
            lines.append("S\(String(format: "%02d", index))\t0.0\(index % 10)2\t\(120_000 + index * 731)\t\(9_000_000 + index * 1_013)")
        }
        return lines.joined(separator: "\n")
    }()

    static let editInput = #"{"file_path":"/projects/sapropel/Sources/Relay/Models.swift","old_string":"let threshold = 0.01\nlet minimumReads = 1000","new_string":"let threshold = 0.012\nlet minimumReads = 2500\nlet requireMapq = 30"}"#

    static let unifiedDiff = """
    --- a/analysis/labels.json
    +++ b/analysis/labels.json
    @@ -3,4 +3,4 @@
       "site": "Kap København",
    -  "label": "sample_07_old",
    +  "label": "sample_07",
       "layer": "B2",
    -  "depth_cm": 112
    +  "depth_cm": 114
    """

    static let failedOutput = "Exit code 1\nsamtools: error while loading shared libraries: libhts.so.3: cannot open shared object file"

    static let answer = """
    ## Damage summary
    The 5′ deamination rate is **0.012** across the 59 libraries, so the threshold change is safe.

    - `S07` had the lowest MAPQ≥30 count.
    - The label fix in `analysis/labels.json` matches the field notes.

    | Sample | damage_5p | mapq30 |
    |---|---|---|
    | S01 | 0.012 | 120731 |
    | S07 | 0.072 | 125117 |
    """

    static let infraError = "Host exec outcome unavailable; job job-5f0c2a9e-1b7d-4d0e-9c41-2a7f9e3b8d10. Do not replay execution. The network connection was lost."

    static func pane(active: Bool) -> PaneModel {
        let phase: AgentPhase = active ? .active : .quiet
        let saved = PersistedAgentPaneState(cursor: 0, kind: .claude, phase: phase, summary: active ? "Using Bash" : "Finished",
            subagents: [], activities: [AgentActivityItem(id: UUID(), label: active ? "Using Bash" : "Finished", phase: phase,
                                                          occurredAt: Date().addingTimeInterval(-12))],
            resourceUsage: nil, progressPercent: nil, pendingApprovals: 0)
        let pane = PaneModel(profile: host, customName: "Sapropel - damage review - claude 767dc7",
                             directory: "/projects/sapropel", savedAgentState: saved)
        pane.connectionState = .connected
        return pane
    }

    static func timelineConversation(pane: PaneModel) -> RelayAgentConversation {
        let binding = RelayAgentConversationBinding(hostID: host.id.uuidString, paneID: pane.id, provider: "claude",
            processID: 4242, processStart: "start", sessionID: "6f1d0c2e-session", sourceIdentity: "source-1")
        var conversation = RelayAgentConversation(); conversation.bind(binding)
        let items: [(String, RelayAgentConversationItem.Role, RelayAgentConversationItem.Block)] = [
            ("u1", .user, .markdown("Check the damage stats and fix the threshold.")),
            ("t1", .tool, .tool(name: "Bash", status: "requested", summary: #"{"command":"samtools stats -@4 merged.bam | cut -f2-","description":"Collect damage stats"}"#)),
            ("t2", .tool, .tool(name: "Bash", status: "completed", summary: longOutput)),
            ("t3", .tool, .tool(name: "Edit", status: "requested", summary: editInput)),
            ("t4", .tool, .tool(name: "Bash", status: "completed", summary: unifiedDiff)),
            ("t5", .tool, .tool(name: "Bash", status: "failed", summary: failedOutput)),
            ("a1", .assistant, .markdown(answer)),
            ("t6", .tool, .tool(name: "Read", status: "requested", summary: #"{"file_path":"/projects/sapropel/Sources/Relay/Models.swift"}"#)),
        ]
        for (index, entry) in items.enumerated() {
            conversation.receive(.init(id: entry.0, turnID: nil, role: entry.1, blocks: [entry.2],
                                       revision: UInt64(index + 1), complete: true), binding: binding)
        }
        return conversation
    }

    static func nativeConversation(failure: String? = nil) throws -> RelayNativeConversation {
        let identity = RelayNativeIdentity(pane: "pane", instance: "instance", provider: "claude")
        let model = RelayNativeConversation(binding: RelayNativeBinding(identity: identity, profile: .local,
            account: .init(provider: "claude", label: "work", dir: "")))
        let body: [String: Any] = [
            "version": 1, "identity": ["pane": "pane", "instance": "instance", "provider": "claude"],
            "sessionId": "s", "turnId": "turn", "cwd": "/projects/sapropel", "model": "Claude", "phase": "running", "revision": 9,
            "items": [
                ["id": "u1", "role": "user", "text": "Check the damage stats and fix the threshold.", "sequence": 1],
                ["id": "t1", "role": "tool", "tool": "Bash", "status": "running",
                 "text": "{\n  \"command\": \"samtools stats -@4 merged.bam | cut -f2-\"\n}", "sequence": 2],
                ["id": "t2", "role": "tool", "tool": "Tool result", "status": "completed", "text": longOutput, "sequence": 3],
                ["id": "t3", "role": "tool", "tool": "Edit", "status": "running", "text": editInput, "sequence": 4],
                ["id": "t4", "role": "tool", "tool": "File changes", "status": "completed", "text": unifiedDiff, "sequence": 5],
                ["id": "t5", "role": "tool", "tool": "Tool result", "status": "failed", "text": failedOutput, "sequence": 6],
                ["id": "a1", "role": "assistant", "text": answer, "sequence": 7],
                ["id": "t6", "role": "tool", "tool": "Read", "status": "running",
                 "text": "{\n  \"file_path\": \"/projects/sapropel/Sources/Relay/Models.swift\"\n}", "sequence": 8],
            ],
            "requests": [],
            "capabilities": ["send": true, "steer": true, "interrupt": true, "interruptScope": "turn",
                "respond": true, "maintenance": false, "scheduledTasks": "unknown", "maintenanceReason": "Unavailable"],
        ]
        model.snapshot = try JSONDecoder().decode(RelayNativeSnapshot.self, from: JSONSerialization.data(withJSONObject: body))
        model.failure = failure
        return model
    }
}

@MainActor @Suite("Native chat snapshots", .serialized) struct RelayNativeChatSnapshotTests {
    private var tag: String { ProcessInfo.processInfo.environment["RELAY_SNAPSHOT_TAG"].map { "-" + $0 } ?? "" }
    private let appearances: [(NSAppearance.Name, ColorScheme)] = [(.darkAqua, .dark), (.aqua, .light)]

    private func shoot<V: View>(_ view: V, name: String, width: CGFloat, height: CGFloat) throws {
        _ = NSApplication.shared
        for (appearance, scheme) in appearances {
            let result = try RelaySnapshot.render(view.frame(height: height).environment(\.colorScheme, scheme),
                                                  name: name + tag + "-" + String(Int(width)), width: width, appearance: appearance)
            #expect(result.size.width == width && result.size.height >= height - 1)
        }
    }

    @Test func timelineTranscript() throws {
        for width in [CGFloat(760), 1100] {
            let pane = RelayNativeChatFixture.pane(active: true)
            let store = RelayAgentTimelineStore(pane: pane, presenting: RelayNativeChatFixture.timelineConversation(pane: pane))
            try shoot(RelayAgentTimelineView(pane: pane, store: store), name: "chat-timeline", width: width, height: 1500)
        }
    }

    @Test func timelineHostError() throws {
        let pane = RelayNativeChatFixture.pane(active: false)
        let store = RelayAgentTimelineStore(pane: pane, presenting: RelayAgentConversation(),
                                            failure: RelayNativeChatFixture.infraError)
        try shoot(RelayAgentTimelineView(pane: pane, store: store), name: "chat-timeline-error", width: 760, height: 520)
    }

    @Test func nativeTranscript() throws {
        for width in [CGFloat(760), 1100] {
            let model = try RelayNativeChatFixture.nativeConversation()
            try shoot(RelayNativeConversationView(conversation: model, observeLive: false), name: "chat-native", width: width, height: 2300)
        }
    }

    @Test func nativeHostError() throws {
        let model = try RelayNativeChatFixture.nativeConversation(failure: RelayNativeChatFixture.infraError)
        try shoot(RelayNativeConversationView(conversation: model, observeLive: false), name: "chat-native-error", width: 760, height: 520)
    }
}
