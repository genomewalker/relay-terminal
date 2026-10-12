import Foundation
import Testing
@testable import Relay

private func recoveryEvidence(verified: Bool = true, authorized: Bool = true,
                              conflict: Bool = false, at: Date = Date(), id: String = "route") -> DesktopRouteRecoveryEvidence {
    .init(routeID: id, identityVerified: verified, reconnectAuthorized: authorized,
          identityConflict: conflict, observedAt: at)
}

@Test func recoveryFallbackResumesApprovedListener() {
    #expect(DesktopRouteRecoveryPolicy.action(for: recoveryEvidence()) == .resumeListener)
}

@Test func recoveryModelCannotExpandAuthority() {
    for evidence in [recoveryEvidence(verified: false), recoveryEvidence(authorized: false),
                     recoveryEvidence(conflict: true)] {
        #expect(DesktopRouteRecoveryPolicy.action(for: evidence, proposed: .resumeListener) == .wait)
    }
}

@Test func recoveryRejectsStaleAndFutureEvidence() {
    let now = Date()
    for offset in [-26.0, 6.0] {
        #expect(DesktopRouteRecoveryPolicy.action(for: recoveryEvidence(at: now.addingTimeInterval(offset)),
                                                  proposed: .resumeListener, now: now) == .wait)
    }
}

@Test func recoveryRechecksEvidenceAfterModelReturns() {
    let evidence = recoveryEvidence()
    let plan = DesktopRouteRecoveryPlan(evidence: evidence, action: .resumeListener, usedAppleModel: true)
    #expect(DesktopRouteRecoveryPolicy.permits(plan, current: evidence))
    #expect(!DesktopRouteRecoveryPolicy.permits(plan, current: recoveryEvidence(id: "changed")))
    #expect(!DesktopRouteRecoveryPolicy.permits(plan, current: evidence,
                                               now: evidence.observedAt.addingTimeInterval(26)))
    let wait = DesktopRouteRecoveryPlan(evidence: evidence, action: .wait, usedAppleModel: true)
    #expect(!DesktopRouteRecoveryPolicy.permits(wait, current: evidence))
}
