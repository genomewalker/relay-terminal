import Foundation
import Testing
@testable import Relay

@Suite("Native draft safety")
struct RelayNativeDraftTests {
    @Test func onlyDefiniteSendClearsUnchangedDraft() {
        let draft = RelayNativeDraft(text: "Important work", images: ["image"])
        for outcome in [RelayNativeActionOutcome.refused, .rejected, .uncertain] {
            #expect(!draft.shouldClear(current: draft, outcome: outcome))
        }
        #expect(draft.shouldClear(current: draft, outcome: .sent))
        #expect(!draft.shouldClear(current: .init(text: "Edited", images: draft.images), outcome: .sent))
        #expect(!draft.shouldClear(current: .init(text: draft.text, images: []), outcome: .sent))
        #expect(RelayNativeActionOutcome.receipt("rejected") == .rejected)
        #expect(RelayNativeActionOutcome.receipt("unknown") == .uncertain)
        #expect(RelayNativeActionOutcome.receipt("sent") == .sent)
    }

    @Test @MainActor func guardRefusalDoesNotDispatch() async {
        let identity = RelayNativeIdentity(pane: "pane", instance: "instance", provider: "claude")
        let binding = RelayNativeBinding(identity: identity, profile: .local,
            account: .init(provider: "claude", label: "fixture", dir: ""))
        let model = RelayNativeConversation(binding: binding)
        #expect(await model.act(kind: "send", text: "Keep this") == .refused)
        #expect(model.uncertainAction == nil)
    }
}
