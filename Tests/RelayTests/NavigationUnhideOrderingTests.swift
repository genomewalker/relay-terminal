import Foundation
import Testing
@testable import Relay

/// Relay 0.5.169 was killed with EXC_GUARD (Relay-2026-11-24-120951.ips) when
/// select_pane switched the tab and unhid a hidden Relay in one main-thread
/// turn. A hidden Relay is unhidden first; the tab changes after the unhide.
@MainActor @Suite("Navigation unhides Relay before it changes the tab")
struct NavigationUnhideOrderingTests {
    /// A fake application that records what happens, in order. The unhide
    /// callback is held until the test delivers didUnhide.
    @MainActor final class FakeApplication {
        var hidden: Bool
        var events: [String] = []
        var pending: (@MainActor @Sendable () -> Void)?
        var postsDidUnhideInsideUnhide = false
        init(hidden: Bool) { self.hidden = hidden }

        var application: NavigationUnhideOrdering.Application {
            .init(
                isHidden: { self.hidden },
                unhide: {
                    self.events.append("unhide")
                    self.hidden = false
                    if self.postsDidUnhideInsideUnhide { self.deliverDidUnhide() }
                },
                afterUnhide: { then in
                    self.events.append("observe")
                    self.pending = then
                }
            )
        }

        func deliverDidUnhide() {
            events.append("didUnhide")
            let then = pending
            pending = nil
            then?()
        }
    }

    @Test func aVisibleRelayIsLeftToTheCaller() {
        let fake = FakeApplication(hidden: false)
        var revealed = 0
        let deferred = NavigationUnhideOrdering.deferIfHidden(fake.application) { revealed += 1 }
        #expect(!deferred)
        #expect(revealed == 0)
        #expect(fake.events.isEmpty)
    }

    @Test func aHiddenRelayIsUnhiddenBeforeTheReveal() {
        let fake = FakeApplication(hidden: true)
        let deferred = NavigationUnhideOrdering.deferIfHidden(fake.application) { fake.events.append("reveal") }
        #expect(deferred)
        // Nothing is revealed in the turn that unhides.
        #expect(fake.events == ["observe", "unhide"])
        fake.deliverDidUnhide()
        #expect(fake.events == ["observe", "unhide", "didUnhide", "reveal"])
    }

    @Test func didUnhidePostedDuringUnhideIsNotMissed() {
        let fake = FakeApplication(hidden: true)
        fake.postsDidUnhideInsideUnhide = true
        var revealed = 0
        _ = NavigationUnhideOrdering.deferIfHidden(fake.application) { revealed += 1 }
        #expect(revealed == 1)
        #expect(fake.events == ["observe", "unhide", "didUnhide"])
    }

    @Test func theRevealRunsOnceWhicheverTriggerComesFirst() {
        var runs = 0
        let once = NavigationUnhideOrdering.Once { runs += 1 }
        once.fire()  // didUnhide
        once.fire()  // the fallback timer
        #expect(runs == 1)
    }

    @Test func aHiddenRelayKeepsItsTabUntilTheUnhide() throws {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.shutdown() }
        workspace.newTab(profile: .sshConfigHost("unhide-order-test.invalid"))
        let target = try #require(workspace.activePane)
        let owner = try #require(workspace.selectedTabID)
        workspace.newTab(profile: .sshConfigHost("unhide-order-test.invalid"))
        let other = try #require(workspace.selectedTabID)
        #expect(other != owner)

        let fake = FakeApplication(hidden: true)
        let deferred = workspace.revealAfterUnhidingIfHidden(target, origin: .programmatic, application: fake.application)
        #expect(deferred)
        // The unhide happens with the old tab still selected.
        #expect(fake.events == ["observe", "unhide"])
        #expect(workspace.selectedTabID == other)

        fake.deliverDidUnhide()
        #expect(workspace.selectedTabID == owner)
        #expect(workspace.activePaneID == target.id)
    }

    @Test func aVisibleRelaySelectsAtOnceAsBefore() throws {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.shutdown() }
        workspace.newTab(profile: .sshConfigHost("unhide-order-test.invalid"))
        let target = try #require(workspace.activePane)
        let owner = try #require(workspace.selectedTabID)
        workspace.newTab(profile: .sshConfigHost("unhide-order-test.invalid"))

        let fake = FakeApplication(hidden: false)
        #expect(!workspace.revealAfterUnhidingIfHidden(target, origin: .programmatic, application: fake.application))
        let (tabID, paneID) = try workspace.selectWorkspacePane(target.id)
        #expect(tabID == owner && paneID == target.id)
        #expect(workspace.selectedTabID == owner)
        #expect(fake.events.isEmpty)
    }
}
