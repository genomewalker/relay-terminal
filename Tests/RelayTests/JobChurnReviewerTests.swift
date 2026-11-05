import Foundation
import Testing
@testable import Relay

@Suite("Job churn independent review")
@MainActor
struct JobChurnReviewerTests {
    @Test("A reconnect during the caller-list read cannot certify that policy was imported on the new transport")
    func attachCacheRequiresImportOnTheCachedIncarnation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("relay-churn-reconnect-review-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let control = RelayCallerControl(directory: directory)
        _ = try await control.register(label: "Fixture", thread: nil)
        let profile = ConnectionProfile(name: "review", kind: .ssh, host: "review.invalid", backend: .relay)
        var incarnation = "transport/1"
        var imports: [String] = []
        var reconnected = false
        control.transportIncarnation = { _ in incarnation }
        control.policyTransport = { _, packet in
            let operation = packet["operation"] as? String ?? ""
            if operation == "caller_policy_import" { imports.append(incarnation) }
            if operation == "caller_list" {
                // The list request reconnects to a new helper with no imported callers.
                if !reconnected { incarnation = "transport/2"; reconnected = true }
                return ["authority": "relayd", "callers": []]
            }
            return ["authority": "relayd"]
        }
        try await control.attachDaemon(profile: profile)
        try await control.attachDaemon(profile: profile)
        #expect(imports.contains("transport/2"), "new transport was cached as attached without importing its policy: \(imports)")
    }
}
