import Foundation
import Testing
@testable import Relay

/// The automatic pane-link janitor retires only confirmed-obsolete local links.
@MainActor
private final class JanitorFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("relay-link-janitor-" + UUID().uuidString)
    var linksDirectory: URL { root.appendingPathComponent("links") }
    var workspaceDirectory: URL { root.appendingPathComponent("workspace") }
    var recoveryDirectory: URL { root.appendingPathComponent("recovery") }
    /// A real closed-pane archive, used as the template for ghost archives.
    private var archiveTemplate: [String: Any] = [:]
    let workspace: WorkspaceModel
    let messaging: RelayPaneMessaging
    let store: RelayClaudeRotationActionStore
    var panes: [PaneModel] = []

    init(paneCount: Int = 2) async throws {
        for directory in [root, root.appendingPathComponent("links"), root.appendingPathComponent("workspace"),
                          root.appendingPathComponent("recovery")] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        workspace = WorkspaceModel(restoreSavedWorkspace: false, workspaceDirectory: root.appendingPathComponent("workspace"),
            recoveryStore: RelayRecoveryStore(directory: root.appendingPathComponent("recovery")))
        messaging = RelayPaneMessaging(linksDirectory: root.appendingPathComponent("links"))
        store = RelayClaudeRotationActionStore(directory: root.appendingPathComponent("links"))
        // Close one real pane so the template is exactly what Relay archives.
        workspace.newTab(profile: .sshConfigHost("janitor-template.invalid"))
        let template = try #require(workspace.activePane).id
        workspace.closeActivePane()
        let archived = try #require(try FileManager.default.contentsOfDirectory(at: recoveryDirectory,
            includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix("closed-") })
        archiveTemplate = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: archived)) as? [String: Any])
        try #require((archiveTemplate["pane"] as? [String: Any])?["id"] as? String == template.uuidString)
        workspace.paneLinkJanitor = messaging
        for index in 0..<paneCount {
            workspace.newTab(profile: .sshConfigHost("janitor-\(index).invalid"))
            panes.append(try #require(workspace.activePane))
        }
        messaging.nativeRequestOverride = { pane, _ in
            let n = abs(pane.id.hashValue % 100_000) + 10
            return ["endpoint": ["pid": n, "start": "start-\(n)", "provider": "claude", "sessionID": "session-\(n)",
                "rootPID": n + 1, "rootStart": "root-\(n)", "socketPath": "/tmp/janitor-\(n).sock",
                "socketIdentity": "id-\(n)", "socketPID": n, "socketStart": "start-\(n)", "transport": "unix"]]
        }
        try await settle()
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    /// Save, then wait until the workspace is authoritative for the janitor.
    func settle() async throws {
        workspace.persistWorkspace()
        let deadline = Date().addingTimeInterval(5)
        while workspace.paneLinkJanitorKnownPaneIDs.map({ Set(workspace.panes.keys).isSubset(of: $0) }) != true {
            try #require(Date() < deadline, "workspace did not become authoritative")
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Writes a closed-pane archive for `id`, as `rememberClosedPane` does.
    func archive(_ id: UUID) throws {
        var entry = archiveTemplate, pane = try #require(entry["pane"] as? [String: Any])
        pane["id"] = id.uuidString
        entry["pane"] = pane
        let entryID = UUID()
        entry["id"] = entryID.uuidString
        let data = try JSONSerialization.data(withJSONObject: entry)
        _ = try JSONDecoder().decode(ClosedPaneRecovery.self, from: data)
        try data.write(to: recoveryDirectory.appendingPathComponent("closed-\(entryID.uuidString.lowercased()).json"))
    }

    /// The archive files that hold `paneID`.
    func recoveryArchives(of paneID: UUID) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: recoveryDirectory, includingPropertiesForKeys: nil)) ?? [])
            .filter { url in
                guard url.lastPathComponent.hasPrefix("closed-"), let data = try? Data(contentsOf: url),
                      let entry = try? JSONDecoder().decode(ClosedPaneRecovery.self, from: data) else { return false }
                return entry.pane.id == paneID
            }
    }

    /// A pane that was closed: held nowhere, with an archive.
    func ghost() throws -> UUID {
        let id = UUID()
        try archive(id)
        return id
    }

    func member(_ id: UUID, host: UUID? = nil) -> RelayPaneMessaging.Link.Member {
        let pane = workspace.panes[id]
        return .init(paneID: id, hostID: host ?? pane?.profile.id ?? UUID(), name: "pane", provider: "claude",
                     pid: 0, start: "")
    }

    /// Save a link as `connect` would, or with an explicit (older-generation) ID.
    @discardableResult
    func save(_ a: UUID, _ b: UUID, id: String? = nil, hostA: UUID? = nil) throws -> String {
        let members = [member(a, host: hostA), member(b)].sorted { $0.paneID.uuidString < $1.paneID.uuidString }
        let linkID = id ?? RelayPaneMessaging.canonicalLinkID(members)
        let link = RelayPaneMessaging.Link(id: linkID, members: members, transport: "relay_native_socket")
        try store.replacePaneLink(intent: linkID, result: JSONEncoder().encode(link))
        return linkID
    }

    func active() -> Set<String> {
        Set((try? store.records(limit: 64))?.compactMap { record in
            record.result.flatMap { try? JSONDecoder().decode(RelayPaneMessaging.Link.self, from: $0) }?.id
        } ?? [])
    }

    /// Every file in the link directory, with contents.
    func listing() -> [String: Data] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: linksDirectory.path)) ?? []
        return Dictionary(uniqueKeysWithValues: names.compactMap { name in
            (try? Data(contentsOf: linksDirectory.appendingPathComponent(name))).map { (name, $0) }
        })
    }
}

private func hex(_ c: Character) -> String { String(repeating: c, count: 64) }

@MainActor
@Suite(.serialized) struct RelayPaneLinkJanitorTests {
    /// Panes still in the workspace (offline, reconnecting, lazy) and panes
    /// another Relay instance holds are never treated as deleted.
    @Test func offlineAndOtherInstancePanesKeepTheirLinks() async throws {
        let f = try await JanitorFixture(paneCount: 2)
        let (a, b) = (f.panes[0].id, f.panes[1].id)
        #expect(f.panes.allSatisfy { $0.connectionState != .connected }, "fixture panes are not connected")
        let present = try f.save(a, b)

        // Another Relay instance on the same profile commits its own pane.
        let other = WorkspaceModel(restoreSavedWorkspace: true, workspaceDirectory: f.workspaceDirectory,
            recoveryStore: RelayRecoveryStore(directory: f.recoveryDirectory))
        other.newTab(profile: .sshConfigHost("janitor-other.invalid"))
        let foreign = try #require(other.activePane).id
        other.persistWorkspace()
        let deadline = Date().addingTimeInterval(5)
        while f.workspace.paneLinkJanitorKnownPaneIDs?.contains(foreign) != true {
            try #require(Date() < deadline, "other instance's pane did not reach the shared snapshot: other=\(other.workspacePersistenceIssue ?? "nil") this=\(f.workspace.workspacePersistenceIssue ?? "nil")")
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(f.workspace.panes[foreign] == nil, "not in this window")
        let shared = try f.save(a, foreign)

        #expect(f.messaging.retireObsoleteLinks(workspace: f.workspace, reason: "test").isEmpty)
        #expect(f.active() == [present, shared])
        other.shutdown()
    }

    /// (a) A link to a pane held nowhere is retired, and admission then succeeds.
    @Test func deletedPaneLinkIsRetiredAndAdmissionSucceeds() async throws {
        let f = try await JanitorFixture(paneCount: 2)
        let (a, b) = (f.panes[0].id, f.panes[1].id)
        // 63 links to gone panes stay protected by in-flight messages; one does not.
        for index in 0..<63 {
            let ghost = try f.ghost()
            try f.save(a, ghost)
            try f.messaging.beginDeliveryForTesting(UUID(), pair: [a, ghost])
            _ = index
        }
        let deleted = try f.save(a, try f.ghost())
        #expect(f.active().count == 64)
        let link = try await f.messaging.connect(panes: [a, b], workspace: f.workspace)
        #expect(!f.active().contains(deleted), "the deleted-pane link was retired at admission")
        #expect(f.active().contains(link.id))
        #expect(f.active().count == 64)
    }

    /// (b) An older generation of a pair whose current link exists is retired;
    /// without a current link, or with different hosts, it is kept.
    @Test func olderGenerationDuplicateIsRetiredOnlyBesideItsCurrentLink() async throws {
        let f = try await JanitorFixture(paneCount: 3)
        let (a, b, c) = (f.panes[0].id, f.panes[1].id, f.panes[2].id)
        let current = try f.save(a, b)
        let old = try f.save(a, b, id: hex("e"))
        // Different host: its own canonical ID has no current link, so kept.
        let otherHost = try f.save(a, b, id: hex("d"), hostA: UUID())
        let orphan = try f.save(a, c, id: hex("c"))     // no current (a, c) link
        // A mis-keyed record: its ID is the canonical ID of (a@hostX, b) but it
        // holds (a@hostA, b). It is itself an older generation of `current`.
        // It is not proof that the (a@hostX, b) generation is superseded: the
        // member-host check keeps that one.
        let hostX = UUID()
        let misKeyed = try f.save(a, b, id: RelayPaneMessaging.canonicalLinkID([f.member(a, host: hostX), f.member(b)]))
        let staleX = try f.save(a, b, id: hex("b"), hostA: hostX)
        let retired = f.messaging.retireObsoleteLinks(workspace: f.workspace, reason: "test")
        #expect(Set(retired) == [old, misKeyed])
        #expect(f.active() == [current, otherHost, orphan, staleX])
    }

    /// A message in flight between the pair blocks eviction until it settles.
    @Test func inFlightMessageBlocksEviction() async throws {
        let f = try await JanitorFixture(paneCount: 1)
        let a = f.panes[0].id, ghost = try f.ghost()
        let link = try f.save(a, ghost)
        let message = UUID()
        try f.messaging.beginDeliveryForTesting(message, pair: [a, ghost])
        #expect(f.messaging.retireObsoleteLinks(workspace: f.workspace, reason: "test").isEmpty)
        #expect(f.active().contains(link))
        f.messaging.endDeliveryForTesting(message)
        #expect(f.messaging.retireObsoleteLinks(workspace: f.workspace, reason: "test") == [link])
    }

    /// When the workspace cannot be stated authoritatively (here: another
    /// instance has unsaved pending changes), nothing is evicted and the
    /// capacity refusal stands.
    @Test func unverifiedWorkspaceEvictsNothingAndTheLimitStands() async throws {
        let f = try await JanitorFixture(paneCount: 2)
        let (a, b) = (f.panes[0].id, f.panes[1].id)
        var ghosts: Set<String> = []
        for _ in 0..<64 { ghosts.insert(try f.save(a, try f.ghost())) }
        try Data("{}".utf8).write(to: f.workspaceDirectory.appendingPathComponent("pending-other-instance.json"))
        #expect(f.workspace.paneLinkJanitorKnownPaneIDs == nil)
        #expect(f.messaging.retireObsoleteLinks(workspace: f.workspace, reason: "test").isEmpty)
        await #expect(throws: (any Error).self) {
            _ = try await f.messaging.connect(panes: [a, b], workspace: f.workspace)
        }
        #expect(f.active() == ghosts, "no eviction, no new link")
    }

    /// The janitor only retires: no link is created or edited, and each
    /// retired record is kept byte-for-byte as history.
    @Test func janitorOnlyRetiresAndKeepsHistory() async throws {
        let f = try await JanitorFixture(paneCount: 2)
        let (a, b) = (f.panes[0].id, f.panes[1].id)
        try f.save(a, b)
        let gone = try f.save(a, try f.ghost())
        let before = f.listing()
        #expect(f.messaging.retireObsoleteLinks(workspace: f.workspace, reason: "test") == [gone])
        let after = f.listing()
        let activeBefore = before.filter { !$0.key.hasPrefix(".") }
        let activeAfter = after.filter { !$0.key.hasPrefix(".") }
        #expect(Set(activeAfter.keys).isSubset(of: Set(activeBefore.keys)), "no link created")
        #expect(activeAfter.allSatisfy { before[$0.key] == $0.value }, "no remaining link edited")
        let removed = Set(activeBefore.keys).subtracting(activeAfter.keys)
        #expect(removed.count == 1)
        for name in removed {
            #expect(after.contains { $0.key.hasPrefix(".previous-") && $0.key.hasSuffix(name) && $0.value == before[name] },
                "retired record kept as history")
        }
    }

    /// Lifecycle: closing a pane retires its links after the shared commit.
    /// Reopening it later restores the pane, not the link (stated tradeoff).
    @Test func closingAPaneRetiresItsLinksAfterTheSave() async throws {
        let f = try await JanitorFixture(paneCount: 3)
        let (a, b, c) = (f.panes[0].id, f.panes[1].id, f.panes[2].id)
        let kept = try f.save(a, b)
        let closing = try f.save(a, c)
        #expect(f.workspace.activePane?.id == c)
        f.workspace.closeActivePane()
        let deadline = Date().addingTimeInterval(5)
        while f.active().contains(closing) {
            try #require(Date() < deadline, "closed pane's link was not retired after the save")
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(f.active() == [kept])
    }

    /// (a) needs positive evidence of closure: a missing pane with no archive
    /// (for instance one another instance created and has not committed yet)
    /// keeps its link; once it is archived, the link is retired.
    @Test func missingPaneWithoutArchiveKeepsItsLink() async throws {
        let f = try await JanitorFixture(paneCount: 1)
        let a = f.panes[0].id, unseen = UUID()
        let link = try f.save(a, unseen)
        #expect(f.messaging.retireObsoleteLinks(workspace: f.workspace, reason: "test").isEmpty)
        #expect(f.active() == [link])
        try f.archive(unseen)
        #expect(f.messaging.retireObsoleteLinks(workspace: f.workspace, reason: "test") == [link])
    }

    /// Another instance's pane P was closed (archived, committed without P).
    /// Returns the instance, the snapshots with and without P, and the link.
    private func closedForeignPane(_ f: JanitorFixture) async throws
        -> (other: WorkspaceModel, withP: WorkspaceSnapshot, withoutP: WorkspaceSnapshot, p: UUID, link: String) {
        let reader = RelaySharedWorkspaceStore(directory: f.workspaceDirectory)
        let other = WorkspaceModel(restoreSavedWorkspace: true, workspaceDirectory: f.workspaceDirectory,
            recoveryStore: RelayRecoveryStore(directory: f.recoveryDirectory))
        other.newTab(profile: .sshConfigHost("janitor-other.invalid"))
        let p = try #require(other.activePane).id
        other.persistWorkspace()
        var deadline = Date().addingTimeInterval(5)
        while f.workspace.paneLinkJanitorKnownPaneIDs?.contains(p) != true {
            try #require(Date() < deadline, "P did not reach the shared snapshot")
            try await Task.sleep(for: .milliseconds(20))
        }
        let withP = try #require(try reader.restore(legacy: nil))
        let link = try f.save(f.panes[0].id, p)
        other.closeActivePane()
        deadline = Date().addingTimeInterval(5)
        while f.workspace.withPaneLinkJanitorFence({ !$0.known.contains(p) && $0.closed.contains(p) }) != true {
            try #require(Date() < deadline, "P's close did not reach the shared snapshot and archive")
            try await Task.sleep(for: .milliseconds(20))
        }
        let withoutP = try #require(try reader.restore(legacy: nil))
        #expect(!withoutP.panes.contains { $0.id == p })
        return (other, withP, withoutP, p, link)
    }

    /// Fence: the other instance reopens P (archive removed, P committed
    /// again) exactly between this janitor's decision and its retire. The
    /// commit must not land inside the sweep; it lands after, and then the
    /// stated closed-pane tradeoff applies (P is back, its link is not).
    @Test func otherInstanceCommitBetweenDecisionAndRetireIsFenced() async throws {
        let f = try await JanitorFixture(paneCount: 1)
        let (other, withP, withoutP, p, link) = try await closedForeignPane(f)
        let reopener = RelaySharedWorkspaceStore(directory: f.workspaceDirectory)
        var committedInWindow = false, refusedInWindow = false
        f.messaging.janitorWindowForTesting = {
            for archive in f.recoveryArchives(of: p) { try? FileManager.default.removeItem(at: archive) }
            do { _ = try reopener.commit(withP, baseline: withoutP); committedInWindow = true }
            catch RelaySharedWorkspaceError.busy { refusedInWindow = true }
            catch { Issue.record("unexpected commit error \(error)") }
        }
        let retired = f.messaging.retireObsoleteLinks(workspace: f.workspace, reason: "test")
        f.messaging.janitorWindowForTesting = nil
        #expect(!(committedInWindow && retired.contains(link)),
            "a link was retired after its pane was committed again inside the sweep")
        #expect(refusedInWindow && !committedInWindow, "the shared-workspace lock fences the sweep")
        #expect(retired == [link])
        // The other instance's save retries after the sweep and succeeds.
        let merged = try reopener.commit(withP, baseline: withoutP)
        #expect(merged.panes.contains { $0.id == p })
        other.shutdown()
    }

    /// Fence: the other instance preserves pending changes (its recovery path
    /// when a save cannot complete) between decision and retire. The
    /// preserve must not land inside the sweep.
    @Test func otherInstancePendingRecoveryBetweenDecisionAndRetireIsFenced() async throws {
        let f = try await JanitorFixture(paneCount: 1)
        let (other, withP, _, p, link) = try await closedForeignPane(f)
        let recovering = RelaySharedWorkspaceStore(directory: f.workspaceDirectory)
        var preservedInWindow = false, refusedInWindow = false
        f.messaging.janitorWindowForTesting = {
            for archive in f.recoveryArchives(of: p) { try? FileManager.default.removeItem(at: archive) }
            do { try recovering.preservePending(withP); preservedInWindow = true }
            catch RelaySharedWorkspaceError.busy { refusedInWindow = true }
            catch { Issue.record("unexpected preserve error \(error)") }
        }
        let retired = f.messaging.retireObsoleteLinks(workspace: f.workspace, reason: "test")
        f.messaging.janitorWindowForTesting = nil
        #expect(!(preservedInWindow && retired.contains(link)),
            "a link was retired after pending changes holding its pane were preserved inside the sweep")
        #expect(refusedInWindow && !preservedInWindow, "the shared-workspace lock fences the sweep")
        // After the sweep the preserve lands, and from then on the gate holds.
        try recovering.preservePending(withP)
        #expect(f.workspace.paneLinkJanitorKnownPaneIDs == nil)
        other.shutdown()
    }

    /// A delivery in flight in another instance (another messaging object on
    /// the same profile store) blocks eviction through its shared marker.
    /// Markers of dead processes or past the age bound do not protect.
    @Test func otherInstanceInFlightMarkerBlocksEviction() async throws {
        let f = try await JanitorFixture(paneCount: 1)
        let a = f.panes[0].id
        let (g1, g2, g3) = (try f.ghost(), try f.ghost(), try f.ghost())
        let (busy, dead, expired) = (try f.save(a, g1), try f.save(a, g2), try f.save(a, g3))
        let otherInstance = RelayPaneMessaging(linksDirectory: f.linksDirectory)
        let message = UUID()
        try otherInstance.beginDeliveryForTesting(message, pair: [a, g1])
        let markers = InFlightMarkers(directory: f.linksDirectory.appendingPathComponent("InFlight"))
        let exited = Process()
        exited.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try exited.run()
        exited.waitUntilExit()
        try markers.mark(UUID(), pair: [a, g2], pid: exited.processIdentifier)
        try markers.mark(UUID(), pair: [a, g3], created: Date().addingTimeInterval(-2 * InFlightMarkers.maximumAge))
        #expect(Set(f.messaging.retireObsoleteLinks(workspace: f.workspace, reason: "test")) == [dead, expired])
        #expect(f.active() == [busy])
        otherInstance.endDeliveryForTesting(message)
        #expect(f.messaging.retireObsoleteLinks(workspace: f.workspace, reason: "test") == [busy])
        let left = try FileManager.default.contentsOfDirectory(atPath: markers.directory.path).filter { $0.hasSuffix(".json") }
        #expect(left.isEmpty, "settled, dead and expired markers are gone: \(left)")
    }

    // MARK: r3

    /// Any marker-named file that cannot be proven live or dead skips the
    /// whole sweep: nothing is retired while it is there.
    @Test func unverifiableMarkersSkipTheSweep() async throws {
        let f = try await JanitorFixture(paneCount: 1)
        let a = f.panes[0].id
        let link = try f.save(a, try f.ghost())
        let markers = f.linksDirectory.appendingPathComponent("InFlight")
        try FileManager.default.createDirectory(at: markers, withIntermediateDirectories: true)
        func marker(_ pair: [UUID], pid: Int32 = getpid()) throws -> Data {
            try JSONEncoder().encode(InFlightMarkers.Marker(pair: pair, pid: pid, created: Date()))
        }
        let padded = String(repeating: " ", count: InFlightMarkers.maximumMarkerBytes)
        let cases: [(String, String, Data, mode_t)] = [
            ("malformed", "\(UUID()).\(UUID()).json", Data("not a marker".utf8), 0o600),
            ("unreadable", "\(UUID()).\(UUID()).json", try marker([a, UUID()]), 0o000),
            ("oversize", "\(UUID()).\(UUID()).json", try marker([a, UUID()]) + Data(padded.utf8), 0o600),
            ("one pane", "\(UUID()).\(UUID()).json", try marker([a]), 0o600),
            ("three panes", "\(UUID()).\(UUID()).json", try marker([a, UUID(), UUID()]), 0o600),
            ("same pane twice", "\(UUID()).\(UUID()).json", try marker([a, a]), 0o600),
            ("bad pid", "\(UUID()).\(UUID()).json", try marker([a, UUID()], pid: 0), 0o600),
            ("bad name", "not-a-message.json", try marker([a, UUID()]), 0o600),
        ]
        for (label, name, data, mode) in cases {
            let file = markers.appendingPathComponent(name)
            try data.write(to: file)
            #expect(chmod(file.path, mode) == 0)
            #expect(f.messaging.retireObsoleteLinks(workspace: f.workspace, reason: "test").isEmpty, "\(label): sweep skipped")
            #expect(f.active() == [link], "\(label): nothing retired")
            #expect(FileManager.default.fileExists(atPath: file.path), "\(label): the janitor does not remove it")
            chmod(file.path, 0o600)
            try FileManager.default.removeItem(at: file)
        }
        #expect(f.messaging.retireObsoleteLinks(workspace: f.workspace, reason: "test") == [link])
    }

    /// The janitor never waits for the marker lock: while another holder
    /// has it, the sweep is skipped. A writer waits at most `writerWait`.
    @Test func heldMarkerLockSkipsTheSweepAndBoundsWriters() async throws {
        let f = try await JanitorFixture(paneCount: 1)
        let a = f.panes[0].id
        let link = try f.save(a, try f.ghost())
        let markers = InFlightMarkers(directory: f.linksDirectory.appendingPathComponent("InFlight"))
        try FileManager.default.createDirectory(at: markers.directory, withIntermediateDirectories: true)
        let fd = open(markers.directory.appendingPathComponent(".lock").path, O_RDWR | O_CREAT, 0o600)
        try #require(fd >= 0)
        try #require(flock(fd, LOCK_EX | LOCK_NB) == 0)
        let clock = ContinuousClock()
        let swept = clock.measure {
            #expect(f.messaging.retireObsoleteLinks(workspace: f.workspace, reason: "test").isEmpty)
        }
        #expect(swept < .milliseconds(50), "the sweep did not wait: \(swept)")
        #expect(f.active() == [link])
        var refused = false
        let wrote = clock.measure {
            do { try markers.mark(UUID(), pair: [a, UUID()]) } catch InFlightMarkers.Failure.busy { refused = true } catch {}
        }
        #expect(refused, "a writer gives up when the lock stays held")
        #expect(wrote < .seconds(1), "a writer's wait is bounded: \(wrote)")
        flock(fd, LOCK_UN); close(fd)
        #expect(f.messaging.retireObsoleteLinks(workspace: f.workspace, reason: "test") == [link])
    }

    /// A send whose marker cannot be written is refused before any side
    /// effect, so no other instance's janitor can see an unmarked delivery.
    @Test func sendIsRefusedWhenItsMarkerCannotBeWritten() async throws {
        let f = try await JanitorFixture(paneCount: 2)
        let (a, b) = (f.panes[0].id, f.panes[1].id)
        // A file where the marker directory must be: no marker can be written.
        try Data().write(to: f.linksDirectory.appendingPathComponent("InFlight"))
        var endpointLookups = 0
        let original = f.messaging.nativeRequestOverride
        f.messaging.nativeRequestOverride = { pane, packet in endpointLookups += 1; return try await original!(pane, packet) }
        let message = UUID()
        await #expect(throws: (any Error).self) {
            _ = try await f.messaging.send(.init(sourcePaneID: a, messageID: message, text: "hello"), targetID: b,
                                           workspace: f.workspace, submittingClientID: "janitor-test")
        }
        #expect(endpointLookups == 0, "nothing was attempted")
        #expect(f.messaging.activeDeliveryCountForTesting == 0, "no delivery is left marked in this instance")
        #expect(throws: (any Error).self) { try f.messaging.beginDeliveryForTesting(UUID(), pair: [a, b]) }
        #expect(f.messaging.activeDeliveryCountForTesting == 0)
    }

    /// Quit and window close run `saveForClose` first. While another
    /// instance's janitor holds the workspace lock, it reports "not safely
    /// saved" (so quit is cancelled, not lost); after the sweep it succeeds.
    @Test func quitSaveDuringSweepIsRefusedThenSucceeds() async throws {
        let f = try await JanitorFixture(paneCount: 1)
        let (other, _, _, _, link) = try await closedForeignPane(f)
        other.newTab(profile: .sshConfigHost("janitor-unsaved.invalid"))
        let unsaved = try #require(other.activePane).id
        var savedInWindow: Bool?
        f.messaging.janitorWindowForTesting = { savedInWindow = other.saveForClose() }
        #expect(f.messaging.retireObsoleteLinks(workspace: f.workspace, reason: "test") == [link])
        f.messaging.janitorWindowForTesting = nil
        #expect(savedInWindow == false, "quit is refused while the sweep holds the lock")
        #expect(other.workspacePersistenceIssue != nil)
        #expect(other.saveForClose(), "quit succeeds once the sweep is done")
        let committed = try #require(try RelaySharedWorkspaceStore(directory: f.workspaceDirectory).restore(legacy: nil))
        #expect(committed.panes.contains { $0.id == unsaved }, "the change made before quit was saved")
        other.shutdown()
    }

    /// Measurement, not a pass/fail bound: wall time of a sweep, which is
    /// also the longest the workspace lock is held, with as many archives as
    /// the live profile has. Set RELAY_JANITOR_MEASURE_RECOVERY to a recovery
    /// directory to also time a read-only decode of those archives.
    @Test func measureSweepWithLiveArchiveCount() async throws {
        let f = try await JanitorFixture(paneCount: 2)
        let (a, b) = (f.panes[0].id, f.panes[1].id)
        let archives = Int(ProcessInfo.processInfo.environment["RELAY_JANITOR_MEASURE_ARCHIVES"] ?? "") ?? 258
        for _ in 0..<archives { try f.archive(UUID()) }
        try f.save(a, b)
        for _ in 0..<8 { try f.save(a, try f.ghost()) }
        let clock = ContinuousClock()
        var first = Duration.zero, later: [Duration] = []
        first = clock.measure { #expect(f.messaging.retireObsoleteLinks(workspace: f.workspace, reason: "test").count == 8) }
        for _ in 0..<5 { later.append(clock.measure { _ = f.messaging.retireObsoleteLinks(workspace: f.workspace, reason: "test") }) }
        let bytes = try FileManager.default.contentsOfDirectory(at: f.recoveryDirectory, includingPropertiesForKeys: [.fileSizeKey])
            .compactMap { try $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }
        print("JANITOR-MEASURE archives=\(bytes.count) bytes=\(bytes.reduce(0, +)) sweep_retiring_8=\(first) "
            + "sweeps_noop=\(later.map(\.description).joined(separator: ","))")
        if let live = ProcessInfo.processInfo.environment["RELAY_JANITOR_MEASURE_RECOVERY"] {
            let store = RelayRecoveryStore(directory: URL(fileURLWithPath: live))
            var count = 0
            let decode = (0..<5).map { _ in clock.measure { count = store.loadClosedPanes().count } }
            print("JANITOR-MEASURE live_archives_decoded=\(count) decode=\(decode.map(\.description).joined(separator: ","))")
        }
    }

    // MARK: r4

    /// Two instances send the same message ID: an idempotent retry over the
    /// same pair, and a conflicting pair. Each attempt holds its own marker,
    /// so B's completion never removes A's protection.
    @Test func sameMessageIDInAnotherInstanceCannotRemoveProtection() async throws {
        let f = try await JanitorFixture(paneCount: 1)
        let a = f.panes[0].id
        let (g1, g2) = (try f.ghost(), try f.ghost())
        let (first, second) = (try f.save(a, g1), try f.save(a, g2))
        let instanceA = RelayPaneMessaging(linksDirectory: f.linksDirectory)
        let instanceB = RelayPaneMessaging(linksDirectory: f.linksDirectory)
        let message = UUID()
        try instanceA.beginDeliveryForTesting(message, pair: [a, g1])     // A is in flight

        // B retries the same message over the same pair, then completes.
        try instanceB.beginDeliveryForTesting(message, pair: [a, g1])
        instanceB.endDeliveryForTesting(message)
        #expect(f.messaging.retireObsoleteLinks(workspace: f.workspace, reason: "test") == [second],
            "after B's same-pair retry completes, A's pair is still protected")
        #expect(f.active() == [first])

        // B sends the same message ID over a different pair, then completes.
        let g3 = try f.ghost()
        let third = try f.save(a, g3)
        try instanceB.beginDeliveryForTesting(message, pair: [a, g3])
        #expect(f.messaging.retireObsoleteLinks(workspace: f.workspace, reason: "test").isEmpty,
            "both attempts' pairs are protected while both are in flight")
        instanceB.endDeliveryForTesting(message)
        #expect(f.messaging.retireObsoleteLinks(workspace: f.workspace, reason: "test") == [third],
            "B's conflicting-pair attempt clears only its own marker")
        #expect(f.active() == [first], "A's pair is still protected")

        instanceA.endDeliveryForTesting(message)
        #expect(f.messaging.retireObsoleteLinks(workspace: f.workspace, reason: "test") == [first])
        let left = try FileManager.default.contentsOfDirectory(
            atPath: f.linksDirectory.appendingPathComponent("InFlight").path).filter { $0.hasSuffix(".json") }
        #expect(left.isEmpty, "each attempt removed exactly its own marker: \(left)")
    }
}
