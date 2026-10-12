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

    static func quotedPath(_ path: String) -> String? {
        guard path.hasPrefix("/"), path.utf8.count <= 4096,
              !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              !path.contains("\""), !path.contains("\\") else { return nil }
        // A quoted path is one provider paste, not a shell command or prompt.
        return "\"" + path + "\""
    }
}
