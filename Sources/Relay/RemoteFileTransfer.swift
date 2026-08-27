import Foundation

enum RemoteFileTransferError: LocalizedError {
    case notAFile(String)
    case tooLarge(String)
    case failed(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .notAFile(let name): "\(name) is not a regular file"
        case .tooLarge(let name): "\(name) exceeds the 64 MiB transfer limit"
        case .failed(let message): message
        case .invalidResponse: "The remote file transfer returned an invalid response"
        }
    }
}

enum RemoteFileTransfer {
    static let maximumBytes: Int64 = 64 << 20

    static func upload(
        _ urls: [URL],
        to directory: String,
        profile: ConnectionProfile
    ) async throws -> [RemoteFileEntry] {
        try await Task.detached(priority: .userInitiated) {
            var imported: [RemoteFileEntry] = []
            imported.reserveCapacity(urls.count)
            for url in urls {
                imported.append(try upload(url, to: directory, profile: profile))
            }
            return imported
        }.value
    }

    private static func upload(
        _ url: URL,
        to directory: String,
        profile: ConnectionProfile
    ) throws -> RemoteFileEntry {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .nameKey])
        let name = values.name ?? url.lastPathComponent
        guard values.isRegularFile == true else { throw RemoteFileTransferError.notAFile(name) }
        guard Int64(values.fileSize ?? 0) <= maximumBytes else {
            throw RemoteFileTransferError.tooLarge(name)
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard Int64(data.count) <= maximumBytes else { throw RemoteFileTransferError.tooLarge(name) }

        let ssh = Process()
        ssh.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        var arguments = [
            "-T", "-o", "ControlMaster=no", "-o", "ControlPath=~/.ssh/relay-%C",
        ]
        arguments += profile.sshConnectionArguments
        arguments += [
            "~/.local/bin/relayd", "files", "import",
            "--path-b64", Data(directory.utf8).base64EncodedString(),
            "--name-b64", Data(name.utf8).base64EncodedString(),
        ]
        ssh.arguments = arguments
        let output = Pipe()
        let errors = Pipe()
        ssh.standardOutput = output
        ssh.standardError = errors
        ssh.standardInput = Pipe()
        let captured = try ProcessCapture.run(
            ssh, output: output, errors: errors, input: data, timeout: 120
        )
        guard ssh.terminationStatus == 0 else {
            let message = String(data: captured.standardError, encoding: .utf8)?
                .split(separator: "\n").last.map(String.init)
                ?? "Remote file transfer failed"
            throw RemoteFileTransferError.failed(message)
        }
        guard let entry = try? JSONDecoder().decode(RemoteFileEntry.self, from: captured.standardOutput) else {
            throw RemoteFileTransferError.invalidResponse
        }
        return entry
    }
}
