import AppKit
import CryptoKit
import Foundation
import ImageIO

struct PaneArtifact: Identifiable {
    let id = UUID()
    let remotePath: String
    let data: Data
    let contentIdentity: String

    init(remotePath: String, data: Data) {
        self.remotePath = remotePath
        self.data = data
        var hasher = SHA256()
        hasher.update(data: Data(remotePath.utf8))
        hasher.update(data: Data([0]))
        hasher.update(data: data)
        contentIdentity = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    var filename: String { TerminalPathSyntax.lastComponent(remotePath) }
    var image: NSImage? { NSImage(data: data) }
}

enum TerminalImageNormalizer {
    private static let maximumPixelDimension = 4_096
    private static let pngSignature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    /// Kitty graphics payloads declare PNG format, so JPEG, WebP, GIF and SVG
    /// assets must be normalized before entering the terminal byte stream.
    /// Downsampling bounds both terminal traffic and renderer memory.
    @MainActor
    static func pngData(from data: Data) -> Data? {
        // Generated assets are overwhelmingly PNG. Keep that common path
        // zero-copy so opening an image does not add decode work or UI latency.
        if data.starts(with: pngSignature) { return data }
        // NSImage's SVG rasterizer requires an interactive AppKit session on
        // some hosted Macs. CI still validates SVG detection and routing, but
        // leaves the AppKit integration path to local/application tests.
        if RelayLaunchMode.isRunningTests,
           ProcessInfo.processInfo.environment["RELAY_HEADLESS_TESTING"] == "1",
           String(decoding: data.prefix(256), as: UTF8.self).localizedCaseInsensitiveContains("<svg") {
            return nil
        }
        var image: CGImage?
        if let source = CGImageSourceCreateWithData(data as CFData, nil) {
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumPixelDimension,
            ] as CFDictionary)
        }
        if image == nil, let vector = NSImage(data: data) {
            var proposed = NSRect(origin: .zero, size: vector.size)
            image = vector.cgImage(forProposedRect: &proposed, context: nil, hints: nil)
        }
        guard let image else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}

/// Remembers explicit closes without retaining remote paths or image bytes.
/// The digest includes both path and content, so a rewritten image at the same
/// path is still treated as a new artifact and can be presented normally.
enum ArtifactDismissalStore {
    private static let prefix = "relay.artifact-dismissals."
    private static let limit = 32

    static func load(paneID: UUID, defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: key(paneID)) ?? [])
    }

    static func record(_ identity: String, paneID: UUID, defaults: UserDefaults = .standard) {
        var identities = defaults.stringArray(forKey: key(paneID)) ?? []
        identities.removeAll { $0 == identity }
        identities.append(identity)
        if identities.count > limit { identities.removeFirst(identities.count - limit) }
        defaults.set(identities, forKey: key(paneID))
    }

    static func clear(paneID: UUID, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key(paneID))
    }

    private static func key(_ paneID: UUID) -> String {
        prefix + paneID.uuidString.lowercased()
    }
}

struct ImagePathDetector {
    private var boundaryTail = ""
    private var seen = Set<String>()
    private var controlStripper = TerminalControlSequenceStripper()

    mutating func ingest(_ text: String) -> [String] {
        let candidate = boundaryTail + controlStripper.ingest(text)
        boundaryTail = String(candidate.suffix(2_048))
        var discovered: [String] = []
        for link in TerminalLinkScanner.links(in: candidate) {
            guard case .image(let encoded) = TerminalLinkResolver.target(from: link.value) else { continue }
            let path = encoded.removingPercentEncoding ?? encoded
            guard !seen.contains(path) else { continue }
            seen.insert(path)
            discovered.append(path)
        }
        return discovered
    }
}

/// Removes terminal control sequences from the artifact compatibility stream.
/// The state survives packet boundaries, so an SGR/OSC split across SSH reads
/// cannot leak escape bytes into a path token. The rendered stream is untouched.
struct TerminalControlSequenceStripper {
    private enum State { case text, escape, csi, osc, oscEscape, controlString, controlStringEscape }
    private var state: State = .text

    mutating func ingest(_ text: String) -> String {
        var output: [UInt8] = []
        output.reserveCapacity(text.utf8.count)
        for byte in text.utf8 {
            switch state {
            case .text:
                if byte == 0x1B { state = .escape }
                else { output.append(byte) }
            case .escape:
                switch byte {
                case 0x5B: state = .csi              // ESC [
                case 0x5D: state = .osc              // ESC ]
                case 0x50, 0x5E, 0x5F: state = .controlString // DCS, PM, APC
                default: state = .text
                }
            case .csi:
                if (0x40...0x7E).contains(byte) { state = .text }
            case .osc:
                if byte == 0x07 { state = .text }
                else if byte == 0x1B { state = .oscEscape }
            case .oscEscape:
                state = byte == 0x5C ? .text : .osc
            case .controlString:
                if byte == 0x1B { state = .controlStringEscape }
            case .controlStringEscape:
                state = byte == 0x5C ? .text : .controlString
            }
        }
        return String(decoding: output, as: UTF8.self)
    }
}

enum TerminalLinkTarget: Equatable, Sendable {
    case web(URL)
    case image(String)
    case file(String)
}

/// Purely lexical path inspection for terminal output. Foundation's
/// `URL(fileURLWithPath:)` may consult the filesystem to infer whether a path
/// is a directory. That is unacceptable on Relay's display queue: an HPC/NFS
/// path can block terminal rendering and keyboard echo for seconds. Existence
/// and file type are resolved only after the user opens a link.
enum TerminalPathSyntax {
    static func lastComponent(_ path: String) -> String {
        var end = path.endIndex
        while end > path.startIndex {
            let previous = path.index(before: end)
            guard path[previous] == "/" else { break }
            end = previous
        }
        guard end > path.startIndex else { return path }
        let trimmed = path[..<end]
        guard let slash = trimmed.lastIndex(of: "/") else { return String(trimmed) }
        let start = path.index(after: slash)
        return String(path[start..<end])
    }

    static func pathExtension(_ path: String) -> String {
        let component = lastComponent(path)
        guard let dot = component.lastIndex(of: "."),
              dot != component.startIndex else { return "" }
        let start = component.index(after: dot)
        guard start < component.endIndex else { return "" }
        return String(component[start...]).lowercased()
    }

    static func parentDirectory(_ path: String) -> String {
        var end = path.endIndex
        while end > path.startIndex {
            let previous = path.index(before: end)
            guard path[previous] == "/" else { break }
            end = previous
        }
        guard end > path.startIndex else { return "/" }
        let trimmed = path[..<end]
        guard let slash = trimmed.lastIndex(of: "/") else { return "." }
        return slash == path.startIndex ? "/" : String(path[..<slash])
    }

    static func resolving(_ relativePath: String, against directory: String) -> String {
        if relativePath.hasPrefix("/") { return standardized(relativePath) }
        return standardized(directory + "/" + relativePath)
    }

    static func standardized(_ path: String) -> String {
        let absolute = path.hasPrefix("/")
        var components: [Substring] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".": continue
            case "..":
                if components.last != "..", !components.isEmpty {
                    components.removeLast()
                } else if !absolute {
                    components.append(component)
                }
            default:
                components.append(component)
            }
        }
        let joined = components.joined(separator: "/")
        if absolute { return joined.isEmpty ? "/" : "/" + joined }
        return joined.isEmpty ? "." : joined
    }
}

enum TerminalLinkResolver {
    static let imageExtensions = Set(["png", "jpg", "jpeg", "gif", "webp", "svg"])
    private static let artifactPrefix = "file:///__relay_artifact__/"
    private static let legacyArtifactPrefix = "relay-artifact://open/"
    private static let filePrefix = "file:///__relay_remote_file__/"

    static func target(from link: String) -> TerminalLinkTarget? {
        if link.hasPrefix(artifactPrefix) || link.hasPrefix(legacyArtifactPrefix) {
            let prefix = link.hasPrefix(artifactPrefix) ? artifactPrefix : legacyArtifactPrefix
            guard let path = decodePath(String(link.dropFirst(prefix.count))) else { return nil }
            return .image(path)
        }
        if link.hasPrefix(filePrefix) {
            guard let path = decodePath(String(link.dropFirst(filePrefix.count))) else { return nil }
            return target(forRemotePath: path)
        }
        if let url = URL(string: link),
           let scheme = url.scheme?.lowercased(),
           ["http", "https", "mailto"].contains(scheme) {
            return .web(url)
        }

        let path: String
        if let url = URL(string: link), url.isFileURL {
            path = url.path
        } else {
            path = link.removingPercentEncoding ?? link
        }
        guard isRemotePath(path) else { return nil }
        return target(forRemotePath: path)
    }

    static func link(forRemotePath path: String) -> String {
        if isImagePath(path) { return artifactPrefix + Data(path.utf8).base64URLEncodedString() }
        return filePrefix + Data(path.utf8).base64URLEncodedString()
    }

    static func isImagePath(_ path: String) -> Bool {
        imageExtensions.contains(TerminalPathSyntax.pathExtension(path))
            || path.hasPrefix("/tmp/claude-")
    }

    private static func target(forRemotePath path: String) -> TerminalLinkTarget {
        isImagePath(path) ? .image(path) : .file(path)
    }

    private static func isRemotePath(_ path: String) -> Bool {
        let cleaned = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.hasPrefix("/") || cleaned.hasPrefix("./")
            || cleaned.hasPrefix("../") || cleaned.hasPrefix("~/")
            || cleaned.hasPrefix(".codex/")
    }

    private static func decodePath(_ encoded: String) -> String? {
        guard let data = Data(base64URLEncoded: encoded) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

enum ArtifactLinkResolver {

    static func path(from link: String) -> String? {
        guard case .image(let path) = TerminalLinkResolver.target(from: link) else { return nil }
        return path
    }

    static func link(for path: String) -> String {
        TerminalLinkResolver.link(forRemotePath: path)
    }
}

enum ArtifactHyperlinkEncoder {
    private static let osc8Prefix = Data("\u{001B}]8;".utf8)
    private static let kittyGraphicsPrefix = Data("\u{001B}_G".utf8)

    /// Adds zero-width OSC 8 links while preserving the visible terminal text.
    /// Chunks that already contain OSC 8 are left alone to avoid nested links.
    ///
    /// Terminal control strings are opaque. In particular, shell integration
    /// sends paths inside OSC 7 and prompt metadata inside OSC 133. Decorating
    /// those bytes would nest OSC 8 inside another OSC and leave the parser in
    /// an undefined state, which presented as blank or garbled restored SSH
    /// panes. Only ground-state printable runs are eligible for decoration.
    static func encode(_ data: Data) -> Data {
        // Almost all screen-paint packets contain no path. Reject those with
        // one allocation-free byte scan before attempting UTF-8 decoding or
        // the more expensive control-sequence searches.
        guard data.contains(0x2F),
              data.range(of: osc8Prefix) == nil,
              data.range(of: kittyGraphicsPrefix) == nil,
              String(data: data, encoding: .utf8) != nil
        else { return data }

        var encoded = Data()
        encoded.reserveCapacity(data.count + 96)
        var groundStart = data.startIndex
        var index = data.startIndex
        while index < data.endIndex {
            guard data[index] == 0x1B else {
                index = data.index(after: index)
                continue
            }
            appendDecoratedGround(data[groundStart..<index], to: &encoded)
            let controlEnd = terminalControlEnd(in: data, startingAt: index)
            encoded.append(contentsOf: data[index..<controlEnd])
            index = controlEnd
            groundStart = controlEnd
        }
        appendDecoratedGround(data[groundStart..<data.endIndex], to: &encoded)
        return encoded
    }

    private static func appendDecoratedGround(
        _ bytes: Data.SubSequence,
        to output: inout Data
    ) {
        guard !bytes.isEmpty,
              let text = String(data: Data(bytes), encoding: .utf8),
              text.contains("/") else {
            output.append(contentsOf: bytes)
            return
        }

        let links = TerminalLinkScanner.links(in: text)
        guard !links.isEmpty else {
            output.append(contentsOf: bytes)
            return
        }
        var decorated = ""
        decorated.reserveCapacity(text.utf8.count + links.count * 48)
        var cursor = text.startIndex
        for link in links {
            decorated.append(contentsOf: text[cursor..<link.range.lowerBound])
            decorated.append("\u{001B}]8;;\(link.destination)\u{001B}\\")
            decorated.append(contentsOf: text[link.range])
            decorated.append("\u{001B}]8;;\u{001B}\\")
            cursor = link.range.upperBound
        }
        decorated.append(contentsOf: text[cursor...])
        output.append(contentsOf: decorated.utf8)
    }

    private static func terminalControlEnd(
        in data: Data,
        startingAt escape: Data.Index
    ) -> Data.Index {
        var index = data.index(after: escape)
        guard index < data.endIndex else { return index }
        let introducer = data[index]
        index = data.index(after: index)

        switch introducer {
        case 0x5B: // CSI: ESC [ ... final byte in 0x40...0x7E
            while index < data.endIndex {
                let byte = data[index]
                index = data.index(after: index)
                if (0x40...0x7E).contains(byte) { break }
            }
            return index

        case 0x5D: // OSC: ESC ] ... BEL or ST
            return stringControlEnd(in: data, from: index, allowsBEL: true)

        case 0x50, 0x58, 0x5E, 0x5F: // DCS, SOS, PM, APC: terminated by ST
            return stringControlEnd(in: data, from: index, allowsBEL: false)

        default:
            // ISO 2022 escape sequences may contain intermediate bytes before
            // one final byte. Most terminal escapes are two bytes, so this is
            // both complete and cheap for the common case.
            if (0x20...0x2F).contains(introducer) {
                while index < data.endIndex {
                    let byte = data[index]
                    index = data.index(after: index)
                    if (0x30...0x7E).contains(byte) { break }
                }
            }
            return index
        }
    }

    private static func stringControlEnd(
        in data: Data,
        from start: Data.Index,
        allowsBEL: Bool
    ) -> Data.Index {
        var index = start
        while index < data.endIndex {
            let byte = data[index]
            index = data.index(after: index)
            if allowsBEL, byte == 0x07 { return index }
            if byte == 0x1B, index < data.endIndex, data[index] == 0x5C {
                return data.index(after: index)
            }
        }
        return index
    }
}

private struct TerminalDetectedLink {
    let range: Range<String.Index>
    let value: String
    let destination: String
}

/// A bounded token scanner for the compatibility path. Modern shells and
/// agents should emit OSC 8 or structured artifact events directly; this
/// scanner avoids allocating Foundation regex result objects for every TUI
/// repaint packet.
private enum TerminalLinkScanner {
    private static let fileExtensions: Set<String> = Set([
        "png", "jpg", "jpeg", "gif", "webp", "svg", "txt", "md", "markdown", "rst", "log",
        "csv", "tsv", "json", "jsonl", "yaml", "yml", "toml", "ini", "conf", "cfg",
        "swift", "go", "rs", "py", "pyw", "r", "rmd", "sh", "bash", "zsh", "fish",
        "js", "mjs", "cjs", "jsx", "ts", "mts", "cts", "tsx", "html", "htm", "css",
        "scss", "sql", "c", "h", "cc", "cpp", "cxx", "hpp", "java", "kt", "kts",
        "rb", "php", "pl", "lua", "ex", "exs", "erl", "hrl", "scala", "proto",
        "graphql", "tex", "bib", "diff", "patch", "lock",
    ])
    private static let tokenDelimiters = CharacterSet.whitespacesAndNewlines.union(
        CharacterSet(charactersIn: "[](){}<>\"'`")
    )
    private static let trailingPunctuation = CharacterSet(charactersIn: ".,;!?…")

    static func links(in text: String) -> [TerminalDetectedLink] {
        guard text.contains("/") else { return [] }
        var links: [TerminalDetectedLink] = []
        var tokenStart = text.startIndex
        var index = text.startIndex
        while index <= text.endIndex {
            let atEnd = index == text.endIndex
            let delimiter = !atEnd && text[index].unicodeScalars.allSatisfy(tokenDelimiters.contains)
            if atEnd || delimiter {
                if tokenStart < index, let link = link(in: text, tokenRange: tokenStart..<index) {
                    links.append(link)
                }
                if atEnd { break }
                tokenStart = text.index(after: index)
            }
            index = text.index(after: index)
        }
        return links
    }

    private static func link(in text: String, tokenRange: Range<String.Index>) -> TerminalDetectedLink? {
        let token = text[tokenRange]
        guard !token.contains("\u{001B}") else { return nil }
        let start: String.Index
        if let web = firstRange(of: ["https://", "http://", "file:///"], in: token) {
            start = web.lowerBound
        } else if token.hasPrefix(".codex/") || token.hasPrefix("./") || token.hasPrefix("../") {
            start = token.startIndex
        } else if let slash = token.firstIndex(of: "/") {
            start = slash
        } else {
            return nil
        }

        var end = token.endIndex
        while end > start {
            let previous = token.index(before: end)
            guard token[previous].unicodeScalars.allSatisfy(trailingPunctuation.contains) else { break }
            end = previous
        }
        end = droppingLineAndColumnSuffix(from: token, start: start, end: end)
        guard start < end else { return nil }

        let value = String(token[start..<end])
        let target = TerminalLinkResolver.target(from: value)
        let destination: String
        switch target {
        case .web(let url):
            destination = url.absoluteString
        case .image(let path):
            destination = TerminalLinkResolver.link(forRemotePath: path)
        case .file(let path):
            guard supportsFile(path) else { return nil }
            destination = TerminalLinkResolver.link(forRemotePath: path)
        case nil:
            return nil
        }
        return TerminalDetectedLink(range: start..<end, value: value, destination: destination)
    }

    private static func supportsFile(_ path: String) -> Bool {
        if path.hasPrefix("/tmp/claude-") { return true }
        return fileExtensions.contains(TerminalPathSyntax.pathExtension(path))
    }

    private static func firstRange(
        of needles: [String],
        in token: Substring
    ) -> Range<String.Index>? {
        needles.compactMap { token.range(of: $0, options: [.caseInsensitive]) }
            .min { $0.lowerBound < $1.lowerBound }
    }

    private static func droppingLineAndColumnSuffix(
        from token: Substring,
        start: String.Index,
        end: String.Index
    ) -> String.Index {
        var result = end
        for _ in 0..<2 {
            guard let colon = token[start..<result].lastIndex(of: ":") else { break }
            let digitsStart = token.index(after: colon)
            guard digitsStart < result,
                  token[digitsStart..<result].allSatisfy({ $0.isNumber }) else { break }
            result = colon
        }
        return result
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
