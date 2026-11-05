import AppKit
import Foundation
import Testing
@testable import Relay

// Regression for proposal 8b1a127d (2026-11-05): the link sheet took keyboard
// focus and a Return typed for a terminal pressed its default Deny 0.27 s after
// it appeared (performKeyEquivalent -> performClick), so the user's Allow never
// reached the app. The prompt is now a non-activating panel that never takes
// the keyboard; only a click on an armed button answers it.

@MainActor
private func prompt() -> RelayPaneLinkPrompt {
    let mac = ConnectionProfile(name: "This Mac", kind: .local, host: "", backend: .relay)
    let remote = ConnectionProfile(name: "dandy-07", kind: .ssh, host: "dandy-07", backend: .relay)
    return RelayPaneLinkPrompt(source: RelayPaneLinkPane(id: UUID(), displayName: "claude-A", profile: remote, instance: 1),
                               target: RelayPaneLinkPane(id: UUID(), displayName: "codex-B", profile: mac, instance: 2),
                               timeout: 120)
}

private func key(_ characters: String, code: UInt16, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                     characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
}

private func keyPresses() -> [NSEvent] { [key("\r", code: 36), key("\u{3}", code: 76), key("\u{1b}", code: 53), key(" ", code: 49),
                    key("\t", code: 48), key("\r", code: 36, .command), key("d", code: 2, .command)] }

@MainActor
private final class CapturingPresenter {
    var panel: RelayPaneLinkPanel?
    var calls = 0
    var shown = true
    lazy var present: RelayPaneLinkAlertConfirmer.Presenter = { [unowned self] panel in
        calls += 1
        self.panel = panel
        return shown
    }
}

@MainActor
private func waitUntil(_ seconds: TimeInterval = 2, _ condition: () -> Bool) async {
    let end = Date().addingTimeInterval(seconds)
    while !condition() && Date() < end { try? await Task.sleep(nanoseconds: 5_000_000) }
}

@MainActor
@Suite struct RelayPaneLinkAlertTests {
    @Test func panelNeverTakesTheKeyboardOrActivatesRelay() {
        let panel = RelayPaneLinkPanel(prompt: prompt())
        #expect(!panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(panel.level == .floating)
        #expect(!panel.hidesOnDeactivate)
        #expect(panel.defaultButtonCell == nil)
        #expect([panel.denyButton, panel.allowButton].map(\.title) == ["Deny", "Allow"])
        for event in keyPresses() {
            #expect(!panel.performKeyEquivalent(with: event), "the panel answered a key press")
        }
        let buttons = [panel.denyButton, panel.allowButton]
        for button in buttons {
            #expect(button.keyEquivalent == "")
            #expect(!button.acceptsFirstResponder)
            #expect(button.acceptsFirstMouse(for: nil))
            #expect(!button.isEnabled)
        }
        panel.arm()
        for button in buttons {
            #expect(button.isEnabled)
            for event in keyPresses() {
                #expect(!button.performKeyEquivalent(with: event), "\(button.title) answered a key press")
            }
        }
    }

    @Test func panelIsShownImmediatelyAndClicksBeforeTheDelayAreIgnored() async {
        let presenter = CapturingPresenter()
        let confirmer = RelayPaneLinkAlertConfirmer(present: presenter.present, armDelay: 0.3)
        let decision = Task { await confirmer.confirm(prompt(), timeout: 5) }
        await waitUntil(0.1) { presenter.calls == 1 }
        #expect(presenter.calls == 1, "the panel was not shown at once")
        let panel = try! #require(presenter.panel)
        #expect(!panel.denyButton.isEnabled && !panel.allowButton.isEnabled)
        // An early click (even on a forcibly enabled button) does not answer.
        panel.allowButton.isEnabled = true
        panel.allowButton.performClick(nil)
        panel.denyButton.isEnabled = true
        panel.denyButton.performClick(nil)
        panel.denyButton.isEnabled = false
        panel.allowButton.isEnabled = false
        await waitUntil { panel.armed }
        #expect(panel.denyButton.isEnabled && panel.allowButton.isEnabled)
        panel.allowButton.performClick(nil)
        #expect(await decision.value == .allow)
        #expect(!panel.armed && !panel.allowButton.isEnabled && !panel.isVisible)
    }

    @Test func armedDenyClickDenies() async {
        let presenter = CapturingPresenter()
        let confirmer = RelayPaneLinkAlertConfirmer(present: presenter.present, armDelay: 0.01)
        let decision = Task { await confirmer.confirm(prompt(), timeout: 5) }
        await waitUntil { presenter.panel?.armed == true }
        presenter.panel?.denyButton.performClick(nil)
        #expect(await decision.value == .deny)
    }

    @Test func noAnswerExpiresAndHidesThePanel() async {
        let presenter = CapturingPresenter()
        let confirmer = RelayPaneLinkAlertConfirmer(present: presenter.present, armDelay: 0.01)
        #expect(await confirmer.confirm(prompt(), timeout: 0.1) == .timedOut)
        let panel = try! #require(presenter.panel)
        #expect(!panel.armed && !panel.allowButton.isEnabled)
        panel.allowButton.isEnabled = true
        panel.allowButton.performClick(nil)  // a late click is ignored, no crash
    }

    @Test func noScreenIsUnavailable() async {
        let presenter = CapturingPresenter()
        presenter.shown = false
        let confirmer = RelayPaneLinkAlertConfirmer(present: presenter.present, armDelay: 0.01)
        #expect(await confirmer.confirm(prompt(), timeout: 5) == .unavailable)
    }
}
