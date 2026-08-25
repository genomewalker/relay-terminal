import Darwin
import Foundation

enum SSHConfigDiscovery {
    static func hosts(
        configURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh/config")
    ) -> [String] {
        let sshDirectory = configURL.deletingLastPathComponent()
        var visited = Set<String>()
        var aliases: [String] = []
        read(configURL, sshDirectory: sshDirectory, visited: &visited, aliases: &aliases)
        var seen = Set<String>()
        return aliases.filter { seen.insert($0).inserted }
    }

    static func literalHosts(in contents: String) -> [String] {
        contents
            .split(whereSeparator: \Character.isNewline)
            .flatMap { line -> [String] in
                let words = tokenize(String(line))
                guard words.first?.lowercased() == "host" else { return [] }
                return words.dropFirst().filter(isLiteralHost)
            }
    }

    private static func read(
        _ url: URL,
        sshDirectory: URL,
        visited: inout Set<String>,
        aliases: inout [String]
    ) {
        let path = url.standardizedFileURL.path
        guard visited.insert(path).inserted,
              let contents = try? String(contentsOf: url, encoding: .utf8) else { return }

        for rawLine in contents.split(whereSeparator: \Character.isNewline) {
            let words = tokenize(String(rawLine))
            guard let keyword = words.first?.lowercased() else { continue }
            if keyword == "host" {
                aliases.append(contentsOf: words.dropFirst().filter(isLiteralHost))
            } else if keyword == "include" {
                for pattern in words.dropFirst() {
                    for includedURL in expandedURLs(for: pattern, relativeTo: sshDirectory) {
                        read(includedURL, sshDirectory: sshDirectory, visited: &visited, aliases: &aliases)
                    }
                }
            }
        }
    }

    private static func isLiteralHost(_ value: String) -> Bool {
        !value.isEmpty && !value.hasPrefix("!") && !value.contains("*") && !value.contains("?")
    }

    private static func expandedURLs(for pattern: String, relativeTo sshDirectory: URL) -> [URL] {
        var expanded = pattern
        if expanded == "~" {
            expanded = FileManager.default.homeDirectoryForCurrentUser.path
        } else if expanded.hasPrefix("~/") {
            expanded = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(String(expanded.dropFirst(2))).path
        } else if !expanded.hasPrefix("/") {
            expanded = sshDirectory.appendingPathComponent(expanded).path
        }

        var matches = glob_t()
        defer { globfree(&matches) }
        guard glob(expanded, GLOB_NOSORT, nil, &matches) == 0,
              let paths = matches.gl_pathv else { return [] }
        return (0..<Int(matches.gl_pathc)).compactMap { index in
            paths[index].map { URL(fileURLWithPath: String(cString: $0)) }
        }
    }

    private static func tokenize(_ line: String) -> [String] {
        var words: [String] = []
        var word = ""
        var quote: Character?
        var escaped = false

        func finishWord() {
            if !word.isEmpty {
                words.append(word)
                word = ""
            }
        }

        for character in line {
            if escaped {
                word.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if let activeQuote = quote {
                if character == activeQuote { quote = nil } else { word.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "#" {
                break
            } else if character.isWhitespace {
                finishWord()
            } else {
                word.append(character)
            }
        }
        if escaped { word.append("\\") }
        finishWord()
        return words
    }
}
