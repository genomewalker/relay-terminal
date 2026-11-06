import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import Relay

// Key events posted by another process (computer use, automation) are counted
// as synthesized_keys and never read as typed.
@Suite struct RelayKeyEventOriginTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func onlyAProcessIDOfZeroOrWindowServerWithoutUserDataIsHardware() {
        #expect(RelayKeyEventOrigin.classify(sourcePID: 0, userData: 0, windowServerPID: 409) == .hardware)
        #expect(RelayKeyEventOrigin.classify(sourcePID: 409, userData: 0, windowServerPID: 409) == .hardware)
        #expect(RelayKeyEventOrigin.classify(sourcePID: 0, userData: 0, windowServerPID: nil) == .hardware)
        // Negatives: any poster, tagged user data, or an unknown WindowServer.
        #expect(RelayKeyEventOrigin.classify(sourcePID: Int64(getpid()), userData: 0, windowServerPID: 409) == .synthesized)
        #expect(RelayKeyEventOrigin.classify(sourcePID: 4242, userData: 0, windowServerPID: 409) == .synthesized)
        #expect(RelayKeyEventOrigin.classify(sourcePID: 0, userData: 7, windowServerPID: 409) == .synthesized)
        #expect(RelayKeyEventOrigin.classify(sourcePID: 409, userData: 0, windowServerPID: nil) == .synthesized)
        #expect(RelayKeyEventOrigin.classify(sourcePID: 0, userData: 0, windowServerPID: 0) == .hardware)
        #expect(RelayKeyEventOrigin.classify(sourcePID: -1, userData: 0, windowServerPID: -1) == .synthesized)
    }

    @Test func eventsThisProcessCreatesAreSynthesizedWhateverTheirSourceState() throws {
        // A poster using the HID system state gets state ID 1, like the keyboard;
        // its process ID still gives it away.
        for state in [CGEventSourceStateID.hidSystemState, .combinedSessionState, .privateState] {
            let cg = try #require(CGEvent(keyboardEventSource: CGEventSource(stateID: state), virtualKey: 0, keyDown: true))
            #expect(RelayKeyEventOrigin.of(NSEvent(cgEvent: cg)) == .synthesized, "\(state.rawValue)")
        }
        let appKit = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                      context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)
        #expect(RelayKeyEventOrigin.of(appKit) == .synthesized)
        #expect(RelayKeyEventOrigin.of(nil) == .synthesized)
    }

    @Test func aForgedHardwareProcessIDIsTheStatedLimit() throws {
        // Documented limit, not a guarantee: a poster that overwrites the
        // source fields reads as hardware.
        let cg = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))
        cg.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
        #expect(RelayKeyEventOrigin.of(NSEvent(cgEvent: cg)) == .hardware)
        #expect(RelayPromptProvenanceLog.rule.contains("forges the hardware source fields"))
    }

    @Test func processLookupFindsByNameAndRefusesUnknownNames() {
        #expect(RelayKeyEventOrigin.findProcess(named: "launchd") == 1)
        #expect(RelayKeyEventOrigin.findProcess(named: "relay-no-such-process-7f3a") == nil)
    }

    @Test func synthesizedTypingWithAHardwareEnterIsProgrammatic() {
        var log = RelayPromptProvenanceLog()
        log.printable(40, origin: .synthesized)
        let record = log.userSubmit(visible: RelayPromptFingerprint(String(repeating: "c", count: 40)), origin: .hardware, at: t0)
        #expect(record?.inputClass == .programmatic)
        #expect(record?.intent == "weak")
        #expect(record?.programmaticSource == RelayPromptProvenanceLog.synthesizedSource)
        #expect(record?.counts.printable == 0)
        #expect(record?.counts.synthesized == 40)
        // The provider's report cannot upgrade it.
        log.providerPrompt(RelayPromptFingerprint(String(repeating: "c", count: 40)), promptSource: "typed", at: t0 + 1)
        #expect(log.latest?.inputClass == .programmatic)
    }

    @Test func aSynthesizedEnterIsProgrammaticEvenAfterRealTyping() {
        var log = RelayPromptProvenanceLog()
        let text = "yes, install it"
        log.printable(text.count, origin: .hardware)
        let record = log.userSubmit(visible: RelayPromptFingerprint(text), origin: .synthesized, at: t0)
        #expect(record?.inputClass == .programmatic)
        #expect(record?.counts.synthesizedEnter == 1)
        #expect(record?.counts.enter == 0)
    }

    @Test func aLittleSynthesizedInputMakesTypedInputWeak() {
        var log = RelayPromptProvenanceLog()
        log.printable(20, origin: .hardware)
        log.printable(3, origin: .synthesized)
        let record = log.userSubmit(visible: nil, origin: .hardware, at: t0)
        #expect(record?.inputClass == .typed)
        #expect(record?.intent == "weak")
        // It stays weak when the provider's length arrives.
        log.providerPrompt(RelayPromptFingerprint(String(repeating: "t", count: 23)), promptSource: nil, at: t0 + 1)
        #expect(log.latest?.inputClass == .typed)
        #expect(log.latest?.intent == "weak")
    }

    @Test func synthesizedPasteAndKeysNeverCountAsUserInput() {
        var log = RelayPromptProvenanceLog()
        log.paste(bytes: 300, event: 5, origin: .synthesized)
        log.tab(origin: .synthesized)
        log.rightArrow(origin: .synthesized)
        log.delete(origin: .synthesized)
        #expect(log.pending.pasteBytes == 0)
        #expect(log.pending.tab == 0)
        #expect(log.pending.rightArrow == 0)
        #expect(log.pending.delete == 0)
        #expect(log.pending.synthesized == 303)
        #expect(!log.pending.acceptedSuggestion)
        #expect(log.userSubmit(visible: nil, origin: .hardware, at: t0)?.inputClass == .programmatic)
    }

    @Test func hardwareTypingIsUnchanged() {
        var log = RelayPromptProvenanceLog()
        let text = "commit aaa64fdb"
        log.printable(text.count, origin: .hardware)
        let record = log.userSubmit(visible: RelayPromptFingerprint(text), origin: .hardware, at: t0)
        #expect(record?.inputClass == .typed)
        #expect(record?.intent == "strong")
        #expect(record?.counts.synthesized == 0)
        #expect(record?.programmaticSource == nil)
    }

    // insertText is keyboard input only while that key press is being dispatched.
    private func keyEvent(_ type: NSEvent.EventType = .keyDown, hardwareLooking: Bool = true) throws -> NSEvent {
        if type != .keyDown {
            return try #require(NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
                                                   windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        let cg = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))
        if hardwareLooking { cg.setIntegerValueField(.eventSourceUnixProcessID, value: 0) }
        return try #require(NSEvent(cgEvent: cg))
    }

    private func insertedTextOrigin(handling: NSEvent?, current: NSEvent?, replaying: Bool = false) -> RelayKeyEventOrigin {
        RelayKeyEventOrigin.keyPress(forInsertedText: handling, current: current, replaying: replaying)
            .map(RelayKeyEventOrigin.of) ?? .synthesized
    }

    @Test func insertTextWithNoKeyPressInProgressIsSynthesized() throws {
        #expect(insertedTextOrigin(handling: nil, current: nil) == .synthesized)
        #expect(insertedTextOrigin(handling: nil, current: try keyEvent(.leftMouseDown)) == .synthesized)
        #expect(insertedTextOrigin(handling: nil, current: nil, replaying: true) == .synthesized)
    }

    @Test func insertTextWhileAStaleRealKeyPressIsCurrentIsSynthesized() throws {
        // The stale key press reads as hardware on its own, but this view is
        // not dispatching it, so text arriving now is an accessibility or
        // programmatic insert.
        let stale = try keyEvent()
        #expect(RelayKeyEventOrigin.of(stale) == .hardware)
        #expect(insertedTextOrigin(handling: nil, current: stale) == .synthesized)
        // A different key press in flight does not vouch for the current one.
        #expect(insertedTextOrigin(handling: try keyEvent(), current: stale) == .synthesized)
        // A non-key event in flight vouches for nothing, even when current.
        let click = try keyEvent(.leftMouseDown)
        #expect(insertedTextOrigin(handling: click, current: click) == .synthesized)
        #expect(insertedTextOrigin(handling: click, current: click, replaying: true) == .synthesized)
    }

    @Test func insertTextDuringTheHandledKeyPressTakesThatKeyPressOrigin() throws {
        let real = try keyEvent()
        #expect(insertedTextOrigin(handling: real, current: real) == .hardware)
        // A posted key press being handled stays synthesized.
        let posted = try keyEvent(hardwareLooking: false)
        #expect(insertedTextOrigin(handling: posted, current: posted) == .synthesized)
        // A replayed deferred key press is judged by its own stored event.
        #expect(insertedTextOrigin(handling: real, current: nil, replaying: true) == .hardware)
        #expect(insertedTextOrigin(handling: posted, current: real, replaying: true) == .synthesized)
    }
}
