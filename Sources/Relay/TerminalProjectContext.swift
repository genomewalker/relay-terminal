import Foundation

struct TerminalProjectSnapshot: Equatable, Sendable {
    let directory: String
    let names: [String]

    var summary: String {
        guard !names.isEmpty else { return "No recognized top-level project files" }
        return "Top-level project files: " + names.joined(separator: ", ")
    }

    var projectKind: String {
        let lower = Set(names.map { $0.lowercased() })
        if lower.contains("package.swift") { return "swift" }
        if lower.contains("cargo.toml") { return "rust" }
        if lower.contains("go.mod") { return "go" }
        if lower.contains("pyproject.toml") || lower.contains("pytest.ini") { return "python" }
        if lower.contains("package.json") { return "node" }
        if lower.contains("cmakelists.txt") { return "cmake" }
        if lower.contains("makefile") || lower.contains("gnumakefile") { return "make" }
        return "generic"
    }
}

struct TerminalActionFeedback: Codable, Equatable, Sendable {
    var accepted = 0
    var rejected = 0

    var observations: Int { accepted + rejected }
    /// Beta(2, 2) prior prevents one early click from dominating ordering.
    var preference: Double { Double(accepted + 2) / Double(observations + 4) }
}

actor TerminalActionFeedbackStore {
    static let shared = TerminalActionFeedbackStore()

    private let defaults: UserDefaults
    private let storageKey = "relay.intelligence.action-feedback-v1"
    private var values: [String: TerminalActionFeedback]

    init(suiteName: String? = nil) {
        let defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        self.defaults = defaults
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([String: TerminalActionFeedback].self, from: data) {
            values = decoded
        } else {
            values = [:]
        }
    }

    func rank(
        _ candidates: [TerminalProjectAction],
        projectKind: String,
        agentKind: AgentKind
    ) -> [TerminalProjectAction] {
        candidates.enumerated().sorted { lhs, rhs in
            let left = values[Self.key(projectKind, agentKind, lhs.element.kind)] ?? TerminalActionFeedback()
            let right = values[Self.key(projectKind, agentKind, rhs.element.kind)] ?? TerminalActionFeedback()
            guard left.observations >= 3 || right.observations >= 3 else { return lhs.offset < rhs.offset }
            return left.preference == right.preference
                ? lhs.offset < rhs.offset
                : left.preference > right.preference
        }.map(\.element)
    }

    func record(key: String, accepted: Bool) {
        var feedback = values[key] ?? TerminalActionFeedback()
        if accepted { feedback.accepted += 1 } else { feedback.rejected += 1 }
        // Bound retained influence while preserving the learned ratio.
        if feedback.observations > 200 {
            feedback.accepted = max(0, feedback.accepted / 2)
            feedback.rejected = max(0, feedback.rejected / 2)
        }
        values[key] = feedback
        if let data = try? JSONEncoder().encode(values) { defaults.set(data, forKey: storageKey) }
    }

    func reset() {
        values.removeAll()
        defaults.removeObject(forKey: storageKey)
    }

    nonisolated static func key(
        _ projectKind: String,
        _ agentKind: AgentKind,
        _ actionKind: TerminalProjectActionKind
    ) -> String {
        [projectKind, agentKind.rawValue, actionKind.rawValue].joined(separator: "|")
    }
}

enum TerminalProjectActionKind: String, CaseIterable, Sendable {
    case readDocumentation
    case installDependencies
    case build
    case test
    case inspectProject
    case none
}

struct TerminalProjectAction: Equatable, Sendable {
    let kind: TerminalProjectActionKind
    let shellCommand: String
    let agentPrompt: String

    func suggestion(for agentKind: AgentKind) -> String {
        agentKind == .shell ? shellCommand : agentPrompt
    }
}

enum TerminalProjectActionPolicy {
    static func candidates(
        snapshot: TerminalProjectSnapshot,
        recentHistory: [String]
    ) -> [TerminalProjectAction] {
        let names = Set(snapshot.names.map { $0.lowercased() })
        let history = recentHistory.joined(separator: "\n").lowercased()
        var actions: [TerminalProjectAction] = []

        if let readme = snapshot.names.first(where: { $0.lowercased().hasPrefix("readme") }),
           !history.contains(readme.lowercased()) {
            actions.append(TerminalProjectAction(
                kind: .readDocumentation,
                shellCommand: "less \(shellQuote(readme))",
                agentPrompt: "Read \(readme) and summarize how to build, test, and install this project."
            ))
        }

        if names.contains("package.json"), !names.contains("node_modules"), !history.contains("npm install") {
            actions.append(TerminalProjectAction(
                kind: .installDependencies,
                shellCommand: "npm install",
                agentPrompt: "Inspect package.json, install its dependencies, and report any installation errors."
            ))
        }

        let buildSystems: [(markers: Set<String>, build: String?, test: String?)] = [
            (["package.swift"], "swift build", "swift test"),
            (["cargo.toml"], "cargo build", "cargo test"),
            (["go.mod"], nil, "go test ./..."),
            (["pyproject.toml", "pytest.ini"], nil, "python -m pytest"),
            (["package.json"], "npm run build", "npm test"),
            (["makefile", "gnumakefile"], "make", "make test"),
            (["cmakelists.txt"], "cmake -S . -B build", "cmake --build build"),
        ]

        for system in buildSystems where !system.markers.isDisjoint(with: names) {
            if let build = system.build, !history.contains(build.lowercased()) {
                actions.append(TerminalProjectAction(
                    kind: .build,
                    shellCommand: build,
                    agentPrompt: "Inspect the project configuration, then run \(build) and report any failures."
                ))
            }
            if let test = system.test {
                actions.append(TerminalProjectAction(
                    kind: .test,
                    shellCommand: test,
                    agentPrompt: "Run \(test), diagnose any failures, and summarize the result."
                ))
            }
            break
        }

        if actions.isEmpty, names.contains("src") || names.contains(".git") {
            actions.append(TerminalProjectAction(
                kind: .inspectProject,
                shellCommand: "find . -maxdepth 2 -type f | sort | head -80",
                agentPrompt: "Inspect the project structure and identify the documented build and test workflow."
            ))
        }
        return actions
    }

    static func suggestion(
        agentKind: AgentKind,
        snapshot: TerminalProjectSnapshot,
        recentHistory: [String]
    ) -> String? {
        candidates(snapshot: snapshot, recentHistory: recentHistory).first?.suggestion(for: agentKind)
    }

    private static func shellQuote(_ value: String) -> String {
        guard value.contains(where: { $0.isWhitespace || "'\"\\$`".contains($0) }) else { return value }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

actor TerminalProjectContextService {
    static let shared = TerminalProjectContextService()

    private struct Cached: Sendable {
        let snapshot: TerminalProjectSnapshot
        let date: Date
    }

    private var cache: [String: Cached] = [:]
    private let cacheLifetime: TimeInterval = 300

    func snapshot(for context: TerminalSuggestionContext) async -> TerminalProjectSnapshot? {
        let directory = context.directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard directory.hasPrefix("/"), !directory.contains("\n") else { return nil }
        let key = context.profile.id.uuidString + "\u{001F}" + directory
        if let cached = cache[key], Date().timeIntervalSince(cached.date) < cacheLifetime {
            return cached.snapshot
        }

        let profile = context.profile
        let snapshot = await Task.detached(priority: .utility) {
            Self.inspect(profile: profile, directory: directory)
        }.value
        if let snapshot { cache[key] = Cached(snapshot: snapshot, date: Date()) }
        if cache.count > 48 {
            let oldest = cache.min { $0.value.date < $1.value.date }?.key
            if let oldest { cache.removeValue(forKey: oldest) }
        }
        return snapshot
    }

    private nonisolated static func inspect(
        profile: ConnectionProfile,
        directory: String
    ) -> TerminalProjectSnapshot? {
        let names: [String]
        if profile.kind == .local {
            guard let listed = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return nil }
            names = listed
        } else if profile.backend == .relay {
            let ssh = Process()
            ssh.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            var arguments = ["-T", "-o", "ControlMaster=no", "-o", "ControlPath=~/.ssh/relay-%C"]
            arguments += profile.sshConnectionArguments
            arguments += [
                "~/.local/bin/relayd", "files", "list", "--path-b64",
                Data(directory.utf8).base64EncodedString(),
            ]
            ssh.arguments = arguments
            ssh.standardInput = FileHandle.nullDevice
            let output = Pipe()
            let errors = Pipe()
            ssh.standardOutput = output
            ssh.standardError = errors
            guard let captured = try? ProcessCapture.run(
                ssh, output: output, errors: errors, timeout: 4
            ), ssh.terminationStatus == 0,
                  let entries = try? JSONDecoder().decode([RemoteFileEntry].self, from: captured.standardOutput)
            else { return nil }
            names = entries.map(\.name)
        } else {
            return nil
        }

        let relevant = names.filter(isRelevant).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return TerminalProjectSnapshot(directory: directory, names: Array(relevant.prefix(32)))
    }

    private nonisolated static func isRelevant(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasPrefix("readme") || [
            "src", "tests", "test", "package.swift", "cargo.toml", "go.mod", "pyproject.toml",
            "pytest.ini", "package.json", "node_modules", "makefile", "gnumakefile", "cmakelists.txt",
            "install", "install.md", "requirements.txt", "environment.yml", ".git",
        ].contains(lower)
    }
}
