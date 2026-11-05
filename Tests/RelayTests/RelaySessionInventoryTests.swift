import Foundation
import Testing
@testable import Relay

private func pane(_ id: UUID, state: String, worker: Int? = 100, shell: Int? = 101, retained: Bool? = nil) -> RemoteCatalogPane {
    RemoteCatalogPane(paneID: id.uuidString.lowercased(), workspaceID: nil, tabID: nil, parentPaneID: nil, title: "dandy-07",
                      contentKind: "terminal", command: nil, directory: "/tmp", state: state, workerPID: worker, shellPID: shell,
                      lastSequence: 0, recoverable: state == "running", unfiled: true, retained: retained)
}

@Test func sessionCategoriesFollowAttachmentThenState() {
    #expect(RelaySessionInventory.category(state: "running", attached: true) == .open)
    #expect(RelaySessionInventory.category(state: "exited", attached: true) == .open)
    #expect(RelaySessionInventory.category(state: "running", attached: false) == .detached)
    for state in ["exited", "stale", "missing"] {
        #expect(RelaySessionInventory.category(state: state, attached: false) == .dead)
    }
}

@Test func programsExcludeWorkerShellAndOtherPanes() {
    let id = UUID(), other = UUID()
    let processes: [[String: Any]] = [
        ["pid": 100, "pane_id": id.uuidString.lowercased(), "name": "/bin/relayd"],
        ["pid": 101, "pane_id": id.uuidString.lowercased(), "name": "/bin/bash"],
        ["pid": 102, "pane_id": id.uuidString.uppercased(), "name": "/usr/bin/claude"],
        ["pid": 103, "pane_id": id.uuidString.lowercased(), "name": "claude"],
        ["pid": 104, "pane_id": other.uuidString.lowercased(), "name": "codex"],
        ["pid": 105, "name": "htop"],
    ]
    #expect(RelaySessionInventory.programs(for: pane(id, state: "running"), processes: processes) == ["claude"])
}

@Test func cleanupTakesDeadAndOnlyKnownIdleShells() {
    let open = UUID(), busy = UUID(), idle = UUID(), unknown = UUID(), dead = UUID(), kept = UUID()
    let attached: Set<UUID> = [open]
    let processes: [[String: Any]] = [["pid": 200, "pane_id": busy.uuidString.lowercased(), "name": "codex"]]
    var rows = RelaySessionInventory.rows(host: "dandy-07",
        panes: [pane(open, state: "running"), pane(busy, state: "running"), pane(idle, state: "running"),
                pane(dead, state: "exited"), pane(kept, state: "missing", worker: nil, shell: nil, retained: true)],
        processes: processes) { attached.contains($0) }
    rows += RelaySessionInventory.rows(host: "other", panes: [pane(unknown, state: "running")], processes: nil) { _ in false }

    let ids = { (rows: [RelaySessionRow]) in Set(rows.map(\.paneID)) }
    #expect(ids(RelaySessionInventory.cleanupTargets(rows, includeIdleShells: false)) == [dead, kept])
    #expect(ids(RelaySessionInventory.cleanupTargets(rows, includeIdleShells: true)) == [dead, kept, idle])
    #expect(rows.first { $0.paneID == kept }?.retained == true)
    #expect(rows.first { $0.paneID == unknown }?.programs == nil)
}
