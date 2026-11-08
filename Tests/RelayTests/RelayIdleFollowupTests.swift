import AppKit
import Foundation
import Testing
@testable import Relay

private func temporaryJournalURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("journal.json")
}

@MainActor @Test("A pane-health sync bumps revision only when published state changed")
func paneHealthSyncRevisionOnlyOnChange() async throws {
    _ = NSApplication.shared
    let workspace = WorkspaceModel(restoreSavedWorkspace: false)
    let pane = try #require(workspace.activePane)
    pane.connected()
    let coordinator = RelayPaneHealthCoordinator(url: temporaryJournalURL())
    let start = coordinator.revision

    await coordinator.bumpingRevisionIfPublishedStateChanges {}
    #expect(coordinator.revision == start)

    // heartbeat itself does not publish; it adds a host entry the snapshot shows.
    await coordinator.bumpingRevisionIfPublishedStateChanges { coordinator.heartbeat(workspace) }
    #expect(coordinator.revision == start &+ 1)
    #expect(coordinator.snapshot().hosts.count == 1)

    // A repeat heartbeat only refreshes internal bookkeeping.
    await coordinator.bumpingRevisionIfPublishedStateChanges { coordinator.heartbeat(workspace) }
    #expect(coordinator.revision == start &+ 1)
    workspace.shutdown()
}

private func journalHost(_ url: URL, _ key: String) throws -> [String: Any] {
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
    return try #require((object?["hosts"] as? [String: Any])?[key] as? [String: Any])
}

/// The explicit-check operation ID must be durable before the check is
/// dispatched, also when the loaded journal was otherwise unchanged.
@MainActor @Test("Pre-dispatch check fence is written even after an unchanged load")
func paneHealthPreDispatchSaveIsWritten() async throws {
    _ = NSApplication.shared
    let workspace = WorkspaceModel(restoreSavedWorkspace: false)
    let pane = try #require(workspace.activePane)
    pane.connected()
    let key = pane.profile.connectionKey
    let url = temporaryJournalURL()
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    try Data(#"{"hosts":{},"tools":{}}"#.utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    let coordinator = RelayPaneHealthCoordinator(url: url)
    let oldHealth = RelayPreferences.shared.haikuPaneHealth
    RelayPreferences.shared.haikuPaneHealth = true
    defer { RelayPreferences.shared.haikuPaneHealth = oldHealth; workspace.shutdown() }
    try #require(!RelayPreferences.shared.shepherd.enabled)

    await coordinator.checkNow(workspace, profile: pane.profile)
    let host = try journalHost(url, key)
    let operation = try #require(host["daemonCheckOperationID"] as? String)
    #expect(!operation.isEmpty)
    #expect(host["daemonCheckSubmitted"] as? Bool == false)
}

@MainActor @Test("An unchanged pane-health journal is not rewritten, and a missing file is restored")
func paneHealthUnchangedJournalSkipsWrite() throws {
    _ = NSApplication.shared
    let workspace = WorkspaceModel(restoreSavedWorkspace: false)
    let pane = try #require(workspace.activePane)
    pane.connected()
    defer { workspace.shutdown() }
    let key = pane.profile.connectionKey
    let url = temporaryJournalURL()
    let coordinator = RelayPaneHealthCoordinator(url: url)
    coordinator.heartbeat(workspace)

    coordinator.accountConfigurationChanged(profile: pane.profile)
    #expect(try journalHost(url, key)["state"] as? String == "Account settings changed; waiting for a fresh check")
    let past = Date(timeIntervalSince1970: 1_000_000_000)
    try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: url.path)
    let bytes = try Data(contentsOf: url)
    let revision = coordinator.revision

    // Same journal: no encode, no write, no extra save revision.
    coordinator.accountConfigurationChanged(profile: pane.profile)
    let modified = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    #expect(modified == past)
    #expect(try Data(contentsOf: url) == bytes)
    #expect(coordinator.revision == revision &+ 1) // the method's own bump only

    // A deleted file is written again even though the journal is unchanged.
    try FileManager.default.removeItem(at: url)
    coordinator.accountConfigurationChanged(profile: pane.profile)
    #expect(try Data(contentsOf: url) == bytes)
}

@Test("Prompt parse memo parses once per unchanged screen and re-parses a changed one")
func promptParseMemoMatchesFreshParse() {
    let codexFooter = "\n\nGPT-Rosalind Research xhigh · Context 33% left · /exact/cwd\n? for shortcuts\n"
    let claudeFooter = "\n────────────────\nterm:main | [Opus 5.5] | idle\n$118.19\n◈ v5.73.1\n+ Bash ×8\n⏵⏵ bypass permissions on\n"
    let screens: [(String, String)] = [
        ("› \u{1b}[90mAsk Codex to do anything\u{1b}[39m" + codexFooter, "codex"),
        ("› Ask Codex to do anything" + codexFooter, "codex"),
        ("❯ " + claudeFooter, "claude"),
        ("❯ unsent draft" + claudeFooter, "claude"),
        ("❯ " + claudeFooter.replacingOccurrences(of: "idle", with: "idle · 2 agents"), "claude"),
    ]
    var memo = RelayPromptParseMemo()
    for (screen, provider) in screens {
        let before = memo.parses
        for agents in [0, 0, 2, 2] {
            #expect(memo.isEmpty(screen, provider: provider, explainedAgents: agents) ==
                RelayAgentMaintenancePrompt.isEmpty(screen, provider: provider, explainedAgents: agents))
        }
        #expect(memo.hasTypedText(screen, provider: provider) == RelayAgentMaintenancePrompt.hasTypedText(screen, provider: provider))
        #expect(memo.hasTypedText(screen, provider: provider) == RelayAgentMaintenancePrompt.hasTypedText(screen, provider: provider))
        // Unchanged screen: one parse per distinct question, not per call.
        #expect(memo.parses == before + 3)
    }
    // Returning to an earlier screen is a change and is parsed afresh.
    let (first, provider) = screens[0]
    let before = memo.parses
    #expect(memo.isEmpty(first, provider: provider) == RelayAgentMaintenancePrompt.isEmpty(first, provider: provider))
    #expect(memo.parses == before + 1)
    // A one-character change to the screen is never served from the cache.
    let edited = first.replacingOccurrences(of: "anything", with: "anythinG")
    #expect(memo.isEmpty(edited, provider: provider) == RelayAgentMaintenancePrompt.isEmpty(edited, provider: provider))
    #expect(memo.parses == before + 2)
    #expect(RelayAgentMaintenancePrompt.isEmpty(first, provider: provider) != RelayAgentMaintenancePrompt.isEmpty("› Ask Codex to do anything" + codexFooter, provider: provider))
}

/// Releases one pending sleep at a time; records the requested durations.
private actor ManualSleeper {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var requested: [TimeInterval] = []
    func sleep(_ seconds: TimeInterval) async {
        requested.append(seconds)
        await withCheckedContinuation { waiters.append($0) }
    }
    func pending() -> Int { waiters.count }
    func releaseOne() { if !waiters.isEmpty { waiters.removeFirst().resume() } }
}

@MainActor @Test("An observation going stale bumps revision at the boundary without a new sync")
func paneHealthObservationExpiryBumpsRevision() async throws {
    _ = NSApplication.shared
    let workspace = WorkspaceModel(restoreSavedWorkspace: false)
    let pane = try #require(workspace.activePane)
    pane.connected()
    defer { workspace.shutdown() }
    let coordinator = RelayPaneHealthCoordinator(url: temporaryJournalURL())
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    var now = start
    coordinator.clock = { now }
    let sleeper = ManualSleeper()
    coordinator.sleep = { await sleeper.sleep($0) }
    coordinator.heartbeat(workspace, now: start)

    coordinator.observe(pane, proof: RelayAgentMaintenanceProbe(version: 1, unavailable: "Owned unavailable proof"), now: start)
    let observed = coordinator.revision
    #expect(coordinator.freshnessDeadline == start.addingTimeInterval(300))
    #expect(coordinator.hostOverviews(now: start).first?.livePanes.first?.observationState == "unavailable")
    while await sleeper.pending() == 0 { await Task.yield() }
    #expect(await sleeper.requested == [300])
    #expect(coordinator.revision == observed) // nothing until the boundary

    now = start.addingTimeInterval(300)
    await sleeper.releaseOne()
    while coordinator.revision == observed { await Task.yield() }
    #expect(coordinator.revision == observed &+ 1)
    #expect(coordinator.hostOverviews(now: now).first?.livePanes.first?.observationState == "stale")
    // Nothing left to expire: no further wake is armed.
    #expect(coordinator.freshnessDeadline == nil)
    for _ in 0..<20 { await Task.yield() }
    #expect(await sleeper.pending() == 0)
    #expect(coordinator.revision == observed &+ 1)
}
