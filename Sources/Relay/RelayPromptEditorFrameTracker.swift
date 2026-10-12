import Foundation

/// Tracks substantial completed synchronized updates in the actual parser
/// stream. Keep lexical state while unarmed so a payload or partial sequence
/// at the arm boundary cannot impersonate a terminal mode change.
struct RelayPromptEditorFrameTracker {
    enum Event: Equatable { case completedFrame, overflow }
    private enum State { case ground, escape, csi, string }
    private var state: State = .ground
    private var parameters: [UInt8] = []
    private var validCSI = true
    private var stringIsOSC = false
    private var synchronized = false
    private var armed = false
    private var bytes = 0
    private var frameStart: Int?
    private var frameHasText = false
    private var completed = false
    let maximumBytes: Int
    let minimumFrameBytes: Int

    init(maximumBytes: Int = 1 << 20, minimumFrameBytes: Int = 512) {
        self.maximumBytes = max(1, maximumBytes)
        self.minimumFrameBytes = max(1, minimumFrameBytes)
    }

    mutating func arm() {
        armed = true; bytes = 0; frameStart = nil; frameHasText = false; completed = false
    }

    mutating func disarm() {
        armed = false; bytes = 0; frameStart = nil; frameHasText = false; completed = false
    }

    mutating func observe(_ data: Data) -> Event? {
        var overflow = false
        // Most terminal bytes are plain text. Avoid a Swift byte walk when no
        // escape or control sequence can change the tracked lexical state.
        if state == .ground, data.range(of: Data([0x1b])) == nil {
            if armed {
                if data.count > maximumBytes - bytes { disarm(); return .overflow }
                bytes += data.count
                if frameStart != nil, data.contains(where: { $0 >= 0x20 && $0 != 0x7f }) { frameHasText = true }
            }
            return nil
        }
        for byte in data {
            if armed {
                if bytes == maximumBytes { disarm(); overflow = true }
                else { bytes += 1 }
            }
            // Ghostty 1.3.1 decodes UTF-8 in ground state, but handles C1
            // bytes through its VT table elsewhere. OSC overrides those
            // high-byte transitions as payload. DCS/APC/PM/SOS do not.
            if state != .ground, !(state == .string && stringIsOSC) {
                switch byte {
                case 0x9b:
                    parameters.removeAll(keepingCapacity: true); validCSI = true; state = .csi
                    continue
                case 0x9d: stringIsOSC = true; state = .string; continue
                case 0x90, 0x98, 0x9e, 0x9f: stringIsOSC = false; state = .string; continue
                case 0x80...0x8f, 0x91...0x97, 0x99, 0x9a, 0x9c: state = .ground; continue
                default: break
                }
            }
            switch state {
            case .ground:
                if byte == 0x1b { state = .escape }
                else if armed, frameStart != nil, byte >= 0x20, byte != 0x7f { frameHasText = true }
            case .escape:
                switch byte {
                case 0x5b: parameters.removeAll(keepingCapacity: true); validCSI = true; state = .csi
                case 0x5d, 0x50, 0x58, 0x5e, 0x5f: stringIsOSC = byte == 0x5d; state = .string
                case 0x1b: break
                case 0x63: synchronized = false; frameStart = nil; frameHasText = false; completed = false; state = .ground
                default: state = .ground
                }
            case .csi:
                if byte == 0x1b { state = .escape }
                else if byte == 0x18 || byte == 0x1a { state = .ground }
                else if (0x40...0x7e).contains(byte) {
                    if validCSI, (byte == 0x68 || byte == 0x6c), parameters.first == 0x3f,
                       parameters.dropFirst().allSatisfy({ (0x30...0x39).contains($0) || $0 == 0x3b }),
                       parameters.filter({ $0 == 0x3b }).count < 24,
                       parameters.dropFirst().split(separator: 0x3b).contains(where: { Array($0) == [0x32, 0x30, 0x32, 0x36] }) {
                        if byte == 0x68 {
                            if !synchronized, armed { frameStart = bytes; frameHasText = false }
                            synchronized = true
                        } else {
                            if synchronized, armed, frameHasText, let start = frameStart,
                               bytes - start >= minimumFrameBytes { completed = true }
                            synchronized = false; frameStart = nil; frameHasText = false
                        }
                    }
                    state = .ground
                } else if (0x30...0x3f).contains(byte), parameters.count < 64 {
                    parameters.append(byte)
                } else { validCSI = false }
            case .string:
                if byte == 0x18 || byte == 0x1a || (stringIsOSC && byte == 0x07) { state = .ground }
                else if byte == 0x1b { state = .escape }
            }
        }
        if overflow { return .overflow }
        guard armed, completed, !synchronized, state == .ground else { return nil }
        completed = false
        return .completedFrame
    }
}
