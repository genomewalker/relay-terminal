import Foundation
import Testing
@testable import Relay

/// Miko's host comes only from the pinned key: focus, pane order and open
/// panes never choose it, and an unknown key is refused rather than replaced.
@Suite(.serialized)
@MainActor
struct RelayMikoHostPinTests {
    private struct SplitMix64 {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9e37_79b9_7f4a_7c15
            var z = state
            z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
            z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
            return z ^ (z >> 31)
        }
        mutating func below(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    }

    @Test("Default Miko host is This Mac")
    func defaultIsThisMac() throws {
        let defaults = try #require(UserDefaults(suiteName: "relay.tests.miko-host." + UUID().uuidString))
        #expect(RelayPreferences.storedMikoHostKey(defaults) == ConnectionProfile.local.connectionKey)
        defaults.set("dandy-07", forKey: "relay.settings.miko-host")
        #expect(RelayPreferences.storedMikoHostKey(defaults) == "dandy-07")
    }

    @Test("Resolver depends only on the key, never on candidate order")
    func resolverIgnoresOrder() {
        let pool: [ConnectionProfile] = [
            .local,
            ConnectionProfile(name: "dandy-07", kind: .ssh, host: "dandy-07", backend: .relay),
            ConnectionProfile(name: "dandy-07 direct", kind: .ssh, host: "dandy-07", backend: .direct),
            .sshConfigHost("dandy-08"),
            ConnectionProfile(name: "other", kind: .ssh, host: "other.invalid", user: "u", backend: .relay),
        ]
        let keys = pool.map(\.connectionKey) + ["unknown.invalid", ""]
        for seed: UInt64 in [1, 0x5eed_0029_1029, 0xdead_beef, 0x6746_1977_2273_2167] {
            var random = SplitMix64(state: seed)
            for _ in 0..<600 {
                var candidates = (0..<random.below(9)).map { _ in pool[random.below(pool.count)] }
                let key = keys[random.below(keys.count)]
                let expected = candidates.contains { $0.connectionKey == key && $0.backend == .relay }
                let first = RelayAssistantHarness.mikoHost(key: key, candidates: candidates)
                candidates.reverse()
                let reversed = RelayAssistantHarness.mikoHost(key: key, candidates: candidates)
                #expect((first != nil) == expected)
                #expect(first?.connectionKey == reversed?.connectionKey)
                #expect(first.map { $0.connectionKey == key && $0.backend == .relay } ?? true)
            }
        }
    }

    @Test("Live model uses the pinned host whichever pane has focus")
    func liveModelFollowsPinNotFocus() throws {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.shutdown() }
        let focused = try #require(workspace.activePane)
        #expect(focused.profile.connectionKey == ConnectionProfile.local.connectionKey)
        let preferences = RelayPreferences.shared
        let oldKey = preferences.mikoHostKey
        let oldProfiles = workspace.profileStore.profiles
        defer { preferences.mikoHostKey = oldKey; workspace.profileStore.profiles = oldProfiles }

        preferences.mikoHostKey = ConnectionProfile.local.connectionKey
        #expect(try RelayAssistantHarness.liveModel(workspace).1 == RelayAssistantHaikuModel.hostID(for: .local))

        let dandy = ConnectionProfile(name: "dandy-07", kind: .ssh, host: "dandy-07.invalid", backend: .relay)
        preferences.mikoHostKey = dandy.connectionKey
        #expect(throws: RelayAssistantModelFailure.pinnedHostUnavailable) { try RelayAssistantHarness.liveModel(workspace) }

        workspace.profileStore.profiles = oldProfiles + [dandy]
        #expect(try RelayAssistantHarness.liveModel(workspace).1 == RelayAssistantHaikuModel.hostID(for: dandy))
        #expect(workspace.activePane === focused)
    }
}
