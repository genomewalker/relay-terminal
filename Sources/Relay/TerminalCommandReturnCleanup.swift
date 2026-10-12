import Foundation

/// Clear a program-owned display when the shell starts its next prompt.
/// This changes display output only: no keystrokes, command submission, or
/// scrollback-erasure sequence is sent to the terminal or its PTY.
final class TerminalCommandReturnCleanup: @unchecked Sendable {
    private enum State { case ground, escape, csi, string, stringEscape }
    private let lock = NSLock()
    private var state = State.ground
    private var token: [UInt8] = []
    private var stringIsOSC = false
    private var stringIsIgnored = false
    private var programOwnsDisplay = false
    private var programInputModesActive = false
    private var commandStarted = false
    private var hasSeenShellPrompt = false
    private var commandFinished = false
    private var alternateMode: String?
    private var restoringInputPrelude = false
    private var restoredShellInputPrelude = false
    private var finishesShellInputPrelude = false
    // Preserve the shell's own bracketed paste setting and its visible draft.
    private static let restoredShellProtocols = Data((
        "\u{1b}[<65535u\u{1b}[=0u\u{1b}[>4;0m\u{1b}[?1l" +
        "\u{1b}[?1000l\u{1b}[?1002l\u{1b}[?1003l\u{1b}[?1004l" +
        "\u{1b}[?1005l\u{1b}[?1006l\u{1b}[?1015l"
    ).utf8)

    func cachedRestoreProtocolSuffix() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return restoredShellInputPrelude && hasSeenShellPrompt && !commandStarted
            ? Self.restoredShellProtocols : Data()
    }
    private static let escapeByte = Data([0x1b])
    // A crashed TUI can leave keyboard and mouse protocols enabled. Restore
    // shell input modes with the display; otherwise Ctrl+C and mouse movement
    // reach Readline as printable CSI fragments after the program has exited.
    private static let cleanDisplay = Data("\u{1b}[0m\u{1b}[r\u{1b}[?25h\u{1b}[H\u{1b}[2J".utf8)
    private static let shellInputModes = Data((
        "\u{1b}[=0u\u{1b}[>4;0m\u{1b}[?1l" +
        "\u{1b}[?1000l\u{1b}[?1002l\u{1b}[?1003l" +
        "\u{1b}[?1005l\u{1b}[?1006l\u{1b}[?1015l\u{1b}[?1004l" +
        "\u{1b}[?2004l\u{1b}[?7h\u{1b}[?2026l"
    ).utf8)

    func transform(_ data: Data) -> Data { scan(data, emitting: true) }
    func observe(_ data: Data) { _ = scan(data, emitting: false) }

    private func scan(_ data: Data, emitting: Bool) -> Data {
        lock.lock()
        defer { lock.unlock() }
        if state == .ground, data.range(of: Self.escapeByte) == nil {
            return emitting ? data : Data()
        }
        var output = Data()
        if emitting { output.reserveCapacity(data.count) }
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var index = 0
            while index < bytes.count {
                if state == .ground, bytes[index] != 0x1b {
                    restoringInputPrelude = false
                    let start = index
                    repeat { index += 1 } while index < bytes.count && bytes[index] != 0x1b
                    if emitting {
                        output.append(bytes.baseAddress!.assumingMemoryBound(to: UInt8.self).advanced(by: start), count: index - start)
                    }
                    continue
                }
                let byte = bytes[index]
                index += 1
                switch state {
                case .ground:
                    token = [byte]
                    state = .escape
                case .escape:
                    token.append(byte)
                    if byte == 0x5b { state = .csi }
                    else if [0x5d, 0x50, 0x58, 0x5e, 0x5f].contains(byte) {
                        stringIsOSC = byte == 0x5d
                        stringIsIgnored = false
                        state = .string
                    } else { flush(into: &output, emitting: emitting) }
                case .csi:
                    token.append(byte)
                    if (0x40...0x7e).contains(byte) {
                        observeCSI()
                        flush(into: &output, emitting: emitting)
                        if finishesShellInputPrelude {
                            if emitting { output.append(Self.restoredShellProtocols) }
                            finishesShellInputPrelude = false
                        }
                    } else if token.count >= 128 {
                        // Malformed/oversized CSI remains byte-for-byte intact.
                        flush(into: &output, emitting: emitting)
                    }
                case .string, .stringEscape:
                    let wasEscape = state == .stringEscape
                    if stringIsIgnored {
                        if emitting { output.append(byte) }
                    } else { token.append(byte) }
                    if (stringIsOSC && byte == 0x07) || (wasEscape && byte == 0x5c) {
                        if !stringIsIgnored {
                            observeString(into: &output, emitting: emitting)
                            flush(into: &output, emitting: emitting)
                        } else { state = .ground }
                    } else {
                        state = byte == 0x1b ? .stringEscape : .string
                        if !stringIsIgnored && token.count >= 256 {
                            if emitting { output.append(contentsOf: token) }
                            token.removeAll(keepingCapacity: true)
                            stringIsIgnored = true
                        }
                    }
                }
            }
        }
        return output
    }

    private func flush(into output: inout Data, emitting: Bool) {
        if emitting { output.append(contentsOf: token) }
        token.removeAll(keepingCapacity: true)
        state = .ground
    }

    private func observeCSI() {
        guard let final = token.last else { return }
        let parameters = String(decoding: token.dropFirst(2).dropLast(), as: UTF8.self)
        // Durable workers send a canonical mode-only replay beginning with a full
        // Kitty stack pop and ending with bracketed paste. Older workers can retain
        // crashed application modes after OSC 133 has returned to shell input.
        if final == 0x75 && parameters == "<65535" {
            restoringInputPrelude = hasSeenShellPrompt && !commandStarted
        } else if restoringInputPrelude {
            if final == 0x75 && parameters.hasPrefix(">") {
                // Canonical effective keyboard flags.
            } else if (final == 0x68 || final == 0x6c),
                      ["?1", "?1000", "?1002", "?1003", "?1004", "?1006", "?1007", "?2004"].contains(parameters) {
                if parameters == "?2004" {
                    restoredShellInputPrelude = true
                    finishesShellInputPrelude = true
                    restoringInputPrelude = false
                }
            } else {
                restoringInputPrelude = false
            }
        }
        // Shells may enable their own paste mode at a prompt. Only modes
        // enabled while a command owns the terminal belong to that command.
        if commandStarted {
            if final == 0x75, parameters.hasPrefix(">") || parameters.hasPrefix("=") {
                programInputModesActive = true
            } else if final == 0x6d, parameters == ">4;1" || parameters == ">4;2" {
                programInputModesActive = true
            } else if final == 0x68, parameters.hasPrefix("?") {
                let inputModes = ["1000", "1002", "1003", "1004", "1005", "1006", "1015", "2004"]
                if parameters.dropFirst().split(separator: ";").contains(where: { inputModes.contains(String($0)) }) {
                    programInputModesActive = true
                }
            }
        }
        if parameters.hasPrefix("?"), final == 0x68 || final == 0x6c {
            let modes = parameters.dropFirst().split(separator: ";")
            for mode in modes where ["47", "1047", "1049"].contains(String(mode)) {
                if final == 0x68 {
                    alternateMode = String(mode)
                    commandStarted = true
                    programOwnsDisplay = true
                } else { alternateMode = nil }
            }
            if final == 0x68 && modes.contains("2026") {
                commandStarted = true
                programOwnsDisplay = true
            }
        }
        // Older remote shells emit prompt/input markers but no preexec marker.
        // Explicit application display modes still identify display ownership;
        // readline cursor movement alone must not identify a command here.
        guard commandStarted || !hasSeenShellPrompt else { return }
        // Cursor-addressed applications own a layout rather than append lines.
        // SGR/color and erase-to-end-of-line alone are ordinary shell output.
        if [0x41, 0x42, 0x45, 0x46, 0x48, 0x66, 0x64].contains(final),
           !parameters.hasPrefix("?") {
            commandStarted = true
            programOwnsDisplay = true
        }
    }

    private func observeString(into output: inout Data, emitting: Bool) {
        guard stringIsOSC, token.starts(with: [0x1b, 0x5d, 0x31, 0x33, 0x33, 0x3b]), token.count >= 8 else { return }
        // Require an exact marker name, not an OSC payload such as 133;ABC.
        guard token[7] == 0x3b || token[7] == 0x07 || token[7] == 0x1b else { return }
        restoringInputPrelude = false
        let marker = token[6]
        if marker == 0x50 {
            let payload = String(decoding: token.dropFirst(8), as: UTF8.self)
            // Secondary prompts and prompt properties are not command returns.
            guard payload.hasPrefix("k=i"), commandFinished || programOwnsDisplay || programInputModesActive else { return }
        }
        switch marker {
        case 0x43: // OSC 133;C: shell command begins.
            restoredShellInputPrelude = false
            commandStarted = true
            commandFinished = false
            hasSeenShellPrompt = true
            programOwnsDisplay = false
            programInputModesActive = false
            alternateMode = nil
        case 0x44: // OSC 133;D: command finished, before a ble.sh prompt redraw.
            commandFinished = commandStarted
        case 0x42: // OSC 133;B: restored shell input; never erase its draft.
            hasSeenShellPrompt = true
            commandStarted = false
            commandFinished = false
            programOwnsDisplay = false
            programInputModesActive = false
        case 0x41, 0x50: // OSC 133;A: next shell prompt, including older shells without D.
            if commandStarted && emitting {
                if programOwnsDisplay {
                    if let alternateMode {
                        output.append(Data("\u{1b}[?\(alternateMode)l".utf8))
                    }
                    output.append(Self.cleanDisplay)
                }
                if programOwnsDisplay || programInputModesActive {
                    output.append(Self.shellInputModes)
                }
            }
            hasSeenShellPrompt = true
            commandStarted = false
            commandFinished = false
            programOwnsDisplay = false
            programInputModesActive = false
            alternateMode = nil
        default:
            break
        }
    }
}
