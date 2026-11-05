import AppKit
import SwiftUI

enum RelayMikoComposerKeys {
    static func sends(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, hasMarkedText: Bool) -> Bool {
        (keyCode == 36 || keyCode == 76) && !hasMarkedText &&
        modifiers.intersection([.shift, .option, .control]).isEmpty
    }
}

enum RelayMikoPanelPlacement {
    static func panelSize(in bounds: CGSize) -> CGSize {
        CGSize(width: min(560, max(1, bounds.width - 32)), height: min(680, max(1, bounds.height - 70)))
    }
    static func clampedOffset(_ offset: CGSize, in bounds: CGSize) -> CGSize {
        let panel = panelSize(in: bounds)
        return CGSize(width: min(0, max(-max(0, bounds.width - panel.width - 32), offset.width)),
                      height: min(max(0, bounds.height - panel.height - 70), max(-46, offset.height)))
    }
}

/// Plain-text editor keeps composition inside AppKit, including IME marked text.
struct RelayMikoComposer: NSViewRepresentable {
    @Binding var text: String
    var canSend: Bool
    var focusRequest: UUID
    var send: () -> Void

    final class Editor: NSTextView {
        var canSend = false
        var send: () -> Void = {}
        override func keyDown(with event: NSEvent) {
            if RelayMikoComposerKeys.sends(keyCode: event.keyCode, modifiers: event.modifierFlags,
                                          hasMarkedText: hasMarkedText()) {
                if !event.isARepeat && canSend && !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    canSend = false
                    send()
                }
                return
            }
            super.keyDown(with: event)
        }
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RelayMikoComposer
        var focusRequest: UUID?
        init(_ parent: RelayMikoComposer) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let editor = Editor()
        editor.isRichText = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.drawsBackground = false
        editor.textColor = RelayPalette.text
        editor.insertionPointColor = RelayPalette.accent
        editor.font = .systemFont(ofSize: 13)
        editor.textContainerInset = NSSize(width: 0, height: 6)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.delegate = context.coordinator
        editor.setAccessibilityLabel("Message Miko")
        editor.setAccessibilityIdentifier("relay.assistant.input")
        scroll.documentView = editor
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? Editor else { return }
        context.coordinator.parent = self
        if editor.string != text && !editor.hasMarkedText() { editor.string = text }
        editor.canSend = canSend
        editor.send = send
        if context.coordinator.focusRequest != focusRequest {
            context.coordinator.focusRequest = focusRequest
            DispatchQueue.main.async { [weak editor] in
                guard let editor, editor.window != nil else { return }
                editor.window?.makeFirstResponder(editor)
            }
        }
    }
}
