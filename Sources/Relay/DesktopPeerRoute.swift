import Foundation

/// Installed desktop routes are controlled by their verified launch service,
/// never by a PID supplied in a connection-status file.
struct DesktopPeerRoute: Identifiable, Sendable {
    struct MessageReceipt: Codable, Sendable {
        let id: String
        let status: String
        let updatedAt: Double
    }
    struct ConnectionRecord: Codable, Sendable {
        let replyName: String
        let host: String
        let remoteSession: String
        let tasks: [String]
        let currentTask: String
        let updatedAt: String
    }
    struct TaskInfo: Codable, Identifiable, Sendable {
        let id: String
        let name: String?
        let status: String
        var displayName: String { name ?? "ChatGPT task \(id.prefix(8))" }
        var activityLabel: String {
            switch status {
            case "active": "Working now"
            case "idle": "Open · idle"
            default: "Activity unknown"
            }
        }
    }
    let id: String
    let host: String
    let localName: String
    let thread: String
    let remoteName: String
    let remoteSession: String
    let remotePID: Int
    let remoteStart: String
    let configurationURL: URL
    let serviceURL: URL

    static var desktopSocket: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/app-server-control/app-server-control.sock").path
    }

    static var runtimeExecutable: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/relayd")
    }

    struct DiscoveryFailure: Error, LocalizedError, Sendable, Equatable {
        enum Work: String, Sendable { case noSaved = "no_saved_work_refs", savedUnverified = "saved_work_unverified", unavailable = "work_discovery_unavailable" }
        enum Legacy: String, Sendable { case empty, unavailable, notChecked = "not_checked", conflict = "identity_conflict" }
        let work: Work
        let legacy: Legacy

        var errorDescription: String? {
            let workMessage: String = switch work {
            case .noSaved: "No saved Work endpoints."
            case .savedUnverified: "Saved Work endpoint identity could not be verified."
            case .unavailable: "The Work endpoint registry could not be checked."
            }
            let legacyMessage: String = switch legacy {
            case .empty: "Legacy discovery found no tasks."
            case .unavailable: "Legacy discovery is unavailable."
            case .notChecked: "Legacy discovery was not checked."
            case .conflict: "A legacy task conflicts with a pinned Work identity; explicit repair is required."
            }
            return "Desktop task discovery incomplete: " + workMessage + " " + legacyMessage
        }
    }

    static func discoveryMessage(_ error: Error) -> String {
        (error as? DiscoveryFailure)?.errorDescription ?? "Desktop task discovery unavailable."
    }

    static func discoveryFailure(_ data: Data) -> DiscoveryFailure? {
        let prefix = "relayd: relay-desktop-discovery-go-v1:"
        guard data.count <= 160, let text = String(data: data, encoding: .utf8),
              text.hasPrefix(prefix), text.hasSuffix("\n") else { return nil }
        let fields = text.dropFirst(prefix.count).dropLast().split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == 2, let work = DiscoveryFailure.Work(rawValue: String(fields[0])),
              let legacy = DiscoveryFailure.Legacy(rawValue: String(fields[1])) else { return nil }
        switch (work, legacy) {
        case (.noSaved, .empty), (.noSaved, .unavailable),
             (.savedUnverified, .empty), (.savedUnverified, .unavailable), (.savedUnverified, .conflict),
             (.unavailable, .notChecked): return DiscoveryFailure(work: work, legacy: legacy)
        default: return nil
        }
    }

    private static func runtime(_ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = Self.runtimeExecutable
        process.arguments = ["desktop-route"] + arguments
        let output = Pipe(), errors = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output; process.standardError = errors
        let result = try ProcessCapture.run(process, output: output, errors: errors,
            timeout: 20, maximumBytesPerStream: 65_536)
        guard process.terminationStatus == 0 else {
            if arguments.first == "tasks", let failure = discoveryFailure(result.standardError) { throw failure }
            throw NSError(domain: "DesktopPeerRoute", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "Desktop routing failed. Check that the desktop app and Relay routing runtime are running; changed bindings must be reviewed explicitly."])
        }
        return result.standardOutput
    }

    struct MessageSendFailure: LocalizedError {
        let status: String
        var errorDescription: String? {
            status == "not_sent" ?
                "Message was refused before dispatch. Refresh this chat's exact route before sending." :
                "Message outcome is unknown. Check its receipt; do not retry with a new ID."
        }
    }

    static func taskAvailable(_ thread: String) throws -> Bool {
        let data = try runtime(["task-check", "--socket", desktopSocket, "--thread", thread])
        guard let item = try JSONSerialization.jsonObject(with: data) as? [String: String],
              item["id"] == thread, ["work_ipc", "app_server"].contains(item["transport"] ?? "") else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return true
    }

    private static func prepareTask(_ thread: String) throws {
        let data = try runtime(["task-prepare", "--socket", desktopSocket, "--thread", thread])
        guard let item = try JSONSerialization.jsonObject(with: data) as? [String: String],
              item["id"] == thread, ["work_ipc", "app_server"].contains(item["transport"] ?? "") else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }

    static func loadedTasks() throws -> [String] {
        let data = try runtime(["tasks", "--socket", desktopSocket])
        let tasks = try JSONDecoder().decode([String].self, from: data)
        guard tasks.count <= 128, tasks.allSatisfy({
            $0.range(of: #"^[A-Za-z0-9_][A-Za-z0-9_.-]{0,109}$"#, options: .regularExpression) != nil
        }) else { throw CocoaError(.fileReadCorruptFile) }
        return tasks
    }

    static func connections() throws -> [ConnectionRecord] {
        let data = try runtime(["connections", "--sync"])
        let rows = try JSONDecoder().decode([ConnectionRecord].self, from: data)
        guard rows.count <= 64, rows.allSatisfy({ $0.tasks.count <= 32 }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return rows
    }

    static func loadedTaskDetails() throws -> [TaskInfo] {
        let data = try runtime(["tasks", "--socket", desktopSocket, "--details"])
        let tasks = try JSONDecoder().decode([TaskInfo].self, from: data)
        guard tasks.count <= 128, Set(tasks.map(\.id)).count == tasks.count,
              tasks.allSatisfy({ task in
                  task.id.range(of: #"^[A-Za-z0-9_][A-Za-z0-9_.-]{0,109}$"#, options: .regularExpression) != nil &&
                  ["active", "idle", "unknown"].contains(task.status) &&
                  (task.name?.count ?? 0) <= 180 &&
                  (task.name?.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) } ?? true)
              }) else { throw CocoaError(.fileReadCorruptFile) }
        return tasks
    }

    static func applyGroup(_ plan: PeerGroupPlan) throws -> String {
        guard plan.transportError == nil else { throw CocoaError(.validationMissingMandatoryProperty) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("group.json")
        guard FileManager.default.createFile(atPath: file.path, contents: try JSONEncoder().encode(plan),
            attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
        let process = Process()
        process.executableURL = Self.runtimeExecutable
        process.arguments = ["desktop-group", file.path]
        let output = Pipe(), errors = Pipe()
        process.standardInput = FileHandle.nullDevice; process.standardOutput = output; process.standardError = errors
        let result = try ProcessCapture.run(process, output: output, errors: errors, timeout: 300, maximumBytesPerStream: 32_768)
        guard let value = try JSONSerialization.jsonObject(with: result.standardOutput) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        if let error = value["error"] as? String {
            throw NSError(domain: "DesktopPeerRoute", code: 3, userInfo: [NSLocalizedDescriptionKey:
                error + " Inspect saved group receipts before any retry."])
        }
        guard value["state"] as? String == "introductions_attempted" else { throw CocoaError(.fileReadCorruptFile) }
        return "Introduction attempts recorded. Socket writes do not prove agent acknowledgement."
    }

    static func remember(thread: String, host: String, peer: DiscoveredPeer, rebind: Bool = false) throws {
        guard try taskAvailable(thread), let start = peer.procStart,
              PeerDiscovery.validProcessStart(start, host: host) else {
            throw NSError(domain: "DesktopPeerRoute", code: 2, userInfo: [NSLocalizedDescriptionKey:
                "Refresh the endpoints. The desktop task must be open and the remote helper must report its process identity."])
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let request = directory.appendingPathComponent("request.json")
        let data = try JSONSerialization.data(withJSONObject: ["thread": thread, "host": host,
            "remoteName": peer.name, "remoteSession": peer.sessionId, "remotePID": peer.pid,
            "remoteStart": start, "localName": "pending", "socket": desktopSocket])
        guard FileManager.default.createFile(atPath: request.path, contents: data,
            attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
        _ = try runtime(["remember", "--connect"] + (rebind ? ["--rebind"] : []) + ["--config", request.path])
    }

    static func read(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [Self] {
        let directory = home.appendingPathComponent("Library/LaunchAgents")
        let files = (try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.lastPathComponent.hasPrefix("dev.vaklab.relay-desktop-") }
            .sorted { $0.path < $1.path }.prefix(32).compactMap { try? load(service: $0, home: home) }
    }

    func messageReceipt(_ messageID: String) throws -> MessageReceipt? {
        guard messageID.range(of: #"^[A-Za-z0-9_.-]{1,110}$"#, options: .regularExpression) != nil else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let directory = configurationURL.deletingLastPathComponent().appendingPathComponent("receipts")
        let file = directory.appendingPathComponent(configurationURL.deletingPathExtension().lastPathComponent + ".json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let data = try Self.privateData(file, limit: 65_536)
        let values = try JSONDecoder().decode([MessageReceipt].self, from: data)
        guard values.count <= 256, values.allSatisfy({
            ["pending", "not_sent", "written_to_socket", "unknown", "read_acknowledged"].contains($0.status) &&
            $0.id.range(of: #"^[A-Za-z0-9_.-]{1,110}$"#, options: .regularExpression) != nil &&
            $0.updatedAt.isFinite
        }) else { throw CocoaError(.fileReadCorruptFile) }
        if let recent = values.first(where: { $0.id == messageID }) { return recent }
        let archive = file.deletingPathExtension().appendingPathExtension("ids")
            .appendingPathComponent("id-" + messageID)
        guard FileManager.default.fileExists(atPath: archive.path) else { return nil }
        let archived = try Self.privateData(archive, limit: 16_384)
        if archived.isEmpty {
            return MessageReceipt(id: messageID, status: "unknown", updatedAt: 0)
        }
        let receipt = try JSONDecoder().decode(MessageReceipt.self, from: archived)
        guard receipt.id == messageID, receipt.updatedAt.isFinite,
              ["pending", "not_sent", "written_to_socket", "unknown", "read_acknowledged"].contains(receipt.status) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return receipt
    }

    func sendMessage(id messageID: String, content: String) throws -> MessageReceipt {
        var attempted = false
        do {
        guard messageID.range(of: #"^[A-Za-z0-9_.-]{1,110}$"#, options: .regularExpression) != nil,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              content.utf8.count <= 60_000 else { throw CocoaError(.validationMissingMandatoryProperty) }
        let current = try Self.load(service: serviceURL, home: FileManager.default.homeDirectoryForCurrentUser)
        guard current.localName == localName, current.thread == thread, current.host == host,
              current.remoteSession == remoteSession, current.remotePID == remotePID,
              current.remoteStart == remoteStart, current.remoteName == remoteName else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let process = Process()
        process.executableURL = Self.runtimeExecutable
        process.arguments = ["desktop-route", "send", "--config", configurationURL.path]
        let output = Pipe(), errors = Pipe()
        process.standardInput = Pipe(); process.standardOutput = output; process.standardError = errors
        let input = try JSONSerialization.data(withJSONObject: ["id": messageID, "content": content])
        attempted = true
        let result = try ProcessCapture.run(process, output: output, errors: errors,
                                            input: input, timeout: 25, maximumBytesPerStream: 16_384)
        let response = try JSONSerialization.jsonObject(with: result.standardOutput) as? [String: Any]
        if response?["receipt"] as? String == "not_sent" {
            throw MessageSendFailure(status: "not_sent")
        }
        guard process.terminationStatus == 0,
              response?["receipt"] as? String == "written_to_socket" else {
            throw MessageSendFailure(status: "unknown")
        }
        return try messageReceipt(messageID) ?? MessageReceipt(id: messageID, status: "unknown", updatedAt: Date().timeIntervalSince1970)
        } catch let error as MessageSendFailure {
            throw error
        } catch {
            throw MessageSendFailure(status: attempted ? "unknown" : "not_sent")
        }
    }

    private static func privateData(_ url: URL, limit: Int) throws -> Data {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              let mode = attributes[.posixPermissions] as? NSNumber,
              mode.intValue & 0o022 == 0,
              (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= limit else {
            throw CocoaError(.fileReadNoPermission)
        }
        let data = try Data(contentsOf: url)
        guard data.count <= limit else { throw CocoaError(.fileReadTooLarge) }
        return data
    }

    static func load(service: URL, home: URL) throws -> Self {
        let root = home.appendingPathComponent(".local/share/relay/desktop-routing")
        let data = try privateData(service, limit: 16_384)
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let label = plist["Label"] as? String,
              label.range(of: #"^dev\.vaklab\.relay-desktop-[A-Za-z0-9_-]{1,64}$"#, options: .regularExpression) != nil,
              service.lastPathComponent == label + ".plist",
              let args = plist["ProgramArguments"] as? [String], args.count == 5,
              ((args[0] == Self.runtimeExecutable.path && args[1] == "desktop-route") ||
               (args[0] == root.appendingPathComponent("venv/bin/python").path &&
                args[1] == root.appendingPathComponent("relay-desktop-route.py").path)),
              args[2] == "listen", args[3] == "--config" else { throw CocoaError(.fileReadCorruptFile) }
        let configuration = URL(fileURLWithPath: args[4]).standardizedFileURL
        guard configuration.deletingLastPathComponent() == root.standardizedFileURL else {
            throw CocoaError(.fileReadNoPermission)
        }
        let raw = try privateData(configuration, limit: 16_384)
        guard let c = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let storedHost = c["host"] as? String ?? ""
        guard let pid = c["remotePID"] as? Int, pid > 0,
              let start = c["remoteStart"] as? String,
              PeerDiscovery.validProcessStart(start, host: storedHost) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        func identifier(_ key: String) throws -> String {
            guard let value = c[key] as? String,
                  value.range(of: #"^[A-Za-z0-9_][A-Za-z0-9_.-]{0,109}$"#, options: .regularExpression) != nil else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return value
        }
        return try Self(id: label, host: identifier("host"), localName: identifier("localName"),
                        thread: identifier("thread"), remoteName: identifier("remoteName"),
                        remoteSession: identifier("remoteSession"), remotePID: pid, remoteStart: start,
                        configurationURL: configuration, serviceURL: service)
    }

    func matches(_ status: PeerNetworkStatus) -> Bool {
        status.host == host && status.localName == localName && status.localSession == thread &&
            status.remoteSession == remoteSession && status.remotePID == remotePID &&
            status.remoteStart == remoteStart
    }

    func setConnected(_ connected: Bool, home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        // Revalidate at action time. A changed binding requires rediscovery.
        let current = try Self.load(service: serviceURL, home: home)
        guard current.id == id, current.host == host, current.localName == localName,
              current.configurationURL == configurationURL, current.remoteName == remoteName,
              current.thread == thread, current.remoteSession == remoteSession,
              current.remotePID == remotePID, current.remoteStart == remoteStart else {
            throw CocoaError(.fileReadCorruptFile)
        }
        if connected {
            // The native runtime validates and migrates only this exact saved
            // launch service before enabling it; legacy definitions are read
            // for discovery and disconnect, never executed by this app.
            _ = try Self.runtime(["remember", "--connect", "--config", configurationURL.path])
            return
        }
        let target = "gui/\(getuid())/\(id)"
        // launchd's disabled override survives logout. Killing alone would let
        // RunAtLoad silently reconnect a route the user explicitly disconnected.
        for arguments in Self.serviceCommands(connected: connected, target: target) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = arguments
            let output = Pipe(), errors = Pipe()
            process.standardOutput = output; process.standardError = errors
            process.standardInput = FileHandle.nullDevice
            _ = try ProcessCapture.run(process, output: output, errors: errors, timeout: 5, maximumBytesPerStream: 8192)
            guard process.terminationStatus == 0 else {
                throw NSError(domain: "RelayDesktopRoute", code: Int(process.terminationStatus),
                    userInfo: [NSLocalizedDescriptionKey: "The messaging service could not be changed. Check that this saved route is installed for the current login."])
            }
        }
    }

    func handoff(to task: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        let current = try Self.load(service: serviceURL, home: home)
        guard current.id == id, current.configurationURL == configurationURL,
              current.thread == thread, current.host == host,
              current.remoteSession == remoteSession else { throw CocoaError(.fileReadCorruptFile) }
        _ = try Self.runtime(["handoff", "--config", configurationURL.path, "--thread", task])
    }

    static func serviceCommands(connected: Bool, target: String) -> [[String]] {
        connected ? [["enable", target], ["kickstart", target]] :
            [["disable", target], ["kill", "SIGTERM", target]]
    }
}
