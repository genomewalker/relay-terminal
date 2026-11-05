import Foundation
import Testing
@testable import Relay

@Test func questionNoticeIsHeldOnlyWhileAnyDraftSourceIsPresent() {
    func present(draft: String = "", attachments: Int = 0, submitting: Bool = false, held: Bool = false, confirmedEmpty: Bool = true) -> Bool {
        RelayQuestionNotices.draftPresent(composerDraft: draft, attachments: attachments, submitting: submitting,
                                          nativeDeliveryHeld: held, promptConfirmedEmpty: confirmedEmpty)
    }
    #expect(!present())
    #expect(present(draft: "half-typed"))
    #expect(present(attachments: 1))
    #expect(present(submitting: true))
    #expect(present(held: true))
    #expect(present(confirmedEmpty: false))
}

@Test func questionNoticeWithEmptyPromptIsDeliveredAndATypedDraftHoldsItUntilItClears() {
    #expect(RelayQuestionNotices.action(draftPresent: false) == .deliver)
    // A typed draft holds the notice; the next tick sees it cleared and delivers.
    #expect(RelayQuestionNotices.action(draftPresent: true) == .holdDraft)
    #expect(RelayQuestionNotices.action(draftPresent: false) == .deliver)
}

@Test func questionNoticePacketsCarryOnlyPaneAndMessageIdentity() throws {
    let pane = UUID()
    let pull = RelayQuestionNotices.pullPacket(paneIDs: [pane])
    #expect(pull["operation"] as? String == "question_notices")
    #expect(pull["panes"] as? [String] == [pane.uuidString.lowercased()])
    let send = RelayQuestionNotices.sendPacket(paneID: pane, messageID: "m-1")
    #expect(send["operation"] as? String == "question_notice_send")
    #expect(Set(send.keys) == ["operation", "pane_id", "message_id"])
    let held = RelayQuestionNotices.heldPacket(paneID: pane, messageID: "m-1")
    #expect(held["operation"] as? String == "question_notice_ack")
    #expect(held["outcome"] as? String == "held_draft")
    #expect(Set(held.keys) == ["operation", "pane_id", "message_id", "outcome"])
}
