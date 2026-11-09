import SwiftUI

// Shared presentation for tool calls in both native chat surfaces: the CLI
// conversation timeline and the native harness conversation. Pure values so
// both views agree and tests can check them without rendering.

/// What a tool card communicates. Colour always comes with a symbol or a word.
enum RelayToolState: Equatable {
    /// The conversation is active and this is its latest, unanswered call.
    case running
    case failed
    case done
    /// A call whose result is a separate item, or a status Relay does not interpret.
    case other(String)

    static let failureWords: Set<String> = ["error", "failed", "failure", "rejected", "denied"]
    static let doneWords: Set<String> = ["completed", "complete", "done", "succeeded", "success"]
    static let callWords: Set<String> = ["requested", "started", "running", "in_progress", "inprogress", "pending"]

    /// `live` is true only for a call that is still the conversation's current step;
    /// provider transcripts never update a call item, so a status word alone
    /// cannot prove that a call is still running.
    init(status: String, live: Bool) {
        let word = status.lowercased()
        if Self.failureWords.contains(word) { self = .failed }
        else if live { self = .running }
        else if Self.doneWords.contains(word) { self = .done }
        else if Self.callWords.contains(word) { self = .other("Called") }
        else { self = .other(word.isEmpty ? "Unknown" : word.prefix(1).uppercased() + word.dropFirst()) }
    }

    /// Whether this call status may still be in flight (before liveness is applied).
    static func mayBeRunning(_ status: String) -> Bool { callWords.contains(status.lowercased()) }

    var role: RelayTheme.StatusRole {
        switch self {
        case .running: .pending
        case .failed: .danger
        case .done, .other: .neutral
        }
    }
    var label: String {
        switch self {
        case .running: "Running"
        case .failed: "Failed"
        case .done: "Done"
        case .other(let text): text
        }
    }
    /// Spoken with the role, e.g. "Error: Failed".
    var spoken: String { role.spoken(label) }
}

struct RelayToolPresentation: Equatable {
    enum LineKind: Equatable { case plain, added, removed, hunk, header }
    struct Line: Equatable { let text: String; let kind: LineKind }

    static let collapseLines = 12
    static let tabWidth = 8
    /// Inputs larger than this are shown as text, never parsed.
    static let maximumParsedInput = 16_384

    let name: String
    /// Tool name plus a short argument summary, e.g. "Bash · git status".
    let title: String
    let lines: [Line]
    let isDiff: Bool

    /// `status` decides whether `text` is the call's arguments (requested/running)
    /// or its output; output is never reinterpreted, even when it is JSON.
    init(tool: String, status: String = "requested", text: String) {
        let display = Self.displayName(tool)
        name = display
        var body = text
        var summary: String?
        var diff: [Line]?
        if RelayToolState.mayBeRunning(status), let object = Self.jsonObject(text) {
            summary = Self.argumentSummary(tool: tool, input: object)
            if let edit = Self.editDiff(object) { diff = edit; body = "" }
            else if let patch = object["input"] as? String ?? object["patch"] as? String, patch.contains("*** Begin Patch") {
                body = patch
            } else if let command = Self.commandText(object["command"]) { body = command }
            else if Set(object.keys).isSubset(of: Self.summarizedKeys) { body = "" }
        } else if tool == "Command", let first = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first {
            // Codex command items carry the command line, then its output.
            summary = Self.clip(String(first))
            body = String(text.dropFirst(first.count)).trimmingCharacters(in: .newlines)
        }
        title = summary.map { display + " · " + $0 } ?? display
        if let diff { lines = diff; isDiff = true }
        else if Self.isDiffShaped(tool: tool, text: body) {
            lines = Self.diffLines(body); isDiff = true
        } else {
            lines = body.isEmpty ? [] : body.split(separator: "\n", omittingEmptySubsequences: false)
                .map { Line(text: Self.expandTabs(String($0)), kind: .plain) }
            isDiff = false
        }
    }

    var lineCount: Int { lines.count }
    var collapsible: Bool { lines.count > Self.collapseLines }
    var hiddenLineCount: Int { max(0, lines.count - Self.collapseLines) }
    func visibleLines(expanded: Bool) -> ArraySlice<Line> {
        expanded || !collapsible ? lines[...] : lines.prefix(Self.collapseLines)
    }
    func visibleText(expanded: Bool) -> String { visibleLines(expanded: expanded).map(\.text).joined(separator: "\n") }
    static func expandLabel(hidden: Int) -> String { "Show \(hidden) more line\(hidden == 1 ? "" : "s")" }

    // MARK: Names and arguments

    static func displayName(_ tool: String) -> String {
        switch tool {
        case "Tool result": "Result"
        case "": "Tool"
        default: tool
        }
    }

    private static let summarizedKeys: Set<String> = ["file_path", "path", "notebook_path", "pattern", "glob", "query",
        "url", "description", "offset", "limit", "output_mode", "type", "-n", "-i", "head_limit"]

    static func jsonObject(_ text: String) -> [String: Any]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), trimmed.utf8.count <= maximumParsedInput,
              let data = trimmed.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func commandText(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        guard let parts = value as? [String], !parts.isEmpty else { return nil }
        // Codex shell calls arrive as ["bash", "-lc", "<command>"].
        if parts.count == 3, ["bash", "zsh", "sh"].contains((parts[0] as NSString).lastPathComponent),
           parts[1].hasPrefix("-"), parts[1].hasSuffix("c") { return parts[2] }
        return parts.joined(separator: " ")
    }

    static func argumentSummary(tool: String, input: [String: Any]) -> String? {
        if let command = commandText(input["command"]) { return clip(command) }
        for key in ["file_path", "notebook_path"] {
            if let path = input[key] as? String, !path.isEmpty { return clip(AgentLabelFormatter.pathComponent(path)) }
        }
        if let pattern = input["pattern"] as? String, !pattern.isEmpty { return clip(pattern) }
        if let path = input["path"] as? String, !path.isEmpty { return clip(AgentLabelFormatter.pathComponent(path)) }
        for key in ["query", "url", "description", "prompt", "subject"] {
            if let value = input[key] as? String, !value.isEmpty { return clip(value) }
        }
        return nil
    }

    /// First line, whitespace collapsed, at most 60 characters.
    static func clip(_ value: String) -> String {
        let first = value.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        let collapsed = first.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.count > 60 ? String(collapsed.prefix(59)) + "…" : collapsed
    }

    // MARK: Tabs

    /// Expands tabs to the next multiple of `width` so columns stay aligned in monospace.
    static func expandTabs(_ line: String, width: Int = tabWidth) -> String {
        guard line.contains("\t") else { return line }
        var result = ""
        var column = 0
        for character in line {
            if character == "\t" {
                let spaces = width - column % width
                result += String(repeating: " ", count: spaces); column += spaces
            } else { result.append(character); column += 1 }
        }
        return result
    }

    // MARK: Diffs

    static let diffTools: Set<String> = ["Edit", "MultiEdit", "apply_patch", "File changes"]

    /// Only edit tools or unified-diff/patch blocks are coloured; an ordinary line
    /// that happens to start with "-" (a list, a flag) stays plain.
    static func isDiffShaped(tool: String, text: String) -> Bool {
        if text.contains("*** Begin Patch") { return true }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let hunk = lines.contains { $0.hasPrefix("@@ ") || $0 == "@@" }
        let headers = lines.contains { $0.hasPrefix("--- ") } && lines.contains { $0.hasPrefix("+++ ") }
        if hunk && headers { return true }
        return diffTools.contains(tool) && (hunk || headers)
    }

    static func diffLines(_ text: String) -> [Line] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { raw in
            let line = expandTabs(String(raw))
            let kind: LineKind
            if line.hasPrefix("+++ ") || line.hasPrefix("--- ") || line.hasPrefix("*** ") || line.hasPrefix("diff --git") { kind = .header }
            else if line.hasPrefix("@@") { kind = .hunk }
            else if line.hasPrefix("+") { kind = .added }
            else if line.hasPrefix("-") { kind = .removed }
            else { kind = .plain }
            return Line(text: line, kind: kind)
        }
    }

    /// Claude Edit/MultiEdit inputs as removed and added lines.
    static func editDiff(_ input: [String: Any]) -> [Line]? {
        var pairs: [(String, String)] = []
        if let old = input["old_string"] as? String, let new = input["new_string"] as? String { pairs = [(old, new)] }
        else if let edits = input["edits"] as? [[String: Any]] {
            pairs = edits.compactMap { edit in
                guard let old = edit["old_string"] as? String, let new = edit["new_string"] as? String else { return nil }
                return (old, new)
            }
        }
        guard !pairs.isEmpty else { return nil }
        var lines: [Line] = []
        for (index, pair) in pairs.enumerated() {
            if index > 0 { lines.append(Line(text: "@@", kind: .hunk)) }
            if !pair.0.isEmpty {
                lines += pair.0.split(separator: "\n", omittingEmptySubsequences: false).map { Line(text: "-" + expandTabs(String($0)), kind: .removed) }
            }
            if !pair.1.isEmpty {
                lines += pair.1.split(separator: "\n", omittingEmptySubsequences: false).map { Line(text: "+" + expandTabs(String($0)), kind: .added) }
            }
        }
        return lines
    }

    // MARK: Liveness

    /// Indices of call items that are still the conversation's current step: the
    /// trailing run of unanswered calls while the conversation is active.
    static func liveIndices(statuses: [String?], active: Bool) -> Set<Int> {
        guard active else { return [] }
        var live = Set<Int>()
        for index in statuses.indices.reversed() {
            guard let status = statuses[index], RelayToolState.mayBeRunning(status) else { break }
            live.insert(index)
        }
        return live
    }

    static func elapsed(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        if total < 60 { return "\(total) s" }
        if total < 3600 { return "\(total / 60) min" + (total % 60 > 0 ? " \(total % 60) s" : "") }
        return "\(total / 3600) h \(total % 3600 / 60) min"
    }
}

/// Host-transport failures carry a job handle and replay guidance meant for
/// diagnostics, not for the reader. Show a plain sentence and keep the raw text.
enum RelayConversationErrorText {
    static let hostUnavailable = "Couldn't load the conversation from the host. Try again."

    static func isInfrastructure(_ raw: String) -> Bool {
        let markers = ["outcome unavailable", "Do not replay", "job job-", "Host execution failed",
                       "invalid Relay session catalog", "isn’t in the correct format", "isn't in the correct format"]
        return markers.contains { raw.localizedCaseInsensitiveContains($0) }
    }

    /// The sentence to show, plus the raw text for a tooltip/details when it was replaced.
    static func userFacing(_ raw: String) -> (message: String, detail: String?) {
        isInfrastructure(raw) ? (hostUnavailable, raw) : (raw, nil)
    }
}

// MARK: - Views

/// Tool output in monospace with tabs expanded, diff colouring, and a line clamp.
struct RelayToolOutputView: View {
    let axID: String
    let presentation: RelayToolPresentation
    var failed = false
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: RelayTheme.spacing(0)) {
            ScrollView(.horizontal, showsIndicators: false) {
                Group {
                    if presentation.isDiff {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(presentation.visibleLines(expanded: expanded).enumerated()), id: \.offset) { _, line in
                                Self.diffLine(line)
                            }
                        }
                    } else {
                        Text(presentation.visibleText(expanded: expanded))
                            .lineSpacing(RelayAgentDesign.monoLineSpacing)
                            .foregroundStyle(failed ? RelayTheme.text : RelayAgentDesign.secondaryInk)
                    }
                }
                .font(RelayAgentDesign.mono)
                .textSelection(.enabled).fixedSize(horizontal: true, vertical: true)
                .padding(.horizontal, RelayTheme.spacing(10)).padding(.vertical, RelayTheme.spacing(8))
            }
            if presentation.collapsible {
                Button(expanded ? "Show fewer lines" : RelayToolPresentation.expandLabel(hidden: presentation.hiddenLineCount)) {
                    expanded.toggle()
                }
                .buttonStyle(RelayAgentQuietButtonStyle())
                .padding(.horizontal, RelayTheme.spacing(4)).padding(.bottom, RelayTheme.spacing(4))
                .accessibilityIdentifier(axID + ".expand")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RelayAgentDesign.codeFill, in: RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(6)))
    }

    static func role(_ kind: RelayToolPresentation.LineKind) -> RelayTheme.StatusRole? {
        switch kind {
        case .added: .success
        case .removed: .danger
        case .plain, .hunk, .header: nil
        }
    }

    @ViewBuilder static func diffLine(_ line: RelayToolPresentation.Line) -> some View {
        let role = role(line.kind)
        Text(line.text.isEmpty ? " " : line.text)
            .foregroundStyle(role?.color ?? (line.kind == .plain ? RelayAgentDesign.secondaryInk : RelayAgentDesign.tertiaryInk))
            .padding(.vertical, 1).padding(.horizontal, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(role.map { $0.color.opacity(0.13) } ?? .clear)
    }
}

/// The card state: a spinner with elapsed time while running, the role symbol and
/// word otherwise. Elapsed time counts from when Relay first displayed the call,
/// because provider transcripts carry no start time.
struct RelayToolStateBadge: View {
    let state: RelayToolState
    @State private var shownAt = Date()

    var body: some View {
        HStack(spacing: RelayTheme.spacing(4)) {
            switch state {
            case .running:
                ProgressView().controlSize(.mini).frame(width: 12, height: 12)
                TimelineView(.periodic(from: shownAt, by: 1)) { context in
                    Text("Running · " + RelayToolPresentation.elapsed(context.date.timeIntervalSince(shownAt)))
                        .monospacedDigit()
                }
            case .failed:
                Image(systemName: state.role.symbol).font(RelayTheme.font(size: 10, weight: .semibold))
                Text(state.label).fontWeight(.semibold)
            case .done, .other:
                Text(state.label)
            }
        }
        .font(RelayAgentDesign.meta)
        .foregroundStyle(state == .failed ? state.role.color : RelayAgentDesign.tertiaryInk)
        .lineLimit(1).fixedSize()
        .help(state == .running ? "Elapsed since Relay displayed this call" : "")
        .accessibilityElement(children: .combine)
        .accessibilityLabel(state.spoken)
    }
}
