import AppKit
import Foundation

struct PaneArtifact: Identifiable {
    let id = UUID()
    let remotePath: String
    let data: Data

    var filename: String { URL(fileURLWithPath: remotePath).lastPathComponent }
    var image: NSImage? { NSImage(data: data) }
}

struct ImagePathDetector {
    private var boundaryTail = ""
    private var seen = Set<String>()
    private static let regex = try! NSRegularExpression(
        pattern: #"(?:^|[^A-Za-z0-9_.-])(?:file://)?(/[A-Za-z0-9_~.%+@:/-]+\.(?:png|jpe?g|gif|webp))"#,
        options: [.caseInsensitive]
    )
    private static let claudeScratchRegex = try! NSRegularExpression(
        pattern: #"(/tmp/claude-[0-9]+/[A-Za-z0-9_~.%+@:/-]+)(?:[\s)\]])"#,
        options: []
    )
    private static let relativeCodexRegex = try! NSRegularExpression(
        pattern: #"(?:^|[\s└])((?:\./)?\.codex/generated_images/[A-Za-z0-9_~.%+@:/-]+\.(?:png|jpe?g|gif|webp))"#,
        options: [.caseInsensitive, .anchorsMatchLines]
    )

    mutating func ingest(_ text: String) -> [String] {
        let candidate = boundaryTail + text
        boundaryTail = String(candidate.suffix(2_048))
        let stripped = candidate.replacingOccurrences(
            of: "\\x1B(?:[@-Z\\\\-_]|\\[[0-?]*[ -/]*[@-~])",
            with: "",
            options: .regularExpression
        )
        let range = NSRange(stripped.startIndex..., in: stripped)
        var discovered: [String] = []
        let matches = Self.regex.matches(in: stripped, range: range)
            + Self.claudeScratchRegex.matches(in: stripped, range: range)
            + Self.relativeCodexRegex.matches(in: stripped, range: range)
        for match in matches {
            guard let matchRange = Range(match.range(at: 1), in: stripped) else { continue }
            let encoded = String(stripped[matchRange])
            let path = encoded.removingPercentEncoding ?? encoded
            guard !seen.contains(path) else { continue }
            seen.insert(path)
            discovered.append(path)
        }
        return discovered
    }
}

enum ArtifactLinkResolver {
    private static let imageExtensions = Set(["png", "jpg", "jpeg", "gif", "webp"])
    private static let internalPrefix = "file:///__relay_artifact__/"
    private static let legacyInternalPrefix = "relay-artifact://open/"

    static func path(from link: String) -> String? {
        if link.hasPrefix(internalPrefix) || link.hasPrefix(legacyInternalPrefix) {
            let prefix = link.hasPrefix(internalPrefix) ? internalPrefix : legacyInternalPrefix
            let encoded = String(link.dropFirst(prefix.count))
            guard let data = Data(base64URLEncoded: encoded),
                  let path = String(data: data, encoding: .utf8) else { return nil }
            return isImagePath(path) ? path : nil
        }

        let path: String
        if let url = URL(string: link), url.isFileURL {
            path = url.path
        } else {
            path = link.removingPercentEncoding ?? link
        }
        return isImagePath(path) ? path : nil
    }

    static func link(for path: String) -> String {
        internalPrefix + Data(path.utf8).base64URLEncodedString()
    }

    private static func isImagePath(_ path: String) -> Bool {
        let cleaned = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.hasPrefix("/") || cleaned.hasPrefix(".codex/") || cleaned.hasPrefix("./.codex/") else {
            return false
        }
        if imageExtensions.contains(URL(fileURLWithPath: cleaned).pathExtension.lowercased()) {
            return true
        }
        return cleaned.hasPrefix("/tmp/claude-")
    }
}

enum ArtifactHyperlinkEncoder {
    private static let patterns = [
        try! NSRegularExpression(
            pattern: #"(?:file://)?(/[A-Za-z0-9_~.%+@:/-]+\.(?:png|jpe?g|gif|webp))"#,
            options: [.caseInsensitive]
        ),
        try! NSRegularExpression(
            pattern: #"(/tmp/claude-[0-9]+/[A-Za-z0-9_~.%+@:/-]+)"#
        ),
        try! NSRegularExpression(
            pattern: #"((?:\./)?\.codex/generated_images/[A-Za-z0-9_~.%+@:/-]+\.(?:png|jpe?g|gif|webp))"#,
            options: [.caseInsensitive]
        ),
    ]

    /// Adds zero-width OSC 8 links while preserving the visible terminal text.
    /// Chunks that already contain OSC 8 are left alone to avoid nested links.
    static func encode(_ data: Data) -> Data {
        guard data.range(of: Data("\u{001B}]8;".utf8)) == nil,
              let text = String(data: data, encoding: .utf8),
              text.range(of: ".png", options: .caseInsensitive) != nil
                || text.range(of: ".jpg", options: .caseInsensitive) != nil
                || text.range(of: ".jpeg", options: .caseInsensitive) != nil
                || text.range(of: ".gif", options: .caseInsensitive) != nil
                || text.range(of: ".webp", options: .caseInsensitive) != nil
                || text.contains("/tmp/claude-")
        else { return data }

        let mutable = NSMutableString(string: text)
        var ranges: [(range: NSRange, path: String)] = []
        for regex in patterns {
            let current = mutable as String
            let fullRange = NSRange(current.startIndex..., in: current)
            for match in regex.matches(in: current, range: fullRange) {
                guard let range = Range(match.range(at: 1), in: current) else { continue }
                let encodedPath = String(current[range])
                ranges.append((match.range(at: 1), encodedPath.removingPercentEncoding ?? encodedPath))
            }
        }

        // Multiple patterns can recognize the same path. Replace unique ranges
        // from the end so earlier UTF-16 offsets remain valid.
        var seen = Set<String>()
        for item in ranges.sorted(by: { $0.range.location > $1.range.location }) {
            let key = "\(item.range.location):\(item.range.length)"
            guard seen.insert(key).inserted else { continue }
            let visible = mutable.substring(with: item.range)
            let destination = ArtifactLinkResolver.link(for: item.path)
            mutable.replaceCharacters(
                in: item.range,
                with: "\u{001B}]8;;\(destination)\u{001B}\\\(visible)\u{001B}]8;;\u{001B}\\"
            )
        }
        return Data((mutable as String).utf8)
    }
}

private extension Data {
    init?(base64URLEncoded value: String) {
        var base64 = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }

    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Merges structured artifact frames with a text-path compatibility fallback.
/// A current relay worker normally sends the image bytes immediately after the
/// output that names them. Older workers only send terminal output, so Relay
/// fetches that path after a short grace period. A structured frame always wins
/// if both paths discover the same image.
final class TerminalArtifactCoordinator: @unchecked Sendable {
    private enum State {
        case scheduled
        case loading
        case presented
    }

    private let lock = NSLock()
    private var detector = ImagePathDetector()
    private var states: [String: State] = [:]

    func discover(in text: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return detector.ingest(text).filter { path in
            guard states[path] == nil else { return false }
            states[path] = .scheduled
            return true
        }
    }

    func beginFallback(for path: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard states[path] == .scheduled else { return false }
        states[path] = .loading
        return true
    }

    func acceptFallback(for path: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard states[path] == .loading else { return false }
        states[path] = .presented
        return true
    }

    func acceptStructured(for path: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard states[path] != .presented else { return false }
        states[path] = .presented
        return true
    }
}

enum ArtifactLoadError: LocalizedError {
    case failed(String)
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .failed(let message): message
        case .tooLarge: "Image exceeds Relay's 25 MiB preview limit"
        }
    }
}

enum RemoteArtifactLoader {
    static func load(path: String, profile: ConnectionProfile) async throws -> Data {
        try await Task.detached(priority: .utility) {
            if profile.kind == .local {
                let data = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
                guard data.count <= 25 << 20 else { throw ArtifactLoadError.tooLarge }
                return data
            }

            let process = Process()
            let output = Pipe()
            let errors = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            var arguments = [
                "-T",
                "-o", "ControlMaster=auto",
                "-o", "ControlPersist=10m",
                "-o", "ControlPath=~/.ssh/relay-%C"
            ]
            arguments += profile.sshConnectionArguments
            arguments += [
                "~/.local/bin/relayd", "artifact",
                "--path-b64", Data(path.utf8).base64EncodedString()
            ]
            process.arguments = arguments
            process.standardOutput = output
            process.standardError = errors
            let captured = try ProcessCapture.run(process, output: output, errors: errors)
            let data = captured.standardOutput
            let errorData = captured.standardError
            guard process.terminationStatus == 0 else {
                let message = String(data: errorData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw ArtifactLoadError.failed(message?.isEmpty == false ? message! : "Could not fetch remote image")
            }
            guard data.count <= 25 << 20 else { throw ArtifactLoadError.tooLarge }
            guard NSImage(data: data) != nil else { throw ArtifactLoadError.failed("Remote file is not a readable image") }
            return data
        }.value
    }
}

enum KittyImageEncoder {
    static func packets(for image: Data, imageID: UInt32, columns: Int = 44) -> [Data] {
        let encoded = image.base64EncodedString()
        let chunkSize = 4096
        var packets: [Data] = [Data("\r\n".utf8)]
        var offset = encoded.startIndex
        var first = true
        while offset < encoded.endIndex {
            let end = encoded.index(offset, offsetBy: chunkSize, limitedBy: encoded.endIndex) ?? encoded.endIndex
            let chunk = encoded[offset..<end]
            let more = end < encoded.endIndex ? 1 : 0
            let control = first
                ? "a=T,f=100,q=2,i=\(imageID),c=\(columns),m=\(more)"
                : "q=2,i=\(imageID),m=\(more)"
            packets.append(Data("\u{001B}_G\(control);\(chunk)\u{001B}\\".utf8))
            first = false
            offset = end
        }
        packets.append(Data("\r\n".utf8))
        return packets
    }
}
