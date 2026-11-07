import AppKit
import Darwin
import Foundation
import GhosttyTerminal
import SwiftUI

// Darwin exports this locale-specific C function, but its xlocale declaration
// is not re-exported by Swift's Darwin module.
@_silgen_name("wcwidth_l")
private func relayUTF8ScalarWidth(_ scalar: Int32, _ locale: locale_t) -> Int32

enum RelayClipboardAction: String, Sendable, CaseIterable {
    case copy
    case cut
    case paste
    case selectAll
}

@MainActor
final class RelayClipboardRequest {
    let action: RelayClipboardAction
    var handled = false

    init(_ action: RelayClipboardAction) {
        self.action = action
    }
}

enum TerminalPromptSelectionEdit {
    /// Recognize only Relay's known input-line prefixes, never arbitrary output.
    static func inputPrefixLength(_ line: String, shell: Bool) -> Int? {
        let leading = line.prefix(while: { $0 == " " }).count
        var remainder = String(line.dropFirst(leading))
        var count = leading
        if shell, remainder.hasPrefix("╰─ ") {
            remainder = String(remainder.dropFirst(3)); count += 3
            while let space = remainder.firstIndex(of: " ") {
                let label = String(remainder[..<space])
                let exitDigits = label.hasPrefix("exit:") ? String(label.dropFirst(5)) : ""
                guard label == "root" || (!exitDigits.isEmpty && exitDigits.allSatisfy({ $0.isASCII && $0.isNumber })) else { break }
                let length = label.count + 1
                remainder = String(remainder.dropFirst(length)); count += length
            }
        }
        let prefix = Array(remainder.prefix(2))
        guard prefix.count == 2, prefix[0] == "❯" || prefix[0] == "›",
              prefix[1] == " " || prefix[1] == "\u{00A0}" else { return nil }
        return count + 2
    }

    static func clickedRange(
        rendered: String, characters: [Character], clickedIndex: Int,
        lineSelection: Bool, shell: Bool
    ) -> Range<Int>? {
        guard clickedIndex >= 0, clickedIndex < characters.count else { return nil }
        var text = rendered.replacingOccurrences(of: "\r\n", with: "\n")
        if lineSelection, let prefix = inputPrefixLength(text, shell: shell) {
            text = String(text.dropFirst(prefix))
        }
        if lineSelection { text = text.trimmingCharacters(in: .newlines) }
        let selected = Array(text)
        guard !selected.isEmpty, selected.count <= characters.count else { return nil }
        var match: Range<Int>?
        for lower in 0...(characters.count - selected.count) {
            let range = lower..<(lower + selected.count)
            guard range.contains(clickedIndex), Array(characters[range]) == selected else { continue }
            guard match == nil else { return nil }
            match = range
        }
        return match
    }

    static func isEnabled(contentKind: PaneContentKind, agentKind: AgentKind) -> Bool {
        contentKind == .terminal
    }

    static func forcesLocalSelection(agentKind: AgentKind) -> Bool {
        agentKind.usesNativePromptEditing
    }

    /// Full-screen terminal programs own their pointer protocol, so Relay
    /// must not synthesize line-editor movement while a shell is in the
    /// alternate screen. Codex and Claude are different: their composer is
    /// itself an alternate-screen TUI, and Relay deliberately handles prompt
    /// selection locally for those agents.
    static func allowsCursorPlacement(
        geometryIsStable: Bool,
        alternateScreenIsActive: Bool,
        agentPrompt _: Bool
    ) -> Bool {
        // Alternate-screen TUIs own their mouse and composer cursor. Ghostty's
        // IME rectangle is the terminal grid cursor, which can differ from a
        // Codex/Claude prompt; synthesizing arrows from it corrupts input.
        geometryIsStable && !alternateScreenIsActive
    }

    static func deletionSequence(for selectedText: String, backwards _: Bool) -> String? {
        let normalized = selectedText.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let count = normalized.count
        guard count > 0, count <= 4_096 else { return nil }
        // Backspace is implemented consistently by shell line editors, Codex,
        // and Claude. Forward Delete (CSI 3~) is ignored by some agent TUIs.
        // Relay therefore moves the remote caret to the logical end of the
        // selected range and always erases backwards, including real newlines.
        return String(repeating: "\u{007F}", count: count)
    }

    static func selectionIsNearCursor(
        startY: CGFloat,
        endY: CGFloat,
        cursorY: CGFloat,
        viewportHeight: CGFloat,
        agentPrompt: Bool
    ) -> Bool {
        guard startY.isFinite, endY.isFinite, cursorY.isFinite,
              viewportHeight.isFinite, viewportHeight > 0,
              cursorY >= 0, cursorY <= viewportHeight
        else { return false }

        // Agent TUIs place their composer wherever their layout requires;
        // Codex commonly anchors it near the top of a tall pane. Validate the
        // selection against Ghostty's live IME/cursor rectangle instead of a
        // guessed bottom strip. The wider agent range supports wrapped prompt
        // blocks while keeping selections far from the active cursor inert.
        let radius = agentPrompt
            ? min(320, max(96, viewportHeight * 0.42))
            : min(96, max(48, viewportHeight * 0.2))
        return abs(startY - cursorY) <= radius && abs(endY - cursorY) <= radius
    }

    static func cursorMovementOffset(
        cursorOrigin: CGPoint,
        target: CGPoint,
        cellSize: CGSize,
        columns: Int
    ) -> Int? {
        guard cursorOrigin.x.isFinite, cursorOrigin.y.isFinite,
              target.x.isFinite, target.y.isFinite,
              cellSize.width.isFinite, cellSize.height.isFinite,
              cellSize.width > 0, cellSize.height > 0, columns > 0
        else { return nil }

        // Ghostty reports the cursor cell's top-left origin. A click belongs
        // to the cell containing it, so floor is correct in both directions:
        // a click anywhere in the immediately preceding cell moves left once,
        // while a click inside the cursor's current cell does not move.
        let rowDelta = Int(floor((target.y - cursorOrigin.y) / cellSize.height))
        let columnDelta = Int(floor((target.x - cursorOrigin.x) / cellSize.width))
        let offset = rowDelta * columns + columnDelta
        guard abs(offset) <= 4_096 else { return nil }
        return offset
    }

    /// Agent state switches back to `active` as soon as the user types a
    /// response. That describes the conversation, not whether its composer is
    /// editable. Local input is stronger evidence than that eager phase
    /// update. Shell prompts are governed by OSC 133 instead.
    static func promptEditingIsActive(
        agentPrompt: Bool,
        hasLocalInput: Bool,
        agentPhaseAllowsEditing: Bool,
        semanticShellPromptActive: Bool
    ) -> Bool {
        // A completed CLI can retain its agent label after returning to the
        // shell. OSC 133's live input marker describes the current editor;
        // the retained conversation classification describes its history.
        if semanticShellPromptActive { return true }
        if agentPrompt {
            return agentPhaseAllowsEditing || hasLocalInput
        }
        return false
    }

    /// Prefer the exact logical mirror when Relay saw the whole prompt. After
    /// an SSH reconnect the visible line may predate this app process, so a
    /// bounded visual delta is the only honest fallback. Readline and agent
    /// composers clamp arrows at their own input boundaries.
    static func resolvedMovementOffset(
        visualOffset: Int,
        mirroredOffset: Int?,
        mirrorIsReliable: Bool,
        allowsRemoteVisualFallback: Bool
    ) -> Int? {
        if let mirroredOffset { return mirroredOffset }
        guard !mirrorIsReliable,
              allowsRemoteVisualFallback,
              abs(visualOffset) <= 1_024
        else { return nil }
        return visualOffset
    }
}

enum TerminalKeyboardSelectionGeometry {
    static func anchor(
        for cursor: CGPoint,
        cellSize: CGSize,
        columns: Int,
        gridOriginX: CGFloat = 0
    ) -> CGPoint? {
        guard cursor.x.isFinite, cursor.y.isFinite,
              cellSize.width.isFinite, cellSize.height.isFinite,
              gridOriginX.isFinite,
              cellSize.width > 0, cellSize.height > 0,
              columns > 0
        else { return nil }
        let cursorColumn = Int(floor((cursor.x - gridOriginX) / cellSize.width))
        guard cursorColumn >= 0, cursorColumn < columns else { return nil }
        // Preserve Ghostty's exact caret x. The unused horizontal pixels are
        // not guaranteed to be distributed symmetrically, so snapping the
        // caret to a guessed centered grid shifts partial selections.
        return cursor
    }

    /// Moves a terminal-cell center by a signed number of visual cells.
    /// Unlike a raw x offset, this preserves the renderer's row/column grid
    /// when a keyboard selection crosses either edge of a wrapped line.
    static func endpoint(
        from cursor: CGPoint,
        visualCellDelta: Int,
        cellSize: CGSize,
        columns: Int,
        gridOriginX: CGFloat = 0
    ) -> CGPoint? {
        guard cursor.x.isFinite, cursor.y.isFinite,
              cellSize.width.isFinite, cellSize.height.isFinite,
              gridOriginX.isFinite,
              cellSize.width > 0, cellSize.height > 0,
              columns > 0, abs(visualCellDelta) <= 4_096
        else { return nil }

        let cursorColumn = Int(floor((cursor.x - gridOriginX) / cellSize.width))
        guard cursorColumn >= 0, cursorColumn < columns else { return nil }
        let unwrappedColumn = cursorColumn + visualCellDelta
        let rowDelta = Int(floor(Double(unwrappedColumn) / Double(columns)))
        let endpointColumn = unwrappedColumn - rowDelta * columns
        guard endpointColumn >= 0, endpointColumn < columns else { return nil }
        return CGPoint(
            x: cursor.x + CGFloat(endpointColumn - cursorColumn) * cellSize.width,
            y: cursor.y + CGFloat(rowDelta) * cellSize.height
        )
    }
}

enum TerminalViewportRepaintPolicy {
    private struct Evidence {
        var addressedRows: [UInt16] = []
        var hasExplicitClear = false
        var hasSemanticPromptProperty = false
        var hasSemanticPromptEnd = false
        var hasEraseLine = false
        var printableBytes = 0
    }

    /// A resize transaction may be published as soon as the application has
    /// produced a complete replacement frame. This keeps the previous
    /// IOSurface visible across an early clear from a slow TUI such as Codex,
    /// while Claude, htop, and synchronized renderers swap immediately when
    /// their destination-sized frame completes.
    static func hasCompleteReplacement(_ data: Data, rows: UInt16) -> Bool {
        guard data.count >= 96 else { return false }
        // Presentation keeps the existing grid and applies every buffered byte.
        // A completed synchronized update may therefore be a differential
        // repaint. Replay compaction requires a self-contained clear instead;
        // sharing its stricter predicate held normal agent updates for 5s.
        let begin = Data("\u{001B}[?2026h".utf8)
        let end = Data("\u{001B}[?2026l".utf8)
        if let start = data.range(of: begin),
           data.range(of: end, in: start.upperBound..<data.endIndex) != nil {
            return true
        }
        let evidence = repaintEvidence(in: data, rows: rows)
        if replacementIsSubstantial(evidence, rows: rows) { return true }
        let printableFloor = max(512, Int(rows) * 4)
        return evidence.hasExplicitClear && evidence.printableBytes >= printableFloor
    }

    private static func replacementIsSubstantial(_ evidence: Evidence, rows: UInt16) -> Bool {
        let required = rows > 0 && rows < 5 ? 2 : 3
        let semanticPromptRepaint = evidence.hasSemanticPromptProperty &&
            evidence.hasSemanticPromptEnd && evidence.hasEraseLine && evidence.printableBytes >= 4
        return evidence.addressedRows.count >= required || semanticPromptRepaint
    }

    private static func repaintEvidence(in data: Data, rows _: UInt16) -> Evidence {
        data.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            var evidence = Evidence()
            evidence.addressedRows.reserveCapacity(4)
            var index = 0
            while index + 1 < bytes.count {
                guard bytes[index] == 0x1B else {
                    if bytes[index] >= 0x20, bytes[index] != 0x7F {
                        evidence.printableBytes += 1
                    }
                    index += 1
                    continue
                }
                if bytes[index + 1] == 0x63 { // RIS: ESC c
                    evidence.hasExplicitClear = true
                    index += 2
                    continue
                }
                if bytes[index + 1] == 0x5D, index + 6 < bytes.count,
                   bytes[index + 2] == 0x31,
                   bytes[index + 3] == 0x33,
                   bytes[index + 4] == 0x33,
                   bytes[index + 5] == 0x3B {
                    if bytes[index + 6] == 0x50 { evidence.hasSemanticPromptProperty = true }
                    if bytes[index + 6] == 0x42 { evidence.hasSemanticPromptEnd = true }
                    index += 7
                    continue
                }
                guard bytes[index + 1] == 0x5B else {
                    index += 2
                    continue
                }
                var cursor = index + 2
                var firstParameter = 0
                var hasFirstParameter = false
                while cursor < bytes.count, (0x30...0x39).contains(bytes[cursor]) {
                    hasFirstParameter = true
                    firstParameter = min(
                        Int(UInt16.max),
                        firstParameter * 10 + Int(bytes[cursor] - 0x30)
                    )
                    cursor += 1
                }
                if hasFirstParameter, cursor < bytes.count,
                   (firstParameter == 2 || firstParameter == 3),
                   bytes[cursor] == 0x4A { // CSI 2J / CSI 3J
                    evidence.hasExplicitClear = true
                    index = cursor + 1
                    continue
                }
                if cursor < bytes.count, bytes[cursor] == 0x4B { // CSI K / 0K / 2K
                    evidence.hasEraseLine = true
                    index = cursor + 1
                    continue
                }
                guard hasFirstParameter else {
                    index += 2
                    continue
                }
                if cursor < bytes.count, bytes[cursor] == 0x3B {
                    cursor += 1
                    while cursor < bytes.count, (0x30...0x39).contains(bytes[cursor]) {
                        cursor += 1
                    }
                }
                // Only CUP/HVP terminators address a row. A semicolon in SGR
                // (for example CSI 38;5;...m) is merely another color parameter.
                if cursor < bytes.count,
                   bytes[cursor] == 0x48 || bytes[cursor] == 0x66 {
                    let row = UInt16(firstParameter)
                    if !evidence.addressedRows.contains(row) {
                        evidence.addressedRows.append(row)
                    }
                }
                index = max(index + 1, cursor + 1)
            }
            return evidence
        }
    }
}

enum TerminalViewportGeometry {
    /// Ghostty accounts for its own cell padding and minimum dimensions.
    /// Only a surface measurement for the current view bounds may be used as
    /// the remote commit target; dividing bounds by cell size can overestimate
    /// both columns and rows.
    static func measuredViewport(
        _ metrics: TerminalGridMetrics,
        bounds: CGSize,
        backingScaleFactor: CGFloat
    ) -> RelayViewport? {
        guard bounds.width.isFinite, bounds.height.isFinite,
              backingScaleFactor.isFinite, backingScaleFactor > 0 else { return nil }
        let width = Int((bounds.width * backingScaleFactor).rounded(.down))
        let height = Int((bounds.height * backingScaleFactor).rounded(.down))
        guard width > 0, height > 0,
              abs(Int(metrics.widthPixels) - width) <= 2,
              abs(Int(metrics.heightPixels) - height) <= 2 else { return nil }
        return RelayViewport(columns: metrics.columns, rows: metrics.rows)
    }
}

enum TerminalPointerGeometry {
    /// While Relay atomically resizes an SSH pane, Ghostty deliberately keeps
    /// the previous IOSurface visible until the destination PTY frame is
    /// complete. Core Animation scales that retained surface to the new view
    /// bounds, but Ghostty's selection grid still has the retained surface's
    /// pixel dimensions. Translate the visible pointer back into that grid so
    /// the selected cells remain under the pointer throughout the handoff.
    static func remappedPoint(
        _ point: CGPoint,
        visibleSize: CGSize,
        surfaceSizePixels: CGSize,
        backingScaleFactor: CGFloat
    ) -> CGPoint {
        guard point.x.isFinite, point.y.isFinite,
              visibleSize.width.isFinite, visibleSize.height.isFinite,
              visibleSize.width > 0, visibleSize.height > 0,
              surfaceSizePixels.width.isFinite, surfaceSizePixels.height.isFinite,
              surfaceSizePixels.width > 0, surfaceSizePixels.height > 0,
              backingScaleFactor.isFinite, backingScaleFactor > 0
        else { return point }

        let surfaceSize = CGSize(
            width: surfaceSizePixels.width / backingScaleFactor,
            height: surfaceSizePixels.height / backingScaleFactor
        )
        guard abs(surfaceSize.width - visibleSize.width) >= 0.5 ||
                abs(surfaceSize.height - visibleSize.height) >= 0.5
        else { return point }

        let surfaceX = min(
            max(point.x * surfaceSize.width / visibleSize.width, 0),
            surfaceSize.width
        )
        // AppKit locations are bottom-origin while Ghostty flips them against
        // the *current* view height. Preserve that final flip by mapping the
        // top-origin distance and expressing it back in the current view's
        // coordinate system; a retained surface taller than the view can
        // therefore legitimately produce a negative AppKit y coordinate.
        let visibleTop = visibleSize.height - point.y
        let surfaceTop = min(
            max(visibleTop * surfaceSize.height / visibleSize.height, 0),
            surfaceSize.height
        )
        return CGPoint(
            x: surfaceX,
            y: visibleSize.height - surfaceTop
        )
    }
}

enum TerminalGeometry {
    /// SwiftUI can briefly propose invalid NSView dimensions while replacing
    /// one tab tree with another. Reject those values rather than clamping to
    /// a tiny placeholder: Ghostty propagates every accepted size to the
    /// remote PTY, where even a momentary 1x1 grid permanently reflows TUI
    /// output.
    static func accepts(_ size: NSSize) -> Bool {
        size.width.isFinite && size.height.isFinite &&
            size.width >= 2 && size.height >= 2
    }
}

struct TerminalStableGeometrySampler {
    private(set) var candidate: CGSize?
    private(set) var consecutiveSamples = 0

    mutating func observe(_ size: CGSize) -> Bool {
        guard TerminalGeometry.accepts(size) else {
            candidate = nil
            consecutiveSamples = 0
            return false
        }
        if let candidate,
           abs(candidate.width - size.width) < 0.5,
           abs(candidate.height - size.height) < 0.5 {
            consecutiveSamples += 1
        } else {
            candidate = size
            consecutiveSamples = 1
        }
        return consecutiveSamples >= 2
    }
}

enum TerminalBufferRetentionPolicy {
    static let retainedCapacityLimit = 512 << 10

    static func clear(_ data: inout Data) {
        if data.count > retainedCapacityLimit {
            data = Data()
        } else {
            data.removeAll(keepingCapacity: true)
        }
    }
}

enum TerminalReconnectReplayPolicy {
    static func canRetainHydratedGrid(remoteSequence: UInt64, explicitBoundary: Bool) -> Bool {
        remoteSequence > 0 && explicitBoundary
    }

    private static let presentationClear = Data("\u{001B}[2J\u{001B}[H".utf8)
    private static let terminalReset = Data("\u{001B}c".utf8)
    private static let eraseScrollback = Data("\u{001B}[3J".utf8)

    static func isPresentationClear(_ data: Data, remoteSequence: UInt64) -> Bool {
        remoteSequence == 0 && data == presentationClear
    }

    /// Missing terminal bytes invalidate cursor, scroll-region and grid state.
    /// A suffix after a gap cannot be applied as a delta over a saved screen.
    static func extendsCachedScreenAfterOutputReset(hasExactSnapshot: Bool) -> Bool {
        false
    }

    /// relayd prefixes a replay that starts inside its bounded ring with RIS.
    /// RIS and CSI 3J are correct for a renderer starting from nothing, but
    /// when Relay has just reconstructed an exact checkpoint they also erase
    /// its scrollback. Remove only a destructive *leading* replay prefix; later
    /// application resets remain authoritative terminal output.
    static func preservingCheckpointScrollback(_ replay: Data) -> Data {
        var remainder = replay[...]
        var removedPrefix = false
        while true {
            if remainder.starts(with: terminalReset) {
                remainder = remainder.dropFirst(terminalReset.count)
                removedPrefix = true
                continue
            }
            if remainder.starts(with: eraseScrollback) {
                remainder = remainder.dropFirst(eraseScrollback.count)
                removedPrefix = true
                continue
            }
            break
        }
        return removedPrefix ? Data(remainder) : replay
    }
}

enum TerminalSnapshotDisplayPolicy {
    /// Cached ANSI is a reconstruction journal, not an authoritative TUI frame.
    /// Matching final dimensions do not prove that earlier cursor-addressed
    /// updates were produced on that grid. Agent startup owes a fresh repaint.
    static func requiresAttachRepaint(rendered: Bool, isAgent: Bool) -> Bool {
        !rendered || isAgent
    }
    static func initialReplaySequence(
        remoteSequence: UInt64?, rendered: Bool
    ) -> UInt64 {
        // A repaint can update only the composer or status rows. It cannot
        // supply the screen history of a cache that was never rendered.
        rendered ? (remoteSequence ?? 0) : 0
    }

    /// A checkpoint made only of input-mode negotiation is useful for its
    /// durable output cursor but cannot reconstruct a visible pane. Treat it
    /// as a cache miss so Relay requests one authoritative same-size repaint
    /// from Codex/Claude instead of presenting a blank terminal indefinitely.
    static func hasVisibleContent(_ data: Data) -> Bool {
        let bytes = Array(data)
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x1B, index + 1 < bytes.count {
                switch bytes[index + 1] {
                case 0x5B: // CSI
                    index += 2
                    while index < bytes.count, !(0x40...0x7E).contains(bytes[index]) {
                        index += 1
                    }
                    index = min(index + 1, bytes.count)
                    continue
                case 0x5D, 0x50: // OSC / DCS
                    // BEL terminates OSC only; a DCS payload is 8-bit clean
                    // and may legitimately contain 0x07, so DCS ends on ST.
                    let isOperatingSystemCommand = bytes[index + 1] == 0x5D
                    index += 2
                    while index < bytes.count {
                        if isOperatingSystemCommand, bytes[index] == 0x07 {
                            index += 1
                            break
                        }
                        if bytes[index] == 0x1B,
                           index + 1 < bytes.count,
                           bytes[index + 1] == 0x5C {
                            index += 2
                            break
                        }
                        index += 1
                    }
                    continue
                case 0x28, 0x29, 0x2A, 0x2B: // character-set designation
                    index = min(index + 3, bytes.count)
                    continue
                default:
                    index += 2
                    continue
                }
            }
            // Space, line breaks, tabs, and C0 controls do not make a blank
            // checkpoint renderable. Any other ASCII glyph or UTF-8 byte does.
            if byte >= 0x21, byte != 0x7F { return true }
            index += 1
        }
        return false
    }
}

enum TerminalReplayTrace {
    static let enabled = ProcessInfo.processInfo.environment["RELAY_REPLAY_TRACE"] == "1"

    static func log(_ message: String) {
        guard enabled else { return }
        FileHandle.standardError.write(Data("[ReplayTrace] \(Date().timeIntervalSince1970) \(message) monotonic=\(ProcessInfo.processInfo.systemUptime)\n".utf8))
    }
}

enum TerminalInitialViewportPolicy {
    static func isReady(
        surface: RelayViewport?, confirmed: RelayViewport,
        surfacePixels: CGSize?, viewPixels: CGSize
    ) -> Bool {
        guard let surface, surface == confirmed, let surfacePixels else { return false }
        return abs(surfacePixels.width - viewPixels.width) <= 4 &&
            abs(surfacePixels.height - viewPixels.height) <= 4
    }
}

enum TerminalEnergyPolicy {
    /// Occlusion pauses presentation, never the terminal protocol parser.
    static func pausesPresentation(
        isPresented: Bool,
        applicationVisible: Bool
    ) -> Bool {
        !isPresented || !applicationVisible
    }

    static func showsSurface(isPresented: Bool, applicationVisible: Bool) -> Bool {
        isPresented && applicationVisible
    }
}

enum TerminalSnapshotCompactionPolicy {
    /// Keep live appends O(1). The live buffer is trimmed as soon as it
    /// passes the storage bound, so scheduled saves never hand the store an
    /// oversized stream to compact on every debounce. Trimming to half the
    /// bound leaves headroom: compacting at exactly the bound would rescan the
    /// whole buffer again on every following SSH packet.
    static let highWaterBytes = TerminalSnapshotStore.maximumBytes
    static let trimTargetBytes = TerminalSnapshotStore.maximumBytes / 2

    static func shouldCompact(byteCount: Int) -> Bool {
        byteCount > highWaterBytes
    }

    static func trim(_ buffer: Data) -> (data: Data, truncated: Bool) {
        TerminalSnapshotStore.boundedReportingTruncation(buffer, maximumBytes: trimTargetBytes)
    }
}

enum TerminalResizePolicy {
    /// SwiftUI emits several valid-but-transitional pane sizes while moving
    /// durable terminal views between tab layouts. Only the final geometry
    /// should reach the remote PTY.
    static let debounceMilliseconds = 75
    static let revealAfterCommitMilliseconds = 50
}

enum TerminalViewportOwnershipPolicy {
    /// The native surface only needs to take the PTY back when another client
    /// committed a different grid (or no grid has been committed yet).
    static func needsNativeReclaim(
        native: RelayViewport,
        committed: RelayViewport?
    ) -> Bool {
        native != committed
    }
}

/// Live PTY packets can arrive much faster than a display can present them.
/// One frame-sized batch keeps parsing, link detection, and renderer wakeups
/// proportional to visible frames instead of SSH packet count. Explicit replay
/// and resize barriers continue to bypass this delay.
enum TerminalDisplayBatchPolicy {
    static let liveMilliseconds = 16
    /// An echo or other small update after a quiet period is drawn at once.
    /// Only sustained output waits, so a packet burst stays one Ghostty write.
    static let interactiveBytes = 1024

    static func drainDelayMilliseconds(
        immediate: Bool, pendingBytes: Int, millisecondsSinceLastDrain: Double?
    ) -> Int {
        if immediate { return 0 }
        guard pendingBytes <= interactiveBytes else { return liveMilliseconds }
        guard let elapsed = millisecondsSinceLastDrain else { return 0 }
        return elapsed >= Double(liveMilliseconds) ? 0 : liveMilliseconds
    }
}

enum TerminalViewportPosition {
    static func isAtBottom(_ scrollbar: TerminalScrollbar) -> Bool {
        scrollbar.len >= scrollbar.total ||
            scrollbar.offset >= scrollbar.total - scrollbar.len
    }
}

struct TerminalStableViewportCommit {
    let explicit: Bool
    let remoteGeneration: UInt64?
    let presentationEpoch: UInt64
}

struct TerminalPresentationAttachmentState {
    private(set) var generation: UInt64 = 0
    private(set) var currentLease: UUID?
    private(set) var isPresented = false

    mutating func begin(lease: UUID) -> UInt64 {
        generation &+= 1
        if generation == 0 { generation = 1 }
        currentLease = lease
        isPresented = false
        return generation
    }

    mutating func setPresented(_ presented: Bool, lease: UUID, generation: UInt64) -> Bool {
        guard self.generation == generation, currentLease == lease else { return false }
        isPresented = presented
        return true
    }

    mutating func end(lease: UUID, generation: UInt64) -> Bool {
        guard self.generation == generation, currentLease == lease else { return false }
        currentLease = nil
        isPresented = false
        return true
    }
}


@MainActor
final class TerminalRuntime: NSObject {
    /// The external observations and final write used by shell admission.
    /// Supplying a transport does not replace any identity, revision or
    /// authorization check in sendAssistantShellCommand.
    struct AssistantShellTransport {
        let promptIsEmpty: @MainActor () -> Bool
        let readOwner: @MainActor () async -> RelayPromptOwnerIdentity?
        let send: @MainActor (String, Int) -> Bool
    }
    private weak var pane: PaneModel?
    private let io = TerminalIOBridge()
    private let activityCoalescer = TerminalActivityCoalescer()
    private let artifactCoalescer = TerminalActivityCoalescer(delayMilliseconds: 250)
    private let artifactCoordinator = TerminalArtifactCoordinator()
    private var lastArtifact: (path: String, data: Data)?
    private var hoveredLink: String?
    private var fileTransferTask: Task<Void, Never>?
    private var started = false
    /// Whether this runtime has started (attached). Read only; for checks
    /// that hidden workspace moves never start a pane.
    var hasStarted: Bool { started }
    private var reconnectRequiresExistingWorker = false
    private var awaitingInitialViewport = false
    private var restoreStartedAt: UInt64?
    private var restoreReason = "launch"
    private var presentationAttachment = TerminalPresentationAttachmentState()
    private var allowsRendering = RelayApplicationActivityState.allowsContinuousUpdates
    private var legacyActivityHeuristicsEnabled = true
    private var workerProvidesTerminalModeState = false
    private var terminalWorkerCapabilitiesKnown = false
    private var terminalReplayCaughtUp = false
    private var legacyTerminalModeCompatibilityApplied = false
    private var explicitGeometryTransitionPending = false
    private var revealLatestAfterGeometryTransition = true
    private var viewportIsAtBottom = true {
        didSet { if oldValue != viewportIsAtBottom { nativeImageValidation?.yield(.validate) } }
    }
    private var presentationRecoveryTask: Task<Void, Never>?
    private var focusRecoveryTask: Task<Void, Never>?
    private var interactionPresentationTask: Task<Void, Never>?
    private var nativeViewportRecoveryTask: Task<Void, Never>?
    private var viewportCommitFallbackTask: Task<Void, Never>?
    private var pendingViewportCommitGeneration: UInt64?
    private var pendingViewportCommitEpoch: UInt64?
    private var viewportPresentationEpoch: UInt64 = 0
    private var pendingExplicitViewportTarget: RelayViewport?
    private var latestSurfaceViewport: RelayViewport?
    private var latestSurfaceGridMetrics: TerminalGridMetrics?
    private var pendingFocusOnPresentation = false
    private var focusIntentGeneration: UInt64 = 0
    private var keyboardFocusEligible = false
    var onPaneSelection: (() -> Void)?
    private var readlineShellIdentity: String?
    private var promptEditorProbeTask: Task<Void, Never>?

    fileprivate var usesReadlinePromptUnits: Bool { readlineShellIdentity != nil }
    /// Tests only: the readline identity is otherwise proven by a remote
    /// process-inventory probe.
    func setReadlineShellIdentityForTesting(_ identity: String?) { readlineShellIdentity = identity }

    fileprivate func synchronizePromptWidthPolicy(active: Bool) {
        io.configurePromptWidth(readline: usesReadlinePromptUnits, promptActive: active)
    }

    fileprivate func resolvePromptEditorPolicy() {
        guard let pane, pane.profile.backend == .relay else { return }
        guard promptEditorProbeTask == nil else {
            recordInputDiagnostic("prompt-editor-probe-skipped", details: ["reason": "in-flight"])
            return
        }
        // Process inventory is host-scoped and does not use the request cwd.
        // A fresh remote prompt may arrive without OSC 7, so its shell policy
        // must not depend on a working-directory notification.
        let directory = pane.directory.flatMap { $0.hasPrefix("/") ? $0 : nil } ?? "/"
        recordInputDiagnostic("prompt-editor-probe-start", details: [
            "directory_fallback": String(pane.directory?.hasPrefix("/") != true)
        ])
        readlineShellIdentity = nil
        let paneID = pane.id
        let profileID = pane.profile.id
        let context = RelayExecutionContext(profile: pane.profile, directory: directory)
        promptEditorProbeTask = Task { @MainActor [weak self] in
            defer {
                self?.promptEditorProbeTask = nil
                self?.view.synchronizePromptWidthPolicy()
            }
            do {
                let result = try await RelayHostFiles.request(context: context, fields: ["operation": "process_list"])
                guard let self else { return }
                guard self.pane?.id == paneID, self.pane?.profile.id == profileID else {
                    self.recordInputDiagnostic("prompt-editor-probe-rejected", details: ["reason": "context-changed"])
                    return
                }
                guard let rows = result["processes"] as? [[String: Any]] else {
                    self.recordInputDiagnostic("prompt-editor-probe-rejected", details: ["reason": "missing-processes"])
                    return
                }
                let shells = rows.filter {
                    ($0["pane_id"] as? String)?.lowercased() == paneID.uuidString.lowercased() &&
                    ["bash", "zsh", "fish", "sh", "dash", "ksh", "nu", "elvish"].contains(
                        (($0["name"] as? String ?? "") as NSString).lastPathComponent) &&
                    ($0["relationship"] as? String) == "Relay terminal"
                }
                guard shells.count == 1, let shell = shells.first else {
                    let paneRows = rows.filter {
                        ($0["pane_id"] as? String)?.lowercased() == paneID.uuidString.lowercased()
                    }
                    self.recordInputDiagnostic("prompt-editor-probe-rejected", details: [
                        "reason": "shell-count", "shells": String(shells.count), "pane_processes": String(paneRows.count)
                    ])
                    return
                }
                guard ((shell["name"] as? String ?? "") as NSString).lastPathComponent == "bash" else {
                    self.recordInputDiagnostic("prompt-editor-probe-rejected", details: ["reason": "non-bash-shell"])
                    return
                }
                guard let pid = shell["pid"] as? Int, let start = shell["start"] as? String,
                      pid > 0, !start.isEmpty else {
                    self.recordInputDiagnostic("prompt-editor-probe-rejected", details: ["reason": "missing-shell-identity"])
                    return
                }
                self.readlineShellIdentity = "\(pid):\(start)"
                self.recordInputDiagnostic("prompt-editor-policy", details: ["editor": "readline"])
            } catch {
                self?.recordInputDiagnostic("prompt-editor-probe-failed", details: ["error": error.localizedDescription])
            }
        }
    }
    private var initialAuthoritativeRepaintPending = false
    private var initialRestoreUsedCachedDisplay = false
    private var authoritativeAttachRepaintRequested = false
    private var initialReplayDisplayCommitted = false
    private var initialReplayWritesResumed = false
    private var initialWidthRepaintPending = false
    private var initialWidthRepaintCompleted = false
    private var initialWidthRepaintFailureEpoch: UInt64?
    private var initialWidthRepaintTask: Task<Void, Never>?
    private var initialWidthRepaintEvents: AsyncStream<InitialWidthRepaintEvent>.Continuation?

    private enum InitialWidthRepaintEvent: Sendable {
        case viewport(InMemoryTerminalViewport)
        case frame(UUID)
        case timeout
    }

    private var session: InMemoryTerminalSession { io.session }
    private(set) lazy var view: RelayGhosttyView = makeView()

    var networkForegroundPID: pid_t? {
        guard started else { return nil }
        return view.foregroundPid
    }

    private static let controller = TerminalController(
        configuration: RelayPreferences.shared.terminalConfiguration(),
        // The controller appends its theme after the configuration. Relay
        // owns these colors; the default theme would override our palette.
        theme: TerminalTheme()
    )

    static func applyPreferences(_ preferences: RelayPreferences = .shared) {
        _ = controller.setTerminalConfiguration(preferences.terminalConfiguration())
    }

    init(pane: PaneModel) {
        if ProcessInfo.processInfo.environment["RELAY_TERMINAL_DEBUG"] == "1" {
            TerminalDebugLog.sink = { message in
                FileHandle.standardError.write(Data((message + "\n").utf8))
            }
            TerminalDebugLog.enable([.lifecycle, .metrics])
        }
        self.pane = pane
        super.init()
        io.onReplayFinished = { [weak self] hasVisibleScreen in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.initialReplayDisplayCommitted = true
                if self.pane?.kind.usesNativePromptEditing == true && !hasVisibleScreen {
                    self.initialWidthRepaintPending = true
                }
                TerminalReplayTrace.log("finish-start pane=\(self.pane?.id.uuidString ?? "unknown") attached=\(self.view.window != nil) presented=\(self.presentationAttachment.isPresented) surfaceVisible=\(self.view.relaySurfaceIsVisible) renderingAllowed=\(self.allowsRendering) appActive=\(NSApp.isActive) windowVisible=\(self.view.window?.isVisible == true) alpha=\(self.view.alphaValue) epoch=\(self.pendingViewportCommitEpoch.map(String.init) ?? "none")")
                // A replay commit changes a large part of Ghostty's grid in one
                // write. Reconcile the live NSView metrics and explicitly owe a
                // render before removing Relay's restore cover. Window resizes
                // and tab switches did this incidentally, which is why they
                // appeared to "fix" a garbled reconnect.
                var sampler = TerminalStableGeometrySampler()
                var settled = false
                for delay in [0, 16, 32, 64, 120, 240] {
                    if delay == 0 {
                        await Task.yield()
                    } else {
                        try? await Task.sleep(for: .milliseconds(delay))
                    }
                    guard !Task.isCancelled else { return }
                    self.view.superview?.layoutSubtreeIfNeeded()
                    guard self.view.window != nil,
                          sampler.observe(self.view.bounds.size),
                          !self.explicitGeometryTransitionPending,
                          self.pendingViewportCommitEpoch == nil else { continue }
                    self.view.fitToSize()
                    self.view.synchronizeAndRedraw()
                    self.commitStableViewport()
                    settled = true
                    break
                }
                // A minimized/off-Space window can remain unmeasurable for the
                // whole bounded wait. Do not fit transient geometry; the normal
                // application-presentation recovery will fit it when visible.
                if !settled {
                    self.view.synchronizeAndRedraw()
                }
                // Ghostty applies a large replay over several render passes. Keep
                // the overlay up until the viewport settles on the live screen.
                for delay in [0, 32, 96] {
                    if delay > 0 {
                        try? await Task.sleep(for: .milliseconds(delay))
                    }
                    _ = self.view.performBindingAction("scroll_to_bottom")
                    _ = self.view.scrollToRow(UInt.max)
                    self.view.synchronizeAndRedraw()
                }
                self.pane?.finishTerminalRestore()
                self.view.recoverPromptHistoryAfterReplay()
                TerminalReplayTrace.log("finish-end pane=\(self.pane?.id.uuidString ?? "unknown") settled=\(settled) attached=\(self.view.window != nil) surfaceVisible=\(self.view.relaySurfaceIsVisible) renderingAllowed=\(self.allowsRendering) appActive=\(NSApp.isActive) windowVisible=\(self.view.window?.isVisible == true) alpha=\(self.view.alphaValue)")
                self.finishMeasuredRestore()
            }
        }
        io.onPresentationResumed = { [weak self] in
            Task { @MainActor [weak self] in
                self?.finishPresentationResume()
            }
        }
        io.onReplayWritesResumed = { [weak self] in
            Task { @MainActor [weak self] in
                self?.initialReplayWritesResumed = true
                self?.requestInitialRepaintIfReady()
            }
        }
        io.onObservedRepaintFrame = { [weak self] id in
            Task { @MainActor [weak self] in
                self?.initialWidthRepaintEvents?.yield(.frame(id))
            }
        }
        io.onViewportCommitted = { [weak self, weak io] generation, source, deliveryEpoch in
            Task { @MainActor [weak self, weak io, weak source] in
                guard let self, let io, let source,
                      io.isCurrentTransport(source, deliveryEpoch: deliveryEpoch) else { return }
                self.viewportDidCommit(generation)
            }
        }
        io.onViewportFrameReady = { [weak self, weak io] producer, source, epoch in
            Task { @MainActor [weak self, weak io, weak source] in
                guard let self, let io, io.isCurrentOutputProducer(producer) else { return }
                if let epoch {
                    guard let source, io.isCurrentTransport(source, deliveryEpoch: epoch) else { return }
                }
                self.viewportFrameDidBecomeReady()
            }
        }
        io.onPromptHistoryInvalidated = { [weak self] in
            Task { @MainActor [weak self] in
                self?.view.promptExecutionBoundaryWasObserved()
            }
        }
        io.onSemanticPromptStateChanged = { [weak self] active in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if active {
                    self.view.shellPromptBecameActive()
                } else {
                    self.view.setShellPromptActive(false)
                }
            }
        }
        io.onViewportReady = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.awaitingInitialViewport else { return }
                self.view.fitToSize()
                self.startIfNeeded()
            }
        }
        // Selector delivery avoids moving Foundation's non-Sendable
        // `Notification` value across an async-sequence isolation boundary.
        // RelayApplicationActivityState posts this notification on the main
        // actor, where every TerminalRuntime already lives.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationActivityChanged(_:)),
            name: .relayApplicationActivityChanged,
            object: nil
        )
    }

    deinit {
        presentationRecoveryTask?.cancel()
        focusRecoveryTask?.cancel()
        interactionPresentationTask?.cancel()
        nativeViewportRecoveryTask?.cancel()
        viewportCommitFallbackTask?.cancel()
        initialWidthRepaintTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func applicationActivityChanged(_ notification: Notification) {
        guard let allowed = notification.object as? Bool else { return }
        setApplicationRenderingAllowed(allowed)
    }

    /// Tests only: marks the terminal started on an injected transport, as
    /// startIfNeeded does after its viewport is ready, without connecting.
    /// Call before the view joins a window so no real transport starts.
    func startForTesting(transport: RelayRemoteTransport) {
        started = true
        io.installTransport(transport)
    }
    var ioForTesting: TerminalIOBridge { io }

    func startIfNeeded() {
        guard !started, let pane else { return }
        guard pane.profile.backend == .relay else {
            started = true
            return
        }
        if view.window != nil {
            let pixels = view.convertToBacking(view.bounds).size
            let surfacePixels = latestSurfaceGridMetrics.map {
                CGSize(width: CGFloat($0.widthPixels), height: CGFloat($0.heightPixels))
            }
            guard TerminalInitialViewportPolicy.isReady(
                surface: latestSurfaceViewport, confirmed: io.currentViewport,
                surfacePixels: surfacePixels, viewPixels: pixels
            ) else {
                awaitingInitialViewport = true
                TerminalReplayTrace.log("wait-viewport pane=\(pane.id.uuidString) surface=\(String(describing: latestSurfaceViewport)) io=\(io.currentViewport) pixels=\(String(describing: surfacePixels)) view=\(pixels)")
                return
            }
        }
        awaitingInitialViewport = false
        started = true

        let remote = RelayRemoteTransport()
        let artifactsEnabled = RelayPreferences.shared.showArtifactPreviews && !RelayLaunchMode.isSafeMode
        io.installTransport(remote)
        beginMeasuredRestore(reason: "launch")
        // Do not let the legacy 750 ms timer publish an empty grid during SSH
        // setup. The attached status selects the worker's actual boundary mode.
        io.setExplicitReplayBoundary(true)
        io.beginReplay()
        // Open the shared node connection while the cache is validated and
        // scanned. This reservation sends no pane hello, so live output cannot
        // arrive before the cache and its replay cursor are installed.
        let connectionPreparation = RelayNodeTransportPool.shared.attach(
            profile: pane.profile,
            sessionID: pane.id.uuidString.lowercased(),
            onReady: { _ in },
            onFrame: { _ in },
            onDisconnect: { _ in }
        )
        // start() replaces this reservation with the real subscription. Closing
        // the old channel is identity checked and cannot detach the new one.
        defer { connectionPreparation.close() }
        TerminalReplayTrace.log("connection-prepared pane=\(pane.id.uuidString)")
        let restoration = io.restoreSnapshot(paneID: pane.id)
        // A cursor without a renderable checkpoint cannot reconstruct an idle
        // shell. Ask the durable worker for its bounded screen history when the
        // saved viewport differs or the checkpoint contains only mode changes.
        let restoredSequence = TerminalSnapshotDisplayPolicy.initialReplaySequence(
            remoteSequence: restoration?.remoteSequence,
            rendered: restoration?.rendered == true
        )
        // Missing checkpoints need a repaint. Agent cache hits need one too:
        // their ANSI journal is provisional until the original TUI paints its
        // current frame at the final viewport, as on a manual reconnect.
        initialRestoreUsedCachedDisplay = restoration?.rendered == true
        authoritativeAttachRepaintRequested = false
        initialReplayDisplayCommitted = false
        initialReplayWritesResumed = false
        initialWidthRepaintCompleted = false
        initialWidthRepaintFailureEpoch = nil
        initialWidthRepaintPending = pane.kind.usesNativePromptEditing
        let forceAttachRepaint = TerminalSnapshotDisplayPolicy.requiresAttachRepaint(
            rendered: initialRestoreUsedCachedDisplay, isAgent: pane.kind != .shell
        )
        initialAuthoritativeRepaintPending = forceAttachRepaint
        if restoration?.rendered == true {
            // A snapshot may contain a partially composed command entered
            // before this Relay process existed. The rendered state is valid;
            // the local prompt mirror is not.
            view.remoteTerminalStateWasRestored()
            pane.showTerminalSnapshot()
        }
        let io = self.io
        let artifactCoalescer = self.artifactCoalescer
        let artifactCoordinator = self.artifactCoordinator
        let artifactProfile = pane.profile
        remote.start(
            profile: pane.profile,
            sessionID: pane.id.uuidString.lowercased(),
            parentSessionID: pane.remoteParentSessionID,
            workspaceSessionID: pane.remoteWorkspaceSessionID,
            tabID: pane.remoteTabID,
            paneTitle: pane.displayName,
            contentKind: pane.contentKind.rawValue,
            // A requested start directory applies only when relayd creates the worker.
            workingDirectory: pane.requestedStartDirectory,
            requiresExistingWorker: pane.requiresExistingWorker || reconnectRequiresExistingWorker,
            initialLastSequence: restoredSequence,
            // Retained v1 workers repaint an unchanged attach by briefly
            // changing rows. Keep replay on one grid and request the final
            // viewport repaint after its parser and geometry have settled.
            forceAttachRepaint: false,
            onOutput: { [weak self, weak remote, weak io] data, sequence, deliveryEpoch in
                autoreleasepool {
                    guard let remote, let io, remote.isCurrentDeliveryEpoch(deliveryEpoch) else { return }
                    // Linkify the 4 ms display batch in TerminalIOBridge, not
                    // every small SSH frame. This keeps clickable paths while
                    // avoiding repeated UTF-8 scans during TUI repaint bursts.
                    let isLiveOutput = io.receive(data, remoteSequence: sequence, sourceTransport: remote)
                    // Historical replay is compacted once when caught_up arrives.
                    // Decoding and scanning every replay packet here both repeats
                    // work and can stop the shared node reader long enough for
                    // later pane handshakes to fall back to dedicated SSH streams.
                    guard isLiveOutput, remote.isCurrentDeliveryEpoch(deliveryEpoch) else { return }
                    guard let text = String(data: data, encoding: .utf8) else { return }
                    if artifactsEnabled {
                        artifactCoalescer.ingest(text, deliveryEpoch: deliveryEpoch) { [weak self, weak remote, weak io] batch in
                            guard let remote, let io, io.isCurrentTransport(remote, deliveryEpoch: deliveryEpoch) else { return }
                            for path in artifactCoordinator.discover(in: batch) {
                                Task { @Sendable [weak self, weak remote, weak io] in
                                    // Modern workers put a structured artifact frame
                                    // directly after this output. Give it priority and
                                    // only open a separate SSH fetch for older workers.
                                    try? await Task.sleep(for: .milliseconds(150))
                                    guard let remote, let io, io.isCurrentTransport(remote, deliveryEpoch: deliveryEpoch),
                                          artifactCoordinator.beginFallback(for: path) else { return }
                                    guard let data = try? await RemoteArtifactLoader.load(path: path, profile: artifactProfile),
                                          artifactCoordinator.acceptFallback(for: path) else { return }
                                    await MainActor.run { [weak self] in
                                        guard let self, io.isCurrentTransport(remote, deliveryEpoch: deliveryEpoch) else { return }
                                        // The TUI owns its cursor and cell layout. A host file
                                        // fetch cannot reserve image rows inside that layout.
                                        self.presentArtifact(path: path, data: data)
                                    }
                                }
                            }
                        }
                    }
                    self?.activityCoalescer.ingest(text, deliveryEpoch: deliveryEpoch) { [weak self, weak remote, weak io] batch in
                        Task { @MainActor [weak self, weak remote, weak io] in
                            guard let self, let remote, let io, io.isCurrentTransport(remote, deliveryEpoch: deliveryEpoch),
                                  let pane = self.pane else { return }
                            pane.received(batch)
                            self.agentKindDidChange(pane.kind)
                        }
                    }
                }
            },
            onStatus: { [weak self, weak remote, weak io] status, deliveryEpoch in
                guard let remote, let io, remote.isCurrentDeliveryEpoch(deliveryEpoch) else { return }
                let statusReceivedAt = TerminalReplayTrace.enabled ? ProcessInfo.processInfo.systemUptime : 0
                TerminalReplayTrace.log("status-received pane=\(pane.id.uuidString) state=\(status.state) message=\(status.message ?? "")")
                // Gate reconstruction on the ordered transport callback, before
                // the next byte frame. MainActor can be busy resizing windows;
                // scheduling this there lets replay bytes enter the live path
                // and can reset an already-prepared replay a second time.
                guard io.performForTransport(remote, {
                    if status.state == "reconnecting" || status.state == "waiting_for_network" {
                        io.beginReplay()
                    }
                    if status.outputReset { io.resetRemoteSequence() }
                    if status.state == "attached" || status.state == "read_only" {
                        // Current workers emit an authoritative caught_up marker
                        // after replay. Do not let the legacy timeout start feeding
                        // reconstruction packets into Ghostty before that marker.
                        io.setExplicitReplayBoundary(status.capabilities.contains("event_cursor_v1"))
                        io.setProgramStatusReplyOwnership(status.capabilities.contains("program_status_reply_v1"))
                    }
                }) else { return }
                RelayDiagnostics.shared.record(category: "pane", name: status.state, details: [
                    "pane_id": pane.id.uuidString.lowercased(),
                    "profile": pane.profile.name,
                    "message": status.message ?? "",
                ])
                Task { @MainActor [weak self, weak remote, weak io] in
                    guard let self, let remote, let io, io.isCurrentTransport(remote, deliveryEpoch: deliveryEpoch) else { return }
                    if TerminalReplayTrace.enabled {
                        TerminalReplayTrace.log("status-main pane=\(pane.id.uuidString) state=\(status.state) queueSeconds=\(ProcessInfo.processInfo.systemUptime - statusReceivedAt)")
                    }
                    self.pane?.applyProgramStatus(status, deliveryEpoch: deliveryEpoch)
                    if status.state == "program_status" { return }
                    if let clientCount = status.clientCount {
                        self.pane?.recordRemoteClientCount(clientCount)
                    }
                    if status.state == "attached" || status.state == "read_only" {
                        // Modern workers provide authoritative process, hook,
                        // and transcript events. Legacy text parsing also
                        // sleeps whenever Relay is not interactive.
                        self.legacyActivityHeuristicsEnabled =
                            !status.capabilities.contains("event_cursor_v1")
                        self.workerProvidesTerminalModeState = status.capabilities.contains(
                            LegacyTerminalModeCompatibility.durableCapability
                        )
                        self.terminalWorkerCapabilitiesKnown = true
                        self.terminalReplayCaughtUp = false
                        self.initialReplayDisplayCommitted = false
                        self.initialReplayWritesResumed = false
                        self.legacyTerminalModeCompatibilityApplied = false
                        self.updateBackgroundTextWork()
                    }
                    if status.state == "attached" {
                        self.pane?.terminalInputTransportMessage = nil
                        if status.outputReset { self.initialAuthoritativeRepaintPending = true }
                        self.pane?.beginTerminalRestore()
                        self.pane?.connected()
                    } else if status.state == "caught_up" {
                        self.terminalReplayCaughtUp = true
                        self.applyLegacyTerminalModeCompatibilityIfNeeded()
                        self.io.endReplayAfterViewportSettle()
                        self.requestInitialRepaintIfReady()
                    } else if status.state == "reconnecting" {
                        self.pane?.terminalInputTransportMessage = "This pane is reconnecting. Typing will resume when its connection is ready."
                        self.terminalReplayCaughtUp = false
                        self.terminalWorkerCapabilitiesKnown = false
                        self.view.remoteTerminalStateWasRestored()
                        self.beginMeasuredRestore(reason: "reconnect")
                        self.pane?.connectionInterrupted(status.message ?? "Reconnecting")
                    } else if status.state == "waiting_for_network" {
                        self.pane?.terminalInputTransportMessage = "This pane's host is unavailable. Relay is retrying the connection."
                        self.terminalReplayCaughtUp = false
                        self.terminalWorkerCapabilitiesKnown = false
                        self.view.remoteTerminalStateWasRestored()
                        self.beginMeasuredRestore(reason: "network-recovery")
                        self.pane?.waitingForNetwork(status.message ?? "VPN or network route unavailable. Retrying automatically.")
                    } else if status.state == "read_only" {
                        self.pane?.terminalInputTransportMessage = "Another client controls input for this pane. Relay is retrying input ownership automatically."
                        self.pane?.connectionInterrupted(status.message ?? "Another client controls this pane.")
                    } else if status.state == "exited" {
                        self.io.endReplay()
                        // Keep Ghostty as a renderer. Host-managed exits do not
                        // have exec lifecycle metadata, so forwarding finish()
                        // makes Ghostty present its generic "failed to launch"
                        // screen. Relay owns this lifecycle and renders a native
                        // ended-session overlay with an explicit restart action.
                        self.pane?.exited(exitCode: status.exitCode ?? 0)
                    } else if status.state == "error" {
                        self.io.endReplay()
                        let message = status.message ?? "Remote session error"
                        self.io.receive(Data("\r\n\u{001B}[38;2;255;139;120mRelay: \(message)\u{001B}[0m\r\n".utf8))
                        self.pane?.disconnected(message)
                    } else if status.state == "input_dropped" {
                        let message = status.message ?? "Some offline input was not queued."
                        self.io.receive(Data("\r\n\u{001B}[38;2;255;184;108mRelay: \(message)\u{001B}[0m\r\n".utf8))
                    }
                }
            },
            onAgentEvent: { [weak self, weak remote, weak io] data, deliveryEpoch in
                Task { @MainActor [weak self, weak remote, weak io] in
                    guard let self, let remote, let io, io.isCurrentTransport(remote, deliveryEpoch: deliveryEpoch),
                          let pane = self.pane else { return }
                    pane.receivedAgentEvent(data)
                    self.agentKindDidChange(pane.kind)
                    remote.acknowledgeAgentEvent(data, deliveryEpoch: deliveryEpoch)
                }
            },
            onArtifact: { [weak self, weak remote, weak io] artifact, deliveryEpoch in
                guard let self, let remote, let io, io.isCurrentTransport(remote, deliveryEpoch: deliveryEpoch) else { return }
                guard artifactsEnabled else { return }
                guard artifactCoordinator.acceptStructured(for: artifact.path) else { return }
                Task { @MainActor [weak self, weak remote, weak io] in
                    guard let self, let remote, let io, io.isCurrentTransport(remote, deliveryEpoch: deliveryEpoch) else { return }
                    self.presentArtifact(path: artifact.path, data: artifact.data)
                }
            },
            onDisconnect: { [weak self, weak remote, weak io] message, deliveryEpoch in
                Task { @MainActor [weak self, weak remote, weak io] in
                    guard let self, let remote, let io, io.isCurrentTransport(remote, deliveryEpoch: deliveryEpoch) else { return }
                    self.io.endReplay()
                    self.io.receive(Data("\r\n\u{001B}[38;2;255;139;120mRelay connection: \(message)\u{001B}[0m\r\n".utf8))
                    self.pane?.disconnected(message)
                }
            }
        )
    }

    /// Agent lifecycle events and terminal replay are independent ordered
    /// streams. Either may identify readiness first, so compatibility is
    /// committed only after both have arrived instead of relying on startup
    /// timing.
    func agentKindDidChange(_ kind: AgentKind) {
        if kind.usesNativePromptEditing, !initialWidthRepaintCompleted,
           initialWidthRepaintTask == nil {
            initialWidthRepaintPending = true
            initialAuthoritativeRepaintPending = true
            requestInitialRepaintIfReady()
        }
        // Discovery may identify an exec-replaced shell after its first hello.
        // That timing cannot turn a cached agent frame into a final restore.
        if kind != .shell, initialRestoreUsedCachedDisplay, !authoritativeAttachRepaintRequested {
            initialAuthoritativeRepaintPending = true
            requestInitialRepaintIfReady()
        }
        applyLegacyTerminalModeCompatibilityIfNeeded(agentKind: kind)
    }

    private func requestInitialRepaintIfReady() {
        guard initialAuthoritativeRepaintPending, terminalWorkerCapabilitiesKnown,
              terminalReplayCaughtUp, initialReplayDisplayCommitted, initialReplayWritesResumed,
              allowsRendering, presentationAttachment.isPresented, view.window != nil,
              !explicitGeometryTransitionPending, pendingViewportCommitEpoch == nil,
              initialWidthRepaintTask == nil else { return }
        if initialWidthRepaintPending {
            // A route without the input lease drops resizes, so the attempt
            // could only time out and lock this presentation out of its
            // repaint. The lease-granted attach's caught_up calls back here.
            guard io.routeAcceptsViewportRepaint else { return }
            // A failed attempt belongs to its presentation. Retry only after
            // a new tab/window/geometry presentation, not on each output burst.
            guard initialWidthRepaintFailureEpoch != viewportPresentationEpoch else { return }
            if beginInitialWidthRepaint() {
                initialAuthoritativeRepaintPending = false
                authoritativeAttachRepaintRequested = true
                initialWidthRepaintPending = false
            }
            return
        }
        commitStableViewport()
    }

    /// Claude and Codex keep a diff buffer across SIGWINCH. A one-column change makes
    /// it redraw while Ghostty parses each frame on that same actual grid.
    /// The existing inspection surface withholds the temporary frame.
    private func beginInitialWidthRepaint() -> Bool {
        let original = io.currentViewport
        guard original.columns > 0, original.columns < 4_098 else { return false }
        let wide = RelayViewport(columns: original.columns + 1, rows: original.rows)
        let originalBounds = view.bounds.size
        let attemptEpoch = viewportPresentationEpoch
        let nativeResizes = session.nativeResizeEvents()
        let (events, continuation) = AsyncStream<InitialWidthRepaintEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(16)
        )
        io.beginObservedViewportResize()
        guard view.beginViewportInspection(columns: Int(wide.columns)) else {
            io.resumeAutomaticViewportResizes()
            continuation.finish()
            return false
        }
        initialWidthRepaintEvents = continuation
        RelayDiagnostics.shared.record(category: "snapshot", name: "agent-width-repaint-started",
            details: ["pane_id": pane?.id.uuidString.lowercased() ?? "unknown",
                      "columns": String(original.columns), "rows": String(original.rows)])
        initialWidthRepaintTask = Task { @MainActor [weak self] in
            guard let self else { continuation.finish(); return }
            let native = Task { @MainActor in
                for await viewport in nativeResizes {
                    guard !Task.isCancelled else { break }
                    continuation.yield(.viewport(viewport))
                }
            }
            let deadline = Task { @MainActor in
                do { try await Task.sleep(for: .seconds(8)) } catch { return }
                continuation.yield(.timeout)
            }
            var restoring = false
            var frameID: UUID?
            var succeeded = false
            defer {
                native.cancel()
                deadline.cancel()
                continuation.finish()
                self.initialWidthRepaintEvents = nil
                self.io.cancelObservedRepaint()
                self.view.restoreViewportAfterInspection()
                self.view.finishViewportInspection()
                self.io.resumeAutomaticViewportResizes()
                self.view.synchronizeAndRedraw()
                self.initialWidthRepaintTask = nil
                if succeeded {
                    self.initialWidthRepaintFailureEpoch = nil
                } else {
                    // Hiding a tab while its frame is in flight must not spend
                    // the repaint permanently. Its next presentation owes it.
                    self.initialWidthRepaintPending = true
                    self.initialAuthoritativeRepaintPending = true
                    self.initialWidthRepaintFailureEpoch = attemptEpoch
                    if self.viewportPresentationEpoch != attemptEpoch {
                        Task { @MainActor [weak self] in
                            await Task.yield()
                            self?.requestInitialRepaintIfReady()
                        }
                    }
                }
                RelayDiagnostics.shared.record(category: "snapshot",
                    name: succeeded ? "agent-width-repaint-completed" : "agent-width-repaint-incomplete",
                    details: ["pane_id": self.pane?.id.uuidString.lowercased() ?? "unknown"])
            }
            for await event in events {
                guard !Task.isCancelled, self.started, self.presentationAttachment.isPresented,
                      self.view.window != nil, self.view.bounds.size == originalBounds else { return }
                switch event {
                case .viewport(let viewport):
                    let target = restoring ? original : wide
                    guard frameID == nil, viewport.columns == target.columns,
                          viewport.rows == target.rows, self.io.currentViewport == target else { continue }
                    let id = UUID()
                    frameID = id
                    self.io.requestObservedViewportRepaint(id: id)
                case .frame(let id):
                    guard id == frameID else { continue }
                    if restoring {
                        succeeded = true
                        self.initialWidthRepaintCompleted = true
                        return
                    }
                    restoring = true
                    frameID = nil
                    self.io.beginObservedViewportResize()
                    self.view.restoreViewportAfterInspection()
                case .timeout:
                    return
                }
            }
        }
        return true
    }

    private func applyLegacyTerminalModeCompatibilityIfNeeded(agentKind: AgentKind? = nil) {
        guard terminalWorkerCapabilitiesKnown,
              terminalReplayCaughtUp,
              !legacyTerminalModeCompatibilityApplied,
              let agentKind = agentKind ?? pane?.kind,
              let prelude = LegacyTerminalModeCompatibility.prelude(
                  agentKind: agentKind,
                  capabilities: workerProvidesTerminalModeState
                      ? [LegacyTerminalModeCompatibility.durableCapability]
                      : []
              ) else { return }
        legacyTerminalModeCompatibilityApplied = true
        _ = io.receive(prelude, remoteSequence: 0)
    }

    func stop() {
        initialWidthRepaintTask?.cancel()
        initialWidthRepaintEvents?.finish()
        fileTransferTask?.cancel()
        fileTransferTask = nil
        io.finishViewportTransition(rows: latestSurfaceViewport?.rows ?? 0)
        io.flushSnapshot()
        io.endReplay()
        io.removeTransport()?.detach()
        started = false
    }

    /// Attaches a restored pane whose tab has not been shown, at the grid its
    /// snapshot log was saved at. An unattached view has no surface, so
    /// nothing resizes until a window lays it out. A pane in a window is left
    /// to its presentation path.
    func startInBackground(viewport: RelayViewport) {
        guard !started, let pane, pane.profile.backend == .relay, pane.contentKind == .terminal,
              view.window == nil else { return }
        io.seedInitialViewport(viewport)
        startIfNeeded()
    }

    func restart() {
        io.removeTransport()?.detach()
        started = false
        pane?.reconnecting()
        startIfNeeded()
    }

    /// Catalog recovery may replace the viewer route, never its remote shell.
    func reconnectRetainedPane() {
        guard pane?.profile.backend == .relay else { return }
        reconnectRequiresExistingWorker = true
        restart()
    }

    func focus() {
        guard keyboardFocusEligible else { return }
        pendingFocusOnPresentation = true
        // A mounted terminal should take keyboard ownership synchronously.
        // Waiting only for the recovery task leaves a visible interval where
        // AppKit can keep the previously selected pane as first responder,
        // especially while several surfaces are restoring at once. Keep the
        // delayed claims as a SwiftUI reparenting fallback, but do not make
        // normal input wait for them.
        _ = claimKeyboardFocus()
        scheduleFocusRecovery()
    }

    fileprivate var canReceiveKeyboardFocus: Bool {
        keyboardFocusEligible && presentationAttachment.isPresented && view.relaySurfaceIsVisible
    }

    /// The notice names the exits that exist in the current hold. Escape never
    /// discards: only the pane menu's Discard Preserved Input does.
    fileprivate func notePreservedTyping(inspectionActive: Bool, files: Bool) {
        pane?.terminalInputDraftMessage = Self.preservedTypingNotice(inspectionActive: inspectionActive, files: files)
    }

    static func preservedTypingNotice(inspectionActive: Bool, files: Bool) -> String {
        if files {
            return "Your text and files are kept. Use Copy Preserved Text or Copy Preserved Files in the pane menu, or Discard Preserved Input."
        }
        if inspectionActive {
            return "Relay is checking the draft. Your text is kept. Press Escape to stop the check and resume typing; held keys are not sent, use Copy Preserved Text in the pane menu."
        }
        return "Typing is paused: Relay could not verify the draft. Your text is kept. Press Escape to resume typing; held keys are not sent, use Copy Preserved Text in the pane menu."
    }

    fileprivate func clearPreservedTypingNotice() { pane?.terminalInputDraftMessage = nil }

    func setKeyboardFocusEligible(_ eligible: Bool) {
        guard keyboardFocusEligible != eligible else { return }
        keyboardFocusEligible = eligible
        guard !eligible else { return }
        pendingFocusOnPresentation = false
        focusRecoveryTask?.cancel()
        focusRecoveryTask = nil
    }

    private func claimKeyboardFocus() -> Bool {
        let success = view.acquireProgrammaticFocus() || (view.window?.makeFirstResponder(view) ?? false)
        recordInputDiagnostic("focus-claim", details: ["success": String(success),
            "eligible": String(keyboardFocusEligible), "presented": String(presentationAttachment.isPresented),
            "surface_visible": String(view.relaySurfaceIsVisible), "window_key": String(view.window?.isKeyWindow == true),
            "app_active": String(NSApp.isActive), "sheet_active": String(view.window?.attachedSheet != nil)])
        return success
    }

    private func scheduleFocusRecovery() {
        focusRecoveryTask?.cancel()
        guard pendingFocusOnPresentation, keyboardFocusEligible else { return }
        let intentGeneration = focusIntentGeneration
        focusRecoveryTask = Task { @MainActor [weak self] in
            // SwiftUI can reset first responder at the end of the same update
            // that mounts an NSViewRepresentable. Claim it after that update,
            // with bounded retries for a busy multi-pane restore.
            for delay in [24, 64, 128] {
                try? await Task.sleep(for: .milliseconds(delay))
                guard !Task.isCancelled, let self,
                      self.pendingFocusOnPresentation,
                      self.focusIntentGeneration == intentGeneration,
                      self.keyboardFocusEligible,
                      self.presentationAttachment.isPresented,
                      self.view.window != nil else { continue }
                if self.claimKeyboardFocus() {
                    self.pendingFocusOnPresentation = false
                    self.focusRecoveryTask = nil
                    return
                }
            }
            self?.focusRecoveryTask = nil
        }
    }

    /// A deliberate click into sibling workspace chrome supersedes delayed
    /// terminal recovery. It does not change the active pane or PTY owner.
    func cancelFocusRecoveryForExternalFocus() {
        focusIntentGeneration &+= 1
        pendingFocusOnPresentation = false
        focusRecoveryTask?.cancel()
        focusRecoveryTask = nil
    }

    @discardableResult
    func jumpToPrompt(by offset: Int16) -> Bool {
        view.jumpToPrompt(by: offset)
    }

    /// A durable Ghostty NSView is reparented when SwiftUI changes tabs, zoom,
    /// or floating layout. Representable teardown and creation can overlap, so
    /// an unordered lease set lets a stale coordinator hide the newly attached
    /// view. Only the newest attachment generation may present or dismantle it.
    func beginPresentationAttachment(lease: UUID) -> UInt64 {
        presentationAttachment.begin(lease: lease)
    }

    func setPresented(
        _ presented: Bool,
        lease: UUID,
        generation: UInt64,
        force: Bool = false
    ) {
        let changed = presentationAttachment.isPresented != presented
        guard presentationAttachment.setPresented(
            presented, lease: lease, generation: generation
        ) else { return }
        // Closing a recovery sheet can leave the app-wide occlusion sample in
        // its background state without a new activation notification. A newly
        // attached pane is direct evidence that the active workspace is visible;
        // refresh the shared gate before deciding whether to pause its display.
        if presented,
           let window = view.window,
           window.isVisible,
           !window.isMiniaturized,
           !NSApp.isHidden {
            RelayApplicationActivityState.setApplicationVisible(true)
        }
        if !TerminalEnergyPolicy.pausesPresentation(
            isPresented: presented,
            applicationVisible: allowsRendering
        ) {
            io.setPresentationPaused(false)
        } else {
            io.setPresentationPaused(true)
        }
        if changed || force {
            // Occluding the surface releases Ghostty's shared display-link.
            // The ordered PTY stream continues into the live parser.
            let visible = TerminalEnergyPolicy.showsSurface(
                isPresented: presented,
                applicationVisible: allowsRendering
            )
            view.setSurfaceVisible(visible)
            // Visibility must precede the redraw. Ghostty does not publish a
            // new IOSurface for an invisible idle terminal, so redrawing first
            // left restored panes transparent until an unrelated resize.
            if visible {
                view.synchronizeAndRedraw()
                // The retained IOSurface is valid immediately. A later stable
                // geometry sample replaces it atomically, but the user should
                // never wait on a black cover just to revisit a tab.
                if pendingViewportCommitEpoch == nil && presentationRecoveryTask == nil {
                    view.alphaValue = 1
                }
                if pendingFocusOnPresentation { scheduleFocusRecovery() }
            }
        }
    }

    func endPresentationAttachment(lease: UUID, generation: UInt64) {
        guard presentationAttachment.end(lease: lease, generation: generation) else { return }
        focusRecoveryTask?.cancel()
        focusRecoveryTask = nil
        // Preserve the retained terminal grid while detached. AppKit removes
        // the view from a window; subsequent PTY bytes accumulate as an
        // ordered delta without mutating that grid's input state.
        finishHiddenGeometryTransitionIfNeeded()
        // A detached tab does not need Ghostty to parse and render every
        // remote repaint. Continue consuming the transport into the bounded
        // snapshot and delta, then catch the retained grid up once when this
        // pane is shown again. This removes renderer bursts that could delay
        // keyboard echo in the active pane.
        io.setPresentationPaused(true)
    }

    /// SwiftUI can remove a pane while AppKit's final resize settle is still
    /// pending. A hidden pane has no surface to reveal, but its ordered PTY
    /// stream must leave the viewport transaction and continue accumulating in
    /// the paused snapshot path for its next attachment.
    private func finishHiddenGeometryTransitionIfNeeded() {
        guard explicitGeometryTransitionPending ||
                pendingViewportCommitEpoch != nil ||
                viewportCommitFallbackTask != nil ||
                presentationRecoveryTask != nil
        else { return }
        abandonGeometryTransition()
    }

    /// A transaction begun without a following frame change or re-host has no
    /// settle callback to end it: `setFrameSize` never runs, so nothing commits,
    /// and the ordered PTY stream stays in the transition buffer while the pane
    /// looks frozen or blank until an unrelated resize. Re-checked once after
    /// the layout turn that follows `beginExplicitGeometryTransition`. A real
    /// geometry change has by then either started a newer transaction through
    /// `setFrameSize` (new epoch) or moved this view's frame, and a dismantle
    /// has already cleared the flag. Anything else is abandoned here.
    private func abandonGeometryTransitionIfUnchanged(epoch: UInt64, frameSize: CGSize) {
        guard explicitGeometryTransitionPending,
              viewportPresentationEpoch == epoch,
              pendingViewportCommitEpoch == nil,
              presentationRecoveryTask == nil
        else { return }
        let current = view.frame.size
        let frameMoved = abs(current.width - frameSize.width) >= 0.5 ||
            abs(current.height - frameSize.height) >= 0.5
        // A detached view has no settle path at all; an attached one that
        // moved will be committed by its own settle callback.
        guard view.window == nil || !frameMoved else { return }
        abandonGeometryTransition()
    }

    /// Leave the viewport transaction without a remote commit. Buffered PTY
    /// bytes are released verbatim into the ordinary (paused or live) display
    /// path: no resize is sent, no repaint is requested, nothing is cleared.
    private func abandonGeometryTransition() {
        viewportPresentationEpoch &+= 1
        if viewportPresentationEpoch == 0 { viewportPresentationEpoch = 1 }
        explicitGeometryTransitionPending = false
        pendingViewportCommitGeneration = nil
        pendingViewportCommitEpoch = nil
        pendingExplicitViewportTarget = nil
        viewportCommitFallbackTask?.cancel()
        viewportCommitFallbackTask = nil
        presentationRecoveryTask?.cancel()
        presentationRecoveryTask = nil
        view.setResizeThrottle(milliseconds: nil)
        view.setResizeSynchronizationSuspended(false)
        io.finishViewportTransition(rows: latestSurfaceViewport?.rows ?? 0)
    }

    private func setApplicationRenderingAllowed(_ allowed: Bool) {
        guard allowsRendering != allowed else { return }
        allowsRendering = allowed
        updateBackgroundTextWork()
        guard started else { return }
        let isPresented = presentationAttachment.isPresented
        // Backgrounding suppresses optional intelligence/link scanning and
        // Metal presentation, but keeps terminal protocol state current.
        io.setPresentationPaused(
            TerminalEnergyPolicy.pausesPresentation(
                isPresented: isPresented,
                applicationVisible: allowed
            )
        )
        let surfaceVisible = TerminalEnergyPolicy.showsSurface(
            isPresented: isPresented,
            applicationVisible: allowed
        )
        view.setSurfaceVisible(surfaceVisible)
        guard surfaceVisible, view.window != nil else { return }

        // AppKit can report a transient negative frame while a full-screen
        // Space is becoming active. Remote panes must not fit their Ghostty
        // surface in that interval: doing so leaves the current grid blank or
        // offset until an unrelated tab switch. The bounded recovery below
        // samples stable geometry, reclaims the remote viewport, and redraws.
        if pane?.profile.backend == .relay {
            reclaimNativeViewportOwnership()
            return
        }
        view.layoutSubtreeIfNeeded()
        prepareFinalSurfaceMeasurement()
        fitForStableViewportCommit()
        view.synchronizeAndRedraw()
        view.alphaValue = 1
    }

    /// Input delivery is stronger evidence of interactivity than a possibly
    /// stale occlusion notification during full-screen and Space transitions.
    /// Wake the ordered display path before forwarding the input so its remote
    /// echo can be rendered. Synthetic/background input receives only a short
    /// lease; genuine app interaction updates the shared visibility state and
    /// remains awake until the normal resign/occlusion notification.
    fileprivate func prepareForUserInteraction() {
        interactionPresentationTask?.cancel()
        interactionPresentationTask = nil
        let windowIsInteractive = NSApp.isActive &&
            view.window?.isVisible == true &&
            view.window?.isMiniaturized == false
        if windowIsInteractive {
            RelayApplicationActivityState.setApplicationVisible(true)
            setApplicationRenderingAllowed(true)
            return
        }

        setApplicationRenderingAllowed(true)
        interactionPresentationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1_500))
            guard !Task.isCancelled, let self else { return }
            if !RelayApplicationActivityState.allowsContinuousUpdates {
                self.setApplicationRenderingAllowed(false)
            }
            self.interactionPresentationTask = nil
        }
    }

    private func updateBackgroundTextWork() {
        artifactCoalescer.setEnabled(allowsRendering)
        activityCoalescer.setEnabled(allowsRendering && legacyActivityHeuristicsEnabled)
    }

    func beginExplicitGeometryTransition() {
        viewportPresentationEpoch &+= 1
        if viewportPresentationEpoch == 0 { viewportPresentationEpoch = 1 }
        explicitGeometryTransitionPending = true
        if pane?.profile.backend == .relay {
            view.setResizeSynchronizationSuspended(true)
        }
        // Reflow changes the number of wrapped rows in a primary-screen agent
        // transcript. Preserving its raw scrollbar offset can land on an empty
        // region and make the composer appear to have vanished after zoom or
        // restore. Agent panes therefore return to their live composer; an
        // ordinary shell keeps the user's deliberate scrollback position.
        revealLatestAfterGeometryTransition = viewportIsAtBottom || pane?.kind != .shell
        pendingViewportCommitGeneration = nil
        pendingViewportCommitEpoch = nil
        pendingExplicitViewportTarget = nil
        viewportCommitFallbackTask?.cancel()
        viewportCommitFallbackTask = nil
        presentationRecoveryTask?.cancel()
        presentationRecoveryTask = nil
        // Keep PTY output out of Ghostty while AppKit is changing the cell
        // grid. The remote viewport commit below is the presentation barrier:
        // once its SIGWINCH repaint has reached Relay, the complete replacement
        // is delivered to Ghostty as one ordered batch. Feeding live TUI deltas
        // into intermediate grids is what left Codex, Claude, and htop with
        // stale columns after zoom, tab, and divider transitions.
        if pane?.profile.backend == .relay {
            io.beginViewportTransition()
        }
        // Coalesce AppKit's animation frames locally. The settling callback
        // switches to synchronous measurement only for the final fit, avoiding
        // a Ghostty resize/render for every full-screen or divider frame.
        view.setResizeThrottle(milliseconds: 16)
        // Bound the transaction to the geometry change that justifies it. See
        // abandonGeometryTransitionIfUnchanged: this is a one-shot lifecycle
        // check after the next layout turn, not a redraw timer.
        let epoch = viewportPresentationEpoch
        let frameSize = view.frame.size
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.abandonGeometryTransitionIfUnchanged(epoch: epoch, frameSize: frameSize)
        }
    }

    /// Test hooks: a viewport transaction is open from
    /// `beginExplicitGeometryTransition` until geometry settles, the view is
    /// dismantled, or the transaction is abandoned for lack of a geometry change.
    var isGeometryTransitionPending: Bool { explicitGeometryTransitionPending }
    var isBufferingViewportTransition: Bool { io.isViewportTransitionActive }

    fileprivate func prepareFinalSurfaceMeasurement() {
        guard explicitGeometryTransitionPending else { return }
        view.setResizeThrottle(milliseconds: 0)
    }

    /// Fit the parser before asking the application to repaint. Remote TUIs
    /// may query terminal state during resize; keeping the old grid until a
    /// guessed complete frame arrives creates a circular dependency.
    fileprivate func fitForStableViewportCommit() {
        view.setResizeSynchronizationSuspended(false)
        view.fitToSize()
        guard pane?.profile.backend == .relay,
              let metrics = latestSurfaceGridMetrics,
              let scale = view.window?.backingScaleFactor else { return }
        pendingExplicitViewportTarget = TerminalViewportGeometry.measuredViewport(
            metrics,
            bounds: view.bounds.size,
            backingScaleFactor: scale
        )
    }

    /// NSView frame changes are the authoritative signal that a presented
    /// remote terminal is moving to a different grid. Treat the whole resize
    /// as one viewport transaction even when it originated in macOS full
    /// screen or SwiftUI layout rather than Relay's pane controls.
    fileprivate func beginSurfaceGeometryTransition() {
        guard started,
              pane?.profile.backend == .relay,
              presentationAttachment.isPresented
        else { return }
        beginExplicitGeometryTransition()
    }

    @discardableResult
    fileprivate func commitStableViewport() -> TerminalStableViewportCommit {
        let explicit = explicitGeometryTransitionPending
        explicitGeometryTransitionPending = false
        let repaintRestoredScreen = initialAuthoritativeRepaintPending &&
            !initialWidthRepaintPending && initialReplayWritesResumed &&
            terminalWorkerCapabilitiesKnown && terminalReplayCaughtUp && initialReplayDisplayCommitted
        // InMemoryTerminalSession reports the new grid synchronously during
        // fitToSize(). The public surface delegate follows asynchronously and
        // may still describe the outgoing layout here; never overwrite the
        // backend's fresh viewport with that stale delegate value.
        let committedViewport = explicit ? pendingExplicitViewportTarget : nil
        let waitsForRemoteFrame = explicit && pane?.profile.backend == .relay
        let epoch = viewportPresentationEpoch
        if waitsForRemoteFrame {
            pendingViewportCommitEpoch = epoch
            io.armViewportFrameBarrier(rows: committedViewport?.rows ?? io.currentViewport.rows)
        }
        let generation = io.flushPendingResize(
            viewport: committedViewport,
            forceRepaint: explicit || repaintRestoredScreen,
            compatibilityRepaintPulse: (explicit || repaintRestoredScreen) &&
                (pane?.kind != .shell || io.isAlternateScreenActive)
        )
        if repaintRestoredScreen {
            initialAuthoritativeRepaintPending = false
            authoritativeAttachRepaintRequested = true
        }
        if explicit, pane?.profile.backend == .relay {
            // Return subsequent live frame changes to the surface policy once
            // the one-shot destination measurement has been committed.
            view.setResizeThrottle(milliseconds: nil)
        }
        if waitsForRemoteFrame {
            pendingViewportCommitGeneration = generation
            if pane?.kind == .shell && !io.isAlternateScreenActive {
                // Ordinary shell output rarely paints a full screen.
                scheduleUnacknowledgedViewportSettle(epoch: epoch)
            } else if let generation {
                scheduleViewportCommitFallback(generation, epoch: epoch)
            } else {
                scheduleUnacknowledgedViewportSettle(epoch: epoch)
            }
        }
        if initialWidthRepaintPending { requestInitialRepaintIfReady() }
        return TerminalStableViewportCommit(
            explicit: explicit,
            remoteGeneration: generation,
            presentationEpoch: viewportPresentationEpoch
        )
    }

    @discardableResult
    fileprivate func finishStableGeometryTransition(
        _ commit: TerminalStableViewportCommit
    ) -> Bool {
        if commit.explicit,
           pane?.profile.backend == .relay {
            // The outgoing IOSurface stays visible while the remote repaint is
            // in flight. The ordered output path publishes the replacement
            // only after it observes a complete destination-sized frame, so
            // this path has no black cover and no partial redraw.
            return false
        }
        view.synchronizeAndRedraw()
        return true
    }

    private func finishPresentationResume() {
        guard allowsRendering,
              presentationAttachment.isPresented,
              view.window != nil else { return }
        view.layoutSubtreeIfNeeded()
        prepareFinalSurfaceMeasurement()
        fitForStableViewportCommit()
        let commit = commitStableViewport()
        if finishStableGeometryTransition(commit) {
            view.setSurfaceVisible(true)
            view.synchronizeAndRedraw()
            view.alphaValue = 1
        }
        requestInitialRepaintIfReady()
    }

    private func viewportDidCommit(_ generation: UInt64) {
        guard generation == pendingViewportCommitGeneration,
              let epoch = pendingViewportCommitEpoch,
              epoch == viewportPresentationEpoch else { return }
        // The ACK confirms PTY geometry, not that the application has painted
        // the destination grid. Keep the previous IOSurface published until
        // the ordered output path observes a complete replacement frame.
        pendingViewportCommitGeneration = nil
    }

    private func viewportFrameDidBecomeReady() {
        guard let epoch = pendingViewportCommitEpoch,
              epoch == viewportPresentationEpoch else { return }
        viewportCommitFallbackTask?.cancel()
        viewportCommitFallbackTask = nil
        pendingViewportCommitGeneration = nil
        pendingViewportCommitEpoch = nil
        finishViewportPresentation(
            revealLatest: revealLatestAfterGeometryTransition,
            epoch: epoch
        )
    }

    private func scheduleViewportCommitFallback(_ generation: UInt64, epoch: UInt64) {
        viewportCommitFallbackTask?.cancel()
        viewportCommitFallbackTask = Task { @MainActor [weak self] in
            // A frame may be absent even after an ACK (idle app, old worker,
            // or interrupted repaint). The bounded fallback cannot claim
            // a complete frame, but must eventually release ordered output.
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled,
                  let self,
                  self.pendingViewportCommitEpoch == epoch,
                  self.viewportPresentationEpoch == epoch else { return }
            self.pendingViewportCommitGeneration = nil
            self.pendingViewportCommitEpoch = nil
            self.viewportCommitFallbackTask = nil
            RelayDiagnostics.shared.record(
                category: "performance",
                name: "viewport-commit-fallback",
                details: [
                    "pane_id": self.pane?.id.uuidString.lowercased() ?? "unknown",
                    "generation": String(generation),
                ]
            )
            self.finishViewportPresentation(
                revealLatest: self.revealLatestAfterGeometryTransition,
                epoch: epoch
            )
        }
    }

    /// Older workers acknowledge ordinary resize implicitly through their PTY
    /// stream. Hold the local atomic transaction for one bounded repaint
    /// window; a new geometry change cancels this task and starts a newer one.
    private func scheduleUnacknowledgedViewportSettle(epoch: UInt64) {
        viewportCommitFallbackTask?.cancel()
        viewportCommitFallbackTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let waitsForApplicationFrame = self.pane?.kind != .shell ||
                self.io.isAlternateScreenActive
            try? await Task.sleep(
                for: .milliseconds(waitsForApplicationFrame ? 5_000 : 250)
            )
            guard !Task.isCancelled,
                  self.viewportPresentationEpoch == epoch else { return }
            self.pendingViewportCommitEpoch = nil
            self.viewportCommitFallbackTask = nil
            self.finishViewportPresentation(
                revealLatest: self.revealLatestAfterGeometryTransition,
                epoch: epoch
            )
        }
    }

    private func finishViewportPresentation(revealLatest: Bool, epoch: UInt64) {
        guard epoch == viewportPresentationEpoch else { return }
        let rows = pendingExplicitViewportTarget?.rows ?? latestSurfaceViewport?.rows ?? 0
        presentationRecoveryTask?.cancel()
        presentationRecoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Mutate Ghostty's grid only when its matching remote repaint is
            // ready to be delivered in the same ordered presentation turn.
            self.view.layoutSubtreeIfNeeded()
            self.view.setResizeSynchronizationSuspended(false)
            self.view.fitToSize()
            await withCheckedContinuation { continuation in
                self.io.finishViewportTransition(rows: rows) {
                    continuation.resume()
                }
            }
            guard !Task.isCancelled,
                  self.viewportPresentationEpoch == epoch else { return }
            guard self.view.window != nil else {
                self.presentationRecoveryTask = nil
                return
            }
            self.view.setSurfaceVisible(self.presentationAttachment.isPresented)
            self.recoverPresentation(revealLatest: revealLatest, epoch: epoch)
        }
    }

    private func recoverPresentation(revealLatest: Bool, epoch: UInt64) {
        guard viewportPresentationEpoch == epoch else { return }
        presentationRecoveryTask = nil
        guard view.window != nil else { return }
        pendingExplicitViewportTarget = nil
        // TerminalIOBridge has crossed both ordered display queues and waited
        // for Ghostty to parse the complete replacement. One render is enough;
        // retry loops made every resize feel sluggish and could race a newer
        // geometry generation.
        view.layoutSubtreeIfNeeded()
        view.synchronizeAndRedraw()
        if revealLatest {
            _ = view.performBindingAction("scroll_to_bottom")
            _ = view.scrollToRow(UInt.max)
        }
        view.alphaValue = 1
        requestInitialRepaintIfReady()
    }


    private func beginMeasuredRestore(reason: String) {
        if restoreStartedAt == nil {
            restoreStartedAt = DispatchTime.now().uptimeNanoseconds
            restoreReason = reason
        }
        pane?.beginTerminalRestore()
    }

    private func finishMeasuredRestore() {
        guard let startedAt = restoreStartedAt else { return }
        restoreStartedAt = nil
        let elapsed = DispatchTime.now().uptimeNanoseconds &- startedAt
        RelayDiagnostics.shared.record(category: "performance", name: "terminal-restore", details: [
            "pane_id": pane?.id.uuidString.lowercased() ?? "unknown",
            "reason": restoreReason,
            "milliseconds": String(format: "%.2f", Double(elapsed) / 1_000_000),
        ])
    }

    private func makeView() -> RelayGhosttyView {
        let terminal = RelayGhosttyView(frame: .zero)
        terminal.owner = self
        terminal.delegate = self
        if let pane, pane.profile.backend == .relay {
            terminal.configuration = TerminalSurfaceOptions(
                backend: .inMemory(session),
                context: .window,
                resizeThrottleMilliseconds: 16
            )
        } else {
            var environment = RelayTerminfo.sessionEnvironment
            environment["RELAY_PANE_ID"] = pane?.id.uuidString ?? ""
            environment["COLORTERM"] = "truecolor"
            environment["TERM_PROGRAM"] = "relay"
            terminal.configuration = TerminalSurfaceOptions(
                backend: .exec,
                envVars: environment,
                command: directCommand(),
                waitAfterCommand: true,
                context: .window
            )
        }
        // Ghostty creates a surface as soon as a controller is installed on
        // an attached view. Set the backend first so a remote pane never
        // transiently launches and tears down the default exec surface.
        terminal.controller = Self.controller
        terminal.setAccessibilityElement(true)
        terminal.setAccessibilityLabel("Terminal for \(pane?.profile.name ?? "session")")
        return terminal
    }

    fileprivate func terminalGridGeometry(
        backingScaleFactor: CGFloat
    ) -> (cellSize: CGSize, columns: Int)? {
        guard let metrics = latestSurfaceGridMetrics,
              backingScaleFactor.isFinite, backingScaleFactor > 0,
              metrics.columns > 0,
              metrics.cellWidthPixels > 0, metrics.cellHeightPixels > 0
        else { return nil }
        let cellSize = CGSize(
            width: CGFloat(metrics.cellWidthPixels) / backingScaleFactor,
            height: CGFloat(metrics.cellHeightPixels) / backingScaleFactor
        )
        guard cellSize.width.isFinite, cellSize.height.isFinite,
              cellSize.width > 0, cellSize.height > 0
        else { return nil }
        return (cellSize, Int(metrics.columns))
    }

    fileprivate func terminalRenderedSurfaceSizePixels() -> CGSize? {
        guard let metrics = latestSurfaceGridMetrics,
              metrics.widthPixels > 0, metrics.heightPixels > 0
        else { return nil }
        return CGSize(
            width: CGFloat(metrics.widthPixels),
            height: CGFloat(metrics.heightPixels)
        )
    }

    fileprivate var promptCursorPlacementAllowed: Bool {
        TerminalPromptSelectionEdit.allowsCursorPlacement(
            geometryIsStable: viewportIsAtBottom &&
                !explicitGeometryTransitionPending &&
                pendingViewportCommitEpoch == nil &&
                presentationRecoveryTask == nil,
            alternateScreenIsActive: io.isAlternateScreenActive,
            agentPrompt: forcesLocalPromptSelection
        )
    }

    fileprivate var agentPromptEditingAllowed: Bool {
        guard let pane, pane.kind != .shell else { return false }
        return pane.phase == .quiet || pane.phase == .needsInput
    }

    fileprivate var allowsRemotePromptVisualFallback: Bool {
        pane?.profile.backend == .relay
    }

    fileprivate var bracketedPasteIsActive: Bool {
        io.isBracketedPasteActive
    }

    fileprivate func performPromptControlTranslation(in view: AppTerminalView,
        expectedControlLease: RelayPromptEditorControlLease? = nil,
        actions: () -> Void) -> Bool {
        guard pane?.profile.backend == .relay else {
            actions()
            return true
        }
        let originalIO = io
        guard beginPromptControlTranslationCapture(expectedControlLease: expectedControlLease),
              let capture = originalIO.currentPromptControlCaptureIdentity else { return false }
        guard let translated = view.collectNativeInput(actions) else {
            originalIO.cancelPromptControlCapture(expectedCapture: capture)
            return false
        }
        guard originalIO.appendNativePromptControlInput(translated, expectedCapture: capture) else {
            originalIO.cancelPromptControlCapture(expectedCapture: capture)
            return false
        }
        return originalIO.endPromptControlCapture(expectedCapture: capture)
    }

    fileprivate func beginPromptControlTranslationCapture(expectedControlLease: RelayPromptEditorControlLease? = nil) -> Bool {
        guard pane?.profile.backend == .relay else { return false }
        guard let pane, let lease = io.promptEditorControlLease(paneID: pane.id,
            hostID: pane.profile.id, requireIdleInput: false),
              expectedControlLease == nil || expectedControlLease == lease else { return false }
        return io.beginPromptControlCapture(expectedControlLease: lease)
    }


    /// Read the existing renderer without attaching another client, scrolling,
    /// focusing, or resizing the user's terminal. This is a viewport only.
    func sidePanelViewportText() -> String? {
        guard pane?.contentKind == .terminal else { return nil }
        let text = pane?.profile.backend == .relay
            ? session.readViewportText()
            : view.readViewportText()
        guard let text else { return nil }
        return String(text.prefix(32_768))
    }

    /// Reopen this viewer's already attached worker route. A fresh provider can
    /// own a live PTY before it publishes an editable conversation binding.
    /// That binding protects prompt mutations; it is not a viewer-route lease.
    /// The transport checks its captured pane/channel, attached worker and live
    /// connection under its lock, and retries with requiresExistingWorker.
    @discardableResult
    func reconnectExistingPaneRoute() async -> Bool {
        guard let pane, pane.contentKind == .terminal,
              pane.profile.backend == .relay, pane.remoteExitCode == nil else { return false }
        let accepted = io.reconnectExistingPaneRoute()
        recordInputDiagnostic(accepted ? "pane-route-reconnect-requested" : "pane-route-reconnect-unavailable")
        return accepted
    }

    /// Tests only: replaces the host's prompt-owner-binding RPC.
    var promptOwnerBindingForTesting: (() async -> RelayPromptOwnerIdentity?)?

    fileprivate func readPromptOwnerBinding() async -> RelayPromptOwnerIdentity? {
        if let promptOwnerBindingForTesting { return await promptOwnerBindingForTesting() }
        guard let pane, pane.profile.backend == .relay else { return nil }
        let paneID = pane.id
        let hostID = pane.profile.id
        do {
            let command = RelayHostExecution.daemonCommand(profile: pane.profile,
                arguments: ["prompt-owner-binding", paneID.uuidString.lowercased()])
            let result = try await RelayHostExecution.capture(profile: pane.profile,
                command: command, timeout: 10, maximumBytes: 8 << 10)
            try Task.checkCancellation()
            guard self.pane?.id == paneID, self.pane?.profile.id == hostID,
                  result.exitCode == 0 else { return nil }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let binding = try decoder.decode(RelayPromptOwnerBinding.self, from: result.stdout)
            return binding.isValid(for: paneID) ? RelayPromptOwnerIdentity(hostID: hostID, binding: binding) : nil
        } catch { return nil }
    }

    var canConfigureHostRotation: Bool {
        guard let pane, pane.contentKind == .terminal, pane.profile.backend == .relay,
              conversationInputLease == nil else { return false }
        return io.promptEditorControlLease(paneID: pane.id, hostID: pane.profile.id, requireIdleInput: false) != nil
    }

    func readHostRotationStatus() async throws -> RelayHostRotationRPC.Status {
        guard let pane, pane.contentKind == .terminal, pane.profile.backend == .relay else {
            throw RelayHostRotationRPC.Failure.unavailable
        }
        let profile = pane.profile
        let result = try await RelayHostRotationRPC.send(.init(operation: .status),
            profile: profile, paneID: pane.id)
        guard self.pane === pane, pane.profile == profile else { throw RelayHostRotationRPC.Failure.changedConnection }
        return result
    }

    func configureHostRotation(enabled: Bool) async throws -> RelayHostRotationRPC.Status {
        guard let pane, pane.contentKind == .terminal, pane.profile.backend == .relay,
              conversationInputLease == nil,
              let lease = io.promptEditorControlLease(paneID: pane.id, hostID: pane.profile.id, requireIdleInput: false),
              let events = io.promptEditorLeaseEvents() else { throw RelayHostRotationRPC.Failure.unavailable }
        let profile = pane.profile
        let revision = pane.agentInputRevision
        let inputLease = UUID()
        conversationInputLease = inputLease
        defer { if conversationInputLease == inputLease { conversationInputLease = nil } }
        func currentLease(_ idle: Bool) -> RelayPromptEditorControlLease? {
            guard self.pane === pane, pane.profile == profile, pane.agentInputRevision == revision,
                  conversationInputLease == inputLease else { return nil }
            return io.promptEditorControlLease(paneID: pane.id, hostID: profile.id, requireIdleInput: idle)
        }
        try await RelayPromptEditorLeaseWaiter.wait(for: lease, events: events,
            identity: { currentLease(false) }, ready: { currentLease(enabled) })
        var request = RelayHostRotationRPC.Request(operation: enabled ? .enroll : .disable,
            id: RelayHostRotationRPC.newOperationID())
        if enabled {
            let candidate = try await RelayHostRotationRPC.readNativeCandidate(profile: profile, paneID: pane.id)
            let original = candidate.binding
            let directory = candidate.cwd
            let observed = try await RelayHostRotationRPC.readNativeBinding(profile: profile, paneID: pane.id)
            guard original == observed, currentLease(true) == lease else {
                throw RelayHostRotationRPC.Failure.changedConnection
            }
            request.sessionID = original.sessionID
            request.client = original.producer.provider
            request.cwd = directory
            request.agentPID = original.producer.processID
            request.agentStart = original.producer.processStart
        }
        return try await RelayHostRotationRPC.send(request, profile: profile, paneID: pane.id, lease: lease,
            currentLease: { currentLease(enabled) })
    }

    func readHostRotationTextStatus() async throws -> RelayHostRotationTextRPC.Status {
        guard let pane, pane.contentKind == .terminal, pane.profile.backend == .relay else {
            throw RelayHostRotationRPC.Failure.unavailable
        }
        let profile = pane.profile
        let request = RelayHostRotationTextRPC.Request(operation: .status)
        let data = try await RelayHostRotationTextRPC.send(request, profile: profile, paneID: pane.id)
        guard self.pane === pane, pane.profile == profile else { throw RelayHostRotationRPC.Failure.changedConnection }
        return try RelayHostRotationTextRPC.decode(data, request: request)
    }

    func configureHostRotationText(_ settings: RelayHostRotationTextRPC.Settings) async throws -> RelayHostRotationTextRPC.Status {
        let request = RelayHostRotationTextRPC.Request(operation: .configure,
            id: RelayHostRotationRPC.newOperationID(), settings: settings)
        let data = try await changeHostRotationText(request)
        return try RelayHostRotationTextRPC.decode(data, request: request)
    }

    func abandonHostRotationText(operationID: String) async throws -> RelayHostRotationTextRPC.Status {
        let request = RelayHostRotationTextRPC.Request(operation: .abandon, operationID: operationID)
        let data = try await changeHostRotationText(request)
        try RelayHostRotationTextRPC.decodeAbandon(data, operationID: operationID)
        return try await readHostRotationTextStatus()
    }

    func saveHostRotationCredential(reference: String, accountID: String, secret: String) async throws -> RelayHostRotationTextRPC.CredentialReceipt {
        let request = RelayHostRotationTextRPC.Request(operation: .credentialSave,
            credentialReference: reference, credentialSecret: secret, credentialAccountID: accountID)
        let data = try await changeHostRotationText(request)
        return try RelayHostRotationTextRPC.decodeCredential(data, reference: reference)
    }

    func deleteHostRotationCredential(reference: String) async throws -> RelayHostRotationTextRPC.CredentialReceipt {
        let request = RelayHostRotationTextRPC.Request(operation: .credentialDelete, credentialReference: reference)
        let data = try await changeHostRotationText(request)
        return try RelayHostRotationTextRPC.decodeCredential(data, reference: reference)
    }

    func readHostRotationCredential(reference: String) async throws -> RelayHostRotationTextRPC.CredentialReceipt {
        guard let pane, pane.contentKind == .terminal, pane.profile.backend == .relay else {
            throw RelayHostRotationRPC.Failure.unavailable
        }
        let profile = pane.profile
        let request = RelayHostRotationTextRPC.Request(operation: .credentialStatus, credentialReference: reference)
        let data = try await RelayHostRotationTextRPC.send(request, profile: profile, paneID: pane.id)
        guard self.pane === pane, pane.profile == profile else { throw RelayHostRotationRPC.Failure.changedConnection }
        return try RelayHostRotationTextRPC.decodeCredential(data, reference: reference)
    }

    func readHostRotationCredentials() async throws -> [RelayHostRotationTextRPC.CredentialRecord] {
        guard let pane, pane.contentKind == .terminal, pane.profile.backend == .relay else {
            throw RelayHostRotationRPC.Failure.unavailable
        }
        let profile = pane.profile
        let request = RelayHostRotationTextRPC.Request(operation: .credentialList)
        let data = try await RelayHostRotationTextRPC.send(request, profile: profile, paneID: pane.id)
        guard self.pane === pane, pane.profile == profile else { throw RelayHostRotationRPC.Failure.changedConnection }
        return try RelayHostRotationTextRPC.decodeCredentials(data)
    }

    private func changeHostRotationText(_ request: RelayHostRotationTextRPC.Request) async throws -> Data {
        guard let pane, pane.contentKind == .terminal, pane.profile.backend == .relay,
              conversationInputLease == nil,
              let lease = io.promptEditorControlLease(paneID: pane.id, hostID: pane.profile.id, requireIdleInput: false),
              let events = io.promptEditorLeaseEvents() else { throw RelayHostRotationRPC.Failure.unavailable }
        let profile = pane.profile
        let revision = pane.agentInputRevision
        let inputLease = UUID()
        conversationInputLease = inputLease
        defer { if conversationInputLease == inputLease { conversationInputLease = nil } }
        func currentLease() -> RelayPromptEditorControlLease? {
            guard self.pane === pane, pane.profile == profile, pane.agentInputRevision == revision,
                  conversationInputLease == inputLease else { return nil }
            return io.promptEditorControlLease(paneID: pane.id, hostID: profile.id, requireIdleInput: false)
        }
        try await RelayPromptEditorLeaseWaiter.wait(for: lease, events: events,
            identity: { currentLease() }, ready: { currentLease() })
        return try await RelayHostRotationTextRPC.send(request, profile: profile, paneID: pane.id,
            lease: lease, currentLease: { currentLease() })
    }

    fileprivate func promptEditorRequest(_ request: RelayPromptEditorRPC.Request, inputLease: UUID,
        expectedControlLease lease: RelayPromptEditorControlLease) async throws -> RelayPromptEditorRPC.Response {
        guard conversationInputLease == inputLease, let pane, let events = io.promptEditorLeaseEvents(),
              io.promptEditorControlLease(paneID: pane.id, hostID: pane.profile.id, requireIdleInput: false) == lease else {
            throw RelayPromptEditorRPC.Failure.changedConnection
        }
        let profile = pane.profile
        let revision = pane.agentInputRevision
        func currentLease(_ idle: Bool) -> RelayPromptEditorControlLease? {
            guard self.conversationInputLease == inputLease, self.pane === pane,
                  pane.profile == profile, pane.agentInputRevision == revision else { return nil }
            return io.promptEditorControlLease(paneID: pane.id, hostID: profile.id, requireIdleInput: idle)
        }
        try await RelayPromptEditorLeaseWaiter.wait(for: lease, events: events,
            identity: { currentLease(false) }, ready: { currentLease(true) })
        return try await RelayPromptEditorRPC.send(request, profile: profile, lease: lease) { [weak self, weak pane] in
            guard let self, let pane, self.conversationInputLease == inputLease,
                  self.pane === pane, pane.profile == profile,
                  pane.agentInputRevision == revision else { return nil }
            return self.io.promptEditorControlLease(paneID: pane.id, hostID: profile.id)
        }
    }

    fileprivate func promptInspectionControlLease(_ inputLease: UUID, requireIdleInput: Bool = true) -> RelayPromptEditorControlLease? {
        guard conversationInputLease == inputLease, let pane else { return nil }
        return io.promptEditorControlLease(paneID: pane.id, hostID: pane.profile.id, requireIdleInput: requireIdleInput)
    }

    fileprivate func triggerReadOnlyPromptEditor(inputLease: UUID,
        expectedControlLease lease: RelayPromptEditorControlLease) -> Bool {
        guard promptInspectionControlLease(inputLease) == lease else { return false }
        // The supported bridge is already armed. Ctrl+G opens the editor;
        // no Return or provider submission is part of this inspection.
        return io.sendPromptEditorControlInput(Data([0x07]), expectedControlLease: lease, automation: true)
    }

    fileprivate func beginPromptInspectionRestorationBarrier(inputLease: UUID,
        expectedControlLease lease: RelayPromptEditorControlLease) -> TerminalIOBridge.PromptEditorRestorationBarrier? {
        guard promptInspectionControlLease(inputLease) == lease else { return nil }
        return io.beginPromptEditorRestorationBarrier()
    }

    fileprivate func promptInspectionLeaseEvents(_ inputLease: UUID) -> AsyncStream<Void>? {
        guard conversationInputLease == inputLease else { return nil }
        return io.promptEditorLeaseEvents()
    }

    fileprivate func endPromptInspectionRestorationBarrier(_ id: UUID) {
        io.endPromptEditorRestorationBarrier(id)
    }

    /// The terminal input mirror observes actual keys/paste, not provider predictions.
    /// Unknown input after reconnect remains unavailable until an empty prompt or
    /// a submitted edit establishes a fresh boundary.
    func claudePromptPredictionHasEmptyInput() -> Bool {
        view.claudePromptPredictionHasEmptyInput()
    }

    @discardableResult
    func displayInlineArtifact(path: String, data: Data) -> Bool {
        let artifact = PaneArtifact(remotePath: path, data: data)
        guard pane?.contentKind == .terminal,
              artifact.isPDF || artifact.image != nil else { return false }
        // Native inline layout owns real space outside the terminal grid.
        // Do not synthesize cursor movement or Kitty placements into a live TUI.
        presentArtifact(path: path, data: data)
        return true
    }

    func refreshInlineRichContent() {
        guard let pane, pane.contentKind == .terminal, pane.profile.backend == .relay,
              let rows = session.readViewportRows(), let metrics = latestSurfaceGridMetrics,
              let window = view.window, metrics.rows > 0 else { return }
        let scale = window.backingScaleFactor
        guard scale > 0 else { return }
        let geometry = CGSize(width: CGFloat(metrics.cellWidthPixels) / scale,
                              height: CGFloat(metrics.cellHeightPixels) / scale)
        let regions = RelayInlineRichRegion.detect(rows: rows, cellSize: geometry,
                                                   columns: Int(metrics.columns))
        if regions != pane.inlineRichRegions { pane.inlineRichRegions = regions }
    }

    var conversationComposerOwnsFocus = false {
        didSet { if oldValue != conversationComposerOwnsFocus { nativeImageValidation?.yield(.validate) } }
    }
    private var nativeImageValidation: AsyncStream<NativeImageWakeup>.Continuation?
    private var conversationInputLease: UUID?
    /// Whether an inspection or conversation input operation holds the prompt.
    var holdsConversationInputLease: Bool { conversationInputLease != nil }

    fileprivate func acquirePromptInspectionInputLease() -> UUID? {
        guard conversationInputLease == nil else { return nil }
        let lease = UUID()
        conversationInputLease = lease
        return lease
    }

    fileprivate func releasePromptInspectionInputLease(_ lease: UUID) {
        guard conversationInputLease == lease else { return }
        conversationInputLease = nil
    }

    func accountForceScreenSnapshot() -> TerminalIOBridge.MaintenanceScreenSnapshot? {
        io.maintenanceScreenSnapshot()
    }

    func accountForceScreenIsCurrent(_ token: TerminalIOBridge.MaintenanceScreenToken) -> Bool {
        io.maintenanceScreenIsCurrent(token)
    }

    /// The account-force card is pinned to a rendered screen, pane profile and
    /// input revision. This lease excludes other Relay conversation-input
    /// operations. Physical input can still arrive; if it or the screen changes
    /// while the host request is in flight, the result is uncertain and the
    /// caller must not continue the account move.
    func withAccountForceLease(expectedPane: PaneModel, profile: ConnectionProfile, inputRevision: UInt64,
                               screen: TerminalIOBridge.MaintenanceScreenToken,
                               permits: @MainActor () -> Bool,
                               execute: @MainActor () async -> RelayAccountForceTransaction.Result) async -> RelayAccountForceTransaction.Result {
        guard pane === expectedPane, expectedPane.profile == profile,
              expectedPane.agentInputRevision == inputRevision, expectedPane.pendingAgentApprovals == 0,
              !view.promptInspectionBlocksExternalInput,
              let inputLease = acquirePromptInspectionInputLease() else { return .refused }
        defer { releasePromptInspectionInputLease(inputLease) }
        guard let control = promptInspectionControlLease(inputLease, requireIdleInput: false) else { return .refused }
        func current() -> Bool {
            pane === expectedPane && expectedPane.profile == profile &&
                expectedPane.agentInputRevision == inputRevision && expectedPane.pendingAgentApprovals == 0 &&
                promptInspectionControlLease(inputLease, requireIdleInput: false) == control &&
                io.maintenanceScreenIsCurrent(screen) && !view.promptInspectionBlocksExternalInput && permits()
        }
        guard current(), !Task.isCancelled else { return .refused }
        let result = await execute()
        return current() ? result : .unknown
    }

    /// A native submission owns the same original PTY for one synchronous write.
    /// The key conversation window excludes terminal keyboard/browser writers;
    /// companion prompt writers must also respect this lease.
    private func admitsConversationPrompt(_ text: String, paneID: UUID, rootPID: Int, control: RelayAgentConversationControl) -> Bool {
        guard let pane, pane.id == paneID,
              (pane.profile.kind == .local || pane.profile.backend == .relay), NSApp.isActive,
              (NSApp.keyWindow?.identifier?.rawValue == "relay.agent." + paneID.uuidString ||
               (conversationComposerOwnsFocus && NSApp.keyWindow === view.window)),
              control.permitsSend, control.binding.paneID == paneID,
              control.binding.hostID == pane.profile.id.uuidString,
              control.inputRevision == pane.agentInputRevision,
              control.observedAt > pane.agentLastInputAt, pane.pendingAgentApprovals == 0,
              pane.connectionState == .connected, io.isBracketedPasteActive,
              view.conversationPromptIsEmpty,
              conversationInputLease == nil,
              (pane.profile.kind != .local || Int(networkForegroundPID ?? 0) == rootPID),
              (pane.profile.backend != .relay || io.canSendSupervisorInterrupt),
              !text.utf8.contains(where: { $0 < 32 && $0 != 10 && $0 != 9 }),
              !text.utf8.contains(127) else { return false }
        return true
    }

    func sendConversationPrompt(_ text: String, paneID: UUID, rootPID: Int, control: RelayAgentConversationControl) -> Bool {
        guard admitsConversationPrompt(text, paneID: paneID, rootPID: rootPID, control: control) else { return false }
        conversationInputLease = UUID()
        defer { conversationInputLease = nil }
        return sendPromptTransport(text)
    }

    /// Native images must be ingested and acknowledged before the final Return.
    /// A partial delivery stays in the original composer and is never replayed.
    func sendConversationPrompt(_ text: String, imagePaths: [String], paneID: UUID,
        rootPID: Int, control: RelayAgentConversationControl,
        revalidate: @escaping @MainActor () async -> RelayAgentConversationControl?) async -> RelayNativeConversationSendResult {
        guard !imagePaths.isEmpty else {
            guard admitsConversationPrompt(text, paneID: paneID, rootPID: rootPID, control: control) else { return .notSent }
            return sendConversationPrompt(text, paneID: paneID, rootPID: rootPID, control: control) ? .submitted : .submissionUncertain
        }
        guard let pane, pane.id == paneID, imagePaths.count <= 32,
              imagePaths.allSatisfy({ RelayNativeImageComposer.quotedPath($0) != nil }),
              (pane.profile.kind == .local || pane.profile.backend == .relay),
              conversationInputLease == nil, control.permitsSend,
              control.binding.paneID == paneID, control.binding.hostID == pane.profile.id.uuidString,
              control.inputRevision == pane.agentInputRevision, control.observedAt > pane.agentLastInputAt,
              pane.pendingAgentApprovals == 0, pane.connectionState == .connected,
              io.isBracketedPasteActive, view.conversationPromptIsEmpty, promptEditingViewportIsLive,
              text.utf8.count <= 65536,
              !text.utf8.contains(where: { $0 < 32 && $0 != 10 && $0 != 9 }), !text.utf8.contains(127),
              RelayNativeImageComposer.acknowledges(0, provider: control.binding.provider,
                rows: session.readViewportRows() ?? []) else { return .notSent }
        let lease = UUID()
        let profile = pane.profile
        let binding = control.binding
        var expectedRevision = pane.agentInputRevision
        var staged = false
        conversationInputLease = lease
        defer { if conversationInputLease == lease { conversationInputLease = nil } }
        func locallyValid() -> Bool {
            nativeConversationImageInputIsCurrent(lease: lease, pane: pane, profile: profile,
                revision: expectedRevision, rootPID: rootPID)
        }
        let initialOwner = profile.backend == .relay ? await readPromptOwnerBinding() : nil
        if profile.backend == .relay {
            guard let initialOwner, !initialOwner.binding.isInputOnly,
                  initialOwner.binding.provider == binding.provider,
                  initialOwner.binding.processId == binding.processID,
                  "kernel:" + String(initialOwner.binding.processStart) == binding.processStart,
                  initialOwner.binding.sessionId == binding.sessionID else { return .notSent }
        }
        guard locallyValid(), let fresh = await revalidate(), fresh.binding == binding,
              fresh.permitsSend, locallyValid() else { return .notSent }
        for (index, path) in imagePaths.enumerated() {
            guard locallyValid(), let quoted = RelayNativeImageComposer.quotedPath(path) else {
                return staged ? .stagedOnly : .notSent
            }
            if profile.backend == .relay {
                guard await readPromptOwnerBinding() == initialOwner, locallyValid() else {
                    return staged ? .stagedOnly : .notSent
                }
            }
            let before = session.parsedHostOutputRevision
            let events = session.parsedHostOutputEvents()
            guard let payload = TerminalPastePayload.directPayload(for: quoted, bracketed: true) else {
                return staged ? .stagedOnly : .notSent
            }
            // After a write is attempted, transport failure cannot prove that
            // the provider received no bytes. Preserve the draft and block replay.
            staged = true
            if profile.backend == .relay {
                guard io.sendUserInput(Data(payload.utf8)) else { return .stagedOnly }
            } else {
                guard let local = TerminalPastePayload.rendererPayload(for: quoted, bracketed: true) else {
                    return staged ? .stagedOnly : .notSent
                }
                view.sendText(local)
            }
            staged = true
            view.unobservedPromptInput(); pane.userEnteredInput()
            expectedRevision = pane.agentInputRevision
            let count = index + 1
            let awaitedRevision = expectedRevision
            let acknowledged = await waitForNativeImageAcknowledgement(events: events, after: before,
                count: count, binding: binding, lease: lease, pane: pane, profile: profile,
                revision: awaitedRevision, rootPID: rootPID)
            guard acknowledged, locallyValid() else { return .stagedOnly }
        }
        guard locallyValid(), let final = await revalidate(), final.binding == binding,
              final.lifecycle == "quiet", Date().timeIntervalSince(final.checkedAt) < 5,
              locallyValid(), RelayNativeImageComposer.acknowledges(imagePaths.count,
                provider: binding.provider, rows: session.readViewportRows() ?? []) else { return .stagedOnly }
        if profile.backend == .relay {
            guard await readPromptOwnerBinding() == initialOwner, locallyValid() else { return .stagedOnly }
        }
        if !text.isEmpty {
            return sendPromptTransport(text) ? .submitted : .submissionUncertain
        }
        let sent = profile.backend == .relay ? io.sendUserInput(Data([13])) : view.performBindingAction("text:\\r")
        if sent { view.unobservedPromptInput(); pane.userEnteredInput(); noteProgrammaticInput("conversation_prompt", text) }
        return sent ? .submitted : .submissionUncertain
    }

    private enum NativeImageWakeup: Sendable { case output(UInt64), validate, deadline }

    private func waitForNativeImageAcknowledgement(events: AsyncStream<UInt64>, after: UInt64,
        count: Int, binding: RelayAgentConversationBinding, lease: UUID, pane: PaneModel,
        profile: ConnectionProfile, revision: UInt64, rootPID: Int) async -> Bool {
        let (wakeups, continuation) = AsyncStream<NativeImageWakeup>.makeStream(bufferingPolicy: .bufferingNewest(8))
        nativeImageValidation = continuation
        let output = Task { @MainActor in
            for await revision in events {
                if Task.isCancelled { break }
                continuation.yield(.output(revision))
            }
            continuation.finish()
        }
        let deadline = Task { @MainActor in
            try? await Task.sleep(for: .seconds(12))
            if !Task.isCancelled { continuation.yield(.deadline) }
        }
        let changes = pane.objectWillChange.sink { continuation.yield(.validate) }
        let focus = NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)
            .sink { _ in continuation.yield(.validate) }
        let app = NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
            .sink { _ in continuation.yield(.validate) }
        defer {
            nativeImageValidation = nil
            output.cancel(); deadline.cancel(); changes.cancel(); focus.cancel(); app.cancel()
            continuation.finish()
        }
        for await event in wakeups {
            guard nativeConversationImageInputIsCurrent(lease: lease, pane: pane, profile: profile,
                revision: revision, rootPID: rootPID) else { return false }
            switch event {
            case .deadline: return false
            case .validate:
                if session.parsedHostOutputRevision > after, RelayNativeImageComposer.acknowledges(count,
                    provider: binding.provider, rows: session.readViewportRows() ?? []) { return true }
            case .output(let observed):
                if observed > after, RelayNativeImageComposer.acknowledges(count,
                    provider: binding.provider, rows: session.readViewportRows() ?? []) { return true }
            }
        }
        return false
    }

    private func nativeConversationImageInputIsCurrent(lease: UUID, pane: PaneModel,
        profile: ConnectionProfile, revision: UInt64, rootPID: Int) -> Bool {
        !Task.isCancelled && conversationInputLease == lease && self.pane === pane &&
            pane.profile == profile && pane.agentInputRevision == revision &&
            pane.connectionState == .connected && pane.pendingAgentApprovals == 0 &&
            io.isBracketedPasteActive && promptEditingViewportIsLive && view.markedRange().location == NSNotFound && NSApp.isActive &&
            (NSApp.keyWindow?.identifier?.rawValue == "relay.agent." + pane.id.uuidString ||
                (conversationComposerOwnsFocus && NSApp.keyWindow === view.window)) &&
            (profile.kind != .local || Int(networkForegroundPID ?? 0) == rootPID) &&
            (profile.backend != .relay || io.canSendSupervisorInterrupt)
    }

    func interruptConversation(paneID: UUID, rootPID: Int, control: RelayAgentConversationControl) -> Bool {
        guard let pane, pane.id == paneID, NSApp.isActive,
              (pane.profile.kind == .local || pane.profile.backend == .relay),
              (NSApp.keyWindow?.identifier?.rawValue == "relay.agent." + paneID.uuidString ||
               NSApp.keyWindow === view.window),
              control.permitsInterrupt, control.binding.paneID == paneID,
              control.binding.hostID == pane.profile.id.uuidString,
              control.inputRevision == pane.agentInputRevision,
              pane.pendingAgentApprovals == 0, pane.connectionState == .connected,
              conversationInputLease == nil,
              (pane.profile.kind != .local || Int(networkForegroundPID ?? 0) == rootPID),
              (pane.profile.backend != .relay || io.canSendSupervisorInterrupt) else { return false }
        conversationInputLease = UUID()
        defer { conversationInputLease = nil }
        view.unobservedPromptInput()
        if pane.profile.backend == .relay { io.sendUserInput(Data([0x03])) }
        else { _ = view.performBindingAction("text:\\x03") }
        pane.userEnteredInput()
        return true
    }

    /// Sends a complete prompt from Relay's authenticated local companion.
    /// Newlines are preserved as line breaks but the final carriage return is
    /// the only submit action, matching a paste followed by Return.
    @discardableResult
    func sendSidePanelPrompt(_ text: String, maximumBytes: Int = 64 << 10) -> Bool {
        guard conversationInputLease == nil, !view.promptInspectionBlocksExternalInput else { return false }
        return sendPromptTransport(text, maximumBytes: maximumBytes)
    }

    /// Relay assistant input fence, using agent maintenance's empty-prompt
    /// proof (live screen, or the prepared screen for a hidden pane). Nil when
    /// the pane cannot be inspected; `empty` false means a draft or unknown.
    func assistantPromptProof() async -> RelayAssistantInputFence.Proof? {
        guard let pane, pane.contentKind == .terminal, pane.profile.backend == .relay,
              pane.connectionState == .connected else { return nil }
        await prepareAgentMaintenancePromptProof()
        guard self.pane === pane else { return nil }
        let observation = observeActiveScreen()
        return .init(empty: assistantPromptIsEmptyNow(observation), inputRevision: pane.agentInputRevision,
                     draft: assistantPromptHasTypedTextNow(observation))
    }

    /// Positive evidence only: a visible typed draft, as maintenance reads it.
    private func assistantPromptHasTypedTextNow(_ observation: RelayActiveScreenCache.Observation) -> Bool {
        guard let pane else { return false }
        if let composer = pane.composerStateIfCreated, !composer.draft.isEmpty || !composer.attachmentQueue.attachments.isEmpty {
            return true
        }
        switch pane.kind {
        case .claude, .codex: return agentMaintenanceTerminalPromptHasTypedText(observation)
        case .shell:
            return RelayAgentMaintenancePrompt.retainedShellHasTypedText(observation.screen)
        case .other: return false
        }
    }

    private func assistantPromptIsEmptyNow(_ observation: RelayActiveScreenCache.Observation) -> Bool {
        guard let pane, conversationInputLease == nil, !view.promptInspectionBlocksExternalInput else { return false }
        switch pane.kind {
        case .claude, .codex: return agentMaintenancePromptIsEmpty(observation, preservingComposerDraft: false)
        case .shell: return agentMaintenanceRetainedShellPromptIsEmpty(observation)
        case .other: return false
        }
    }

    /// Sends user-approved assistant text only if, at this moment, the input
    /// revision is the one shown on the card and the prompt is still provably
    /// empty. The check and the write happen under the conversation input
    /// lease with no suspension in between. A draft is never cleared or joined.
    func sendAssistantApprovedText(_ text: String, expectedInputRevision: UInt64) async -> RelayAssistantInputFence.Outcome {
        guard let pane, pane.connectionState == .connected else { return .unavailable }
        await prepareAgentMaintenancePromptProof()
        guard self.pane === pane, pane.connectionState == .connected else { return .unavailable }
        let observation = observeActiveScreen()
        let outcome = RelayAssistantInputFence.admit(expected: expectedInputRevision, current: pane.agentInputRevision,
                                                     empty: assistantPromptIsEmptyNow(observation),
                                                     draft: assistantPromptHasTypedTextNow(observation))
        guard outcome == .sent, conversationInputLease == nil else { return outcome == .sent ? .inputChanged : outcome }
        guard let fence = screenFence(observation) else { return .inputChanged }
        conversationInputLease = UUID()
        defer { conversationInputLease = nil }
        return sendPromptTransport(text, maximumBytes: 64 << 10, fence: fence) ? .sent : .unavailable
    }

    /// Autonomous assistant input uses a fresh owner binding and an observed,
    /// empty shell prompt. It cannot append to a draft or an agent composer.
    func sendAssistantShellCommand(_ text: String, authorization: @MainActor () -> Bool = { true },
                                   transport: AssistantShellTransport? = nil) async -> Bool {
        func promptIsEmpty() -> Bool {
            if let transport { return transport.promptIsEmpty() }
            return view.assistantShellPromptIsEmpty()
        }
        guard !Task.isCancelled, authorization(), let pane, pane.kind == .shell, pane.connectionState == .connected,
              pane.profile.backend == .relay, promptIsEmpty() else { return false }
        let revision = pane.agentInputRevision
        let owner: RelayPromptOwnerIdentity?
        if let transport { owner = await transport.readOwner() }
        else { owner = await readPromptOwnerBinding() }
        guard !Task.isCancelled, authorization(), RelayAssistantShellAdmission.allows(owner, paneID: pane.id, hostID: pane.profile.id),
              self.pane === pane, pane.kind == .shell,
              pane.agentInputRevision == revision, promptIsEmpty() else { return false }
        if let transport { return transport.send(text, 16 << 10) }
        return sendSidePanelPrompt(text, maximumBytes: 16 << 10)
    }


    /// Explicit user recovery of an ended provider in its retained Bash pane.
    /// Recheck the worker, shell, and foreground owner before clearing the
    /// corrupted shell draft and sending one ordered launch packet.
    func recoverCommandInRetainedShell(_ input: RelayShellRecoveryInput) async -> Bool {
        guard input.isValid, conversationInputLease == nil, let pane,
              pane.kind == .shell, pane.connectionState == .connected,
              pane.profile.backend == .relay else { return false }
        let identity = pane.id
        let revision = pane.agentInputRevision
        guard let command = RelayShellRecoveryProof.command(paneID: identity, input: input) else { return false }
        do {
            let result = try await RelayHostExecution.capture(profile: pane.profile, command: command,
                timeout: 10, maximumBytes: 4_096)
            guard result.exitCode == 0,
                  let proof = try JSONSerialization.jsonObject(with: result.stdout) as? [String: Any],
                  proof["verified"] as? Bool == true,
                  proof["pane_id"] as? String == identity.uuidString.lowercased(),
                  self.pane === pane, pane.id == identity, pane.kind == .shell,
                  pane.agentInputRevision == revision, pane.connectionState == .connected,
                  conversationInputLease == nil,
                  let payload = TerminalPastePayload.directPayload(for: input.text,
                      bracketed: io.isBracketedPasteActive) else { return false }
            // Ctrl-E then Ctrl-U clears the entire Bash Readline draft,
            // including text to the right of the cursor, outside paste framing.
            // Queue it with the launch command so no separate sender can
            // append this command to the old corrupted line.
            let packet = Data([0x05, 0x15]) + Data((payload + "\r").utf8)
            guard io.sendUserInput(packet) else { return false }
            view.unobservedPromptInput()
            pane.userEnteredInput()
            noteProgrammaticInput("shell_recovery", nil)
            return true
        } catch { return false }
    }

    func assistantShellPromptIsEmpty() -> Bool { view.assistantShellPromptIsEmpty() }

    /// The serialized active screen; see RelayActiveScreenCache. An unchanged
    /// screen is answered from memory, a changed one is dumped once.
    /// Each admission takes exactly one observation, after its last
    /// suspension, decides from it alone, and passes its fence to the send.
    private var activeScreenCache = RelayActiveScreenCache()
    var activeScreenDumpCount: Int { activeScreenCache.dumps }
    func observeActiveScreen() -> RelayActiveScreenCache.Observation {
        // Output received but not yet shown (an open replay or viewport
        // transition): refuse at admission as a changing screen, so callers
        // refuse before their pre-send step and can retry. Advisory only;
        // the send fence rechecks the phase under outputOrderingLock.
        if io.outputPhaseOpenNow {
            activeScreenCache.invalidate()
            return .unstable
        }
        let session = session
        let sample = activeScreenSampleForTesting ?? { session.activeScreenSample() }
        return activeScreenCache.read(sample: sample, dump: { session.readActiveScreenVT() })
    }
    /// Tests only: replaces the admission's in-memory sample. The send fence
    /// in TerminalIOBridge always samples the real session.
    var activeScreenSampleForTesting: (() -> RelayActiveScreenCache.Sample)?

    /// The hidden-pane replay proof. Used only when no native surface is
    /// attached; a live surface that is changing never falls back to it.
    private func currentPreparedPrompt(_ observation: RelayActiveScreenCache.Observation) -> PreparedMaintenancePrompt? {
        guard observation == .noSurface, let pane, let prepared = preparedMaintenancePrompt,
              prepared.inputRevision == pane.agentInputRevision, io.maintenanceScreenIsCurrent(prepared.token) else { return nil }
        return prepared
    }

    /// What the send must re-verify at the write: the admitted live screen,
    /// or for a pane with no surface the current replayed screen's token.
    /// There is no fence without one of them, so every automatic input needs
    /// a live key or a current replay token (nil = refuse): a changing live
    /// screen, or a hidden pane whose replayed screen was never read or has
    /// changed since, is refused before any other evidence counts.
    enum ScreenFence: Equatable {
        case live(RelayActiveScreenCache.Key)
        case replay(TerminalIOBridge.MaintenanceScreenToken)
        var live: RelayActiveScreenCache.Key? { if case .live(let key) = self { return key }; return nil }
        var replay: TerminalIOBridge.MaintenanceScreenToken? { if case .replay(let token) = self { return token }; return nil }
    }
    func screenFence(_ observation: RelayActiveScreenCache.Observation) -> ScreenFence? {
        switch observation {
        case .screen(_, let key): return .live(key)
        case .unstable: return nil
        case .noSurface: return currentPreparedPrompt(observation).map { .replay($0.token) }
        }
    }

    var agentMaintenancePromptIsEmpty: Bool { agentMaintenancePromptIsEmpty(preservingComposerDraft: false) }
    var agentMaintenanceTerminalPromptIsEmpty: Bool { agentMaintenancePromptIsEmpty(preservingComposerDraft: true) }
    /// `explainedAgents` is how many footer agents relayd's evidence accounts
    /// for (`RelayAgentMaintenancePolicy.explainedFooterAgents`); a larger
    /// footer agent count is running work.
    func agentMaintenancePromptIsEmpty(explainedAgents: Int) -> Bool {
        agentMaintenancePromptIsEmpty(preservingComposerDraft: false, explainedAgents: explainedAgents)
    }
    func agentMaintenanceTerminalPromptIsEmpty(explainedAgents: Int) -> Bool {
        agentMaintenancePromptIsEmpty(preservingComposerDraft: true, explainedAgents: explainedAgents)
    }

    /// Positive evidence of typed (non-placeholder) prompt text on the current
    /// screen. False also means "unknown"; it never authorizes a capture alone.
    var agentMaintenanceTerminalPromptHasTypedText: Bool { agentMaintenanceTerminalPromptHasTypedText(observeActiveScreen()) }

    private func agentMaintenanceTerminalPromptHasTypedText(_ observation: RelayActiveScreenCache.Observation) -> Bool {
        guard let pane, pane.profile.backend == .relay, pane.connectionState == .connected else { return false }
        let provider = pane.kind == .codex ? "codex" : "claude"
        switch observation {
        case .screen(let screen, _): return RelayAgentMaintenancePrompt.hasTypedText(screen, provider: provider)
        case .unstable: return false
        case .noSurface: return currentPreparedPrompt(observation)?.agentTyped ?? false
        }
    }

    /// Positive evidence that Claude's settings overlay, and nothing else,
    /// covers the prompt. False also means unknown.
    var agentMaintenanceClaudeSettingsOverlay: Bool { agentMaintenanceClaudeSettingsOverlay(observeActiveScreen()) }

    private func agentMaintenanceClaudeSettingsOverlay(_ observation: RelayActiveScreenCache.Observation) -> Bool {
        guard let pane, pane.kind != .codex, pane.profile.backend == .relay, pane.connectionState == .connected else { return false }
        switch observation {
        case .screen(let screen, _): return RelayAgentMaintenancePrompt.isClaudeSettingsOverlay(screen)
        case .unstable: return false
        case .noSurface: return currentPreparedPrompt(observation)?.claudeOverlay ?? false
        }
    }

    /// Why the terminal prompt could not be confirmed empty, for the pane's
    /// maintenance hold. Mirrors agentMaintenancePromptIsEmpty's checks in order.
    var agentMaintenanceTerminalPromptBlocker: String? { agentMaintenanceTerminalPromptBlocker(explainedAgents: 0) }

    func agentMaintenanceTerminalPromptBlocker(explainedAgents: Int) -> String? {
        agentMaintenanceTerminalPromptBlocker(observeActiveScreen(), explainedAgents: explainedAgents)
    }

    private func agentMaintenanceTerminalPromptBlocker(_ observation: RelayActiveScreenCache.Observation,
                                                       explainedAgents: Int) -> String? {
        guard let pane else { return "the pane closed" }
        let provider = pane.kind == .codex ? "codex" : "claude"
        for (passed, reason) in [
            (pane.profile.backend == .relay, "the pane is not a Relay terminal"),
            (pane.connectionState == .connected, "the pane is not connected"),
            // Agent monitoring marks a pane connected before its terminal
            // starts; that waits for the tab's first layout.
            (started, "the pane's terminal has not been opened since Relay started; select its tab once so its prompt can be read"),
            (pane.pendingAgentApprovals == 0, "an approval prompt is pending"),
            (conversationInputLease == nil, "another input operation holds the prompt"),
            ((pane.remoteClientCount ?? 1) <= 1, "\(pane.remoteClientCount ?? 0) viewers are attached"),
            (!view.promptInspectionBlocksExternalInput, "a prompt inspection is active"),
            (view.window == nil || promptEditingViewportIsLive, "the visible viewport is not live"),
            (io.isBracketedPasteActive, "the agent has not enabled bracketed paste"),
            (view.markedRange().location == NSNotFound, "text composition (IME) is in progress"),
        ] where !passed { return reason }
        if let composer = pane.composerStateIfCreated, composer.submitting || composer.nativeDeliveryHeld {
            return "the composer is delivering a prompt"
        }
        if observation == .unstable { return "the screen is changing, so its prompt cannot be read yet" }
        if let screen = observation.screen {
            if RelayAgentMaintenancePrompt.isEmpty(screen, provider: provider, explainedAgents: explainedAgents) { return nil }
            if let work = RelayAgentMaintenancePrompt.backgroundWork(screen, provider: provider, explainedAgents: explainedAgents) {
                if RelayAgentMaintenancePrompt.backgroundWork(screen, provider: provider, explainedAgents: .max) == nil {
                    return "the footer shows \(RelayAgentMaintenancePrompt.footerAgentCount(screen, provider: provider)) agent(s) but " +
                        "relayd accounts for \(explainedAgents): the pane's subagents, harness status or the host's background " +
                        "agent jobs are not verified (\(String(work.suffix(60))))"
                }
                return "the footer shows background work still running (\(String(work.suffix(60))))"
            }
            return "the screen's prompt or footer was not recognised"
        }
        guard preparedMaintenancePrompt != nil else { return "the hidden pane's screen has not been read" }
        guard let prepared = currentPreparedPrompt(observation) else { return "the hidden pane's screen reading is stale" }
        return prepared.empty(explainedAgents: explainedAgents) ? nil
            : "the hidden pane's prompt or footer was not recognised, or its footer agents are not accounted for"
    }

    private func agentMaintenancePromptIsEmpty(preservingComposerDraft: Bool, explainedAgents: Int = 0) -> Bool {
        agentMaintenancePromptIsEmpty(observeActiveScreen(), preservingComposerDraft: preservingComposerDraft,
                                      explainedAgents: explainedAgents)
    }

    private func agentMaintenancePromptIsEmpty(_ observation: RelayActiveScreenCache.Observation,
                                               preservingComposerDraft: Bool, explainedAgents: Int = 0) -> Bool {
        guard let pane, pane.profile.backend == .relay, pane.connectionState == .connected, started,
              pane.pendingAgentApprovals == 0, conversationInputLease == nil,
              (pane.remoteClientCount ?? 1) <= 1,
              !view.promptInspectionBlocksExternalInput,
              (view.window == nil || promptEditingViewportIsLive), io.isBracketedPasteActive,
              view.markedRange().location == NSNotFound else { return false }
        if let composer = pane.composerStateIfCreated {
            guard !composer.submitting, !composer.nativeDeliveryHeld,
                  preservingComposerDraft || composer.draft.isEmpty && composer.attachmentQueue.attachments.isEmpty else { return false }
        }
        switch observation {
        case .screen(let screen, _):
            return RelayAgentMaintenancePrompt.isEmpty(screen, provider: pane.kind == .codex ? "codex" : "claude",
                                                       explainedAgents: explainedAgents)
        case .unstable: return false
        case .noSurface: return currentPreparedPrompt(observation)?.empty(explainedAgents: explainedAgents) ?? false
        }
    }

    private struct PreparedMaintenancePrompt {
        let token: TerminalIOBridge.MaintenanceScreenToken
        let inputRevision: UInt64
        let agentEmpty: Bool
        /// Empty apart from the footer agent count, and that count.
        let agentEmptyIgnoringAgents: Bool
        let footerAgents: Int

        func empty(explainedAgents: Int) -> Bool {
            explainedAgents == 0 ? agentEmpty : agentEmptyIgnoringAgents && footerAgents <= explainedAgents
        }
        let agentTyped: Bool
        let shellEmpty: Bool
        var claudeOverlay = false
    }
    private var preparedMaintenancePrompt: PreparedMaintenancePrompt?

    /// Uses the provider's editor bridge to read exact bytes, including hard
    /// newlines and expanded pastes. No draft is inferred from a screen and no
    /// Return is sent. The caller must persist the backup before allowing a clear.
    func editAgentMaintenanceDraft(proof: RelayAgentMaintenanceProbe, inputRevision: UInt64,
        expected: Data?, replacement: Data?, beforeApply: (Data) throws -> Void = { _ in }) async throws -> Data {
        guard let pane else { throw RelayAgentMaintenanceDraftRefusal("the pane closed") }
        for (admitted, reason) in [
            (proof.valid(for: pane.id) && proof.owner != nil, "the native agent identity is not verified"),
            (proof.provider == "claude", "only Claude drafts can be captured exactly"),
            (proof.lifecycle == "quiet", "the agent is not idle"),
            (proof.backgroundWork == false, "background work is not verified absent"),
            (pane.agentInputRevision == inputRevision, "new input arrived"),
            (pane.connectionState == .connected, "the pane is not connected"),
            (pane.pendingAgentApprovals == 0, "an approval prompt is pending"),
            ((pane.remoteClientCount ?? 1) <= 1, "another Relay window is attached"),
            (!view.promptInspectionBlocksExternalInput, "a prompt inspection is already active"),
            (view.markedRange().location == NSNotFound, "text composition (IME) is in progress"),
            (io.isBracketedPasteActive, "the agent has not enabled bracketed paste"),
        ] where !admitted {
            throw RelayAgentMaintenanceDraftRefusal(reason)
        }
        guard let owner = proof.owner, let inputLease = acquirePromptInspectionInputLease() else {
            throw RelayAgentMaintenanceDraftRefusal("the terminal input lease is unavailable")
        }
        defer { releasePromptInspectionInputLease(inputLease) }
        let profile = pane.profile
        guard let control = promptInspectionControlLease(inputLease),
              await readPromptOwnerBinding()?.binding == owner else { throw RelayPromptEditorRPC.Failure.changedConnection }
        func current() -> Bool {
            self.pane === pane && pane.profile == profile && pane.agentInputRevision == inputRevision &&
            pane.pendingAgentApprovals == 0 && !Task.isCancelled &&
            promptInspectionControlLease(inputLease, requireIdleInput: false) == control
        }
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        func request(_ operation: RelayPromptEditorRPC.Operation) -> RelayPromptEditorRPC.Request {
            .init(operation: operation, id: id, owner: owner)
        }
        let armed = try await promptEditorRequest(request(.arm), inputLease: inputLease, expectedControlLease: control)
        guard current(), armed.state == .armed,
              triggerReadOnlyPromptEditor(inputLease: inputLease, expectedControlLease: control) else {
            throw RelayPromptEditorRPC.Failure.invalidResponse
        }
        let captured = try await promptEditorRequest(request(.snapshot), inputLease: inputLease, expectedControlLease: control)
        guard current(), captured.state == .captured, let text = captured.text,
              RelayAgentMaintenanceDraft.validText(text),
              let barrier = beginPromptInspectionRestorationBarrier(inputLease: inputLease, expectedControlLease: control) else {
            throw RelayPromptEditorRPC.Failure.invalidResponse
        }
        defer { endPromptInspectionRestorationBarrier(barrier.id) }
        var iterator = barrier.events.makeAsyncIterator()
        guard let event = await iterator.next(), case .armed = event, current() else {
            throw RelayPromptEditorRPC.Failure.changedConnection
        }
        // Cancellation restores the original text if admission or persistence
        // fails. Once a commit is attempted its uncertain outcome is never retried.
        do {
            guard expected == nil || text == expected else { throw RelayPromptEditorRPC.Failure.changedConnection }
            try beforeApply(text)
        } catch {
            _ = try? await promptEditorRequest(request(.cancel), inputLease: inputLease, expectedControlLease: control)
            throw error
        }
        if let replacement {
            guard RelayAgentMaintenanceDraft.validText(replacement), current() else { throw RelayPromptEditorRPC.Failure.invalidRequest }
            var commit = request(.commit); commit.digest = RelayPromptEditorRPC.digest(text); commit.text = replacement
            let committed = try await promptEditorRequest(commit, inputLease: inputLease, expectedControlLease: control)
            guard committed.state == .committed, current() else { throw RelayPromptEditorRPC.Failure.invalidResponse }
            var receipt = request(.receipt); receipt.digest = RelayPromptEditorRPC.digest(replacement)
            let applied = try await promptEditorRequest(receipt, inputLease: inputLease, expectedControlLease: control)
            guard applied.state == .applied, current() else { throw RelayPromptEditorRPC.Failure.invalidResponse }
        } else {
            let cancelled = try await promptEditorRequest(request(.cancel), inputLease: inputLease, expectedControlLease: control)
            guard cancelled.state == .cancelled, current() else { throw RelayPromptEditorRPC.Failure.invalidResponse }
        }
        let (wakeups, continuation) = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(2))
        let frames = Task { @MainActor in
            for await event in barrier.events {
                switch event {
                case .parsedFrame, .hostFrame: continuation.yield(true)
                case .invalidated: continuation.yield(false)
                case .armed: continue
                }
                break
            }
        }
        let timeout = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            continuation.yield(false)
        }
        defer { frames.cancel(); timeout.cancel(); continuation.finish() }
        var ready = wakeups.makeAsyncIterator()
        guard await ready.next() == true, current(), await readPromptOwnerBinding()?.binding == owner else {
            throw RelayPromptEditorRPC.Failure.changedConnection
        }
        preparedMaintenancePrompt = nil
        view.unobservedPromptInput()
        return text
    }

    /// Whether an explicit account move can read this pane's screen now:
    /// its live surface, or a complete replayed buffer for the hidden
    /// renderer. Nothing is started or attached here. A pane that has not been
    /// opened since Relay started has neither; attaching it headless would
    /// size its remote PTY to a default grid and still yield no complete
    /// screen (an idle agent never repaints in full until it is presented).
    /// The move presents the pane itself and polls this until it is nil.
    func accountMoveScreenRefusal() -> String? {
        guard let pane, pane.contentKind == .terminal, pane.profile.backend == .relay,
              pane.connectionState == .connected else { return "the pane is not connected" }
        if started {
            switch observeActiveScreen() {
            case .screen: return nil
            case .unstable: return "the screen of “\(pane.displayName)” is changing"
            case .noSurface: if io.maintenanceScreenSnapshot() != nil { return nil }
            }
        }
        return "Relay has no complete screen for “\(pane.displayName)” yet"
    }

    func prepareAgentMaintenancePromptProof() async {
        guard let pane, pane.profile.backend == .relay, pane.connectionState == .connected,
              observeActiveScreen() == .noSurface else { return }
        if let cached = preparedMaintenancePrompt,
           cached.inputRevision == pane.agentInputRevision, io.maintenanceScreenIsCurrent(cached.token) { return }
        preparedMaintenancePrompt = nil
        let revision = pane.agentInputRevision
        guard let snapshot = io.maintenanceScreenSnapshot(),
              let screen = await RelayAgentMaintenanceScreen.read(snapshot.data, viewport: snapshot.token.viewport),
              self.pane === pane, pane.agentInputRevision == revision,
              io.maintenanceScreenIsCurrent(snapshot.token) else { return }
        preparedMaintenancePrompt = PreparedMaintenancePrompt(token: snapshot.token, inputRevision: revision,
            agentEmpty: RelayAgentMaintenancePrompt.isEmpty(screen, provider: pane.kind == .codex ? "codex" : "claude"),
            agentEmptyIgnoringAgents: RelayAgentMaintenancePrompt.isEmpty(screen,
                provider: pane.kind == .codex ? "codex" : "claude", explainedAgents: .max),
            footerAgents: RelayAgentMaintenancePrompt.footerAgentCount(screen, provider: pane.kind == .codex ? "codex" : "claude"),
            agentTyped: RelayAgentMaintenancePrompt.hasTypedText(screen, provider: pane.kind == .codex ? "codex" : "claude"),
            shellEmpty: RelayAgentMaintenancePrompt.retainedShellIsEmpty(screen))
        preparedMaintenancePrompt?.claudeOverlay = pane.kind != .codex && RelayAgentMaintenancePrompt.isClaudeSettingsOverlay(screen)
    }

    /// Fixed native commands only. The model, terminal transcript and peer
    /// messages cannot supply maintenance input. Admission is tied to the
    /// original transport lease and a twice-checked native process proof.
    func sendAgentMaintenanceCommand(_ command: String, proof: RelayAgentMaintenanceProbe,
        inputRevision: UInt64, preservingComposerDraft: Bool = false) -> Bool {
        sendAgentMaintenanceCommandOutcome(command, proof: proof, inputRevision: inputRevision,
            preservingComposerDraft: preservingComposerDraft) == .sent
    }

    enum AgentMaintenanceSendOutcome: Equatable, Sendable {
        case sent
        /// Refused at admission, before any transport call, because a replay
        /// or viewport transition was open: nothing was typed.
        case outputPhaseOpen
        /// Any other refusal, including one at the write, which callers must
        /// not retry blindly.
        case refused
    }

    func sendAgentMaintenanceCommandOutcome(_ command: String, proof: RelayAgentMaintenanceProbe,
        inputRevision: UInt64, preservingComposerDraft: Bool = false) -> AgentMaintenanceSendOutcome {
        guard let pane else { return .refused }
        let observation = observeActiveScreen()
        if observation == .unstable, io.outputPhaseOpenNow { return .outputPhaseOpen }
        let empty = agentMaintenancePromptIsEmpty(observation, preservingComposerDraft: preservingComposerDraft,
            explainedAgents: RelayAgentMaintenancePolicy.explainedFooterAgents(proof, activeSubagents: pane.activeSubagents))
        guard proof.valid(for: pane.id), RelayAgentMaintenancePolicy.idleEvidence(proof, emptyPrompt: empty, hasDraft: false), proof.backgroundWork != true,
              proof.subagentWork != true,
              command == RelayAgentMaintenancePolicy.exitCommand(provider: proof.provider),
              pane.agentInputRevision == inputRevision,
              empty, let fence = screenFence(observation),
              let lease = io.promptEditorControlLease(paneID: pane.id, hostID: pane.profile.id),
              let payload = TerminalPastePayload.directPayload(for: command, bracketed: true) else { return .refused }
        conversationInputLease = UUID()
        defer { conversationInputLease = nil }
        let sent = io.sendPromptEditorControlInput(Data((payload + "\r").utf8), expectedControlLease: lease,
            expectedMaintenanceScreen: fence.replay, expectedLiveScreen: fence.live, automation: true)
        if sent { view.unobservedPromptInput(); pane.userEnteredInput(); noteProgrammaticInput("agent_maintenance", command) }
        return sent ? .sent : .refused
    }

    /// r3: the context rotation's send-time gates (RelayStockRotationPolicy.sendBlocker) over the live
    /// prompt, composer draft, approvals and input revision; nil when the input may be typed now.
    /// The prompt is judged on `observation` when given, so a sender gates and fences one screen;
    /// without one, the active screen is observed here.
    func contextRotationSendBlocker(_ text: String, kind: RelayContextRotationInput, proof: RelayAgentMaintenanceProbe,
        inputRevision: UInt64, observation: RelayActiveScreenCache.Observation? = nil) -> String? {
        guard let pane else { return "The pane is gone" }
        let empty = agentMaintenancePromptIsEmpty(observation ?? observeActiveScreen(), preservingComposerDraft: false,
            explainedAgents: RelayAgentMaintenancePolicy.explainedFooterAgents(proof, activeSubagents: pane.activeSubagents))
        return RelayStockRotationPolicy.sendBlocker(proof, paneID: pane.id, emptyPrompt: empty,
            hasDraft: pane.contextRotationDraftPending, pendingApprovals: pane.pendingAgentApprovals,
            inputRevision: pane.agentInputRevision, expectedRevision: inputRevision, text: text, kind: kind)
    }

    /// Context rotation's three inputs (capsule request, `/clear`, restore),
    /// under the same native proof, idle evidence, input-revision, empty-prompt
    /// and control-lease fences as a maintenance command. A composer draft is
    /// never preserved around it: any draft defers. Only text that
    /// RelayContextRotationPolicy admits for `kind` is typed.
    func sendContextRotationInput(_ text: String, kind: RelayContextRotationInput, proof: RelayAgentMaintenanceProbe,
        inputRevision: UInt64) -> Bool {
        guard let pane else { return false }
        let observation = observeActiveScreen()
        let empty = agentMaintenancePromptIsEmpty(observation, preservingComposerDraft: false,
            explainedAgents: RelayAgentMaintenancePolicy.explainedFooterAgents(proof, activeSubagents: pane.activeSubagents))
        guard contextRotationSendBlocker(text, kind: kind, proof: proof, inputRevision: inputRevision,
                                         observation: observation) == nil,
              proof.valid(for: pane.id), proof.bound == true,
              RelayAgentMaintenancePolicy.idleEvidence(proof, emptyPrompt: empty, hasDraft: false), proof.backgroundWork != true,
              proof.subagentWork != true, pane.pendingAgentApprovals == 0,
              RelayStockRotationPolicy.admits(text, kind: kind),
              pane.agentInputRevision == inputRevision,
              empty, let fence = screenFence(observation),
              let lease = io.promptEditorControlLease(paneID: pane.id, hostID: pane.profile.id),
              let payload = TerminalPastePayload.directPayload(for: text, bracketed: true) else { return false }
        conversationInputLease = UUID()
        defer { conversationInputLease = nil }
        let sent = io.sendPromptEditorControlInput(Data((payload + "\r").utf8), expectedControlLease: lease,
            expectedMaintenanceScreen: fence.replay, expectedLiveScreen: fence.live, automation: true)
        if sent { view.unobservedPromptInput(); pane.userEnteredInput(); noteProgrammaticInput("context_rotation", text) }
        return sent
    }

    /// One Esc that closes Claude's settings overlay, under the same native
    /// proof, input-revision and control-lease fences as a maintenance
    /// command. It is automation, like a draft edit: the pane's input
    /// revision is not advanced.
    func dismissClaudeSettingsOverlay(proof: RelayAgentMaintenanceProbe, inputRevision: UInt64) -> Bool {
        let observation = observeActiveScreen()
        guard let pane, proof.valid(for: pane.id), proof.provider == "claude", proof.lifecycle == "quiet",
              proof.backgroundWork != true, proof.subagentWork != true,
              pane.agentInputRevision == inputRevision, pane.pendingAgentApprovals == 0,
              conversationInputLease == nil, (pane.remoteClientCount ?? 1) <= 1,
              !view.promptInspectionBlocksExternalInput, view.markedRange().location == NSNotFound,
              agentMaintenanceClaudeSettingsOverlay(observation), let fence = screenFence(observation),
              let lease = io.promptEditorControlLease(paneID: pane.id, hostID: pane.profile.id) else { return false }
        conversationInputLease = UUID()
        defer { conversationInputLease = nil }
        let sent = io.sendPromptEditorControlInput(Data([0x1b]), expectedControlLease: lease,
            expectedMaintenanceScreen: fence.replay, expectedLiveScreen: fence.live, automation: true)
        if sent { preparedMaintenancePrompt = nil; view.unobservedPromptInput() }
        return sent
    }

    /// A changing live screen refuses before any other evidence is consulted.
    private func agentMaintenanceRetainedShellPromptIsEmpty(_ observation: RelayActiveScreenCache.Observation) -> Bool {
        guard observation != .unstable else { return false }
        return view.assistantShellPromptIsEmpty() ||
            // A hidden pane has no live prompt mirror. An OSC 133 shell that
            // has echoed nothing since its input-start mark has an empty line.
            (io.shellInputIsEmpty && view.markedRange().location == NSNotFound &&
             !view.promptInspectionBlocksExternalInput) ||
            (view.markedRange().location == NSNotFound && !view.promptInspectionBlocksExternalInput &&
             (RelayAgentMaintenancePrompt.retainedShellIsEmpty(observation.screen) ||
              currentPreparedPrompt(observation)?.shellEmpty == true))
    }

    func resumeAgentAfterMaintenance(_ command: String, original: RelayAgentMaintenanceProbe,
        inputRevision: UInt64, willSend: () throws -> Void) async throws -> Bool {
        await prepareAgentMaintenancePromptProof()
        let first = observeActiveScreen()
        guard let pane, original.valid(for: pane.id), ["claude", "codex"].contains(original.provider ?? ""),
              command == original.resumeCommand, command.utf8.count <= 8192,
              !command.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              pane.agentInputRevision == inputRevision, conversationInputLease == nil,
              pane.connectionState == .connected, (pane.remoteClientCount ?? 1) <= 1, agentMaintenanceRetainedShellPromptIsEmpty(first),
              !view.promptInspectionBlocksExternalInput else { return false }
        let profile = pane.profile
        let currentShell = await readPromptOwnerBinding()
        await prepareAgentMaintenancePromptProof()
        // The admitted observation is taken after the last suspension.
        let observation = observeActiveScreen()
        guard let shell = currentShell, let old = original.owner,
              shell.hostID == profile.id, shell.binding.provider == "shell",
              shell.binding.nodeBootId == old.nodeBootId,
              shell.binding.workerPid == old.workerPid, shell.binding.workerStart == old.workerStart,
              shell.binding.shellPid == old.shellPid, shell.binding.shellStart == old.shellStart,
              self.pane === pane, pane.profile == profile, pane.agentInputRevision == inputRevision,
              pane.connectionState == .connected, conversationInputLease == nil,
              agentMaintenanceRetainedShellPromptIsEmpty(observation), !view.promptInspectionBlocksExternalInput,
              let fence = screenFence(observation),
              let lease = io.promptEditorControlLease(paneID: pane.id, hostID: profile.id),
              let payload = TerminalPastePayload.directPayload(for: command, bracketed: io.isBracketedPasteActive)
              else { return false }
        conversationInputLease = UUID()
        defer { conversationInputLease = nil }
        try willSend()
        let sent = io.sendPromptEditorControlInput(Data((payload + "\r").utf8), expectedControlLease: lease,
            expectedMaintenanceScreen: fence.replay, expectedLiveScreen: fence.live, automation: true)
        if sent { view.unobservedPromptInput(); pane.userEnteredInput(); noteProgrammaticInput("agent_maintenance", command) }
        return sent
    }

    /// With a fence, the relay write is refused unless the admitted screen is
    /// still current at the transport boundary (TerminalIOBridge.sendUserInput).
    private func sendPromptTransport(_ text: String, maximumBytes: Int = 64 << 10, fence: ScreenFence? = nil) -> Bool {
        guard pane?.contentKind == .terminal,
              !text.isEmpty, text.utf8.count <= maximumBytes, maximumBytes <= 128 << 10 else { return false }
        // Automation, never typing: desktop counting pauses for the write.
        pane?.promptProvenance.beginProgrammatic()
        defer { pane?.promptProvenance.endProgrammatic() }
        let prompt = text.replacingOccurrences(of: "\r\n", with: "\n")
        if pane?.profile.backend == .relay {
            guard let payload = TerminalPastePayload.directPayload(
                for: prompt, bracketed: io.isBracketedPasteActive
            ) else { return false }
            let data = Data((payload + "\r").utf8)
            let sent = fence.map {
                io.sendUserInput(data, expectedLiveScreen: $0.live, expectedMaintenanceScreen: $0.replay)
            } ?? io.sendUserInput(data)
            guard sent else { return false }
            view.unobservedPromptInput()
            pane?.userEnteredInput()
            noteProgrammaticInput("relay_prompt", prompt)
            return true
        }
        guard let payload = TerminalPastePayload.rendererPayload(
            for: prompt, bracketed: io.isBracketedPasteActive
        ) else { return false }
        view.unobservedPromptInput()
        view.sendText(payload)
        // Submit outside Ghostty's paste framing. A carriage return passed to
        // surface_text is clipboard content, not a separate Return key.
        let submitted = view.performBindingAction("text:\\r")
        pane?.userEnteredInput()
        if submitted { noteProgrammaticInput("relay_prompt", prompt) }
        return submitted
    }

    /// Records a Relay automation write as a programmatic submit. Content-free.
    private func noteProgrammaticInput(_ source: String, _ text: String?) {
        pane?.promptProvenance.programmaticSubmit(source: source, fingerprint: text.map(RelayPromptFingerprint.init))
    }

    func beginSidePanelTerminalMirror(
        deliver: @escaping @Sendable (Data) -> Void,
        viewportChanged: @escaping @Sendable (RelayViewport) -> Void,
        ready: @escaping @Sendable (Data, RelayViewport) -> Void
    ) -> UUID? {
        guard pane?.contentKind == .terminal,
              pane?.profile.backend == .relay else { return nil }
        startIfNeeded()
        return io.beginSidePanelMirror(
            deliver: deliver,
            viewportChanged: viewportChanged,
            ready: ready
        )
    }

    func endSidePanelTerminalMirror(_ id: UUID) {
        io.endSidePanelMirror(id)
    }

    private enum TerminalEditScreen {
        case background(TerminalIOBridge.MaintenanceScreenSnapshot)
        case renderer(ScreenFence)
    }
    private struct PreparedTerminalEdit {
        let token: UUID
        let pane: PaneModel
        let profile: ConnectionProfile
        let owner: RelayPromptOwnerIdentity
        let revision: UInt64
        let screen: TerminalEditScreen
        let expires: TimeInterval
    }
    var terminalEditUptimeForTesting: (() -> TimeInterval)?
    private var terminalEditUptime: TimeInterval { terminalEditUptimeForTesting?() ?? ProcessInfo.processInfo.systemUptime }
    private var preparedTerminalEdit: PreparedTerminalEdit?

    /// Background read of the exact ordered worker buffer. It never attaches,
    /// selects, focuses or resizes the live terminal to make a screen readable.
    func backgroundViewportText() async -> String? {
        if let text = sidePanelViewportText() { return text }
        guard let pane, pane.contentKind == .terminal, pane.profile.backend == .relay,
              pane.connectionState == .connected, let snapshot = io.maintenanceScreenSnapshot() else { return nil }
        let profile = pane.profile
        guard let text = await RelayAgentMaintenanceScreen.editingScreen(snapshot.data, viewport: snapshot.token.viewport, identity: snapshot.token.producer),
              self.pane === pane, pane.profile == profile, io.maintenanceScreenIsCurrent(snapshot.token) else { return nil }
        return String(text.prefix(32_768))
    }

    private func terminalEditScreenIsCurrent(_ screen: TerminalEditScreen) -> Bool {
        switch screen {
        case .background(let snapshot): return io.maintenanceScreenIsCurrent(snapshot.token)
        case .renderer(let fence):
            guard let key = fence.live else { return false }
            return screenFence(observeActiveScreen()) == fence && io.nativeEditingScreenIsCurrent(key)
        }
    }

    /// Read-only proof from the ordered worker snapshot or an already attached
    /// native renderer. Neither path opens a window, changes focus or resizes.
    func terminalEditState() async -> [String: String] {
        preparedTerminalEdit = nil
        guard let pane, pane.contentKind == .terminal, pane.profile.backend == .relay,
              pane.connectionState == .connected, conversationInputLease == nil,
              !view.promptInspectionBlocksExternalInput, view.markedRange().location == NSNotFound else {
            return ["status": "unavailable", "reason": "No current terminal editing surface; no focus change was attempted."]
        }
        let profile = pane.profile, revision = pane.agentInputRevision
        guard let owner = await readPromptOwnerBinding() else { return ["status": "changed"] }
        let screen: TerminalEditScreen, plain: String, source: String
        if let snapshot = io.maintenanceScreenSnapshot() {
            guard let text = await RelayAgentMaintenanceScreen.editingScreen(snapshot.data,
                viewport: snapshot.token.viewport, identity: snapshot.token.producer) else { return ["status": "changed"] }
            screen = .background(snapshot); plain = text; source = "ordered_worker_snapshot"
        } else {
            // AppKit retains the native surface when a tab leaves its window.
            // Its current parsed screen is still fenced; no view is attached or
            // constructed here, and an absent/retired surface cannot prove it.
            let observation = observeActiveScreen()
            guard case .screen(_, let key) = observation else {
                return ["status": observation == .noSurface ? "unavailable" : "changed",
                    "reason": "No complete ordered snapshot or current native renderer; no focus change was attempted."]
            }
            screen = .renderer(.live(key)); plain = key.rows.joined(separator: "\n")
            source = view.window == nil ? "retained_native_renderer" : "attached_native_renderer"
        }
        guard await readPromptOwnerBinding() == owner, self.pane === pane, pane.profile == profile,
              pane.agentInputRevision == revision, terminalEditScreenIsCurrent(screen),
              conversationInputLease == nil, pane.connectionState == .connected else { return ["status": "changed"] }
        let token = UUID()
        preparedTerminalEdit = .init(token: token, pane: pane, profile: profile, owner: owner,
            revision: revision, screen: screen, expires: terminalEditUptime + 30)
        return ["status": "observed", "proof_id": token.uuidString.lowercased(),
            "pane_id": pane.id.uuidString.lowercased(), "host": profile.kind == .local ? "This Mac" : profile.host,
            "input_revision": String(revision), "provider": owner.binding.provider, "screen_source": source,
            "viewport_tail": RelayAssistantRedaction.boundedTail(plain, limit: 2000),
            "session_id": owner.binding.sessionId ?? "",
            "note": "User focus unchanged. Proof expires in 30 seconds. New output, input or process invalidates it."]
    }

    /// Same source and kernel fences as terminal editing, without changing focus.
    /// Only a recognized empty native prompt authorizes an operator resume.
    /// A displayed pane has no ordered worker snapshot; its proof is the
    /// attached (or retained) native renderer under the same live fence.
    func agentResumePromptProof(expected: RelayPromptOwnerBinding) async -> UUID? {
        let state = await terminalEditState()
        guard state["status"] == "observed", let proof = preparedTerminalEdit,
              proof.owner.binding == expected else { return nil }
        let vt: String?
        switch proof.screen {
        case .background(let snapshot):
            vt = await RelayAgentMaintenanceScreen.read(snapshot.data, viewport: snapshot.token.viewport)
        case .renderer(let fence):
            // The serialized screen (with SGR, so the faint placeholder stays
            // distinguishable) of exactly the fenced live key; plain rows are not enough.
            guard case .screen(let screen, let key) = observeActiveScreen(), ScreenFence.live(key) == fence else { return nil }
            vt = screen
        }
        guard terminalEditScreenIsCurrent(proof.screen),
              await readPromptOwnerBinding() == proof.owner,
              let pane, preparedTerminalEdit?.token == proof.token,
              Self.agentResumePromptAdmits(expected: expected, vt: vt, pendingApprovals: pane.pendingAgentApprovals,
                  composerBusy: pane.composerStateIfCreated.map({ !$0.draft.isEmpty || !$0.attachmentQueue.attachments.isEmpty || $0.submitting || $0.nativeDeliveryHeld }) == true)
        else { return nil }
        return proof.token
    }

    /// The screen and local-state half of a resume admission: no approval or
    /// composer activity, and the exact provider's prompt is idle and empty.
    nonisolated static func agentResumePromptAdmits(expected: RelayPromptOwnerBinding, vt: String?,
                                                    pendingApprovals: Int, composerBusy: Bool) -> Bool {
        guard pendingApprovals == 0, !composerBusy, expected.inputOnly != true else { return false }
        switch expected.provider {
        // No Claude footer agent is explained here, so any "← N agent" holds.
        case "codex", "claude": return RelayAgentMaintenancePrompt.isEmpty(vt, provider: expected.provider)
        case "shell": return RelayAgentMaintenancePrompt.retainedShellIsEmpty(vt)
        default: return false
        }
    }

    func agentResumeOwner() async -> RelayPromptOwnerBinding? { await readPromptOwnerBinding()?.binding }

    /// Budget notices may observe the native prompt but never authorize input.
    func budgetPromptEmpty() -> Bool? {
        let observation = observeActiveScreen()
        if agentMaintenancePromptIsEmpty(observation, preservingComposerDraft: false) { return true }
        if agentMaintenanceTerminalPromptHasTypedText(observation) { return false }
        return nil
    }

    func sendTerminalEdit(_ request: RelayTerminalEditRequest, appendShellReturn: Bool = false,
                          authorization: @MainActor () -> Bool = { true }) async -> String {
        guard request.isValid, let proof = preparedTerminalEdit, proof.token == request.token else { return "not_sent" }
        // Return is appended only to a retained shell's launch text, or to
        // Claude's fixed exit command; never to other agent prompt text.
        guard !appendShellReturn || request.action == "insert_text" && (proof.owner.binding.provider == "shell" ||
            proof.owner.binding.provider == "claude" && request.text == RelayAgentMaintenancePolicy.exitCommand(provider: "claude"))
        else { return "not_sent" }
        preparedTerminalEdit = nil
        let pane = proof.pane
        guard let inputLease = acquirePromptInspectionInputLease() else { return "not_sent" }
        defer { releasePromptInspectionInputLease(inputLease) }
        guard await readPromptOwnerBinding() == proof.owner else { return "not_sent" }
        var packet: Data
        switch proof.screen {
        case .background(let snapshot):
            guard let data = await RelayAgentMaintenanceScreen.editingInput(snapshot.data,
                viewport: snapshot.token.viewport, request: request, identity: snapshot.token.producer) else { return "not_sent" }
            packet = data
        case .renderer:
            guard terminalEditScreenIsCurrent(proof.screen),
                  let data = view.collectNativeInput({ view.translateTerminalEdit(request) }) else { return "not_sent" }
            packet = data
        }
        if appendShellReturn { packet.append(0x0d) }
        guard !packet.isEmpty, await readPromptOwnerBinding() == proof.owner,
              self.pane === pane, pane.profile == proof.profile, terminalEditUptime < proof.expires,
              pane.connectionState == .connected, pane.agentInputRevision == proof.revision,
              terminalEditScreenIsCurrent(proof.screen), !view.promptInspectionBlocksExternalInput,
              view.markedRange().location == NSNotFound, authorization(),
              let control = io.promptEditorControlLease(paneID: pane.id, hostID: pane.profile.id) else { return "not_sent" }
        let sent: Bool
        switch proof.screen {
        case .background(let snapshot):
            sent = io.sendPromptEditorControlInput(packet, expectedControlLease: control,
                expectedMaintenanceScreen: snapshot.token, automation: true)
        case .renderer(let fence):
            sent = io.sendPromptEditorControlInput(packet, expectedControlLease: control,
                expectedMaintenanceScreen: fence.replay, expectedLiveScreen: fence.live, automation: true)
        }
        if sent { view.unobservedPromptInput(); pane.userEnteredInput(); noteProgrammaticInput("terminal_edit", nil) }
        return sent ? "input_submitted" : "not_sent"
    }

    @discardableResult
    func sendSidePanelTerminalInput(_ data: Data) -> Bool {
        guard pane?.contentKind == .terminal,
              pane?.profile.backend == .relay,
              !data.isEmpty, data.count <= 64 << 10,
              conversationInputLease == nil, !view.promptInspectionBlocksExternalInput else { return false }
        view.unobservedPromptInput()
        io.sendUserInput(data)
        pane?.userEnteredInput()
        noteProgrammaticInput("side_panel_terminal_input", nil)
        return true
    }

    /// Exposes one fixed lifecycle capability to the supervisor. Unlike the
    /// side-panel paths this cannot carry arbitrary text or submit a command.
    @discardableResult
    func sendSupervisorInterrupt() -> Bool {
        guard pane?.contentKind == .terminal,
              pane?.profile.backend == .relay else { return false }
        return io.sendSupervisorInterrupt()
    }

    var canSendSupervisorInterrupt: Bool {
        guard pane?.contentKind == .terminal,
              pane?.profile.backend == .relay else { return false }
        return io.canSendSupervisorInterrupt
    }

    @discardableResult
    func resizeForSidePanel(columns: UInt16, rows: UInt16) -> Bool {
        guard pane?.contentKind == .terminal,
              pane?.profile.backend == .relay,
              columns >= 20, rows >= 5 else { return false }
        _ = io.flushPendingResize(
            viewport: RelayViewport(columns: columns, rows: rows),
            forceRepaint: true
        )
        return true
    }

    /// Restores the PTY geometry owned by the native Ghostty surface after an
    /// external browser viewer relinquishes input. The view may not emit a
    /// resize callback because its own frame never changed while backgrounded,
    /// so explicitly compare and commit its last measured grid.
    func reclaimNativeViewportOwnership() {
        nativeViewportRecoveryTask?.cancel()
        nativeViewportRecoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var sampler = TerminalStableGeometrySampler()
            for delay in [0, 16, 32, 64, 120, 240] {
                if delay == 0 {
                    await Task.yield()
                } else {
                    try? await Task.sleep(for: .milliseconds(delay))
                }
                guard !Task.isCancelled,
                      self.started,
                      self.allowsRendering,
                      self.pane?.profile.backend == .relay,
                      self.presentationAttachment.isPresented,
                      let window = self.view.window,
                      window.isVisible,
                      !window.isMiniaturized else { continue }

                self.view.superview?.layoutSubtreeIfNeeded()
                guard sampler.observe(self.view.bounds.size),
                      !self.explicitGeometryTransitionPending,
                      self.pendingViewportCommitEpoch == nil else { continue }

                // Returning from another Space can make the IOSurface stale
                // without changing the PTY grid. Fit only after AppKit has
                // published stable geometry, then redraw unconditionally;
                // viewport ownership and surface presentation are separate.
                self.view.fitToSize()
                if let viewport = self.latestSurfaceViewport {
                    _ = self.io.reclaimNativeViewport(
                        viewport,
                        compatibilityRepaintPulse: self.pane?.kind != .shell
                    )
                }
                self.view.setSurfaceVisible(true)
                self.view.synchronizeAndRedraw()
                if self.pane?.kind != .shell {
                    // Primary-screen agents can retain an obsolete internal
                    // viewport across a Space transition even though their
                    // PTY grid is current. Keep the composer visible after the
                    // same stable barrier used for resize and restore.
                    _ = self.view.performBindingAction("scroll_to_bottom")
                    _ = self.view.scrollToRow(UInt.max)
                }
                self.view.alphaValue = 1
                self.nativeViewportRecoveryTask = nil
                return
            }
            guard !Task.isCancelled else { return }
            // The bounded sampling window elapsed without stable geometry (a
            // Space or full-screen handoff, or a viewport transaction still
            // open). PTY-grid ownership stays unclaimed, but surface visibility
            // is a separate concern: it was switched off when rendering was
            // disallowed, and if it is not restored here the retained
            // IOSurface stays hidden until an unrelated resize.
            if self.presentationAttachment.isPresented,
               self.allowsRendering,
               self.view.window != nil {
                self.view.setSurfaceVisible(true)
                self.view.synchronizeAndRedraw()
                self.view.alphaValue = 1
            }
            self.nativeViewportRecoveryTask = nil
        }
    }

    fileprivate func recordInputDiagnostic(
        _ name: String,
        details: [String: String] = [:]
    ) {
        guard let pane else { return }
        if TerminalReplayTrace.enabled,
           name.hasPrefix("prompt-history") || name.hasPrefix("prompt-mirror") || name.hasPrefix("prompt-click") {
            let fields = details.keys.sorted().map { "\($0)=\(details[$0] ?? "")" }.joined(separator: " ")
            TerminalReplayTrace.log("input pane=\(pane.id.uuidString) name=\(name) \(fields)")
        }
        var metadata = details
        metadata["pane_id"] = pane.id.uuidString.lowercased()
        metadata["kind"] = pane.kind.rawValue
        metadata["remote"] = String(
            pane.profile.backend == .relay
        )
        RelayDiagnostics.shared.record(
            category: "terminal-input",
            name: name,
            details: metadata
        )
    }

    fileprivate func recordClipboardCopyOutcome(source: String, bytes: Int, succeeded: Bool) {
        guard let pane else { return }
        RelayDiagnostics.shared.record(category: "terminal-clipboard", name: "copy", details: [
            "pane_id": pane.id.uuidString.lowercased(),
            "source": source,
            "bytes": String(bytes),
            "succeeded": String(succeeded),
            "first_responder": String(view.window?.firstResponder === view),
            "window_key": String(view.window?.isKeyWindow == true),
        ])
    }

    @discardableResult
    fileprivate func endPromptControlTranslationCapture() -> Bool {
        io.endPromptControlCapture()
    }

    private func directCommand() -> String? {
        guard let pane, pane.profile.kind == .ssh else { return nil }
        let profile = pane.profile
        var parts = ["/usr/bin/ssh", "-tt"]
        parts.append(contentsOf: profile.sshConnectionArguments.map(ShellQuoting.quote))
        if let command = profile.remoteCommand(forPane: pane.id) {
            parts.append(ShellQuoting.quote(command))
        }
        // Ghostty applies the configured local shell integration to custom
        // commands. A noninteractive shell prevents shell-only flags (such as
        // bash's --posix) from reaching SSH, and exec keeps SSH in the foreground.
        return "/bin/sh -c " + ShellQuoting.quote("exec " + parts.joined(separator: " "))
    }


    nonisolated private static func stableImageID(for path: String) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for byte in path.utf8 {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
        return hash == 0 ? 1 : hash
    }

    fileprivate func selectPane() {
        guard let pane else { return }
        if let onPaneSelection { onPaneSelection(); return }
        NotificationCenter.default.post(name: .relaySelectPane, object: pane.id)
    }

    fileprivate func split(_ axis: SplitAxis) {
        selectPane()
        NotificationCenter.default.post(
            name: axis == .horizontal ? .relaySplitRight : .relaySplitDown,
            object: pane?.id
        )
    }

    fileprivate func closePane() {
        selectPane()
        NotificationCenter.default.post(name: .relayClosePane, object: pane?.id)
    }

    fileprivate func terminatePane() {
        selectPane()
        NotificationCenter.default.post(name: .relayTerminatePane, object: pane?.id)
    }

    fileprivate func openHoveredLink() -> Bool {
        guard let hoveredLink else { return false }
        return openTerminalLink(hoveredLink)
    }

    fileprivate var allowsPromptSelectionEditing: Bool {
        guard let pane else { return false }
        return TerminalPromptSelectionEdit.isEnabled(
            contentKind: pane.contentKind,
            agentKind: pane.kind
        )
    }

    fileprivate var forcesLocalPromptSelection: Bool {
        pane.map { TerminalPromptSelectionEdit.forcesLocalSelection(agentKind: $0.kind) } ?? false
    }

    fileprivate var promptEditingViewportIsLive: Bool { viewportIsAtBottom }

    fileprivate struct PromptInspectionIdentity: Equatable {
        let paneID: UUID
        let hostID: UUID
        let kind: AgentKind
        let revision: UInt64
        let connection: PaneConnectionState
    }

    fileprivate var promptInspectionIdentity: PromptInspectionIdentity? {
        pane.map { .init(paneID: $0.id, hostID: $0.profile.id, kind: $0.kind,
            revision: $0.agentInputRevision, connection: $0.connectionState) }
    }

    fileprivate var promptInspectionRequiresKernelIdentity: Bool { pane?.profile.backend == .relay }

    fileprivate func userEnteredInput() {
        pane?.userEnteredInput()
    }

    /// Desktop input counters for this pane (counts only, never content).
    fileprivate func recordPromptInput(_ body: (inout RelayPromptProvenanceLog) -> Void) {
        guard let pane else { return }
        body(&pane.promptProvenance)
    }

    @discardableResult
    func handleApplicationClipboardAction(_ action: RelayClipboardAction) -> Bool {
        guard pane?.contentKind == .terminal else { return false }
        prepareForUserInteraction()
        _ = view.acquireProgrammaticFocus()
        return view.handleApplicationClipboardAction(action)
    }

    @discardableResult
    func handleApplicationUndoAction(redo: Bool) -> Bool {
        guard pane?.contentKind == .terminal else { return false }
        prepareForUserInteraction()
        _ = view.acquireProgrammaticFocus()
        return view.performPromptHistoryAction(redo: redo)
    }

    fileprivate func importLocalFiles(_ urls: [URL], resume: Bool = false) -> Bool {
        guard !urls.isEmpty, fileTransferTask == nil,
              let pane, pane.profile.backend == .relay else { return false }
        let profile = pane.profile
        let paneID = pane.id.uuidString.lowercased()
        let transferID = UUID()
        pane.uploadProgressID = transferID
        let transferName = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items"
        pane.uploadProgress = .init(phase: .preparing, name: transferName)
        view.toolTip = "Uploading \(transferName)…"
        fileTransferTask = Task { @MainActor [weak self] in
            do {
                let imported = try await RemoteFileTransfer.upload(
                    urls,
                    toPane: paneID,
                    profile: profile,
                    resume: resume,
                    progress: { [weak pane] update in
                        await MainActor.run {
                            guard let pane, pane.uploadProgressID == transferID else { return }
                            pane.uploadProgress = update
                        }
                    }
                )
                guard let self, !Task.isCancelled, self.pane?.id == pane.id,
                      pane.uploadProgressID == transferID else { return }
                self.fileTransferTask = nil
                if let path = imported.first?.path {
                    pane.directory = TerminalPathSyntax.parentDirectory(path)
                }
                self.view.toolTip = imported.count == 1
                    ? "Uploaded \(imported[0].name)"
                    : "Uploaded \(imported.count) files"
                let paths = imported.map { Self.promptPath($0.path) }.joined(separator: " ") + " "
                self.view.sendText(paths)
                RelayDiagnostics.shared.record(category: "transfer", name: "uploaded", details: [
                    "pane_id": pane.id.uuidString.lowercased(),
                    "files": String(imported.count),
                ])
            } catch is CancellationError {
                self?.fileTransferTask = nil
                if pane.uploadProgressID == transferID {
                    pane.uploadProgress = .init(phase: .failed, name: transferName,
                        message: "Upload paused. Drop the same items here to resume.")
                }
            } catch {
                guard let self, pane.uploadProgressID == transferID else { return }
                self.fileTransferTask = nil
                pane.uploadProgress = .init(phase: .failed, name: transferName, message: error.localizedDescription)
                self.view.toolTip = error.localizedDescription
                NSSound.beep()
                let alert = RelayTheme.alert()
                alert.alertStyle = .warning
                let recoveryAvailable: Bool
                if case RemoteFileTransferError.recoveryAvailable = error { recoveryAvailable = true }
                else { recoveryAvailable = false }
                alert.messageText = recoveryAvailable ? "Recover saved upload" : "Could not upload items"
                alert.informativeText = error.localizedDescription
                if recoveryAvailable {
                    alert.addButton(withTitle: "Resume Upload")
                    alert.addButton(withTitle: "Forget Saved Upload")
                    alert.addButton(withTitle: "Cancel")
                }
                let respond: (NSApplication.ModalResponse) -> Void = { [weak self] response in
                    guard recoveryAvailable, let self, self.pane?.id == pane.id,
                          self.pane?.profile == profile else { return }
                    if response == .alertFirstButtonReturn {
                        _ = self.importLocalFiles(urls, resume: true)
                    } else if response == .alertSecondButtonReturn {
                        self.forgetLocalUploads(urls, paneID: paneID, profile: profile)
                    }
                }
                if let window = self.view.window {
                    alert.beginSheetModal(for: window, completionHandler: respond)
                } else {
                    respond(alert.runModal())
                }
            }
        }
        return true
    }

    private func forgetLocalUploads(_ urls: [URL], paneID: String, profile: ConnectionProfile) {
        guard fileTransferTask == nil else { return }
        fileTransferTask = Task { @MainActor [weak self] in
            defer { self?.fileTransferTask = nil }
            do {
                try await RemoteFileTransfer.discard(urls, toPane: paneID, profile: profile)
                self?.view.toolTip = "Saved upload cleared. Drop the item again to start another upload."
            } catch {
                guard let self else { return }
                self.view.toolTip = error.localizedDescription
                let alert = RelayTheme.alert()
                alert.alertStyle = .warning
                alert.messageText = "Could not clear saved upload"
                alert.informativeText = error.localizedDescription
                if let window = self.view.window { alert.beginSheetModal(for: window) { _ in } }
                else { alert.runModal() }
            }
        }
    }

    private func presentArtifact(path: String, data: Data) {
        cacheArtifact(path: path, data: data)
        pane?.receivedArtifact(path: path, data: data)
    }

    private func cacheArtifact(path: String, data: Data) {
        lastArtifact = (path, data)
    }

    private func showArtifact(path: String) {
        // An explicit open always rereads the file: cached bytes may be stale.
        pane?.openFilePreview(path: path, kind: RelayFilePreviewKind.from(path: path))
    }

    @discardableResult
    private func openTerminalLink(_ link: String) -> Bool {
        guard let target = TerminalLinkResolver.target(from: link) else { return false }
        switch target {
        case .web(let url):
            NSWorkspace.shared.open(url)
        case .image(let path):
            showArtifact(path: resolvedRemotePath(path))
        case .file(let path) where RelayFilePreviewKind.from(path: path) != nil:
            showArtifact(path: resolvedRemotePath(path))
        case .file(let path):
            guard let pane else { return false }
            NotificationCenter.default.post(
                name: .relayOpenRemoteFile,
                object: RemoteFileOpenRequest(
                    profile: pane.profile,
                    parentSessionID: pane.id.uuidString.lowercased(),
                    request: EditorOpenRequest(paths: [resolvedRemotePath(path)], diff: false)
                )
            )
        }
        return true
    }

    private func resolvedRemotePath(_ path: String) -> String {
        guard (path.hasPrefix("./") || path.hasPrefix("../")),
              let directory = pane?.directory, directory.hasPrefix("/") else { return path }
        return TerminalPathSyntax.resolving(path, against: directory)
    }

    private static func promptPath(_ path: String) -> String {
        // This path comes from the remote relayd's JSON and is typed into the
        // user's shell as synthetic keystrokes. Control bytes (newline, CR,
        // ESC, 0x03) cannot be neutralized by shell quoting — the PTY line
        // discipline acts on them before any shell does — so a compromised
        // remote could inject an interrupt plus a command. Strip control
        // characters first, then quote shell metacharacters.
        let sanitized = String(path.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F })
        guard sanitized.contains(where: { $0.isWhitespace || "'\"\\$`!()[]{};&|<>".contains($0) })
                || sanitized.count != path.count else {
            return sanitized
        }
        return "'" + sanitized.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

final class TerminalActivityCoalescer: @unchecked Sendable {
    private static let maximumCharacters = 256 << 10
    private let lock = NSLock()
    private let delayMilliseconds: Int
    private var pendingText = ""
    private var pendingBytes = 0
    private var deliveryScheduled = false
    private var pendingEpoch: UUID?
    private var schedulingGeneration: UInt64 = 0
    private var enabled = true

    init(delayMilliseconds: Int = 80) {
        self.delayMilliseconds = delayMilliseconds
    }

    func setEnabled(_ enabled: Bool) {
        lock.lock()
        self.enabled = enabled
        if !enabled {
            pendingText.removeAll(keepingCapacity: true)
            pendingBytes = 0
            pendingEpoch = nil
            deliveryScheduled = false
            schedulingGeneration &+= 1
        }
        lock.unlock()
    }

    func ingest(_ text: String, deliveryEpoch: UUID, deliver: @escaping @Sendable (String) -> Void) {
        lock.lock()
        guard enabled else {
            lock.unlock()
            return
        }
        if pendingEpoch != deliveryEpoch {
            // Retired text cannot share a callback with its successor epoch.
            pendingEpoch = deliveryEpoch
            pendingText.removeAll(keepingCapacity: true)
            pendingBytes = 0
            deliveryScheduled = false
            schedulingGeneration &+= 1
        }
        pendingText.append(text)
        pendingBytes += text.utf8.count
        if pendingBytes > Self.maximumCharacters {
            pendingText = UTF8TailTruncation.tail(pendingText, maximumUTF8Bytes: Self.maximumCharacters)
            pendingBytes = pendingText.utf8.count
        }
        guard !deliveryScheduled else {
            lock.unlock()
            return
        }
        deliveryScheduled = true
        let generation = schedulingGeneration
        lock.unlock()

        let delayMilliseconds = self.delayMilliseconds
        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + .milliseconds(delayMilliseconds)
        ) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            guard self.enabled, self.schedulingGeneration == generation,
                  self.pendingEpoch == deliveryEpoch else {
                self.lock.unlock()
                return
            }
            let batch = self.pendingText
            self.pendingText.removeAll(keepingCapacity: true)
            self.pendingBytes = 0
            self.deliveryScheduled = false
            self.lock.unlock()
            if !batch.isEmpty { deliver(batch) }
        }
    }
}

final class TerminalIOBridge: @unchecked Sendable {
    struct MaintenanceScreenToken: Equatable, Sendable {
        let producer: UUID
        let sequence: UInt64
        let replayGeneration: UInt64
        let viewport: RelayViewport
        var snapshotRevision: UInt64 = 0
    }
    struct MaintenanceScreenSnapshot: Sendable {
        let token: MaintenanceScreenToken
        let data: Data
    }

    struct SnapshotRestoration {
        let remoteSequence: UInt64
        let rendered: Bool
    }

    enum PromptEditorRestorationEvent: Equatable, Sendable {
        case armed(revision: UInt64)
        case parsedFrame(revision: UInt64)
        // Raw frame completion wakes a hidden pane. Its caller must still use
        // the exact editor readback or a current offscreen native screen proof.
        case hostFrame
        case invalidated
    }
    struct PromptEditorRestorationBarrier: Sendable {
        let id: UUID
        let events: AsyncStream<PromptEditorRestorationEvent>
    }
    private struct PendingEditorRestoration {
        let id: UUID
        let baseline: UInt64
        let continuation: AsyncStream<PromptEditorRestorationEvent>.Continuation
    }
    // Confined to displayQueue, alongside actual native parser delivery.
    private var editorFrameTracker = RelayPromptEditorFrameTracker()
    private var pendingEditorRestoration: PendingEditorRestoration?

    func beginPromptEditorRestorationBarrier() -> PromptEditorRestorationBarrier {
        let id = UUID()
        let (events, continuation) = AsyncStream<PromptEditorRestorationEvent>.makeStream(bufferingPolicy: .bufferingNewest(8))
        continuation.onTermination = { [weak self] _ in self?.endPromptEditorRestorationBarrier(id) }
        displayQueue.async { [weak self] in
            guard let self else { continuation.finish(); return }
            guard self.pendingEditorRestoration == nil else {
                continuation.yield(.invalidated); continuation.finish(); return
            }
            self.drainDisplay()
            self.session.waitForPendingOutput()
            let baseline = self.session.parsedHostOutputRevision
            self.editorFrameTracker.arm()
            self.pendingEditorRestoration = .init(id: id, baseline: baseline, continuation: continuation)
            continuation.yield(.armed(revision: baseline))
        }
        return .init(id: id, events: events)
    }

    func endPromptEditorRestorationBarrier(_ id: UUID) {
        displayQueue.async { [weak self] in
            guard let self, self.pendingEditorRestoration?.id == id else { return }
            self.editorFrameTracker.disarm()
            let pending = self.pendingEditorRestoration
            self.pendingEditorRestoration = nil
            pending?.continuation.finish()
        }
    }

    private func invalidatePromptEditorRestorationBarrier() {
        displayQueue.async { [weak self] in
            guard let self else { return }
            self.editorFrameTracker.disarm()
            let pending = self.pendingEditorRestoration
            self.pendingEditorRestoration = nil
            pending?.continuation.yield(.invalidated)
            pending?.continuation.finish()
        }
    }

    private var transport: RelayRemoteTransport?
    var onReplayFinished: (@Sendable (Bool) -> Void)?
    var onReplayWritesResumed: (@Sendable () -> Void)?
    var onObservedRepaintFrame: (@Sendable (UUID) -> Void)?
    var onPresentationResumed: (@Sendable () -> Void)?
    var onViewportCommitted: (@Sendable (UInt64, RelayRemoteTransport, UUID) -> Void)?
    var onViewportFrameReady: (@Sendable (UUID, RelayRemoteTransport?, UUID?) -> Void)?
    private var outputProducerID = UUID()
    var onViewportReady: (@Sendable (RelayViewport) -> Void)?
    var onSemanticPromptStateChanged: (@Sendable (Bool) -> Void)?
    var onPromptHistoryInvalidated: (@Sendable () -> Void)?
    private let receiveLock = NSLock()
    private let outputOrderingLock = NSRecursiveLock()
    private let resizeLock = NSLock()
    private let promptControlLock = NSLock()
    private let presentationLock = NSLock()
    private let displayLock = NSLock()
    private struct ObservedRepaint {
        let id: UUID
        var generation: UInt64?
        var waitingForCommit = true
        var frameParsed = false
        var tracker = RelayPromptEditorFrameTracker(minimumFrameBytes: 96)
    }
    private var observedRepaint: ObservedRepaint?
    private var pendingObservedRepaintFrame: UUID?
    private let displayQueue = DispatchQueue(label: "relay.terminal-display", qos: .userInteractive)
    private var displayBuffer = Data()
    private var displayDrainScheduled = false
    /// Display bytes accepted from receive() and not yet handed to the native
    /// session: buffered or taken by a drain still delivering. Guarded by
    /// displayLock. The live-screen send fence requires zero.
    private var displayBytesInTransit = 0
    /// Tests only: runs inside outputOrderingLock right after a send's final
    /// fence check and before the transport records the input.
    var fenceCheckedForTesting: (() -> Void)?
    /// Tests only: runs on the replay commit with replayLock held, just before
    /// the commit enters the display queue.
    var replayCommitWillEnqueueForTesting: (() -> Void)?
    /// Tests only: runs when a send-side phase read, holding
    /// outputOrderingLock, is about to take replayLock.
    var phaseReadWillLockReplayForTesting: (() -> Void)?
    var snapshotRevisionForTesting: UInt64 {
        receiveLock.lock(); defer { receiveLock.unlock() }
        return snapshotRevision
    }
    var displayBytesInTransitForTesting: Int {
        displayLock.lock(); defer { displayLock.unlock() }
        return displayBytesInTransit
    }
    /// Uptime of the last display drain; guarded by displayLock.
    private var lastDisplayDrainUptime: UInt64?
    /// Live browser companions observe the exact byte stream delivered to
    /// Ghostty. This dictionary is confined to displayQueue so a viewer cannot
    /// contend with terminal input or the PTY reader.
    private struct SidePanelMirrorObserver: Sendable {
        let deliver: @Sendable (Data) -> Void
        let viewportChanged: @Sendable (RelayViewport) -> Void
    }
    private var sidePanelMirrorObservers: [UUID: SidePanelMirrorObserver] = [:]
    private var presentationPaused = false
    /// Resize output is withheld until the matching viewport acknowledgement.
    /// Ghostty then sees one replacement repaint instead of intermediate grids
    /// painted over the previous viewport.
    private var viewportTransitionActive = false
    private var viewportTransitionBuffer = Data()
    private var viewportTransitionRemoteSequence: UInt64 = 0
    private var viewportTransitionFrameRows: UInt16?
    private var viewportTransitionFrameStart = 0
    private let replayLock = NSLock()
    private var replaying = false
    private var maximumObservedRemoteSequence: UInt64 = 0
    private var replayKnownSequence: UInt64 = 0
    private var preservesRestoredScreenOnReconnect = false
    private var reconnectReplayExtendsRestoredScreen = false
    private var replayRequiresFreshBase = false
    // A transport reconnect does not destroy the in-memory terminal. Apply
    // cursor-resumed bytes to that exact parser state, not a lossy ANSI cache.
    private var hasCommittedReplay = false
    private var replayUsesRetainedGrid = false
    private var expectsExplicitReplayBoundary = false
    private var suppressingTerminalWrites = false
    private var replayBuffer = Data()
    private var replayGeneration: UInt64 = 0
    /// Non-nil while a background compaction is preparing an atomic replay
    /// commit. The generation makes a newer reconnect cancel the old commit
    /// without discarding bytes already acknowledged by the remote worker.
    private var replayCommitGeneration: UInt64?
    private var legacyReplayGeneration: UInt64 = 0
    private var legacyReplayHardDeadline = DispatchTime.distantFuture
    private var programStatusReplyOwnedByWorker = false
    private var filterDeviceResponsesUntil = Date.distantPast
    private var snapshotPaneID: UUID?
    /// Guarded by receiveLock. Every mutation (append, compaction, restore,
    /// replay commit, reset) advances snapshotRevision, so a maintenance
    /// token names these exact bytes, not only their remote sequence.
    private var snapshotBuffer = Data() { didSet { snapshotRevision &+= 1 } }
    private var snapshotRevision: UInt64 = 0
    /// The buffer was cut to a suffix without its screen base. It is still
    /// persisted for its resume cursor, but the store will not replay it.
    private var snapshotBufferTruncated = false
    private var snapshotRemoteSequence: UInt64 = 0
    private let alternateScreenCleanup = TerminalAlternateScreenCleanupFilter()
    private let commandReturnCleanup = TerminalCommandReturnCleanup()
    private let bracketedPasteTracker = TerminalBracketedPasteStateTracker()
    private let semanticPromptTracker = TerminalSemanticPromptStateTracker()
    private let shellInputTracker = TerminalShellInputTracker()
    private let promptWidthMode = TerminalPromptWidthMode()
    private var snapshotWriteWindowStartedAt: DispatchTime?
    private var snapshotScheduledDeadline: DispatchTime?
    private var usesBackgroundSnapshotCadence = false
    private var latestViewport = RelayViewport.default
    private var lastSentViewport: RelayViewport?
    private var pendingConfirmedViewport: RelayViewport?
    private var pendingConfirmedRepaint = false
    private var resizeTransitionActive = false
    /// Capture explicitly synchronous input on the initiating thread without
    /// consuming renderer replies from another queue. Ghostty's native key and
    /// paste writes arrive asynchronously and need a separate transaction
    /// boundary before this collector can batch a complete native edit.
    private var promptControlCaptureTransport: RelayRemoteTransport?
    private var promptControlCaptureLease: RelayPromptEditorControlLease?
    private var promptControlCaptureThread: UInt32?
    private var promptControlCaptureIdentity: UUID?
    private var promptControlCaptureBuffer = RelayPromptControlBatch()
    /// Input diagnostics are deliberately bounded and record counts/state only.
    /// They make a dead keyboard diagnosable without retaining terminal text.
    private let legacyReplayTimer: DispatchSourceTimer
    private let snapshotSaveTimer: DispatchSourceTimer
    private let resizeTimer: DispatchSourceTimer

    init() {
        legacyReplayTimer = DispatchSource.makeTimerSource(
            queue: DispatchQueue.global(qos: .userInitiated)
        )
        snapshotSaveTimer = DispatchSource.makeTimerSource(
            queue: DispatchQueue.global(qos: .utility)
        )
        resizeTimer = DispatchSource.makeTimerSource(
            queue: DispatchQueue.global(qos: .userInteractive)
        )

        legacyReplayTimer.setEventHandler { [weak self] in
            self?.finishLegacyReplayIfIdle()
        }
        legacyReplayTimer.schedule(deadline: .distantFuture)
        legacyReplayTimer.resume()

        // One reschedulable timer is a real debounce. Enqueuing a new
        // asyncAfter closure for every PTY packet leaves thousands of dormant
        // closures behind during agent/TUI repaint storms, increasing memory
        // and waking utility workers only to discover stale generations.
        snapshotSaveTimer.setEventHandler { [weak self] in
            self?.savePendingSnapshot()
        }
        snapshotSaveTimer.schedule(deadline: .distantFuture)
        snapshotSaveTimer.resume()

        resizeTimer.setEventHandler { [weak self] in
            self?.flushPendingResize()
        }
        resizeTimer.schedule(deadline: .distantFuture)
        resizeTimer.resume()
    }

    deinit {
        pendingEditorRestoration?.continuation.finish()
        legacyReplayTimer.cancel()
        snapshotSaveTimer.cancel()
        resizeTimer.cancel()
    }

    lazy var session = InMemoryTerminalSession(
        write: { [weak self] data in self?.forwardTerminalWrite(data) },
        resize: { [weak self] viewport in
            self?.terminalDidResize(columns: viewport.columns, rows: viewport.rows)
        },
        suppressesPixelOnlyResizes: true
    )

    /// The grid a hidden pane's first Hello carries. Only before a transport
    /// is installed; a laid-out surface reports its own grid afterwards.
    func seedInitialViewport(_ viewport: RelayViewport) {
        resizeLock.lock()
        if transport == nil { latestViewport = viewport }
        resizeLock.unlock()
    }

    func installTransport(_ transport: RelayRemoteTransport) {
        outputOrderingLock.lock()
        invalidatePromptEditorRestorationBarrier()
        resizeLock.lock()
        self.transport = transport
        outputProducerID = UUID()
        let viewport = latestViewport
        lastSentViewport = nil
        resizeLock.unlock()
        outputOrderingLock.unlock()
        transport.setInitialViewport(viewport)
        transport.setViewportCommitHandler { [weak self, weak transport] generation, deliveryEpoch in
            guard let self, let transport else { return }
            _ = self.performForTransport(transport) {
                guard transport.isCurrentDeliveryEpoch(deliveryEpoch) else { return }
                self.displayLock.lock()
                var completedRepaint: UUID?
                if self.observedRepaint?.generation == generation {
                    self.observedRepaint?.waitingForCommit = false
                    if self.observedRepaint?.frameParsed == true {
                        completedRepaint = self.observedRepaint?.id
                        self.observedRepaint = nil
                    }
                }
                self.displayLock.unlock()
                if let completedRepaint { self.onObservedRepaintFrame?(completedRepaint) }
                self.onViewportCommitted?(generation, transport, deliveryEpoch)
            }
        }
    }

    func promptEditorControlLease(paneID: UUID, hostID: UUID, requireIdleInput: Bool = true) -> RelayPromptEditorControlLease? {
        resizeLock.lock()
        let current = transport
        resizeLock.unlock()
        return current?.promptEditorControlLease(paneID: paneID, hostID: hostID, requireIdleInput: requireIdleInput)
    }

    func promptEditorLeaseEvents() -> AsyncStream<Void>? {
        resizeLock.lock()
        let current = transport
        resizeLock.unlock()
        return current?.promptEditorLeaseEvents()
    }

    /// Whether the worker will act on a resize sent over the current route.
    var routeAcceptsViewportRepaint: Bool {
        resizeLock.lock()
        let current = transport
        resizeLock.unlock()
        return current?.acceptsViewportRepaint == true
    }

    @discardableResult
    func reconnectExistingPaneRoute() -> Bool {
        resizeLock.lock()
        let currentTransport = transport
        resizeLock.unlock()
        return currentTransport?.reconnectExistingPaneRoute() == true
    }

    func removeTransport() -> RelayRemoteTransport? {
        outputOrderingLock.lock()
        invalidatePromptEditorRestorationBarrier()
        resizeLock.lock()
        let transport = self.transport
        self.transport = nil
        outputProducerID = UUID()
        resizeTimer.schedule(deadline: .distantFuture)
        resizeLock.unlock()
        outputOrderingLock.unlock()
        return transport
    }

    var currentViewport: RelayViewport {
        resizeLock.lock()
        let viewport = latestViewport
        resizeLock.unlock()
        return viewport
    }

    func maintenanceScreenSnapshot() -> MaintenanceScreenSnapshot? {
        outputOrderingLock.lock()
        defer { outputOrderingLock.unlock() }
        phaseReadWillLockReplayForTesting?()
        replayLock.lock()
        let ready = !replaying && replayCommitGeneration == nil
        let generation = replayGeneration
        let observed = maximumObservedRemoteSequence
        replayLock.unlock()
        guard ready else { return nil }
        // Sequence-zero bytes buffered in an open viewport transition change
        // neither the sequence nor the replay buffer: no token while it is open.
        presentationLock.lock()
        let transitionOpen = viewportTransitionActive
        presentationLock.unlock()
        guard !transitionOpen else { return nil }
        resizeLock.lock()
        let producer = outputProducerID
        let viewport = latestViewport
        let connected = transport != nil
        resizeLock.unlock()
        receiveLock.lock()
        defer { receiveLock.unlock() }
        guard connected, !snapshotBufferTruncated, !snapshotBuffer.isEmpty,
              snapshotRemoteSequence > 0, observed <= snapshotRemoteSequence else { return nil }
        return MaintenanceScreenSnapshot(token: MaintenanceScreenToken(producer: producer,
            sequence: snapshotRemoteSequence, replayGeneration: generation, viewport: viewport,
            snapshotRevision: snapshotRevision), data: snapshotBuffer)
    }

    func maintenanceScreenIsCurrent(_ token: MaintenanceScreenToken) -> Bool {
        maintenanceScreenSnapshot()?.token == token
    }

    func beginSidePanelMirror(
        deliver: @escaping @Sendable (Data) -> Void,
        viewportChanged: @escaping @Sendable (RelayViewport) -> Void,
        ready: @escaping @Sendable (Data, RelayViewport) -> Void
    ) -> UUID {
        let id = UUID()
        displayQueue.async { [weak self] in
            guard let self else { return }
            // Cross the pending display boundary first. The snapshot then
            // precedes every byte observed by the newly registered mirror.
            self.drainDisplay()
            self.receiveLock.lock()
            let snapshot = self.snapshotBuffer
            self.receiveLock.unlock()
            let viewport = self.currentViewport
            self.sidePanelMirrorObservers[id] = SidePanelMirrorObserver(
                deliver: deliver,
                viewportChanged: viewportChanged
            )
            ready(snapshot, viewport)
        }
        return id
    }

    func endSidePanelMirror(_ id: UUID) {
        displayQueue.async { [weak self] in
            self?.sidePanelMirrorObservers.removeValue(forKey: id)
        }
    }

    var isAlternateScreenActive: Bool {
        alternateScreenCleanup.isActive
    }

    var isViewportTransitionActive: Bool {
        presentationLock.lock()
        defer { presentationLock.unlock() }
        return viewportTransitionActive
    }

    var isBracketedPasteActive: Bool {
        bracketedPasteTracker.isActive
    }

    /// The retained shell has begun reading a command line and has echoed
    /// nothing since; see TerminalShellInputTracker.
    var shellInputIsEmpty: Bool { shellInputTracker.inputIsEmpty }

    func terminalDidResize(columns: UInt16, rows: UInt16) {
        let viewport = RelayViewport(columns: columns, rows: rows)
        resizeLock.lock()
        latestViewport = viewport
        let confirmsCommit = pendingConfirmedViewport == viewport
        if transport != nil, !resizeTransitionActive, viewport != lastSentViewport {
            resizeTimer.schedule(
                deadline: .now() + .milliseconds(TerminalResizePolicy.debounceMilliseconds),
                leeway: .milliseconds(20)
            )
        }
        resizeLock.unlock()
        notifySidePanelViewport(viewport)
        onViewportReady?(viewport)
        if confirmsCommit { _ = flushPendingResize() }
    }

    func beginObservedViewportResize() {
        resizeLock.lock()
        resizeTransitionActive = true
        resizeTimer.schedule(deadline: .distantFuture)
        resizeLock.unlock()
    }

    func resumeAutomaticViewportResizes() {
        resizeLock.lock()
        resizeTransitionActive = false
        if transport != nil, latestViewport != lastSentViewport {
            resizeTimer.schedule(deadline: .now() + .milliseconds(TerminalResizePolicy.debounceMilliseconds))
        }
        resizeLock.unlock()
    }

    /// Arm before writing the resize: the worker can repaint before its ACK.
    /// Completion waits for both that ACK and the native parser barrier.
    func requestObservedViewportRepaint(id: UUID) {
        outputOrderingLock.lock()
        displayLock.lock()
        var observation = ObservedRepaint(id: id)
        observation.tracker.arm()
        observedRepaint = observation
        pendingObservedRepaintFrame = nil
        displayLock.unlock()
        let generation = flushPendingResize(forceRepaint: true)
        displayLock.lock()
        observedRepaint?.generation = generation
        if generation == nil {
            observedRepaint?.waitingForCommit = false
        }
        displayLock.unlock()
        outputOrderingLock.unlock()
    }

    func cancelObservedRepaint() {
        displayLock.lock()
        observedRepaint = nil
        pendingObservedRepaintFrame = nil
        displayLock.unlock()
    }

    @discardableResult
    func flushPendingResize(
        viewport committedViewport: RelayViewport? = nil,
        forceRepaint: Bool = false,
        compatibilityRepaintPulse: Bool = false
    ) -> UInt64? {
        resizeLock.lock()
        // AppKit's size report precedes Ghostty's IO-thread resize. Never
        // promote a predicted size to an engine-confirmed size: doing so can
        // invite a remote repaint while the parser still has the old grid.
        if let committedViewport {
            pendingConfirmedViewport = committedViewport
            pendingConfirmedRepaint = forceRepaint
        }
        if let expected = pendingConfirmedViewport, expected != latestViewport {
            resizeTimer.schedule(deadline: .distantFuture)
            resizeLock.unlock()
            return nil
        }
        let forceRepaint = forceRepaint || pendingConfirmedRepaint
        pendingConfirmedViewport = nil
        pendingConfirmedRepaint = false
        let viewport = latestViewport
        let transport = self.transport
        let viewportChanged = viewport != lastSentViewport
        resizeTransitionActive = false
        resizeTimer.schedule(deadline: .distantFuture)
        guard forceRepaint || viewportChanged else {
            resizeLock.unlock()
            return nil
        }
        lastSentViewport = viewport
        resizeLock.unlock()
        if committedViewport != nil { notifySidePanelViewport(viewport) }
        // Explicit stable geometry uses the acknowledged commit path whenever
        // the negotiated worker/supervisor promises exactly-one SIGWINCH. The
        // transport falls back to the ordinary resize frame for changed grids
        // on v1 peers, which could otherwise signal the TUI twice.
        return transport?.sendResize(
            columns: viewport.columns,
            rows: viewport.rows,
            forceRepaint: forceRepaint,
            viewportChanged: viewportChanged,
            compatibilityRepaintPulse: compatibilityRepaintPulse
        )
    }

    /// Returns true only when another client changed the committed PTY grid.
    /// Avoid a repaint on ordinary app activation when Relay already owns the
    /// correct dimensions.
    @discardableResult
    func reclaimNativeViewport(
        _ viewport: RelayViewport,
        compatibilityRepaintPulse: Bool
    ) -> Bool {
        resizeLock.lock()
        let needsReclaim = TerminalViewportOwnershipPolicy.needsNativeReclaim(
            native: viewport,
            committed: lastSentViewport
        )
        resizeLock.unlock()
        guard needsReclaim else { return false }
        _ = flushPendingResize(
            viewport: viewport,
            forceRepaint: true,
            compatibilityRepaintPulse: compatibilityRepaintPulse
        )
        return true
    }

    private func notifySidePanelViewport(_ viewport: RelayViewport) {
        displayQueue.async { [weak self] in
            guard let self else { return }
            for observer in self.sidePanelMirrorObservers.values {
                observer.viewportChanged(viewport)
            }
        }
    }

    /// A viewport-mismatched snapshot contributes only its durable resume
    /// cursor. Once input ownership is attached, request one fresh screen at
    /// the already measured native grid so an up-to-date cursor cannot result
    /// in a valid zero-byte replay and a blank renderer.
    func requestCurrentViewportRepaint(compatibilityRepaintPulse: Bool) {
        _ = flushPendingResize(
            forceRepaint: true,
            compatibilityRepaintPulse: compatibilityRepaintPulse
        )
    }

    func beginViewportTransition() {
        // Opening the phase is ordered with the send fence, which refuses
        // while it is open (outputPhaseIsOpen).
        outputOrderingLock.lock()
        defer { outputOrderingLock.unlock() }
        resizeLock.lock()
        pendingConfirmedViewport = nil
        pendingConfirmedRepaint = false
        resizeTransitionActive = true
        resizeTimer.schedule(deadline: .distantFuture)
        resizeLock.unlock()
        presentationLock.lock()
        viewportTransitionActive = true
        viewportTransitionFrameRows = nil
        presentationLock.unlock()
    }

    /// Start recognizing destination frames without discarding the ordered
    /// PTY stream. A resize is not an output boundary: the buffered prefix can
    /// contain an unfinished escape sequence or the shell's only prompt.
    func armViewportFrameBarrier(rows: UInt16) {
        presentationLock.lock()
        guard viewportTransitionActive else {
            presentationLock.unlock()
            return
        }
        viewportTransitionFrameStart = viewportTransitionBuffer.count
        viewportTransitionFrameRows = rows
        presentationLock.unlock()
    }

    /// Caller holds outputOrderingLock. True when a replacement was queued.
    private func finishViewportTransitionOrdered() -> Bool {
        resizeLock.lock()
        resizeTransitionActive = false
        resizeLock.unlock()
        presentationLock.lock()
        guard viewportTransitionActive else {
            presentationLock.unlock()
            return false
        }
        viewportTransitionActive = false
        let replacement = viewportTransitionBuffer
        let remoteSequence = viewportTransitionRemoteSequence
        TerminalBufferRetentionPolicy.clear(&viewportTransitionBuffer)
        viewportTransitionRemoteSequence = 0
        viewportTransitionFrameRows = nil
        viewportTransitionFrameStart = 0

        guard !replacement.isEmpty else {
            presentationLock.unlock()
            return false
        }
        // Resize does not imply a complete repaint, even on the alternate
        // screen. Preserve the application stream verbatim: a synthetic erase
        // also resets the cursor and destroys cells omitted by partial updates.

        receiveLock.lock()
        appendSnapshotLocked(replacement, remoteSequence: remoteSequence)
        receiveLock.unlock()
        // The native surface may be paused while a browser companion is live.
        // Keep one ordered display path; drainDisplay decides independently
        // whether to feed Ghostty, the side-panel observers, or both.
        enqueueDisplayWhilePresentationLocked(replacement, immediate: true)
        presentationLock.unlock()
        return true
    }

    func finishViewportTransition(
        rows: UInt16,
        completion: (@Sendable () -> Void)? = nil
    ) {
        // Ordered with the send fence: the replacement frame and its snapshot
        // bytes enter under outputOrderingLock, taken before presentationLock.
        // The completion never runs under the lock.
        outputOrderingLock.lock()
        let queued = finishViewportTransitionOrdered()
        outputOrderingLock.unlock()
        guard queued else {
            completion?()
            return
        }
        guard let completion else { return }
        // Drain explicitly so completion cannot overtake the zero-delay
        // display work item. Waiting for the in-memory backend is the parser
        // barrier that makes the following AppKit redraw deterministic.
        displayQueue.async { [weak self] in
            guard let self else { return }
            self.drainDisplay()
            self.session.waitForPendingOutput()
            completion()
        }
    }

    func setPresentationPaused(_ paused: Bool) {
        presentationLock.lock()
        guard presentationPaused != paused else {
            presentationLock.unlock()
            return
        }
        presentationPaused = paused
        // Only rendering and snapshot cadence pause. Terminal protocol state
        // remains live; a scrollback byte cache is not a parser checkpoint.
        receiveLock.lock()
        usesBackgroundSnapshotCadence = paused
        snapshotWriteWindowStartedAt = nil
        snapshotScheduledDeadline = nil
        if snapshotPaneID != nil, !snapshotBuffer.isEmpty {
            scheduleSnapshotSaveLocked()
        } else {
            snapshotSaveTimer.schedule(deadline: .distantFuture)
        }
        receiveLock.unlock()
        presentationLock.unlock()
        guard !paused else { return }
        displayQueue.async { [weak self] in
            guard let self else { return }
            self.drainDisplay()
            self.session.waitForPendingOutput()
            self.onPresentationResumed?()
        }
    }

    /// Run an ordered callback only while its producer is installed.
    @discardableResult
    func performForTransport(_ source: RelayRemoteTransport, _ operation: () -> Void) -> Bool {
        outputOrderingLock.lock()
        defer { outputOrderingLock.unlock() }
        guard acceptsOutputSource(source) else { return false }
        operation()
        return acceptsOutputSource(source)
    }

    func isCurrentOutputProducer(_ id: UUID) -> Bool {
        resizeLock.lock()
        defer { resizeLock.unlock() }
        return outputProducerID == id
    }

    /// The transport incarnation producing output, and the shell's command
    /// count and prompt state, for binding a sign-in code hand-off.
    var signInContext: (producer: UUID, execution: UInt64, promptShown: Bool) {
        resizeLock.lock()
        let producer = outputProducerID
        resizeLock.unlock()
        let prompt = semanticPromptTracker.persistentState
        return (producer, prompt.executions, prompt.promptActive)
    }

    func isCurrentTransport(_ source: RelayRemoteTransport, deliveryEpoch: UUID? = nil) -> Bool {
        acceptsOutputSource(source) &&
            (deliveryEpoch.map { source.isCurrentDeliveryEpoch($0) } ?? true)
    }

    private func acceptsOutputSource(_ source: RelayRemoteTransport?) -> Bool {
        guard let source else { return true }
        resizeLock.lock()
        let current = transport === source
        resizeLock.unlock()
        return current
    }

    /// Returns true for live output and false for buffered reconstruction data.
    @discardableResult
    func receive(_ data: Data, remoteSequence: UInt64 = 0,
        sourceTransport: RelayRemoteTransport? = nil) -> Bool {
        outputOrderingLock.lock()
        defer { outputOrderingLock.unlock() }
        guard acceptsOutputSource(sourceTransport) else { return false }
        resizeLock.lock()
        let producer = outputProducerID
        resizeLock.unlock()
        let sourceEpoch = sourceTransport?.deliveryEpochSnapshot()
        let preprocessingStartedAt = TerminalReplayTrace.enabled ? ProcessInfo.processInfo.systemUptime : 0
        bracketedPasteTracker.observe(data)
        shellInputTracker.observe(data)
        let priorExecution = semanticPromptTracker.executionGeneration
        let semanticState = semanticPromptTracker.observe(data)
        let executionChanged = semanticPromptTracker.executionGeneration != priorExecution
        replayLock.lock()
        let newExecution = TerminalPromptReconnectBoundaryPolicy.invalidatesHistory(
            executionChanged: executionChanged, replaying: replaying,
            remoteSequence: remoteSequence, knownSequence: replayKnownSequence)
        maximumObservedRemoteSequence = max(maximumObservedRemoteSequence, remoteSequence)
        replayLock.unlock()
        if newExecution { onPromptHistoryInvalidated?() }
        if let active = semanticState { onSemanticPromptStateChanged?(active) }
        // A semantic callback may recursively replace this producer.
        guard acceptsOutputSource(sourceTransport) else { return false }
        let displayData = promptWidthMode.transform(alternateScreenCleanup.transform(commandReturnCleanup.transform(data)))
        if TerminalReplayTrace.enabled {
            TerminalReplayTrace.log("preprocess pane=\(snapshotPaneID?.uuidString ?? "unknown") bytes=\(data.count) output=\(displayData.count) seconds=\(ProcessInfo.processInfo.systemUptime - preprocessingStartedAt)")
        }
        guard !displayData.isEmpty else { return true }
        replayLock.lock()
        if replaying {
            // Older workers add a sequence-zero clear before an unchanged-size
            // attach repaint. When Relay already restored an exact-viewport
            // checkpoint, that presentation-only clear erases the visible
            // Codex/Claude transcript and leaves only the prompt. Preserve the
            // retained screen and apply the following cursor-addressed repaint
            // over it. A real output reset clears this flag before replay.
            if preservesRestoredScreenOnReconnect,
               TerminalReconnectReplayPolicy.isPresentationClear(
                   displayData,
                   remoteSequence: remoteSequence
               ) {
                reconnectReplayExtendsRestoredScreen = true
                replayLock.unlock()
                return false
            }
            replayBuffer.append(displayData)
            // Never rebound while endReplay()'s commit is in flight: it
            // snapshotted bufferedCount and will slice the live tail with
            // dropFirst(bufferedCount), so rewriting the buffer here would
            // shift those offsets and drop or garble the tail.
            if replayBuffer.count > TerminalSnapshotStore.maximumBytes * 2,
               replayCommitGeneration == nil {
                replayBuffer = TerminalSnapshotStore.bounded(replayBuffer)
            }
            replayLock.unlock()
            receiveLock.lock()
            snapshotRemoteSequence = max(snapshotRemoteSequence, remoteSequence)
            receiveLock.unlock()
            scheduleLegacyReplayEnd()
            return false
        }
        replayLock.unlock()
        presentationLock.lock()
        if viewportTransitionActive {
            viewportTransitionBuffer.append(displayData)
            viewportTransitionRemoteSequence = max(
                viewportTransitionRemoteSequence, remoteSequence
            )
            if viewportTransitionBuffer.count > TerminalSnapshotStore.maximumBytes * 2 {
                viewportTransitionBuffer = TerminalSnapshotStore.bounded(viewportTransitionBuffer)
                // Compaction invalidates byte offsets. Only subsequent bytes
                // may satisfy the frame barrier; retained data still drains.
                viewportTransitionFrameStart = viewportTransitionBuffer.count
            }
            var frameReady = false
            if let rows = viewportTransitionFrameRows {
                frameReady = TerminalViewportRepaintPolicy.hasCompleteReplacement(
                    Data(viewportTransitionBuffer.dropFirst(viewportTransitionFrameStart)),
                    rows: rows
                )
            }
            let frameReadyCallback = frameReady ? onViewportFrameReady : nil
            if frameReady { viewportTransitionFrameRows = nil }
            presentationLock.unlock()
            frameReadyCallback?(producer, sourceTransport, sourceEpoch)
            return acceptsOutputSource(sourceTransport)
        }
        presentationLock.unlock()
        receiveLock.lock()
        appendSnapshotLocked(displayData, remoteSequence: remoteSequence)
        receiveLock.unlock()
        enqueueDisplay(displayData)
        return true
    }

    func configurePromptWidth(readline: Bool, promptActive: Bool) {
        outputOrderingLock.lock()
        defer { outputOrderingLock.unlock() }
        // Apply at a safe output boundary, never within a split scalar or control.
        promptWidthMode.configure(readline: readline, promptActive: promptActive)
    }

    func restoreSnapshot(paneID: UUID) -> SnapshotRestoration? {
        // The restored bytes replace the replay buffer and enter the display
        // queue; both are ordered with the send fence.
        outputOrderingLock.lock()
        defer { outputOrderingLock.unlock() }
        shellInputTracker.forget()
        let cacheStartedAt = TerminalReplayTrace.enabled ? ProcessInfo.processInfo.systemUptime : 0
        receiveLock.lock()
        snapshotPaneID = paneID
        receiveLock.unlock()
        let store = TerminalSnapshotStore.shared
        guard let cached = store.loadSnapshot(paneID: paneID, viewport: currentViewport),
              !cached.payload.isEmpty else {
            replayLock.lock()
            preservesRestoredScreenOnReconnect = false
            replayLock.unlock()
            if let resumeCursor = store.loadResumeCursor(paneID: paneID), resumeCursor > 0 {
                // The worker resumes after this cursor, so the bytes that
                // enabled bracketed paste are never replayed. Workers without
                // terminal_mode_state_v1 send no mode prelude either.
                if let saved = store.loadBracketedPasteState(paneID: paneID),
                   bracketedPasteTracker.persistentState == TerminalSnapshotTrackerState.initial.bracketedPaste {
                    bracketedPasteTracker.restore(saved)
                }
                receiveLock.lock()
                TerminalBufferRetentionPolicy.clear(&snapshotBuffer)
                // relayd resumes a valid cursor with only the bytes after it,
                // and nothing here holds their screen base: neither a truncated
                // log nor one for another viewport. Keep the rebuilt buffer
                // unreplayable until a full clear or replacement commit.
                snapshotBufferTruncated = true
                snapshotRemoteSequence = resumeCursor
                receiveLock.unlock()
                RelayDiagnostics.shared.record(
                    category: "snapshot",
                    name: "viewport-mismatch-cursor-restored",
                    details: [
                        "pane_id": paneID.uuidString.lowercased(),
                        "remote_sequence": String(resumeCursor),
                    ]
                )
                return SnapshotRestoration(
                    remoteSequence: resumeCursor,
                    rendered: false
                )
            }
            if ProcessInfo.processInfo.environment["RELAY_TERMINAL_DEBUG"] == "1" {
                let viewport = currentViewport
                FileHandle.standardError.write(Data(
                    "[RelayTerminal] pane=\(paneID.uuidString.lowercased()) snapshot=miss viewport=\(viewport.columns)x\(viewport.rows)\n".utf8
                ))
            }
            return nil
        }
        guard TerminalSnapshotDisplayPolicy.hasVisibleContent(cached.payload) else {
            replayLock.lock()
            preservesRestoredScreenOnReconnect = false
            reconnectReplayExtendsRestoredScreen = false
            replayLock.unlock()
            receiveLock.lock()
            TerminalBufferRetentionPolicy.clear(&snapshotBuffer)
            // Cursor-only like the branch above: the delta that follows has
            // lost the cached modes it was drawn under.
            snapshotBufferTruncated = true
            snapshotRemoteSequence = cached.remoteSequence
            receiveLock.unlock()
            _ = hydrateRestoreTrackers(cached, includesSemanticPrompt: false)
            RelayDiagnostics.shared.record(
                category: "snapshot",
                name: "mode-only-cursor-restored",
                details: [
                    "pane_id": paneID.uuidString.lowercased(),
                    "bytes": String(cached.payload.count),
                    "remote_sequence": String(cached.remoteSequence),
                ]
            )
            return SnapshotRestoration(
                remoteSequence: cached.remoteSequence,
                rendered: false
            )
        }
        if ProcessInfo.processInfo.environment["RELAY_TERMINAL_DEBUG"] == "1" {
            let viewport = currentViewport
            FileHandle.standardError.write(Data(
                "[RelayTerminal] pane=\(paneID.uuidString.lowercased()) snapshot=hit bytes=\(cached.payload.count) viewport=\(viewport.columns)x\(viewport.rows)\n".utf8
            ))
        }
        receiveLock.lock()
        snapshotBuffer = cached.payload
        snapshotBufferTruncated = false
        snapshotRemoteSequence = cached.remoteSequence
        receiveLock.unlock()
        replayLock.lock()
        preservesRestoredScreenOnReconnect = true
        replayLock.unlock()
        let trackersStartedAt = TerminalReplayTrace.enabled ? ProcessInfo.processInfo.systemUptime : 0
        let hydration = hydrateRestoreTrackers(cached, includesSemanticPrompt: true)
        if let active = hydration.semanticChange {
            onSemanticPromptStateChanged?(active)
        }
        if TerminalReplayTrace.enabled {
            let finishedAt = ProcessInfo.processInfo.systemUptime
            TerminalReplayTrace.log("cache-hydration pane=\(paneID.uuidString) bytes=\(cached.payload.count) loadSeconds=\(trackersStartedAt - cacheStartedAt) trackerSeconds=\(finishedAt - trackersStartedAt) trackers=\(hydration.fromCheckpoint ? "checkpoint" : "scan")")
        }
        // Historical screen bytes stay intact; only stale worker input protocols
        // identified at a known shell prompt are neutralized after hydration.
        enqueueDisplay(cached.payload + commandReturnCleanup.cachedRestoreProtocolSuffix(), immediate: true)
        // The cache is already ordered ahead of all replay output on the
        // display queue. A modern worker continuing this cursor can append
        // directly to that grid; outputReset and legacy attachment explicitly
        // invalidate this path before subsequent frames arrive.
        replayLock.lock()
        replayUsesRetainedGrid = TerminalReconnectReplayPolicy.canRetainHydratedGrid(
            remoteSequence: cached.remoteSequence,
            explicitBoundary: expectsExplicitReplayBoundary
        )
        replayLock.unlock()
        RelayDiagnostics.shared.record(category: "snapshot", name: "restored", details: [
            "pane_id": paneID.uuidString.lowercased(),
            "bytes": String(cached.payload.count),
            "remote_sequence": String(cached.remoteSequence),
        ])
        return SnapshotRestoration(
            remoteSequence: cached.remoteSequence,
            rendered: true
        )
    }

    /// Brings the restore trackers to the cached payload's end state. A log
    /// checkpoint carries that state, avoiding a scan that costs hundreds of
    /// milliseconds for a multi-megabyte agent transcript. Legacy records, and
    /// trackers that already observed output, still scan the payload.
    private func hydrateRestoreTrackers(
        _ cached: TerminalSnapshotRecordCodec.Snapshot,
        includesSemanticPrompt: Bool
    ) -> (semanticChange: Bool?, fromCheckpoint: Bool) {
        let initial = TerminalSnapshotTrackerState.initial
        if let saved = cached.trackerState,
           TerminalCommandReturnCleanup().restore(saved.commandReturn),
           TerminalSemanticPromptStateTracker().restore(saved.semanticPrompt),
           commandReturnCleanup.persistentState == initial.commandReturn,
           alternateScreenCleanup.persistentState == initial.alternateScreen,
           bracketedPasteTracker.persistentState == initial.bracketedPaste,
           !includesSemanticPrompt ||
            semanticPromptTracker.persistentState == initial.semanticPrompt {
            commandReturnCleanup.restore(saved.commandReturn)
            alternateScreenCleanup.restore(saved.alternateScreen)
            bracketedPasteTracker.restore(saved.bracketedPaste)
            guard includesSemanticPrompt else { return (nil, true) }
            semanticPromptTracker.restore(saved.semanticPrompt)
            return (saved.semanticChange, true)
        }
        commandReturnCleanup.observe(cached.payload)
        alternateScreenCleanup.observe(cached.payload)
        bracketedPasteTracker.observe(cached.payload)
        guard includesSemanticPrompt else { return (nil, false) }
        return (semanticPromptTracker.observe(cached.payload), false)
    }

    func resetRemoteSequence() {
        outputOrderingLock.lock()
        defer { outputOrderingLock.unlock() }
        shellInputTracker.forget()
        replayLock.lock()
        replayUsesRetainedGrid = false
        replayRequiresFreshBase = true
        preservesRestoredScreenOnReconnect = false
        reconnectReplayExtendsRestoredScreen =
            TerminalReconnectReplayPolicy.extendsCachedScreenAfterOutputReset(
                hasExactSnapshot: preservesRestoredScreenOnReconnect
            )
        replayLock.unlock()
        receiveLock.lock()
        // Also remove the merge base: prepare() normally extends cached data
        // when incoming bytes have no full clear. That is unsafe after a gap.
        TerminalBufferRetentionPolicy.clear(&snapshotBuffer)
        snapshotBufferTruncated = false
        snapshotRemoteSequence = 0
        receiveLock.unlock()
        onPromptHistoryInvalidated?()
        RelayDiagnostics.shared.record(category: "snapshot", name: "replay-gap-base-discarded",
            details: ["pane_id": snapshotPaneID?.uuidString.lowercased() ?? "unknown"])
    }

    func flushSnapshot() {
        receiveLock.lock()
        let paneID = snapshotPaneID
        let snapshot = snapshotBuffer
        let truncated = snapshotBufferTruncated
        let remoteSequence = snapshotRemoteSequence
        snapshotWriteWindowStartedAt = nil
        snapshotScheduledDeadline = nil
        snapshotSaveTimer.schedule(deadline: .distantFuture)
        receiveLock.unlock()
        if let paneID, !snapshot.isEmpty {
            TerminalSnapshotStore.shared.saveSynchronously(
                snapshot, paneID: paneID, viewport: currentViewport,
                remoteSequence: remoteSequence, truncated: truncated
            )
        }
    }

    func beginReplay() {
        outputOrderingLock.lock()
        defer { outputOrderingLock.unlock() }
        invalidatePromptEditorRestorationBarrier()
        replayLock.lock()
        if !replaying { replayKnownSequence = maximumObservedRemoteSequence }
        if !replaying { replayUsesRetainedGrid = hasCommittedReplay && expectsExplicitReplayBoundary }
        if !replaying { TerminalBufferRetentionPolicy.clear(&replayBuffer) }
        replaying = true
        reconnectReplayExtendsRestoredScreen = false
        replayCommitGeneration = nil
        suppressingTerminalWrites = true
        filterDeviceResponsesUntil = Date().addingTimeInterval(5)
        // Pre-caught_up workers can redraw continuously (Codex and Claude do),
        // so an idle-only boundary would leave the opaque restore layer up
        // forever. Bound that compatibility path while newer workers still end
        // reconstruction immediately with their explicit caught_up status.
        let explicitBoundary = expectsExplicitReplayBoundary
        legacyReplayHardDeadline = explicitBoundary
            ? .now() + .seconds(30)
            : .now() + .milliseconds(750)
        replayGeneration &+= 1
        let explicitDeadline = legacyReplayHardDeadline
        replayLock.unlock()
        if explicitBoundary {
            legacyReplayTimer.schedule(deadline: explicitDeadline, leeway: .seconds(1))
        } else {
            scheduleLegacyReplayEnd()
        }
    }

    func setProgramStatusReplyOwnership(_ enabled: Bool) {
        replayLock.lock()
        programStatusReplyOwnedByWorker = enabled
        replayLock.unlock()
    }

    func setExplicitReplayBoundary(_ enabled: Bool) {
        // May reopen a replay, so it is ordered with the send fence.
        outputOrderingLock.lock()
        defer { outputOrderingLock.unlock() }
        replayLock.lock()
        expectsExplicitReplayBoundary = enabled
        if enabled {
            // SSH setup may finish while the short compatibility timeout is
            // already compacting. The authoritative worker boundary wins:
            // cancel that provisional commit but retain its buffer so the
            // ordered caught_up commit contains every acknowledged byte.
            if replayCommitGeneration != nil {
                replayGeneration &+= 1
                replayCommitGeneration = nil
            }
            // `attached` is ordered before replay frames, but SSH setup can
            // outlast the legacy 750 ms timer armed at launch. Re-enter replay
            // here when that timer already fired so no frame can escape into
            // Ghostty's per-write queue. A long failsafe prevents a broken
            // worker from holding the restore layer forever.
            if !replaying {
                TerminalBufferRetentionPolicy.clear(&replayBuffer)
                replaying = true
                suppressingTerminalWrites = true
                filterDeviceResponsesUntil = Date().addingTimeInterval(5)
                replayGeneration &+= 1
            }
            legacyReplayHardDeadline = .now() + .seconds(30)
            legacyReplayTimer.schedule(deadline: legacyReplayHardDeadline, leeway: .seconds(1))
        } else if replaying {
            replayUsesRetainedGrid = false
            // A downgraded worker has no caught_up marker. Restore the bounded
            // compatibility path instead of leaving its replay open forever.
            legacyReplayHardDeadline = .now() + .milliseconds(750)
            replayGeneration &+= 1
            legacyReplayGeneration = replayGeneration
            legacyReplayTimer.schedule(deadline: legacyReplayHardDeadline)
        }
        replayLock.unlock()
    }

    func endReplay() {
        replayLock.lock()
        guard replaying, replayCommitGeneration == nil else {
            replayLock.unlock()
            return
        }
        replayGeneration &+= 1
        let generation = replayGeneration
        replayCommitGeneration = generation
        let buffered = replayBuffer
        let bufferedCount = buffered.count
        let preservesCachedBase = reconnectReplayExtendsRestoredScreen
        let retainGrid = replayUsesRetainedGrid
        let requiresFreshBase = replayRequiresFreshBase
        TerminalReplayTrace.log("endReplay pane=\(snapshotPaneID?.uuidString ?? "unknown") incoming=\(buffered.count) retain=\(retainGrid)")
        legacyReplayHardDeadline = .distantFuture
        legacyReplayTimer.schedule(deadline: .distantFuture)
        replayLock.unlock()
        RelayDiagnostics.shared.record(category: "snapshot", name: "worker-replay-base", details: [
            "pane_id": snapshotPaneID?.uuidString.lowercased() ?? "unknown",
            "bytes": String(bufferedCount),
            "retained_grid": String(retainGrid),
            "visible_content": String(TerminalSnapshotDisplayPolicy.hasVisibleContent(buffered)),
        ])

        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let self else { return }
            self.receiveLock.lock()
            let cached = self.snapshotBuffer
            self.receiveLock.unlock()
            let replacement = retainGrid ? buffered : TerminalReplayCommit.prepare(
                cached: cached,
                incoming: buffered,
                preserveCachedBase: preservesCachedBase,
                requiresFreshBase: requiresFreshBase
            )

            // Keep the replay gate closed while the expensive compaction runs.
            // Fresh PTY bytes accumulate after `buffered`; enqueue the reset,
            // reconstruction, and that live tail as one ordered display commit
            // before reopening the live path. Previously `replaying` became
            // false above, allowing the tail to overtake the reconstruction.
            // outputOrderingLock first (the order receive() uses), so the
            // commit is ordered with the send fence.
            self.outputOrderingLock.lock()
            self.replayLock.lock()
            guard self.replaying,
                  self.replayGeneration == generation,
                  self.replayCommitGeneration == generation else {
                self.replayLock.unlock()
                self.outputOrderingLock.unlock()
                return
            }
            let liveTail: Data
            if self.replayBuffer.count > bufferedCount {
                liveTail = Data(self.replayBuffer.dropFirst(bufferedCount))
            } else {
                liveTail = Data()
            }
            let commit = TerminalReplayCommit.appendingLiveTail(liveTail, to: replacement)
            TerminalReplayTrace.log("commit pane=\(self.snapshotPaneID?.uuidString ?? "unknown") cached=\(cached.count) replacement=\(replacement.count) tail=\(liveTail.count) visible=\(TerminalSnapshotDisplayPolicy.hasVisibleContent(commit))")
            if !commit.isEmpty {
                self.receiveLock.lock()
                let bounded = TerminalSnapshotStore.boundedReportingTruncation(
                    retainGrid ? self.snapshotBuffer + commit : commit
                )
                // A cut base survives unless the commit replaced it outright.
                self.snapshotBufferTruncated = bounded.truncated ||
                    (self.snapshotBufferTruncated && (retainGrid || !requiresFreshBase))
                self.snapshotBuffer = bounded.data
                self.scheduleSnapshotSaveLocked()
                self.receiveLock.unlock()
                // receive() cannot pass replayLock until this has entered the
                // display queue, so later live frames cannot overtake it.
                self.replayCommitWillEnqueueForTesting?()
                self.enqueueDisplay(commit, immediate: true)
            }
            TerminalBufferRetentionPolicy.clear(&self.replayBuffer)
            self.replaying = false
            self.hasCommittedReplay = true
            self.replayUsesRetainedGrid = false
            self.preservesRestoredScreenOnReconnect = false
            self.reconnectReplayExtendsRestoredScreen = false
            self.replayRequiresFreshBase = false
            self.replayCommitGeneration = nil
            self.replayLock.unlock()
            self.outputOrderingLock.unlock()

            // Publish as soon as the parser barrier completes. Device-query
            // suppression is a separate guard and must not delay first paint.
            self.displayQueue.async { [weak self] in
                guard let self else { return }
                self.drainDisplay()
                self.session.waitForPendingOutput()
                self.replayLock.lock()
                let finished = !self.replaying && self.replayGeneration == generation
                self.replayLock.unlock()
                guard finished else { return }
                self.onReplayFinished?(retainGrid || TerminalSnapshotDisplayPolicy.hasVisibleContent(commit))
                // Keep asynchronous renderer replies local for two more frames,
                // without holding the user's restored screen behind a timer.
                self.displayQueue.asyncAfter(deadline: .now() + .milliseconds(150)) { [weak self] in
                    guard let self else { return }
                    self.replayLock.lock()
                    let resumed = !self.replaying && self.replayGeneration == generation
                    if resumed {
                        self.suppressingTerminalWrites = false
                    }
                    self.replayLock.unlock()
                    if resumed { self.onReplayWritesResumed?() }
                }
            }
        }
    }

    /// The worker emits `caught_up` before it consumes the viewport frame that
    /// follows the attach acknowledgement. Keep reconstruction buffered long
    /// enough to include the resulting SIGWINCH redraw, then reveal one
    /// correctly-sized screen rather than historical cursor-addressed output.
    func endReplayAfterViewportSettle() {
        replayLock.lock()
        let generation = replayGeneration
        replayLock.unlock()
        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + .milliseconds(120)
        ) { [weak self] in
            guard let self else { return }
            self.replayLock.lock()
            let isCurrent = self.replaying && self.replayGeneration == generation
            self.replayLock.unlock()
            if isCurrent { self.endReplay() }
        }
    }

    private func appendSnapshotLocked(_ data: Data, remoteSequence: UInt64) {
        guard snapshotPaneID != nil else { return }
        snapshotBuffer.append(data)
        snapshotRemoteSequence = max(snapshotRemoteSequence, remoteSequence)
        // Trim once past the storage bound, down to a lower target, so later
        // packets append without rescanning and saves never need compaction.
        if TerminalSnapshotCompactionPolicy.shouldCompact(byteCount: snapshotBuffer.count) {
            // Compaction rebuilds from the latest full clear, which restores a
            // complete base; only a suffix cut leaves the buffer without one.
            let trimmed = TerminalSnapshotCompactionPolicy.trim(snapshotBuffer)
            snapshotBuffer = trimmed.data
            snapshotBufferTruncated = trimmed.truncated
        }
        scheduleSnapshotSaveLocked()
    }

    private func scheduleSnapshotSaveLocked() {
        guard snapshotPaneID != nil else { return }
        let now = DispatchTime.now()
        if snapshotWriteWindowStartedAt == nil {
            snapshotWriteWindowStartedAt = now
        }
        let debounceMilliseconds = usesBackgroundSnapshotCadence
            ? TerminalSnapshotWritePolicy.backgroundDebounceMilliseconds
            : TerminalSnapshotWritePolicy.debounceMilliseconds
        let maximumIntervalMilliseconds = usesBackgroundSnapshotCadence
            ? TerminalSnapshotWritePolicy.backgroundMaximumIntervalMilliseconds
            : TerminalSnapshotWritePolicy.maximumIntervalMilliseconds
        let debounceDeadline = now + .milliseconds(
            debounceMilliseconds
        )
        let maximumDeadline = snapshotWriteWindowStartedAt! + .milliseconds(
            maximumIntervalMilliseconds
        )
        let deadline = min(debounceDeadline, maximumDeadline)
        // Reprogramming a DispatchSourceTimer for every PTY packet becomes a
        // kernel-event hot loop for htop and agent TUIs. Move the deadline at
        // most four times per second; the normal debounce remains accurate to
        // 250 ms and the hard five-second persistence bound is unchanged.
        let minimumMove = UInt64(250_000_000)
        if let scheduled = snapshotScheduledDeadline,
           deadline.uptimeNanoseconds <= scheduled.uptimeNanoseconds &+ minimumMove {
            return
        }
        snapshotScheduledDeadline = deadline
        snapshotSaveTimer.schedule(
            deadline: deadline,
            leeway: .milliseconds(TerminalSnapshotWritePolicy.leewayMilliseconds)
        )
    }

    private func savePendingSnapshot() {
        receiveLock.lock()
        guard let paneID = snapshotPaneID, !snapshotBuffer.isEmpty else {
            receiveLock.unlock()
            return
        }
        let snapshot = snapshotBuffer
        let truncated = snapshotBufferTruncated
        let remoteSequence = snapshotRemoteSequence
        snapshotWriteWindowStartedAt = nil
        snapshotScheduledDeadline = nil
        snapshotSaveTimer.schedule(deadline: .distantFuture)
        receiveLock.unlock()

        TerminalSnapshotStore.shared.save(
            snapshot, paneID: paneID, viewport: currentViewport,
            remoteSequence: remoteSequence, truncated: truncated
        )
    }

    /// Sends input only if the live screen an admission judged is still the
    /// settled native screen. The check and the transport's recording of the
    /// packet happen under outputOrderingLock; the transport writes
    /// asynchronously, so the lock is never held across network I/O.
    func sendUserInput(_ data: Data, expectedLiveScreen live: RelayActiveScreenCache.Key?,
                       expectedMaintenanceScreen screen: MaintenanceScreenToken?) -> Bool {
        guard live != nil || screen != nil else { return false }
        outputOrderingLock.lock()
        defer { outputOrderingLock.unlock() }
        guard screen.map({ maintenanceScreenIsCurrent($0) }) ?? true,
              live.map({ liveScreenIsSettled($0) }) ?? true else { return false }
        fenceCheckedForTesting?()
        return sendUserInput(data)
    }

    @discardableResult
    func sendUserInput(_ data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        RelayPerformance.shared.recordTerminalInput(bytes: data.count)
        resizeLock.lock()
        let transport = self.transport
        resizeLock.unlock()
        recordInputDiagnostic("bridge-send", details: [
            "bytes": String(data.count),
            "transport": String(transport != nil),
        ])
        return transport?.sendInput(data) ?? false
    }

    /// Sends only the terminal's native interrupt byte. The supervisor cannot
    /// inject prompts or shell commands through this capability.
    var canSendSupervisorInterrupt: Bool {
        resizeLock.lock()
        let available = transport != nil
        resizeLock.unlock()
        return available
    }

    func sendSupervisorInterrupt() -> Bool {
        resizeLock.lock()
        let transport = self.transport
        resizeLock.unlock()
        guard let transport else { return false }
        transport.sendInput(Data([0x03]))
        return true
    }

    func sendPromptControlInput(_ data: Data) {
        guard !data.isEmpty else { return }
        if capturePromptControlWrite(data) { return }
        sendUserInput(data)
    }

    func beginPromptControlCapture(expectedControlLease lease: RelayPromptEditorControlLease) -> Bool {
        resizeLock.lock()
        let originalTransport = transport
        resizeLock.unlock()
        guard let originalTransport,
              originalTransport.promptEditorControlLease(paneID: lease.paneID, hostID: lease.hostID,
                requireIdleInput: false) == lease else { return false }

        let thread = pthread_mach_thread_np(pthread_self())
        promptControlLock.lock()
        guard promptControlCaptureThread == nil else {
            promptControlLock.unlock()
            return false
        }
        promptControlCaptureThread = thread
        promptControlCaptureIdentity = UUID()
        promptControlCaptureTransport = originalTransport
        promptControlCaptureLease = lease
        promptControlCaptureBuffer.reset()
        promptControlLock.unlock()
        return true
    }

    func appendPromptControlPaste(_ text: String) -> Bool {
        guard let encoded = TerminalPastePayload.encodedPayload(for: text,
            bracketed: isBracketedPasteActive) else { return false }
        return capturePromptControlWrite(encoded)
    }

    var currentPromptControlCaptureIdentity: UUID? {
        promptControlLock.lock()
        defer { promptControlLock.unlock() }
        guard promptControlCaptureThread == pthread_mach_thread_np(pthread_self()) else { return nil }
        return promptControlCaptureIdentity
    }

    func appendNativePromptControlInput(_ data: Data, expectedCapture: UUID) -> Bool {
        capturePromptControlWrite(data, expectedCapture: expectedCapture)
    }

    func cancelPromptControlCapture(expectedCapture: UUID? = nil) {
        let thread = pthread_mach_thread_np(pthread_self())
        promptControlLock.lock()
        defer { promptControlLock.unlock() }
        guard promptControlCaptureThread == thread,
              expectedCapture == nil || expectedCapture == promptControlCaptureIdentity else { return }
        promptControlCaptureBuffer.reset()
        promptControlCaptureThread = nil
        promptControlCaptureIdentity = nil
        promptControlCaptureTransport = nil
        promptControlCaptureLease = nil
    }

    @discardableResult
    func endPromptControlCapture(expectedCapture: UUID? = nil) -> Bool {
        let thread = pthread_mach_thread_np(pthread_self())
        promptControlLock.lock()
        guard promptControlCaptureThread == thread,
              expectedCapture == nil || expectedCapture == promptControlCaptureIdentity else {
            promptControlLock.unlock()
            return false
        }
        let translated = promptControlCaptureBuffer.take()
        let originalTransport = promptControlCaptureTransport
        let lease = promptControlCaptureLease
        promptControlCaptureThread = nil
        promptControlCaptureIdentity = nil
        promptControlCaptureTransport = nil
        promptControlCaptureLease = nil
        promptControlLock.unlock()
        guard let translated, let originalTransport, let lease else { return false }
        resizeLock.lock()
        let admitted = transport === originalTransport
            ? originalTransport.preparePromptControlInput(translated, expectedControlLease: lease) : nil
        resizeLock.unlock()
        // Admission was atomic with the original IO pointer check; callbacks
        // can now replace the connection without reentering either IO lock.
        return admitted?.dispatch() == true
    }

    func sendPromptEditorControlInput(_ data: Data,
        expectedControlLease lease: RelayPromptEditorControlLease,
        expectedMaintenanceScreen screen: MaintenanceScreenToken? = nil,
        expectedLiveScreen live: RelayActiveScreenCache.Key? = nil,
        automation: Bool = false, requireAutomation: Bool = false) -> Bool {
        outputOrderingLock.lock()
        guard screen.map({ maintenanceScreenIsCurrent($0) }) ?? true,
              live.map({ liveScreenIsSettled($0) }) ?? true else {
            outputOrderingLock.unlock()
            return false
        }
        fenceCheckedForTesting?()
        resizeLock.lock()
        let admitted = transport?.preparePromptControlInput(data, expectedControlLease: lease,
            automation: automation, requireAutomation: requireAutomation)
        resizeLock.unlock()
        outputOrderingLock.unlock()
        return admitted?.dispatch() == true
    }

    private func capturePromptControlWrite(_ data: Data, expectedCapture: UUID? = nil) -> Bool {
        let thread = pthread_mach_thread_np(pthread_self())
        promptControlLock.lock()
        guard promptControlCaptureThread == thread,
              expectedCapture == nil || expectedCapture == promptControlCaptureIdentity else {
            promptControlLock.unlock()
            return false
        }
        // Once overflowed, swallow the rest of the edit too. Sending an
        // earlier prefix could move/delete a different range than intended.
        promptControlCaptureBuffer.append(data)
        promptControlLock.unlock()
        return true
    }

    private func forwardTerminalWrite(_ data: Data) {
        if capturePromptControlWrite(data) {
            recordInputDiagnostic("ghostty-write-captured", details: [
                "bytes": String(data.count),
            ])
            return
        }
        replayLock.lock()
        let filterDeviceResponses = suppressingTerminalWrites || Date() < filterDeviceResponsesUntil
        let programStatusReplyOwnedByWorker = self.programStatusReplyOwnedByWorker
        replayLock.unlock()
        // Ghostty reports both real user input and renderer-generated terminal
        // replies through this callback. Replay reconstruction must filter the
        // latter, but it must never make the keyboard read-only. The transport
        // already queues input safely until the remote attach completes.
        let shouldForward = TerminalWriteForwardingPolicy.shouldForward(
            data,
            filteringDeviceResponses: filterDeviceResponses,
            programStatusReplyOwnedByWorker: programStatusReplyOwnedByWorker
        )
        recordInputDiagnostic("ghostty-write", details: [
            "bytes": String(data.count),
            "filtering": String(filterDeviceResponses),
            "forwarded": String(shouldForward),
            "terminal_report": TerminalInputDiagnosticReport.name(data),
        ])
        guard shouldForward else { return }
        sendUserInput(data)
    }

    private func recordInputDiagnostic(
        _ name: String,
        details: [String: String]
    ) {
        receiveLock.lock()
        let paneID = snapshotPaneID?.uuidString.lowercased() ?? "unknown"
        receiveLock.unlock()
        var metadata = details
        metadata["pane_id"] = paneID
        RelayDiagnostics.shared.record(
            category: "terminal-input",
            name: name,
            details: metadata
        )
    }

    // Workers released before the caught_up marker remain attachable. One
    // reschedulable timer handles their idle boundary without enqueuing a timer
    // for every replay frame.
    private func scheduleLegacyReplayEnd() {
        replayLock.lock()
        guard replaying, !expectsExplicitReplayBoundary else {
            replayLock.unlock()
            return
        }
        replayGeneration &+= 1
        legacyReplayGeneration = replayGeneration
        legacyReplayTimer.schedule(deadline: min(.now() + .seconds(1), legacyReplayHardDeadline))
        replayLock.unlock()
    }

    private func finishLegacyReplayIfIdle() {
        replayLock.lock()
        let hardDeadlineReached = DispatchTime.now() >= legacyReplayHardDeadline
        let shouldFinish = replaying && (replayGeneration == legacyReplayGeneration || hardDeadlineReached)
        replayLock.unlock()
        if shouldFinish { endReplay() }
    }

    func receiveInlineImageOrdered(_ data: Data, imageID: UInt32) {
        var encoded = Data()
        for packet in KittyImageEncoder.packets(for: data, imageID: imageID) {
            encoded.append(packet)
        }
        replayLock.lock()
        if replaying {
            replayBuffer.append(encoded)
            replayLock.unlock()
            return
        }
        replayLock.unlock()
        enqueueDisplay(encoded)
    }

    /// Collapse a burst of PTY frames into one Ghostty write. The dependency's
    /// in-memory surface queues one GCD closure per call, so forwarding every
    /// 4–8 KiB SSH packet can retain gigabytes during a repaint storm. One
    /// scheduled drain preserves byte order and interactive latency while a
    /// high-water compaction makes overload memory-bounded.
    /// Every display producer enters here or holds outputOrderingLock around
    /// enqueueDisplayWhilePresentationLocked: the one ordering boundary with
    /// the live-screen send fence. Lock order: outputOrderingLock, then
    /// replayLock / presentationLock / receiveLock / displayLock.
    private func enqueueDisplay(_ data: Data, immediate: Bool = false) {
        guard !data.isEmpty else { return }
        outputOrderingLock.lock()
        defer { outputOrderingLock.unlock() }
        presentationLock.lock()
        // Native and browser parsers consume the same lossless ordered stream,
        // even while rendering is occluded.
        enqueueDisplayWhilePresentationLocked(data, immediate: immediate)
        presentationLock.unlock()
    }

    /// Caller owns presentationLock so resume catch-up is ordered before the
    /// first newly arriving live frame.
    private func enqueueDisplayWhilePresentationLocked(_ data: Data, immediate: Bool) {
        displayLock.lock()
        displayBuffer.append(data)
        displayBytesInTransit += data.count
        if observedRepaint != nil {
            let event = observedRepaint?.tracker.observe(data)
            if event == .completedFrame {
                pendingObservedRepaintFrame = observedRepaint?.id
                observedRepaint?.tracker.disarm()
            }
        }
        // This is live protocol data, not a scrollback cache. Cutting its
        // prefix can remove half an escape sequence, a mode change, or the
        // saved primary screen. The ordered drain must deliver every byte.
        guard !displayDrainScheduled else {
            displayLock.unlock()
            return
        }
        displayDrainScheduled = true
        let elapsed = lastDisplayDrainUptime.map {
            Double(DispatchTime.now().uptimeNanoseconds &- $0) / 1_000_000
        }
        let delay = TerminalDisplayBatchPolicy.drainDelayMilliseconds(
            immediate: immediate, pendingBytes: displayBuffer.count, millisecondsSinceLastDrain: elapsed
        )
        displayLock.unlock()
        displayQueue.asyncAfter(deadline: .now() + .milliseconds(delay)) { [weak self] in
            self?.drainDisplay()
        }
    }

    private func drainDisplay() {
        presentationLock.lock()
        displayLock.lock()
        let batch = displayBuffer
        let observedFrameID = pendingObservedRepaintFrame
        pendingObservedRepaintFrame = nil
        displayBuffer = Data()
        displayDrainScheduled = false
        lastDisplayDrainUptime = DispatchTime.now().uptimeNanoseconds
        displayLock.unlock()
        // Hide rendering, not terminal emulation. A bounded byte suffix cannot
        // reconstruct an arbitrary terminal, especially after an alternate-
        // screen exit. Keeping the parser current also avoids a large catch-up
        // burst on tab return; occlusion already stops the Metal display link.
        presentationLock.unlock()
        guard !batch.isEmpty else { return }
        deliverDisplayBatch(batch, observedFrameID: observedFrameID)
        displayLock.lock()
        displayBytesInTransit -= batch.count
        displayLock.unlock()
    }

    /// Whether the native screen still shows exactly `expected` and every
    /// output byte this bridge has received is already parsed into it: nothing
    /// in the display pipeline, nothing queued in the session, no mutation in
    /// flight, and a fresh state, rows, state sample equal to the admitted
    /// one. The caller holds outputOrderingLock, so receive() cannot accept
    /// more output until the caller's input is recorded by the transport.
    /// Received output can wait before display in four places: the replay
    /// buffer (while a replay or its commit is open), the viewport-transition
    /// buffer (while a transition is open), the display buffer (counted in
    /// displayBytesInTransit) and the session's queue. The first two are
    /// covered by phase: while either phase is open no fenced send passes,
    /// whether or not bytes are buffered yet. Caller holds outputOrderingLock;
    /// every opener and closer of these phases takes it.
    private func outputPhaseIsOpen() -> Bool {
        phaseReadWillLockReplayForTesting?()
        replayLock.lock()
        let replayOpen = replaying || replayCommitGeneration != nil
        replayLock.unlock()
        presentationLock.lock()
        let transitionOpen = viewportTransitionActive
        presentationLock.unlock()
        return replayOpen || transitionOpen
    }

    /// An unlocked read of the phase, for admissions and tests. Only the read
    /// under outputOrderingLock inside the send fence decides a send.
    var outputPhaseOpenNow: Bool { outputPhaseIsOpen() }

    /// Read-only admission for retained renderers. A stable native grid alone
    /// is insufficient when new output is still in the display pipeline or
    /// the transport that supplied it has retired.
    func nativeEditingScreenIsCurrent(_ expected: RelayActiveScreenCache.Key) -> Bool {
        outputOrderingLock.lock()
        defer { outputOrderingLock.unlock() }
        resizeLock.lock()
        let connected = transport != nil
        resizeLock.unlock()
        return connected && liveScreenIsSettled(expected)
    }

    private func liveScreenIsSettled(_ expected: RelayActiveScreenCache.Key) -> Bool {
        let phaseOpen = outputPhaseIsOpen()
        displayLock.lock()
        let inTransit = displayBytesInTransit
        displayLock.unlock()
        let session = session
        return Self.liveScreenIsSettled(outputPhaseOpen: phaseOpen, displayBytesInTransit: inTransit,
            sessionPendingBytes: { session.pendingOutputByteCount },
            sample: { session.activeScreenSample() }, expected: expected)
    }

    /// Read in pipeline order: bytes leave the display buffer only after they
    /// are queued in the session, and leave the session queue only with the
    /// in-flight flag set, so a byte moving between reads is still seen.
    static func liveScreenIsSettled(outputPhaseOpen: Bool, displayBytesInTransit: Int, sessionPendingBytes: () -> Int,
        sample: () -> RelayActiveScreenCache.Sample, expected: RelayActiveScreenCache.Key) -> Bool {
        guard !outputPhaseOpen else { return false }
        guard displayBytesInTransit == 0, sessionPendingBytes() == 0 else { return false }
        return sample() == .stable(expected)
    }

    private func deliverDisplayBatch(
        _ batch: Data,
        toNative: Bool = true,
        toMirrors: Bool = true,
        observedFrameID: UUID? = nil
    ) {
        autoreleasepool {
            if !toNative, (!toMirrors || sidePanelMirrorObservers.isEmpty) {
                return
            }
            // PTY packets may split OSC/DCS/CSI or UTF-8 at any byte. A
            // packet-local hyperlink decorator cannot know whether a path is
            // visible text or the continuation of a control string. Preserve
            // the wire stream; link detection belongs to parsed screen text.
            if toNative {
                let frameEvent = editorFrameTracker.observe(batch)
                session.receive(batch)
                if let observedFrameID {
                    session.waitForPendingOutput()
                    displayLock.lock()
                    var completed: UUID?
                    if observedRepaint?.id == observedFrameID {
                        observedRepaint?.frameParsed = true
                        if observedRepaint?.waitingForCommit == false {
                            completed = observedFrameID
                            observedRepaint = nil
                        }
                    }
                    displayLock.unlock()
                    if let completed { onObservedRepaintFrame?(completed) }
                }
                if let frameEvent, let pending = pendingEditorRestoration {
                    switch frameEvent {
                    case .overflow:
                        pendingEditorRestoration = nil
                        pending.continuation.yield(.invalidated)
                        pending.continuation.finish()
                    case .completedFrame:
                        // Notification follows actual parser completion, not a
                        // damage callback or a raw network packet.
                        session.waitForPendingOutput()
                        let revision = session.parsedHostOutputRevision
                        if revision != pending.baseline {
                            pending.continuation.yield(.parsedFrame(revision: revision))
                        } else {
                            pending.continuation.yield(.hostFrame)
                        }
                    }
                }
            }
            if toMirrors {
                for observer in sidePanelMirrorObservers.values {
                    observer.deliver(batch)
                }
            }
            RelayPerformance.shared.recordTerminalBatch(
                bytes: batch.count,
                pendingBytes: session.pendingOutputByteCount
            )
        }
    }
}

/// Tracks the shell's semantic input region directly from OSC 133. Older
/// durable relayd workers may predate OSC 7 working-directory callbacks, but
/// their prompt still emits `133;B` and `133;C`. Keeping this small state
/// machine in the transport makes remote click-to-move use the same prompt
/// safety gate as a local shell without depending on packet boundaries.
/// Whether the shell's command line is provably empty, from the remote byte
/// stream alone: an OSC 133;B (input begins) has been seen and nothing the
/// shell echoes has followed it. Escape sequences do not count; any printable
/// or editing byte does. Unknown (not empty) until a B arrives in this
/// process's stream, after a restore or an output reset, and after 133;A/P/C/D.
/// Hidden panes have no live prompt mirror, so this is how a maintenance
/// resume proves the retained shell prompt is empty.
final class TerminalShellInputTracker: @unchecked Sendable {
    private enum State { case ground, escape, csi, osc, oscEscape }
    private let lock = NSLock()
    private var state = State.ground
    private var payload: [UInt8] = []
    private var awaitingInput = false
    private var echoed = 0

    var inputIsEmpty: Bool {
        lock.lock(); defer { lock.unlock() }
        return awaitingInput && echoed == 0
    }

    func forget() {
        lock.lock(); defer { lock.unlock() }
        awaitingInput = false
        echoed = 0
        state = .ground
        payload.removeAll(keepingCapacity: true)
    }

    func observe(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        for byte in data {
            switch state {
            case .ground:
                if byte == 0x1B { state = .escape } else if awaitingInput { echoed &+= 1 }
            case .escape:
                switch byte {
                case 0x5B: state = .csi                      // ESC [
                case 0x5D: payload.removeAll(keepingCapacity: true); state = .osc // ESC ]
                case 0x1B: state = .escape
                default: state = .ground                     // two-byte escape
                }
            case .csi:
                if (0x40...0x7E).contains(byte) { state = .ground }
            case .osc:
                if byte == 0x07 { finish(); state = .ground }
                else if byte == 0x1B { state = .oscEscape }
                else if payload.count < 16 { payload.append(byte) }
            case .oscEscape:
                if byte == 0x5C { finish(); state = .ground } else { state = .osc }
            }
        }
    }

    private func finish() {
        defer { payload.removeAll(keepingCapacity: true) }
        guard payload.count >= 5, payload[0] == 0x31, payload[1] == 0x33, payload[2] == 0x33,
              payload[3] == 0x3B else { return }
        switch payload[4] {
        case 0x42: awaitingInput = true; echoed = 0          // B: input begins
        case 0x41, 0x50, 0x43, 0x44: awaitingInput = false   // A, P, C, D
        default: break
        }
    }
}

final class TerminalSemanticPromptStateTracker: @unchecked Sendable {
    private enum ParserState {
        case ground
        case escape
        case osc
        case oscEscape
    }

    private let lock = NSLock()
    private var parserState = ParserState.ground
    private var payload: [UInt8] = []
    private var promptActive = false
    private var executions: UInt64 = 0

    var executionGeneration: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return executions
    }

    /// Returns the newest prompt state only when a complete semantic marker
    /// changes it. Other OSC payloads are ignored and bounded to avoid retaining
    /// terminal titles or clipboard data.
    func observe(_ data: Data) -> Bool? {
        guard !data.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        var changed: Bool?
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
          var index = 0
          while index < bytes.count {
            // Ordinary ground-state bytes cannot change this OSC-only tracker.
            // Avoid Foundation's per-byte Data iterator on large checkpoints.
            if parserState == .ground {
                while index < bytes.count && bytes[index] != 0x1B { index += 1 }
                if index == bytes.count { break }
            }
            let byte = bytes[index]
            index += 1
            switch parserState {
            case .ground:
                if byte == 0x1B { parserState = .escape }
            case .escape:
                if byte == 0x5D { // ESC ]
                    payload.removeAll(keepingCapacity: true)
                    parserState = .osc
                } else {
                    parserState = byte == 0x1B ? .escape : .ground
                }
            case .osc:
                if byte == 0x07 { // BEL terminator
                    changed = finishPayload() ?? changed
                    parserState = .ground
                } else if byte == 0x1B {
                    parserState = .oscEscape
                } else if payload.count < 64 {
                    payload.append(byte)
                }
            case .oscEscape:
                if byte == 0x5C { // ST: ESC \
                    changed = finishPayload() ?? changed
                    parserState = .ground
                } else {
                    if payload.count < 63 {
                        payload.append(0x1B)
                        payload.append(byte)
                    }
                    parserState = .osc
                }
            }
          }
        }
        return changed
    }

    private func finishPayload() -> Bool? {
        defer { payload.removeAll(keepingCapacity: true) }
        guard payload.count >= 5,
              payload[0] == 0x31, payload[1] == 0x33, payload[2] == 0x33,
              payload[3] == 0x3B else { return nil }
        let active: Bool
        switch payload[4] {
        case 0x42: active = true  // OSC 133;B — command input begins
        case 0x43: executions &+= 1; active = false // OSC 133;C — command execution begins
        default: return nil
        }
        guard active != promptActive else { return nil }
        promptActive = active
        return active
    }
}

/// Tracks alternate-screen ownership without rewriting application output.
/// Leaving the alternate screen restores the saved primary screen and cursor.
/// Injecting a clear/home here destroys that state behind the application's
/// incremental renderer, corrupting its next partial redraw.
final class TerminalAlternateScreenCleanupFilter: @unchecked Sendable {
    private static let entries = [
        Array("\u{001B}[?1049h".utf8),
        Array("\u{001B}[?1047h".utf8),
        Array("\u{001B}[?47h".utf8),
    ]
    private static let exits = [
        Array("\u{001B}[?1049l".utf8),
        Array("\u{001B}[?1047l".utf8),
        Array("\u{001B}[?47l".utf8),
    ]
    private static let modeMarker = Data([0x1B, 0x5B, 0x3F]) // ESC [ ?

    private let lock = NSLock()
    private var pending: [UInt8] = []
    private var inAlternateScreen = false

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return inAlternateScreen
    }

    func transform(_ data: Data) -> Data {
        scan(data, emitsOutput: true)
    }

    private func scan(_ data: Data, emitsOutput: Bool) -> Data {
        guard !data.isEmpty else { return data }
        lock.lock()
        if pending.isEmpty,
           data.range(of: Self.modeMarker) == nil,
           !Self.endsWithCandidatePrefix(data) {
            lock.unlock()
            return data
        }
        defer { lock.unlock() }
        var output = Data()
        if emitsOutput { output.reserveCapacity(data.count) }
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var index = 0
            while index < bytes.count {
                if pending.isEmpty, bytes[index] != 0x1B {
                    let start = index
                    repeat { index += 1 } while index < bytes.count && bytes[index] != 0x1B
                    // Copy ordinary text as one span. Appending each byte to
                    // Foundation Data dominated multi-megabyte replay handling.
                    if emitsOutput {
                        output.append(bytes.baseAddress!.assumingMemoryBound(to: UInt8.self).advanced(by: start), count: index - start)
                    }
                    continue
                }
                pending.append(bytes[index])
                index += 1
                drainPending(into: &output, emitsOutput: emitsOutput)
            }
        }
        return output
    }

    func observe(_ data: Data) {
        _ = scan(data, emitsOutput: false)
    }

    private func drainPending(into output: inout Data, emitsOutput: Bool) {
        while !pending.isEmpty {
            guard pending[0] == 0x1B else {
                let byte = pending.removeFirst()
                if emitsOutput { output.append(byte) }
                continue
            }
            if let active = Self.completedModes[pending] {
                if emitsOutput { output.append(contentsOf: pending) }
                pending.removeAll(keepingCapacity: true)
                inAlternateScreen = active
                return
            }
            if Self.candidatePrefixes.contains(pending) { return }
            let byte = pending.removeFirst()
            if emitsOutput { output.append(byte) }
        }
    }

    private static let completedModes: [[UInt8]: Bool] = {
        var modes: [[UInt8]: Bool] = [:]
        for sequence in entries { modes[sequence] = true }
        for sequence in exits { modes[sequence] = false }
        return modes
    }()

    private static let candidatePrefixes: Set<[UInt8]> = {
        var prefixes: Set<[UInt8]> = []
        for sequence in entries + exits {
            for count in 1..<sequence.count { prefixes.insert(Array(sequence.prefix(count))) }
        }
        return prefixes
    }()

    private static func endsWithCandidatePrefix(_ data: Data) -> Bool {
        guard let last = data.last else { return false }
        if last == 0x1B { return true }
        guard last == 0x5B, data.count >= 2 else { return false }
        return data[data.index(data.endIndex, offsetBy: -2)] == 0x1B
    }
}

/// Builds the screen replacement separately from the replay gate so expensive
/// ANSI compaction never blocks the shared node reader. The caller appends any
/// bytes that arrived during preparation while still holding that gate.
enum TerminalReplayCommit {
    private static let reset = Data("\u{001B}c".utf8)

    static func prepare(
        cached: Data,
        incoming: Data,
        preserveCachedBase: Bool = false,
        requiresFreshBase: Bool = false
    ) -> Data {
        if requiresFreshBase {
            // Older workers can start a trimmed replay in the middle of an
            // escape sequence. Only a real screen reset/clear is a base after
            // missing bytes. Otherwise await the explicitly requested repaint.
            guard let safe = TerminalReplayCompactor.freshScreenSuffix(incoming) else { return reset }
            var replacement = reset
            replacement.append(safe)
            return replacement
        }
        if preserveCachedBase, !cached.isEmpty {
            // An exact-viewport checkpoint is already a compact, renderable
            // base. An older worker's unchanged-size SIGWINCH replay contains
            // cursor-addressed agent updates whose internal clear markers are
            // not standalone transcript boundaries. Apply them over the base
            // without running boundary selection a second time.
            var replacement = reset
            replacement.append(cached)
            replacement.append(
                TerminalReconnectReplayPolicy.preservingCheckpointScrollback(incoming)
            )
            return replacement
        }
        let replayHistory = TerminalReplayCompactor.preservingAlternateScreenOwner(
            cached: cached,
            incoming: incoming
        )
        let reconstruction = TerminalReplayCompactor.compact(replayHistory)
        guard !reconstruction.isEmpty else { return Data() }
        var replacement = reset
        replacement.append(reconstruction)
        return replacement
    }

    static func appendingLiveTail(_ liveTail: Data, to replacement: Data) -> Data {
        guard !liveTail.isEmpty else { return replacement }
        var commit = replacement
        commit.append(liveTail)
        return commit
    }
}

enum TerminalReplayCompactor {
    private static let reset = Data("\u{001B}c".utf8)

    /// A raw byte suffix can begin halfway through CSI/OSC or a UTF-8 glyph.
    /// Ghostty then prints the remaining parameters as text and the rest of
    /// the replay paints over a damaged grid. Start at a complete line break
    /// when possible; otherwise start at an escape sequence in ground state.
    static func safeSuffix(_ data: Data, maximumBytes: Int) -> Data {
        guard maximumBytes > 0, data.count > maximumBytes else { return data }
        // This path scans multi-megabyte replay buffers. Traverse borrowed
        // bytes directly: allocating an array and using generic Collection
        // iteration dominated the production CPU sample during compaction.
        return data.withUnsafeBytes { raw -> Data in
            guard let bytes = raw.bindMemory(to: UInt8.self).baseAddress else { return Data() }
            let count = raw.count
            let cutoff = count - maximumBytes
            enum State { case ground, escape, csi, osc, oscEscape, dcs, dcsEscape }
            var state = State.ground
            var escapeBoundary: Int?
            var index = 0
            while index < count {
                let byte = bytes[index]
                switch state {
                case .ground:
                    if index >= cutoff {
                        if byte == 0x0A { return Data(bytes: bytes.advanced(by: index + 1), count: count - index - 1) }
                        if byte == 0x1B, escapeBoundary == nil { escapeBoundary = index }
                    }
                    if byte == 0x1B { state = .escape }
                case .escape:
                    switch byte {
                    case 0x5B: state = .csi
                    case 0x5D: state = .osc
                    case 0x50, 0x5F, 0x5E, 0x58: state = .dcs
                    default: state = .ground
                    }
                case .csi:
                    if byte >= 0x40 && byte <= 0x7E { state = .ground }
                case .osc:
                    if byte == 0x07 { state = .ground }
                    else if byte == 0x1B { state = .oscEscape }
                case .oscEscape:
                    state = byte == 0x5C ? .ground : .osc
                case .dcs:
                    if byte == 0x1B { state = .dcsEscape }
                case .dcsEscape:
                    state = byte == 0x5C ? .ground : .dcs
                }
                index += 1
            }
            return escapeBoundary.map { Data(bytes: bytes.advanced(by: $0), count: count - $0) } ?? Data()
        }
    }
    private struct PreservedPrivateMode {
        let enable: [UInt8]
        let disable: [UInt8]
        var preserveDisabled = false
    }

    /// RIS resets terminal input modes as well as the visible grid. A compacted
    /// replay that starts after the original mode negotiation must restore the
    /// modes that were active at its new boundary or the terminal consumes
    /// wheel/key input locally instead of forwarding it to the TUI.
    private static let preservedPrivateModes = [
        PreservedPrivateMode(
            enable: Array("\u{001B}[?1h".utf8),
            disable: Array("\u{001B}[?1l".utf8)
        ),
        PreservedPrivateMode(
            enable: Array("\u{001B}[?1000h".utf8),
            disable: Array("\u{001B}[?1000l".utf8)
        ),
        PreservedPrivateMode(
            enable: Array("\u{001B}[?1002h".utf8),
            disable: Array("\u{001B}[?1002l".utf8)
        ),
        PreservedPrivateMode(
            enable: Array("\u{001B}[?1003h".utf8),
            disable: Array("\u{001B}[?1003l".utf8)
        ),
        PreservedPrivateMode(
            enable: Array("\u{001B}[?1004h".utf8),
            disable: Array("\u{001B}[?1004l".utf8)
        ),
        PreservedPrivateMode(
            enable: Array("\u{001B}[?1006h".utf8),
            disable: Array("\u{001B}[?1006l".utf8)
        ),
        PreservedPrivateMode(
            enable: Array("\u{001B}[?1007h".utf8),
            disable: Array("\u{001B}[?1007l".utf8)
        ),
        PreservedPrivateMode(
            enable: Array("\u{001B}[?2004h".utf8),
            disable: Array("\u{001B}[?2004l".utf8)
        ),
        // Width negotiation affects cursor-addressed redraws as well as input.
        // Preserve an explicit legacy selection too: RIS restores the configured
        // default, which can differ from the shell's active width method.
        PreservedPrivateMode(
            enable: Array("\u{001B}[?2027h".utf8),
            disable: Array("\u{001B}[?2027l".utf8),
            preserveDisabled: true
        ),
    ]
    private static let alternateScreenEntries = [
        Array("\u{001B}[?1049h".utf8),
        Array("\u{001B}[?1047h".utf8),
        Array("\u{001B}[?47h".utf8),
    ]
    private static let alternateScreenExits = [
        Array("\u{001B}[?1049l".utf8),
        Array("\u{001B}[?1047l".utf8),
        Array("\u{001B}[?47l".utf8),
    ]
    private static let synchronizedOutputBegin = Array("\u{001B}[?2026h".utf8)
    private static let synchronizedOutputEnd = Array("\u{001B}[?2026l".utf8)
    // Codex and Claude wrap both complete redraws and tiny spinner/status
    // deltas in synchronized output. The latter are commonly 40–300 bytes and
    // cannot reconstruct the unchanged grid by themselves. A 512-byte floor
    // keeps the latest substantial completed frame as the base, followed by
    // every later incremental frame.
    private static let minimumReplayableSynchronizedFrameBytes = 512

    /// A fresh local surface needs the current screen, not every cursor-addressed
    /// redraw ever emitted by a TUI. Reconstruct from its latest full clear.
    static func compact(_ data: Data) -> Data {
        guard !data.isEmpty else { return data }
        // scan() produces zero-based offsets; rebase a nonzero-startIndex
        // slice (Data.SubSequence keeps its parent's index base) so the
        // collection indexing below stays aligned.
        let data = data.startIndex == 0 ? data : Data(data)
        let scanned = scan(data)
        let latest = [
            scanned.replayStart,
            scanned.promptStormStart,
            scanned.synchronizedFrameStart,
        ]
            .compactMap { $0 }
            .max()
        guard let latest, latest > data.startIndex else { return data }
        var result = reset
        result.append(privateModePrelude(in: data, before: latest))
        result.append(contentsOf: data[latest...])
        return result
    }

    static func freshScreenSuffix(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        let bytes = data.startIndex == 0 ? data : Data(data)
        guard let start = scan(bytes).primaryClearStart else { return nil }
        var suffix = privateModePrelude(in: bytes, before: start)
        suffix.append(contentsOf: bytes[start...])
        return suffix
    }

    static func hasCompletedSynchronizedFrame(_ data: Data) -> Bool {
        !data.isEmpty && scan(data).synchronizedFrameStart != nil
    }

    /// A resume cursor normally returns only bytes missed since the local
    /// snapshot. Primary-screen TUIs such as Codex often emit nothing more
    /// than a spinner/cursor delta, so that delta must extend the cached base;
    /// treating it as a complete screen produces an otherwise blank pane.
    /// A replay containing its own reset/clear is self-contained. The special
    /// alternate-screen branch below also preserves the cached owner when an
    /// older worker synthesizes a reset before an incremental TUI repaint.
    static func preservingAlternateScreenOwner(cached: Data, incoming: Data) -> Data {
        guard !cached.isEmpty else { return incoming }
        guard !incoming.isEmpty else { return cached }
        let incomingScan = scan(incoming)
        if incomingScan.replayStart == nil {
            var continuation = cached
            continuation.append(incoming)
            return continuation
        }
        guard scan(cached).endsInAlternateScreen,
              !incomingScan.containsAlternateScreenEntry else { return incoming }
        var continuation = incoming
        // Compatibility workers synthesize RIS before a replay that begins at
        // an alternate-screen clear. The cached stream already established
        // the correct terminal mode, so applying that RIS here would exit the
        // alternate screen and erase its saved primary shell.
        while continuation.starts(with: reset) {
            continuation.removeFirst(reset.count)
        }
        var merged = cached
        merged.append(continuation)
        return merged
    }

    /// A full-screen program saves the primary shell screen before switching
    /// to its alternate screen. A clear emitted inside that alternate screen
    /// is not a valid replay boundary: dropping the preceding mode switch
    /// makes `htop`/`less` content become the shell background after exit.
    ///
    /// An unmatched exit is produced by older relayd workers that already
    /// truncated replay inside an alternate screen. In that compatibility
    /// case, discard the orphaned TUI prefix and reconstruct from the bytes
    /// after the exit rather than painting them onto the primary screen.
    private struct ScanResult {
        let primaryClearStart: Int?
        let replayStart: Int?
        let promptStormStart: Int?
        let synchronizedFrameStart: Int?
        let endsInAlternateScreen: Bool
        let containsAlternateScreenEntry: Bool
    }

    /// Scan the contiguous Data storage once. Terminal streams are overwhelmingly
    /// printable bytes, so ignore them with one comparison and inspect control
    /// sequences only at ESC. This replaces an Array copy plus six collection
    /// comparisons at every byte of every periodic snapshot.
    private static func scan(_ data: Data) -> ScanResult {
        data.withUnsafeBytes { rawBytes in
            let bytes = rawBytes.bindMemory(to: UInt8.self)
            var index = 0
            var inAlternateScreen = false
            var sawAlternateScreenEntry = false
            var latestPrimaryClear: Int?
            var unmatchedExitEnd: Int?
            var promptRedrawCount = 0
            var promptStormStart: Int?
            var synchronizedFrameCandidate: Int?
            var synchronizedFrameRepaintsFromTop = false
            var latestCompletedSynchronizedFrame: Int?

            while index < bytes.count {
                guard bytes[index] == 0x1B else {
                    index += 1
                    continue
                }
                if let count = matchingLength(alternateScreenEntries, in: bytes, at: index) {
                    inAlternateScreen = true
                    sawAlternateScreenEntry = true
                    // A synchronized frame that enters the alternate screen
                    // is not independently replayable: it still depends on
                    // the preceding mode switch to preserve the primary shell.
                    synchronizedFrameCandidate = nil
                    index += count
                    continue
                }
                if let count = matchingLength(alternateScreenExits, in: bytes, at: index) {
                    if inAlternateScreen {
                        inAlternateScreen = false
                    } else {
                        unmatchedExitEnd = index + count
                        latestPrimaryClear = nil
                    }
                    index += count
                    continue
                }
                if !inAlternateScreen,
                   sequence(synchronizedOutputBegin, matches: bytes, at: index, before: bytes.count) {
                    // DEC synchronized output gives us an explicit atomic TUI
                    // frame boundary. Codex and Claude redraw rapidly without
                    // clearing the screen; retaining every historical frame
                    // fills the snapshot and makes restore replay thousands of
                    // obsolete cursor updates. Only a completed frame is safe
                    // as a new reconstruction base because the current frame
                    // may still be arriving on another SSH packet.
                    synchronizedFrameCandidate = index
                    synchronizedFrameRepaintsFromTop = false
                    index += synchronizedOutputBegin.count
                    continue
                }
                if !inAlternateScreen,
                   sequence(synchronizedOutputEnd, matches: bytes, at: index, before: bytes.count) {
                    // Size alone is not proof of a full repaint: ratatui (Codex)
                    // and Ink (Claude Code) emit incremental frames that only
                    // cursor-address the rows that changed, and those routinely
                    // exceed the byte floor. Replaying such a frame after RIS
                    // paints only that fragment and blanks the transcript above
                    // it. Only a frame that clears the screen is independently
                    // replayable. Cursor-home alone does not erase unchanged
                    // cells and is never evidence of a complete repaint.
                    if let candidate = synchronizedFrameCandidate,
                       synchronizedFrameRepaintsFromTop,
                       index + synchronizedOutputEnd.count - candidate >=
                       minimumReplayableSynchronizedFrameBytes {
                        latestCompletedSynchronizedFrame = candidate
                    }
                    synchronizedFrameCandidate = nil
                    synchronizedFrameRepaintsFromTop = false
                    index += synchronizedOutputEnd.count
                    continue
                }
                if !inAlternateScreen, index + 6 < bytes.count,
                   bytes[index + 1] == 0x5D,
                   bytes[index + 2] == 0x31,
                   bytes[index + 3] == 0x33,
                   bytes[index + 4] == 0x33,
                   bytes[index + 5] == 0x3B {
                    switch bytes[index + 6] {
                    case 0x50: // OSC 133;P — prompt property/redraw
                        promptRedrawCount += 1
                        if promptRedrawCount >= 3 { promptStormStart = index }
                    case 0x43, 0x44: // command start/finished
                        promptRedrawCount = 0
                        promptStormStart = nil
                    default:
                        break
                    }
                }
                if !inAlternateScreen, let count = clearSequenceLength(in: bytes, at: index) {
                    if synchronizedFrameCandidate != nil { synchronizedFrameRepaintsFromTop = true }
                    latestPrimaryClear = index
                    promptRedrawCount = 0
                    promptStormStart = nil
                    index += count
                    continue
                }
                index += 1
            }
            return ScanResult(
                primaryClearStart: latestPrimaryClear,
                replayStart: latestPrimaryClear ?? unmatchedExitEnd,
                promptStormStart: promptStormStart,
                synchronizedFrameStart: latestCompletedSynchronizedFrame,
                endsInAlternateScreen: inAlternateScreen,
                containsAlternateScreenEntry: sawAlternateScreenEntry
            )
        }
    }

    private static func clearSequenceLength(
        in bytes: UnsafeBufferPointer<UInt8>,
        at index: Int
    ) -> Int? {
        if index + 2 <= bytes.count, bytes[index + 1] == 0x63 { return 2 } // ESC c
        guard index + 4 <= bytes.count,
              bytes[index + 1] == 0x5B,
              bytes[index + 2] == 0x32,
              bytes[index + 3] == 0x4A else { return nil } // ESC [ 2J; 3J erases scrollback only
        return 4
    }

    private static func privateModePrelude(in data: Data, before boundary: Int) -> Data {
        data.withUnsafeBytes { rawBytes in
            let bytes = rawBytes.bindMemory(to: UInt8.self)
            let end = min(boundary, bytes.count)
            var enabled = Array<Bool?>(repeating: nil, count: preservedPrivateModes.count)
            // Kitty's progressive keyboard protocol is negotiated by the TUI,
            // not by the shell. RIS clears it, so replay compaction must restore
            // the effective flags just like mouse and bracketed-paste modes.
            // Keep the stack while scanning so nested push/pop sequences resolve
            // to the same active mode at the replay boundary.
            var kittyKeyboardStack = [0]
            var index = 0
            while index < end {
                guard bytes[index] == 0x1B else {
                    index += 1
                    continue
                }

                if index + 1 < end, bytes[index + 1] == 0x63 {
                    // RIS discards negotiations that precede it, including an
                    // explicit width method. Do not resurrect them in a replay.
                    enabled = Array(repeating: nil, count: preservedPrivateModes.count)
                    kittyKeyboardStack = [0]
                    index += 2
                    continue
                }

                if let command = kittyKeyboardCommand(in: bytes, at: index, before: end) {
                    switch command.operation {
                    case 0x3E: // CSI > flags u — push
                        kittyKeyboardStack.append(command.value ?? 0)
                    case 0x3D: // CSI = flags u — set
                        kittyKeyboardStack[kittyKeyboardStack.count - 1] = command.value ?? 0
                    case 0x3C: // CSI < count u — pop
                        let requested = max(command.value ?? 1, 1)
                        let removable = min(requested, kittyKeyboardStack.count - 1)
                        if removable > 0 {
                            kittyKeyboardStack.removeLast(removable)
                        }
                    default:
                        break
                    }
                    index += command.length
                    continue
                }

                var matched = false
                for (modeIndex, mode) in preservedPrivateModes.enumerated() {
                    if sequence(mode.enable, matches: bytes, at: index, before: end) {
                        enabled[modeIndex] = true
                        index += mode.enable.count
                        matched = true
                        break
                    }
                    if sequence(mode.disable, matches: bytes, at: index, before: end) {
                        enabled[modeIndex] = false
                        index += mode.disable.count
                        matched = true
                        break
                    }
                }
                if !matched { index += 1 }
            }

            var prelude = Data()
            for (modeIndex, mode) in preservedPrivateModes.enumerated() {
                if enabled[modeIndex] == true {
                    prelude.append(contentsOf: mode.enable)
                } else if enabled[modeIndex] == false, mode.preserveDisabled {
                    prelude.append(contentsOf: mode.disable)
                }
            }
            if let keyboardFlags = kittyKeyboardStack.last, keyboardFlags > 0 {
                prelude.append(Data("\u{001B}[=\(keyboardFlags)u".utf8))
            }
            return prelude
        }
    }

    private struct KittyKeyboardCommand {
        let operation: UInt8
        let value: Int?
        let length: Int
    }

    private static func kittyKeyboardCommand(
        in bytes: UnsafeBufferPointer<UInt8>,
        at index: Int,
        before end: Int
    ) -> KittyKeyboardCommand? {
        guard index + 3 < end,
              bytes[index] == 0x1B,
              bytes[index + 1] == 0x5B else { return nil }
        let operation = bytes[index + 2]
        guard operation == 0x3E || operation == 0x3D || operation == 0x3C else { return nil }

        var cursor = index + 3
        var value: Int?
        while cursor < end, bytes[cursor] >= 0x30, bytes[cursor] <= 0x39 {
            let digit = Int(bytes[cursor] - 0x30)
            value = min((value ?? 0) * 10 + digit, Int(UInt16.max))
            cursor += 1
        }
        guard cursor < end, bytes[cursor] == 0x75 else { return nil }
        return KittyKeyboardCommand(
            operation: operation,
            value: value,
            length: cursor - index + 1
        )
    }

    private static func sequence(
        _ sequence: [UInt8],
        matches bytes: UnsafeBufferPointer<UInt8>,
        at index: Int,
        before end: Int
    ) -> Bool {
        guard index + sequence.count <= end else { return false }
        var offset = 0
        while offset < sequence.count, bytes[index + offset] == sequence[offset] {
            offset += 1
        }
        return offset == sequence.count
    }

    private static func matchingLength(
        _ sequences: [[UInt8]],
        in bytes: UnsafeBufferPointer<UInt8>,
        at index: Int
    ) -> Int? {
        for sequence in sequences where index + sequence.count <= bytes.count {
            var offset = 0
            while offset < sequence.count, bytes[index + offset] == sequence[offset] {
                offset += 1
            }
            if offset == sequence.count { return sequence.count }
        }
        return nil
    }
}

enum TerminalFocusReport {
    /// A non-sensitive diagnostic category; never log the terminal input bytes.
    static func name(_ data: Data) -> String? {
        guard !data.isEmpty, data.count.isMultiple(of: 3) else { return nil }
        let bytes = Array(data)
        for offset in stride(from: 0, to: bytes.count, by: 3) {
            guard bytes[offset] == 0x1B, bytes[offset + 1] == 0x5B,
                  bytes[offset + 2] == 0x49 || bytes[offset + 2] == 0x4F else { return nil }
        }
        if bytes.count > 3 { return "focus_multiple" }
        if bytes[2] == 0x49 { return "focus_in" }
        if bytes[2] == 0x4F { return "focus_out" }
        return nil
    }
}

enum TerminalInputDiagnosticReport {
    /// Recognize report grammars without retaining their content or coordinates.
    static func name(_ data: Data) -> String {
        if let focus = TerminalFocusReport.name(data) { return focus }
        if TerminalDeviceResponseFilter.matches(data) { return "device_response" }
        let bytes = Array(data)
        if bytes.count >= 9, bytes.starts(with: [0x1B, 0x5B, 0x3C]),
           bytes.last == 0x4D || bytes.last == 0x6D {
            let fields = bytes.dropFirst(3).dropLast().split(separator: 0x3B, omittingEmptySubsequences: false)
            if fields.count == 3,
               fields.allSatisfy({ !$0.isEmpty && $0.allSatisfy { (0x30...0x39).contains($0) } }),
               let button = Int(String(decoding: fields[0], as: UTF8.self)) {
                if button & 64 != 0 { return "mouse_wheel" }
                return button & 0x23 == 0x23 ? "mouse_motion" : "mouse_button"
            }
        }
        return "none"
    }
}

enum TerminalDeviceResponseFilter {
    /// Ghostty and the shell share one in-memory write callback. During surface
    /// startup, drop only complete terminal capability replies; ordinary input
    /// (including arrows, mouse reports, function keys, and paste) does not
    /// match this grammar.
    static func matches(_ data: Data) -> Bool {
        let bytes = Array(data)
        guard !bytes.isEmpty else { return false }
        var index = 0
        while index < bytes.count {
            guard bytes[index] == 0x1B, index + 1 < bytes.count else { return false }
            switch bytes[index + 1] {
            case 0x5B: // CSI
                let parameterStart = index + 2
                var final = parameterStart
                while final < bytes.count && !(0x40...0x7E).contains(bytes[final]) {
                    final += 1
                }
                guard final < bytes.count else { return false }
                let parameters = bytes[parameterStart..<final]
                switch bytes[final] {
                case 0x63, 0x52: // device attributes or cursor position
                    break
                case 0x75: // kitty keyboard capability reply, always private
                    guard parameters.contains(0x3F) || parameters.contains(0x3E) else { return false }
                case 0x79: // DECRPM reply: CSI ? mode ; state $ y
                    guard parameters.first == 0x3F, parameters.last == 0x24,
                          parameters.dropFirst().dropLast().allSatisfy({ (0x30...0x39).contains($0) || $0 == 0x3B }) else { return false }
                case 0x74: // Window/pixel-size replies, never keyboard or mouse reports
                    let values = String(decoding: parameters, as: UTF8.self).split(separator: ";")
                    guard values.count == 3, let kind = Int(values[0]), [4, 6, 8, 9].contains(kind),
                          values.dropFirst().allSatisfy({ Int($0) != nil }) else { return false }
                default:
                    return false
                }
                index = final + 1
            case 0x5D, 0x50, 0x5F: // OSC, DCS or kitty graphics APC, terminated by BEL or ST
                if bytes[index + 1] == 0x5F {
                    let prefix = Array("Gi=".utf8)
                    guard index + 2 + prefix.count <= bytes.count,
                          Array(bytes[(index + 2)..<(index + 2 + prefix.count)]) == prefix else { return false }
                }
                var end = index + 2
                var found = false
                while end < bytes.count {
                    if bytes[end] == 0x07 {
                        end += 1
                        found = true
                        break
                    }
                    if bytes[end] == 0x1B, end + 1 < bytes.count, bytes[end + 1] == 0x5C {
                        end += 2
                        found = true
                        break
                    }
                    end += 1
                }
                guard found else { return false }
                index = end
            default:
                return false
            }
        }
        return true
    }
}

enum TerminalWriteForwardingPolicy {
    /// During replay/startup, only terminal-generated capability responses are
    /// local. User keys, paste, mouse reports, and application key sequences
    /// continue to the transport, where they may be buffered until attach.
    static func shouldForward(_ data: Data, filteringDeviceResponses: Bool, programStatusReplyOwnedByWorker: Bool = false) -> Bool {
        guard !data.isEmpty else { return false }
        let query = Data([0x1b, 0x5d, 0x37, 0x35, 0x30, 0x31, 0x3b, 0x3f])
        if programStatusReplyOwnedByWorker &&
            (data == query + Data([0x1b, 0x5c]) || data == query + Data([0x07])) {
            return false
        }
        return !filteringDeviceResponses || !TerminalDeviceResponseFilter.matches(data)
    }
}

extension TerminalRuntime:
    TerminalSurfaceGridResizeDelegate,
    TerminalSurfaceTitleDelegate,
    TerminalSurfaceCloseDelegate,
    TerminalSurfaceFocusDelegate,
    TerminalSurfacePwdDelegate,
    TerminalSurfaceCommandFinishedDelegate,
    TerminalSurfaceProgressReportDelegate,
    TerminalSurfaceOpenURLDelegate,
    TerminalSurfaceHoverLinkDelegate,
    TerminalSurfaceScrollbarDelegate,
    TerminalSurfaceClipboardConfirmationDelegate
{
    func terminalDidRequestClipboardConfirmation(_ request: TerminalClipboardConfirmationRequest) {
        guard case .paste = request.kind, let pane, let window = view.window else {
            request.respond(allow: false)
            return
        }
        let identity = promptInspectionIdentity
        let targetView = view
        guard let decision = targetView.beginNativePasteConfirmation() else {
            request.respond(allow: false); return
        }
        Task { @MainActor [weak self] in
            guard let self else {
                targetView.finishNativePasteConfirmation(decision, request: request, allow: false, ownerIsValid: false)
                return
            }
            let binding = await self.readPromptOwnerBinding()
            guard self.pane === pane, self.promptInspectionIdentity == identity,
                  self.view.window === window,
                  !self.promptInspectionRequiresKernelIdentity || binding != nil else {
                targetView.finishNativePasteConfirmation(decision, request: request, allow: false, ownerIsValid: false)
                return
            }
            let alert = NSAlert()
            alert.messageText = "Paste text with line breaks?"
            alert.informativeText = "Line breaks can run commands or submit a message in this terminal."
            alert.addButton(withTitle: "Paste")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { [weak self] response in
                Task { @MainActor in
                    guard let self,
                          self.pane === pane, self.promptInspectionIdentity == identity,
                          self.view.window === window else {
                        targetView.finishNativePasteConfirmation(decision, request: request, allow: false, ownerIsValid: false)
                        return
                    }
                    let observed = await self.readPromptOwnerBinding()
                    let valid = self.pane === pane && self.promptInspectionIdentity == identity &&
                        self.view.window === window && observed == binding
                    targetView.finishNativePasteConfirmation(decision, request: request,
                        allow: response == .alertFirstButtonReturn, ownerIsValid: valid)
                }
            }
        }
    }
    func terminalDidResize(_ size: TerminalGridMetrics) {
        latestSurfaceGridMetrics = size
        latestSurfaceViewport = RelayViewport(
            columns: size.columns,
            rows: size.rows
        )
        if awaitingInitialViewport {
            Task { @MainActor [weak self] in self?.startIfNeeded() }
        }
    }

    func terminalDidChangeTitle(_ title: String) {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            guard let pane = self?.pane, pane.title != normalized else { return }
            pane.title = normalized
        }
    }

    func terminalDidClose(processAlive: Bool) {
        // Ghostty is an in-memory renderer, not the shell process owner.
        // A renderer close request must not mark a live host worker exited.
        // Only the transport's explicit exited status owns pane lifecycle.
    }

    func terminalDidChangeFocus(_ focused: Bool) {
        if focused {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.view.window?.firstResponder === self.view else { return }
                self.selectPane()
            }
        }
    }

    func terminalDidChangeWorkingDirectory(_ path: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let pane = self.pane else { return }
            if pane.directory != path { pane.directory = path }
            // The editor policy needs this directory to capture its host context.
            // Probe after publishing it, including repeated prompt notifications.
            self.view.shellPromptBecameActive()
        }
    }

    func terminalDidFinishCommand(exitCode: Int?, durationNanos: UInt64) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let pane = self.pane else { return }
            let provider = pane.kind
            pane.recordCommandCompletion(exitCode: exitCode, durationNanos: durationNanos)
            if provider == .claude, let exitCode, exitCode != 0 {
                // Early CLI failures may disappear with its alternate screen.
                // Leave recovery guidance in the shell without attaching or
                // sending input to a background provider process.
                self.io.receive(Data(("\r\nRelay: Claude exited with status \(exitCode). " +
                    "If --continue reported a background conversation, run `claude agents` " +
                    "and select that existing conversation. Your shell remains open.\r\n").utf8))
            }
        }
    }

    func terminalDidReportProgress(state: TerminalProgressState, percent: Int?) {
        DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        switch state {
        case .remove:
            pane?.recordTerminalProgress(state: nil, percent: nil)
        case .set:
            pane?.recordTerminalProgress(state: "running", percent: percent)
        case .error:
            pane?.recordTerminalProgress(state: "error", percent: percent)
        case .indeterminate:
            pane?.recordTerminalProgress(state: "indeterminate", percent: nil)
        case .pause:
            pane?.recordTerminalProgress(state: "paused", percent: percent)
        }
        }
    }

    func terminalDidRequestOpenURL(_ url: String, kind: TerminalOpenURLKind) {
        _ = openTerminalLink(url)
    }

    func terminalDidUpdateHoverLink(_ url: String?) {
        hoveredLink = url
    }

    func terminalDidUpdateScrollbar(_ scrollbar: TerminalScrollbar) {
        viewportIsAtBottom = TerminalViewportPosition.isAtBottom(scrollbar)
    }
}

@MainActor
final class RelayGhosttyView: TerminalView, @preconcurrency NSTextInputTraits {
    private struct PromptMutationIntent {
        let expected: TerminalPromptBuffer.Snapshot
        let target: TerminalPromptBuffer.Snapshot
        let expectedOwner: RelayPromptOwnerIdentity?
        let requiresOwnedHistory: Bool
        let isCurrent: @MainActor () -> Bool
        let publish: @MainActor () -> Void
        let nativeFallback: @MainActor (RelayPromptEditorControlLease) -> Bool
        let recoveryAction: DeferredPromptInput
    }

    private struct PromptSelection: Equatable {
        let characterCount: Int
        let movementOffset: Int
    }

    /// AppKit keeps delivering a drag to the view that received mouse-down,
    /// but SwiftUI is allowed to move that durable terminal view when the pane
    /// becomes active. Retaining the original NSEvent therefore retains a
    /// window coordinate that may no longer address the same terminal cell.
    /// Keep the semantic terminal point and only recreate the event after the
    /// final view placement is known.
    private struct PendingLocalSelectionMouseDown {
        let terminalPoint: CGPoint
        let modifierFlags: NSEvent.ModifierFlags
        let timestamp: TimeInterval
        let eventNumber: Int
        let clickCount: Int
        let pressure: Float
    }

    weak var owner: TerminalRuntime?
    private var pointerDownPoint: CGPoint?
    private var selectionStart: CGPoint?
    private var selectionCanEditPrompt = false
    private var promptSelection: PromptSelection?
    private var keyboardSelectionOffset: Int?
    private var keyboardSelectionIsVisual = false
    /// A primary-button gesture is held locally until AppKit distinguishes a
    /// click from a drag. Drags always use Ghostty's local selection path,
    /// even when a remote TUI (or a stale terminal mode) has mouse reporting
    /// enabled. Clicks are replayed to the terminal after mouse-up.
    private var forcingLocalSelectionGesture = false
    private var pendingLocalSelectionMouseDown: PendingLocalSelectionMouseDown?
    private var localSelectionDidDrag = false
    private var geometryRevealTask: Task<Void, Never>?
    private var promptBuffer = TerminalPromptBuffer()
    private var promptHistory = TerminalPromptEditHistory()
    private struct SuspendedPromptHistory {
        let binding: RelayPromptOwnerIdentity
        let snapshot: TerminalPromptBuffer.Snapshot
        let history: TerminalPromptEditHistory
    }
    private var promptOwnerBinding: RelayPromptOwnerIdentity?
    private var suspendedPromptHistory: SuspendedPromptHistory?
    private var promptOwnerTask: Task<Void, Never>?
    private var promptOwnerTaskID: UUID?
    private var promptHistoryGeneration: UInt64 = 0
    private enum PromptInspectionEvent {
        case viewport(InMemoryTerminalViewport)
        case parsedHostOutput
        case inputLeaseChanged
        case editorRestoration(TerminalIOBridge.PromptEditorRestorationEvent)
        case paint
        case timeout
    }
    private enum DeferredPromptInput {
        case key(NSEvent)
        case text(Any, NSRange)
        case clipboard(RelayClipboardAction)
        case paste(text: String?, files: [URL])
        case history(Bool)
        case deleteSelection(TerminalPromptBuffer.Snapshot, PromptSelection)
        case marked(Any, NSRange, NSRange)
        case unmark
        case command(Selector)
    }
    private var promptInspectionTask: Task<Void, Never>?
    fileprivate var promptInspectionBlocksExternalInput: Bool {
        promptInspectionTask != nil || promptInspectionPreservesInput || !deferredPromptInput.isEmpty
    }
    private var promptInspectionTaskID: UUID?
    private var promptInspectionInputRelease: (id: UUID, release: @MainActor () -> Void)?
    private(set) var promptInspectionPhase = "idle"
    private(set) var promptInspectionDraftState = "idle"
    private var promptInspectionEvents: AsyncStream<PromptInspectionEvent>.Continuation?
    private var deferredPromptInput: [DeferredPromptInput] = []
    private var promptInspectionRequiresRecovery = false
    private var promptInspectionPreservesInput = false
    private var preservedPromptInputIdentity: TerminalRuntime.PromptInspectionIdentity?
    private var promptInspectionVisualCopy: String?
    /// A local agent Command-A over the painted composer, whose exact text is
    /// unproven. The first edit that needs that text starts exact inspection.
    private var localSelectAllNeedsExactText = false
    private var replayingDeferredPromptText = false
    /// The key press AppKit is dispatching to this view right now; insertText
    /// outside it is not keyboard input. A replayed deferred key is not recounted.
    private var promptKeyDownInFlight: NSEvent?
    private var replayingDeferredPromptKey = false
    private var quarantinedPromptKeyCodes: Set<UInt16> = []
    private var translatingPromptControlKey = false
    private struct NativePasteConfirmation {
        let id: UUID
        let identity: TerminalRuntime.PromptInspectionIdentity?
        let snapshot: TerminalPromptBuffer.Snapshot?
        let selection: PromptSelection?
        let generation: UInt64
        let window: Int?
        let frame: NSRect
    }
    private var nativePasteConfirmation: NativePasteConfirmation?
    private var promptMirrorAwaitingHostOutput: (session: InMemoryTerminalSession, revision: UInt64)?
    var promptMirrorIsAwaitingHostOutput: Bool { promptMirrorAwaitingHostOutput != nil }
    var promptInspectionBlocksInput: Bool { promptInspectionPreservesInput }
    /// Tests only: recovery is meaningful only together with a visible hold.
    var promptInspectionRecoveryPendingForTesting: Bool { promptInspectionRequiresRecovery }
    /// Tests only: the held queue in order, by kind (keys with characters).
    var deferredPromptInputSummaryForTesting: [String] {
        deferredPromptInput.map { action in
            switch action {
            case .key(let event): return "key:" + (event.characters ?? "")
            case .deleteSelection: return "deleteSelection"
            default: return String(String(describing: action).prefix { $0 != "(" })
            }
        }
    }
    /// Tests only: run the replay loop (as inspection completion does) over a
    /// deletion of the current selection followed by `keys`.
    func replaySelectionDeletionThenKeysForTesting(_ keys: [NSEvent]) {
        guard let expected = promptBuffer.snapshot, let selection = promptSelection else { return }
        let queued = [DeferredPromptInput.deleteSelection(expected, selection)] + keys.map { DeferredPromptInput.key($0) }
        for action in queued { replayDeferredPromptInput(action) }
    }

    private func preservedPromptText(_ text: Any) -> Any {
        if let attributed = text as? NSAttributedString { return attributed.copy() }
        if let string = text as? NSString { return string.copy() }
        return text
    }

    private var semanticShellPromptActive = false
    private var hasLocalInputSincePromptBoundary = false
    var didAttachToWindow: (() -> Void)?
    private(set) var relaySurfaceIsVisible = true

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        onTerminalContentUpdate = { [weak self] in self?.promptInspectionEvents?.yield(.paint) }
        registerForDraggedTypes([.fileURL])
    }

    override var acceptsFirstResponder: Bool { owner?.canReceiveKeyboardFocus == true }

    override func becomeFirstResponder() -> Bool {
        // Hidden or previously selected durable surfaces can still receive
        // AppKit restore callbacks. They must not take input from the active pane.
        guard owner?.canReceiveKeyboardFocus == true else { return false }
        return super.becomeFirstResponder()
    }

    // A terminal is not a prose editor. Advertising these input traits keeps
    // AppKit from sending terminal keystrokes through autocorrection, inline
    // prediction, or Writing Tools. Relay's optional Foundation Models agent
    // refinement is separate and never participates in terminal input.
    var autocorrectionType: NSTextInputTraitType {
        get { .no }
        set {}
    }

    var spellCheckingType: NSTextInputTraitType {
        get { .no }
        set {}
    }

    var grammarCheckingType: NSTextInputTraitType {
        get { .no }
        set {}
    }

    var smartQuotesType: NSTextInputTraitType {
        get { .no }
        set {}
    }

    var smartDashesType: NSTextInputTraitType {
        get { .no }
        set {}
    }

    var smartInsertDeleteType: NSTextInputTraitType {
        get { .no }
        set {}
    }

    var textReplacementType: NSTextInputTraitType {
        get { .no }
        set {}
    }

    var dataDetectionType: NSTextInputTraitType {
        get { .no }
        set {}
    }

    var linkDetectionType: NSTextInputTraitType {
        get { .no }
        set {}
    }

    var textCompletionType: NSTextInputTraitType {
        get { .no }
        set {}
    }

    @available(macOS 14.0, *)
    var inlinePredictionType: NSTextInputTraitType {
        get { .no }
        set {}
    }

    @available(macOS 15.0, *)
    var writingToolsBehavior: NSWritingToolsBehavior {
        get { .none }
        set {}
    }

    /// Relay uses a full-size content view and lets empty chrome move the
    /// window. A terminal surface is never empty chrome: every drag belongs to
    /// Ghostty for selection or mouse reporting. Without this override AppKit
    /// can promote a text-selection drag into a window drag before mouseDragged
    /// reaches the terminal.
    override var mouseDownCanMoveWindow: Bool { false }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func setSurfaceVisible(_ visible: Bool) {
        relaySurfaceIsVisible = visible
        super.setSurfaceVisible(visible)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        // A restored workspace with many panes/agent threads can take longer
        // than the representable's initial settling window to enter AppKit's
        // hierarchy. Drive presentation from the real attachment event so a
        // late pane cannot remain a header above an unstarted blank surface.
        didAttachToWindow?()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        guard superview != nil else { return }
        // SwiftUI may establish the superview before AppKit propagates the
        // containing window. Recheck on the following run-loop turn.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil else { return }
            self.didAttachToWindow?()
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        guard TerminalGeometry.accepts(newSize) else { return }
        let previousSize = frame.size
        let geometryChanged = newSize.width > 1 &&
            newSize.height > 1 &&
            (abs(previousSize.width - newSize.width) >= 0.5 ||
                abs(previousSize.height - newSize.height) >= 0.5)
        // AppTerminalView fits its grid inside super.setFrameSize(). Suspend
        // that synchronization before the mutation so the outgoing terminal
        // remains presentable throughout the remote resize transaction.
        if window != nil, geometryChanged {
            owner?.beginSurfaceGeometryTransition()
        }
        super.setFrameSize(newSize)
        guard window != nil, geometryChanged else { return }
        settleGeometryBeforeReveal()
    }

    /// Coalesce transitional geometry without hiding or reconstructing the
    /// terminal. The existing surface remains usable while the final grid is
    /// measured.
    private func settleGeometryBeforeReveal() {
        geometryRevealTask?.cancel()
        geometryRevealTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(TerminalResizePolicy.debounceMilliseconds))
            } catch {
                return
            }
            guard let self, self.window != nil else { return }
            var sampler = TerminalStableGeometrySampler()
            for _ in 0..<4 {
                self.layoutSubtreeIfNeeded()
                if sampler.observe(self.bounds.size) { break }
                try? await Task.sleep(for: .milliseconds(16))
                guard !Task.isCancelled, self.window != nil else { return }
            }
            guard sampler.consecutiveSamples >= 2 else {
                self.geometryRevealTask = nil
                self.settleGeometryBeforeReveal()
                return
            }
            self.owner?.prepareFinalSurfaceMeasurement()
            self.owner?.fitForStableViewportCommit()
            let commit = self.owner?.commitStableViewport() ?? TerminalStableViewportCommit(
                explicit: false,
                remoteGeneration: nil,
                presentationEpoch: 0
            )
            let mayReveal = self.owner?.finishStableGeometryTransition(commit) ?? true
            guard !Task.isCancelled, self.window != nil else { return }
            if mayReveal { self.alphaValue = 1 }
            self.geometryRevealTask = nil
        }
    }

    override func mouseDown(with event: NSEvent) {
        // Resolve the cell before selecting the pane. Pane selection can
        // synchronously reorder a floating pane or rebuild a tiled host, which
        // changes the meaning of event.locationInWindow while this method is
        // still running.
        let point = terminalPoint(for: event)
        owner?.prepareForUserInteraction()
        // Own the keyboard before publishing the SwiftUI selection change.
        // A floating-pane reorder or tab/zoom transition can reparent this
        // durable view during that notification. The model schedules a second
        // focus claim after its update, covering both sides of the handoff.
        let focused = acquireProgrammaticFocus()
        owner?.recordInputDiagnostic("pointer-down", details: [
            "focus_claimed": String(focused),
            "surface_visible": String(relaySurfaceIsVisible),
            "window_key": String(window?.isKeyWindow == true),
        ])
        owner?.selectPane()
        owner?.focus()
        synchronizePromptMirrorFromRenderer()
        promptSelection = nil
        keyboardSelectionOffset = nil
        keyboardSelectionIsVisual = false
        localSelectAllNeedsExactText = false
        pointerDownPoint = point
        let agentPrompt = owner?.forcesLocalPromptSelection == true
        let canBeginPromptSelection = owner?.allowsPromptSelectionEditing == true &&
            owner?.promptEditingViewportIsLive == true &&
            promptEditingIsSemanticallyActive &&
            (agentPrompt || pointIsNearActivePrompt(point))
        // Remote TUIs can keep mouse reporting enabled after they exit, and a
        // reconnect can restore that mode before its reset sequence arrives.
        // Hold every primary-button gesture locally until it proves to be a
        // drag. A drag gets native macOS selection semantics; a genuine click
        // is replayed to the remote application from mouseUp. Prompt deletion
        // remains gated by `selectionCanEditPrompt`, so selecting old output
        // can never edit the live composer.
        selectionStart = (canBeginPromptSelection || agentPrompt) ? point : nil
        selectionCanEditPrompt = canBeginPromptSelection
        forcingLocalSelectionGesture = true
        localSelectionDidDrag = false
        if forcingLocalSelectionGesture {
            // Do not commit the terminal selection mode until AppKit proves
            // this is a drag. A focus click can otherwise be coalesced with a
            // subsequent drag as a double/triple click, expanding a precise
            // character selection to word or line boundaries. A genuine click
            // is replayed to the TUI from mouseUp instead.
            pendingLocalSelectionMouseDown = PendingLocalSelectionMouseDown(
                terminalPoint: point,
                modifierFlags: event.modifierFlags,
                timestamp: event.timestamp,
                eventNumber: event.eventNumber,
                clickCount: event.clickCount,
                pressure: event.pressure
            )
        } else {
            pendingLocalSelectionMouseDown = nil
            super.mouseDown(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard forcingLocalSelectionGesture else {
            super.mouseDragged(with: event)
            return
        }
        if let pending = pendingLocalSelectionMouseDown {
            pendingLocalSelectionMouseDown = nil
            // The replayed mouse-down carries Shift so Ghostty selects locally
            // under TUI mouse reporting — but Shift+press EXTENDS a retained
            // selection from its old anchor (and inside the repeat-click
            // interval expands to word/line). Drop any retained selection and
            // click state first so this gesture starts a fresh selection.
            resetSelection()
            if let down = localSelectionEvent(from: pending, clickCount: 1) {
                super.mouseDown(with: down)
            }
        }
        localSelectionDidDrag = true
        super.mouseDragged(with: localSelectionEvent(from: event, clickCount: 1) ?? event)
    }

    override func mouseUp(with event: NSEvent) {
        let start = selectionStart
        let pointerStart = pointerDownPoint
        let canEditPrompt = selectionCanEditPrompt
        let end = terminalPoint(for: event)
        let forcedLocalSelection = forcingLocalSelectionGesture
        let pendingLocalDown = pendingLocalSelectionMouseDown
        let completedLocalDrag = localSelectionDidDrag
        var handledLocalSelectionClick = false
        if forcedLocalSelection {
            if completedLocalDrag {
                super.mouseUp(with: localSelectionEvent(from: event, clickCount: 1) ?? event)
            } else if let pendingLocalDown,
                      pendingLocalDown.clickCount > 1 ||
                        !pendingLocalDown.modifierFlags
                            .intersection([.command, .option, .control, .shift]).isEmpty {
                // Preserve deliberate word/line selection and modified-click
                // selection. Ordinary single clicks belong to the agent TUI.
                if let down = localSelectionEvent(from: pendingLocalDown) {
                    super.mouseDown(with: down)
                    super.mouseUp(with: localSelectionEvent(from: event) ?? event)
                    handledLocalSelectionClick = true
                }
            }
        } else {
            super.mouseUp(with: event)
        }
        selectionStart = nil
        pointerDownPoint = nil
        selectionCanEditPrompt = false
        forcingLocalSelectionGesture = false
        pendingLocalSelectionMouseDown = nil
        localSelectionDidDrag = false
        if handledLocalSelectionClick {
            // Read Ghostty's selection directly, without touching the clipboard.
            // Only a range proven against the live logical input may be edited.
            if canEditPrompt, let start, let pendingLocalDown,
               pendingLocalDown.clickCount > 1,
               pendingLocalDown.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
               promptBuffer.isReliable,
               let offset = cursorMovementOffset(toTerminalPoint: start),
               let rendered = selectedText(),
               let range = TerminalPromptSelectionEdit.clickedRange(
                   rendered: rendered, characters: promptBuffer.characters,
                   clickedIndex: promptBuffer.cursor + offset,
                   lineSelection: pendingLocalDown.clickCount >= 3,
                   shell: owner?.forcesLocalPromptSelection != true
               ) {
                promptSelection = PromptSelection(
                    characterCount: range.count,
                    movementOffset: range.upperBound - promptBuffer.cursor
                )
            }
            return
        }
        let clickDistance = pointerStart.map { hypot(end.x - $0.x, end.y - $0.y) }
        let unmodified = event.modifierFlags
            .intersection([.command, .option, .control, .shift]).isEmpty
        if let clickDistance, clickDistance < 4, unmodified {
            // Open links only after this has proven to be a click. Opening on
            // mouse-down made paths and URLs impossible to drag-select and
            // therefore impossible to copy from Codex/Claude transcripts.
            if owner?.openHoveredLink() == true { return }
            if placePromptCursor(at: event.locationInWindow) {
                return
            }
            if forcedLocalSelection {
                // Alternate-screen applications and ordinary shells still
                // receive real clicks; only drag gestures stay local.
                replayTerminalClick(at: event.locationInWindow)
                return
            }
        }
        guard canEditPrompt, let start,
              hypot(end.x - start.x, end.y - start.y) >= 2,
              selectionIsNearActivePrompt(start: start, end: end)
        else { return }
        // Arm a prompt deletion only from the logical prompt mirror. The
        // previous fallback copied Ghostty's rendered selection to obtain a
        // character count, which wrote the system clipboard on every prompt
        // drag — and a jittery click past the drag threshold clobbered
        // whatever the user was about to paste. When the mirror cannot
        // resolve both endpoints no deletion is armed; Cmd+C still copies.
        guard promptBuffer.isReliable,
              let startOffset = cursorMovementOffset(toTerminalPoint: start),
              let endOffset = cursorMovementOffset(toTerminalPoint: end),
              startOffset != endOffset
        else { return }
        promptSelection = PromptSelection(
            characterCount: abs(endOffset - startOffset),
            movementOffset: max(startOffset, endOffset)
        )
    }

    override func keyUp(with event: NSEvent) {
        guard quarantinedPromptKeyCodes.remove(event.keyCode) == nil else { return }
        super.keyUp(with: event)
    }

    override func keyDown(with event: NSEvent) {
        let enclosingKeyDown = promptKeyDownInFlight
        promptKeyDownInFlight = event
        defer { promptKeyDownInFlight = enclosingKeyDown }
        if handleWorkOverviewShortcut(event) { quarantinedPromptKeyCodes.insert(event.keyCode); return }
        quarantinedPromptKeyCodes.remove(event.keyCode)
        if !replayingDeferredPromptKey { recordPromptProvenanceKey(event) }
        var forwardsOriginalKey = false
        defer {
            if !forwardsOriginalKey { quarantinedPromptKeyCodes.insert(event.keyCode) }
        }
        let cancelModifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let cancelsPrompt = (event.keyCode == 53 && cancelModifiers.isEmpty) ||
            (cancelModifiers == .control && event.charactersIgnoringModifiers?.lowercased() == "c")
        if promptInspectionBlocksExternalInput, nativePasteConfirmation == nil, cancelsPrompt {
            cancelPromptInspectionForNativeInput()
            forwardsOriginalKey = true
            super.keyDown(with: event)
            return
        }
        if promptInspectionPreservesInput, promptInspectionTask == nil,
           nativePasteConfirmation == nil, !promptInspectionRequiresRecovery,
           preservedPromptFiles.isEmpty {
            resumeNativeTypingPreservingText()
        }
        if localSelectAllNeedsExactText, !promptInspectionPreservesInput {
            // Replacing or deleting the local selection needs the exact draft:
            // inspect now and queue this key. Other keys end the selection;
            // Command shortcuts (copy, paste, cut) are handled on their own path.
            if Self.editsPromptSelection(event) { beginDeferredSelectAllInspection() }
            else if !event.modifierFlags.contains(.command) { localSelectAllNeedsExactText = false }
        }
        if promptInspectionPreservesInput {
            owner?.recordInputDiagnostic("input-blocked", details: ["phase": promptInspectionPhase,
                "queued_actions": String(deferredPromptInput.count),
                "inspection_active": String(promptInspectionTask != nil),
                "paste_active": String(nativePasteConfirmation != nil)])
            owner?.notePreservedTyping(inspectionActive: promptInspectionTask != nil,
                                       files: !preservedPromptFiles.isEmpty)
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "a" {
                // Command-A stays local; it never starts or restarts inspection.
                owner?.recordInputDiagnostic("select-all-local", details: ["path": "preserved"])
            } else { deferredPromptInput.append(.key(event)) }
            return
        }
        if event.timestamp > 0 {
            RelayPerformance.shared.recordKeyDispatchLatency(
                milliseconds: max(
                    0,
                    (ProcessInfo.processInfo.systemUptime - event.timestamp) * 1_000
                )
            )
        }
        owner?.prepareForUserInteraction()
        owner?.clearPreservedTypingNotice()
        owner?.recordInputDiagnostic("key-down", details: [
            "first_responder": String(window?.firstResponder === self),
            "surface_visible": String(relaySurfaceIsVisible),
        ])
        synchronizePromptMirrorFromRenderer()
        if handlePaneReconnectShortcut(event) { return }
        if handlePromptHistoryShortcut(event) { return }
        if handleApplicationClipboardShortcut(event) { return }
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "v",
           importFiles(from: NSPasteboard.general) {
            invalidatePromptMirror()
            return
        }
        if handleKeyboardPromptSelection(event) {
            return
        }
        if handleKeyboardPromptNavigation(event) { return }
        if (event.keyCode == 51 || event.keyCode == 117),
           event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           promptSelection != nil {
            if !deleteCurrentPromptSelection() {
                preserveDeferredPromptInput(.key(event), message: "The selected draft could not be verified. Input is preserved for recovery.")
            }
            return
        }
        if handleCompositePromptDeletion(event) { return }
        let hadPromptSelection = promptSelection != nil
        trackNonTextKey(event)
        forwardsOriginalKey = true
        super.keyDown(with: event)
        // Printable input synchronously reaches insertText, where it replaces
        // the selected prompt range. Navigation, Escape, and other TUI keys do
        // not, so collapse the local selection after Ghostty handles them.
        if hadPromptSelection, promptSelection != nil {
            clearPromptSelection()
        }
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        if !replayingDeferredPromptText { recordPromptProvenanceText(string) }
        if localSelectAllNeedsExactText, !replayingDeferredPromptText { beginDeferredSelectAllInspection() }
        if promptInspectionPreservesInput {
            consumeCurrentTextInputEvent()
            deferredPromptInput.append(.text(preservedPromptText(string), replacementRange))
            recordInsertTextRoute("preserved")
            return
        }
        owner?.prepareForUserInteraction()
        let text: String?
        if let attributed = string as? NSAttributedString {
            text = attributed.string
        } else {
            text = string as? String
        }
        if let text, !text.isEmpty {
            synchronizePromptMirrorFromRenderer()
            owner?.recordInputDiagnostic("insert-text", details: [
                "characters": String(text.count),
            ])
            if requiresExactPromptReplacement(.text(preservedPromptText(string), replacementRange)) {
                consumeCurrentTextInputEvent()
                // Clear the local IME preview while retaining the committed
                // text as the transaction's original recovery action.
                super.unmarkText()
                recordInsertTextRoute("exact_replacement")
                _ = handleExactPromptReplacement(text, kind: .typing,
                    recoveryAction: .text(preservedPromptText(string), replacementRange))
                return
            }
            hasLocalInputSincePromptBoundary = true
            recordInsertTextRoute(promptSelection != nil ? "selection_replace" : "native")
            if let promptSelection {
                // Match native text fields: typing replaces the active
                // selection and remains one undoable edit.
                guard window != nil, promptBuffer.plannedDeletionSnapshot(
                    characterCount: promptSelection.characterCount, movementOffset: promptSelection.movementOffset) != nil else {
                    preserveDeferredPromptInput(.text(preservedPromptText(string), replacementRange),
                        message: "The selected draft could not be verified. Input is preserved for recovery.")
                    return
                }
                guard applyPromptEdit(promptSelection, recordHistory: true, historyKind: .typing, followingText: text) else {
                    preserveDeferredPromptInput(.text(preservedPromptText(string), replacementRange),
                        message: "The selected draft could not be verified. Input is preserved for recovery.")
                    return
                }
                clearPromptSelection()
                consumeCurrentTextInputEvent()
                super.unmarkText()
                promptBuffer.insert(text)
                if !promptBuffer.isReliable { resetPromptHistory() }
                owner?.userEnteredInput()
                return
            } else {
                recordPromptEdit(.typing)
            }
            promptBuffer.insert(text)
            if !promptBuffer.isReliable { resetPromptHistory() }
            owner?.userEnteredInput()
        }
        else { recordInsertTextRoute("native") }
        if replayingDeferredPromptText {
            // Inspection may finish after keyboard focus changes. Replay the
            // already admitted commit on its captured ordered surface path.
            super.unmarkText()
            if let text { sendPromptPlainText(text) }
        } else {
            super.insertText(string, replacementRange: replacementRange)
        }
    }

    @discardableResult
    func handleApplicationClipboardShortcut(_ event: NSEvent) -> Bool {
        // Own the standard macOS editing shortcuts. Delegating these through
        // Ghostty's binding lookup made them dependent on the active terminal
        // mode and key-equivalent echo path, which can differ after an SSH
        // reconnect or while an agent TUI has application keyboard mode set.
        // Command always means a local clipboard operation in Relay.
        if event.type == .keyDown,
           event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
           let key = event.charactersIgnoringModifiers?.lowercased() {
            switch key {
            case "c":
                return handleApplicationClipboardAction(.copy)
            case "x":
                return handleApplicationClipboardAction(.cut)
            case "v":
                return handleApplicationClipboardAction(.paste)
            case "a":
                return handleApplicationClipboardAction(.selectAll)
            default:
                break
            }
        }
        return false
    }

    @discardableResult
    func handleApplicationClipboardAction(_ action: RelayClipboardAction) -> Bool {
        if localSelectAllNeedsExactText, action == .cut || action == .paste { beginDeferredSelectAllInspection() }
        if promptInspectionPreservesInput {
            if action == .copy, promptInspectionTask == nil, nativePasteConfirmation == nil,
               copyPreservedPromptText() { return true }
            if action == .selectAll {
                if nativePasteConfirmation != nil { deferredPromptInput.append(.clipboard(action)) }
                else { owner?.recordInputDiagnostic("select-all-local", details: ["path": "preserved"]) }
            } else if action == .copy, let text = promptInspectionVisualCopy {
                _ = writeCopiedText(text, source: "preserved-composer-selection")
            } else if action == .paste {
                let files = localFileURLs(from: .general)
                let text = NSPasteboard.general.string(forType: .string)
                if !files.isEmpty || text?.isEmpty == false {
                    deferredPromptInput.append(.paste(text: text, files: files))
                }
            } else { deferredPromptInput.append(.clipboard(action)) }
            return true
        }
        // This result means the local command was handled, not that bytes
        // were written. An empty selection/clipboard is a local no-op; letting
        // it fall through can invoke Ghostty's remote key path or another pane.
        switch action {
        case .copy:
            _ = copyRelaySelectionToPasteboard()
        case .cut:
            _ = cutRelayPromptSelection()
        case .paste:
            _ = pasteFromClipboard()
        case .selectAll:
            _ = selectAllRelayContent()
        }
        return true
    }

    @IBAction override func copy(_ sender: Any?) {
        _ = copyRelaySelectionToPasteboard()
    }

    @IBAction override func selectAll(_ sender: Any?) {
        _ = selectAllRelayContent()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // AppKit offers equivalents to sibling views too. A visible terminal
        // must never consume an editor's paste, selection or navigation keys.
        guard window?.firstResponder === self else { return false }
        if handleWorkOverviewShortcut(event) { quarantinedPromptKeyCodes.insert(event.keyCode); return true }
        if promptInspectionPreservesInput {
            quarantinedPromptKeyCodes.insert(event.keyCode)
            if handleApplicationClipboardShortcut(event) { quarantinedPromptKeyCodes.insert(event.keyCode); return true }
            deferredPromptInput.append(.key(event))
            return true
        }
        if handlePaneReconnectShortcut(event) { quarantinedPromptKeyCodes.insert(event.keyCode); return true }
        if handlePromptHistoryShortcut(event) { quarantinedPromptKeyCodes.insert(event.keyCode); return true }
        if handleApplicationClipboardShortcut(event) { quarantinedPromptKeyCodes.insert(event.keyCode); return true }
        // Shift-Return can be offered to AppKit's key-equivalent chain instead
        // of keyDown (notably after a terminal has been reparented, floated, or
        // restored). Replay it through the normal Ghostty keyboard translator
        // so negotiated Kitty keyboard mode still produces CSI 13;2u rather
        // than submitting the agent prompt.
        if event.type == .keyDown,
           (event.keyCode == 36 || event.keyCode == 76),
           event.modifierFlags.contains(.shift),
           event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            keyDown(with: event)
            return true
        }
        // AppKit offers navigation keys to the key-equivalent chain before it
        // delivers keyDown. Intercept Shift+Arrow here as well so keyboard
        // prompt selection is reliable with hardware keyboards and synthetic
        // accessibility input alike.
        if event.type == .keyDown, handleKeyboardPromptSelection(event) {
            quarantinedPromptKeyCodes.insert(event.keyCode)
            return true
        }
        if event.type == .keyDown, handleKeyboardPromptNavigation(event) {
            quarantinedPromptKeyCodes.insert(event.keyCode)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Consume the native diagnostics equivalent in the focused terminal too.
    /// Accessibility key events can be delivered directly to this view while
    /// AppKit's menu tracking is elsewhere; they must never enter the PTY.
    private func handleWorkOverviewShortcut(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              let binding = RelayKeyBinding(event: event),
              binding == RelayKeyBindingStorage.binding(
                for: .quickNavigate, overrides: RelayKeyBindingStorage.load()
              ) else { return false }
        // AppKit can deliver equivalents directly to the terminal. Application
        // navigation must precede draft preservation and never enter its queue
        // or Ghostty, including when prompt inspection owns native input.
        if !event.isARepeat {
            NotificationCenter.default.post(name: .relayWorkOverview, object: nil)
        }
        return true
    }

    private func handlePaneReconnectShortcut(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.modifierFlags.intersection([.command, .option, .control, .shift]) == [.command, .option, .shift],
              event.charactersIgnoringModifiers?.lowercased() == "r" else { return false }
        Task { @MainActor [weak runtime = owner] in
            _ = await runtime?.reconnectExistingPaneRoute()
        }
        return true
    }

    private func handlePromptHistoryShortcut(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.modifierFlags.contains(.command),
              event.modifierFlags.intersection([.control, .option]).isEmpty,
              event.charactersIgnoringModifiers?.lowercased() == "z"
        else { return false }
        _ = performPromptHistoryAction(redo: event.modifierFlags.contains(.shift))
        // Command-Z is an application editing shortcut, like Command-C/V/A.
        // Consume it even while reconnect has invalidated the prompt mirror
        // or history. Falling through to Ghostty can insert a literal z.
        return true
    }

    @discardableResult
    func performPromptHistoryAction(redo: Bool) -> Bool {
        if promptInspectionPreservesInput {
            deferredPromptInput.append(.history(redo))
            return true
        }
        synchronizePromptMirrorFromRenderer()
        // Recovered text alone cannot authorize restoring quarantined history.
        // Keep this action behind the pending fresh identity observation, and
        // discard it if local editing, focus, or the exact draft/caret changes.
        if suspendedPromptHistory != nil, let pendingOwner = promptOwnerTask,
           let expected = promptBuffer.snapshot {
            let generation = promptHistoryGeneration
            Task { @MainActor [weak self] in
                await pendingOwner.value
                guard let self, self.promptHistoryGeneration == generation,
                      self.promptBuffer.snapshot == expected,
                      self.window?.firstResponder === self else { return }
                _ = self.performPromptHistoryAction(redo: redo)
            }
            return true
        }
        let hasRequestedHistory = redo ? promptHistory.canRedo : promptHistory.canUndo
        owner?.recordInputDiagnostic("prompt-history-action", details: [
            "redo": String(redo), "history": String(hasRequestedHistory),
            "reliable": String(promptBuffer.isReliable),
            "semantic_editing": String(promptEditingIsSemanticallyActive),
            "characters": String(promptBuffer.snapshot?.characters.count ?? -1),
        ])
        guard let current = promptBuffer.snapshot,
              promptEditingIsSemanticallyActive || hasRequestedHistory else { return false }
        var proposedHistory = promptHistory
        let target = redo
            ? proposedHistory.redo(current: current)
            : proposedHistory.undo(current: current)
        guard let target else { return false }
        if owner?.promptInspectionRequiresKernelIdentity == true,
           owner?.promptInspectionIdentity?.kind == .claude {
            let generation = promptHistoryGeneration
            let intent = PromptMutationIntent(expected: current, target: target,
                expectedOwner: promptOwnerBinding, requiresOwnedHistory: true,
                isCurrent: { [weak self] in self?.promptHistoryGeneration == generation },
                publish: { [weak self] in
                    guard let self else { return }
                    self.promptHistory = proposedHistory
                    self.refreshPromptHistoryIdentity()
                },
                nativeFallback: { [weak self] lease in
                    self?.restorePromptSnapshot(target, replacing: current, expectedControlLease: lease, publish: false) == true
                }, recoveryAction: .history(redo))
            guard beginExactPromptInspection(mutation: intent) else {
                promptInspectionRequiresRecovery = true
                preserveDeferredPromptInput(.history(redo),
                    message: "The history action is preserved; recover the prompt before retrying.")
                return true
            }
            return true
        }
        guard restorePromptSnapshot(target, replacing: current) else {
            if promptInspectionRequiresRecovery {
                preserveDeferredPromptInput(.history(redo),
                    message: "The prompt history edit could not be dispatched. Input is preserved for recovery.")
            }
            return false
        }
        promptHistory = proposedHistory
        return true
    }

    private var usesExactPromptMutations: Bool {
        owner?.promptInspectionRequiresKernelIdentity == true && owner?.promptInspectionIdentity?.kind == .claude
    }

    private func requiresExactPromptReplacement(_ action: DeferredPromptInput) -> Bool {
        guard usesExactPromptMutations else { return false }
        if promptSelection != nil { return true }
        if case .text(_, let range) = action { return range.location != NSNotFound }
        return false
    }

    /// Stage one original editing intent without publishing its history or
    /// mirror before provider application and original renderer readback.
    @discardableResult
    private func startExactPromptMutation(current: TerminalPromptBuffer.Snapshot,
        target: TerminalPromptBuffer.Snapshot, kind: TerminalPromptEditHistory.Kind,
        recoveryAction: DeferredPromptInput) -> Bool {
        guard current.cursor != target.cursor ||
              Data(current.text.utf8) != Data(target.text.utf8) else { return true }
        let generation = promptHistoryGeneration
        let suspended = suspendedPromptHistory
        var proposedHistory = suspended?.snapshot == current ? suspended!.history : promptHistory
        let requiresOwnedHistory = proposedHistory.canUndo || proposedHistory.canRedo
        let expectedOwner = suspended?.binding ?? promptOwnerBinding
        proposedHistory.record(before: current, kind: kind)
        let intent = PromptMutationIntent(expected: current, target: target,
            expectedOwner: expectedOwner, requiresOwnedHistory: requiresOwnedHistory,
            isCurrent: { [weak self] in self?.promptHistoryGeneration == generation },
            publish: { [weak self] in
                guard let self else { return }
                self.suspendedPromptHistory = nil
                self.promptHistoryGeneration &+= 1
                self.promptHistory = proposedHistory
                self.refreshPromptHistoryIdentity()
            }, nativeFallback: { [weak self] lease in
                self?.restorePromptSnapshot(target, replacing: current, expectedControlLease: lease, publish: false) == true
            }, recoveryAction: recoveryAction)
        if !beginExactPromptInspection(mutation: intent) {
            promptInspectionRequiresRecovery = true
            preserveDeferredPromptInput(recoveryAction,
                message: "The edit is preserved; recover the original prompt before retrying.")
        }
        return true
    }

    @discardableResult
    private func handleExactPromptReplacement(_ text: String, kind: TerminalPromptEditHistory.Kind,
        recoveryAction: DeferredPromptInput) -> Bool {
        guard requiresExactPromptReplacement(recoveryAction) else { return false }
        guard let current = promptBuffer.snapshot else {
            promptInspectionRequiresRecovery = true
            preserveDeferredPromptInput(recoveryAction, message: "The draft could not be verified. Input is preserved for recovery.")
            return true
        }
        var planned = promptBuffer
        if let selection = promptSelection {
            guard let deleted = planned.plannedDeletionSnapshot(characterCount: selection.characterCount,
                movementOffset: selection.movementOffset) else {
                promptInspectionRequiresRecovery = true
                preserveDeferredPromptInput(recoveryAction, message: "The selected draft could not be verified. Input is preserved for recovery.")
                return true
            }
            planned.restore(deleted)
        }
        planned.insert(text)
        guard let target = planned.snapshot else {
            promptInspectionRequiresRecovery = true
            preserveDeferredPromptInput(recoveryAction, message: "The edit exceeds the prompt limit. Input is preserved for recovery.")
            return true
        }
        return startExactPromptMutation(current: current, target: target, kind: kind, recoveryAction: recoveryAction)
    }

    private func recordPromptEdit(_ kind: TerminalPromptEditHistory.Kind) {
        suspendedPromptHistory = nil
        promptHistoryGeneration &+= 1
        refreshPromptHistoryIdentity()

        guard let snapshot = promptBuffer.snapshot else {
            resetPromptHistory()
            return
        }
        promptHistory.record(before: snapshot, kind: kind)
    }

    /// Reconcile the remote editor using its negotiated keyboard mode. Moving
    /// to the end and backspacing is understood by shells, Codex, and Claude;
    /// embedded newlines use negotiated bracketed paste framing. A synthetic
    /// Shift-Return can become an ordinary Return when the provider has not
    /// negotiated an extended keyboard protocol.
    private func restorePromptSnapshot(
        _ target: TerminalPromptBuffer.Snapshot,
        replacing current: TerminalPromptBuffer.Snapshot,
        expectedControlLease: RelayPromptEditorControlLease? = nil,
        publish: Bool = true
    ) -> Bool {
        guard window != nil, target.characters.count <= 4_096, current.characters.count <= 4_096,
              target.cursor >= 0, target.cursor <= target.characters.count,
              current.cursor >= 0, current.cursor <= current.characters.count else {
            resetPromptHistory()
            return false
        }
        // Refuse multiline restoration before sending any editing keys if
        // the editor cannot distinguish pasted newlines from submission.
        guard !target.characters.contains(where: { $0.isNewline })
                || owner?.bracketedPasteIsActive == true else {
            owner?.recordInputDiagnostic("prompt-history-multiline-unavailable")
            return false
        }
        let movementKeys = promptEditorKeyCount(current.characters[current.cursor...])
        let deletionKeys = promptEditorKeyCount(current.characters[...])
        let caretKeys = promptEditorKeyCount(target.characters[target.cursor...])
        guard movementKeys <= 65_536, deletionKeys <= 65_536, caretKeys <= 65_536 else {
            owner?.recordInputDiagnostic("prompt-history-key-limit")
            return false
        }
        guard let owner, owner.performPromptControlTranslation(in: self,
            expectedControlLease: expectedControlLease, actions: {
                for _ in 0..<movementKeys { sendSyntheticPromptKey(124) }
                for _ in 0..<deletionKeys { sendSyntheticPromptKey(51) }
                sendPromptPlainText(String(target.characters))
                for _ in 0..<caretKeys { sendSyntheticPromptKey(123) }
            }) else {
            // Nothing was dispatched; an undo/redo restore has no native
            // single-key equivalent, so the caller keeps the hold.
            owner?.recordInputDiagnostic("prompt-control-refused", details: [
                "reason": "restore", "queued_actions": String(deferredPromptInput.count)])
            promptInspectionRequiresRecovery = true
            return false
        }
        guard publish else { return true }
        promptBuffer.restore(target)
        refreshPromptHistoryIdentity()
        promptSelection = nil
        keyboardSelectionOffset = nil
        keyboardSelectionIsVisual = false
        hasLocalInputSincePromptBoundary = !target.characters.isEmpty
        owner.userEnteredInput()
        return true
    }

    private func sendPromptPlainText(_ text: String) {
        // Ghostty treats this as pasted text. It supplies mode 2004 framing
        // while retaining ordering with synthetic keys already sent to it.
        sendText(text)
    }

    /// Recover a soft-wrapped draft only at its logical end. The
    /// renderer must prove every boundary is a soft wrap, and its text length
    /// must match the exact grid distance from a recognized prompt to the caret.
    private func recoverWrappedPrompt(row: Int, column: Int, columns: Int) -> Bool {
        guard row > 0, column >= 0, column < columns, columns > 0 else { return false }
        let limit = min(row, min(32, 4_096 / columns + 1))
        for distance in 1...limit {
            let firstRow = row - distance
            guard let first = readViewportRow(firstRow, columns: columns),
                  let prefix = TerminalPromptSelectionEdit.inputPrefixLength(first, shell: semanticShellPromptActive)
            else { continue }
            guard let rendered = readViewportRange(startRow: firstRow, endRow: row, columns: columns),
                  !rendered.contains("\n"), !rendered.contains("\r") else { return false }
            guard let beforeCaret = readViewportBeforeCaret(startRow: firstRow, caretRow: row,
                                                           caretColumn: column, columns: columns),
                  !beforeCaret.contains("\n"), !beforeCaret.contains("\r") else { return false }
            let caretCharacters = Array(beforeCaret)
            let cellsToCaret = caretCharacters.count
            let characters = Array(rendered)
            guard cellsToCaret >= prefix, characters.count >= cellsToCaret,
                  Array(characters.prefix(cellsToCaret)) == caretCharacters,
                  characters.dropFirst(cellsToCaret).allSatisfy({ $0 == " " }) else { return false }
            let draft = Array(characters[prefix..<cellsToCaret])
            guard !draft.isEmpty, draft.count <= 4_096,
                  draft.allSatisfy({ $0.unicodeScalars.allSatisfy { $0.value >= 32 && $0.value != 127 } })
            else { return false }
            promptBuffer.restore(.init(characters: draft, cursor: draft.count))
            refreshPromptHistoryIdentity()
            owner?.recordInputDiagnostic("prompt-mirror-recovered", details: [
                "characters": String(draft.count), "wrapped_rows": String(distance + 1)
            ])
            return true
        }
        return false
    }

    /// Recover an exact agent input line at the live caret.
    /// Transcript rows, placeholders, hidden input and hard line boundaries
    /// do not provide an exact editor range and must never be used for deletion.
    private func synchronizePromptMirrorFromRenderer() {
        if let pending = promptMirrorAwaitingHostOutput {
            if case .inMemory(let session) = configuration.backend, session === pending.session {
                guard session.parsedHostOutputRevision != pending.revision else { return }
            }
            promptMirrorAwaitingHostOutput = nil
        }
        // Submitting clears the mirror to a reliable empty buffer. Providers
        // can subsequently populate their composer without any local key event
        // (history, queued prompts, or an accepted suggestion). An empty mirror
        // is therefore not evidence that the visible provider composer is empty.
        // Keep mirrors containing local input intact while their echo catches up.
        let providerMayHavePopulatedPrompt = owner?.forcesLocalPromptSelection == true &&
            !hasLocalInputSincePromptBoundary && promptBuffer.snapshot?.characters.isEmpty == true
        guard !promptBuffer.isReliable || providerMayHavePopulatedPrompt else { return }
        var diagnostic = [
            "reason": "inactive",
            "shell_prompt": String(semanticShellPromptActive),
            "agent_prompt": String(owner?.forcesLocalPromptSelection == true),
            "semantic_editing": String(promptEditingIsSemanticallyActive),
            "viewport_live": String(owner?.promptEditingViewportIsLive == true),
        ]
        defer { owner?.recordInputDiagnostic("prompt-mirror-recovery", details: diagnostic) }
        // A restored CLI may still be labelled Shell while status discovery
        // catches up. A real local editor interaction permits recovery, but the
        // live renderer must still prove a recognized prefix and exact caret.
        guard owner?.forcesLocalPromptSelection == true || semanticShellPromptActive ||
              hasLocalInputSincePromptBoundary else { return }
        diagnostic["reason"] = "viewport"
        guard owner?.promptEditingViewportIsLive == true else { return }
        diagnostic["reason"] = "geometry"
        guard let geometry = activeCursorGeometry() else { return }
        let gridX = geometry.gridOrigin.x
        // IME geometry lies one row below the rendered input, as in pointer lookup.
        let row = Int(floor((geometry.point.y - geometry.cellSize.height - geometry.gridOrigin.y) / geometry.cellSize.height))
        let column = Int(floor((geometry.origin.x - gridX) / geometry.cellSize.width))
        diagnostic["row"] = String(row)
        diagnostic["column"] = String(column)
        diagnostic["columns"] = String(geometry.columns)
        if recoverWrappedPrompt(row: row, column: column, columns: geometry.columns) {
            diagnostic["reason"] = "recovered_wrapped"
            return
        }
        for offset in -1...1 {
            if let nearby = readViewportRow(row + offset, columns: geometry.columns) {
                diagnostic["shell_prefix_\(offset)"] = String(
                    TerminalPromptSelectionEdit.inputPrefixLength(nearby, shell: true) ?? -1)
                diagnostic["agent_prefix_\(offset)"] = String(
                    TerminalPromptSelectionEdit.inputPrefixLength(nearby, shell: false) ?? -1)
            }
        }
        diagnostic["reason"] = "row"
        guard let line = readViewportRow(row, columns: geometry.columns) else { return }
        diagnostic["linefeeds"] = String(line.filter { $0 == "\n" }.count)
        diagnostic["carriage_returns"] = String(line.filter { $0 == "\r" }.count)
        diagnostic["reason"] = "line_break"
        guard !line.contains("\n"), !line.contains("\r") else { return }
        let chars = Array(line)
        diagnostic["row_characters"] = String(chars.count)
        diagnostic["reason"] = "prefix"
        guard let start = TerminalPromptSelectionEdit.inputPrefixLength(line, shell: semanticShellPromptActive) else { return }
        diagnostic["reason"] = "caret_text"
        guard let beforeCaret = readViewportBeforeCaret(startRow: row, caretRow: row,
                                                       caretColumn: column, columns: geometry.columns) else { return }
        let caretCharacters = Array(beforeCaret)
        guard caretCharacters.count >= start,
              Array(chars.prefix(caretCharacters.count)) == caretCharacters else { return }
        let cursor = caretCharacters.count - start
        var draft = Array(chars.dropFirst(start))
        diagnostic["prefix"] = String(start)
        diagnostic["cursor"] = String(cursor)
        diagnostic["reason"] = "control_text"
        guard draft.allSatisfy({ $0.unicodeScalars.allSatisfy { $0.value >= 32 && $0.value != 127 } }) else { return }
        while draft.last == " ", draft.count > cursor { draft.removeLast() }
        diagnostic["draft_characters"] = String(draft.count)
        diagnostic["reason"] = "range"
        guard cursor >= 0, cursor <= draft.count, column < geometry.columns - 1,
              draft.count <= 4_096 else { return }
        // At column zero, dim placeholder text is indistinguishable from a draft.
        diagnostic["reason"] = "placeholder"
        guard cursor > 0 || draft.isEmpty else { return }
        promptBuffer.restore(.init(characters: draft, cursor: cursor))
        refreshPromptHistoryIdentity()
        diagnostic["reason"] = "recovered"
        owner?.recordInputDiagnostic("prompt-mirror-recovered", details: ["characters": String(draft.count)])
    }

    /// Select the painted provider composer without inventing its logical text.
    /// Provider word wrapping loses whitespace/newline information; that range
    /// is suitable for visual selection and copy, but cannot arm a deletion.
    private func selectRenderedProviderComposer() -> Bool {
        guard owner?.forcesLocalPromptSelection == true,
              let geometry = activeCursorGeometry(), geometry.columns > 0 else { return false }
        let row = Int(floor((geometry.point.y - geometry.cellSize.height - geometry.gridOrigin.y) / geometry.cellSize.height))
        let column = Int(floor((geometry.origin.x - geometry.gridOrigin.x) / geometry.cellSize.width))
        guard row > 0, column > 0, column < geometry.columns else { return false }
        for firstRow in stride(from: row - 1, through: max(0, row - 32), by: -1) {
            guard let first = readViewportRow(firstRow, columns: geometry.columns),
                  let prefix = TerminalPromptSelectionEdit.inputPrefixLength(first, shell: false) else { continue }
            let indent = String(repeating: " ", count: prefix)
            var valid = true
            for continuation in (firstRow + 1)...row {
                guard let line = readViewportRow(continuation, columns: geometry.columns),
                      line.hasPrefix(indent),
                      TerminalPromptSelectionEdit.inputPrefixLength(line, shell: false) == nil else { valid = false; break }
                if continuation == row {
                    guard let before = readViewportBeforeCaret(startRow: row, caretRow: row,
                        caretColumn: column, columns: geometry.columns), before.hasPrefix(indent),
                        line.hasPrefix(before), line.dropFirst(before.count).allSatisfy({ $0 == " " }),
                        before.count > prefix else { valid = false; break }
                }
            }
            guard valid else { return false }
            // Resolve the prompt boundary in cells, including wide Unicode.
            let expected = String(first.prefix(prefix))
            guard let startColumn = (0..<geometry.columns).last(where: {
                readViewportBeforeCaret(startRow: firstRow, caretRow: firstRow,
                    caretColumn: $0, columns: geometry.columns) == expected
            }) else { return false }
            let start = (firstRow - row) * geometry.columns + startColumn - column
            clearPromptSelection()
            let selected = beginKeyboardPromptSelection(delta: 0, anchorOffset: start,
                visualOffsets: (start: start, end: 0))
            owner?.recordInputDiagnostic("select-all-rendered-composer", details: [
                "rows": String(row - firstRow + 1), "selected": String(selected)
            ])
            return selected
        }
        return false
    }

    /// Select the editable draft without moving the live PTY caret. A restored
    /// terminal screen does not prove the contents of its editor: consume the
    /// shortcut conservatively until the prompt mirror becomes reliable again.
    private func selectAllRelayContent() -> Bool {
        if promptInspectionPreservesInput {
            // Command-A stays local; it never starts or restarts inspection.
            owner?.recordInputDiagnostic("select-all-local", details: ["path": "preserved"])
            return true
        }
        synchronizePromptMirrorFromRenderer()
        let agentPrompt = owner?.forcesLocalPromptSelection == true
        guard owner?.allowsPromptSelectionEditing == true,
              promptEditingIsSemanticallyActive || hasLocalInputSincePromptBoundary,
              owner?.promptEditingViewportIsLive == true else {
            clearPromptSelection()
            if agentPrompt {
                // An agent TUI does not necessarily publish shell input marks,
                // and its busy phase can lag an editable restored composer.
                // Select only this live composer, locally; exact inspection
                // waits for an edit. Never select its transcript.
                if owner?.allowsPromptSelectionEditing == true,
                   owner?.promptEditingViewportIsLive == true { selectRenderedComposerLocally() }
                else { owner?.recordInputDiagnostic("select-all-local", details: ["path": "unknown", "reason": "not_editable"]) }
                return true
            }
            return performBindingAction("select_all")
        }
        guard let snapshot = promptBuffer.snapshot,
              snapshot.characters.count <= 4_096 else {
            clearPromptSelection()
            // A restored agent composer may not have a trustworthy mirror yet.
            // Cmd+A must never expand that uncertainty into transcript selection.
            if agentPrompt {
                selectRenderedComposerLocally()
                return true
            }
            return performBindingAction("select_all")
        }
        clearPromptSelection()
        guard !snapshot.characters.isEmpty else {
            if agentPrompt { selectRenderedComposerLocally() }
            return true
        }
        promptHistory.breakCoalescing()
        promptSelection = PromptSelection(
            characterCount: snapshot.characters.count,
            movementOffset: snapshot.characters.count - snapshot.cursor
        )
        owner?.recordInputDiagnostic("select-all-prompt", details: [
            "characters": String(snapshot.characters.count),
            "cursor": String(snapshot.cursor)
        ])
        if agentPrompt {
            owner?.recordInputDiagnostic("select-all-local", details: ["path": "mirror",
                "visual": String(!applicationIsCapturingMouse)])
            // A synthesized drag would be a mouse report while the TUI captures
            // the mouse; keep the exact mirror range without the highlight.
            guard !applicationIsCapturingMouse else { return true }
        }
        keyboardSelectionIsVisual = beginKeyboardPromptSelection(
            delta: snapshot.characters.count - snapshot.cursor,
            anchorOffset: -snapshot.cursor
        )
        return true
    }

    /// Agent Command-A without a trusted mirror: select the painted composer
    /// locally, never the transcript, and leave its exact text to the first
    /// edit. No bytes, editor bridge or resize. Unknown screens select nothing.
    @discardableResult
    private func selectRenderedComposerLocally() -> Bool {
        let reason = applicationIsCapturingMouse ? "mouse_capture" : selectRenderedProviderComposer() ? nil : "no_composer"
        owner?.recordInputDiagnostic("select-all-local", details: ["path": reason == nil ? "rendered" : "unknown",
            "reason": reason ?? ""])
        guard reason == nil else { return false }
        localSelectAllNeedsExactText = true
        return true
    }

    /// The exact inspection a local agent Command-A deferred, started when an
    /// edit needs the exact draft. The caller's action is then queued by the
    /// existing preserved-input path. Without inspection the local selection
    /// is dropped and the edit applies at the caret, as a plain edit.
    private func beginDeferredSelectAllInspection() {
        guard localSelectAllNeedsExactText else { return }
        localSelectAllNeedsExactText = false
        guard !promptInspectionPreservesInput else { return }
        let started = beginExactPromptInspection()
        owner?.recordInputDiagnostic("select-all-deferred-inspection", details: ["started": String(started)])
        if !started { clearPromptSelection() }
    }

    /// Keys that replace or delete a selected draft: Delete, Forward Delete
    /// and printable text without Command or Control. Navigation, Return, Tab
    /// and Escape are not.
    private static func editsPromptSelection(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.modifierFlags.intersection([.command, .control]).isEmpty else { return false }
        if event.keyCode == 51 || event.keyCode == 117 { return true }
        guard ![36, 48, 53, 76].contains(event.keyCode), let scalars = event.characters?.unicodeScalars,
              !scalars.isEmpty else { return false }
        return scalars.allSatisfy { $0.value >= 32 && $0.value != 127 && !(0xF700...0xF8FF).contains($0.value) }
    }

    /// Widen only the native viewport to make provider word wrapping reversible.
    /// No editing keys are sent during inspection. User input remains queued
    /// until the original viewport and the exact owner have both been restored.
    @discardableResult
    private func beginExactPromptInspection(mutation: PromptMutationIntent? = nil) -> Bool {
        if let mutation {
            guard mutation.isCurrent(), promptBuffer.snapshot == mutation.expected,
                  String(mutation.expected.characters).utf8.count <= RelayPromptEditorRPC.maximumDraftBytes,
                  String(mutation.target.characters).utf8.count <= RelayPromptEditorRPC.maximumDraftBytes,
                  mutation.expected.characters.count <= 4_096, mutation.target.characters.count <= 4_096,
                  mutation.target.cursor >= 0, mutation.target.cursor <= mutation.target.characters.count,
                  !String(mutation.target.characters).utf8.contains(0) else { return false }
        }
        guard promptInspectionTask == nil, !promptInspectionRequiresRecovery, nativePasteConfirmation == nil, let owner,
              owner.forcesLocalPromptSelection, owner.allowsPromptSelectionEditing,
              owner.promptEditingViewportIsLive,
              let identity = owner.promptInspectionIdentity,
              preservedPromptInputIdentity == nil || preservedPromptInputIdentity == identity,
              let window, window.firstResponder === self,
              let metrics = currentGridMetrics(), metrics.cellWidthPixels > 0,
              case .inMemory(let session) = configuration.backend else { return false }
        let columns = min(4_098, 8_000 / Int(metrics.cellWidthPixels))
        let originalRevision = session.parsedHostOutputRevision
        guard let originalGeometry = activeCursorGeometry(),
              let initialPromptFrame = captureProviderPromptFrame(geometry: originalGeometry) else { return false }
        guard let inputLease = owner.acquirePromptInspectionInputLease() else { return false }
        var inputLeaseReleased = false
        let releaseInputLease: @MainActor () -> Void = { [weak owner] in
            guard !inputLeaseReleased else { return }
            inputLeaseReleased = true
            owner?.releasePromptInspectionInputLease(inputLease)
        }
        let originalControlLease = owner.promptInspectionControlLease(inputLease)
        let originalFrame = frame
        let windowNumber = window.windowNumber
        _ = selectRenderedProviderComposer()
        promptInspectionVisualCopy = selectedText()
        let nativeResizes = session.nativeResizeEvents()
        let hostOutput = session.parsedHostOutputEvents()
        let (events, continuation) = AsyncStream<PromptInspectionEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(16))
        let taskID = UUID()
        promptInspectionPhase = "checking_owner"
        promptInspectionTaskID = taskID
        promptInspectionInputRelease = (taskID, releaseInputLease)
        promptInspectionEvents = continuation
        preservedPromptInputIdentity = identity
        promptInspectionPreservesInput = true
        clearPromptSelection()
        promptInspectionTask = Task { @MainActor [weak self, weak owner] in
            defer {
                releaseInputLease()
                if self?.promptInspectionInputRelease?.id == taskID {
                    self?.promptInspectionInputRelease = nil
                }
            }
            guard let self else { continuation.finish(); return }
            guard let owner else {
                continuation.finish()
                guard self.promptInspectionTaskID == taskID else { return }
                if let mutation {
                    self.promptInspectionRequiresRecovery = true
                    self.promptInspectionPreservesInput = true
                    self.deferredPromptInput.insert(mutation.recoveryAction, at: 0)
                }
                if self.promptInspectionTaskID == taskID {
                    self.promptInspectionTaskID = nil
                    self.promptInspectionTask = nil
                    self.promptInspectionEvents = nil
                    if self.deferredPromptInput.isEmpty {
                        self.promptInspectionPreservesInput = false
                        self.preservedPromptInputIdentity = nil
                        self.promptInspectionVisualCopy = nil
                    }
                }
                return
            }
            let resizes = Task { @MainActor in
                for await viewport in nativeResizes {
                    guard !Task.isCancelled else { break }
                    continuation.yield(.viewport(viewport))
                }
            }
            let parsedOutput = Task { @MainActor in
                for await _ in hostOutput {
                    guard !Task.isCancelled else { break }
                    continuation.yield(.parsedHostOutput)
                }
            }
            let leaseUpdates = Task { @MainActor in
                if let changes = owner.promptInspectionLeaseEvents(inputLease) {
                    for await _ in changes {
                        guard !Task.isCancelled else { break }
                        continuation.yield(.inputLeaseChanged)
                    }
                }
            }
            let deadline = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(mutation == nil ? 20 : 45)) } catch { return }
                continuation.yield(.timeout)
                if self?.promptInspectionTaskID == taskID { self?.promptInspectionTask?.cancel() }
            }
            var originalPromptFrame = initialPromptFrame
            var inspecting = false
            var restored = false
            var selectionAttempted = false
            var editorBarrier: TerminalIOBridge.PromptEditorRestorationBarrier?
            var editorRestorationTask: Task<Void, Never>?
            var editorRestoredRevision: UInt64?
            var recovered: TerminalPromptBuffer.Snapshot?
            var mutationCaretRevision: UInt64?
            var nativeFallbackRevision: UInt64?
            @MainActor func stillOwnsPrompt() -> Bool {
                !Task.isCancelled && self.promptInspectionTaskID == taskID && self.owner === owner &&
                owner.promptInspectionIdentity == identity &&
                (originalControlLease == nil || owner.promptInspectionControlLease(inputLease, requireIdleInput: false) == originalControlLease) &&
                owner.promptEditingViewportIsLive && owner.forcesLocalPromptSelection &&
                self.frame == originalFrame && self.window?.windowNumber == windowNumber &&
                self.window?.firstResponder === self && (mutation?.isCurrent() ?? true)
            }
            defer {
                resizes.cancel(); parsedOutput.cancel(); leaseUpdates.cancel(); deadline.cancel()
                editorRestorationTask?.cancel()
                if let editorBarrier { owner.endPromptInspectionRestorationBarrier(editorBarrier.id) }
                continuation.finish()
                let ownsInspection = self.promptInspectionTaskID == taskID
                if inspecting && ownsInspection { self.restoreViewportAfterInspection(); self.finishViewportInspection() }
                if ownsInspection {
                    self.promptInspectionEvents = nil
                    self.promptInspectionTask = nil
                    self.promptInspectionTaskID = nil
                }
                if ownsInspection, !restored, let mutation {
                    self.promptInspectionRequiresRecovery = true
                    self.promptInspectionPreservesInput = true
                    self.deferredPromptInput.insert(mutation.recoveryAction, at: 0)
                }
                if ownsInspection, !restored {
                    self.promptInspectionPhase = "failed_" + self.promptInspectionPhase
                    if self.deferredPromptInput.isEmpty && !selectionAttempted && !self.promptInspectionRequiresRecovery {
                        self.promptInspectionPreservesInput = false
                        self.preservedPromptInputIdentity = nil
                        self.promptInspectionVisualCopy = nil
                        self.toolTip = "Could not select the draft."
                    } else {
                        self.toolTip = self.promptInspectionRequiresRecovery
                            ? "Prompt inspection could not verify the original composer. Input is preserved; use the input recovery actions."
                            : "Could not select the draft. Your typed input is preserved; try Select All again."
                    }
                    owner.recordInputDiagnostic("prompt-inspection-unavailable", details: [
                        "queued_actions": String(self.deferredPromptInput.count),
                        "phase": self.promptInspectionPhase,
                        "draft_state": self.promptInspectionDraftState])
                }
            }
            let binding = await owner.readPromptOwnerBinding()
            guard stillOwnsPrompt(), !owner.promptInspectionRequiresKernelIdentity || binding != nil else { return }
            if let mutation {
                guard (!mutation.requiresOwnedHistory || mutation.expectedOwner != nil),
                      mutation.expectedOwner == nil || mutation.expectedOwner == binding else {
                    self.promptInspectionPhase = "history_owner_unverified_or_changed"
                    return
                }
            }
            var wideViewportReady = false
            var originalViewportReady = false
            if let binding, binding.binding.provider == "claude", let controlLease = originalControlLease {
                let transactionID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
                func request(_ operation: RelayPromptEditorRPC.Operation) -> RelayPromptEditorRPC.Request {
                    .init(operation: operation, id: transactionID, owner: binding.binding)
                }
                // Even an uncertain arm response must not be replayed. Explicit
                // unsupported responses are the only route to the wide fallback.
                self.promptInspectionRequiresRecovery = true
                self.promptInspectionPhase = "arming_readonly_editor"
                do {
                    let armed = try await owner.promptEditorRequest(request(.arm), inputLease: inputLease,
                        expectedControlLease: controlLease)
                    self.promptInspectionPhase = "readonly_editor_arm_" + armed.state.rawValue
                    guard stillOwnsPrompt() else { return }
                    switch armed.state {
                    case .refused, .unarmed, .unavailable:
                        guard armed.isExplicitlyUnsupported(for: request(.arm)) else { return }
                        self.promptInspectionPhase = "checking_unsupported_editor_owner"
                        let stillBound = await owner.readPromptOwnerBinding()
                        guard stillOwnsPrompt(), stillBound == binding else { return }
                        if let mutation {
                            // A fallback is permitted only before editor entry,
                            // with the original native draft and control lease.
                            guard session.parsedHostOutputRevision == originalRevision,
                                  self.promptBuffer.snapshot == mutation.expected,
                                  let original = RelayProviderPromptRowMatch.map(draft: mutation.expected.characters,
                                    frame: originalPromptFrame), original.cursor == mutation.expected.cursor,
                                  owner.promptInspectionControlLease(inputLease) == controlLease,
                                  stillOwnsPrompt() else { return }
                            nativeFallbackRevision = session.parsedHostOutputRevision
                            guard mutation.nativeFallback(controlLease) else { return }
                            recovered = mutation.target
                            originalViewportReady = true
                            self.promptInspectionPhase = "waiting_native_fallback_readback"
                        } else {
                            // A bound unsupported response proves that no editor was
                            // entered. A status-line repaint or the final echo of
                            // pre-selection typing may arrive during the owner RPC.
                            // Capture the current composer under the same input lease;
                            // later wide/restored mappings still verify the exact draft.
                            self.promptInspectionRequiresRecovery = false
                            self.promptInspectionPhase = "refreshing_unsupported_editor_frame"
                            self.synchronizeAndRedraw()
                            guard let geometry = self.activeCursorGeometry(),
                                  let currentFrame = self.captureProviderPromptFrame(geometry: geometry) else { return }
                            originalPromptFrame = currentFrame
                        }
                    case .armed:
                        guard session.parsedHostOutputRevision == originalRevision,
                              owner.triggerReadOnlyPromptEditor(inputLease: inputLease,
                                expectedControlLease: controlLease) else { return }
                        self.promptInspectionPhase = "capturing_readonly_editor"
                        let captured = try await owner.promptEditorRequest(request(.snapshot), inputLease: inputLease,
                            expectedControlLease: controlLease)
                        guard stillOwnsPrompt(), captured.state == .captured, let bytes = captured.text,
                              let text = String(data: bytes, encoding: .utf8),
                              let barrier = owner.beginPromptInspectionRestorationBarrier(inputLease: inputLease,
                                expectedControlLease: controlLease) else { return }
                        editorBarrier = barrier
                        var barrierEvents = barrier.events.makeAsyncIterator()
                        guard let ready = await barrierEvents.next(), case .armed = ready,
                              stillOwnsPrompt() else { return }
                        // The parser drain/arm acknowledgment precedes cancel.
                        guard text.count <= 4_096,
                              let original = RelayProviderPromptRowMatch.map(draft: Array(text), frame: originalPromptFrame) else { return }
                        if let mutation {
                            // Comparing UTF-8 also rejects canonically equivalent but
                            // byte-distinct stale drafts before the single commit.
                            guard bytes == Data(String(mutation.expected.characters).utf8),
                                  original.cursor == mutation.expected.cursor,
                                  self.promptBuffer.snapshot == mutation.expected else { return }
                            let targetBytes = Data(String(mutation.target.characters).utf8)
                            var commit = request(.commit)
                            commit.digest = RelayPromptEditorRPC.digest(bytes)
                            commit.text = targetBytes
                            self.promptInspectionPhase = "committing_exact_editor"
                            let committed = try await owner.promptEditorRequest(commit, inputLease: inputLease,
                                expectedControlLease: controlLease)
                            guard stillOwnsPrompt(), committed.state == .committed else { return }
                            var receipt = request(.receipt)
                            receipt.digest = RelayPromptEditorRPC.digest(targetBytes)
                            self.promptInspectionPhase = "waiting_editor_application_receipt"
                            let applied = try await owner.promptEditorRequest(receipt, inputLease: inputLease,
                                expectedControlLease: controlLease)
                            guard stillOwnsPrompt(), applied.state == .applied else { return }
                            recovered = mutation.target
                        } else {
                            // Cancel itself is never evidence of provider resumption.
                            self.promptInspectionPhase = "cancelling_readonly_editor"
                            let cancelled = try await owner.promptEditorRequest(request(.cancel), inputLease: inputLease,
                                expectedControlLease: controlLease)
                            guard stillOwnsPrompt(), cancelled.state == .cancelled else { return }
                            recovered = .init(characters: Array(text), cursor: original.cursor)
                        }
                        originalViewportReady = true
                        self.promptInspectionPhase = "waiting_readonly_editor_restoration"
                        editorRestorationTask = Task { @MainActor in
                            for await event in barrier.events {
                                guard !Task.isCancelled else { break }
                                continuation.yield(.editorRestoration(event))
                            }
                        }
                    default: return
                    }
                } catch {
                    self.promptInspectionPhase = "uncertain_readonly_editor"
                    return
                }
            }
            if recovered == nil {
                guard mutation == nil else { return }
                guard columns > Int(metrics.columns), stillOwnsPrompt(),
                      self.beginViewportInspection(columns: columns) else { return }
                inspecting = true
                self.promptInspectionPhase = "waiting_wide_viewport"
            }
            for await event in events {
                guard stillOwnsPrompt() else {
                    self.promptInspectionPhase = (Task.isCancelled ? "cancelled_from_" : "ownership_changed_from_") + self.promptInspectionPhase
                    return
                }
                switch event {
                case .timeout: self.promptInspectionPhase = "timeout_" + self.promptInspectionPhase; return
                case .viewport(let viewport):
                    if recovered == nil {
                        wideViewportReady = Int(viewport.columns) == columns && viewport.rows == metrics.rows
                        if wideViewportReady { self.promptInspectionPhase = "waiting_exact_wide_draft" }
                    } else {
                        originalViewportReady = viewport.columns == metrics.columns && viewport.rows == metrics.rows
                        if originalViewportReady { self.promptInspectionPhase = "waiting_restored_draft_mapping" }
                    }
                case .editorRestoration(let restoration):
                    switch restoration {
                    case .invalidated: self.promptInspectionPhase = "editor_restoration_invalidated"; return
                    case .armed: break
                    case .parsedFrame(let revision): editorRestoredRevision = revision
                    case .hostFrame: break
                    }
                case .paint, .parsedHostOutput, .inputLeaseChanged: break
                }
                if editorBarrier != nil, editorRestoredRevision == nil { continue }
                self.synchronizeAndRedraw()
                if let mutation {
                    let providerFrameReady = nativeFallbackRevision.map {
                        session.parsedHostOutputRevision > $0
                    } ?? (editorRestoredRevision != nil)
                    guard originalViewportReady, providerFrameReady,
                          self.parsedGridHasColumns(Int(metrics.columns)),
                          let geometry = self.activeCursorGeometry(),
                          let painted = self.captureProviderPromptFrame(geometry: geometry),
                          let actual = RelayProviderPromptRowMatch.map(draft: mutation.target.characters, frame: painted) else { continue }
                    let revision = session.parsedHostOutputRevision
                    if let movedAt = mutationCaretRevision, revision <= movedAt { continue }
                    guard owner.promptInspectionControlLease(inputLease) == originalControlLease else { continue }
                    if actual.cursor != mutation.target.cursor {
                        // Send at most once, using the target readback rather than
                        // the pre-commit mirror to count translated cursor units.
                        guard mutationCaretRevision == nil, stillOwnsPrompt(),
                              self.sendPromptControl(movementOffset: mutation.target.cursor - actual.cursor,
                                snapshotOverride: .init(characters: mutation.target.characters, cursor: actual.cursor),
                                expectedControlLease: originalControlLease) else { return }
                        mutationCaretRevision = revision
                        continue
                    }
                    let observed = await owner.readPromptOwnerBinding()
                    guard stillOwnsPrompt(), observed == binding,
                          session.parsedHostOutputRevision == revision,
                          owner.promptInspectionControlLease(inputLease) == originalControlLease else { continue }
                    self.clearPromptSelection()
                    // Bind the graph to the owner verified with this completion,
                    // rather than a later asynchronous query of a new process.
                    self.promptOwnerTask?.cancel()
                    self.promptOwnerTask = nil
                    self.promptOwnerTaskID = nil
                    self.promptOwnerBinding = observed
                    self.promptBuffer.restore(mutation.target)
                    mutation.publish()
                    self.hasLocalInputSincePromptBoundary = !mutation.target.characters.isEmpty
                    owner.userEnteredInput()
                    self.promptInspectionRequiresRecovery = false
                    self.promptInspectionPreservesInput = false
                    self.preservedPromptInputIdentity = nil
                    self.promptInspectionVisualCopy = nil
                    restored = true
                    self.promptInspectionPhase = nativeFallbackRevision == nil
                        ? "mutation_verified" : "mutation_native_fallback_verified"
                    self.toolTip = nil
                    self.promptInspectionEvents = nil
                    self.promptInspectionTask = nil
                    self.promptInspectionTaskID = nil
                    let queued = self.deferredPromptInput
                    self.deferredPromptInput.removeAll()
                    releaseInputLease()
                    for action in queued { self.replayDeferredPromptInput(action) }
                    return
                }
                if recovered == nil {
                    guard wideViewportReady else { continue }
                    guard self.parsedGridHasColumns(columns) else {
                        self.promptInspectionPhase = "waiting_wide_parser_grid"; continue
                    }
                    self.promptInspectionPhase = "waiting_exact_wide_draft"
                    guard let snapshot = self.exactSingleRowInspectionSnapshot() else { continue }
                    guard let original = RelayProviderPromptRowMatch.map(draft: snapshot.characters, frame: originalPromptFrame),
                          original.cursor == snapshot.cursor else {
                        self.promptInspectionDraftState = "original_caret_unavailable"
                        continue
                    }
                    recovered = snapshot
                    self.promptInspectionPhase = "waiting_original_viewport"
                    self.restoreViewportAfterInspection()
                } else if originalViewportReady, let snapshot = recovered {
                    guard self.parsedGridHasColumns(Int(metrics.columns)) else {
                        self.promptInspectionPhase = "waiting_original_parser_grid"; continue
                    }
                    let restoredRevision = session.parsedHostOutputRevision
                    if let editorRestoredRevision, restoredRevision < editorRestoredRevision { continue }
                    if let originalControlLease, editorBarrier != nil,
                       owner.promptInspectionControlLease(inputLease) != originalControlLease { return }
                    // The known logical draft must map back to the original
                    // painted composer before it can authorize a replacement.
                    guard let geometry = self.activeCursorGeometry(),
                          let visualOffsets = self.renderedProviderRowSelectionOffsets(
                            delta: snapshot.characters.count - snapshot.cursor,
                            anchorOffset: -snapshot.cursor, geometry: geometry,
                            snapshot: snapshot) else { continue }
                    let observed = await owner.readPromptOwnerBinding()
                    self.promptInspectionPhase = "checking_restored_owner"
                    guard stillOwnsPrompt(), observed == binding else { return }
                    // Kernel verification crosses an await. Its result cannot
                    // authorize a draft/caret read from an earlier native frame.
                    guard session.parsedHostOutputRevision == restoredRevision else {
                        self.promptInspectionPhase = "waiting_original_draft"
                        continue
                    }
                    // Build the renderer selection from the verified frame before
                    // publishing the draft or releasing any queued keyboard input.
                    selectionAttempted = true
                    guard self.beginKeyboardPromptSelection(
                        delta: snapshot.characters.count - snapshot.cursor,
                        anchorOffset: -snapshot.cursor, visualOffsets: visualOffsets),
                          stillOwnsPrompt(),
                          session.parsedHostOutputRevision == restoredRevision else {
                        self.clearPromptSelection()
                        self.promptInspectionPhase = "selection_unavailable"
                        return
                    }
                    self.finishViewportInspection(); inspecting = false
                    self.resetPromptHistory()
                    self.promptBuffer.restore(snapshot)
                    self.refreshPromptHistoryIdentity()
                    self.promptSelection = PromptSelection(
                        characterCount: snapshot.characters.count,
                        movementOffset: snapshot.characters.count - snapshot.cursor)
                    self.keyboardSelectionIsVisual = true
                    self.promptInspectionRequiresRecovery = false
                    self.promptInspectionPreservesInput = false
                    self.preservedPromptInputIdentity = nil
                    self.promptInspectionVisualCopy = nil
                    restored = true
                    self.promptInspectionPhase = "selected"
                    self.toolTip = nil
                    self.promptInspectionEvents = nil
                    self.promptInspectionTask = nil
                    self.promptInspectionTaskID = nil
                    let queued = self.deferredPromptInput
                    self.deferredPromptInput.removeAll()
                    owner.recordInputDiagnostic("prompt-inspection-selected", details: [
                        "characters": String(snapshot.characters.count), "queued_actions": String(queued.count)])
                    releaseInputLease()
                    for action in queued { self.replayDeferredPromptInput(action) }
                    return
                }
            }
        }
        return true
    }

    private func exactSingleRowInspectionSnapshot() -> TerminalPromptBuffer.Snapshot? {
        guard let geometry = activeCursorGeometry() else { promptInspectionDraftState = "geometry_unavailable"; return nil }
        let row = Int(floor((geometry.point.y - geometry.cellSize.height - geometry.gridOrigin.y) / geometry.cellSize.height))
        let column = Int(floor((geometry.origin.x - geometry.gridOrigin.x) / geometry.cellSize.width))
        let position = "row=\(row),column=\(column),columns=\(geometry.columns):"
        promptInspectionDraftState = position + "caret_range"
        guard row >= 0, column > 0, column < geometry.columns - 1 else { return nil }
        promptInspectionDraftState = position + "row_unavailable"
        guard let line = readViewportRow(row, columns: geometry.columns) else { return nil }
        promptInspectionDraftState = position + "prefix_unavailable"
        guard let prefix = TerminalPromptSelectionEdit.inputPrefixLength(line, shell: false) else { return nil }
        promptInspectionDraftState = position + "caret_text_unavailable"
        guard let before = readViewportBeforeCaret(startRow: row, caretRow: row,
            caretColumn: column, columns: geometry.columns) else { return nil }
        promptInspectionDraftState = position + "line_break"
        guard !line.contains("\n"), !line.contains("\r") else { return nil }
        promptInspectionDraftState = position + "caret_prefix_mismatch"
        guard line.hasPrefix(before), before.count > prefix else { return nil }
        promptInspectionDraftState = position + "text_after_caret"
        guard line.dropFirst(before.count).allSatisfy({ $0 == " " }) else { return nil }
        let draft = Array(before.dropFirst(prefix))
        promptInspectionDraftState = position + "draft_range_or_control_character"
        guard !draft.isEmpty, draft.count <= 4_096,
              draft.allSatisfy({ $0.unicodeScalars.allSatisfy { $0.value >= 32 && $0.value != 127 } }) else { return nil }
        promptInspectionDraftState = position + "captured"
        return .init(characters: draft, cursor: draft.count)
    }

    private func replayDeferredPromptInput(_ action: DeferredPromptInput) {
        if promptInspectionPreservesInput {
            deferredPromptInput.append(action)
            return
        }
        switch action {
        case .key(let event):
            replayingDeferredPromptKey = true
            defer { replayingDeferredPromptKey = false }
            keyDown(with: event)
        case .text(let text, let range):
            replayingDeferredPromptText = true
            defer { replayingDeferredPromptText = false }
            insertText(text, replacementRange: range)
        case .clipboard(let action): _ = handleApplicationClipboardAction(action)
        case .paste(let text, let files):
            if !files.isEmpty, owner?.importLocalFiles(files) == true {
                invalidatePromptMirror()
            } else if let text, !text.isEmpty {
                // Mode negotiation can change during the resize transaction.
                // Never fall through to a live-pasteboard read for a captured
                // multiline paste whose safe framing is no longer available.
                guard TerminalPastePayload.rendererPayload(for: text,
                    bracketed: owner?.bracketedPasteIsActive == true) != nil else {
                    if !pasteCapturedText(text) {
                        preserveDeferredPromptInput(action, message: "Your paste is preserved; try Select All again.")
                    }
                    return
                }
                _ = pastePromptText(text)
            } else if !files.isEmpty {
                preserveDeferredPromptInput(action, message: "Your file paste is preserved; try Select All again when the upload is available.")
            }
        case .history(let redo): _ = performPromptHistoryAction(redo: redo)
        case .deleteSelection(let expected, let selection):
            guard promptBuffer.snapshot == expected, promptSelection == selection else {
                promptInspectionRequiresRecovery = true
                preserveDeferredPromptInput(action, message: "The original deletion is preserved; its draft and selection could not be verified.")
                return
            }
            guard deleteCurrentPromptSelection() else {
                // Nothing was dispatched, but applyPromptEdit may have
                // invalidated the mirror and set recovery. Keep this original
                // action (its snapshot and selection predate invalidation)
                // behind a visible hold. Replay runs with no hold and an empty
                // queue, so this lands first; later queued items re-queue
                // behind it in order, and it is preserved once.
                promptInspectionRequiresRecovery = true
                preserveDeferredPromptInput(action, message: "The original deletion is preserved; it could not be dispatched.")
                return
            }
        case .marked(let text, let selected, let replacement):
            setMarkedText(text, selectedRange: selected, replacementRange: replacement)
        case .unmark: unmarkText()
        case .command(let selector): doCommand(by: selector)
        }
    }

    private func preserveDeferredPromptInput(_ action: DeferredPromptInput, message: String, atFront: Bool = false,
                                             line: Int = #line) {
        if atFront { deferredPromptInput.insert(action, at: 0) }
        else { deferredPromptInput.append(action) }
        promptInspectionPreservesInput = true
        preservedPromptInputIdentity = owner?.promptInspectionIdentity
        toolTip = message
        // Metadata only: the call site's line and the hold's state, never text.
        owner?.recordInputDiagnostic("prompt-inspection-input-preserved", details: [
            "queued_actions": String(deferredPromptInput.count),
            "reason": promptInspectionRequiresRecovery ? "recovery_required" : "held",
            "inspection_active": String(promptInspectionTask != nil),
            "line": String(line)])
    }

    private func recordInsertTextRoute(_ route: String) {
        owner?.recordInputDiagnostic("insert-text-route", details: ["reason": route,
            "queued_actions": String(deferredPromptInput.count),
            "inspection_active": String(promptInspectionTask != nil)])
    }

    private var recoveredPreservedText = ""

    /// A completed read-only check, or the user's explicit Escape/Control-C,
    /// must not keep the native keyboard captive. Captured text is appended to
    /// the retained copy (never overwriting earlier retained text), stays
    /// available for copying, and is never replayed. Only Discard clears it.
    private func resumeNativeTypingPreservingText(reason: String = "completed-readonly-check") {
        let text = preservedCommittedPromptText
        recoveredPreservedText = text
        deferredPromptInput.removeAll()
        promptInspectionRequiresRecovery = false
        promptInspectionPreservesInput = false
        preservedPromptInputIdentity = nil
        promptInspectionVisualCopy = nil
        clearPromptSelection()
        invalidatePromptMirror()
        owner?.recordInputDiagnostic("input-resumed", details: ["reason": reason])
    }

    private var preservedCommittedPromptText: String {
        recoveredPreservedText + deferredPromptInput.compactMap { action -> String? in
            switch action {
            case .text(let value, _):
                return (value as? NSAttributedString)?.string ?? (value as? String)
            case .paste(let text, _): return text
            case .key(let event):
                guard event.modifierFlags.intersection([.command, .control]).isEmpty,
                      let text = event.characters,
                      text.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 }) else { return nil }
                return text
            default: return nil
            }
        }.joined()
    }

    private var preservedPromptFiles: [URL] {
        deferredPromptInput.flatMap { action -> [URL] in
            if case .paste(_, let files) = action { return files }
            return []
        }
    }

    @discardableResult
    func copyPreservedPromptText() -> Bool {
        guard promptInspectionTask == nil, nativePasteConfirmation == nil,
              !preservedCommittedPromptText.isEmpty else { return false }
        return writeCopiedText(preservedCommittedPromptText, source: "preserved-input")
    }

    private func cancelPromptInspectionForNativeInput() {
        let hadInspection = promptInspectionTask != nil
        promptInspectionTaskID = nil
        promptInspectionEvents?.finish()
        promptInspectionEvents = nil
        promptInspectionTask?.cancel()
        promptInspectionTask = nil
        promptInspectionInputRelease?.release()
        promptInspectionInputRelease = nil
        if hadInspection {
            restoreViewportAfterInspection()
            finishViewportInspection()
        }
        // Cancelling the check never discards captured input; only the pane
        // menu's Discard Preserved Input does. Retained files keep the whole
        // hold, which the notice and menu make recoverable.
        if !preservedPromptFiles.isEmpty {
            owner?.recordInputDiagnostic("input-hold-kept", details: ["reason": "files",
                "queued_actions": String(deferredPromptInput.count)])
            owner?.notePreservedTyping(inspectionActive: false, files: true)
        } else {
            resumeNativeTypingPreservingText(reason: "native_cancel")
            super.unmarkText()
            toolTip = nil
            owner?.clearPreservedTypingNotice()
        }
        promptInspectionPhase = "cancelled_by_native_input"
        owner?.reclaimNativeViewportOwnership()
    }

    @discardableResult
    func discardPreservedPromptInput() -> Bool {
        guard promptInspectionTask == nil, nativePasteConfirmation == nil else { return false }
        deferredPromptInput.removeAll()
        recoveredPreservedText = ""
        promptInspectionRequiresRecovery = false
        promptInspectionPreservesInput = false
        preservedPromptInputIdentity = nil
        promptInspectionVisualCopy = nil
        clearPromptSelection()
        invalidatePromptMirror()
        super.unmarkText()
        toolTip = nil
        owner?.recordInputDiagnostic("prompt-inspection-preserved-input-discarded")
        return true
    }

    func waitForPendingPromptInspection() async {
        await promptInspectionTask?.value
    }

    func beginNativePasteConfirmation() -> UUID? {
        guard nativePasteConfirmation == nil else { return nil }
        let id = UUID()
        nativePasteConfirmation = .init(id: id, identity: owner?.promptInspectionIdentity,
            snapshot: promptBuffer.snapshot, selection: promptSelection,
            generation: promptHistoryGeneration, window: window?.windowNumber, frame: frame)
        promptInspectionPreservesInput = true
        preservedPromptInputIdentity = owner?.promptInspectionIdentity
        return id
    }

    func finishNativePasteConfirmation(_ id: UUID, request: TerminalClipboardConfirmationRequest,
        allow: Bool, ownerIsValid: Bool) {
        guard let pending = nativePasteConfirmation, pending.id == id else {
            request.respond(allow: false); return
        }
        var valid = ownerIsValid && owner?.promptInspectionIdentity == pending.identity &&
            promptBuffer.snapshot == pending.snapshot && promptSelection == pending.selection &&
            promptHistoryGeneration == pending.generation && window?.windowNumber == pending.window && frame == pending.frame && selectedPromptDeletionIsAvailable
        var consumedSelectionPaste = false
        if allow && valid {
            if let selection = promptSelection {
                request.respond(allow: false)
                consumedSelectionPaste = true
                valid = applyPromptEdit(selection, recordHistory: true, historyKind: .paste, followingText: request.contents)
                if valid { clearPromptSelection() }
            } else {
                recordPromptEdit(.paste)
            }
            if valid {
                if case .inMemory(let session) = configuration.backend {
                    promptMirrorAwaitingHostOutput = (session, session.parsedHostOutputRevision)
                }
                // Confirmed unbracketed paste may submit lines, so it cannot
                // establish an editable multiline mirror.
                invalidatePromptMirror()
                hasLocalInputSincePromptBoundary = true
                owner?.userEnteredInput()
            }
        }
        if !consumedSelectionPaste { request.respond(allow: allow && valid) }
        nativePasteConfirmation = nil
        if allow && !valid {
            // Approval cannot authorize a changed owner, draft, or selection.
            // Retain the captured paste rather than dropping it or sending it.
            promptInspectionRequiresRecovery = true
            preserveDeferredPromptInput(.paste(text: request.contents, files: []),
                message: "The approved paste could not be applied to the original draft. Input is preserved for recovery.", atFront: true)
            preservedPromptInputIdentity = pending.identity
            return
        }
        if valid || deferredPromptInput.isEmpty {
            promptInspectionPreservesInput = false
            preservedPromptInputIdentity = nil
            promptInspectionVisualCopy = nil
        }
        guard valid else { return }
        let queued = deferredPromptInput
        deferredPromptInput.removeAll()
        for action in queued { replayDeferredPromptInput(action) }
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if localSelectAllNeedsExactText { beginDeferredSelectAllInspection() }
        if promptInspectionPreservesInput {
            deferredPromptInput.append(.marked(preservedPromptText(string), selectedRange, replacementRange))
            return
        }
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    }

    override func unmarkText() {
        if promptInspectionPreservesInput { deferredPromptInput.append(.unmark); return }
        super.unmarkText()
    }

    override func doCommand(by selector: Selector) {
        if promptInspectionPreservesInput && !translatingPromptControlKey {
            consumeCurrentTextInputEvent()
            deferredPromptInput.append(.command(selector))
            return
        }
        super.doCommand(by: selector)
    }

    private func handleKeyboardPromptSelection(_ event: NSEvent) -> Bool {
        // Agent detection is asynchronous after an attach. Local input is
        // sufficient evidence that this terminal currently owns an editable
        // prompt, so Shift-arrow selection must not depend on the sidebar
        // having already relabeled the pane from Shell to Codex/Claude.
        guard owner?.allowsPromptSelectionEditing == true,
              (promptEditingIsSemanticallyActive || hasLocalInputSincePromptBoundary),
              event.modifierFlags.contains(.shift),
              !event.modifierFlags.contains(.control),
              event.keyCode == 123 || event.keyCode == 124
        else { return false }

        let usesCommand = event.modifierFlags.contains(.command)
        let usesOption = event.modifierFlags.contains(.option)
        guard !(usesCommand && usesOption) else { return false }
        let direction = event.keyCode == 123 ? -1 : 1
        let granularity: TerminalPromptBuffer.NavigationGranularity = if usesCommand {
            .line
        } else if usesOption {
            .word
        } else {
            .character
        }
        promptHistory.breakCoalescing()
        let current = keyboardSelectionOffset ?? 0
        let next: Int
        if let resolved = promptBuffer.navigationOffset(
            from: current,
            direction: direction,
            granularity: granularity
        ) {
            next = resolved
        } else if granularity == .character {
            // A restored session may not have a complete local prompt mirror.
            // Character selection is still safe because it never guesses a
            // semantic boundary; word/line selection remains conservative.
            next = current + direction
        } else {
            return false
        }
        if next == 0 {
            clearPromptSelection()
            return true
        }

        keyboardSelectionOffset = next
        // The logical selection is authoritative. Ghostty's cursor rectangle
        // can be temporarily unavailable while a TUI repaints, so visual
        // highlighting is best-effort but Shift-arrow deletion still works.
        keyboardSelectionIsVisual = beginKeyboardPromptSelection(delta: next)
        promptSelection = PromptSelection(
            characterCount: abs(next),
            movementOffset: next > 0 ? next : 0
        )
        return true
    }

    private func handleKeyboardPromptNavigation(_ event: NSEvent) -> Bool {
        guard owner?.allowsPromptSelectionEditing == true,
              promptEditingIsSemanticallyActive || hasLocalInputSincePromptBoundary,
              !event.modifierFlags.contains(.shift),
              !event.modifierFlags.contains(.control),
              event.keyCode == 123 || event.keyCode == 124
        else { return false }

        let usesCommand = event.modifierFlags.contains(.command)
        let usesOption = event.modifierFlags.contains(.option)
        guard !(usesCommand && usesOption) else { return false }
        let direction = event.keyCode == 123 ? -1 : 1
        let granularity: TerminalPromptBuffer.NavigationGranularity = usesCommand ? .line : (usesOption ? .word : .character)
        guard let movementOffset = promptBuffer.navigationOffset(
            direction: direction,
            granularity: granularity
        ) else { return false }

        promptHistory.breakCoalescing()
        clearPromptSelection()
        if movementOffset != 0 {
            guard sendPromptControl(movementOffset: movementOffset) else {
                // A refused controlled move dispatched nothing: admission is
                // all-or-nothing (the remote transport refuses while earlier
                // input awaits acknowledgement, or without a lease). Nothing
                // is uncertain, so do not pause typing. The mirror no longer
                // knows the caret; this key continues on the ordinary ordered
                // native path like any other key. No held input is replayed.
                invalidatePromptMirror()
                owner?.recordInputDiagnostic("prompt-cursor-native-fallback", details: [
                    "reason": "control_refused", "queued_actions": String(deferredPromptInput.count)])
                return false
            }
            promptBuffer.move(by: movementOffset)
        }
        return true
    }

    /// Resolve logical character boundaries through the renderer's text reads.
    /// A wide glyph can occupy several cells while remaining one Character;
    /// the last matching prefix boundary ends after its continuation cells.
    private func renderedPromptSelectionOffsets(
        delta: Int, anchorOffset: Int, geometry: CursorGeometry
    ) -> (start: Int, end: Int)? {
        guard let snapshot = promptBuffer.snapshot else { return nil }
        let targets = [snapshot.cursor + anchorOffset, snapshot.cursor + delta]
        guard targets.allSatisfy({ $0 >= 0 && $0 <= snapshot.characters.count }) else { return nil }
        let columns = geometry.columns
        let row = Int(floor((geometry.point.y - geometry.cellSize.height - geometry.gridOrigin.y) /
                            geometry.cellSize.height))
        let column = Int(floor((geometry.origin.x - geometry.gridOrigin.x) / geometry.cellSize.width))
        guard row >= 0, columns > 0, column >= 0, column < columns else { return nil }
        let caretCell = row * columns + column
        // Rightward selection also needs renderer boundaries after the caret.
        // Limit reads to the visible grid and the existing 4096-cell budget;
        // exact prefix equality below proves the selected text at each endpoint.
        let visibleRows = Int(floor((bounds.height - geometry.gridOrigin.y) / geometry.cellSize.height))
        let lastVisibleCell = max(caretCell, visibleRows * columns - 1)
        let forwardLimit = min(lastVisibleCell, caretCell + 4_096)
        let draftPrefix = String(snapshot.characters.prefix(snapshot.cursor))
        let firstPossibleRow = max(0, row - min(32, 4_096 / columns + 1))
        for firstRow in stride(from: row, through: firstPossibleRow, by: -1) {
            guard let line = readViewportRow(firstRow, columns: columns),
                  let prefixCount = TerminalPromptSelectionEdit.inputPrefixLength(line, shell: semanticShellPromptActive),
                  let rendered = readViewportBeforeCaret(startRow: firstRow, caretRow: row,
                                                        caretColumn: column, columns: columns) else { continue }
            let prefix = String(line.prefix(prefixCount))
            guard rendered == prefix + draftPrefix else { continue }
            var offsets: [Int] = []
            for target in targets {
                if target == snapshot.cursor { offsets.append(0); continue }
                let expected = prefix + String(snapshot.characters.prefix(target))
                var low = firstRow * columns
                var high = target > snapshot.cursor ? forwardLimit : caretCell
                var boundary: Int?
                // Prefix character count is monotone across the proven rendered
                // range, including soft wraps and wide glyph continuation cells.
                while low <= high {
                    let middle = low + (high - low) / 2
                    guard let text = readViewportBeforeCaret(startRow: firstRow,
                        caretRow: middle / columns, caretColumn: middle % columns,
                        columns: columns) else { return nil }
                    if text.count <= expected.count {
                        if text == expected { boundary = middle }
                        low = middle + 1
                    } else {
                        high = middle - 1
                    }
                }
                guard let boundary else { return nil }
                offsets.append(boundary - caretCell)
            }
            return (offsets[0], offsets[1])
        }
        return nil
    }

    /// Provider composers wrap words into separately painted, indented rows.
    /// Match every visible row against the reliable logical draft, then resolve
    /// boundaries inside each row through Ghostty rather than counting cells.
    private func renderedProviderRowSelectionOffsets(
        delta: Int, anchorOffset: Int, geometry: CursorGeometry,
        snapshot suppliedSnapshot: TerminalPromptBuffer.Snapshot? = nil
    ) -> (start: Int, end: Int)? {
        guard owner?.forcesLocalPromptSelection == true,
              let snapshot = suppliedSnapshot ?? promptBuffer.snapshot,
              !snapshot.characters.isEmpty, snapshot.characters.count <= 4_096,
              case .inMemory(let session) = configuration.backend else { return nil }
        let outputRevision = session.parsedHostOutputRevision
        let targets = [snapshot.cursor + anchorOffset, snapshot.cursor + delta]
        guard targets.allSatisfy({ $0 >= 0 && $0 <= snapshot.characters.count }) else { return nil }
        let columns = geometry.columns
        let caretRow = Int(floor((geometry.point.y - geometry.cellSize.height - geometry.gridOrigin.y) / geometry.cellSize.height))
        let caretColumn = Int(floor((geometry.origin.x - geometry.gridOrigin.x) / geometry.cellSize.width))
        guard columns > 0, caretRow >= 0, caretColumn >= 0, caretColumn < columns else { return nil }
        guard let captured = captureProviderPromptFrame(geometry: geometry),
              let mapped = RelayProviderPromptRowMatch.map(draft: snapshot.characters, frame: captured),
              mapped.cursor == snapshot.cursor else { return nil }
        let rows = mapped.rows
        var valid = true
        var resolved: [Int] = []
        for target in targets {
            if target == snapshot.cursor { resolved.append(0); continue }
            guard let targetRow = rows.last(where: { $0.start <= target }) else { valid = false; break }
            let within = min(target - targetRow.start, targetRow.body.count)
            let expected = targetRow.prefix + String(targetRow.body.prefix(within))
            var low = 0
            var high = columns - 1
            var boundary: Int?
            while low <= high {
                let middle = low + (high - low) / 2
                guard let text = readViewportBeforeCaret(startRow: targetRow.row, caretRow: targetRow.row,
                                                        caretColumn: middle, columns: columns) else { valid = false; break }
                if text.count <= expected.count {
                    if text == expected { boundary = middle }
                    low = middle + 1
                } else { high = middle - 1 }
            }
            guard valid, let boundary else { valid = false; break }
            resolved.append((targetRow.row - caretRow) * columns + boundary - caretColumn)
        }
        if valid, resolved.count == 2, session.parsedHostOutputRevision == outputRevision {
            return (resolved[0], resolved[1])
        }
        return nil
    }

    /// Capture the original renderer before any viewport or editor operation.
    /// A parsed-output change during the reads invalidates the whole frame.
    private func captureProviderPromptFrame(geometry: CursorGeometry) -> RelayProviderPromptRowMatch.Frame? {
        guard case .inMemory(let session) = configuration.backend else { return nil }
        let revision = session.parsedHostOutputRevision
        let columns = geometry.columns
        let caretRow = Int(floor((geometry.point.y - geometry.cellSize.height - geometry.gridOrigin.y) / geometry.cellSize.height))
        let caretColumn = Int(floor((geometry.origin.x - geometry.gridOrigin.x) / geometry.cellSize.width))
        let visibleRows = Int(floor((bounds.height - geometry.gridOrigin.y) / geometry.cellSize.height))
        guard columns > 0, caretRow >= 0, caretRow < visibleRows,
              caretColumn >= 0, caretColumn < columns,
              let before = readViewportBeforeCaret(startRow: caretRow, caretRow: caretRow,
                caretColumn: caretColumn, columns: columns) else { return nil }
        let earliest = max(0, caretRow - 32)
        var lines: [Int: String] = [:]
        for row in earliest..<min(visibleRows, caretRow + 33) {
            guard let line = readViewportRow(row, columns: columns) else { return nil }
            lines[row] = line
        }
        var candidates: [[RelayProviderPromptRowMatch.PaintedRow]] = []
        for firstRow in stride(from: caretRow, through: earliest, by: -1) {
            guard let first = lines[firstRow],
                  let prefixCount = TerminalPromptSelectionEdit.inputPrefixLength(first, shell: false) else { continue }
            var rows: [RelayProviderPromptRowMatch.PaintedRow] = []
            for row in firstRow..<min(visibleRows, firstRow + 33) {
                guard let line = lines[row] else { break }
                let prefix = row == firstRow ? String(line.prefix(prefixCount)) : String(repeating: " ", count: prefixCount)
                guard line.hasPrefix(prefix) else { break }
                rows.append(.init(row: row, prefix: prefix, rendered: Array(line.dropFirst(prefix.count))))
            }
            candidates.append(rows)
        }
        guard session.parsedHostOutputRevision == revision else { return nil }
        return .init(caretRow: caretRow, caretColumn: caretColumn, columns: columns,
            beforeCaret: before, candidates: candidates)
    }

    private func beginKeyboardPromptSelection(
        delta: Int, anchorOffset: Int = 0, visualOffsets: (start: Int, end: Int)? = nil
    ) -> Bool {
        guard delta != anchorOffset, abs(delta) <= 4_096, abs(anchorOffset) <= 4_096,
              let window,
              let geometry = activeCursorGeometry(),
              parsedGridHasColumns(geometry.columns)
        else { return false }

        // `ghostty_surface_ime_point` identifies the insertion boundary below
        // the row that Ghostty's pointer hit-testing uses for the live text.
        // AppTerminalView's NSTextInputClient rectangle preserves that IME
        // convention, so keyboard selection must move the visual anchor up by
        // one cell before synthesizing the native renderer drag.
        let reportedSelectionCursor = CGPoint(
            x: geometry.point.x,
            y: geometry.point.y - geometry.cellSize.height
        )
        let gridOriginX = geometry.gridOrigin.x
        guard let cursorAnchor = TerminalKeyboardSelectionGeometry.anchor(
            for: reportedSelectionCursor,
            cellSize: geometry.cellSize,
            columns: geometry.columns,
            gridOriginX: gridOriginX
        ) else { return false }
        let resolvedOffsets = visualOffsets ?? renderedPromptSelectionOffsets(
            delta: delta, anchorOffset: anchorOffset, geometry: geometry
        ) ?? renderedProviderRowSelectionOffsets(
            delta: delta, anchorOffset: anchorOffset, geometry: geometry
        )
        let asciiMirror = promptBuffer.snapshot?.characters.allSatisfy {
            $0.unicodeScalars.count == 1 && $0.unicodeScalars.first!.value >= 32 &&
                $0.unicodeScalars.first!.value < 127
        } == true
        guard resolvedOffsets != nil || asciiMirror else { return false }
        guard let selectionCursor = TerminalKeyboardSelectionGeometry.endpoint(
            from: cursorAnchor,
            visualCellDelta: resolvedOffsets?.start ?? anchorOffset,
            cellSize: geometry.cellSize,
            columns: geometry.columns,
            gridOriginX: gridOriginX
        ), let selectionEnd = TerminalKeyboardSelectionGeometry.endpoint(
            from: cursorAnchor,
            visualCellDelta: resolvedOffsets?.end ?? delta,
            cellSize: geometry.cellSize,
            columns: geometry.columns,
            gridOriginX: gridOriginX
        ) else { return false }
        guard selectionCursor.y >= 0, selectionCursor.y <= bounds.height,
              selectionEnd.y >= 0, selectionEnd.y <= bounds.height
        else { return false }
        let insertionBoundaryOffset = geometry.cellSize.width / 2
        let startLocal = CGPoint(
            // Ghostty's selection endpoints are text insertion boundaries,
            // while `selectionCursor` is the center used for cell lookup.
            x: selectionCursor.x - insertionBoundaryOffset,
            y: bounds.height - selectionCursor.y
        )
        let endLocal = CGPoint(
            x: selectionEnd.x - insertionBoundaryOffset,
            y: bounds.height - selectionEnd.y
        )
        let start = convert(startLocal, to: nil)
        let end = convert(endLocal, to: nil)
        let timestamp = ProcessInfo.processInfo.systemUptime
        guard let down = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: start,
            // Rebuild the complete visual range from the fixed keyboard
            // anchor on every arrow event. Shift would ask Ghostty to extend
            // its previous pointer selection a second time.
            modifierFlags: [],
            timestamp: timestamp,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ), let drag = NSEvent.mouseEvent(
            with: .leftMouseDragged,
            location: end,
            modifierFlags: [],
            timestamp: timestamp,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ), let up = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: end,
            modifierFlags: [],
            timestamp: timestamp,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0
        ) else { return false }
        super.mouseDown(with: down)
        super.mouseDragged(with: drag)
        super.mouseUp(with: up)
        return true
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        localFileURLs(from: sender.draggingPasteboard).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        importFiles(from: sender.draggingPasteboard)
    }

    override func mouseMoved(with event: NSEvent) {
        // A crashed TUI can leave mode 1003 enabled in the terminal. Once
        // OSC 133 proves that the shell owns input again, hover is local;
        // otherwise every pointer move becomes garbage in the shell draft.
        if semanticShellPromptActive, applicationIsCapturingMouse {
            restoreShellMouseReporting()
            return
        }
        super.mouseMoved(with: event)
        // Ghostty intentionally discovers hover links only with Command held.
        // Probe the same cell with Command for Relay's single-click image UX;
        // regular terminal mouse delivery above remains unchanged.
        guard !event.modifierFlags.contains(.command),
              let probe = NSEvent.mouseEvent(
                with: event.type,
                location: event.locationInWindow,
                modifierFlags: event.modifierFlags.union(.command),
                timestamp: event.timestamp,
                windowNumber: event.windowNumber,
                context: nil,
                eventNumber: event.eventNumber,
                clickCount: event.clickCount,
                pressure: event.pressure
              ) else { return }
        super.mouseMoved(with: probe)
    }

    private func terminalPoint(for event: NSEvent) -> CGPoint {
        let point = convert(
            selectionAdjustedWindowLocation(event.locationInWindow),
            from: nil
        )
        return CGPoint(x: point.x, y: bounds.height - point.y)
    }

    private func selectionAdjustedWindowLocation(_ locationInWindow: CGPoint) -> CGPoint {
        guard let window,
              let surfaceSizePixels = owner?.terminalRenderedSurfaceSizePixels()
        else { return locationInWindow }
        let local = convert(locationInWindow, from: nil)
        let remapped = TerminalPointerGeometry.remappedPoint(
            local,
            visibleSize: bounds.size,
            surfaceSizePixels: surfaceSizePixels,
            backingScaleFactor: window.backingScaleFactor
        )
        return convert(remapped, to: nil)
    }

    private func selectionIsNearActivePrompt(start: CGPoint, end: CGPoint) -> Bool {
        if let cursorY = activeCursorGeometry()?.point.y {
            return TerminalPromptSelectionEdit.selectionIsNearCursor(
                startY: start.y,
                endY: end.y,
                cursorY: cursorY,
                viewportHeight: bounds.height,
                agentPrompt: owner?.forcesLocalPromptSelection == true
            )
        }

        // A surface can briefly lack an IME rectangle during attachment.
        // Retain the conservative bottom-only fallback for that short window.
        let promptBand = min(96, max(48, bounds.height * 0.2))
        let top = bounds.height - promptBand
        return start.y >= top && end.y >= top
    }

    private struct CursorGeometry {
        let origin: CGPoint
        let point: CGPoint
        let gridOrigin: CGPoint
        let cellSize: CGSize
        let columns: Int
    }

    private func activeCursorGeometry() -> CursorGeometry? {
        guard let window else { return nil }
        let screenRect = firstRect(
            forCharacterRange: NSRange(location: NSNotFound, length: 0),
            actualRange: nil
        )
        guard screenRect != .zero,
              screenRect.origin.x.isFinite, screenRect.origin.y.isFinite,
              screenRect.size.width.isFinite, screenRect.size.height.isFinite
        else { return nil }
        let windowRect = window.convertFromScreen(screenRect)
        let localRect = convert(windowRect, from: nil)
        let liveMetrics = currentGridMetrics()
        let exactGrid: (cellSize: CGSize, columns: Int)?
        if let metrics = liveMetrics, metrics.cellWidthPixels > 0, metrics.cellHeightPixels > 0,
           let parsedColumns = parsedGridColumnCount() {
            exactGrid = (CGSize(width: CGFloat(metrics.cellWidthPixels) / window.backingScaleFactor,
                                height: CGFloat(metrics.cellHeightPixels) / window.backingScaleFactor), parsedColumns)
        } else {
            exactGrid = owner?.terminalGridGeometry(backingScaleFactor: window.backingScaleFactor)
        }
        let fallback = fallbackCellSize()
        // A bar cursor can legitimately expose a zero-width IME rectangle.
        // The origin is still authoritative; use the configured monospace
        // metrics only for missing dimensions.
        let cellSize = CGSize(
            width: exactGrid?.cellSize.width ?? (localRect.width >= 2 ? localRect.width : fallback.width),
            height: exactGrid?.cellSize.height ?? (localRect.height >= 2 ? localRect.height : fallback.height)
        )
        let cursorTop = bounds.height - localRect.maxY
        let origin = CGPoint(x: localRect.minX, y: cursorTop)
        let point = CGPoint(
            x: origin.x + cellSize.width / 2,
            y: origin.y + cellSize.height / 2
        )
        guard point.x.isFinite, point.y.isFinite,
              point.x >= 0, point.x <= (promptInspectionTask == nil ? bounds.width :
                  max(bounds.width, CGFloat(liveMetrics?.columns ?? 0) * cellSize.width)),
              point.y >= 0, point.y <= bounds.height,
              cellSize.width > 0, cellSize.height > 0
        else { return nil }
        let columns = exactGrid?.columns ?? max(1, Int(floor(bounds.width / cellSize.width)))
        return CursorGeometry(
            origin: origin,
            point: point,
            gridOrigin: CGPoint(
                x: CGFloat(Int(min(max(RelayPreferences.shared.terminalPadding.rounded(), 0), 32))),
                y: CGFloat(Int(min(max(RelayPreferences.shared.terminalPadding.rounded(), 0), 32)))
            ),
            cellSize: cellSize,
            columns: columns
        )
    }

    private func fallbackCellSize() -> CGSize {
        let preferences = RelayPreferences.shared
        let size = CGFloat(min(max(preferences.fontSize, 9), 32))
        let font = NSFont(name: preferences.resolvedFontFamily, size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let width = max(4, ("M" as NSString).size(withAttributes: [.font: font]).width)
        let height = max(8, ceil(font.ascender - font.descender + font.leading))
        return CGSize(width: width, height: height)
    }

    private func resetPromptHistory(file: String = #fileID, line: Int = #line) {
        owner?.recordInputDiagnostic("prompt-history-reset", details: [
            "line": String(line), "suspended": String(suspendedPromptHistory != nil),
            "owner": String(promptOwnerBinding != nil), "reliable": String(promptBuffer.isReliable),
        ])
        promptHistory.reset()
        suspendedPromptHistory = nil
        promptOwnerBinding = nil
        promptHistoryGeneration &+= 1
        promptOwnerTask?.cancel()
        promptOwnerTask = nil
        promptOwnerTaskID = nil
    }

    /// Cache only an identity observed while the mirrored draft remains unchanged.
    /// After replay, restore history only after a fresh identity and exact renderer
    /// text/caret agree; this method never writes to the terminal.
    private func refreshPromptHistoryIdentity() {
        guard promptOwnerTask == nil, let expected = promptBuffer.snapshot,
              promptOwnerBinding == nil || suspendedPromptHistory != nil else { return }
        if let suspendedPromptHistory, suspendedPromptHistory.snapshot != expected {
            owner?.recordInputDiagnostic("prompt-history-snapshot-rejected", details: [
                "expected_characters": String(suspendedPromptHistory.snapshot.characters.count),
                "rendered_characters": String(expected.characters.count),
                "expected_cursor": String(suspendedPromptHistory.snapshot.cursor),
                "rendered_cursor": String(expected.cursor),
            ])
            self.suspendedPromptHistory = nil
        }
        let generation = promptHistoryGeneration
        let suspended = suspendedPromptHistory
        let taskID = UUID()
        promptOwnerTaskID = taskID
        promptOwnerTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let binding = await self.owner?.readPromptOwnerBinding()
            self.owner?.recordInputDiagnostic("prompt-history-owner-observed", details: [
                "owner": String(binding != nil), "suspended": String(suspended != nil),
                "generation_matches": String(generation == self.promptHistoryGeneration),
                "snapshot_matches": String(self.promptBuffer.snapshot == expected),
                "owner_matches": String(suspended?.binding == binding),
            ])
            guard !Task.isCancelled, self.promptOwnerTaskID == taskID else { return }
            self.promptOwnerTask = nil
            self.promptOwnerTaskID = nil
            guard generation == self.promptHistoryGeneration,
                  self.promptBuffer.snapshot == expected else {
                self.refreshPromptHistoryIdentity()
                return
            }
            self.suspendedPromptHistory = nil
            if let suspended, suspended.binding.permitsHistoryRestore(observed: binding,
                expected: suspended.snapshot, rendered: self.promptBuffer.snapshot) {
                self.promptHistory = suspended.history
                self.owner?.recordInputDiagnostic("prompt-history-reconnect-restored")
            }
            self.promptOwnerBinding = binding
        }
    }

    private func invalidatePromptMirror() {
        promptBuffer.invalidate()
        resetPromptHistory()
    }

    /// Accept and delete keys for prompt provenance. Command and Control
    /// chords are shortcuts, not input; Option-Delete still deletes.
    private func recordPromptProvenanceKey(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .control])
        guard flags.isEmpty else { return }
        let origin = RelayKeyEventOrigin.of(event)
        switch event.keyCode {
        case 48: owner?.recordPromptInput { $0.tab(origin: origin) }
        case 124: owner?.recordPromptInput { $0.rightArrow(origin: origin) }
        case 51, 117: owner?.recordPromptInput { $0.delete(origin: origin) }
        default: break
        }
    }

    /// Printable characters committed by the keyboard or an input method.
    private func recordPromptProvenanceText(_ string: Any) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        let printable = RelayPromptProvenanceLog.printableCount(text)
        // Only the key press being dispatched here; any other insert is synthesized.
        let keyPress = RelayKeyEventOrigin.keyPress(forInsertedText: promptKeyDownInFlight,
                                                    current: NSApp.currentEvent,
                                                    replaying: replayingDeferredPromptKey)
        let origin = keyPress.map(RelayKeyEventOrigin.of) ?? .synthesized
        if printable > 0 { owner?.recordPromptInput { $0.printable(printable, origin: origin) } }
    }

    /// The submitting Enter. Relay's mirror of the line, when reliable, gives
    /// the visible length; it is reduced to a fingerprint immediately.
    private func recordPromptProvenanceSubmit(_ event: NSEvent) {
        let line = promptBuffer.isReliable ? promptBuffer.text.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let visible = line.isEmpty ? nil : RelayPromptFingerprint(line)
        let origin = RelayKeyEventOrigin.of(event)
        owner?.recordPromptInput { _ = $0.userSubmit(visible: visible, origin: origin) }
    }

    private func trackNonTextKey(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let control = flags.contains(.control)
        let command = flags.contains(.command)
        let option = flags.contains(.option)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""

        if event.keyCode == 36 || event.keyCode == 76 {
            if flags.contains(.shift),
               flags.intersection([.command, .control, .option]).isEmpty {
                hasLocalInputSincePromptBoundary = true
                recordPromptEdit(.typing)
                promptBuffer.insert("\n")
                if !promptBuffer.isReliable { resetPromptHistory() }
                return
            }
            setShellPromptActive(false)
            recordPromptProvenanceSubmit(event)
            _ = promptBuffer.submit()
            resetPromptHistory()
            hasLocalInputSincePromptBoundary = false
            return
        }
        if event.keyCode == 48 {
            invalidatePromptMirror()
            return
        }
        if command && key == "v" {
            if let pasted = NSPasteboard.general.string(forType: .string) {
                owner?.recordPromptInput {
                    $0.paste(bytes: pasted.utf8.count, event: event.timestamp, origin: RelayKeyEventOrigin.of(event))
                }
                hasLocalInputSincePromptBoundary = true
                recordPromptEdit(.paste)
                promptBuffer.insert(pasted)
                if !promptBuffer.isReliable { resetPromptHistory() }
            } else {
                invalidatePromptMirror()
            }
            return
        }
        if control {
            switch key {
            case "a":
                promptHistory.breakCoalescing()
                promptBuffer.moveToStart()
            case "e":
                promptHistory.breakCoalescing()
                promptBuffer.moveToEnd()
            case "u":
                if promptBuffer.cursor > 0 { recordPromptEdit(.deleting) }
                promptBuffer.deleteToStart()
            case "k":
                if !promptBuffer.isAtEnd { recordPromptEdit(.deleting) }
                promptBuffer.deleteToEnd()
            case "w":
                if promptBuffer.cursor > 0 { recordPromptEdit(.deleting) }
                promptBuffer.deletePreviousWord()
            case "c":
                promptBuffer.clear()
                resetPromptHistory()
            case "l": break
            default: invalidatePromptMirror()
            }
            return
        }
        switch event.keyCode {
        case 51:
            if promptBuffer.cursor > 0 { recordPromptEdit(.deleting) }
            if command { promptBuffer.deleteToStart() }
            else if option { promptBuffer.deletePreviousWord() }
            else { promptBuffer.backspace() }
        case 117:
            if !promptBuffer.isAtEnd { recordPromptEdit(.deleting) }
            promptBuffer.deleteForward()
        case 123:
            promptHistory.breakCoalescing()
            promptBuffer.move(by: -1)
        case 124:
            promptHistory.breakCoalescing()
            promptBuffer.move(by: 1)
        case 115:
            promptHistory.breakCoalescing()
            promptBuffer.moveToStart()
        case 119:
            promptHistory.breakCoalescing()
            promptBuffer.moveToEnd()
        case 125, 126:
            invalidatePromptMirror()
            // History recall is an editor interaction even though it inserts
            // no text through AppKit. Agent phase updates can arrive later;
            // selection must not wait for the sidebar to report "Ready".
            hasLocalInputSincePromptBoundary = true
        default:
            if command || option { return }
            return
        }
    }

    private func cursorMovementOffset(to locationInWindow: CGPoint) -> Int? {
        cursorMovementOffset(
            toTerminalPoint: terminalPointForWindowLocation(locationInWindow)
        )
    }

    private func cursorMovementOffset(toTerminalPoint target: CGPoint) -> Int? {
        guard let geometry = activeCursorGeometry() else { return nil }
        guard let visualOffset = TerminalPromptSelectionEdit.cursorMovementOffset(
            // IME reports the boundary below the text row. Pointer selections
            // hit the row above it, just as keyboard-generated selections do.
            cursorOrigin: CGPoint(x: geometry.origin.x, y: geometry.origin.y - geometry.cellSize.height),
            target: target,
            cellSize: geometry.cellSize,
            columns: geometry.columns
        ) else { return nil }
        let promptMirrorIsReliable = promptBuffer.isReliable
        return TerminalPromptSelectionEdit.resolvedMovementOffset(
            visualOffset: visualOffset,
            mirroredOffset: promptBuffer.logicalMovementOffset(
                forVisualCellDelta: visualOffset
            ),
            mirrorIsReliable: promptMirrorIsReliable,
            allowsRemoteVisualFallback: owner?.allowsRemotePromptVisualFallback == true &&
                (semanticShellPromptActive ||
                    owner?.agentPromptEditingAllowed == true ||
                    hasLocalInputSincePromptBoundary)
        )
    }

    private func placePromptCursor(at locationInWindow: CGPoint) -> Bool {
        let point = terminalPointForWindowLocation(locationInWindow)
        guard owner?.allowsPromptSelectionEditing == true,
              owner?.promptCursorPlacementAllowed == true,
              promptEditingIsSemanticallyActive,
              pointIsNearActivePrompt(point),
              let movementOffset = cursorMovementOffset(to: locationInWindow)
        else {
            owner?.recordInputDiagnostic("prompt-click-rejected", details: [
                "selection_allowed": String(owner?.allowsPromptSelectionEditing == true),
                "placement_allowed": String(owner?.promptCursorPlacementAllowed == true),
                "semantic_editing": String(promptEditingIsSemanticallyActive),
                "near_prompt": String(pointIsNearActivePrompt(point)),
                "movement": cursorMovementOffset(to: locationInWindow).map(String.init) ?? "unresolved",
                "mirror_reliable": String(promptBuffer.isReliable)
            ])
            return false
        }

        window?.makeFirstResponder(self)
        guard movementOffset != 0 else { return true }
        promptHistory.breakCoalescing()
        guard sendPromptControl(movementOffset: movementOffset) else {
            invalidatePromptMirror()
            return false
        }
        promptBuffer.move(by: movementOffset)
        return true
    }

    func shellPromptBecameActive() {
        setShellPromptActive(true)
        owner?.resolvePromptEditorPolicy()
    }

    func setShellPromptActive(_ active: Bool) {
        let changed = semanticShellPromptActive != active
        semanticShellPromptActive = active
        if active { restoreShellMouseReporting() }
        if changed { synchronizePromptWidthPolicy() }
        if !active {
            promptSelection = nil
            keyboardSelectionOffset = nil
            keyboardSelectionIsVisual = false
        }
    }

    fileprivate func synchronizePromptWidthPolicy() {
        owner?.synchronizePromptWidthPolicy(active: semanticShellPromptActive)
    }

    /// A remote snapshot/replay is visual terminal state, not proof that Relay
    /// observed the complete editable line. Keep semantic prompt state but
    /// discard the local text mirror so mouse placement cannot clamp itself to
    /// only the suffix typed after reconnect.
    fileprivate func promptExecutionBoundaryWasObserved() {
        invalidatePromptMirror()
        hasLocalInputSincePromptBoundary = false
        owner?.recordInputDiagnostic("prompt-history-execution-boundary")
    }

    fileprivate func recoverPromptHistoryAfterReplay() {
        guard suspendedPromptHistory != nil else { return }
        synchronizePromptMirrorFromRenderer()
        refreshPromptHistoryIdentity()
        owner?.recordInputDiagnostic("prompt-history-replay-recovery", details: [
            "suspended": String(suspendedPromptHistory != nil),
            "reliable": String(promptBuffer.isReliable),
            "characters": String(promptBuffer.snapshot?.characters.count ?? -1),
            "cursor": String(promptBuffer.snapshot?.cursor ?? -1),
        ])
    }

    func remoteTerminalStateWasRestored() {
        owner?.recordInputDiagnostic("prompt-history-suspend", details: [
            "already_suspended": String(suspendedPromptHistory != nil),
            "owner": String(promptOwnerBinding != nil), "reliable": String(promptBuffer.isReliable),
            "undo": String(promptHistory.canUndo), "redo": String(promptHistory.canRedo),
            "characters": String(promptBuffer.snapshot?.characters.count ?? -1),
            "cursor": String(promptBuffer.snapshot?.cursor ?? -1),
        ])
        if suspendedPromptHistory == nil, let binding = promptOwnerBinding,
           let snapshot = promptBuffer.snapshot, promptHistory.canUndo || promptHistory.canRedo {
            suspendedPromptHistory = SuspendedPromptHistory(
                binding: binding, snapshot: snapshot, history: promptHistory)
        }
        promptOwnerTask?.cancel()
        promptOwnerTask = nil
        promptOwnerTaskID = nil
        promptOwnerBinding = nil
        promptHistoryGeneration &+= 1
        promptBuffer.invalidate()
        promptHistory.reset()
        hasLocalInputSincePromptBoundary = false
        promptSelection = nil
        keyboardSelectionOffset = nil
        keyboardSelectionIsVisual = false
    }

    fileprivate func unobservedPromptInput() {
        invalidatePromptMirror()
        hasLocalInputSincePromptBoundary = true
    }

    fileprivate func assistantShellPromptIsEmpty() -> Bool {
        guard semanticShellPromptActive, owner?.promptEditingViewportIsLive == true,
              markedRange().location == NSNotFound else { return false }
        synchronizePromptMirrorFromRenderer()
        return promptBuffer.isReliable && promptBuffer.snapshot?.characters.isEmpty == true
    }

    fileprivate func claudePromptPredictionHasEmptyInput() -> Bool {
        guard owner?.promptEditingViewportIsLive == true,
              conversationPromptIsEmpty,
              markedRange().location == NSNotFound,
              let geometry = activeCursorGeometry() else { return false }
        let gridX = geometry.gridOrigin.x
        let row = Int(floor((geometry.point.y - geometry.cellSize.height - geometry.gridOrigin.y) / geometry.cellSize.height))
        let column = Int(floor((geometry.origin.x - gridX) / geometry.cellSize.width))
        guard let line = readViewportRow(row, columns: geometry.columns),
              line.trimmingCharacters(in: .whitespaces).hasPrefix("❯"),
              let start = TerminalPromptSelectionEdit.inputPrefixLength(
                line.replacingOccurrences(of: "\u{00A0}", with: " "), shell: false) else { return false }
        // Claude paints suggestions after the caret. A typed draft, accepted
        // suggestion, history selection or IME composition invalidates this proof.
        return column == start
    }

    fileprivate var conversationPromptIsEmpty: Bool {
        // After reconnect or an unobserved edit the mirror is unreliable;
        // refuse native composition until the original terminal resynchronizes.
        promptBuffer.isReliable && promptBuffer.snapshot?.characters.isEmpty == true &&
            !hasLocalInputSincePromptBoundary && !promptInspectionPreservesInput && markedRange().location == NSNotFound
    }

    private var promptEditingIsSemanticallyActive: Bool {
        TerminalPromptSelectionEdit.promptEditingIsActive(
            agentPrompt: owner?.forcesLocalPromptSelection == true,
            hasLocalInput: hasLocalInputSincePromptBoundary ||
                (owner?.forcesLocalPromptSelection == true &&
                 promptBuffer.snapshot?.characters.isEmpty == false),
            agentPhaseAllowsEditing: owner?.agentPromptEditingAllowed == true,
            semanticShellPromptActive: semanticShellPromptActive
        )
    }

    private func terminalPointForWindowLocation(_ locationInWindow: CGPoint) -> CGPoint {
        let local = convert(selectionAdjustedWindowLocation(locationInWindow), from: nil)
        return CGPoint(x: local.x, y: bounds.height - local.y)
    }

    private var selectedPromptDeletionIsAvailable: Bool {
        guard let selection = promptSelection else { return true }
        return window != nil && promptBuffer.plannedDeletionSnapshot(
            characterCount: selection.characterCount, movementOffset: selection.movementOffset) != nil
    }

    @discardableResult
    private func deleteCurrentPromptSelection(recordHistory: Bool = true) -> Bool {
        guard let selection = promptSelection else { return false }
        if recordHistory, usesExactPromptMutations {
            guard let current = promptBuffer.snapshot,
                  let target = promptBuffer.plannedDeletionSnapshot(characterCount: selection.characterCount,
                    movementOffset: selection.movementOffset) else { return false }
            return startExactPromptMutation(current: current, target: target, kind: .deleting,
                recoveryAction: .deleteSelection(current, selection))
        }
        guard applyPromptEdit(selection, recordHistory: recordHistory) else { return false }
        clearPromptSelection()
        return true
    }

    private func clearPromptSelection() {
        _ = resetSelection()
        localSelectAllNeedsExactText = false
        promptSelection = nil
        keyboardSelectionOffset = nil
        keyboardSelectionIsVisual = false
    }

    @discardableResult
    private func applyPromptEdit(_ selection: PromptSelection, recordHistory: Bool,
        historyKind: TerminalPromptEditHistory.Kind = .deleting, followingText: String? = nil) -> Bool {
        guard window != nil,
              let target = promptBuffer.plannedDeletionSnapshot(
                characterCount: selection.characterCount, movementOffset: selection.movementOffset) else { return false }
        // History is published only after the translated input is admitted.
        // A rejected edit must retain the original history for owned recovery.
        guard sendPromptControl(
            movementOffset: selection.movementOffset,
            deletionCount: selection.characterCount, followingText: followingText
        ) else {
            // Nothing was dispatched (admission is all-or-nothing), but the
            // selection this edit replaces is local intent with no single-key
            // native equivalent. Callers keep the hold rather than guess.
            owner?.recordInputDiagnostic("prompt-control-refused", details: [
                "reason": "edit", "queued_actions": String(deferredPromptInput.count)])
            remoteTerminalStateWasRestored()
            promptInspectionRequiresRecovery = true
            return false
        }
        if recordHistory { recordPromptEdit(historyKind) }
        promptBuffer.restore(target)
        return true
    }

    private func handleCompositePromptDeletion(_ event: NSEvent) -> Bool {
        guard promptSelection == nil, semanticShellPromptActive,
              owner?.usesReadlinePromptUnits == true,
              event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
              let snapshot = promptBuffer.snapshot else { return false }
        let index = event.keyCode == 51 ? snapshot.cursor - 1 : snapshot.cursor
        guard event.keyCode == 51 || event.keyCode == 117,
              index >= 0, index < snapshot.characters.count,
              promptEditorKeyCount(snapshot.characters[index...index]) > 1 else { return false }
        guard applyPromptEdit(PromptSelection(characterCount: 1,
            movementOffset: event.keyCode == 51 ? 0 : 1), recordHistory: true) else {
            // This character spans several readline units, so a native
            // Backspace/Delete would remove only part of it. Nothing was
            // dispatched; keep the whole draft and hold this key, so the
            // recovery state applyPromptEdit set always has a visible hold
            // (Escape resumes and keeps the text) instead of a stale flag
            // that would make a later transient hold stick.
            preserveDeferredPromptInput(.key(event),
                message: "The deletion could not be dispatched. Input is preserved for recovery.")
            return true
        }
        owner?.userEnteredInput()
        return true
    }

    // Never let the application's ambient C locale change Unicode editing
    // units. This private immutable locale does not change process-wide locale.
    private static let promptWidthLocale: locale_t? = newlocale(LC_CTYPE_MASK, "en_US.UTF-8", nil)

    private func promptEditorKeyCount(_ characters: ArraySlice<Character>) -> Int {
        guard semanticShellPromptActive, owner?.usesReadlinePromptUnits == true,
              let locale = Self.promptWidthLocale else { return characters.count }
        // GNU Readline moves/deletes to the preceding nonzero-width scalar,
        // not a Unicode extended grapheme boundary. Combining scalars stay
        // with their base; emoji modifiers and joined bases are separate units.
        return characters.reduce(0) { count, character in
            count + max(1, character.unicodeScalars.filter { relayUTF8ScalarWidth(Int32($0.value), locale) != 0 }.count)
        }
    }

    @discardableResult
    private func sendPromptControl(movementOffset: Int, deletionCount: Int = 0, followingText: String? = nil,
        snapshotOverride: TerminalPromptBuffer.Snapshot? = nil,
        expectedControlLease: RelayPromptEditorControlLease? = nil) -> Bool {
        guard window != nil, movementOffset >= -4_096, movementOffset <= 4_096,
              deletionCount >= 0, deletionCount <= 4_096 else { return false }
        guard movementOffset != 0 || deletionCount != 0 else { return false }

        // Always let Ghostty translate keys against the live terminal mode.
        // Codex and Claude can enable Kitty keyboard or application-cursor
        // modes, where hard-coded ESC [ D/C is not equivalent to an actual
        // arrow key. Collect at the native surface before its IO queue, then
        // admit the complete packet to the original transport and lease.
        var movementKeys = abs(movementOffset)
        var deletionKeys = deletionCount
        if let snapshot = snapshotOverride ?? promptBuffer.snapshot {
            let end = snapshot.cursor + movementOffset
            guard end >= 0, end <= snapshot.characters.count,
                  end - deletionCount >= 0 else { return false }
            movementKeys = promptEditorKeyCount(snapshot.characters[min(snapshot.cursor, end)..<max(snapshot.cursor, end)])
            deletionKeys = promptEditorKeyCount(snapshot.characters[(end - deletionCount)..<end])
        }
        guard movementKeys <= 65_536, deletionKeys <= 65_536 else { return false }
        guard let owner else { return false }
        return owner.performPromptControlTranslation(in: self, expectedControlLease: expectedControlLease) {
            let movementKey: UInt16 = movementOffset < 0 ? 123 : 124
            for _ in 0..<movementKeys { sendSyntheticPromptKey(movementKey) }
            for _ in 0..<deletionKeys { sendSyntheticPromptKey(51) }
            if let followingText { sendPromptPlainText(followingText) }
        }
    }

    /// Same Ghostty translation used by physical terminal input. Captured by
    /// collectNativeInput; this method alone never claims transport delivery.
    func translateTerminalEdit(_ request: RelayTerminalEditRequest) {
        if request.action == "insert_text", let text = request.text { super.sendText(text); return }
        guard let key = request.key.flatMap(RelayTerminalEditKey.init(rawValue:)) else { return }
        let native = key.native
        let modifiers = request.nativeModifiers
        let characters = modifiers.contains(.shift) ? native.characters.uppercased() : native.characters
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window?.windowNumber ?? 0, context: nil,
            characters: characters, charactersIgnoringModifiers: native.characters, isARepeat: false, keyCode: native.code) else { return }
        let previous = translatingPromptControlKey
        translatingPromptControlKey = true
        defer { translatingPromptControlKey = previous }
        super.keyDown(with: event)
    }

    private func sendSyntheticPromptKey(
        _ keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags = []
    ) {
        guard let window else { return }
        let characters: String
        switch keyCode {
        case 123: characters = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        case 124: characters = String(UnicodeScalar(NSRightArrowFunctionKey)!)
        case 36: characters = "\r"
        default: characters = "\u{007F}"
        }
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ) else { return }
        let wasTranslating = translatingPromptControlKey
        translatingPromptControlKey = true
        defer { translatingPromptControlKey = wasTranslating }
        super.keyDown(with: event)
    }

    private func pointIsNearActivePrompt(_ point: CGPoint) -> Bool {
        selectionIsNearActivePrompt(start: point, end: point)
    }

    private func localSelectionEvent(
        from event: NSEvent,
        clickCount: Int? = nil
    ) -> NSEvent? {
        NSEvent.mouseEvent(
            with: event.type,
            location: selectionAdjustedWindowLocation(event.locationInWindow),
            modifierFlags: event.modifierFlags.union(.shift),
            timestamp: event.timestamp,
            windowNumber: event.windowNumber,
            context: nil,
            eventNumber: event.eventNumber,
            clickCount: clickCount ?? event.clickCount,
            pressure: event.pressure
        )
    }

    private func localSelectionEvent(
        from pending: PendingLocalSelectionMouseDown,
        clickCount: Int? = nil
    ) -> NSEvent? {
        guard let window else { return nil }
        return NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: windowLocation(forTerminalPoint: pending.terminalPoint),
            modifierFlags: pending.modifierFlags.union(.shift),
            timestamp: pending.timestamp,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: pending.eventNumber,
            clickCount: clickCount ?? pending.clickCount,
            pressure: pending.pressure
        )
    }

    private func windowLocation(forTerminalPoint point: CGPoint) -> CGPoint {
        convert(
            CGPoint(x: point.x, y: bounds.height - point.y),
            to: nil
        )
    }

    private func replayTerminalClick(at locationInWindow: CGPoint) {
        guard let window else { return }
        let timestamp = ProcessInfo.processInfo.systemUptime
        guard let down = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: locationInWindow,
            modifierFlags: [],
            timestamp: timestamp,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ), let up = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: locationInWindow,
            modifierFlags: [],
            timestamp: timestamp,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0
        ) else { return }
        super.mouseDown(with: down)
        super.mouseUp(with: up)
    }

    override func rightMouseDown(with event: NSEvent) {
        owner?.prepareForUserInteraction()
        _ = acquireProgrammaticFocus()
        owner?.selectPane()
        owner?.focus()
        NSMenu.popUpContextMenu(relayContextMenu(), with: event, for: self)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        relayContextMenu()
    }

    private func relayContextMenu() -> NSMenu {
        let menu = NSMenu(title: "Terminal")
        menu.autoenablesItems = false
        menu.addItem(item("Copy", action: #selector(copyRelay), key: "c", enabled: true))
        menu.addItem(item(
            "Paste",
            action: #selector(pasteRelay),
            key: "v",
            enabled: NSPasteboard.general.string(forType: .string) != nil
                || !localFileURLs(from: NSPasteboard.general).isEmpty
        ))
        menu.addItem(item("Select All", action: #selector(selectAllRelay), key: "a", enabled: true))
        menu.addItem(item("Select All Terminal Output", action: #selector(selectAllTerminalOutput), enabled: true))
        if (promptInspectionPreservesInput || !recoveredPreservedText.isEmpty), promptInspectionTask == nil, nativePasteConfirmation == nil {
            menu.addItem(item("Copy Preserved Text", action: #selector(copyPreservedPromptTextAction),
                enabled: !preservedCommittedPromptText.isEmpty))
            menu.addItem(item("Copy Preserved Files", action: #selector(copyPreservedPromptFilesAction),
                enabled: !preservedPromptFiles.isEmpty))
            menu.addItem(item("Discard Preserved Input", action: #selector(discardPreservedPromptInputAction), enabled: true))
        }
        menu.addItem(item(
            "Delete Prompt Selection",
            action: #selector(deleteRelayPromptSelection),
            enabled: promptSelection != nil
        ))
        menu.addItem(.separator())
        menu.addItem(item("Previous Prompt", action: #selector(previousPrompt), enabled: true))
        menu.addItem(item("Next Prompt", action: #selector(nextPrompt), enabled: true))
        menu.addItem(.separator())
        menu.addItem(item("Split Right", action: #selector(splitRight), key: "d", enabled: true))
        menu.addItem(item("Split Down", action: #selector(splitDown), key: "D", enabled: true))
        menu.addItem(.separator())
        menu.addItem(item("Clear Scrollback", action: #selector(clearScrollback), enabled: true))
        menu.addItem(item(
            owner?.paneIsRemote == true ? "Detach Pane" : "Close Pane",
            action: #selector(closeRelayPane),
            key: "w",
            enabled: true
        ))
        if owner?.paneIsRemote == true {
            menu.addItem(item(
                "Terminate Remote Pane…",
                action: #selector(terminateRelayPane),
                enabled: true
            ))
        }
        return menu
    }

    private func item(
        _ title: String,
        action: Selector,
        key: String = "",
        enabled: Bool
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.isEnabled = enabled
        return item
    }

    @objc private func copyRelay() { _ = copyRelaySelectionToPasteboard() }
    @objc private func pasteRelay() { _ = handleApplicationClipboardAction(.paste) }
    @objc private func copyPreservedPromptTextAction() { _ = copyPreservedPromptText() }
    @objc private func discardPreservedPromptInputAction() { _ = discardPreservedPromptInput() }
    @objc private func copyPreservedPromptFilesAction() {
        guard promptInspectionTask == nil, nativePasteConfirmation == nil, !preservedPromptFiles.isEmpty else { return }
        NSPasteboard.general.clearContents()
        _ = NSPasteboard.general.writeObjects(preservedPromptFiles.map { $0 as NSURL })
    }
    @objc private func selectAllRelay() { _ = selectAllRelayContent() }
    @objc private func selectAllTerminalOutput() {
        clearPromptSelection()
        _ = performBindingAction("select_all")
    }
    @objc private func deleteRelayPromptSelection() {
        // Capture the original draft and selection before a refused edit
        // invalidates them.
        guard let selection = promptSelection else { return }
        let expected = promptBuffer.snapshot
        guard !deleteCurrentPromptSelection(), let expected else { return }
        // Nothing was dispatched; keep the deletion behind a visible hold
        // instead of leaving recovery set with no hold.
        promptInspectionRequiresRecovery = true
        preserveDeferredPromptInput(.deleteSelection(expected, selection),
            message: "The selection deletion could not be dispatched. It is preserved for recovery.")
    }
    @objc private func clearScrollback() { _ = performBindingAction("clear_scrollback") }
    @objc private func previousPrompt() { _ = owner?.jumpToPrompt(by: -1) }
    @objc private func nextPrompt() { _ = owner?.jumpToPrompt(by: 1) }
    @objc private func splitRight() { owner?.split(.horizontal) }
    @objc private func splitDown() { owner?.split(.vertical) }
    @objc private func closeRelayPane() { owner?.closePane() }
    @objc private func terminateRelayPane() { owner?.terminatePane() }

    private func importFiles(from pasteboard: NSPasteboard) -> Bool {
        let urls = localFileURLs(from: pasteboard)
        return !urls.isEmpty && owner?.importLocalFiles(urls) == true
    }

    @discardableResult
    private func pasteFromClipboard() -> Bool {
        owner?.prepareForUserInteraction()
        if importFiles(from: NSPasteboard.general) {
            invalidatePromptMirror()
            return true
        }
        guard let text = NSPasteboard.general.string(forType: .string) else { return false }
        // Cmd+V or a menu click: the origin of whichever event triggered it.
        let current = NSApp.currentEvent
        owner?.recordPromptInput {
            $0.paste(bytes: text.utf8.count, event: current?.timestamp, origin: RelayKeyEventOrigin.of(current))
        }
        return pastePromptText(text)
    }

    private func pastePromptText(_ text: String) -> Bool {
        // A restored terminal has no trusted local draft. Recover the live
        // prompt before paste changes it, while an empty or ASCII draft can
        // still be read exactly from the renderer. This matches insertText.
        synchronizePromptMirrorFromRenderer()
        if TerminalPastePayload.rendererPayload(for: text,
            bracketed: owner?.bracketedPasteIsActive == true) != nil,
           handleExactPromptReplacement(text, kind: .paste, recoveryAction: .paste(text: text, files: [])) { return true }
        if let payload = TerminalPastePayload.rendererPayload(
            for: text,
            bracketed: owner?.bracketedPasteIsActive == true
        ) {
            // Paste replaces an armed editable range, just like insertText.
            // Record the original draft once so Undo restores the replacement
            // as one edit rather than exposing an intermediate empty range.
            guard selectedPromptDeletionIsAvailable else {
                preserveDeferredPromptInput(.paste(text: text, files: []),
                    message: "The selected draft could not be verified. Paste is preserved for recovery.")
                return true
            }
            if let selection = promptSelection {
                guard applyPromptEdit(selection, recordHistory: true, historyKind: .paste, followingText: payload) else {
                    preserveDeferredPromptInput(.paste(text: text, files: []),
                        message: "The selected draft could not be verified. Paste is preserved for recovery.")
                    return true
                }
                clearPromptSelection()
            } else {
                recordPromptEdit(.paste)
                sendText(payload)
            }
        } else {
            // Unbracketed multi-line pastes keep Ghostty's existing safety
            // confirmation. Single-line and bracketed payloads above use the
            // already-captured value and therefore cannot race a clipboard
            // manager restoring the pasteboard.
            // The native confirmation handler owns edits after the decision.
            // Do not mutate the mirror or revision while its dialog is pending.
            return pasteCapturedText(text)
        }

        // Clipboard input bypasses insertText/keyDown, so keep the semantic
        // prompt mirror in sync explicitly for cursor placement.
        hasLocalInputSincePromptBoundary = true
        promptBuffer.insert(text)
        if !promptBuffer.isReliable { resetPromptHistory() }
        owner?.userEnteredInput()
        return true
    }

    /// Cut = copy the selection, then delete it from the live prompt. Only an
    /// armed prompt selection is deletable, so cutting old transcript output
    /// degrades to a plain copy rather than doing nothing.
    @discardableResult
    private func cutRelayPromptSelection() -> Bool {
        guard copyRelaySelectionToPasteboard() else { return false }
        guard promptSelection != nil else { return true }
        guard deleteCurrentPromptSelection() else {
            promptInspectionRequiresRecovery = true
            preserveDeferredPromptInput(.clipboard(.cut),
                message: "The selection was copied, but deletion could not be verified. Input is preserved for recovery.")
            return false
        }
        return true
    }

    /// Copy a proven prompt range exactly, otherwise read Ghostty's current
    /// rendered selection. The final keyboard fallback covers an agent composer
    /// repaint between Shift-arrow and Command-C. Mouse-down clears those prompt
    /// ranges, so copying transcript output cannot reuse a stale prompt selection.
    @discardableResult
    private func copyRelaySelectionToPasteboard() -> Bool {
        if promptInspectionPreservesInput, let text = promptInspectionVisualCopy {
            return writeCopiedText(text, source: "preserved-composer-selection")
        }
        if let selection = promptSelection, let snapshot = promptBuffer.snapshot {
            let upper = snapshot.cursor + selection.movementOffset
            let lower = upper - selection.characterCount
            if lower >= 0, upper <= snapshot.characters.count, lower < upper {
                return writeCopiedText(
                    String(snapshot.characters[lower..<upper]), source: "prompt-range"
                )
            }
        }
        // Read the surface synchronously. Ghostty's copy binding only reports
        // dispatch; its clipboard callback can arrive after this method returns,
        // making an immediate pasteboard read observe an older clipboard value.
        if let rendered = selectedText(), !rendered.isEmpty {
            return writeCopiedText(rendered, source: "surface-selection")
        }
        guard let offset = keyboardSelectionOffset,
              let text = promptBuffer.selectedText(relativeToCursor: offset),
              !text.isEmpty else {
            owner?.recordClipboardCopyOutcome(source: "no-selection", bytes: 0, succeeded: false)
            return false
        }
        return writeCopiedText(text, source: "keyboard-range")
    }

    private func writeCopiedText(_ text: String, source: String) -> Bool {
        NSPasteboard.general.clearContents()
        let succeeded = NSPasteboard.general.setString(text, forType: .string)
        owner?.recordClipboardCopyOutcome(source: source, bytes: text.utf8.count, succeeded: succeeded)
        return succeeded
    }

    private func localFileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let objects = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [NSURL] ?? []
        return objects.compactMap { $0 as URL }
    }
}

private extension TerminalRuntime {
    var paneIsRemote: Bool {
        pane?.profile.backend == .relay
    }

}

extension Notification.Name {
    static let relaySelectPane = Notification.Name("relay.select-pane")
    static let relaySplitRight = Notification.Name("relay.split-right")
    static let relaySplitDown = Notification.Name("relay.split-down")
    static let relayWorkOverview = Notification.Name("relay.work-overview")
    static let relayClosePane = Notification.Name("relay.close-pane")
    static let relayRestartExitedPane = Notification.Name("relay.restart-exited-pane")
    static let relayResumeSavedConversation = Notification.Name("relay.resume-saved-conversation")
    static let relayReconnectPane = Notification.Name("relay.reconnect-pane")
    static let relayTerminatePane = Notification.Name("relay.terminate-pane")
    static let relayOpenRemoteFile = Notification.Name("relay.open-remote-file")
    static let relayClipboardRequest = Notification.Name("relay.clipboard-request")
}

@MainActor
struct TerminalSurface: NSViewRepresentable, Equatable {
    let pane: PaneModel
    nonisolated let covered: Bool
    nonisolated let identity: UUID

    init(pane: PaneModel, covered: Bool = false) {
        self.pane = pane
        self.covered = covered
        self.identity = pane.id
    }

    nonisolated static func == (lhs: TerminalSurface, rhs: TerminalSurface) -> Bool {
        lhs.identity == rhs.identity && lhs.covered == rhs.covered
    }

    final class Coordinator {
        let presentationLease = UUID()
        var attachmentGeneration: UInt64?
        var presentationTask: Task<Void, Never>?
        var isPresented = false
        var isDismantled = false
        var candidateSize: CGSize?
        var stableSizeSamples = 0
        var covered = false

        deinit { presentationTask?.cancel() }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> RelayGhosttyView {
        let view = pane.runtime.view
        let coordinator = context.coordinator
        if ProcessInfo.processInfo.environment["RELAY_TERMINAL_DEBUG"] == "1" {
            FileHandle.standardError.write(Data(
                "[RelaySurface] make pane=\(pane.id.uuidString.lowercased()) view=\(ObjectIdentifier(view))\n".utf8
            ))
        }
        coordinator.isDismantled = false
        coordinator.covered = covered
        coordinator.attachmentGeneration = pane.runtime.beginPresentationAttachment(
            lease: coordinator.presentationLease
        )
        view.didAttachToWindow = { [weak view, weak coordinator] in
            guard let view, let coordinator else { return }
            presentAfterLayout(view, coordinator: coordinator)
        }
        // Reuse Ghostty's last settled IOSurface immediately. Stable-layout
        // measurement below will replace it at the destination grid, but a
        // normal tab switch must never insert an artificial black frame.
        view.alphaValue = 1
        view.setSurfaceVisible(!covered)
        if !covered { view.synchronizeAndRedraw() }
        presentAfterLayout(view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ nsView: RelayGhosttyView, context: Context) {
        let coordinator = context.coordinator
        if coordinator.covered != covered {
            coordinator.covered = covered
            if coordinator.isPresented, let generation = coordinator.attachmentGeneration {
                pane.runtime.setPresented(
                    !covered, lease: coordinator.presentationLease,
                    generation: generation, force: true
                )
            }
        }
        presentAfterLayout(nsView, coordinator: context.coordinator)
        // AppTerminalView already synchronizes its grid from setFrameSize and
        // layout. Calling fitToSize for every unrelated SwiftUI model update
        // forces an immediate Metal frame even when geometry did not change.
    }

    static func dismantleNSView(_ nsView: RelayGhosttyView, coordinator: Coordinator) {
        if ProcessInfo.processInfo.environment["RELAY_TERMINAL_DEBUG"] == "1" {
            FileHandle.standardError.write(Data(
                "[RelaySurface] dismantle view=\(ObjectIdentifier(nsView))\n".utf8
            ))
        }
        coordinator.isDismantled = true
        coordinator.presentationTask?.cancel()
        coordinator.presentationTask = nil
        coordinator.isPresented = false
        coordinator.candidateSize = nil
        coordinator.stableSizeSamples = 0
        // The same durable terminal view can be reattached by another tab or
        // zoom layout. Keep its previous IOSurface hidden until that layout is
        // stable instead of briefly stretching the old cell grid.
        if let generation = coordinator.attachmentGeneration {
            nsView.owner?.endPresentationAttachment(
                lease: coordinator.presentationLease,
                generation: generation
            )
        }
        coordinator.attachmentGeneration = nil
    }

    private func presentAfterLayout(_ view: RelayGhosttyView, coordinator: Coordinator) {
        guard !coordinator.isDismantled,
              !coordinator.isPresented,
              coordinator.presentationTask == nil else { return }
        coordinator.presentationTask = Task { @MainActor [weak view, weak coordinator] in
            guard let view, let coordinator else { return }
            for delay in [0, 8, 16, 24, 32, 48, 64] {
                if delay == 0 {
                    await Task.yield()
                } else {
                    try? await Task.sleep(for: .milliseconds(delay))
                }
                guard !Task.isCancelled else { return }
                view.superview?.layoutSubtreeIfNeeded()
                guard view.window != nil,
                      view.bounds.width > 1,
                      view.bounds.height > 1 else { continue }

                let size = view.bounds.size
                if let candidate = coordinator.candidateSize,
                   abs(candidate.width - size.width) < 0.5,
                   abs(candidate.height - size.height) < 0.5 {
                    coordinator.stableSizeSamples += 1
                } else {
                    coordinator.candidateSize = size
                    coordinator.stableSizeSamples = 1
                }

                // Require the same geometry in two distinct layout samples.
                // A merely non-zero size is commonly the outgoing tab's frame.
                guard coordinator.stableSizeSamples >= 2 else { continue }

                pane.runtime.prepareFinalSurfaceMeasurement()
                pane.runtime.fitForStableViewportCommit()
                let commit = pane.runtime.commitStableViewport()
                let mayReveal = pane.runtime.finishStableGeometryTransition(commit)
                // Snapshot and remote replay bytes must not reach Ghostty
                // until its final pane grid exists. Feeding them after merely
                // one run-loop yield makes multi-pane launches interpret a
                // TUI redraw at the outgoing/full-window width; later resize
                // cannot reconstruct cursor-addressed output and leaves the
                // familiar vertical/garbled columns.
                pane.runtime.startIfNeeded()
                guard let attachmentGeneration = coordinator.attachmentGeneration else { return }
                pane.runtime.setPresented(
                    !coordinator.covered,
                    lease: coordinator.presentationLease,
                    generation: attachmentGeneration,
                    force: true
                )
                TerminalReplayTrace.log("present pane=\(pane.id.uuidString) size=\(Int(size.width))x\(Int(size.height)) revealed=\(mayReveal)")

                guard !Task.isCancelled, view.window != nil else { return }
                if mayReveal { view.alphaValue = 1 }
                coordinator.isPresented = true
                coordinator.presentationTask = nil
                return
            }
            // Extremely busy restored workspaces can attach the NSView after
            // the initial settling samples have elapsed. Keep retrying only
            // while this representable is alive; dismantling cancels the
            // lifecycle so hidden tabs consume no polling work.
            coordinator.presentationTask = nil
            guard !coordinator.isDismantled else { return }
            if ProcessInfo.processInfo.environment["RELAY_TERMINAL_DEBUG"] == "1" {
                FileHandle.standardError.write(Data(
                    "[RelaySurface] unsettled view=\(ObjectIdentifier(view)) window=\(view.window != nil) bounds=\(view.bounds.width)x\(view.bounds.height)\n".utf8
                ))
            }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, !coordinator.isDismantled else { return }
            presentAfterLayout(view, coordinator: coordinator)
        }
    }
}

extension TerminalSemanticPromptStateTracker {
    /// Parser state after an observed stream, persisted by snapshot
    /// checkpoints so a restore need not rescan the whole cached payload.
    struct PersistentState: Codable, Equatable, Sendable {
        var parser: UInt8
        var payload: [UInt8]
        var promptActive: Bool
        var executions: UInt64
    }

    private static let persistentParsers: [ParserState] = [.ground, .escape, .osc, .oscEscape]

    var persistentState: PersistentState {
        lock.lock()
        defer { lock.unlock() }
        return PersistentState(
            parser: UInt8(Self.persistentParsers.firstIndex(of: parserState)!),
            payload: payload,
            promptActive: promptActive,
            executions: executions
        )
    }

    /// Returns false, leaving the tracker unchanged, for a corrupt record.
    @discardableResult
    func restore(_ saved: PersistentState) -> Bool {
        guard Int(saved.parser) < Self.persistentParsers.count else { return false }
        lock.lock()
        defer { lock.unlock() }
        parserState = Self.persistentParsers[Int(saved.parser)]
        payload = saved.payload
        promptActive = saved.promptActive
        executions = saved.executions
        return true
    }
}

extension TerminalAlternateScreenCleanupFilter {
    /// State after an observed stream, persisted by snapshot checkpoints.
    struct PersistentState: Codable, Equatable, Sendable {
        var pending: [UInt8]
        var inAlternateScreen: Bool
    }

    var persistentState: PersistentState {
        lock.lock()
        defer { lock.unlock() }
        return PersistentState(pending: pending, inAlternateScreen: inAlternateScreen)
    }

    func restore(_ saved: PersistentState) {
        lock.lock()
        defer { lock.unlock() }
        pending = saved.pending
        inAlternateScreen = saved.inAlternateScreen
    }
}

/// Everything `restoreSnapshot` would derive by observing a cached payload
/// with fresh trackers. `semanticChange` is the last non-nil result of
/// `TerminalSemanticPromptStateTracker.observe` over that payload.
struct TerminalSnapshotTrackerState: Codable, Equatable, Sendable {
    var commandReturn: TerminalCommandReturnCleanup.PersistentState
    var alternateScreen: TerminalAlternateScreenCleanupFilter.PersistentState
    var bracketedPaste: TerminalBracketedPasteStateTracker.PersistentState
    var semanticPrompt: TerminalSemanticPromptStateTracker.PersistentState
    var semanticChange: Bool?

    static var initial: TerminalSnapshotTrackerState {
        TerminalSnapshotTrackerState(
            commandReturn: TerminalCommandReturnCleanup().persistentState,
            alternateScreen: TerminalAlternateScreenCleanupFilter().persistentState,
            bracketedPaste: TerminalBracketedPasteStateTracker().persistentState,
            semanticPrompt: TerminalSemanticPromptStateTracker().persistentState,
            semanticChange: nil
        )
    }

    /// Continues the restore-time scan from this state over appended bytes.
    func advanced(by data: Data) -> TerminalSnapshotTrackerState? {
        guard !data.isEmpty else { return self }
        let commandReturn = TerminalCommandReturnCleanup()
        let alternateScreen = TerminalAlternateScreenCleanupFilter()
        let bracketedPaste = TerminalBracketedPasteStateTracker()
        let semanticPrompt = TerminalSemanticPromptStateTracker()
        guard commandReturn.restore(self.commandReturn),
              semanticPrompt.restore(self.semanticPrompt) else { return nil }
        alternateScreen.restore(self.alternateScreen)
        bracketedPaste.restore(self.bracketedPaste)
        commandReturn.observe(data)
        alternateScreen.observe(data)
        bracketedPaste.observe(data)
        let change = semanticPrompt.observe(data)
        return TerminalSnapshotTrackerState(
            commandReturn: commandReturn.persistentState,
            alternateScreen: alternateScreen.persistentState,
            bracketedPaste: bracketedPaste.persistentState,
            semanticPrompt: semanticPrompt.persistentState,
            semanticChange: change ?? semanticChange
        )
    }
}

/// The code hand-off's view of a login pane. Nothing but the code and
/// Return is typed; input diagnostics record only its length.
extension TerminalRuntime: RelayAgentSignInPort {
    func signInPaneState() -> RelayAgentSignInPaneState? {
        guard let pane, pane.contentKind == .terminal, pane.profile.backend == .relay else { return nil }
        let context = io.signInContext
        return RelayAgentSignInPaneState(paneID: pane.id, hostID: pane.profile.id,
            connected: pane.connectionState == .connected, inputLeaseHeld: conversationInputLease != nil,
            producer: context.producer, execution: context.execution, shellPromptShown: context.promptShown,
            viewport: sidePanelViewportText())
    }

    func signInProcesses() async throws -> [[String: Any]] {
        guard let pane else { throw RelayHostRPCError.invalidRequest }
        // Process inventory is host-scoped and does not use the request cwd.
        let result = try await RelayHostFiles.request(context: RelayExecutionContext(profile: pane.profile, directory: "/"),
                                                      fields: ["operation": "process_list"])
        guard let rows = result["processes"] as? [[String: Any]] else { throw RelayHostRPCError.invalidRequest }
        return rows
    }

    func sendSignInInput(_ data: Data) -> Bool {
        guard let pane, io.sendUserInput(data) else { return false }
        pane.userEnteredInput()
        return true
    }
}
