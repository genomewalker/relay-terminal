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
        pattern: #"(?:file://)?(/[A-Za-z0-9_~.%+@:/-]+\.(?:png|jpe?g|gif|webp))"#,
        options: [.caseInsensitive]
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
        for match in Self.regex.matches(in: stripped, range: range) {
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
            try process.run()
            let data = try output.fileHandleForReading.readToEnd() ?? Data()
            process.waitUntilExit()
            let errorData = try errors.fileHandleForReading.readToEnd() ?? Data()
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
