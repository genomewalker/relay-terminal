import Foundation
import Testing
@testable import Relay

@Suite("Local dedicated helper terminal negotiation")
struct LocalRelayDedicatedEnvironmentTests {
    @Test func terminalHelperObservesStatusAndPreservesRepaint() {
        let process = Process()
        LocalRelayProcess.configureDedicated(process, observeAgentsOnly: false, repaint: true)
        #expect(process.environment?["RELAY_OBSERVE_PROGRAM_STATUS"] == "1")
        #expect(process.environment?["RELAY_ATTACH_REPAINT"] == "1")
        #expect(process.environment?["PROMPT_COMMAND"] == nil)
        #expect(process.currentDirectoryURL == FileManager.default.homeDirectoryForCurrentUser)
    }
    @Test func terminalWithoutRepaintStillObservesStatus() {
        let process = Process()
        LocalRelayProcess.configureDedicated(process, observeAgentsOnly: false, repaint: false)
        #expect(process.environment?["RELAY_OBSERVE_PROGRAM_STATUS"] == "1")
        #expect(process.environment?["RELAY_ATTACH_REPAINT"] == nil)
    }
    @Test func agentObserverHasNeitherTerminalFlag() {
        let process = Process()
        LocalRelayProcess.configureDedicated(process, observeAgentsOnly: true, repaint: true)
        #expect(process.environment?["RELAY_OBSERVE_PROGRAM_STATUS"] == nil)
        #expect(process.environment?["RELAY_ATTACH_REPAINT"] == nil)
    }
    @Test func isolatedRoutingAndShellEnvironmentArePreserved() {
        let standard = Process(), dedicated = Process()
        LocalRelayProcess.configure(standard)
        LocalRelayProcess.configureDedicated(dedicated, observeAgentsOnly: false, repaint: true)
        for key in ["XDG_RUNTIME_DIR", "XDG_STATE_HOME", "SHELL", "PATH"] {
            #expect(dedicated.environment?[key] == standard.environment?[key])
        }
    }
}
