//
//  AppTerminalView+PublicInput.swift
//  libghostty-spm
//
//  Public wrappers around `TerminalSurface` write paths so hosts can
//  inject bytes into the pty without reaching for internal API.
//

#if canImport(AppKit) && !canImport(UIKit)
    import AppKit
    import Foundation

    extension AppTerminalView {
        /// Make this view the window's first responder, reporting whether
        /// keyboard focus was actually acquired. Fails (returns false) while
        /// the view is not in a window; ``TerminalViewState/requestFocus()``
        /// retries then on window attach.
        @discardableResult
        public func acquireProgrammaticFocus() -> Bool {
            guard let window else { return false }
            if window.firstResponder === self { return true }
            return window.makeFirstResponder(self)
        }

        public func collectNativeInput(_ actions: () -> Void) -> Data? {
            guard let original = surface else { return nil }
            let packet = original.collectNativeInput(actions)
            guard surface === original else { return nil }
            return packet
        }

        /// Send UTF-8 text through Ghostty's paste path, bypassing key
        /// translation. Ghostty sanitizes controls and adds mode 2004 framing.
        /// Use key events or a `text:` binding for control bytes instead.
        /// No-op when the surface has not been created yet.
        public func sendText(_ text: String) {
            surface?.sendText(text)
        }

        /// Clear the renderer selection and reset click-gesture state, so a
        /// following Shift+press starts a fresh selection rather than extending
        /// a retained one. Hosts that replay pointer gestures locally call this
        /// before re-sending a deferred mouse-down.
        @discardableResult
        public func resetSelection() -> Bool {
            surface?.resetSelection() ?? false
        }

        public var applicationIsCapturingMouse: Bool {
            surface?.applicationIsCapturingMouse ?? false
        }

        public func restoreShellMouseReporting() {
            surface?.restoreShellMouseReporting()
        }

        /// The current selection's text without touching the pasteboard, or nil
        /// when nothing is selected.
        public func selectedText() -> String? {
            surface?.readSelection()
        }

        /// Paste the captured value through native protection/confirmation.
        /// Returns whether the synchronous native request consumed the value;
        /// confirmation can still decline it. Never changes the pasteboard.
        public func pasteCapturedText(_ text: String) -> Bool {
            core.pasteCapturedText(text)
        }

        /// Bounded admission diagnostic. Contains no clipboard text or tokens.
        public var capturedPasteRequestState: String { core.capturedPasteRequestState }

        public func readViewportRow(_ row: Int, columns: Int) -> String? {
            surface?.readViewportRow(row, columns: columns)
        }

        public func parsedGridHasColumns(_ columns: Int) -> Bool {
            surface?.parsedGridHasColumns(columns) ?? false
        }

        public func parsedGridColumnCount() -> Int? {
            surface?.parsedGridColumnCount()
        }

        public func readViewportRange(startRow: Int, endRow: Int, columns: Int) -> String? {
            surface?.readViewportRange(startRow: startRow, endRow: endRow, columns: columns)
        }

        public func readViewportBeforeCaret(startRow: Int, caretRow: Int, caretColumn: Int, columns: Int) -> String? {
            surface?.readViewportBeforeCaret(startRow: startRow, caretRow: caretRow, caretColumn: caretColumn, columns: columns)
        }

        /// Invoke a named Ghostty binding action (e.g. "copy_to_clipboard",
        /// "clear_screen"). Returns true when the action dispatched.
        @discardableResult
        public func performBindingAction(_ action: String) -> Bool {
            surface?.performBindingAction(action) ?? false
        }

        /// Jump the viewport by a number of shell prompts.
        ///
        /// Negative offsets move toward older prompts and positive offsets move
        /// toward newer prompts. Prompt navigation requires shell integration.
        @discardableResult
        public func jumpToPrompt(by offset: Int16) -> Bool {
            surface?.jumpToPrompt(by: offset) ?? false
        }

        /// Reveal an absolute scrollback row, where zero is the first row.
        @discardableResult
        public func scrollToRow(_ row: UInt) -> Bool {
            surface?.scrollToRow(row) ?? false
        }
    }
#endif
