import Foundation

enum RelayIntelligenceSettingsCopy {
    static func availabilityTitle(_ value: String) -> String {
        if value == "checking" { return "Checking…" }
        if value == "available" { return "Available" }
        if value == "unsupported" { return "Requires macOS 26" }
        return "Unavailable"
    }

    static func availabilityDetail(_ value: String) -> String {
        if value == "checking" { return "Checking the system model without making a model request." }
        if value == "available" { return "Ready on this Mac. Enable the features you want below." }
        if value == "unsupported" { return "On-device model features need macOS 26 or later and a supported Mac." }
        if value.contains("appleIntelligenceNotEnabled") { return "Enable Apple Intelligence in macOS System Settings to use the system model." }
        if value.contains("modelNotReady") { return "The system model is still preparing. Check again after macOS finishes downloading it." }
        if value.contains("deviceNotEligible") { return "This Mac does not support Apple’s on-device model. Your activity history and ordinary search still work." }
        return "The system model is not available right now. Your activity history and ordinary search still work."
    }

    static func activityDetail(enabled: Bool, summaries: Bool, search: Bool) -> String {
        guard enabled else { return "On-device intelligence is off. Enable it above to use these optional features." }
        if !summaries && !search { return "Summaries and search by meaning are both off. Enable either above to see its results in agent activity." }
        if summaries && search { return "Results appear as agents complete work and activity becomes available." }
        if summaries { return "Summaries are on; search by meaning is off. Summaries appear after completed work." }
        return "Search by meaning is on; summaries are off. Search becomes useful as agent activity is recorded."
    }
}
