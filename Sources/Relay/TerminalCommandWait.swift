import Foundation

/// `relay_wait_for_command`: waits, read-only, for the shell in one pane to
/// report that a command returned to its prompt. The status comes from the
/// pane's own output (OSC 133;D from Relay's shell integration), which any
/// program in the pane can print: it is shell-reported, never verified, and
/// must not be used for authorization.
enum TerminalCommandWait {
    static let source = "shell_reported_osc133"
    static let defaultTimeoutMilliseconds = 30_000
    static let maximumTimeoutMilliseconds = 600_000
    /// One HTTP request waits at most this long; relay-mcp re-issues the wait
    /// with the same `after` until the caller's whole timeout has elapsed.
    static let maximumRequestMilliseconds = 50_000

    struct Request: Equatable, Sendable {
        var after: UInt64?
        var timeoutMilliseconds: Int

        /// Body: `{"after"?: uint, "timeout_ms"?: 1...50000}`. Nothing else.
        static func decode(_ data: Data) -> Request? {
            if data.isEmpty { return Request(after: nil, timeoutMilliseconds: defaultTimeoutMilliseconds) }
            guard let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(fields.keys).isSubset(of: ["after", "timeout_ms"]) else { return nil }
            var request = Request(after: nil, timeoutMilliseconds: defaultTimeoutMilliseconds)
            if let raw = fields["after"] {
                guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                      let value = UInt64(exactly: number.doubleValue) else { return nil }
                request.after = value
            }
            if let raw = fields["timeout_ms"] {
                guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                      let value = Int(exactly: number.doubleValue),
                      (1...maximumRequestMilliseconds).contains(value) else { return nil }
                request.timeoutMilliseconds = value
            }
            return request
        }
    }

    /// What the pane model knows about the pane itself, separate from the
    /// shell's command markers.
    enum PaneState: Equatable, Sendable {
        case live
        case exited(code: Int?)
        case disconnected
        case unsupported(String)
    }

    enum Outcome: Equatable, Sendable {
        case returned(exitStatus: Int?, generation: UInt64)
        case running(generation: UInt64)
        case paneExited(code: Int?)
        case unknown(reason: String, generation: UInt64?)
    }

    /// The handle a wait without `after` uses: the newest completion already
    /// seen, so the wait reports the next command to return.
    static func defaultAfter(_ observation: TerminalSemanticPromptStateTracker.CommandObservation) -> UInt64 {
        observation.completedExecutions
    }

    /// A final outcome, or nil to keep waiting. `deadline` true forces one.
    static func decide(_ observation: TerminalSemanticPromptStateTracker.CommandObservation,
                       after: UInt64, pane: PaneState, producerChanged: Bool,
                       deadline: Bool) -> Outcome? {
        if case .unsupported(let reason) = pane { return .unknown(reason: reason, generation: nil) }
        // A completion newer than the handle answers the command, even if the
        // pane ended afterwards.
        if !producerChanged, observation.completedExecutions > after {
            return .returned(exitStatus: observation.exitStatus, generation: observation.completedExecutions)
        }
        if case .exited(let code) = pane { return .paneExited(code: code) }
        if pane == .disconnected {
            return .unknown(reason: "pane is not connected", generation: observation.executions)
        }
        if producerChanged {
            return .unknown(reason: "terminal transport reconnected during the wait; read the viewport",
                            generation: observation.executions)
        }
        guard deadline else { return nil }
        if !observation.integrationSeen {
            return .unknown(reason: "no shell integration (OSC 133) observed in this pane", generation: nil)
        }
        if observation.executions > after, observation.executions > observation.completedExecutions {
            return .running(generation: observation.executions)
        }
        return .unknown(reason: "no command start observed after generation \(after); the pane may be idle or running a non-shell program",
                        generation: observation.executions)
    }

    static func json(_ outcome: Outcome, paneID: UUID, after: UInt64) -> [String: Any] {
        // next_after is the handle for waiting again: the returned command's
        // generation, or the same handle while that command has not returned.
        // A running result's generation is the command's own number and would
        // never match it.
        var result: [String: Any] = ["pane_id": paneID.uuidString.lowercased(), "after": after,
                                     "next_after": after, "source": source]
        switch outcome {
        case .returned(let status, let generation):
            result["state"] = "returned"
            result["next_after"] = generation
            result["exit_status"] = status.map { $0 as Any } ?? NSNull()
            result["generation"] = generation
        case .running(let generation):
            result["state"] = "running"
            result["generation"] = generation
        case .paneExited(let code):
            result["state"] = "pane_exited"
            result["exit_code"] = code.map { $0 as Any } ?? NSNull()
        case .unknown(let reason, let generation):
            result["state"] = "unknown"
            result["reason"] = reason
            if let generation { result["generation"] = generation }
        }
        return result
    }
}
