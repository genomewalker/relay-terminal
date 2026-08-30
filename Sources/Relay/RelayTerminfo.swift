import CryptoKit
import Foundation

struct RelayTerminfoStatus: Equatable, Sendable {
    let name: String
    let fallback: String
    let hash: String
    let userDatabase: URL?
    let activeTerm: String
    let installedForCurrentUser: Bool
    let installedForSystemPrograms: Bool
    let updatedLocations: [URL]
    let message: String

    var usesRelayEntry: Bool { activeTerm == name }
}

enum RelayTerminfo {
    static let name = "xterm-relay"
    static let fallback = "xterm-256color"

    private static let lock = NSLock()
    // All access is serialized by `lock`; Swift cannot infer synchronization
    // performed by NSLock for static mutable storage.
    nonisolated(unsafe) private static var storedStatus = RelayTerminfoStatus(
        name: name,
        fallback: fallback,
        hash: "unavailable",
        userDatabase: nil,
        activeTerm: fallback,
        installedForCurrentUser: false,
        installedForSystemPrograms: false,
        updatedLocations: [],
        message: "Relay terminfo has not been checked yet."
    )

    static var status: RelayTerminfoStatus {
        lock.lock()
        defer { lock.unlock() }
        return storedStatus
    }

    @discardableResult
    static func bootstrap(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        bundledEntry: URL? = bundledEntryURL(),
        systemDatabases: [URL] = defaultSystemDatabases(),
        fileManager: FileManager = .default
    ) -> RelayTerminfoStatus {
        let result = install(
            homeDirectory: homeDirectory,
            bundledEntry: bundledEntry,
            systemDatabases: systemDatabases,
            fileManager: fileManager
        )
        lock.lock()
        storedStatus = result
        lock.unlock()
        RelayDiagnostics.shared.record(category: "terminal", name: "terminfo", details: [
            "term": result.activeTerm,
            "hash": result.hash,
            "user_visible": String(result.installedForCurrentUser),
            "system_visible": String(result.installedForSystemPrograms),
        ])
        return result
    }

    static var sessionEnvironment: [String: String] {
        let current = status
        guard current.usesRelayEntry, let root = current.userDatabase else {
            return ["TERM": fallback]
        }
        return [
            "TERM": name,
            "TERMINFO": root.path,
        ]
    }

    static var sudoCompatibilityCommand: String {
        "sudo env TERM=\(fallback)"
    }

    static var privilegedInstallCommand: String? {
        let current = status
        guard !current.installedForSystemPrograms,
              let bundled = bundledEntryURL(),
              let targetRoot = preferredPrivilegedDatabase()
        else { return nil }
        let directory = targetRoot.appendingPathComponent("78", isDirectory: true)
        let target = directory.appendingPathComponent(name)
        return "sudo mkdir -p \(shellQuote(directory.path)) && sudo install -m 0644 \(shellQuote(bundled.path)) \(shellQuote(target.path))"
    }

    static func install(
        homeDirectory: URL,
        bundledEntry: URL?,
        systemDatabases: [URL],
        fileManager: FileManager
    ) -> RelayTerminfoStatus {
        guard let bundledEntry,
              let data = try? Data(contentsOf: bundledEntry),
              !data.isEmpty else {
            return unavailable("The signed application does not contain xterm-relay; new shells use xterm-256color.")
        }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let userRoot = homeDirectory.appendingPathComponent(".terminfo", isDirectory: true)
        let userEntry = entryURL(in: userRoot)
        var updated: [URL] = []
        let userInstalled: Bool
        do {
            if try install(data, at: userEntry, directoryMode: 0o700, fileManager: fileManager) {
                updated.append(userEntry)
            }
            userInstalled = (try? Data(contentsOf: userEntry)) == data
        } catch {
            return RelayTerminfoStatus(
                name: name,
                fallback: fallback,
                hash: hash,
                userDatabase: userRoot,
                activeTerm: fallback,
                installedForCurrentUser: false,
                installedForSystemPrograms: false,
                updatedLocations: updated,
                message: "Could not install xterm-relay in \(userRoot.path): \(error.localizedDescription). New shells use xterm-256color."
            )
        }

        var systemInstalled = false
        for root in systemDatabases where fileManager.fileExists(atPath: root.path) {
            let target = entryURL(in: root)
            if fileManager.isWritableFile(atPath: root.path) {
                do {
                    if try install(data, at: target, directoryMode: 0o755, fileManager: fileManager) {
                        updated.append(target)
                    }
                } catch {
                    // User-local resolution remains authoritative. Settings
                    // exposes the system visibility failure without blocking shells.
                }
            }
            if (try? Data(contentsOf: target)) == data {
                systemInstalled = true
            }
        }

        let resolves = userInstalled && resolves(entry: name, in: userRoot)
        let activeTerm = resolves ? name : fallback
        let message: String
        if !resolves {
            message = "xterm-relay was installed but this host could not resolve it. New shells use xterm-256color."
        } else if systemInstalled {
            message = "xterm-relay is current for Relay shells and Homebrew/system terminal programs."
        } else {
            message = "xterm-relay is current for Relay shells. For sudo programs, use ‘sudo env TERM=xterm-256color …’ or copy the one-time install command below."
        }
        return RelayTerminfoStatus(
            name: name,
            fallback: fallback,
            hash: hash,
            userDatabase: userRoot,
            activeTerm: activeTerm,
            installedForCurrentUser: userInstalled && resolves,
            installedForSystemPrograms: systemInstalled,
            updatedLocations: updated,
            message: message
        )
    }

    private static func install(
        _ data: Data,
        at destination: URL,
        directoryMode: Int,
        fileManager: FileManager
    ) throws -> Bool {
        if (try? Data(contentsOf: destination)) == data { return false }
        let directory = destination.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: directoryMode]
        )
        let temporary = directory.appendingPathComponent(".xterm-relay.\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: temporary) }
        try data.write(to: temporary, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: temporary.path)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: destination)
        }
        return true
    }

    private static func resolves(entry: String, in root: URL) -> Bool {
        let executableCandidates = [
            "/opt/homebrew/opt/ncurses/bin/infocmp",
            "/usr/local/opt/ncurses/bin/infocmp",
            "/usr/bin/infocmp",
        ]
        guard let executable = executableCandidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-A", root.path, entry]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func bundledEntryURL() -> URL? {
        Bundle.module.url(
            forResource: name,
            withExtension: nil,
            subdirectory: "Terminfo/78"
        )
    }

    private static func entryURL(in root: URL) -> URL {
        root
            .appendingPathComponent("78", isDirectory: true)
            .appendingPathComponent(name)
    }

    private static func defaultSystemDatabases() -> [URL] {
        [
            URL(fileURLWithPath: "/opt/homebrew/opt/ncurses/share/terminfo", isDirectory: true),
            URL(fileURLWithPath: "/usr/local/opt/ncurses/share/terminfo", isDirectory: true),
        ]
    }

    private static func preferredPrivilegedDatabase() -> URL? {
        let candidates = defaultSystemDatabases() + [
            URL(fileURLWithPath: "/usr/local/share/terminfo", isDirectory: true),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
            ?? candidates.last
    }

    private static func unavailable(_ message: String) -> RelayTerminfoStatus {
        RelayTerminfoStatus(
            name: name,
            fallback: fallback,
            hash: "unavailable",
            userDatabase: nil,
            activeTerm: fallback,
            installedForCurrentUser: false,
            installedForSystemPrograms: false,
            updatedLocations: [],
            message: message
        )
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
