import Foundation
import Darwin

/// Single actor serializes state changes. A single atomically replaced file is
/// the commit point; pending reviews never change the active installation.
actor RelayPluginStore {
    struct Revision: Codable, Sendable {
        let bytes: Data
        let repository: String
        let releaseTag: String
        let digest: String

        init(_ candidate: ReviewedPluginCandidate) {
            bytes = candidate.bytes
            repository = candidate.repository
            releaseTag = candidate.releaseTag
            digest = candidate.digest
        }

        func validated() throws -> ReviewedPluginCandidate {
            let result = try ReviewedPluginCandidate(bytes: bytes, repository: repository, releaseTag: releaseTag)
            guard result.digest == digest else { throw PluginError.invalid("Stored package digest mismatch") }
            return result
        }
    }

    struct Installation: Codable, Sendable {
        var current: Revision
        var previous: Revision?
        var enabled: Bool
    }

    private struct State: Codable { var schema = 1; var installations: [String: Installation] = [:] }
    private let file: URL
    private var state = State()
    private var loaded = false
    private let safeMode: Bool
    private static let maximumInstallations = 64
    private static let maximumStateBytes = 48 * 1024 * 1024

    init(directory: URL, safeMode: Bool = false) {
        file = directory.appendingPathComponent("installations.json")
        self.safeMode = safeMode
    }

    func installations() throws -> [String: Installation] {
        let lock = try beginTransaction(); defer { endTransaction(lock) }
        return state.installations
    }

    /// The UI must show this digest and repository before invoking install.
    /// Only core-owned tool capabilities can activate; each use is separately scoped.
    func install(_ candidate: ReviewedPluginCandidate, approvedDigest: String) throws {
        let lock = try beginTransaction(); defer { endTransaction(lock) }
        guard candidate.digest == approvedDigest else { throw PluginError.invalid("Package changed after review") }
        let id = candidate.package.id
        let existing = state.installations[id]
        guard existing != nil || state.installations.count < Self.maximumInstallations else {
            throw PluginError.invalid("Plugin installation limit reached")
        }
        if let existing {
            guard existing.current.repository == candidate.repository else { throw PluginError.invalid("Plugin ID belongs to another repository") }
            if existing.current.digest == candidate.digest { return }
            let old = try existing.current.validated()
            guard old.package.version != candidate.package.version else {
                throw PluginError.invalid("This version was republished with different contents; use a new version")
            }
        }
        var updated = state
        updated.installations[id] = Installation(current: Revision(candidate), previous: existing?.current, enabled: false)
        try commit(updated)
    }

    func setEnabled(_ id: String, _ enabled: Bool) throws {
        let lock = try beginTransaction(); defer { endTransaction(lock) }
        guard var installation = state.installations[id] else { throw PluginError.invalid("Plugin is not installed") }
        let candidate = try installation.current.validated()
        if enabled {
            guard !safeMode else { throw PluginError.invalid("Plugins are disabled in safe mode") }
            guard candidate.package.supportsActivation else {
                throw PluginError.invalid("This plugin requires capabilities that are not yet supported")
            }
        }
        installation.enabled = enabled
        var updated = state
        updated.installations[id] = installation
        try commit(updated)
    }

    func activePackages() throws -> [RelayPluginPackage] {
        let lock = try beginTransaction(); defer { endTransaction(lock) }
        guard !safeMode else { return [] }
        return try state.installations.values.filter(\.enabled).map {
            let package = try $0.current.validated().package
            guard package.supportsActivation else { throw PluginError.invalid("Unsupported active permissions") }
            return package
        }.sorted { $0.id < $1.id }
    }

    func rollback(_ id: String) throws {
        let lock = try beginTransaction(); defer { endTransaction(lock) }
        guard var installation = state.installations[id], let previous = installation.previous else {
            throw PluginError.invalid("No previous version is available")
        }
        _ = try previous.validated()
        installation.previous = installation.current
        installation.current = previous
        installation.enabled = false
        var updated = state
        updated.installations[id] = installation
        try commit(updated)
    }

    func uninstall(_ id: String) throws {
        let lock = try beginTransaction(); defer { endTransaction(lock) }
        var updated = state
        updated.installations.removeValue(forKey: id)
        try commit(updated)
    }

    private func beginTransaction() throws -> Int32 {
        let directory = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lock = Darwin.open(directory.appendingPathComponent(".install.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw PluginError.invalid("Cannot open plugin installation lock") }
        // Fail promptly rather than hanging a Settings operation behind another app instance.
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(lock)
            throw PluginError.invalid("Another Relay instance is changing plugins; retry shortly")
        }
        do {
            loaded = false
            state = State()
            try load()
            return lock
        } catch {
            endTransaction(lock)
            throw error
        }
    }

    private func endTransaction(_ lock: Int32) {
        flock(lock, LOCK_UN)
        Darwin.close(lock)
    }

    private func load() throws {
        guard !loaded else { return }
        guard FileManager.default.fileExists(atPath: file.path) else { loaded = true; return }
        let attributes = try file.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey, .isRegularFileKey])
        guard attributes.isSymbolicLink != true, attributes.isRegularFile == true else {
            throw PluginError.invalid("Plugin state must be a regular file, not a link")
        }
        let size = attributes.fileSize ?? 0
        guard size <= Self.maximumStateBytes else { throw PluginError.invalid("Plugin state exceeds size limit") }
        let decoded = try JSONDecoder().decode(State.self, from: Data(contentsOf: file))
        guard decoded.schema == 1, decoded.installations.count <= Self.maximumInstallations else {
            throw PluginError.invalid("Unsupported plugin state")
        }
        for (id, installation) in decoded.installations {
            let current = try installation.current.validated()
            guard current.package.id == id else { throw PluginError.invalid("Stored plugin identity mismatch") }
            if let previous = installation.previous {
                let old = try previous.validated()
                guard old.package.id == id, old.repository == current.repository else { throw PluginError.invalid("Invalid rollback identity") }
            }
        }
        state = decoded
        loaded = true
    }

    private func commit(_ updated: State) throws {
        let bytes = try JSONEncoder().encode(updated)
        guard bytes.count <= Self.maximumStateBytes else { throw PluginError.invalid("Plugin state exceeds size limit") }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: file, options: .atomic)
        state = updated
    }
}
