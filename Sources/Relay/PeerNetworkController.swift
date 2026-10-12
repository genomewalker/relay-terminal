import Foundation
import Combine

struct PeerLinkConfiguration: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var host = ""
    var localName = ""
    var localSession = ""
    var localPID = ""
    var localLabel = "laptop"
    var remoteName = ""
    var remoteSession = ""
    var remotePID = ""
    var remoteStart: String? = nil
    var remoteLabel = ""
    var remoteBinary = ".local/share/relay/peer-network/relay-peer-link"

    var validationError: String? {
        let identifier = #"^[A-Za-z0-9_][A-Za-z0-9_.-]{0,109}$"#
        for value in [host, localName, localSession, localLabel, remoteName, remoteSession, remoteLabel] {
            guard value.range(of: identifier, options: .regularExpression) != nil else {
                return "Use exact peer identifiers and an SSH host alias (letters, numbers, dots, hyphens or underscores)."
            }
        }
        guard let local = Int32(localPID), local > 0, let remote = Int32(remotePID), remote > 0 else {
            return "Both process IDs must be positive numbers."
        }
        if let remoteStart, (remoteStart.isEmpty || remoteStart.utf8.count > 128 || remoteStart.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })) {
            return "The remote process start identity is invalid. Refresh discovery."
        }
        guard localLabel.count + localName.count <= 110,
              remoteLabel.count + remoteName.count <= 110 else { return "Combined host and peer names are too long." }
        guard remoteBinary.count <= 512,
              remoteBinary.range(of: #"^[A-Za-z0-9_./][A-Za-z0-9_./-]*$"#, options: .regularExpression) != nil else {
            return "Enter a remote helper path without spaces or shell characters."
        }
        return nil
    }

    var arguments: [String] {
        ["--name", localName, "--session", localSession, "--pid", localPID,
         "--label", localLabel, "--host", host, "--remote-name", remoteName,
         "--remote-session", remoteSession, "--remote-pid", remotePID,
         "--remote-label", remoteLabel, "--remote-binary", remoteBinary, "--retries", "5"] +
            (remoteStart.map { ["--remote-start", $0] } ?? [])
    }
}

/// Owns only processes launched from Relay's explicit connection controls.
/// It never signals a process inferred from a status file or a provider PID.
@MainActor
final class PeerNetworkController: ObservableObject {
    static let shared = PeerNetworkController()
    @Published private(set) var configurations: [PeerLinkConfiguration] = []
    @Published private(set) var running: Set<UUID> = []
    @Published var error: String?
    private var processes: [UUID: Process] = [:]
    private var logs: [UUID: FileHandle] = [:]
    private var stopping: Set<UUID> = []
    private(set) var revision: UInt64 = 0
    private let root: URL

    init(root: URL? = nil) {
        self.root = root ?? RelayStateProfile.applicationSupportRoot
            .appendingPathComponent("Relay/PeerNetwork", isDirectory: true)
        let file = self.root.appendingPathComponent("links.json")
        if let values = try? file.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey]),
           values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 262_144,
           let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode([PeerLinkConfiguration].self, from: data),
           saved.count <= 32, Set(saved.map(\.id)).count == saved.count {
            configurations = saved.filter { $0.validationError == nil }
        }
    }

    @discardableResult
    func save(_ configuration: PeerLinkConfiguration) -> Bool {
        guard configuration.validationError == nil else { error = configuration.validationError; return false }
        guard configurations.count < 32 else { error = "At most 32 explicit links can be configured."; return false }
        guard !configurations.contains(where: { $0.id == configuration.id }) else {
            error = "This configuration identifier already exists."; return false
        }
        guard !configurations.contains(where: {
            $0.host == configuration.host && $0.localSession == configuration.localSession &&
            $0.remoteSession == configuration.remoteSession && $0.remotePID == configuration.remotePID
        }) else { error = "This session pair is already configured."; return false }
        let next = configurations + [configuration]
        do {
            try persist(next)
            configurations = next
            revision &+= 1
            error = nil
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    func remove(_ configuration: PeerLinkConfiguration) {
        guard !running.contains(configuration.id) else { error = "Disconnect this link before removing it."; return }
        let next = configurations.filter { $0.id != configuration.id }
        do { try persist(next); configurations = next; revision &+= 1 } catch { self.error = error.localizedDescription }
    }

    private func persist(_ values: [PeerLinkConfiguration]) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(values)
        let target = root.appendingPathComponent("links.json")
        try data.write(to: target, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    }

    func connect(_ configuration: PeerLinkConfiguration, observed: [PeerNetworkStatus]) {
        guard !running.contains(configuration.id) else { return }
        guard configuration.validationError == nil else { error = configuration.validationError; return }
        guard !observed.contains(where: {
            $0.host == configuration.host && $0.localSession == configuration.localSession &&
            $0.remoteSession == configuration.remoteSession && $0.displayState() == "Connected"
        }) else { error = "This pair already has a live link. Disconnect its current owner first."; return }
        guard let executable = Bundle.main.executableURL?.deletingLastPathComponent()
            .appendingPathComponent("relay-peer-link"), FileManager.default.isExecutableFile(atPath: executable.path) else {
            error = "The bundled peer-link helper is missing. Install a Relay build that includes it."
            return
        }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let logURL = root.appendingPathComponent("\(configuration.id.uuidString).log")
            // A fresh, bounded-lifetime link run replaces its own diagnostic log.
            try Data().write(to: logURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logURL.path)
            let handle = try FileHandle(forWritingTo: logURL)
            let process = Process()
            process.executableURL = executable
            process.arguments = configuration.arguments
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = handle
            let id = configuration.id
            process.terminationHandler = { [weak self] process in
                let status = process.terminationStatus
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.processes.removeValue(forKey: id)
                    self.revision &+= 1
                    self.running.remove(id)
                    try? self.logs.removeValue(forKey: id)?.close()
                    let intentional = self.stopping.remove(id) != nil
                    if status != 0 && !intentional { self.error = "Link stopped. Check connection status and the link log; messages were not replayed." }
                }
            }
            do { try process.run() } catch { try? handle.close(); throw error }
            processes[id] = process
            logs[id] = handle
            running.insert(id)
            revision &+= 1
        } catch { self.error = error.localizedDescription }
    }

    static func nativePairConfiguration(local: PeerGroupPlan.Endpoint, remote: PeerGroupPlan.Endpoint) -> PeerLinkConfiguration? {
        guard local.kind == .native, local.host == "laptop", remote.kind == .native,
              remote.host != "laptop", let localPID = local.pid, let remotePID = remote.pid,
              let remoteStart = remote.processStart else { return nil }
        var configuration = PeerLinkConfiguration()
        configuration.host = remote.host
        configuration.localName = local.name
        configuration.localSession = local.session
        configuration.localPID = String(localPID)
        configuration.localLabel = "laptop"
        configuration.remoteName = remote.name
        configuration.remoteSession = remote.session
        configuration.remotePID = String(remotePID)
        configuration.remoteStart = remoteStart
        configuration.remoteLabel = remote.host
        return configuration.validationError == nil ? configuration : nil
    }

    func connectNativePair(local: PeerGroupPlan.Endpoint, remote: PeerGroupPlan.Endpoint) -> String? {
        guard let requested = Self.nativePairConfiguration(local: local, remote: remote) else {
            return "This cross-host native pair is not fully verified."
        }
        let existing = configurations.first {
            $0.host == requested.host && $0.localSession == requested.localSession &&
                $0.remoteSession == requested.remoteSession && $0.remotePID == requested.remotePID
        }
        var configuration = existing ?? requested
        if existing == nil {
            guard save(configuration) else { return error ?? "Could not save the direct link." }
        } else {
            if running.contains(configuration.id) { return nil }
            configuration.remoteStart = requested.remoteStart
            var updated = configurations
            if let index = updated.firstIndex(where: { $0.id == configuration.id }) {
                updated[index] = configuration
                do { try persist(updated); configurations = updated } catch { return error.localizedDescription }
            }
        }
        connect(configuration, observed: [])
        return running.contains(configuration.id) ? nil : (error ?? "Could not start the direct SSH link.")
    }

    func disconnect(_ configuration: PeerLinkConfiguration) {
        guard let process = processes[configuration.id], process.isRunning else { return }
        stopping.insert(configuration.id)
        revision &+= 1
        process.terminate()
    }

    func disconnectAll() {
        revision &+= 1
        for (id, process) in processes where process.isRunning { stopping.insert(id); process.terminate() }
    }
}
