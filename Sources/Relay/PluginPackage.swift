import CryptoKit
import Foundation

/// v1 packages are data, never Swift/JavaScript, shell commands, HTML or archives.
/// Runtime capabilities must be separately implemented and broker-authorized.
struct RelayPluginPackage: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let apiVersion: Int
    let id: String
    let name: String
    let version: String
    let repository: String
    let permissions: [Permission]
    let contributions: [Contribution]

    struct Permission: Codable, Hashable, Sendable {
        enum Kind: String, Codable, Sendable {
            case agentMetadata, agentContent, projectRead, projectWrite, projectExecute, network, remoteOperation, jobSubmit, jobCancel
        }
        let kind: Kind
        /// A concrete scope is supplied at activation, never taken from a package.
        let reason: String
    }

    struct Contribution: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Sendable { case information, link, tool }
        let id: String
        let kind: Kind
        let title: String
        let text: String
        let url: String?
        var operation: RelayPluginOperation? = nil
    }

    static let maximumBytes = 256 * 1024

    static func decode(_ data: Data, repository: String) throws -> Self {
        guard data.count <= maximumBytes else { throw PluginError.invalid("Package exceeds 256 KiB") }
        // Reject unknown top-level fields rather than silently ignoring a future executable entrypoint.
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: ["schemaVersion", "apiVersion", "id", "name", "version", "repository", "permissions", "contributions"]) else {
            throw PluginError.invalid("Unsupported package fields")
        }
        guard let permissionObjects = object["permissions"] as? [[String: Any]],
              permissionObjects.allSatisfy({ Set($0.keys).isSubset(of: ["kind", "reason"]) }),
              let contributionObjects = object["contributions"] as? [[String: Any]],
              contributionObjects.allSatisfy({ Set($0.keys).isSubset(of: ["id", "kind", "title", "text", "url", "operation"]) }) else {
            throw PluginError.invalid("Unsupported permission or contribution fields")
        }
        let package = try JSONDecoder().decode(Self.self, from: data)
        guard package.schemaVersion == 1, [1, 2, 3].contains(package.apiVersion) else {
            throw PluginError.invalid("Unsupported plugin schema or API")
        }
        guard validToken(package.id, maximum: 100), validToken(package.version, maximum: 64),
              !package.name.isEmpty, package.name.count <= 100 else {
            throw PluginError.invalid("Invalid plugin identity")
        }
        guard try GitHubPluginRepository(package.repository) == GitHubPluginRepository(repository) else {
            throw PluginError.invalid("Package repository does not match its source")
        }
        guard package.permissions.count <= 8,
              Set(package.permissions.map(\.kind)).count == package.permissions.count,
              package.permissions.allSatisfy({ !$0.reason.isEmpty && $0.reason.count <= 500 }),
              package.contributions.count <= 32,
              Set(package.contributions.map(\.id)).count == package.contributions.count else {
            throw PluginError.invalid("Invalid or duplicate permissions/contributions")
        }
        for item in package.contributions {
            guard validToken(item.id, maximum: 100), !item.title.isEmpty, item.title.count <= 120,
                  item.text.count <= 8_000 else { throw PluginError.invalid("Invalid contribution") }
            switch item.kind {
            case .tool:
                guard package.apiVersion >= 2, let operation = item.operation, item.url == nil,
                      !operation.isMutation || package.apiVersion >= 3,
                      Set(package.permissions.map(\.kind)).isSuperset(of: operation.permissions) else {
                    throw PluginError.invalid("Tool is missing its required permissions")
                }
            case .information:
                guard item.url == nil, item.operation == nil else { throw PluginError.invalid("Information must not contain an action") }
            case .link:
                guard item.operation == nil, let raw = item.url, raw.count <= 2_048,
                      let url = URLComponents(string: raw), url.scheme == "https",
                      let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else {
                    throw PluginError.invalid("Links must use HTTPS without embedded credentials")
                }
            }
        }
        return package
    }

    var supportsActivation: Bool {
        let required = contributions.compactMap(\.operation).reduce(into: Set<Permission.Kind>()) { $0.formUnion($1.permissions) }
        return Set(permissions.map(\.kind)) == required
    }

    private static func validToken(_ token: String, maximum: Int) -> Bool {
        !token.isEmpty && token.count <= maximum && token != "." && token != ".." &&
        token.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 46 || $0 == 95 }
    }
}

enum PluginError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}

struct GitHubPluginRepository: Equatable, Sendable {
    let slug: String
    init(_ value: String) throws {
        var candidate = value
        if value.hasPrefix("https://github.com/") { candidate = String(value.dropFirst(19)) }
        if candidate.hasSuffix("/") { candidate.removeLast() }
        let components = candidate.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2, components.allSatisfy({ component in
            !component.isEmpty && component.count <= 100 && component != "." && component != ".." &&
            component.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 46 || $0 == 95 }
        }) else { throw PluginError.invalid("Use owner/repository or an HTTPS github.com repository URL") }
        slug = candidate.lowercased()
    }
}

struct ReviewedPluginCandidate: Sendable {
    static func localManifest(_ bytes: Data) throws -> Self {
        guard bytes.count <= RelayPluginPackage.maximumBytes,
              let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let repository = object["repository"] as? String else {
            throw PluginError.invalid("Invalid local plugin manifest")
        }
        return try Self(bytes: bytes, repository: repository, releaseTag: "local-review")
    }
    let package: RelayPluginPackage
    let bytes: Data
    let digest: String
    let repository: String
    let releaseTag: String

    init(bytes: Data, repository: String, releaseTag: String) throws {
        // Keep an explicit scalar closure: the bound CharacterSet method
        // reference rejected valid tags in the optimized macOS build.
        guard !releaseTag.isEmpty, releaseTag.count <= 128,
              !releaseTag.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw PluginError.invalid("Invalid release tag")
        }
        self.repository = try GitHubPluginRepository(repository).slug
        package = try RelayPluginPackage.decode(bytes, repository: repository)
        self.bytes = bytes
        digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        self.releaseTag = releaseTag
    }
}
