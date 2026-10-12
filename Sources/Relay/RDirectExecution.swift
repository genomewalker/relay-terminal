import Foundation
import CryptoKit

struct RExecutionSource: Codable, Equatable, Sendable {
    let kind: String
    var path: String? = nil
    var documentID: String? = nil
    var revision: String? = nil
    var range: [String: Int]? = nil
    var documentSHA256: String? = nil
    let codeSHA256: String

    static func digest(_ code: String) -> String {
        SHA256.hash(data: Data(code.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

struct RProjectExecutionSnapshot {
    let code: String
    let source: RExecutionSource
    static func capture(_ bytes: Data, path: String, expectedSHA256: String) throws -> Self {
        guard bytes.count <= RWorkspaceCommand.maximumCodeBytes,
              let code = String(data: bytes, encoding: .utf8), !code.isEmpty,
              expectedSHA256.count == 64, expectedSHA256 == RExecutionSource.digest(code) else {
            throw PluginError.invalid("Project file differs from the requested SHA-256 version")
        }
        return Self(code: code, source: RExecutionSource(kind: "disk_snapshot", path: path,
            documentSHA256: expectedSHA256, codeSHA256: expectedSHA256))
    }
}

/// Terminal evidence for one exact direct R execution. Markers are emitted by
/// base R, not a Relay companion; echoed source never contains their raw bytes.
struct RDirectExecution: Codable, Sendable {
    let id: UUID
    let sessionID: String
    let nonce: String
    let source: RExecutionSource?
    let codeSnapshot: String?
    let humanConsole: Bool?
    var status = "submitted"
    var output = Data()
    var pending = Data()
    var started = false

    init(id: UUID, sessionID: String, code: String? = nil, source: RExecutionSource? = nil, humanConsole: Bool = false) {
        self.id = id
        self.sessionID = sessionID
        self.nonce = UUID().uuidString.lowercased()
        self.codeSnapshot = code
        self.humanConsole = humanConsole
        self.source = source ?? code.map { RExecutionSource(kind: "provided_code", codeSHA256: RExecutionSource.digest($0)) }
    }

    func marker(_ status: String) -> Data {
        Data(("\u{001e}RelayR:" + nonce + ":" + status + "\u{001f}").utf8)
    }

    mutating func receive(_ bytes: Data) -> Bool {
        guard !["completed", "error", "interrupted"].contains(status) else { return false }
        pending.append(bytes)
        if !started {
            guard let range = pending.range(of: marker("started")) else {
                // On restart the bounded terminal snapshot may retain the end
                // marker after the start has scrolled away. Its fresh nonce is
                // still completion evidence; earlier output is unavailable.
                for terminal in ["completed", "error", "interrupted"] where pending.range(of: marker(terminal)) != nil {
                    pending.removeAll()
                    status = terminal
                    return true
                }
                pending = Data(pending.suffix(256)); return false
            }
            pending.removeSubrange(pending.startIndex..<range.upperBound)
            started = true
            status = "running"
        }
        for terminal in ["completed", "error", "interrupted"] {
            if let range = pending.range(of: marker(terminal)) {
                output.append(pending[..<range.lowerBound])
                output = Data(output.suffix(16_384))
                pending.removeAll()
                status = terminal
                return true
            }
        }
        if pending.count > 256 {
            output.append(pending.prefix(pending.count - 256))
            output = Data(output.suffix(16_384))
            pending = Data(pending.suffix(256))
        }
        return false
    }

    func command(code: String) throws -> String {
        guard codeSnapshot == nil || codeSnapshot == code else {
            throw PluginError.invalid("Execution source differs from its captured code")
        }
        let code = try RWorkspaceCommand.userInput(code)
        if humanConsole == true { return code }
        let scalars = Array(code.unicodeScalars)
        let chunks = try stride(from: 0, to: scalars.count, by: 256).map { start in
            try RWorkspaceCommand.quote(String(String.UnicodeScalarView(scalars[start..<min(start + 256, scalars.count)])))
        }.joined(separator: ",\n")
        let prefix = try RWorkspaceCommand.quote("\u{001e}RelayR:")
        let token = try RWorkspaceCommand.quote(nonce)
        let suffix = try RWorkspaceCommand.quote("\u{001f}\n")
        func signal(_ state: String) throws -> String {
            "base::cat(\(prefix), \(token), \(try RWorkspaceCommand.quote(":" + state)), \(suffix), sep=\"\")"
        }
        let command = """
        base::local({
        \(try signal("started"))
        base::tryCatch({
        .relay_value <- base::withVisible(base::eval(base::parse(text=base::paste0(
        \(chunks)
        )), envir=.GlobalEnv))
        if (.relay_value$visible) base::print(.relay_value$value)
        \(try signal("completed"))
        }, error=function(e) {
        base::message(base::conditionMessage(e))
        \(try signal("error"))
        }, interrupt=function(e) {
        \(try signal("interrupted"))
        })
        })
        """
        guard command.utf8.count <= 128 << 10 else { throw PluginError.invalid("Encoded R document exceeds the direct transport limit") }
        return command
    }

    var receipt: [String: Any] {
        var result: [String: Any] = ["version": 2, "request_id": id.uuidString.lowercased(), "session_id": sessionID,
         "status": status, "execution": "direct", "completion_evidence": "native_terminal_marker",
         "text": String(decoding: output, as: UTF8.self)]
        if let codeSnapshot { result["code"] = codeSnapshot }
        if humanConsole == true {
            result["execution"] = "human_console"
            result["completion_evidence"] = "none"
            result["completion"] = "unknown"
        }
        if let source, let data = try? JSONEncoder().encode(source),
           let object = try? JSONSerialization.jsonObject(with: data) { result["source"] = object }
        result["state_may_be_partially_changed"] = ["error", "interrupted", "unknown"].contains(status)
        return result
    }
}

/// Serializes fragmented terminal frames before hopping to the main actor.
final class RDirectExecutionMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var record: RDirectExecution
    init(_ record: RDirectExecution) { self.record = record }
    func receive(_ bytes: Data) -> RDirectExecution? {
        lock.lock()
        defer { lock.unlock() }
        let wasStarted = record.started
        let terminal = record.receive(bytes)
        return terminal || (!wasStarted && record.started) ? record : nil
    }
}
