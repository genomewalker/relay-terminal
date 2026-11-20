import SwiftUI

// Structured file-edit and shell cards from the conversation reader. A card is
// optional: without one, or when it fails validation, the item keeps its
// generic tool row. Everything shown comes from the provider transcript; absent
// fields stay absent (no invented exit codes or durations).

struct RelayToolCard: Equatable, Codable, Sendable {
    struct Hunk: Equatable, Codable, Sendable {
        let header: String
        let lines: [String]
    }
    struct File: Equatable, Codable, Sendable {
        let path: String
        let change: String
        var movePath: String? = nil
        let added: Int
        let removed: Int
        let hunks: [Hunk]
        var omittedLines: Int? = nil
        var inferred: Bool? = nil
    }
    let kind: String
    var files: [File]? = nil
    var omittedFiles: Int? = nil
    var command: String? = nil
    var stdout: String? = nil
    var stderr: String? = nil
    /// Codex reports one combined stream.
    var output: String? = nil
    var exitCode: Int? = nil
    var durationMs: Int? = nil
    var interrupted: Bool? = nil
    /// Claude reports a failed tool call, which is not a process exit status.
    var toolError: Bool? = nil
    var outputTruncated: Bool? = nil

    static let maximumBytes = 96 << 10

    /// Decodes a card without failing the surrounding snapshot: a malformed
    /// card becomes nil and the item keeps its generic row.
    struct Lenient: Decodable {
        let value: RelayToolCard?
        init(from decoder: Decoder) throws { value = try? RelayToolCard(from: decoder) }
    }

    /// Bounds match the host reader; anything larger or of another kind is refused.
    var isValid: Bool {
        switch kind {
        case "edit":
            guard let files, !files.isEmpty, files.count <= 16 else { return false }
            var lines = 0
            for file in files {
                guard !file.path.isEmpty, file.path.utf8.count <= 4096, ["update", "add", "delete"].contains(file.change),
                      file.added >= 0, file.removed >= 0, file.hunks.count <= 400, (file.movePath?.utf8.count ?? 0) <= 4096 else { return false }
                lines += file.hunks.reduce(0) { $0 + $1.lines.count }
            }
            return lines <= 400 * 16 && byteCount <= Self.maximumBytes
        case "shell":
            return files == nil && (command?.utf8.count ?? 0) <= 16_384 && byteCount <= Self.maximumBytes
        default:
            return false
        }
    }

    var byteCount: Int {
        var total = (command?.utf8.count ?? 0) + (stdout?.utf8.count ?? 0) + (stderr?.utf8.count ?? 0) + (output?.utf8.count ?? 0)
        for file in files ?? [] {
            total += file.path.utf8.count + (file.movePath?.utf8.count ?? 0)
            for hunk in file.hunks { total += hunk.header.utf8.count + hunk.lines.reduce(0) { $0 + $1.utf8.count + 1 } }
        }
        return total
    }

    var added: Int { (files ?? []).reduce(0) { $0 + $1.added } }
    var removed: Int { (files ?? []).reduce(0) { $0 + $1.removed } }

    /// Card title: the command, or the edited file name(s).
    var title: String {
        if kind == "shell" { return RelayToolPresentation.clip(command ?? "Command") }
        guard let files, let first = files.first else { return "File change" }
        let name = (first.path as NSString).lastPathComponent
        let others = files.count - 1 + (omittedFiles ?? 0)
        return others > 0 ? "\(name) and \(others) more" : name
    }

    /// Short facts for the header, only from reported fields.
    var facts: [String] {
        if kind == "edit" {
            let hunks = (files ?? []).reduce(0) { $0 + $1.hunks.count }
            var facts = ["+\(added)", "−\(removed)"]
            if hunks > 1 { facts.insert("\(hunks) hunks", at: 0) }
            if (files ?? []).contains(where: { $0.inferred == true }) { facts.append("inferred") }
            return facts
        }
        var facts: [String] = []
        if let exitCode { facts.append("exit \(exitCode)") }
        if let durationMs { facts.append(Self.duration(durationMs)) }
        if interrupted == true { facts.append("interrupted") }
        return facts
    }

    static func duration(_ milliseconds: Int) -> String {
        if milliseconds < 1000 { return "\(milliseconds) ms" }
        if milliseconds < 60_000 {
            let tenths = (milliseconds + 50) / 100
            return "\(tenths / 10).\(tenths % 10) s"
        }
        return RelayToolPresentation.elapsed(TimeInterval(milliseconds) / 1000)
    }

    /// Whether this card shows a failure; a non-zero exit is a failure even when
    /// the provider marked the item completed.
    func failed(status: String) -> Bool {
        if RelayToolState(status: status, live: false) == .failed || toolError == true { return true }
        if let exitCode, exitCode != 0 { return true }
        return false
    }

    /// Indices of call items folded into a later result card for the same call,
    /// so an edit or command shows once. Calls without a carded result stay.
    static func foldedCalls(_ items: [(callID: String?, carded: Bool, status: String?)]) -> Set<Int> {
        var carded = Set<String>()
        var folded = Set<Int>()
        for index in items.indices.reversed() {
            guard let id = items[index].callID, !id.isEmpty else { continue }
            if items[index].carded { carded.insert(id) }
            else if let status = items[index].status, RelayToolState.mayBeRunning(status), carded.contains(id) { folded.insert(index) }
        }
        return folded
    }

    /// Diff lines for one file: hunk headers then classified lines.
    static func lines(_ file: File) -> [RelayToolPresentation.Line] {
        var result: [RelayToolPresentation.Line] = []
        for hunk in file.hunks {
            if !hunk.header.isEmpty { result.append(.init(text: hunk.header, kind: .hunk)) }
            for raw in hunk.lines {
                let line = RelayToolPresentation.expandTabs(raw)
                let kind: RelayToolPresentation.LineKind = line.hasPrefix("+") ? .added : line.hasPrefix("-") ? .removed : .plain
                result.append(.init(text: line, kind: kind))
            }
        }
        return result
    }
}

/// One edit or shell call as a single card: a header with title, facts and
/// state, and the diff or output below.
struct RelayAgentToolCardView: View {
    let axID: String
    let card: RelayToolCard
    let status: String
    private let failed: Bool
    @State private var open: Bool

    init(axID: String, card: RelayToolCard, status: String) {
        self.axID = axID; self.card = card; self.status = status
        let failed = card.failed(status: status)
        self.failed = failed
        // Edits and failures open; successful command output waits for a click.
        _open = State(initialValue: card.kind == "edit" || failed)
    }

    private var symbol: String { card.kind == "edit" ? "plus.forwardslash.minus" : "terminal" }
    private var stateLabel: String {
        if card.kind == "shell", card.toolError == true { return "Tool error" }
        if failed { return "Failed" }
        return card.kind == "edit" ? "Edited" : "Done"
    }

    var body: some View {
        RelayAgentDisclosureRow(axID: axID, open: $open) {
            HStack(spacing: RelayTheme.spacing(6)) {
                Image(systemName: symbol).font(RelayTheme.font(size: 10)).frame(width: 12)
                    .foregroundStyle(RelayAgentDesign.tertiaryInk).accessibilityHidden(true)
                Text(card.title)
                    .font(card.kind == "shell" ? RelayAgentDesign.mono : RelayAgentDesign.label)
                    .foregroundStyle(Color.primary.opacity(0.8)).lineLimit(1).truncationMode(.middle)
                ForEach(Array(card.facts.enumerated()), id: \.offset) { _, fact in
                    Text(fact).font(RelayAgentDesign.meta).monospacedDigit()
                        .foregroundStyle(factColor(fact)).lineLimit(1).fixedSize()
                }
                HStack(spacing: RelayTheme.spacing(3)) {
                    if failed { Image(systemName: RelayTheme.StatusRole.danger.symbol).font(RelayTheme.font(size: 10, weight: .semibold)) }
                    Text(stateLabel).fontWeight(failed ? .semibold : .regular)
                }
                .font(RelayAgentDesign.meta).lineLimit(1).fixedSize()
                .foregroundStyle(failed ? RelayTheme.StatusRole.danger.color : RelayAgentDesign.tertiaryInk)
            }
        } detail: {
            VStack(alignment: .leading, spacing: RelayTheme.spacing(6)) {
                if card.kind == "edit" { editDetail } else { shellDetail }
            }
            .overlay(alignment: .leading) {
                if failed { Rectangle().fill(RelayTheme.StatusRole.danger.color).frame(width: 2) }
            }
        }
        .accessibilityLabel(accessibilityText)
    }

    private func factColor(_ fact: String) -> Color {
        if fact.hasPrefix("+") { return RelayTheme.StatusRole.success.color }
        if fact.hasPrefix("−") { return RelayTheme.StatusRole.danger.color }
        return RelayAgentDesign.tertiaryInk
    }

    private var accessibilityText: String {
        (card.kind == "edit" ? "File edit " : "Command ") + card.title + ", " + card.facts.joined(separator: ", ") + ", " + stateLabel
    }

    @ViewBuilder private var editDetail: some View {
        ForEach(Array((card.files ?? []).enumerated()), id: \.offset) { index, file in
            VStack(alignment: .leading, spacing: RelayTheme.spacing(3)) {
                HStack(spacing: RelayTheme.spacing(6)) {
                    Text(file.movePath.map { file.path + " → " + $0 } ?? file.path)
                        .font(RelayAgentDesign.mono).foregroundStyle(RelayAgentDesign.secondaryInk)
                        .lineLimit(1).truncationMode(.head).textSelection(.enabled)
                    Text(Self.changeLabel(file)).font(RelayAgentDesign.meta).foregroundStyle(RelayAgentDesign.tertiaryInk).fixedSize()
                }
                if file.inferred == true {
                    Text("No patch was reported; showing the requested before and after text.")
                        .font(RelayAgentDesign.meta).foregroundStyle(RelayAgentDesign.tertiaryInk)
                }
                let lines = RelayToolCard.lines(file)
                if lines.isEmpty {
                    Text(file.change == "delete" ? "File deleted." : "No diff recorded.")
                        .font(RelayAgentDesign.meta).foregroundStyle(RelayAgentDesign.tertiaryInk)
                } else {
                    RelayAgentCardLines(axID: axID + ".file." + String(index), lines: lines, diff: true)
                }
                if let omitted = file.omittedLines, omitted > 0 {
                    Text("\(omitted) more line\(omitted == 1 ? "" : "s") not shown").font(RelayAgentDesign.meta)
                        .foregroundStyle(RelayAgentDesign.tertiaryInk)
                }
            }
        }
        if let omitted = card.omittedFiles, omitted > 0 {
            Text("\(omitted) more file\(omitted == 1 ? "" : "s") not shown").font(RelayAgentDesign.meta)
                .foregroundStyle(RelayAgentDesign.tertiaryInk)
        }
    }

    static func changeLabel(_ file: RelayToolCard.File) -> String {
        switch file.change {
        case "add": "new file"
        case "delete": "deleted"
        default: file.movePath == nil ? "modified" : "moved"
        }
    }

    @ViewBuilder private var shellDetail: some View {
        if let command = card.command, !command.isEmpty {
            RelayAgentCardLines(axID: axID + ".command", lines: [.init(text: "$ " + command, kind: .plain)], diff: false)
        }
        stream("Combined output", card.output, suffix: "output")
        stream("stdout", card.stdout, suffix: "stdout")
        stream("stderr", card.stderr, suffix: "stderr")
        if (card.output ?? "").isEmpty && (card.stdout ?? "").isEmpty && (card.stderr ?? "").isEmpty {
            Text("No output recorded.").font(RelayAgentDesign.meta).foregroundStyle(RelayAgentDesign.tertiaryInk)
        }
        if card.outputTruncated == true {
            Text("Earlier output not shown; showing the end.").font(RelayAgentDesign.meta).foregroundStyle(RelayAgentDesign.tertiaryInk)
        }
    }

    @ViewBuilder private func stream(_ label: String, _ text: String?, suffix: String) -> some View {
        if let text, !text.isEmpty {
            VStack(alignment: .leading, spacing: RelayTheme.spacing(2)) {
                Text(label).font(RelayAgentDesign.meta).foregroundStyle(RelayAgentDesign.tertiaryInk)
                RelayAgentCardLines(axID: axID + "." + suffix,
                                    lines: text.split(separator: "\n", omittingEmptySubsequences: false)
                                        .map { .init(text: RelayToolPresentation.expandTabs(String($0)), kind: .plain) },
                                    diff: false)
            }
        }
    }
}

/// Monospace lines with the shared diff colouring and line clamp.
struct RelayAgentCardLines: View {
    let axID: String
    let lines: [RelayToolPresentation.Line]
    let diff: Bool
    @State private var expanded = false

    private var collapsible: Bool { lines.count > RelayToolPresentation.collapseLines }
    private var visible: ArraySlice<RelayToolPresentation.Line> {
        expanded || !collapsible ? lines[...] : lines.prefix(RelayToolPresentation.collapseLines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                Group {
                    if diff {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(visible.enumerated()), id: \.offset) { _, line in RelayToolOutputView.diffLine(line) }
                        }
                    } else {
                        Text(visible.map(\.text).joined(separator: "\n"))
                            .lineSpacing(RelayAgentDesign.monoLineSpacing).foregroundStyle(RelayAgentDesign.secondaryInk)
                    }
                }
                .font(RelayAgentDesign.mono).textSelection(.enabled).fixedSize(horizontal: true, vertical: true)
                .padding(.horizontal, RelayTheme.spacing(10)).padding(.vertical, RelayTheme.spacing(6))
            }
            if collapsible {
                Button(expanded ? "Show fewer lines" : RelayToolPresentation.expandLabel(hidden: lines.count - RelayToolPresentation.collapseLines)) {
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
}
