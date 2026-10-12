import Foundation

#if DEBUG
/// A launch-scoped acceptance fixture for the isolated candidate only. It
/// supplies deterministic severe telemetry while the pane itself remains a
/// real local Relay terminal, so UI approval exercises the production receipt,
/// audit, capability, and native Ctrl-C path against a harmless process.
enum RelaySupervisorAcceptanceFixture {
    static var isEnabled: Bool {
        RelayStateProfile.isIsolated &&
            ProcessInfo.processInfo.environment["RELAY_SUPERVISOR_ACCEPTANCE_FIXTURE"] == "1"
    }

    static var configuration: RelaySupervisorConfiguration {
        var configuration = RelaySupervisorConfiguration()
        configuration.escalationCooldown = 0
        return configuration
    }
}
#endif
