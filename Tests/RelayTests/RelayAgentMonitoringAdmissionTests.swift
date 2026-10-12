import Testing
@testable import Relay

@Test("Agent event observers cover local and remote Relay terminals")
func agentMonitoringHostCoverage() {
    #expect(RelayAgentMonitoringAdmission.allows(profile: .local, contentKind: .terminal))
    #expect(RelayAgentMonitoringAdmission.allows(profile: .sshConfigHost("fixture"), contentKind: .terminal))
    #expect(!RelayAgentMonitoringAdmission.allows(profile: .local, contentKind: .editor))
    #expect(!RelayAgentMonitoringAdmission.allows(profile: .sshConfigHost("fixture"), contentKind: .editor))
}
