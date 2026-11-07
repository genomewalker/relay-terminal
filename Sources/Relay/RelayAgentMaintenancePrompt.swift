import Foundation

/// Reads the engine's serialized screen, including the native placeholder's
/// faint style. Plain viewport text cannot distinguish it from a typed draft.
enum RelayAgentMaintenancePrompt {
    // Native per-cell SGR can exceed 256 KiB for an ordinary 112x33 grid.
    // Keep this bound aligned with the native screen exporter.
    static let maximumScreenBytes = 1 << 20
    private struct Cell {
        let character: Unicode.Scalar
        let faint: Bool
    }

    /// The Claude footer row that reports running background work ("2 shells",
    /// "1 background task", "← 1 agent"), which keeps an otherwise empty prompt
    /// busy. "← N agent" counts the user's Claude background agent jobs on the
    /// host as well as the pane's own; up to `explainedAgents` of them are
    /// accounted for by relayd's evidence (see `explainedFooterAgents`).
    static func backgroundWork(_ vt: String?, provider: String, explainedAgents: Int = 0) -> String? {
        guard provider == "claude", let vt, vt.utf8.count <= maximumScreenBytes, let rows = parse(vt) else { return nil }
        return rows.suffix(14).map {
            String(String.UnicodeScalarView($0.map(\.character))).trimmingCharacters(in: .whitespaces)
        }.last { value in
            busy(value, explainedAgents: explainedAgents)
        }
    }

    /// The footer's "N agent(s)" count, 0 when none is shown.
    static func footerAgentCount(_ vt: String?, provider: String) -> Int {
        guard provider == "claude", let vt, vt.utf8.count <= maximumScreenBytes, let rows = parse(vt) else { return 0 }
        return rows.suffix(14).map {
            agentCount(String(String.UnicodeScalarView($0.map(\.character))).trimmingCharacters(in: .whitespaces))
        }.max() ?? 0
    }

    private static func agentCount(_ value: String) -> Int {
        guard let range = value.range(of: footerAgents, options: [.regularExpression, .caseInsensitive]) else { return 0 }
        return value[range].split(separator: " ").first.flatMap { Int($0) } ?? Int.max
    }

    private static func busy(_ value: String, explainedAgents: Int) -> Bool {
        value.range(of: footerWork, options: [.regularExpression, .caseInsensitive]) != nil ||
            agentCount(value) > explainedAgents
    }

    private static let footerWork = #"\b[1-9][0-9]* (?:shells?|background tasks?)\b"#
    private static let footerAgents = #"\b[1-9][0-9]* agents?\b"#

    /// A footer agent count above `explainedAgents` keeps the prompt busy; the
    /// default 0 treats any agent count as running work.
    static func isEmpty(_ vt: String?, provider: String, explainedAgents: Int = 0) -> Bool {
        guard let prompt = prompt(vt, provider: provider) else { return false }
        // A wrapped prediction starts on the marker row. Faint rows below a
        // blank marker row are not a known prediction shape.
        if prompt.cells.count > prompt.first,
           prompt.cells.prefix(prompt.first).allSatisfy({ CharacterSet.whitespaces.contains($0.character) }) { return false }
        let input = typed(prompt.cells)
        if !input.isEmpty {
            guard input.allSatisfy(\.faint) else { return false }
            let text = String(String.UnicodeScalarView(prompt.cells.map(\.character)))
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if provider == "codex" {
                guard ["Ask Codex to do anything", "Ask a follow-up question", "Find and fix a bug in @filename",
                       "Explain this codebase", "Write tests for @filename", "Implement {feature}",
                       "Run /review on my current changes"].contains(text) else { return false }
            } else {
                // Claude generates arbitrary suggestions, including short
                // answers. Their native faint style identifies the unaccepted
                // prediction; wording is not an input-buffer contract.
                // The entire prompt and the recognized footer remain required.
            }
        }
        let footer = prompt.rows.dropFirst(prompt.footer).map {
            String(String.UnicodeScalarView($0.map(\.character))).trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
        if provider == "claude", footer.contains(where: { busy($0, explainedAgents: explainedAgents) }) { return false }
        if provider == "codex" {
            // The status line's items are user-configured: it opens with the
            // model and may omit the context segment ("GPT-6.1 Terra high ·
            // ~/cwd · thread title"). At most one row may name the context.
            guard (1...3).contains(footer.count), let first = footer.first, first.contains(" · "),
                  (first.lowercased().hasPrefix("gpt-") || first.lowercased().hasPrefix("openai")),
                  footer.filter({ $0.localizedCaseInsensitiveContains("context") }).count <= 1,
                  footer.dropFirst().allSatisfy({ value in
                      codexIdleHints.contains { value.hasPrefix($0) } || codexSegmentedIdleHint(value) })
            else { return false }
            // A running turn shows its status row just above the composer.
            if codexTurnRunning(prompt.rows, promptRow: prompt.row) { return false }
        } else {
            guard (2...10).contains(footer.count), let first = footer.first, separator(first),
                  footer.dropFirst().filter({ separator($0) }).isEmpty else { return false }
            for value in footer.dropFirst() {
                let waitingStatus = value.range(of:
                    #"^wait [0-9]+(?:\.[0-9]+)?% \| (?:cache [0-9]+% \| )?[0-9]+ CLAUDE\.md [0-9]+ MCPs [0-9]+ hooks$"#,
                    options: .regularExpression) != nil
                // Status-line cost under a dollar is shown in cents ("0.7¢ $0.09/h | …").
                let centsCost = value.range(of: #"^[0-9]+(?:\.[0-9]+)?¢ "#, options: .regularExpression) != nil
                // A finished slash command leaves a one-line result notice ("/rc failed").
                let commandNotice = value.range(of: #"^/[a-z][a-z0-9-]* failed$"#, options: .regularExpression) != nil
                // The status line names the model as "| [Name N.N]" ("[Fable 5.1]",
                // "[Haiku 5.5>]"), so a new model family needs no code change.
                let modelStatus = value.range(of: #"\| \[[A-Z][A-Za-z]* [0-9]+(?:\.[0-9]+)*[^\]|]*\]"#,
                    options: .regularExpression) != nil
                let known = value.hasPrefix("⏵") || value.hasPrefix("⏸") || value.hasPrefix("◈") ||
                    value.hasPrefix("+ ") || value.hasPrefix("$") || centsCost || commandNotice || waitingStatus ||
                    modelStatus ||
                    (value.contains(" | [") && ["Opus", "Sonnet", "Haiku"].contains(where: value.contains))
                guard known else { return false }
            }
        }
        return true
    }

    /// True only when the provider's prompt line is found and shows typed text
    /// that is not the faint native placeholder or prediction. An unreadable or
    /// unrecognized screen is not evidence of a draft; callers hold instead of
    /// starting a draft capture on a guess.
    static func hasTypedText(_ vt: String?, provider: String) -> Bool {
        guard let prompt = prompt(vt, provider: provider) else { return false }
        let input = typed(prompt.cells)
        return !input.isEmpty && !input.allSatisfy(\.faint)
    }

    /// Claude's settings overlay (/status, /config, /usage, /stats) and nothing
    /// else: its tab row, "Esc to cancel" as the last line, and no prompt line.
    /// It hides the prompt and footer; one Esc closes it.
    static func isClaudeSettingsOverlay(_ vt: String?) -> Bool {
        guard let vt, vt.utf8.count <= maximumScreenBytes, let rows = parse(vt),
              prompt(vt, provider: "claude") == nil else { return false }
        let lines = rows.map {
            String(String.UnicodeScalarView($0.map(\.character))).trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
        return lines.last == "Esc to cancel" && lines.contains {
            $0.split(whereSeparator: \.isWhitespace) == ["Settings", "Status", "Config", "Usage", "Stats"]
        }
    }

    /// Classifies the visible weekly-limit menu only; this is not evidence
    /// that the hidden editor is empty or authority to send a key. Bind any
    /// action separately to the current screen token and provider incarnation.
    static func isClaudeWeeklyLimitSelector(_ vt: String?) -> Bool {
        guard let vt, vt.utf8.count <= maximumScreenBytes, let rows = parse(vt) else { return false }
        let lines = rows.map {
            String(String.UnicodeScalarView($0.map(\.character))).trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
        guard lines.count >= 5 else { return false }
        let tail = Array(lines.suffix(5))
        guard tail[0] == "What do you want to do?", tail[4] == "Enter to confirm · Esc to cancel" else { return false }
        let choices = Array(tail[1...3])
        guard choices.filter({ $0.hasPrefix("❯ ") }).count == 1 else { return false }
        let clean = choices.map { $0.hasPrefix("❯ ") ? String($0.dropFirst(2)) : $0 }
        return clean[0] == "1. Stop and wait for limit to reset" &&
            clean[1].hasPrefix("2. Wait here, then continue automatically at ") &&
            clean[1].count > "2. Wait here, then continue automatically at ".count &&
            clean[2] == "3. Switch to usage credits"
    }

    /// The idle composer's hint row. After one Esc on an empty composer,
    /// Codex offers to edit the previous message; the composer is still empty
    /// and nothing runs. Any other hint ("ctrl + c again to quit", queueing)
    /// stays unrecognized.
    private static let codexIdleHints = ["? for shortcuts", "esc again to edit previous message"]

    /// Newer Codex idle hint row, its segments separated by runs of two or
    /// more spaces: "← for agents · ? for shortcuts", optionally followed by
    /// a right-aligned "⚠ N warning(s) · f2 to view". The hint segment is
    /// required; a warnings segment alone or any other segment is unrecognized.
    static func codexSegmentedIdleHint(_ value: String) -> Bool {
        let segments = value.components(separatedBy: "  ")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard (1...2).contains(segments.count), segments[0] == "← for agents · ? for shortcuts" else { return false }
        return segments.dropFirst().allSatisfy {
            $0.range(of: #"^⚠ [0-9]+ warnings? · f2 to view$"#, options: .regularExpression) != nil
        }
    }

    /// Codex's turn status ("• Working (12s • esc to interrupt)") sits in the
    /// rows directly above the composer while a turn runs.
    private static func codexTurnRunning(_ rows: [[Cell]], promptRow: Int) -> Bool {
        rows[max(0, promptRow - 4)..<promptRow].contains { row in
            let text = String(String.UnicodeScalarView(row.map(\.character))).trimmingCharacters(in: .whitespaces)
            return text.localizedCaseInsensitiveContains("esc to interrupt") ||
                text.range(of: #"^[•◦·]?\s*Working\b"#, options: .regularExpression) != nil
        }
    }

    private static func separator(_ value: String) -> Bool {
        value.count >= 4 && value.allSatisfy { "─━- ".contains($0) }
    }

    /// The input cells after the provider's marker (the marker row's count
    /// first), including rows a draft or a long prediction wraps onto, and the
    /// row where the footer starts (Claude's separator or Codex's blank row).
    private static func prompt(_ vt: String?, provider: String) -> (cells: [Cell], first: Int, rows: [[Cell]], footer: Int, row: Int)? {
        guard let vt, vt.utf8.count <= maximumScreenBytes, var rows = parse(vt) else { return nil }
        // Claude's prompt can sit near the top of a tall terminal. The engine
        // serializes the unused grid below its footer, too. Keep all content
        // rows, including wrapped input, and ignore only the empty grid tail.
        while let row = rows.last, row.allSatisfy({ CharacterSet.whitespaces.contains($0.character) }) {
            rows.removeLast()
        }
        let marker: Unicode.Scalar = provider == "codex" ? "›" : "❯"
        guard let index = rows.lastIndex(where: { row in
            row.drop(while: { CharacterSet.whitespaces.contains($0.character) }).first?.character == marker
        }), index >= max(0, rows.count - 14) else { return nil }
        let line = rows[index].drop(while: { CharacterSet.whitespaces.contains($0.character) })
        guard line.count >= 2, let second = line.dropFirst().first,
              CharacterSet.whitespaces.contains(second.character) else { return nil }
        // A draft can wrap below a blank first row; read on until the footer.
        var cells = Array(line.dropFirst(2)), footer = index + 1
        let first = cells.count
        while footer < rows.count {
            let text = String(String.UnicodeScalarView(rows[footer].map(\.character))).trimmingCharacters(in: .whitespaces)
            if text.isEmpty || separator(text) { break }
            cells.append(contentsOf: rows[footer]); footer += 1
        }
        return (cells, first, rows, footer, index)
    }

    /// Non-blank input cells. Only the native faint style marks a prediction:
    /// any other colour, or a caret cell, stays typed or unknown.
    private static func typed(_ cells: [Cell]) -> [Cell] {
        cells.filter { !CharacterSet.whitespaces.contains($0.character) }
    }

    /// Maintenance uses this only with the original worker and shell binding,
    /// no intervening input, and the exact transport control lease. It covers
    /// the retained Bash prompt that does not publish OSC 133 input marks.
    static func retainedShellIsEmpty(_ vt: String?) -> Bool { retainedShellPrompt(vt) == .empty }

    /// Positive evidence of typed shell input after the box prompt marker.
    static func retainedShellHasTypedText(_ vt: String?) -> Bool { retainedShellPrompt(vt) == .typed }

    enum RetainedShellPrompt { case empty, typed, unrecognized }

    static func retainedShellPrompt(_ vt: String?) -> RetainedShellPrompt {
        guard let vt, vt.utf8.count <= maximumScreenBytes, let parsed = parse(vt) else { return .unrecognized }
        func blank(_ cell: Cell) -> Bool { CharacterSet.whitespaces.contains(cell.character) }
        func box(_ scalar: Unicode.Scalar) -> Bool { (0x2500...0x257F).contains(scalar.value) }
        let rows = parsed.filter { !$0.allSatisfy(blank) }
        guard rows.count >= 2, let last = rows.last else { return .unrecognized }
        // The box-drawing prompt family: a header row opening the box, then a
        // closing row of box-drawing characters and one ❯, $ or % marker.
        // Anything after the marker must be blank or the faint suggestion
        // style; any other character is typed input, so it is not empty.
        let cells = Array(last.drop(while: blank))
        let header = String(String.UnicodeScalarView(rows[rows.count - 2].map(\.character))).trimmingCharacters(in: .whitespaces)
        guard let first = cells.first, ["╰", "└", "╚", "┗"].contains(first.character),
              let marker = cells.firstIndex(where: { ["❯", "$", "%"].contains($0.character) }),
              cells[..<marker].allSatisfy({ blank($0) || box($0.character) }),
              let opening = header.unicodeScalars.first, ["╭", "┌", "╔", "┏"].contains(opening),
              header.contains(" · ") else { return .unrecognized }
        return cells[(marker + 1)...].allSatisfy({ blank($0) || $0.faint }) ? .empty : .typed
    }

    private static func parse(_ vt: String) -> [[Cell]]? {
        let input = Array(vt.unicodeScalars)
        var rows: [[Cell]] = [[]]
        var dim = false, gray = false, offset = 0
        while offset < input.count {
            let c = input[offset]; offset += 1
            if c.value == 0x1b {
                guard offset < input.count else { return nil }
                let next = input[offset]; offset += 1
                if next == "[" {
                    let start = offset
                    while offset < input.count, input[offset].value < 0x40 || input[offset].value > 0x7e { offset += 1 }
                    guard offset < input.count, input[offset] == "m", offset - start <= 128 else { return nil }
                    let fields = String(String.UnicodeScalarView(input[start..<offset]))
                        .split(whereSeparator: { $0 == ";" || $0 == ":" }).compactMap { Int($0) }
                    offset += 1
                    let values = fields.isEmpty ? [0] : fields
                    var position = 0
                    while position < values.count {
                        let value = values[position]; position += 1
                        switch value {
                        case 0: dim = false; gray = false
                        case 2: dim = true
                        case 22: dim = false
                        case 39: gray = false
                        case 90: gray = true
                        case 30...37, 91...97: gray = false
                        case 38, 48, 58:
                            guard position < values.count else { return nil }
                            let mode = values[position]; position += 1
                            if mode == 5 {
                                guard position < values.count else { return nil }
                                if value == 38 { gray = values[position] == 8 }
                                position += 1
                            } else if mode == 2 {
                                guard position + 2 < values.count else { return nil }
                                let rgb = Array(values[position...position+2]); position += 3
                                guard rgb.allSatisfy({ (0...255).contains($0) }) else { return nil }
                                if value == 38 {
                                    gray = rgb.max()! - rgb.min()! <= 8 && rgb.min()! >= 64 && rgb.max()! <= 165
                                }
                            } else { return nil }
                        default: break
                        }
                    }
                } else if next == "]" {
                    var ended = false
                    while offset < input.count {
                        if input[offset].value == 7 { offset += 1; ended = true; break }
                        if input[offset].value == 0x1b, offset + 1 < input.count, input[offset + 1] == "\\" {
                            offset += 2; ended = true; break
                        }
                        offset += 1
                    }
                    guard ended else { return nil }
                } else { return nil }
            } else if c == "\n" {
                guard rows.count < 512 else { return nil }
                rows.append([])
            } else if c == "\r" {
                guard offset < input.count, input[offset] == "\n" else { return nil }
            } else if c == "\t" || c.value >= 32 && c.value != 127 {
                guard rows[rows.count - 1].count < 4096 else { return nil }
                rows[rows.count - 1].append(Cell(character: c == "\t" ? " " : c, faint: dim || gray))
            } else { return nil }
        }
        return rows
    }
}
