import Foundation

enum RelayNativeConversationSendResult: Equatable, Sendable {
    case notSent
    case stagedOnly
    case submissionUncertain
    case submitted
}

/// Inspect the current composer, not earlier image markers in the transcript.
/// This acknowledgement authorizes the next paste, never a different owner.
enum RelayNativeImageComposer {
    static func acknowledges(_ count: Int, provider: String, rows: [String]) -> Bool {
        guard (0...32).contains(count), ["claude", "codex"].contains(provider) else { return false }
        let marker: Character = provider == "claude" ? "❯" : "›"
        guard let start = rows.lastIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).first == marker
        }) else { return false }
        var content = String(rows[start].trimmingCharacters(in: .whitespaces).dropFirst())
        for row in rows.dropFirst(start + 1) {
            let trimmed = row.trimmingCharacters(in: .whitespaces)
            // Codex uses an empty row between its highlighted composer and
            // model/status footer; Claude uses a horizontal separator.
            if provider == "codex" && trimmed.isEmpty { break }
            if !trimmed.isEmpty && trimmed.allSatisfy({ "─━".contains($0) }) { break }
            content += trimmed
        }
        if count == 0 { return !content.contains("[Image #") }
        for index in 1...count {
            let chip = "[Image #\(index)]"
            guard let range = content.range(of: chip) else { return false }
            content.removeSubrange(range)
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// True only when the provider's input row on screen holds no text at all.
    /// Placeholder or suggestion text counts as content, so it refuses.
    static func promptIsEmpty(provider: String, rows: [String]) -> Bool {
        guard ["claude", "codex"].contains(provider) else { return false }
        let marker: Character = provider == "claude" ? "❯" : "›"
        guard let start = rows.lastIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).first == marker
        }) else { return false }
        var content = String(rows[start].trimmingCharacters(in: .whitespaces).dropFirst())
        for row in rows.dropFirst(start + 1) {
            let trimmed = row.trimmingCharacters(in: .whitespaces)
            if provider == "codex" && trimmed.isEmpty { break }
            if !trimmed.isEmpty && trimmed.allSatisfy({ "─━".contains($0) }) { break }
            content += trimmed
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func quotedPath(_ path: String) -> String? {
        guard path.hasPrefix("/"), path.utf8.count <= 4096,
              !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              !path.contains("\""), !path.contains("\\") else { return nil }
        // A quoted path is one provider paste, not a shell command or prompt.
        return "\"" + path + "\""
    }
}

/// The rows a provider draws under its input box: cc-status and other status-line
/// plugins, the permission mode, Codex's model and context line. Plain screen text only.
enum RelayAgentTerminalFooter {
    static func rows(provider: String, screen: [String]) -> [String] {
        guard ["claude", "codex"].contains(provider) else { return [] }
        let marker: Character = provider == "claude" ? "❯" : "›"
        guard let start = screen.lastIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).first == marker
        }) else { return [] }
        var index = start + 1
        // Skip the rest of the input box: wrapped input rows up to Claude's
        // closing rule, or up to Codex's blank row under its composer.
        while index < screen.count {
            let trimmed = screen[index].trimmingCharacters(in: .whitespaces)
            index += 1
            if provider == "codex" && trimmed.isEmpty { break }
            if !trimmed.isEmpty && trimmed.allSatisfy({ "─━".contains($0) }) { break }
        }
        guard index <= screen.count else { return [] }
        return screen[index...].map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.allSatisfy({ "─━".contains($0) }) }
            .suffix(6).map { String($0.prefix(400)) }
    }
}

/// Whether a composer send that started no turn has settled: a slash command
/// such as /model, /clear or /compact returns the agent to an empty, idle
/// prompt without a completed turn the conversation reader could report.
enum RelayAgentComposerSettle {
    static let minimumWait: TimeInterval = 3
    static func settledWithoutTurn(vt: String?, provider: String, elapsed: TimeInterval) -> Bool {
        guard elapsed >= minimumWait, let vt,
              RelayAgentMaintenancePrompt.inputIsEmpty(vt, provider: provider) == true else { return false }
        return !vt.localizedCaseInsensitiveContains("esc to interrupt")
    }
}
