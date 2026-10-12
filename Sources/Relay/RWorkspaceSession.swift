import Foundation

/// Invalidates asynchronous result reads when the owning session/view changes.
struct RResultReadGate {
    private(set) var generation = UUID()
    mutating func invalidate() { generation = UUID() }
    func accepts(_ captured: UUID) -> Bool { captured == generation }
}

struct RWorkspaceSession: Decodable, Sendable {
    let version: Int
    let session_id: String
    let pid: Int
    let host: String
    let working_directory: String
    let artifact_root: String
    let capabilities: [String]
    /// Reported by newer companions; installed is not the same as started.
    var httpgd_installed: Bool? = nil
    var rscript: String? = nil
    var library_paths: [String]? = nil
    var companion_version: Int? = nil

    var supportsHttpgd: Bool { capabilities.contains("httpgd") }

    func validate(root: String) throws {
        guard version == 1, pid > 0, !session_id.isEmpty, session_id.utf8.count <= 256,
              !host.isEmpty, host.utf8.count <= 256, artifact_root == root,
              capabilities.contains("evaluate"), capabilities.count <= 20 else {
            throw PluginError.invalid("Invalid or incompatible R session snapshot")
        }
    }
}

enum RWorkspaceCommand {
    static let maximumCodeBytes = 65_536
    static func userInput(_ code: String) throws -> String {
        let value = code.replacingOccurrences(of: "\r\n", with: "\n")
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.utf8.count <= maximumCodeBytes,
              !value.unicodeScalars.contains(where: { ($0.value < 32 && $0 != "\n" && $0 != "\t") || $0.value == 127 }) else {
            throw PluginError.invalid("Select up to 64 KiB of R code without terminal control characters")
        }
        return value
    }
    static func setupFile(path: String, md5: String, root: String) throws -> String {
        guard path.hasPrefix("/"), root.hasPrefix("/"),
              !path.contains("\0"), !root.contains("\0"),
              md5.range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil else {
            throw PluginError.invalid("Invalid companion file")
        }
        let p = try quote(path), r = try quote(root)
        let command = "local({p <- \(p); if (!identical(unname(tools::md5sum(p)), \(try quote(md5)))) stop(\"Relay companion changed\"); if (!requireNamespace(\"jsonlite\", quietly=TRUE)) stop(\"Relay requires jsonlite\"); sys.source(p, envir=.GlobalEnv); relay_r_connect(\(r)); if (is.null(relay_r_httpgd_device()) && is.null(get0(\".relay_r_console\", envir=.GlobalEnv))) {if (requireNamespace(\"httpgd\", quietly=TRUE)) relay_r_httpgd_start(\(r)) else relay_r_console_start(\(r))}})"
        guard command.utf8.count <= 2048 else { throw PluginError.invalid("R workspace path is too long for console setup") }
        return command
    }
    static func quote(_ text: String) throws -> String {
        let encoded = try JSONSerialization.data(withJSONObject: [text], options: [.fragmentsAllowed, .withoutEscapingSlashes])
        let value = String(decoding: encoded, as: UTF8.self)
        return String(value.dropFirst().dropLast())
    }

    static func setup(source: String, root: String) throws -> String {
        guard source.utf8.count <= 32 * 1024, root.hasPrefix("/"), !root.contains("\0") else { throw PluginError.invalid("Invalid R setup") }
        // Readline-backed R consoles impose a per-line limit. Keep physical
        // lines short even after escaping; the outer expression remains a
        // single reviewed operation, so partial delivery cannot execute it.
        let scalars = Array(source.unicodeScalars)
        let chunks = try stride(from: 0, to: scalars.count, by: 256).map { start in
            try quote(String(String.UnicodeScalarView(scalars[start..<min(start + 256, scalars.count)])))
        }
        let encoded = chunks.isEmpty ? "\"\"" : chunks.joined(separator: ",\n")
        return "local({\nif (!requireNamespace(\"jsonlite\", quietly=TRUE)) stop(\"Relay requires jsonlite; nothing installed\")\neval(parse(text=paste0(\n\(encoded)\n)), envir=.GlobalEnv)\nrelay_r_connect(\(try quote(root)))\nif (requireNamespace(\"httpgd\", quietly=TRUE)) relay_r_httpgd_start(\(try quote(root))) else relay_r_console_start(\(try quote(root)))\n})"
    }

    /// Explicit, reviewed device start in the connected session. Installs nothing.
    static func httpgdStart(session: RWorkspaceSession, root: String) throws -> String {
        try session.validate(root: root)
        guard session.supportsHttpgd else { throw PluginError.invalid("This R companion predates httpgd support; reconnect with the current companion") }
        return "relay_r_httpgd_start(\(try quote(session.artifact_root)))"
    }

    static func httpgdStop() -> String { "relay_r_httpgd_stop()" }

    static func evaluate(code: String, id: UUID, root: String, session: RWorkspaceSession) throws -> String {
        try session.validate(root: root)
        let value = try userInput(code)
        let encoded = Data(value.utf8).base64EncodedString()
        let chunks = stride(from: 0, to: encoded.count, by: 256).map { offset in
            let start = encoded.index(encoded.startIndex, offsetBy: offset)
            let end = encoded.index(start, offsetBy: min(256, encoded.count - offset))
            return "\"" + encoded[start..<end] + "\""
        }.joined(separator: ",\n")
        return "local({\n.relay_code <- rawToChar(jsonlite::base64_dec(paste0(\n\(chunks)\n)))\nrelay_r_evaluate(code=.relay_code, request_id=\(try quote(id.uuidString.lowercased())), artifact_root=\(try quote(root)), expected_session=\(try quote(session.session_id)))\n})"
    }
}
