import AppKit
import Foundation

struct RelayDiagnosticEvent: Codable, Equatable, Sendable {
    let timestamp: Date
    let category: String
    let name: String
    let details: [String: String]
}

struct RelayConnectionHealth: Codable, Equatable, Sendable {
    var heartbeatsSent = 0
    var heartbeatsAcknowledged = 0
    var heartbeatTimeouts = 0
    var latestRTTMilliseconds: Double?
    var smoothedRTTMilliseconds: Double?

    var heartbeatLossRate: Double {
        guard heartbeatsSent > 0 else { return 0 }
        return Double(heartbeatTimeouts) / Double(heartbeatsSent)
    }
}

/// A bounded, low-frequency operational timeline. Terminal bytes never enter
/// this store: diagnostics contain lifecycle metadata only.
final class RelayDiagnostics: @unchecked Sendable {
    static let shared = RelayDiagnostics()

    private let lock = NSLock()
    private var events: [RelayDiagnosticEvent] = []
    private var healthByConnection: [String: RelayConnectionHealth] = [:]
    private let capacity = 2_000

    func record(category: String, name: String, details: [String: String] = [:]) {
        let safeDetails = details.reduce(into: [String: String]()) { result, pair in
            result[pair.key] = Self.redact(pair.value, key: pair.key)
        }
        lock.lock()
        events.append(RelayDiagnosticEvent(
            timestamp: Date(), category: category, name: name, details: safeDetails
        ))
        if events.count > capacity { events.removeFirst(events.count - capacity) }
        lock.unlock()
    }

    func heartbeatSent(connection: String) {
        lock.lock()
        healthByConnection[connection, default: RelayConnectionHealth()].heartbeatsSent += 1
        lock.unlock()
    }

    func heartbeatAcknowledged(connection: String, rttMilliseconds: Double) {
        lock.lock()
        var health = healthByConnection[connection, default: RelayConnectionHealth()]
        health.heartbeatsAcknowledged += 1
        health.latestRTTMilliseconds = rttMilliseconds
        health.smoothedRTTMilliseconds = health.smoothedRTTMilliseconds.map {
            ($0 * 0.8) + (rttMilliseconds * 0.2)
        } ?? rttMilliseconds
        healthByConnection[connection] = health
        lock.unlock()
    }

    func heartbeatTimedOut(connection: String) {
        lock.lock()
        healthByConnection[connection, default: RelayConnectionHealth()].heartbeatTimeouts += 1
        lock.unlock()
    }

    func snapshot() -> (events: [RelayDiagnosticEvent], health: [String: RelayConnectionHealth]) {
        lock.lock()
        defer { lock.unlock() }
        return (events, healthByConnection)
    }

    func export(to url: URL) throws {
        let snapshot = snapshot()
        let bundle: [String: Any] = [
            "schema_version": 1,
            "created_at": ISO8601DateFormatter().string(from: Date()),
            "relay_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development",
            "macos_version": ProcessInfo.processInfo.operatingSystemVersionString,
            "safe_mode": RelayLaunchMode.isSafeMode,
            "events": try Self.jsonValue(snapshot.events),
            "connections": try Self.jsonValue(snapshot.health),
        ]
        let data = try JSONSerialization.data(withJSONObject: bundle, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    @MainActor
    func presentExportPanel() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "relay-diagnostics-\(Self.fileTimestamp()).json"
        panel.allowedContentTypes = [.json]
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do { try self?.export(to: url) }
            catch { NSAlert(error: error).runModal() }
        }
    }

    static func redact(_ value: String, key: String = "") -> String {
        let sensitiveKey = key.range(
            of: #"(?i)(password|passwd|token|secret|authorization|cookie|private.?key|credential)"#,
            options: .regularExpression
        ) != nil
        if sensitiveKey { return "<redacted>" }

        var result = value
        let replacements: [(String, String)] = [
            (#"(?i)\b(Bearer|Basic)\s+[A-Za-z0-9._~+/=-]+"#, "$1 <redacted>"),
            (#"\b(gh[opsu]_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9_-]{20,}|AKIA[A-Z0-9]{16})\b"#, "<redacted>"),
            (#"(?i)(https?://)[^/@\s:]+:[^/@\s]+@"#, "$1<redacted>@"),
            (#"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"#, "<redacted-private-key>"),
        ]
        for (pattern, replacement) in replacements {
            result = result.replacingOccurrences(
                of: pattern, with: replacement, options: .regularExpression
            )
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if !home.isEmpty { result = result.replacingOccurrences(of: home, with: "~") }
        return String(result.prefix(8_192))
    }

    private static func jsonValue<T: Encodable>(_ value: T) throws -> Any {
        let data = try JSONEncoder.relayDiagnostics.encode(value)
        return try JSONSerialization.jsonObject(with: data)
    }

    private static func fileTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}

enum RelayLaunchMode {
    static var isSafeMode: Bool {
        ProcessInfo.processInfo.arguments.contains("--safe-mode") ||
            ProcessInfo.processInfo.environment["RELAY_SAFE_MODE"] == "1"
    }
}

/// A marker is deliberately simpler and more reliable than attempting file IO
/// from a fatal signal handler. If it survives, the next launch reports an
/// unclean termination and includes the prior PID/start time.
final class RelayCrashRecovery: @unchecked Sendable {
    static let shared = RelayCrashRecovery()
    private let markerURL: URL

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Relay/Diagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: base.path)
        markerURL = base.appendingPathComponent("running.json")
    }

    func beginLaunch() {
        if let prior = try? String(contentsOf: markerURL, encoding: .utf8) {
            RelayDiagnostics.shared.record(
                category: "crash-recovery", name: "unclean-previous-termination",
                details: ["previous_run": prior]
            )
        }
        let marker: [String: Any] = [
            "pid": ProcessInfo.processInfo.processIdentifier,
            "started_at": ISO8601DateFormatter().string(from: Date()),
        ]
        if let data = try? JSONSerialization.data(withJSONObject: marker, options: [.sortedKeys]) {
            try? data.write(to: markerURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: markerURL.path)
        }
    }

    func cleanShutdown() { try? FileManager.default.removeItem(at: markerURL) }
}

private extension JSONEncoder {
    static var relayDiagnostics: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
