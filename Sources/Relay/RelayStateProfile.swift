import Foundation

struct RelayStateConfiguration: Equatable, Sendable {
    let applicationSupportRoot: URL
    let defaultsSuite: String?
    let sidePanelPort: UInt16
    let isIsolated: Bool
    let error: String?

    static func resolve(
        stateRoot: String?, defaultsSuite: String?, sidePanelPort: String?,
        bundleIdentifier: String?, productionSupportRoot: URL,
        processID: Int32 = ProcessInfo.processInfo.processIdentifier
    ) -> RelayStateConfiguration {
        let quarantine = FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-invalid-profile-\(processID)", isDirectory: true)
        func invalid(_ reason: String) -> RelayStateConfiguration {
            RelayStateConfiguration(applicationSupportRoot: quarantine,
                defaultsSuite: "dev.relay.invalid-profile.\(processID)", sidePanelPort: 0,
                isIsolated: true, error: reason)
        }
        let supplied = [stateRoot, defaultsSuite, sidePanelPort].contains { $0?.isEmpty == false }
        guard supplied else {
            guard bundleIdentifier == "dev.relay.terminal" else {
                return invalid("A non-production Relay build requires an explicit isolated profile.")
            }
            return RelayStateConfiguration(applicationSupportRoot: productionSupportRoot,
                defaultsSuite: nil, sidePanelPort: 47_471, isIsolated: false, error: nil)
        }
        guard let stateRoot, let defaultsSuite, let sidePanelPort,
              !stateRoot.isEmpty, !defaultsSuite.isEmpty, !sidePanelPort.isEmpty else {
            return invalid("The isolated Relay profile is incomplete.")
        }
        guard stateRoot.hasPrefix("/"), !stateRoot.contains("\0"),
              !defaultsSuite.contains("\0") else {
            return invalid("The isolated Relay profile contains an invalid path or suite.")
        }
        guard let port = UInt16(sidePanelPort), port >= 1024, port != 47_471 else {
            return invalid("The isolated Relay profile needs its own valid side-panel port.")
        }

        let root = URL(fileURLWithPath: stateRoot, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        let production = productionSupportRoot.standardizedFileURL.resolvingSymlinksInPath()
        let productionRelay = production.appendingPathComponent("Relay", isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        guard root != production, root != productionRelay else {
            return invalid("The isolated Relay profile resolves to production state.")
        }
        // UserDefaults rejects an app's bundle identifier as an explicit suite
        // name. Keep the isolated suite distinct, and never impersonate production.
        guard bundleIdentifier != "dev.relay.terminal",
              defaultsSuite != "dev.relay.terminal",
              defaultsSuite != bundleIdentifier else {
            return invalid("The isolated Relay profile uses an invalid defaults suite.")
        }
        return RelayStateConfiguration(applicationSupportRoot: root,
            defaultsSuite: defaultsSuite, sidePanelPort: port,
            isIsolated: true, error: nil)
    }
}

/// One process-wide persistence boundary, resolved before any store or listener
/// is initialized. Invalid candidate settings are quarantined and never fall
/// back to production state.
enum RelayStateProfile {
    private static func configured(_ environmentKey: String, bundleKey: String) -> String? {
        if let value = ProcessInfo.processInfo.environment[environmentKey], !value.isEmpty {
            return value
        }
        guard let value = Bundle.main.object(forInfoDictionaryKey: bundleKey) as? String,
              !value.isEmpty else { return nil }
        return value
    }

    static let configuration = RelayStateConfiguration.resolve(
        stateRoot: configured("RELAY_STATE_ROOT", bundleKey: "RelayStateRoot"),
        defaultsSuite: configured("RELAY_DEFAULTS_SUITE", bundleKey: "RelayDefaultsSuite"),
        sidePanelPort: configured("RELAY_SIDE_PANEL_PORT", bundleKey: "RelaySidePanelPort"),
        bundleIdentifier: Bundle.main.bundleIdentifier,
        productionSupportRoot: FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
    )

    static func makeDefaults(
        configuration: RelayStateConfiguration,
        suiteFactory: (String) -> UserDefaults? = { UserDefaults(suiteName: $0) }
    ) -> UserDefaults? {
        if let suite = configuration.defaultsSuite { return suiteFactory(suite) }
        return configuration.isIsolated ? nil : .standard
    }

    nonisolated(unsafe) static let defaults: UserDefaults = {
        guard let defaults = makeDefaults(configuration: configuration) else {
            fatalError("Relay cannot open its isolated defaults suite; refusing production fallback")
        }
        return defaults
    }()

    static var applicationSupportRoot: URL { configuration.applicationSupportRoot }
    static var sidePanelPort: UInt16 { configuration.sidePanelPort }
    static var configurationError: String? { configuration.error }
    static var isIsolated: Bool { configuration.isIsolated && configuration.error == nil }

    static var peerNetworkStatusRoot: URL {
        if configuration.isIsolated {
            return applicationSupportRoot
                .appendingPathComponent("Relay/PeerNetworkStatus", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state/relay/peer-network", isDirectory: true)
    }
}
