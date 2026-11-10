import Foundation

/// Authorization comes from a fresh kernel-verified binding query, never the activity journal.
struct RelayAgentConversationControl: Equatable, Sendable {
    let binding: RelayAgentConversationBinding
    let lifecycle: String
    let revision: String
    let checkedAt: Date
    let observedAt: Date
    let inputRevision: UInt64
    var permitsSend: Bool {
        lifecycle == "quiet" && binding.processStart.hasPrefix("kernel:") &&
        !revision.isEmpty && revision.utf8.count <= 128 && Date().timeIntervalSince(checkedAt) < 5
    }
    var permitsInterrupt: Bool {
        lifecycle == "active" && binding.processStart.hasPrefix("kernel:") &&
        !revision.isEmpty && revision.utf8.count <= 128 && Date().timeIntervalSince(checkedAt) < 5
    }
}

/// A binding is supplied by provider discovery, never inferred from terminal text.
struct RelayAgentConversationBinding: Equatable, Codable, Sendable {
    let hostID: String
    let paneID: UUID
    let provider: String
    let processID: Int
    let processStart: String
    let sessionID: String
    var sourceIdentity: String? = nil
    var isValid: Bool {
        !hostID.isEmpty && ["codex", "claude"].contains(provider) && processID > 0 &&
        !processStart.isEmpty && !sessionID.isEmpty && sessionID.utf8.count <= 128
    }
}

/// A step from Agent details, as a tool call in the conversation: the
/// `ordinalFromEnd`-th most recent call to `toolName` (0 = newest). Steps and
/// transcript items share no id, so the match is by name and order and falls
/// back to the end of the conversation when the call is not in the loaded page.
struct RelayConversationFocus: Equatable, Sendable {
    let toolName: String
    let ordinalFromEnd: Int
    /// Distinguishes two clicks on the same step.
    var request = UUID()

    /// The focus for a step label such as "Using Bash", given how many newer
    /// steps used the same tool; nil for steps that are not tool calls.
    static func step(_ label: String, newerSameTool: Int) -> RelayConversationFocus? {
        guard let name = toolName(of: label) else { return nil }
        return RelayConversationFocus(toolName: name, ordinalFromEnd: newerSameTool)
    }

    static func toolName(of label: String) -> String? {
        guard label.hasPrefix("Using ") else { return nil }
        let name = String(label.dropFirst("Using ".count))
        return name.isEmpty || name == "tool" ? nil : name
    }

    /// The id of the matching tool item, or nil when the loaded page has none.
    func target(in items: [RelayAgentConversationItem]) -> String? {
        var remaining = ordinalFromEnd
        for item in items.reversed() where item.role == .tool {
            guard case .tool(let name, _, _)? = item.blocks.first,
                  name.caseInsensitiveCompare(toolName) == .orderedSame else { continue }
            if remaining == 0 { return item.id }
            remaining -= 1
        }
        return nil
    }
}

struct RelayAgentConversationItem: Equatable, Codable, Identifiable, Sendable {
    enum Role: String, Codable, Sendable { case user, assistant, tool, system }
    enum Block: Equatable, Codable, Sendable {
        case markdown(String)
        case code(language: String, source: String)
        case equation(String)
        case diagram(String)
        /// References resolve through the existing host-bound artifact transport.
        case artifact(id: String, kind: String)
        case providerImage(reference: String)
        case tool(name: String, status: String, summary: String)
    }
    let id: String
    let turnID: String?
    let role: Role
    let blocks: [Block]
    let revision: UInt64
    let complete: Bool
    var isValid: Bool {
        guard !id.isEmpty, id.utf8.count <= 256, blocks.count <= 256 else { return false }
        var total = 0
        for block in blocks {
            switch block {
            case .markdown(let source), .equation(let source), .diagram(let source): total += source.utf8.count
            case .code(let language, let source):
                guard language.utf8.count <= 128 else { return false }
                total += source.utf8.count
            case .providerImage(let reference):
                guard !reference.isEmpty, reference.utf8.count <= 4096, Data(base64Encoded: reference) != nil else { return false }
                total += reference.utf8.count
            case .artifact(let id, let kind):
                guard !id.isEmpty, id.utf8.count <= 4096, ["png", "jpeg", "gif", "webp", "svg", "pdf"].contains(kind) else { return false }
            case .tool(let name, let status, let summary):
                guard name.utf8.count <= 256, status.utf8.count <= 128 else { return false }
                total += summary.utf8.count
            }
            if total > 1_048_576 { return false }
        }
        return true
    }
}

/// Bounded, revision-aware projection of a single provider conversation.
/// The full provider transcript remains the durable record. A rebind clears this projection.
struct RelayAgentConversation: Equatable, Sendable {
    var maximumItems = 512
    private(set) var binding: RelayAgentConversationBinding?
    private(set) var items: [RelayAgentConversationItem] = []
    mutating func bind(_ binding: RelayAgentConversationBinding?) {
        let next = binding?.isValid == true ? binding : nil
        if self.binding != next { self.binding = next; items.removeAll() }
    }
    @discardableResult mutating func receive(_ item: RelayAgentConversationItem,
                                            binding: RelayAgentConversationBinding) -> Bool {
        guard self.binding == binding, binding.isValid, item.isValid else { return false }
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            guard item.revision > items[index].revision else { return false }
            items[index] = item
        } else {
            items.append(item)
            if items.count > maximumItems { items.removeFirst(items.count - maximumItems) }
        }
        return true
    }
}

/// Splits source Markdown, preserving fenced code verbatim. Unfinished blocks remain text
/// while streaming, so a partial delimiter never hides the assistant's output.
enum RelayAgentMarkdownBlocks {
    static func split(_ source: String) -> [RelayAgentConversationItem.Block] {
        guard source.utf8.count <= 1_048_576 else { return [.markdown("Message exceeds preview limit.")] }
        let lines = source.components(separatedBy: "\n")
        var blocks: [RelayAgentConversationItem.Block] = []
        var text: [String] = []
        func flush() {
            if !text.isEmpty { blocks.append(.markdown(text.joined(separator: "\n"))); text.removeAll() }
        }
        var index = 0
        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            var closing: String?
            var language: String?
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                let marker = line.first!
                let count = line.prefix(while: { $0 == marker }).count
                closing = String(repeating: String(marker), count: count)
                language = String(line.dropFirst(count)).trimmingCharacters(in: .whitespaces).lowercased()
            } else if line == "$$" { closing = "$$"; language = "math" }
            else if line == "\\[" { closing = "\\]"; language = "math" }
            guard let closing, let language else { text.append(lines[index]); index += 1; continue }
            var end = index + 1
            while end < lines.count && lines[end].trimmingCharacters(in: .whitespaces) != closing { end += 1 }
            guard end < lines.count else { text.append(contentsOf: lines[index...]); break }
            flush()
            let body = lines[(index + 1)..<end].joined(separator: "\n")
            switch language {
            case "mermaid": blocks.append(.diagram(body))
            case "math", "latex", "tex": blocks.append(.equation(body))
            default: blocks.append(.code(language: language, source: body))
            }
            index = end + 1
        }
        flush()
        return blocks
    }
}
