import Foundation

/// Call under the diagnostics lock. Each five-second window admits a small
/// burst per pane/event and a bounded total across all panes.
struct RelayInputDiagnosticSampler {
    private var windowStart: TimeInterval?
    private var counts: [String: Int] = [:]
    private var admitted = 0
    mutating func admit(paneID: String, name: String, now: TimeInterval) -> Bool {
        if windowStart == nil || now < windowStart! || now - windowStart! >= 5 {
            windowStart = now
            counts.removeAll(keepingCapacity: true)
            admitted = 0
        }
        guard admitted < 128 else { return false }
        let key = paneID + ":" + name
        let count = counts[key, default: 0]
        guard count < 4 else { return false }
        counts[key] = count + 1
        admitted += 1
        return true
    }
}
