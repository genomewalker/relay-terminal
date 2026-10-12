import Foundation

/// Presentation identity from the pane's current kernel process tree. It is
/// deliberately separate from permission to control or message a conversation.
struct AgentHarnessIdentity: Decodable, Equatable, Sendable {
    struct Process: Decodable, Equatable, Sendable {
        let provider: String
        let pid: Int
        let processStart: String
        enum CodingKeys: String, CodingKey { case provider, pid; case processStart = "process_start" }
    }
    let paneID: UUID
    let role: String
    let provider: String?
    let processes: [Process]
    let reason: String?
    enum CodingKeys: String, CodingKey { case paneID = "pane_id"; case role, provider, processes, reason }

    var kind: AgentKind? {
        switch role {
        case "shell": return provider == "shell" && processes.isEmpty ? .shell : nil
        case "harness":
            guard processes.count == 1, let provider, processes[0].provider == provider,
                  processes[0].pid > 1, processes[0].processStart.hasPrefix("kernel:"),
                  processes[0].processStart.dropFirst(7).allSatisfy(\.isNumber),
                  processes[0].processStart.count > 7 else { return nil }
            return AgentKind.provider(provider)
        case "multiple": return processes.count > 1 ? .other : nil
        default: return nil
        }
    }

    var label: String {
        if role == "multiple" { return "Multiple harnesses" }
        return Self.label(for: provider ?? "")
    }

    static func label(for provider: String) -> String {
        switch provider.lowercased() {
        case "shell": return "Shell"
        case "claude", "claude-code": return "Claude"
        case "codex", "codex-cli": return "Codex"
        case "gemini": return "Gemini"
        case "opencode": return "OpenCode"
        case "aider": return "Aider"
        case "goose": return "Goose"
        case "amp": return "Amp"
        case "droid": return "Droid"
        case "copilot": return "Copilot"
        case "cursor-agent": return "Cursor Agent"
        case "crush": return "Crush"
        case "qwen": return "Qwen"
        case "pi": return "Pi"
        default: return "Other harness"
        }
    }
}

struct AgentHarnessReport: Decodable, Sendable {
    let version: Int
    let panes: [AgentHarnessIdentity]
}
