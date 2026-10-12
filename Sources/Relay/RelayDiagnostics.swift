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

    // Resolving the current user's home can query directory services. Repeating
    // that lookup for every diagnostic field stalled the connection queue in
    // sampled reconnects. The home is stable for this process lifetime.
    private static let redactionHome = FileManager.default.homeDirectoryForCurrentUser.path

    private let lock = NSLock()
    private var events: [RelayDiagnosticEvent] = []
    private var healthByConnection: [String: RelayConnectionHealth] = [:]
    private var inputSampler = RelayInputDiagnosticSampler()
    private var inputPersistencePending = 0
    private let capacity = 2_000
    private let persistenceQueue = DispatchQueue(label: "dev.relay.diagnostics.persistence", qos: .utility)
    private var persistenceScheduled = false
    private let liveExportURL: URL? = {
        guard RelayStateProfile.isIsolated,
              ProcessInfo.processInfo.environment["RELAY_DIAGNOSTICS_LIVE_EXPORT"] == "1" else { return nil }
        return RelayStateProfile.applicationSupportRoot
            .appendingPathComponent("Relay/diagnostics-live.json")
    }()

    private let inputLogURL: URL

    init(inputLogURL: URL? = nil) {
        self.inputLogURL = inputLogURL ?? RelayStateProfile.applicationSupportRoot
            .appendingPathComponent("Relay/input-diagnostics.jsonl")
    }

    private static func inputDetails(_ details: [String: String]) -> [String: String] {
        let allowed: Set<String> = ["pane_id", "kind", "remote", "reason", "phase", "queued_actions",
            "first_responder", "surface_visible", "focus_claimed", "window_key", "eligible",
            "presented", "app_active", "sheet_active", "success", "inspection_active", "paste_active",
            "bytes", "characters"]
        return details.filter {
                guard allowed.contains($0.key) else { return false }
                if $0.key == "bytes" || $0.key == "characters" {
                    guard let count = Int($0.value), count >= 0, count <= 1_000_000_000 else { return false }
                }
                return true
        }
    }

    private func persistInputEvent(_ event: RelayDiagnosticEvent) {
        guard event.category == "terminal-input" else { return }
        lock.lock()
        guard inputPersistencePending < 128 else { lock.unlock(); return }
        inputPersistencePending += 1
        lock.unlock()
        persistenceQueue.async { [self] in
            defer {
                lock.lock()
                inputPersistencePending -= 1
                lock.unlock()
            }
            do {
                let fm = FileManager.default
                try fm.createDirectory(at: inputLogURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let size = (try? fm.attributesOfItem(atPath: inputLogURL.path)[.size] as? NSNumber)?.intValue ?? 0
                if size >= 1_048_576 {
                    for index in stride(from: 3, through: 1, by: -1) {
                        let destination = inputLogURL.appendingPathExtension(String(index))
                        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
                        let source = index == 1 ? inputLogURL : inputLogURL.appendingPathExtension(String(index - 1))
                        if fm.fileExists(atPath: source.path) { try fm.moveItem(at: source, to: destination) }
                    }
                }
                if !fm.fileExists(atPath: inputLogURL.path) {
                    fm.createFile(atPath: inputLogURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
                }
                let file = try FileHandle(forWritingTo: inputLogURL)
                defer { try? file.close() }
                try file.seekToEnd()
                var data = try JSONEncoder.relayDiagnostics.encode(event)
                data.append(10)
                try file.write(contentsOf: data)
            } catch { NSLog("Relay input diagnostic persistence failed: %@", String(describing: error)) }
        }
    }

    func flushInputLog() { persistenceQueue.sync {} }

    private func scheduleLiveExport() {
        guard let url = liveExportURL else { return }
        lock.lock()
        guard !persistenceScheduled else { lock.unlock(); return }
        persistenceScheduled = true
        lock.unlock()
        persistenceQueue.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.persistenceScheduled = false
            self.lock.unlock()
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                try self.export(to: url)
            } catch {
                // Recording an export error here would schedule an endless retry.
                NSLog("Relay isolated diagnostic export failed: %@", String(describing: error))
            }
        }
    }

    func record(category: String, name: String, details: [String: String] = [:]) {
        if category == "terminal-input" {
            lock.lock()
            let admitted = inputSampler.admit(paneID: details["pane_id"] ?? "unknown",
                name: name, now: ProcessInfo.processInfo.systemUptime)
            lock.unlock()
            guard admitted else { return }
        }
        let filteredDetails = category == "terminal-input" ? Self.inputDetails(details) : details
        let safeDetails = filteredDetails.reduce(into: [String: String]()) { result, pair in
            result[pair.key] = Self.redact(pair.value, key: pair.key)
        }
        lock.lock()
        let event = RelayDiagnosticEvent(timestamp: Date(), category: category, name: name, details: safeDetails)
        events.append(event)
        if events.count > capacity { events.removeFirst(events.count - capacity) }
        lock.unlock()
        persistInputEvent(event)
        scheduleLiveExport()
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
        scheduleLiveExport()
    }

    func heartbeatTimedOut(connection: String) {
        lock.lock()
        healthByConnection[connection, default: RelayConnectionHealth()].heartbeatTimeouts += 1
        lock.unlock()
        scheduleLiveExport()
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
        SecureFiles.restrictToOwner(url)
    }

    @MainActor
    func presentExportPanel() {
        let panel = RelayTheme.savePanel()
        panel.nameFieldStringValue = "relay-diagnostics-\(Self.fileTimestamp()).json"
        panel.allowedContentTypes = [.json]
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do { try self?.export(to: url) }
            catch { RelayTheme.alert(error: error).runModal() }
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
        let home = redactionHome
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
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["RELAY_TESTING"] == "1" ||
            Bundle.main.bundleURL.pathExtension == "xctest" ||
            ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil ||
            ProcessInfo.processInfo.processName.contains("RelayPackageTests") ||
            ProcessInfo.processInfo.processName.hasPrefix("swiftpm-testing")
    }

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
        let base = RelayStateProfile.applicationSupportRoot
            .appendingPathComponent("Relay/Diagnostics", isDirectory: true)
        SecureFiles.createPrivateDirectory(at: base)
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
            SecureFiles.restrictToOwner(markerURL)
        }
    }

    func cleanShutdown() { RelayDiagnostics.shared.flushInputLog(); try? FileManager.default.removeItem(at: markerURL) }
}

private extension JSONEncoder {
    static var relayDiagnostics: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
