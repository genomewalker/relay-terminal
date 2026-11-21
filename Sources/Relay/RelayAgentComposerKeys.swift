import AppKit
import SwiftUI

/// Keys in the agent conversation composer, matching the Claude Code and Codex
/// prompts: Return sends, Shift/Option/Control-Return insert a newline, Esc
/// interrupts a working agent, and Up/Down at the first/last line recall
/// earlier prompts. Keys pressed while an input method holds marked text always
/// stay with the text system, so IME composition is never sent or interrupted.
enum RelayAgentComposerKeys {
    enum Key: Equatable { case returnKey, escape, upArrow, downArrow, other }
    enum Action: Equatable { case send, interrupt, historyPrevious, historyNext, passThrough }

    static func action(key: Key, modifiers: EventModifiers, hasMarkedText: Bool,
                       caretOnFirstLine: Bool, caretOnLastLine: Bool, agentWorking: Bool) -> Action {
        guard !hasMarkedText else { return .passThrough }
        switch key {
        case .returnKey:
            // Shift, Option or Control keep the platform newline; ⌘↩ still sends.
            return modifiers.isDisjoint(with: [.shift, .option, .control]) ? .send : .passThrough
        case .escape:
            return modifiers.isEmpty && agentWorking ? .interrupt : .passThrough
        case .upArrow:
            return modifiers.isEmpty && caretOnFirstLine ? .historyPrevious : .passThrough
        case .downArrow:
            return modifiers.isEmpty && caretOnLastLine ? .historyNext : .passThrough
        case .other:
            return .passThrough
        }
    }

    /// Caret position in `text` for an NSTextView selection (UTF-16 offsets).
    static func caretLines(text: String, selection: NSRange) -> (first: Bool, last: Bool) {
        let ns = text as NSString
        let start = min(max(0, selection.location), ns.length)
        let end = min(max(start, NSMaxRange(selection)), ns.length)
        let before = ns.substring(to: start)
        let after = ns.substring(from: end)
        return (!before.contains("\n"), !after.contains("\n"))
    }

    /// The text of the user's own turns, oldest first, for history recall.
    static func userPrompts(_ items: [RelayAgentConversationItem]) -> [String] {
        items.compactMap { item -> String? in
            guard item.role == .user else { return nil }
            let text = item.blocks.compactMap { block -> String? in
                if case .markdown(let value) = block { return value }
                return nil
            }.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
    }
}

/// Up/Down prompt history. Browsing keeps the unsent draft and restores it
/// when Down moves past the newest entry, like the CLI prompts.
struct RelayAgentComposerHistory: Equatable {
    private(set) var index: Int?
    private(set) var stash = ""

    var browsing: Bool { index != nil }

    /// The entry to show for Up, or nil when there is nothing older.
    mutating func previous(entries: [String], current: String) -> String? {
        guard !entries.isEmpty else { return nil }
        let next: Int
        if let index {
            guard index > 0 else { return nil }
            next = index - 1
        } else {
            stash = current
            next = entries.count - 1
        }
        // Skip an entry identical to what is shown, so one Up always changes the text.
        if entries[next] == current, next > 0, index == nil {
            index = next - 1
            return entries[next - 1]
        }
        index = next
        return entries[next]
    }

    /// The entry to show for Down; the stashed draft after the newest entry,
    /// or nil when not browsing.
    mutating func next(entries: [String]) -> String? {
        guard let index else { return nil }
        if index + 1 < entries.count {
            self.index = index + 1
            return entries[index + 1]
        }
        self.index = nil
        defer { stash = "" }
        return stash
    }

    /// Typing or sending ends browsing.
    mutating func reset() { index = nil; stash = "" }
}
