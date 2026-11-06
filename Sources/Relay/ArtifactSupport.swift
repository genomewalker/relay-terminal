import AppKit
import CryptoKit
import Foundation
import ImageIO

enum RelayFilePreviewKind: String, Sendable, Equatable {
    case image, pdf, log
    static let imageExtensions: Set = ["png", "jpg", "jpeg", "gif", "tiff", "tif", "bmp", "webp", "heic", "svg"]
    static let logExtensions: Set = ["log", "txt", "out", "output", "err", "tsv", "csv", "md", "json", "yaml", "yml", "stdout", "stderr"]

    static func from(path: String) -> RelayFilePreviewKind? {
        let ext = TerminalPathSyntax.pathExtension(path)
        if ext == "pdf" { return .pdf }
        if imageExtensions.contains(ext) { return .image }
        return logExtensions.contains(ext) ? .log : nil
    }

    var symbol: String {
        switch self { case .image: "photo"; case .pdf: "doc.richtext"; case .log: "doc.plaintext" }
    }
}

/// The bounded tail of a text file. Only the final `maxBytes` are ever read.
struct RelayLogTail: Sendable, Equatable {
    static let defaultMaxBytes = 1 << 20
    let text: String
    let shownBytes: Int
    let totalBytes: Int
    var partial: Bool { shownBytes < totalBytes }
    var label: String? { partial ? "Showing last \(shownBytes) of \(totalBytes) bytes" : nil }

    init(bytes: Data, totalBytes: Int) {
        // A tail that starts mid-character would otherwise begin with U+FFFD.
        var start = bytes.startIndex
        if bytes.count < totalBytes {
            while start < bytes.endIndex, start - bytes.startIndex < 3, bytes[start] & 0xC0 == 0x80 { start += 1 }
        }
        text = String(decoding: bytes[start...], as: UTF8.self)
        shownBytes = bytes.count
        self.totalBytes = totalBytes
    }

    static func readLocal(path: String, maxBytes: Int = defaultMaxBytes) throws -> RelayLogTail {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw ArtifactLoadError.failed(String(cString: strerror(errno)) + ": " + path) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw ArtifactLoadError.failed("Refusing to preview a non-regular or symlinked file")
        }
        let size = Int(info.st_size)
        try handle.seek(toOffset: UInt64(max(0, size - maxBytes)))
        let bytes = try handle.read(upToCount: min(size, maxBytes)) ?? Data()
        return RelayLogTail(bytes: bytes, totalBytes: max(size, bytes.count))
    }
}

struct PaneArtifact: Identifiable, Sendable {
    let id = UUID()
    let remotePath: String
    let data: Data
    let contentIdentity: String
    let kind: RelayFilePreviewKind
    var log: RelayLogTail?
    var failure: String?
    /// Opened explicitly by the user: always shown floating, never recorded as dismissed.
    var userRequested = false

    init(remotePath: String, data: Data) {
        self.remotePath = remotePath
        if !data.starts(with: Data("%PDF-".utf8)), RelayFilePreviewKind.from(path: remotePath) == .log {
            self.data = Data()
            kind = .log
            log = RelayLogTail(bytes: Data(data.suffix(RelayLogTail.defaultMaxBytes)), totalBytes: data.count)
        } else {
            self.data = data
            kind = data.starts(with: Data("%PDF-".utf8)) ? .pdf : .image
        }
        contentIdentity = Self.identity(remotePath, data)
    }

    init(remotePath: String, log: RelayLogTail) {
        self.remotePath = remotePath
        data = Data()
        kind = .log
        self.log = log
        userRequested = true
        contentIdentity = Self.identity(remotePath, Data(log.text.utf8))
    }

    init(remotePath: String, kind: RelayFilePreviewKind, failure: String) {
        self.remotePath = remotePath
        data = Data()
        self.kind = kind
        self.failure = failure
        userRequested = true
        contentIdentity = Self.identity(remotePath, Data(failure.utf8))
    }

    private static func identity(_ path: String, _ data: Data) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(path.utf8))
        hasher.update(data: Data([0]))
        hasher.update(data: data)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    var text: String? { log?.text }
    var totalBytes: Int { log?.totalBytes ?? data.count }
    var partial: Bool { log?.partial ?? false }
    var filename: String { TerminalPathSyntax.lastComponent(remotePath) }
    var isPDF: Bool { data.starts(with: Data("%PDF-".utf8)) }
    var imagePixelSize: CGSize? {
        guard kind == .image, let image else { return nil }
        let reps = image.representations.filter { $0.pixelsWide > 0 && $0.pixelsHigh > 0 }
        if let rep = reps.max(by: { $0.pixelsWide < $1.pixelsWide }) { return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh) }
        return image.size.width > 0 ? image.size : nil
    }

    /// Zoom, relative to the fitted image, at which one image pixel occupies one backing pixel.
    static func actualSizeZoom(pixelSize: CGSize, viewport: CGSize, displayScale: CGFloat) -> CGFloat {
        guard pixelSize.width > 0, pixelSize.height > 0, viewport.width > 0, viewport.height > 0, displayScale > 0 else { return 1 }
        let fitScale = min(viewport.width / pixelSize.width, viewport.height / pixelSize.height)
        return 1 / (fitScale * displayScale)
    }
    var image: NSImage? {
        if TerminalPathSyntax.pathExtension(remotePath) == "svg" {
            let source = String(decoding: data, as: UTF8.self).lowercased()
            guard data.count <= 2 << 20, !source.contains("<!entity"), !source.contains("<!doctype"),
                  !source.contains("<script"), !source.contains("<foreignobject"),
                  !source.contains("href="), !source.contains("url("),
                  !source.contains(" onload=") else { return nil }
        }
        return NSImage(data: data)
    }
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
    static let imageExtensions = Set(["png", "jpg", "jpeg", "gif", "webp", "svg", "pdf"])
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
            // An explicit file URL is a filename, even when its basename
            // happens to resemble a provider slash-command description.
            return target(forRemotePath: url.path)
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
        // Provider welcome/help rows are commands followed by descriptions.
        // Treating an entire "/review - review changes" row as a filename
        // opens a broken editor when the user merely focuses the terminal.
        // Explicit file URLs and encoded file links remain unambiguous above.
        if cleaned.range(
            of: #"^/[A-Za-z][A-Za-z0-9_-]*\s+[-–—]\s+\S"#,
            options: .regularExpression
        ) != nil { return false }
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
        "png", "jpg", "jpeg", "gif", "webp", "svg", "pdf", "txt", "md", "markdown", "rst", "log",
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
        // ASCII tokens without a slash cannot match any supported path or URL.
        // Avoid three Foundation case-folding searches for every ordinary word
        // in a TUI repaint. Non-ASCII tokens keep the existing matching rules.
        guard token.utf8.contains(0x2F) || token.utf8.contains(where: { $0 >= 0x80 }) else { return nil }
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
    // Each discovered path spawns a delayed SSH fetch buffering up to 25 MiB.
    // A chatty or malicious remote printing thousands of distinct image-like
    // paths would otherwise open thousands of concurrent connections. Bound
    // the number of in-flight (non-presented) loads; a handful of real images
    // is well under this, and a flood is throttled instead of exhausting the
    // machine.
    private static let maximumOutstandingLoads = 8

    func discover(in text: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        var outstanding = states.values.reduce(0) { $0 + ($1 == .presented ? 0 : 1) }
        return detector.ingest(text).filter { path in
            guard states[path] == nil else { return false }
            guard outstanding < Self.maximumOutstandingLoads else { return false }
            states[path] = .scheduled
            outstanding += 1
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
            if profile.kind == .local { return try loadLocal(path: path) }

            return try await RelayHostFiles.image(
                context: RelayExecutionContext(profile: profile, directory: "/"), path: path,
                preserveFormat: ["pdf", "svg"].contains(TerminalPathSyntax.pathExtension(path)))

        }.value
    }

    static func loadLocal(path: String) throws -> Data {
        let url = URL(fileURLWithPath: path)
        // Auto-loading is triggered purely by text printed to the
        // terminal, so refuse a symlink: a program could print a path
        // that points at an unrelated user-readable file.
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
        guard values.isSymbolicLink != true, values.isRegularFile == true else {
            throw ArtifactLoadError.failed("Refusing to open a non-regular or symlinked file")
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= 25 << 20 else { throw ArtifactLoadError.tooLarge }
        return data
    }
}

/// Loads exactly the requested file for an in-place pane preview. Failures become an
/// error card for that same path; another file is never substituted.
enum RelayFilePreviewLoader {
    static func load(path: String, profile: ConnectionProfile, kind: RelayFilePreviewKind? = nil) async -> PaneArtifact {
        let kind = kind ?? RelayFilePreviewKind.from(path: path) ?? .image
        return await artifact(path: path, kind: kind) {
            if kind == .log {
                return .log(profile.kind == .local
                    ? try await Task.detached(priority: .utility) { try RelayLogTail.readLocal(path: path) }.value
                    : try await RelayHostFiles.text(path: path, profile: profile))
            }
            return .data(try await RemoteArtifactLoader.load(path: path, profile: profile))
        }
    }

    /// Previews the immutable, digest-verified attachment snapshot, never its mutable source.
    static func load(snapshot: RelayAgentAttachmentSnapshot.Record, name: String, kind: RelayFilePreviewKind) async -> PaneArtifact {
        await artifact(path: name, kind: kind) {
            try await Task.detached(priority: .utility) {
                if kind == .log {
                    let tail = try snapshot.withVerifiedFile { fd in
                        let size = Int(snapshot.bytes), maxBytes = RelayLogTail.defaultMaxBytes
                        guard lseek(fd, off_t(max(0, size - maxBytes)), SEEK_SET) >= 0 else {
                            throw RelayAgentAttachmentSnapshot.Failure.changed
                        }
                        let bytes = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: min(size, maxBytes)) ?? Data()
                        return RelayLogTail(bytes: bytes, totalBytes: size)
                    }
                    return .log(tail)
                }
                guard snapshot.bytes <= 25 << 20 else { throw ArtifactLoadError.tooLarge }
                return .data(try snapshot.verifiedData())
            }.value
        }
    }

    enum Content: Sendable { case data(Data), log(RelayLogTail) }

    private static func artifact(path: String, kind: RelayFilePreviewKind,
                                 _ read: @Sendable () async throws -> Content) async -> PaneArtifact {
        do {
            var artifact: PaneArtifact
            switch try await read() {
            case .log(let tail): artifact = PaneArtifact(remotePath: path, log: tail)
            case .data(let data):
                artifact = PaneArtifact(remotePath: path, data: data)
                if kind == .pdf, !artifact.isPDF { throw ArtifactLoadError.failed("File is not a PDF document") }
                if kind == .image, !artifact.isPDF, artifact.image == nil { throw ArtifactLoadError.failed("File is not a supported image") }
            }
            artifact.userRequested = true
            return artifact
        } catch {
            return PaneArtifact(remotePath: path, kind: kind, failure: error.localizedDescription)
        }
    }
}

extension PaneModel {
    /// Shows a file the user explicitly asked to preview in this pane's in-place overlay.
    func openFilePreview(path: String, profile: ConnectionProfile? = nil, kind: RelayFilePreviewKind? = nil) {
        let profile = profile ?? self.profile
        openPreview { await RelayFilePreviewLoader.load(path: path, profile: profile, kind: kind) }
    }

    func openAttachmentPreview(snapshot: RelayAgentAttachmentSnapshot.Record, name: String, kind: RelayFilePreviewKind) {
        openPreview { await RelayFilePreviewLoader.load(snapshot: snapshot, name: name, kind: kind) }
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
