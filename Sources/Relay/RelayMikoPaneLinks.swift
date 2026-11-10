import Foundation

/// Finds pane names and ids in Miko's answer text and turns them into links that
/// reveal that pane. The characters of the answer are never changed; only link
/// attributes are added.
enum RelayMikoPaneLinks {
    static let scheme = "relay-pane"

    struct Match: Equatable {
        let range: Range<String.Index>
        let paneID: UUID
    }

    static func url(for paneID: UUID) -> URL {
        URL(string: scheme + "://" + paneID.uuidString.lowercased())!
    }

    static func paneID(from url: URL) -> UUID? {
        guard url.scheme == scheme, let host = url.host else { return nil }
        return UUID(uuidString: host)
    }

    /// Non-overlapping, longest-first matches on word boundaries. Names match
    /// exactly (case-sensitive); full ids and 8-character id prefixes match in any case.
    /// A name or prefix shared by several panes is ambiguous and never linked.
    static func matches(in text: String, panes: [(id: UUID, name: String)]) -> [Match] {
        var owners: [String: Set<UUID>] = [:]
        var caseInsensitive: Set<String> = []
        for pane in panes {
            let name = pane.name.trimmingCharacters(in: .whitespaces)
            if isLinkableName(name) { owners[name, default: []].insert(pane.id) }
            let id = pane.id.uuidString.lowercased()
            for term in [id, String(id.prefix(8))] {
                owners[term, default: []].insert(pane.id)
                caseInsensitive.insert(term)
            }
        }
        let terms = owners.compactMap { term, ids in ids.count == 1 ? (term, ids.first!) : nil }
            .sorted { $0.0.count != $1.0.count ? $0.0.count > $1.0.count : $0.0 < $1.0 }
        var claimed: [Match] = []
        for (term, paneID) in terms {
            let options: String.CompareOptions = caseInsensitive.contains(term) ? [.caseInsensitive] : []
            var start = text.startIndex
            while start < text.endIndex, let found = text.range(of: term, options: options, range: start..<text.endIndex) {
                start = found.upperBound
                guard isBoundary(text, before: found.lowerBound), isBoundary(text, after: found.upperBound),
                      !claimed.contains(where: { $0.range.overlaps(found) }) else { continue }
                claimed.append(Match(range: found, paneID: paneID))
            }
        }
        return claimed.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    static func attributed(_ text: String, panes: [(id: UUID, name: String)]) -> AttributedString {
        var result = AttributedString(text)
        for match in matches(in: text, panes: panes) {
            guard let lower = AttributedString.Index(match.range.lowerBound, within: result),
                  let upper = AttributedString.Index(match.range.upperBound, within: result) else { continue }
            result[lower..<upper].link = url(for: match.paneID)
        }
        return result
    }

    private static func isLinkableName(_ name: String) -> Bool {
        name.count >= 3 && name.unicodeScalars.allSatisfy { scalar in
            !CharacterSet.newlines.contains(scalar) && !CharacterSet.controlCharacters.contains(scalar) &&
                scalar.properties.generalCategory != .format
        }
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }

    private static func isBoundary(_ text: String, before index: String.Index) -> Bool {
        index == text.startIndex || !isWordCharacter(text[text.index(before: index)])
    }

    private static func isBoundary(_ text: String, after index: String.Index) -> Bool {
        index == text.endIndex || !isWordCharacter(text[index])
    }
}
