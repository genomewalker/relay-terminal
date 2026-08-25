import Foundation

enum HostSearch {
    static func score(query: String, candidate: String) -> Int? {
        let needle = normalized(query)
        let haystack = normalized(candidate)
        guard !needle.isEmpty else { return 0 }
        if haystack.hasPrefix(needle) { return 0 }
        if let range = haystack.range(of: needle) {
            return 10 + haystack.distance(from: haystack.startIndex, to: range.lowerBound)
        }

        var searchIndex = haystack.startIndex
        var gapPenalty = 0
        var previousMatch: String.Index?
        for character in needle {
            guard let match = haystack[searchIndex...].firstIndex(of: character) else { return nil }
            if let previousMatch {
                gapPenalty += haystack.distance(from: previousMatch, to: match) - 1
            }
            previousMatch = match
            searchIndex = haystack.index(after: match)
        }
        return 100 + gapPenalty
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }
}
