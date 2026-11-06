import Foundation
import Testing
@testable import Relay

// bc08 brief 3c9e7b1f: each submit is classified from counts only. A long
// prompt submitted by Tab+Enter must not read as typed, and automation must
// never be credited as typing.
@Suite struct RelayPromptProvenanceTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func typed(_ text: String, into log: inout RelayPromptProvenanceLog) {
        log.printable(RelayPromptProvenanceLog.printableCount(text), origin: .hardware)
    }

    @Test func tabEnterOnALongPromptIsSuggestionLikely() {
        var log = RelayPromptProvenanceLog()
        log.tab(origin: .hardware)
        let record = log.userSubmit(visible: nil, origin: .hardware, at: t0)
        #expect(record?.inputClass == .suggestionLikely)
        log.providerPrompt(RelayPromptFingerprint(String(repeating: "x", count: 400)), promptSource: "suggestion", at: t0 + 1)
        let latest = log.latest
        #expect(latest?.inputClass == .suggestionLikely)
        #expect(latest?.intent == "weak")
        #expect(latest?.suggestionAccepted == true)
        #expect(latest?.submittedLength == 400)
        #expect(latest?.lengthSource == "provider")
        #expect(latest?.promptSource == "suggestion")
        #expect(latest?.counts == RelayPromptInputCounts(tab: 1, enter: 1))
    }

    @Test func enterAloneIsNeverTyped() {
        var log = RelayPromptProvenanceLog()
        #expect(log.userSubmit(visible: nil, origin: .hardware, at: t0)?.inputClass == .suggestionLikely)
        log.rightArrow(origin: .hardware)
        #expect(log.userSubmit(visible: nil, origin: .hardware, at: t0)?.inputClass == .suggestionLikely)
        #expect(log.latest?.intent == "weak")
    }

    @Test func typedTextIsTypedAndStrong() {
        var log = RelayPromptProvenanceLog()
        let text = "yes, install 96137c3b on dandy"
        typed(text, into: &log)
        let record = log.userSubmit(visible: RelayPromptFingerprint(text), origin: .hardware, at: t0)
        #expect(record?.inputClass == .typed)
        #expect(record?.intent == "strong")
        #expect(record?.suggestionAccepted == false)
        #expect(record?.lengthSource == "visible_input")
        // The provider agrees on the length: still typed.
        log.providerPrompt(RelayPromptFingerprint(text), promptSource: nil, at: t0 + 2)
        #expect(log.latest?.inputClass == .typed)
        #expect(log.latest?.intent == "strong")
        #expect(log.latest?.lengthSource == "provider")
    }

    @Test func fewTypedCharactersBehindALongProviderPromptAreNotTyped() {
        var log = RelayPromptProvenanceLog()
        typed("ok", into: &log)
        _ = log.userSubmit(visible: nil, origin: .hardware, at: t0)
        #expect(log.latest?.inputClass == .typed)
        log.providerPrompt(RelayPromptFingerprint(String(repeating: "y", count: 200)), promptSource: nil, at: t0 + 1)
        #expect(log.latest?.inputClass == .suggestionLikely)
        #expect(log.latest?.intent == "weak")
    }

    @Test func pasteIsPastedAndWeak() {
        var log = RelayPromptProvenanceLog()
        log.paste(bytes: 300, event: 10, origin: .hardware)
        typed("ok", into: &log)
        let record = log.userSubmit(visible: nil, origin: .hardware, at: t0)
        #expect(record?.inputClass == .pasted)
        #expect(record?.intent == "weak")
        log.providerPrompt(RelayPromptFingerprint(String(repeating: "p", count: 302)), promptSource: nil, at: t0 + 1)
        #expect(log.latest?.inputClass == .pasted)
        #expect(log.latest?.counts.pasteBytes == 300)
    }

    @Test func oneCommandVIsCountedOnceAcrossKeyAndMenuPaths() {
        var log = RelayPromptProvenanceLog()
        log.paste(bytes: 40, event: 99.5, origin: .hardware)
        log.paste(bytes: 40, event: 99.5, origin: .hardware)
        #expect(log.pending.pasteBytes == 40)
        log.paste(bytes: 40, event: 100.25, origin: .hardware)
        #expect(log.pending.pasteBytes == 80)
    }

    @Test func sendCommandIsProgrammaticAndNeverTyped() {
        var log = RelayPromptProvenanceLog()
        log.beginProgrammatic()
        // Anything the view sees while automation writes is not counted.
        typed("relay_send_command text", into: &log)
        log.paste(bytes: 50, event: 1, origin: .hardware)
        log.tab(origin: .hardware)
        #expect(log.userSubmit(visible: RelayPromptFingerprint("relay_send_command text"), origin: .hardware, at: t0) == nil)
        log.programmaticSubmit(source: "relay_prompt", fingerprint: RelayPromptFingerprint("relay_send_command text"), at: t0)
        log.endProgrammatic()
        #expect(log.history.count == 1)
        #expect(log.latest?.inputClass == .programmatic)
        #expect(log.latest?.intent == "weak")
        #expect(log.latest?.programmaticSource == "relay_prompt")
        #expect(log.latest?.counts == RelayPromptInputCounts())
        // The provider's report of that prompt never upgrades it.
        log.providerPrompt(RelayPromptFingerprint("relay_send_command text"), promptSource: "typed", at: t0 + 1)
        #expect(log.latest?.inputClass == .programmatic)
        #expect(log.history.count == 1)
    }

    @Test func peerMessageReportedBeforeTheRouteReturnsStaysOneProgrammaticRecord() throws {
        var log = RelayPromptProvenanceLog()
        let id = "4f8b2d6a-3c19-4e75-a0d2-9b7e1c5f3a64"
        typed("draft", into: &log)
        _ = log.userSubmit(visible: RelayPromptFingerprint("draft"), origin: .hardware, at: t0)
        // relayd wrote the message; Claude's hook arrives while the route waits.
        // No pause: the two are joined by message ID, not by timing.
        log.providerPrompt(RelayPromptFingerprint(String(repeating: "m", count: 90)), peerMessageID: id,
                           promptSource: nil, at: t0 + 5)
        log.programmaticSubmit(source: "pane_message", fingerprint: RelayPromptFingerprint(String(repeating: "m", count: 90)),
                               messageID: id, consumesInputLine: false, at: t0 + 6)
        try #require(log.history.count == 2)
        // The earlier typed submit did not borrow the message's length.
        #expect(log.history[0].inputClass == .typed)
        #expect(log.history[0].lengthSource == "visible_input")
        #expect(log.history[1].inputClass == .programmatic)
        #expect(log.history[1].programmaticSource == "pane_message")
    }

    @Test func programmaticSubmitClearsEarlierKeystrokes() {
        var log = RelayPromptProvenanceLog()
        typed("half typed", into: &log)
        log.programmaticSubmit(source: "terminal_edit", fingerprint: nil, at: t0)
        // The next bare Enter cannot claim the keystrokes the automation consumed.
        #expect(log.userSubmit(visible: nil, origin: .hardware, at: t0 + 1)?.inputClass == .suggestionLikely)
    }

    @Test func editedSuggestionIsTypedButWeak() {
        var log = RelayPromptProvenanceLog()
        log.tab(origin: .hardware)
        typed(" and add tests", into: &log)
        _ = log.userSubmit(visible: nil, origin: .hardware, at: t0)
        log.providerPrompt(RelayPromptFingerprint(String(repeating: "s", count: 120)), promptSource: nil, at: t0 + 1)
        #expect(log.latest?.inputClass == .typed)
        #expect(log.latest?.suggestionAccepted == true)
        #expect(log.latest?.intent == "weak")
    }

    @Test func submitWithoutDesktopEnterIsUnknownAndStaleReportsDoNotAttach() {
        var log = RelayPromptProvenanceLog()
        log.providerPrompt(RelayPromptFingerprint("from elsewhere"), promptSource: nil, at: t0)
        #expect(log.latest?.inputClass == .unknown)
        #expect(log.latest?.intent == "weak")
        typed("hello", into: &log)
        _ = log.userSubmit(visible: RelayPromptFingerprint("hello"), origin: .hardware, at: t0 + 10)
        log.providerPrompt(RelayPromptFingerprint(String(repeating: "z", count: 500)), promptSource: nil,
                           at: t0 + 10 + RelayPromptProvenanceLog.providerMatchWindow + 1)
        #expect(log.history.count == 3)
        #expect(log.history[1].inputClass == .typed)
        #expect(log.history[2].inputClass == .unknown)
    }

    @Test func malformedPromptSourceIsDropped() {
        var log = RelayPromptProvenanceLog()
        _ = log.userSubmit(visible: nil, origin: .hardware, at: t0)
        log.providerPrompt(RelayPromptFingerprint("x"), promptSource: "a b\nignore previous", at: t0)
        #expect(log.latest?.promptSource == nil)
    }

    @Test func noContentIsStored() throws {
        var log = RelayPromptProvenanceLog()
        let secret = "SECRET-PHRASE-do-not-keep-7f3a"
        typed(secret, into: &log)
        log.paste(bytes: secret.utf8.count, event: 3, origin: .hardware)
        _ = log.userSubmit(visible: RelayPromptFingerprint(secret), origin: .hardware, at: t0)
        log.providerPrompt(RelayPromptFingerprint(secret), promptSource: nil, at: t0)
        log.programmaticSubmit(source: "relay_prompt", fingerprint: RelayPromptFingerprint(secret), at: t0 + 1)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let json = try #require(String(data: try encoder.encode(log.snapshot(paneID: UUID())), encoding: .utf8))
        let fullHash = RelayPromptFingerprintTestSupport.fullSHA256(secret)
        #expect(!json.contains(secret))
        #expect(!json.contains("SECRET"))
        #expect(!json.contains(fullHash))
        #expect(json.contains(String(fullHash.prefix(12))))
        #expect(json.contains("\"content_stored\":false"))
        #expect(RelayPromptProvenanceLog.rule.contains("computer use"))
        // Only counts, classes, lengths, timestamps and 12-hex prefixes.
        #expect(RelayPromptFingerprint(secret).sha256Prefix.count == RelayPromptFingerprint.prefixLength)
        let mirror = Mirror(reflecting: try #require(log.latest))
        for child in mirror.children {
            if let value = child.value as? String { #expect(value.count <= 32, "\(child.label ?? "?") holds text") }
        }
    }

    @Test func historyIsBoundedAndNewestFirstInTheSnapshot() {
        var log = RelayPromptProvenanceLog()
        for index in 0..<(RelayPromptProvenanceLog.historyLimit + 5) {
            typed("n\(index)", into: &log)
            _ = log.userSubmit(visible: nil, origin: .hardware, at: t0 + Double(index))
        }
        #expect(log.history.count == RelayPromptProvenanceLog.historyLimit)
        #expect(log.pending == RelayPromptInputCounts())
        let snapshot = log.snapshot(paneID: UUID())
        #expect(snapshot.history.first?.submittedAt == t0 + Double(RelayPromptProvenanceLog.historyLimit + 4))
        #expect(snapshot.latest == log.history.last)
    }

    @Test func controlCharactersAreKeysNotText() {
        #expect(RelayPromptProvenanceLog.printableCount("\t\r\n\u{1b}[C\u{7f}") == 2)  // "[" and "C"
        #expect(RelayPromptProvenanceLog.printableCount("héllo") == 5)
    }

    @Test func paneMessageReceiptsThatRuleOutDeliveryAreNotRecorded() {
        #expect(!RelayPromptProvenanceLog.messageMayHaveReachedPane(["delivered": false]))
        #expect(!RelayPromptProvenanceLog.messageMayHaveReachedPane(["status": "rejected_unverified_source"]))
        #expect(RelayPromptProvenanceLog.messageMayHaveReachedPane(["status": "outcome_unknown"]))
        #expect(RelayPromptProvenanceLog.messageMayHaveReachedPane(["status": "delivered", "delivered": true]))
    }
}

enum RelayPromptFingerprintTestSupport {
    static func fullSHA256(_ text: String) -> String {
        RelayPromptFingerprint.hexDigest(text)
    }
}

// bc08 finding 1: a peer message relayd writes to a pane's native inbox (not
// the desktop /message route) is programmatic, matched by message ID between
// relayd's content-free delivery notice and Claude's UserPromptSubmit report.
@Suite struct RelayPromptProvenanceDaemonDeliveryTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let id = "4f8b2d6a-3c19-4e75-a0d2-9b7e1c5f3a64"
    private var report: RelayPromptFingerprint { RelayPromptFingerprint(length: 900, sha256Prefix: "0123456789ab")! }

    @Test func noticeThenProviderReportIsOneProgrammaticRecordTheReportCannotUpgrade() throws {
        var log = RelayPromptProvenanceLog()
        log.daemonDelivery(messageID: id.uppercased(), at: t0)
        log.providerPrompt(report, peerMessageID: id, promptSource: "typed", at: t0 + 2)
        #expect(log.history.count == 1)
        let record = log.latest
        #expect(record?.inputClass == .programmatic)
        #expect(record?.intent == "weak")
        #expect(record?.programmaticSource == RelayPromptProvenanceLog.daemonSource)
        #expect(record?.peerMessageID == id)
        #expect(record?.submittedLength == 900)
        #expect(record?.lengthSource == "provider")
        // A second report for the same message changes nothing.
        log.providerPrompt(report, peerMessageID: id, promptSource: nil, at: t0 + 3)
        try #require(log.history.count == 2)
        #expect(log.history[0].inputClass == .programmatic)
    }

    @Test func providerReportFirstIsUnknownUntilTheNoticeNamesIt() {
        var log = RelayPromptProvenanceLog()
        log.providerPrompt(report, peerMessageID: id, promptSource: nil, at: t0)
        #expect(log.latest?.inputClass == .unknown)
        log.daemonDelivery(messageID: id, at: t0 + 1)
        #expect(log.history.count == 1)
        #expect(log.latest?.inputClass == .programmatic)
        #expect(log.latest?.programmaticSource == RelayPromptProvenanceLog.daemonSource)
        // A repeated notice does not add a record.
        log.daemonDelivery(messageID: id, at: t0 + 2)
        #expect(log.history.count == 1)
    }

    @Test func unmatchedPeerReportStaysUnknownAndNeverJoinsADesktopSubmit() throws {
        var log = RelayPromptProvenanceLog()
        let typed = "yes, commit it"
        log.printable(typed.count, origin: .hardware)
        _ = log.userSubmit(visible: RelayPromptFingerprint(typed), origin: .hardware, at: t0)
        log.providerPrompt(report, peerMessageID: id, promptSource: nil, at: t0 + 1)
        try #require(log.history.count == 2)
        #expect(log.history[0].inputClass == .typed)
        #expect(log.history[0].intent == "strong")
        #expect(log.history[0].lengthSource == "visible_input")
        #expect(log.history[1].inputClass == .unknown)
        #expect(log.history[1].intent == "weak")
    }

    @Test func aNoticeNeverTouchesADesktopSubmitAndMalformedIDsAreIgnored() {
        var log = RelayPromptProvenanceLog()
        log.printable(10, origin: .hardware)
        _ = log.userSubmit(visible: nil, origin: .hardware, at: t0)
        for bad in ["", "not-an-id", "../" + id, id + "0", "4f8b2d6a"] {
            log.daemonDelivery(messageID: bad, at: t0 + 1)
            log.providerPrompt(report, peerMessageID: bad, promptSource: nil, at: t0 + 100)
        }
        #expect(log.history.first?.inputClass == .typed)
        #expect(!log.history.contains { $0.inputClass == .programmatic })
        // A notice for another message is its own programmatic record.
        log.daemonDelivery(messageID: id, at: t0 + 200)
        #expect(log.history.first?.inputClass == .typed)
        #expect(log.latest?.inputClass == .programmatic)
    }

    @Test func aDeliveryLeavesKeysTypedMeanwhileCounted() {
        var log = RelayPromptProvenanceLog()
        let draft = "half a reply"
        log.printable(draft.count, origin: .hardware)
        log.daemonDelivery(messageID: id, at: t0)
        log.providerPrompt(report, peerMessageID: id, promptSource: nil, at: t0 + 1)
        #expect(log.pending.printable == draft.count)
        let record = log.userSubmit(visible: RelayPromptFingerprint(draft), origin: .hardware, at: t0 + 5)
        #expect(record?.inputClass == .typed)
        #expect(record?.intent == "strong")
    }

    @Test func aReportWithoutAPeerIDDoesNotJoinADaemonRecord() throws {
        var log = RelayPromptProvenanceLog()
        log.daemonDelivery(messageID: id, at: t0)
        log.providerPrompt(report, promptSource: nil, at: t0 + 1)
        try #require(log.history.count == 2)
        #expect(log.history[0].providerReportedAt == nil)
        #expect(log.history[1].inputClass == .unknown)
    }

    @Test func desktopRouteAndRelaydNoticeForOneMessageAreOneRecord() {
        var log = RelayPromptProvenanceLog()
        log.programmaticSubmit(source: "pane_message", fingerprint: RelayPromptFingerprint("body"), messageID: id, at: t0)
        log.daemonDelivery(messageID: id, at: t0 + 1)
        #expect(log.history.count == 1)
        #expect(log.latest?.programmaticSource == "pane_message")
        var reversed = RelayPromptProvenanceLog()
        reversed.daemonDelivery(messageID: id, at: t0)
        reversed.programmaticSubmit(source: "pane_message", fingerprint: nil, messageID: id, at: t0 + 1)
        #expect(reversed.history.count == 1)
        #expect(reversed.latest?.inputClass == .programmatic)
    }

    @MainActor @Test func hookFieldsBecomeAFingerprintOnlyWhenWellFormed() {
        let good = PaneModel.providerPromptFingerprint(["prompt_length": 900, "prompt_sha256_prefix": "0123456789ab"])
        #expect(good == RelayPromptFingerprint(length: 900, sha256Prefix: "0123456789ab"))
        #expect(PaneModel.providerPromptFingerprint(["prompt_length": 900, "prompt_sha256_prefix": "0123456789AB"]) == nil)
        #expect(PaneModel.providerPromptFingerprint(["prompt_length": -1, "prompt_sha256_prefix": "0123456789ab"]) == nil)
        #expect(PaneModel.providerPromptFingerprint(["prompt_length": 9, "prompt_sha256_prefix": "0123"]) == nil)
        #expect(PaneModel.providerPromptFingerprint([:]) == nil)
        #expect(PaneModel.providerPromptFingerprint(["prompt": "abc"]) == RelayPromptFingerprint("abc"))
    }
}

// bc08 findings 2 and 3: the awaited pane-message send no longer pauses
// desktop counting, and Right-arrow is cursor movement, not an accept.
@Suite struct RelayPromptProvenanceFindings23Tests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let id = "4f8b2d6a-3c19-4e75-a0d2-9b7e1c5f3a64"

    @Test func keysTypedDuringAPaneMessageSendStillCount() {
        var log = RelayPromptProvenanceLog()
        let reply = "approve only after I type it"
        // The route awaits relayd; the user keeps typing in the target pane.
        log.printable(reply.count, origin: .hardware)
        log.programmaticSubmit(source: "pane_message", fingerprint: RelayPromptFingerprint("peer body"), messageID: id,
                               consumesInputLine: false, at: t0)
        #expect(log.pending.printable == reply.count)
        #expect(log.latest?.inputClass == .programmatic)
        #expect(log.latest?.counts == RelayPromptInputCounts())
        let record = log.userSubmit(visible: RelayPromptFingerprint(reply), origin: .hardware, at: t0 + 3)
        #expect(record?.inputClass == .typed)
        #expect(record?.intent == "strong")
        #expect(record?.counts.printable == reply.count)
    }

    @Test func aWriteIntoTheInputLineStillConsumesAndPausesCounting() {
        // Negative: automation that types into the line keeps both behaviours.
        var log = RelayPromptProvenanceLog()
        log.printable(4, origin: .hardware)
        log.beginProgrammatic()
        log.printable(30, origin: .hardware)
        log.programmaticSubmit(source: "relay_prompt", fingerprint: nil, at: t0)
        log.endProgrammatic()
        #expect(log.latest?.counts.printable == 4)
        #expect(log.pending == RelayPromptInputCounts())
        #expect(log.userSubmit(visible: nil, origin: .hardware, at: t0 + 1)?.inputClass == .suggestionLikely)
    }

    @Test func rightArrowWhileTypingStaysTypedAndStrong() {
        var log = RelayPromptProvenanceLog()
        let text = "commit dd4da14e"
        log.printable(10, origin: .hardware)
        log.rightArrow(origin: .hardware); log.rightArrow(origin: .hardware); log.rightArrow(origin: .hardware)
        log.printable(text.count - 10, origin: .hardware)
        let record = log.userSubmit(visible: RelayPromptFingerprint(text), origin: .hardware, at: t0)
        #expect(record?.inputClass == .typed)
        #expect(record?.intent == "strong")
        #expect(record?.suggestionAccepted == false)
        #expect(record?.counts.rightArrow == 3)
        log.providerPrompt(RelayPromptFingerprint(text), promptSource: nil, at: t0 + 1)
        #expect(log.latest?.intent == "strong")
    }

    @Test func rightArrowAcceptOfALongSuggestionIsStillSuggestionLikely() {
        var log = RelayPromptProvenanceLog()
        log.rightArrow(origin: .hardware)
        _ = log.userSubmit(visible: nil, origin: .hardware, at: t0)
        log.providerPrompt(RelayPromptFingerprint(String(repeating: "s", count: 400)), promptSource: nil, at: t0 + 1)
        #expect(log.latest?.inputClass == .suggestionLikely)
        #expect(log.latest?.intent == "weak")
        // A few typed characters on a Right-arrow accept: still not typed.
        var edited = RelayPromptProvenanceLog()
        edited.rightArrow(origin: .hardware)
        edited.printable(5, origin: .hardware)
        _ = edited.userSubmit(visible: nil, origin: .hardware, at: t0)
        edited.providerPrompt(RelayPromptFingerprint(String(repeating: "s", count: 200)), promptSource: nil, at: t0 + 1)
        #expect(edited.latest?.inputClass == .suggestionLikely)
        #expect(edited.latest?.intent == "weak")
    }

    @Test func tabIsStillAnAccept() {
        var log = RelayPromptProvenanceLog()
        log.tab(origin: .hardware)
        log.printable(12, origin: .hardware)
        let record = log.userSubmit(visible: RelayPromptFingerprint("twelve chars"), origin: .hardware, at: t0)
        #expect(record?.inputClass == .typed)
        #expect(record?.suggestionAccepted == true)
        #expect(record?.intent == "weak")
        #expect(RelayPromptInputCounts(tab: 1).acceptedSuggestion)
        #expect(!RelayPromptInputCounts(rightArrow: 5).acceptedSuggestion)
    }
}
