import Foundation

/// Adjust renderer widths within verified Bash prompt regions, without PTY input.
final class TerminalPromptWidthMode: @unchecked Sendable {
    private enum State { case ground, escape, escapeIntermediate, csi, osc, oscEscape, controlString, controlStringEscape }
    private let lock = NSLock()
    private var state = State.ground
    private var payload: [UInt8] = []
    private var utf8Remaining = 0
    private var readline = false
    private var unicode = true
    private var pendingUnicode: Bool?

    func configure(readline: Bool, promptActive: Bool) {
        lock.lock()
        defer { lock.unlock() }
        self.readline = readline
        let target = !(readline && promptActive)
        pendingUnicode = target == unicode ? nil : target
    }

    private func modeControl(unicode: Bool) -> Data {
        self.unicode = unicode
        pendingUnicode = nil
        return Data((unicode ? "\u{001B}[?2027h" : "\u{001B}[?2027l").utf8)
    }

    /// Preserve original bytes, inserting controls only between complete UTF-8
    /// scalars and terminal sequences. Configuration can arrive mid-packet.
    func transform(_ data: Data) -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard !data.isEmpty else { return data }
        var result = Data()
        var copied = 0
        func insert(_ control: Data, after offset: Int) {
            let start = data.index(data.startIndex, offsetBy: copied)
            let end = data.index(data.startIndex, offsetBy: offset)
            result.append(data[start..<end]); result.append(control); copied = offset
        }
        func flushPending(at offset: Int) {
            if state == .ground, utf8Remaining == 0, let target = pendingUnicode {
                insert(modeControl(unicode: target), after: offset)
            }
        }
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var index = 0
            flushPending(at: 0)
            while index < bytes.count {
                if state == .ground, utf8Remaining == 0, pendingUnicode == nil {
                    while index < bytes.count && bytes[index] < 0x80 && bytes[index] != 0x1B { index += 1 }
                    if index == bytes.count { break }
                }
                let byte = bytes[index]
                index += 1
                var finished = false
                switch state {
                case .ground:
                    if byte == 0x1B { utf8Remaining = 0; state = .escape }
                    else if utf8Remaining > 0, byte & 0xC0 == 0x80 { utf8Remaining -= 1 }
                    else {
                        utf8Remaining = (0xC2...0xDF).contains(byte) ? 1 : ((0xE0...0xEF).contains(byte) ? 2 : ((0xF0...0xF4).contains(byte) ? 3 : 0))
                    }
                case .escape:
                    if byte == 0x5D { payload.removeAll(keepingCapacity: true); state = .osc }
                    else if byte == 0x5B { state = .csi }
                    else if [0x50, 0x5F, 0x5E, 0x58].contains(byte) { state = .controlString }
                    else if (0x20...0x2F).contains(byte) { state = .escapeIntermediate }
                    else { state = byte == 0x1B ? .escape : .ground }
                case .escapeIntermediate:
                    if byte == 0x1B { state = .escape }
                    else if !(0x20...0x2F).contains(byte) { state = .ground }
                case .csi:
                    if byte == 0x1B { state = .escape }
                    else if (0x40...0x7E).contains(byte) || byte == 0x18 || byte == 0x1A { state = .ground }
                case .osc:
                    if byte == 0x07 { finished = true; state = .ground }
                    else if byte == 0x1B { state = .oscEscape }
                    else if byte == 0x18 || byte == 0x1A { payload.removeAll(keepingCapacity: true); state = .ground }
                    else if payload.count < 128 { payload.append(byte) }
                case .oscEscape:
                    if byte == 0x5C || byte == 0x07 { finished = true; state = .ground }
                    else { payload.removeAll(keepingCapacity: true); state = byte == 0x1B ? .oscEscape : .osc }
                case .controlString:
                    if byte == 0x1B { state = .controlStringEscape }
                    else if byte == 0x18 || byte == 0x1A { state = .ground }
                case .controlStringEscape:
                    if byte == 0x5C || byte == 0x18 || byte == 0x1A { state = .ground }
                    else { state = byte == 0x1B ? .controlStringEscape : .controlString }
                }
                if finished {
                    if readline, payload.count >= 5, payload.prefix(4).elementsEqual([0x31, 0x33, 0x33, 0x3B]) {
                        let kind = payload[4]
                        if kind == 0x41 || kind == 0x42 || kind == 0x43 || kind == 0x44 {
                            insert(modeControl(unicode: kind == 0x43 || kind == 0x44), after: index)
                        }
                    }
                    payload.removeAll(keepingCapacity: true)
                }
                flushPending(at: index)
            }
        }
        guard !result.isEmpty else { return data }
        result.append(data[data.index(data.startIndex, offsetBy: copied)...])
        return result
    }
}
