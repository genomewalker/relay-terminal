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
        guard let prefixCount = visibleStart(plain: plain, visible: visible) else { return nil }
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

    /// The plain-byte offset where the viewport begins. Rows are compared
    /// from the bottom and must be equal except for trailing spaces: the VT
    /// export spells background-filled blank cells (a composer box) as
    /// spaces, the text API omits them. The first visible row may be the tail
    /// of a longer logical row from scrollback. Any other difference, a
    /// leading or inner space included, is a mismatch.
    private static func visibleStart(plain: [UInt8], visible: [UInt8]) -> Int? {
        let plainRows = plain.split(separator: 0x0a, omittingEmptySubsequences: false)
        let visibleRows = visible.split(separator: 0x0a, omittingEmptySubsequences: false)
        guard plainRows.count >= visibleRows.count else { return nil }
        func trimmed(_ row: ArraySlice<UInt8>) -> ArraySlice<UInt8> {
            var end = row.endIndex
            while end > row.startIndex, row[end - 1] == 0x20 { end -= 1 }
            return row[row.startIndex..<end]
        }
        let first = plainRows.count - visibleRows.count
        for offset in 1..<max(1, visibleRows.count) {
            guard trimmed(plainRows[first + offset]).elementsEqual(trimmed(visibleRows[offset])) else { return nil }
        }
        let head = trimmed(plainRows[first]), tail = trimmed(visibleRows[0])
        guard head.count >= tail.count, head.suffix(tail.count).elementsEqual(tail) else { return nil }
        // Row slices index into `plain`, so the row's start is its plain offset.
        return plainRows[first].startIndex + head.count - tail.count
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
