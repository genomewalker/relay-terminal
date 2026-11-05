import Foundation

/// Call under the diagnostics lock. Each five-second window admits a small
/// burst per pane/event and a bounded total across all panes.
struct RelayInputDiagnosticSampler {
    /// Events that repeat while nothing changes, with the interval between
    /// samples per pane. A reconnecting pane restores its remote state every
    /// few seconds; across many panes that filled the journal in minutes.
    static let repeatIntervals: [String: TimeInterval] = ["prompt-history-suspend": 60]

    private var windowStart: TimeInterval?
    private var counts: [String: Int] = [:]
    private var admitted = 0
    private var lastRepeat: [String: TimeInterval] = [:]
    mutating func admit(paneID: String, name: String, now: TimeInterval) -> Bool {
        if windowStart == nil || now < windowStart! || now - windowStart! >= 5 {
            windowStart = now
            counts.removeAll(keepingCapacity: true)
            admitted = 0
        }
        if let interval = Self.repeatIntervals[name] {
            let key = paneID + ":" + name
            if let last = lastRepeat[key], now >= last, now - last < interval { return false }
            guard admitted < 128 else { return false }
            if lastRepeat.count >= 1_024 { lastRepeat = lastRepeat.filter { now - $0.value < interval } }
            lastRepeat[key] = now
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
