import Foundation

/// One background command a forced account move found under the agent.
struct RelayForcedMoveCommand: Equatable, Sendable {
    let pid: Int
    let command: String
}

/// A forced account move interrupts the agent's turn and exits it with its
/// background shells still running. Before the exit, Relay records those
/// shells from the host's process table; after the resume it checks which
/// are gone and tells the resumed agent, so it does not assume they finished.
enum RelayForcedAccountMove {
    /// The host's process table: pid, parent pid and full arguments. The same
    /// options work on Linux (procps) and macOS.
    static let processTableCommand = "ps -ww -A -o pid=,ppid=,args="
    static let maximumCommands = 12
    static let maximumCommandLength = 200

    private static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "ksh", "fish"]

    /// The shells started directly by the agent process `agentPID`: the
    /// commands its Bash tool or background terminals run. Status-line
    /// refreshes and non-shell children (MCP servers, helpers) are omitted.
    static func backgroundCommands(processTable: String, agentPID: Int) -> [RelayForcedMoveCommand] {
        var found: [RelayForcedMoveCommand] = []
        for line in processTable.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count == 3, let pid = Int(fields[0]), let parent = Int(fields[1]), parent == agentPID, pid > 1 else { continue }
            let arguments = String(fields[2])
            let executable = arguments.split(separator: " ").first.map(String.init) ?? ""
            let name = (executable as NSString).lastPathComponent.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            guard shells.contains(name), !statusLine(arguments) else { continue }
            found.append(.init(pid: pid, command: readable(arguments)))
            if found.count == maximumCommands { break }
        }
        return found
    }

    static func statusLine(_ arguments: String) -> Bool {
        ["cc-status.sh", "claude-statusline", "subscription-quota-statusline"].contains { arguments.contains($0) }
    }

    /// The user's command inside a shell wrapper. Claude's Bash tool runs
    /// `zsh -c -l source <snapshot> && eval '<command>' \< /dev/null && pwd -P >| <file>`;
    /// Codex runs `bash -lc '<command>'`.
    static func readable(_ arguments: String) -> String {
        var text = arguments
        if let eval = text.range(of: "eval '") {
            var rest = String(text[eval.upperBound...])
            for end in ["' \\< /dev/null", "' < /dev/null", "' && pwd -P"] {
                if let stop = rest.range(of: end, options: .backwards) { rest = String(rest[..<stop.lowerBound]); break }
            }
            text = rest.replacingOccurrences(of: "'\\''", with: "'")
        } else if let flag = text.range(of: #"^\S+\s+-l?c\s+"#, options: .regularExpression) {
            text = String(text[flag.upperBound...])
            if text.count >= 2, text.hasPrefix("'"), text.hasSuffix("'") { text = String(text.dropFirst().dropLast()) }
        }
        text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return text.count > maximumCommandLength ? String(text.prefix(maximumCommandLength - 1)) + "…" : text
    }

    /// The pids from `pids` still listed by `ps -o pid= -p`.
    static func survivors(processList: String, pids: [Int]) -> Set<Int> {
        Set(processList.split(whereSeparator: \.isNewline).compactMap {
            Int($0.trimmingCharacters(in: .whitespaces))
        }).intersection(pids)
    }

    static func survivorCommand(_ pids: [Int]) -> String {
        "ps -o pid= -p " + pids.map(String.init).joined(separator: ",") + " || true"
    }

    /// The one-line notice for the resumed agent; nil when nothing was
    /// interrupted or stopped. `survivors` nil means Relay could not check.
    static func notice(account: String, interrupted: Bool, commands: [RelayForcedMoveCommand],
                       survivors: Set<Int>?) -> String? {
        guard interrupted || !commands.isEmpty else { return nil }
        var text = "[Relay] The user moved this session to the \(account) account with a forced move."
        if interrupted { text += " Your running turn was interrupted before it finished." }
        guard let survivors else {
            text += " These background commands were running when the session exited; Relay could not check whether " +
                "they stopped: " + commands.enumerated().map { "\($0.offset + 1)) `\($0.element.command)`" }.joined(separator: "; ") +
                ". Check their state and restart any you still need; do not assume they finished."
            return text
        }
        let stopped = commands.filter { !survivors.contains($0.pid) }
        let alive = commands.filter { survivors.contains($0.pid) }
        if !stopped.isEmpty {
            text += " These background commands were stopped by the restart: " +
                stopped.enumerated().map { "\($0.offset + 1)) `\($0.element.command)`" }.joined(separator: "; ") + "."
        }
        if !alive.isEmpty {
            text += " These kept running outside this session: " +
                alive.map { "`\($0.command)` (pid \($0.pid))" }.joined(separator: "; ") + "."
        }
        text += " Check their state and restart any you still need; do not assume they finished."
        return text
    }
}
