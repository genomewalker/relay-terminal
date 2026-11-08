import Testing
@testable import Relay

@Suite("Go to pane command shortcut")
struct WorkOverviewShortcutTests {
    @Test("The overview has an independent Command Shift P binding")
    func defaultBinding() {
        let binding = RelayKeyBindingStorage.binding(for: .quickNavigate, overrides: [:])
        #expect(binding == RelayKeyBinding("p", command: true, shift: true))
        #expect(binding != RelayCommand.workspaceOverview.defaultBinding)
        #expect(binding != RelayCommand.findHost.defaultBinding)
    }

    @Test("Customizing overview preserves the existing host search command")
    func customBinding() {
        let custom = RelayKeyBinding("o", command: true, option: true)
        let overrides = [RelayCommand.quickNavigate.rawValue: custom]
        #expect(RelayKeyBindingStorage.binding(for: .quickNavigate, overrides: overrides) == custom)
        #expect(RelayKeyBindingStorage.binding(for: .findHost, overrides: overrides) == RelayCommand.findHost.defaultBinding)
    }
}
