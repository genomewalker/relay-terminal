import Foundation

/// Commands and output share the same node channel as terminal panes.
/// Job identity survives reconnects; this client never resubmits an execution.
enum RelayHostExecution {
    struct Output: Sendable {
        let stdout: Data
        let stderr: Data
        let exitCode: Int
        let jobID: String
    }
    private struct Response: Decodable {
        let result: ResultPayload?
        let error: String?
    }
    private struct ResultPayload: Decodable {
        let state: String?
        let job: Job?
        let stdout: Data?
        let stderr: Data?
        let stdout_offset: Int?
        let stderr_offset: Int?
    }
    private struct Job: Decodable {
        let state: String
        let exit_code: Int?
        let error: String?
    }
    static func capture(profile: ConnectionProfile, command: String, input: Data = Data(),
                        timeout: Int = 12, maximumBytes: Int = 12 << 20,
                        directory: String? = nil) async throws -> Output {
        let id = "job-" + UUID().uuidString.lowercased()
        func request(_ operation: String, fields: [String: Any] = [:]) async throws -> ResultPayload {
            var object = fields
            object["request_id"] = "rpc-" + UUID().uuidString.lowercased()
            object["job_id"] = id
            object["operation"] = operation
            if let directory { object["cwd"] = directory }
            let payload = try JSONSerialization.data(withJSONObject: object)
            let response: Data
            do {
                response = try await RelayNodeTransportPool.shared.request(profile: profile, payload: payload)
            } catch {
                // Preserve the execution handle even when the transport cannot prove delivery.
                throw RemoteCatalogError.failed("Host \(operation) outcome unavailable; job \(id). Do not replay execution. \(error.localizedDescription)")
            }
            let decoded = try JSONDecoder().decode(Response.self, from: response)
            if let error = decoded.error { throw RemoteCatalogError.failed(error) }
            guard let result = decoded.result else { throw RemoteCatalogError.invalidResponse }
            return result
        }
        let started = try await request("exec", fields: ["command": command,
            "stdin": input.base64EncodedString(), "timeout_seconds": timeout])
        guard started.state == "running" || started.state == "exited" else {
            throw RemoteCatalogError.failed("Host execution failed; query job \(id)")
        }
        var output = Data(), errors = Data()
        var stdoutOffset = 0, stderrOffset = 0
        while true {
            if Task.isCancelled {
                _ = try? await request("cancel")
                throw CancellationError()
            }
            let result = try await request("status", fields: ["stdout_offset": stdoutOffset,
                "stderr_offset": stderrOffset, "wait_millis": 15000])
            output.append(result.stdout ?? Data()); errors.append(result.stderr ?? Data())
            stdoutOffset = result.stdout_offset ?? stdoutOffset
            stderrOffset = result.stderr_offset ?? stderrOffset
            guard output.count <= maximumBytes, errors.count <= maximumBytes else {
                _ = try? await request("cancel")
                throw RemoteCatalogError.failed("Host output exceeded client limit; job \(id)")
            }
            guard let job = result.job else { throw RemoteCatalogError.invalidResponse }
            if job.state == "unknown_after_daemon_restart" {
                throw RemoteCatalogError.failed("Execution outcome unknown after daemon restart; job \(id); do not replay")
            }
            if job.state == "exited" || job.state == "failed" {
                if !(result.stdout ?? Data()).isEmpty || !(result.stderr ?? Data()).isEmpty { continue }
                return Output(stdout: output, stderr: errors, exitCode: job.exit_code ?? 1, jobID: id)
            }
        }
    }
    /// Runs a relayd communication request through the installed helper, as
    /// an ordinary exactly-once host job. The node daemon's own `communication`
    /// RPC is not used: it resolves state roots from the daemon's environment,
    /// not the login shell the helper runs under.
    @MainActor static func communicationRequest(profile: ConnectionProfile, packet: [String: Any]) async throws -> (value: [String: Any]?, stderr: Data) {
        let verb = communicationVerb(packet)
        let fallback = daemonCommand(profile: profile, arguments: [verb])
        let command = RelayWorkCarrier.carries(packet) ? workCarrierCommand(profile: profile, verb: verb) : "if [ -x \"$HOME/.local/share/relay/bin/relayd-communication\" ]; then \"$HOME/.local/share/relay/bin/relayd-communication\" " + verb + "; else " + fallback + "; fi"
        let result = try await capture(profile: profile, command: command,
            input: JSONSerialization.data(withJSONObject: packet, options: .sortedKeys), timeout: 60, maximumBytes: captureLimit(packet))
        guard result.exitCode == 0 else { return (nil, result.stderr) }
        return (try JSONSerialization.jsonObject(with: result.stdout) as? [String: Any], result.stderr)
    }
    /// A Work claim carries a signed envelope with up to 128 KiB of file and
    /// note, base64-encoded; other replies stay under 128 KiB.
    static func captureLimit(_ packet: [String: Any]) -> Int {
        RelayWorkCarrier.carries(packet) ? 256 << 10 : 128 << 10
    }
    /// Work host-channel requests go to the relayd that owns the Work link on
    /// each host: the bundled relayd on this Mac, and the Work helper a remote
    /// host installs for it. A host without that helper refuses rather than
    /// reaching a relayd that does not know these operations.
    static func workCarrierCommand(profile: ConnectionProfile, verb: String) -> String {
        if profile.kind == .local { return daemonCommand(profile: profile, arguments: [verb]) }
        let helper = "\"$HOME/.local/share/relay/bin/relayd-work-communication\""
        return "if [ -x " + helper + " ]; then " + helper + " " + verb + "; else echo 'relayd: the Work host-channel helper is not installed on this host' >&2; exit 1; fi"
    }
    static func communicationVerb(_ packet: [String: Any]) -> String {
        // A legacy helper must refuse before I/O, rather than ignore the new
        // link-revision field and accidentally deliver an unpinned report.
        packet["shepherd_report"] as? Bool == true ? "communication-shepherd" : "communication"
    }

    static func daemonCommand(profile: ConnectionProfile, arguments: [String]) -> String {
        let binary = profile.kind == .local
            ? Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/relayd").path
            : "$HOME/.local/bin/relayd"
        let executable = profile.kind == .local ? quote(binary) : "\"\(binary)\""
        return ([executable] + arguments.map(quote)).joined(separator: " ")
    }
    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
