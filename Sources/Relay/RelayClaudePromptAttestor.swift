import Foundation

/// Screen text is inspected transiently and never persisted in rotation state.
enum RelayClaudePromptAttestor {
    static func isEmptyReadyPrompt(_ viewport: String?) -> Bool {
        guard let viewport, !viewport.isEmpty, viewport.count < 32_768 else { return false }
        let lines = viewport.components(separatedBy: .newlines)
        guard let last = lines.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            return false
        }
        let content = last.drop(while: { $0 == " " || $0 == "\t" })
        guard content.hasPrefix("❯\u{00A0}") else { return false }
        let remainder = content.dropFirst(2)
        return remainder.allSatisfy { $0 == " " || $0 == "\t" }
    }

    static func stable(_ first: String?, _ second: String?) -> Bool {
        guard isEmptyReadyPrompt(first), isEmptyReadyPrompt(second),
              first == second else { return false }
        return true
    }
}

/// Reads only the existing renderer for the exact pane; it neither focuses the
/// pane nor adds a remote attachment. No raw viewport leaves this method.
@MainActor struct RelayClaudePanePromptReader {
    weak var pane: PaneModel?

    func ready(paneID: String) async -> Bool {
        guard let pane, pane.id.uuidString.caseInsensitiveCompare(paneID) == .orderedSame,
              pane.contentKind == .terminal, pane.profile.backend == .relay else { return false }
        let first = pane.runtime.sidePanelViewportText()
        guard RelayClaudePromptAttestor.isEmptyReadyPrompt(first) else { return false }
        try? await Task.sleep(for: .seconds(1))
        guard !Task.isCancelled, let samePane = self.pane,
              samePane === pane, samePane.id.uuidString.caseInsensitiveCompare(paneID) == .orderedSame else {
            return false
        }
        return RelayClaudePromptAttestor.stable(first, pane.runtime.sidePanelViewportText())
    }
}
