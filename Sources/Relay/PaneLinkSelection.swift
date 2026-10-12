import SwiftUI

/// Workspace-scoped selection for choosing communication endpoints.
@MainActor
final class PaneLinkSelection: ObservableObject {
    @Published var active = false
    @Published private(set) var paneIDs: Set<UUID> = []
    @Published var reviewing = false
    @Published var acrossApp = false
    @Published private(set) var pairMode = false
    @Published private(set) var connecting = false
    @Published private(set) var pairFailure: String?
    @Published private(set) var resultMessage: String?
    @Published private(set) var orderedPair: [UUID] = []
    @Published private(set) var resultPaneIDs: [UUID] = []
    @Published private(set) var memberships: [PaneLinkMembership] = []
    @Published var refreshingLinks = false
    @Published var linkManagementError: String?
    @Published var removingLinkIDs: Set<String> = []
    private(set) var membershipRevision: UInt64 = 0
    var connectPair: (([UUID], UUID) -> Void)?
    var refreshLinks: (() -> Void)?
    var removeLink: ((String) -> Void)?
    var describePane: ((UUID) -> String)?

    func label(for id: UUID) -> String {
        describePane?(id) ?? String(id.uuidString.prefix(8))
    }
    func memberships(for id: UUID) -> [PaneLinkMembership] {
        memberships.filter { $0.paneIDs.contains(id) }
    }
    func recordMembership(_ link: PaneLinkMembership) {
        membershipRevision &+= 1
        memberships.removeAll { $0.id == link.id }
        memberships.append(link)
    }
    func forgetMembership(_ id: String) {
        membershipRevision &+= 1
        memberships.removeAll { $0.id == id }
    }
    func replaceMemberships(_ links: [PaneLinkMembership], ifRevision revision: UInt64) {
        guard revision == membershipRevision else { return }
        membershipRevision &+= 1
        memberships = links
    }
    func retryPair() {
        guard active, pairMode, !connecting, pairFailure != nil, orderedPair.count == 2 else { return }
        generation = UUID()
        pairFailure = nil
        connecting = true
        connectPair?(orderedPair, generation)
    }
    func chooseAnotherTarget() {
        guard pairMode, !connecting, let source = orderedPair.first else { return }
        generation = UUID()
        pairFailure = nil
        orderedPair = [source]
        paneIDs = [source]
    }
    private var generation = UUID()
    private(set) var startingPaneIDs: Set<UUID> = []
    private(set) var startingTabID: UUID?
    func begin(tabID: UUID?, paneIDs: Set<UUID>) {
        generation = UUID()
        orderedPair = []
        resultPaneIDs = []
        pairMode = false
        connecting = false
        pairFailure = nil
        resultMessage = nil
        self.paneIDs.removeAll()
        startingPaneIDs = paneIDs
        startingTabID = tabID
        acrossApp = false
        active = true
    }
    func cancel() {
        generation = UUID()
        active = false; paneIDs.removeAll(); reviewing = false; acrossApp = false
        startingPaneIDs.removeAll(); startingTabID = nil
        pairMode = false; connecting = false; pairFailure = nil
        resultMessage = nil
        orderedPair = []
        resultPaneIDs = []
    }
    /// A pane-header choice is independent of its current tab or session.
    /// Only the second distinct choice asks the workspace to create a link.
    func selectPairPane(_ id: UUID) {
        guard !connecting else { return }
        if !active || !pairMode || pairFailure != nil {
            begin(tabID: nil, paneIDs: [id])
            pairMode = true
            acrossApp = true
            paneIDs = [id]
            orderedPair = [id]
            return
        }
        if paneIDs.contains(id) { cancel(); return }
        guard paneIDs.count == 1, let first = paneIDs.first else { return }
        paneIDs.insert(id)
        orderedPair = [first, id]
        connecting = true
        connectPair?([first, id], generation)
    }
    func finishPair(_ ids: [UUID], generation request: UUID, failure: String?) {
        guard request == generation, pairMode else { return }
        connecting = false
        if let failure { pairFailure = failure }
        else { cancel(); resultPaneIDs = ids; resultMessage = "Panes linked" }
    }
    func setAcrossApp(_ enabled: Bool) {
        acrossApp = enabled
        if !enabled { paneIDs.formIntersection(startingPaneIDs) }
    }
    func canSelect(_ id: UUID) -> Bool { acrossApp || startingPaneIDs.contains(id) }
    func toggle(_ id: UUID) {
        guard active, canSelect(id) else { return }
        if paneIDs.contains(id) { paneIDs.remove(id) }
        else if paneIDs.count < 8 { paneIDs.insert(id) }
    }
}


struct PaneLinkMembership: Identifiable, Equatable {
    let id: String
    let paneIDs: [UUID]
    let unavailable: Bool

    init(id: String, paneIDs: [UUID], unavailable: Bool) {
        self.id = id; self.paneIDs = paneIDs; self.unavailable = unavailable
    }
    init?(record: [String: Any]) {
        guard let id = record["id"] as? String,
              let members = record["members"] as? [[String: Any]], members.count == 2 else { return nil }
        let ids = members.compactMap { ($0["paneID"] as? String).flatMap(UUID.init(uuidString:)) }
        guard ids.count == 2, Set(ids).count == 2 else { return nil }
        self.id = id
        paneIDs = ids
        unavailable = record["transport"] as? String == "unavailable"
            || record["state"] as? String == "pane_unavailable"
            || !(record["resolutionErrors"] as? [String: String] ?? [:]).isEmpty
    }
}
