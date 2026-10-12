import Foundation
import Testing
@testable import Relay

private func endpoint(_ n: Int) -> PeerGroupPlan.Endpoint {
    .init(kind: .native, host: n % 2 == 0 ? "dandy-07" : "laptop", session: "session-\(n)",
          name: "peer-\(n)", pid: n, processStart: "123")
}

@Test func autonomousGroupRequiresTaskAndPreservesLegacyMode() throws {
    var plan = PeerGroupPlan(id: UUID(), participants: [endpoint(2), endpoint(4)], topology: .everyone, coordinatorID: nil, purpose: " ", autonomous: true)
    #expect(plan.validationError != nil)
    plan.autonomous = false
    #expect(plan.validationError == nil)
    plan.autonomous = nil
    let restored = try JSONDecoder().decode(PeerGroupPlan.self, from: JSONEncoder().encode(plan))
    #expect(restored.autonomous == nil)
    #expect(restored.workingAgreement.contains("Communication only"))
    let active = PeerGroupPlan(id: UUID(), participants: plan.participants, topology: .everyone, coordinatorID: nil, purpose: "Review tests", autonomous: true)
    #expect(active.validationError == nil)
    #expect(active.workingAgreement.contains("Existing permissions remain unchanged"))
}

@Test func nativeSameHostGroupTransport() {
    let plan = PeerGroupPlan(id: UUID(), participants: [endpoint(2), endpoint(4)], topology: .everyone, coordinatorID: nil, purpose: "")
    #expect(plan.transportError == nil)
    // A local/remote native pair now has an explicit SSH tunnel transport.
    #expect(PeerGroupPlan(id: UUID(), participants: [endpoint(1), endpoint(2)], topology: .everyone, coordinatorID: nil, purpose: "").transportError == nil)
}

@Test("Cross-host native pair uses the explicit direct tunnel transport")
func crossHostNativePairTransport() {
    let local = PeerGroupPlan.Endpoint(kind: .native, host: "laptop", session: "local-session",
        name: "claude-local", pid: 31, processStart: "local-start")
    let remote = PeerGroupPlan.Endpoint(kind: .native, host: "dandy-07", session: "remote-session",
        name: "claude-remote", pid: 42, processStart: "remote-start")
    let pair = PeerGroupPlan(id: UUID(), participants: [local, remote], topology: .everyone,
        coordinatorID: nil, purpose: "", autonomous: false)
    #expect(pair.crossHostNativePair?.local == local)
    #expect(pair.crossHostNativePair?.remote == remote)
    #expect(pair.transportError == nil)
    var autonomous = pair
    autonomous.autonomous = true
    autonomous = PeerGroupPlan(id: autonomous.id, participants: autonomous.participants,
        topology: autonomous.topology, coordinatorID: autonomous.coordinatorID,
        purpose: "Review", autonomous: true)
    #expect(autonomous.transportError != nil)
    #expect(PeerGroupPlan(id: UUID(), participants: [local, remote, endpoint(6)], topology: .everyone,
        coordinatorID: nil, purpose: "").transportError != nil)
}

@Test("Group plans create a bounded clique or coordinator star without duplicate edges")
func groupEdgePlans() {
    let members = (1...4).map(endpoint)
    let clique = PeerGroupPlan(id: UUID(), participants: members, topology: .everyone, coordinatorID: nil, purpose: "Review")
    #expect(clique.validationError == nil)
    #expect(clique.edges.count == 6)
    #expect(Set(clique.edges.map(\.id)).count == 6)
    let star = PeerGroupPlan(id: UUID(), participants: members, topology: .coordinator,
                             coordinatorID: members[2].id, purpose: "Review")
    #expect(star.edges.count == 3)
    #expect(star.edges.allSatisfy { $0.source == members[2] })
}

@Test("Introductions never advertise membership as a verified route")
func groupIntroductionEvidence() {
    let a = endpoint(1), b = endpoint(2), c = endpoint(3)
    let plan = PeerGroupPlan(id: UUID(), participants: [a,b,c], topology: .coordinator,
                            coordinatorID: a.id, purpose: "Review")
    let message = plan.introduction(for: b, reachable: [a.id: "route-a", c.id: "route-c"])
    #expect(message.contains("route-a"))
    #expect(!message.contains("route-c"))
    #expect(message.contains("not permission"))
    #expect(plan.introduction(for: b, reachable: [:]).contains("None confirmed"))
}

@Test("Group validation rejects duplicates, excessive membership and missing coordinator")
func groupValidation() {
    for members in [[endpoint(1)], [endpoint(1), endpoint(1)], (1...9).map(endpoint)] {
        #expect(PeerGroupPlan(id: UUID(), participants: members, topology: .everyone,
            coordinatorID: nil, purpose: "").validationError != nil)
    }
    #expect(PeerGroupPlan(id: UUID(), participants: [endpoint(1), endpoint(2)], topology: .coordinator,
        coordinatorID: "missing", purpose: "").validationError != nil)
}

@Test func localDesktopGroupTransport() {
    let members = ["a", "b", "c"].map {
        PeerGroupPlan.Endpoint(kind: .desktop, host: "laptop", session: $0, name: $0, pid: nil, processStart: nil)
    }
    for topology in [PeerGroupPlan.Topology.everyone, .coordinator] {
        let plan = PeerGroupPlan(id: UUID(), participants: members, topology: topology,
            coordinatorID: members[0].id, purpose: "Review")
        #expect(plan.transportError == nil)
    }
}
