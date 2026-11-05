import Foundation
import CoreFoundation

/// Subscription limits are account data, independent of context tokens and session cost.
/// A reset passing invalidates the observation; it never implies a fresh 100% allowance.
struct RelaySubscriptionQuota: Equatable, Sendable {
    enum Provider: String, Sendable { case codex, claude }
    struct Window: Equatable, Identifiable, Sendable {
        let id: String
        let label: String
        let usedPercent: Double
        let durationMinutes: Int?
        let resetsAt: Date?
        var remainingPercent: Double { max(0, 100 - usedPercent) }
    }
    struct Credits: Equatable, Identifiable, Sendable {
        let id: String
        let label: String
        let balance: String?
        let hasCredits: Bool
        let unlimited: Bool
        var displayBalance: String {
            if unlimited { return "Unlimited" }
            if let balance, let decimal = Decimal(string: balance, locale: Locale(identifier: "en_US_POSIX")) {
                let formatter = NumberFormatter()
                formatter.numberStyle = .decimal
                formatter.maximumFractionDigits = 8
                formatter.locale = .current
                return (formatter.string(from: NSDecimalNumber(decimal: decimal)) ?? balance) + " credits"
            }
            return hasCredits ? "Available · balance unknown" : "No credits"
        }
    }
    enum Source: Int, Sendable { case sessionReport, accountAPI }
    var source: Source = .sessionReport
    var sourceLabel: String { source == .accountAPI ? "Account data" : "Session report" }
    let provider: Provider
    let observedAt: Date
    let windows: [Window]
    let credits: [Credits]
    var planDisplayName: String? {
        guard let planType, !planType.isEmpty else { return nil }
        if planType == "self_serve_business_prolite" { return "Business Pro Lite" }
        return planType.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ").capitalized
    }
    let planType: String?
    let availableResets: Int?
    var extraUsageEnabled: Bool? = nil
    var extraUsageUsed: String? = nil
    var extraUsageBalance: String? = nil

    init(provider: Provider, observedAt: Date, windows: [Window], credits: [Credits] = [],
         planType: String? = nil, availableResets: Int? = nil) {
        self.provider = provider; self.observedAt = observedAt; self.windows = windows
        self.credits = credits; self.planType = planType; self.availableResets = availableResets
    }

    static func preferred(_ first: Self?, _ second: Self, now: Date = Date()) -> Self {
        guard let first else { return second }
        let firstCurrent = first.observationIsCurrent(now: now)
        let secondCurrent = second.observationIsCurrent(now: now)
        if firstCurrent != secondCurrent { return secondCurrent ? second : first }
        // A recent account response includes all windows; session status can be partial.
        if firstCurrent, first.source != second.source {
            return second.source.rawValue > first.source.rawValue ? second : first
        }
        return second.observedAt > first.observedAt ? second : first
    }

    func observationIsCurrent(now: Date = Date(), maximumAge: TimeInterval = 300) -> Bool {
        let age = now.timeIntervalSince(observedAt)
        return age >= 0 && age <= maximumAge
    }

    func isCurrent(_ window: Window, now: Date = Date(), maximumAge: TimeInterval = 300) -> Bool {
        let age = now.timeIntervalSince(observedAt)
        return age >= 0 && age <= maximumAge && (window.resetsAt.map { $0 > now } ?? true)
    }

    static func claude(statusLine: Data, expectedSessionID: String, now: Date = Date()) throws -> Self {
        let input = try object(statusLine)
        guard !expectedSessionID.isEmpty, input["session_id"] as? String == expectedSessionID else {
            throw ParseError.identityMismatch
        }
        let limits = input["rate_limits"] as? [String: Any] ?? [:]
        var windows = [("five_hour", "5 hours", 300), ("seven_day", "7 days", 10_080),
                       ("seven_day_oauth_apps", "7 days · OAuth apps", 10_080),
                       ("seven_day_opus", "7 days · Opus", 10_080),
                       ("seven_day_sonnet", "7 days · Sonnet", 10_080),
                       ("seven_day_cowork", "7 days · Cowork", 10_080),
                       ("seven_day_omelette", "7 days · Omelette", 10_080)].compactMap {
            key, label, duration -> Window? in
            window(limits[key], id: key, label: label, duration: duration,
                   percentKey: "used_percentage", resetKey: "resets_at")
        }
        var seen = Set(windows.map(\.id))
        for item in (input["additional_limits"] as? [[String: Any]] ?? []).prefix(32) {
            guard let id = item["id"] as? String, id.count <= 80,
                  let label = item["label"] as? String, !label.isEmpty, label.count <= 80,
                  !label.unicodeScalars.contains(where: { $0.value < 32 }),
                  seen.insert(id).inserted else { continue }
            let duration = number(item["duration_minutes"]).flatMap { $0 == 10080 ? 10080 : nil }
            if let entry = window(item, id: id, label: (duration == 10080 ? "7 days · " : "") + label,
                                  duration: duration, percentKey: "used_percentage", resetKey: "resets_at") {
                windows.append(entry)
            }
        }
        var result = Self(provider: .claude, observedAt: now, windows: windows,
                          planType: input["plan_type"] as? String)
        if expectedSessionID == "account-usage" { result.source = .accountAPI }
        if let spend = input["spend"] as? [String: Any] {
            result.extraUsageEnabled = boolean(spend["enabled"])
            result.extraUsageUsed = money(spend["used"])
            result.extraUsageBalance = money(spend["balance"])
        }
        return result
    }

    private static func money(_ raw: Any?) -> String? {
        guard let value = raw as? [String: Any], let amount = number(value["amount_minor"]),
              abs(amount) <= 1e15, amount.rounded() == amount,
              let exponent = number(value["exponent"]), exponent >= 0, exponent <= 8,
              exponent.rounded() == exponent, let currency = value["currency"] as? String,
              currency.range(of: "^[A-Z]{3}$", options: .regularExpression) != nil else { return nil }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency; formatter.currencyCode = currency
        formatter.minimumFractionDigits = Int(exponent); formatter.maximumFractionDigits = Int(exponent)
        return formatter.string(from: NSNumber(value: amount / pow(10, exponent)))
    }

    static func codex(response: Data, now: Date = Date()) throws -> Self {
        let envelope = try object(response)
        let input = envelope["result"] as? [String: Any] ?? envelope["params"] as? [String: Any] ?? envelope
        // The multi-bucket view is authoritative even when empty. Never merge stale fallback data.
        var buckets = input["rateLimitsByLimitId"] as? [String: Any]
        if buckets == nil, let single = input["rateLimits"] as? [String: Any] {
            buckets = [single["limitId"] as? String ?? "codex": single]
        }
        var windows: [Window] = []
        var credits: [Credits] = []
        var planType: String?
        for key in (buckets ?? [:]).keys.sorted() {
            guard let bucket = buckets?[key] as? [String: Any] else { continue }
            let label = bucket["limitName"] as? String ?? key
            if let plan = bucket["planType"] as? String,
               plan.range(of: #"^[a-z0-9_-]{1,64}$"#, options: .regularExpression) != nil,
               planType == nil || key == "codex" { planType = plan }
            if let value = bucket["credits"] as? [String: Any],
               let hasCredits = boolean(value["hasCredits"]), let unlimited = boolean(value["unlimited"]) {
                let raw = value["balance"] as? String
                let balance = raw.flatMap { $0.range(of: #"^[0-9]{1,24}(\.[0-9]{1,8})?$"#, options: .regularExpression) != nil ? $0 : nil }
                credits.append(Credits(id: key, label: label, balance: balance, hasCredits: hasCredits, unlimited: unlimited))
            }
            for slot in ["primary", "secondary"] {
                guard let value = bucket[slot] as? [String: Any] else { continue }
                let duration = number(value["windowDurationMins"]).flatMap {
                    $0 > 0 && $0 <= 525_600 && $0.rounded() == $0 ? Int($0) : nil
                }
                let period = duration.map(durationLabel) ?? (slot == "primary" ? "Primary window" : "Secondary window")
                let windowLabel = key == "codex" ? period : label + " · " + period
                if let entry = window(value, id: key + ":" + slot, label: windowLabel,
                                      duration: duration, percentKey: "usedPercent", resetKey: "resetsAt") {
                    windows.append(entry)
                }
            }
        }
        let resets = (input["rateLimitResetCredits"] as? [String: Any]).flatMap {
            number($0["availableCount"]).flatMap { $0 >= 0 && $0 <= 1_000_000 && $0.rounded() == $0 ? Int($0) : nil }
        }
        var result = Self(provider: .codex, observedAt: now, windows: windows, credits: credits,
                          planType: planType, availableResets: resets)
        result.source = .accountAPI
        return result
    }

    private static func durationLabel(_ minutes: Int) -> String {
        if minutes % 1440 == 0 {
            let days = minutes / 1440
            return "\(days) " + (days == 1 ? "day" : "days")
        }
        if minutes % 60 == 0 {
            let hours = minutes / 60
            return "\(hours) " + (hours == 1 ? "hour" : "hours")
        }
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    enum ParseError: Error { case invalidPayload, identityMismatch }
    private static func object(_ data: Data) throws -> [String: Any] {
        guard data.count <= 1_048_576,
              let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ParseError.invalidPayload
        }
        return value
    }
    private static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber,
              CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }
    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
    private static func window(_ raw: Any?, id: String, label: String, duration: Int?,
                               percentKey: String, resetKey: String) -> Window? {
        guard let value = raw as? [String: Any], let used = number(value[percentKey]),
              used >= 0, used <= 100 else { return nil }
        let reset: Date?
        if let rawReset = value[resetKey], !(rawReset is NSNull) {
            guard let timestamp = number(rawReset), timestamp > 0, timestamp < 253_402_300_800 else { return nil }
            reset = Date(timeIntervalSince1970: timestamp)
        } else { reset = nil }
        return Window(id: id, label: label, usedPercent: used, durationMinutes: duration, resetsAt: reset)
    }
}
