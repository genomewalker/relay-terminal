import Foundation

/// A screen-file export may include the prefix of a long logical row from
/// scrollback. Keep its SGR state, but expose only the exact viewport text read
/// from the same native surface. A mismatch or unknown escape stays unavailable.
enum TerminalScreenViewportProjection {
    static let maximumBytes = 1 << 20

    static func project(_ raw: String, viewport: String) -> String? {
        let bytes = Array(raw.utf8), visible = Array(viewport.utf8)
        guard bytes.count <= maximumBytes, visible.count <= maximumBytes else { return nil }
        if visible.isEmpty { return "" }
        var plain = [UInt8]()
        plain.reserveCapacity(bytes.count)
        var position = 0
        while position < bytes.count {
            if bytes[position] == 0x1b {
                guard let end = escapeEnd(bytes, from: position) else { return nil }
                position = end
            } else if bytes[position] == 0x0d {
                guard position+1 < bytes.count, bytes[position+1] == 0x0a else { return nil }
                position += 1 // Native VT uses CRLF; the text API uses LF.
            } else {
                let byte = bytes[position]
                guard byte >= 0x20 && byte != 0x7f || byte == 0x09 || byte == 0x0a || byte == 0x0d else { return nil }
                plain.append(byte)
                position += 1
            }
        }
        guard plain.count >= visible.count, plain.suffix(visible.count).elementsEqual(visible) else { return nil }
        let prefixCount = plain.count - visible.count
        var styles = [UInt8](), consumed = 0
        position = 0
        while position < bytes.count {
            if consumed == prefixCount {
                styles.append(contentsOf: bytes[position...])
                return String(bytes: styles, encoding: .utf8)
            }
            if bytes[position] == 0x1b {
                guard let end = escapeEnd(bytes, from: position) else { return nil }
                styles.append(contentsOf: bytes[position..<end])
                position = end
            } else if bytes[position] == 0x0d {
                position += 1 // The first pass already verified its LF.
            } else {
                consumed += 1
                position += 1
            }
        }
        return nil
    }

    private static func escapeEnd(_ bytes: [UInt8], from start: Int) -> Int? {
        guard start+1 < bytes.count else { return nil }
        var position = start+2
        if bytes[start+1] == 0x5b { // SGR only; cursor edits are not a static export.
            while position < bytes.count, !(0x40...0x7e).contains(bytes[position]) {
                guard position-start <= 130, (0x20...0x3f).contains(bytes[position]) else { return nil }
                position += 1
            }
            return position < bytes.count && bytes[position] == 0x6d ? position+1 : nil
        }
        if bytes[start+1] == 0x5d { // OSC colour/hyperlink metadata, no cells.
            while position < bytes.count {
                if bytes[position] == 0x07 { return position+1 }
                if bytes[position] == 0x1b {
                    return position+1 < bytes.count && bytes[position+1] == 0x5c ? position+2 : nil
                }
                position += 1
            }
        }
        return nil
    }
}
