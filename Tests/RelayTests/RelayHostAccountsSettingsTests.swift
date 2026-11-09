import Foundation
import AppKit
import SwiftUI
import Testing
@testable import Relay

private final class AccountSettingsFrameWriter: RelayFrameWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [RelayWireFrame] = []
    func write(type: RelayWireType, payload: Data) throws { append(type, payload) }
    func writeAsync(type: RelayWireType, payload: Data) { append(type, payload) }
    private func append(_ type: RelayWireType, _ payload: Data) {
        lock.lock(); recorded.append(.init(type: type, payload: payload)); lock.unlock()
    }
    var frames: [RelayWireFrame] {
        lock.lock(); defer { lock.unlock() }; return recorded
    }
}
private final class AccountSettingsResult: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<Data, Error>?
    let ready = DispatchSemaphore(value: 0)
    func accept(_ result: Result<Data, Error>) {
        lock.lock(); value = result; lock.unlock(); ready.signal()
    }
    var result: Result<Data, Error>? {
        lock.lock(); defer { lock.unlock() }; return value
    }
}

@Suite(.serialized)
struct RelayHostAccountsSettingsTests {
    private func account(_ id: String, provider: String = "anthropic_api") -> RelayHostRotationTextRPC.Account {
        var value = RelayHostRotationTextRPC.Account()
        value.id = id; value.name = "Owned fixture"; value.provider = provider
        return value
    }

    @Test func addingAccountPreservesHostSettingsAndOtherProfiles() throws {
        var settings = RelayHostRotationTextRPC.Settings()
        settings.providers = ["codex_account"]
        settings.dailyLimitMicrousd = 2_000_000
        settings.monthlyLimitMicrousd = 9_000_000
        settings.maxRequestsPerDay = 11
        settings.codexModel = "owned-model"
        settings.codexPath = "/owned/bin/codex"
        let existing = account("11111111111111111111111111111111", provider: "codex_account")
        settings.accounts = [existing]
        let candidate = account("22222222222222222222222222222222")
        let merged = try settings.mergingAccount(candidate, replacing: nil)
        #expect(!merged.enabled)
        #expect(merged.dailyLimitMicrousd == settings.dailyLimitMicrousd)
        #expect(merged.monthlyLimitMicrousd == settings.monthlyLimitMicrousd)
        #expect(merged.maxRequestsPerDay == settings.maxRequestsPerDay)
        #expect(merged.codexModel == settings.codexModel)
        #expect(merged.codexPath == settings.codexPath)
        #expect(merged.accounts == [existing, candidate])
        #expect(merged.providers == ["codex_account", "anthropic_api"])
    }

    @Test func staleEditorCannotOverwriteAChangedAccount() {
        let original = account("11111111111111111111111111111111")
        var newer = original; newer.name = "Saved elsewhere"
        var candidate = original; candidate.name = "Stale editor"
        var settings = RelayHostRotationTextRPC.Settings(); settings.accounts = [newer]
        #expect(throws: RelayHostRotationRPC.Failure.self) {
            try settings.mergingAccount(candidate, replacing: original)
        }
    }

    @Test func deletedProfileCannotBeRecreatedByAnOldEditor() {
        let original = account("11111111111111111111111111111111")
        var settings = RelayHostRotationTextRPC.Settings(); settings.accounts = []
        #expect(throws: RelayHostRotationRPC.Failure.self) {
            try settings.mergingAccount(original, replacing: original)
        }
    }

    @Test func confirmedSameAccountCanBeReconciledWithoutChangingSettings() throws {
        let original = account("11111111111111111111111111111111")
        var saved = original; saved.name = "Confirmed"
        var settings = RelayHostRotationTextRPC.Settings(); settings.accounts = [saved]
        #expect(try settings.mergingAccount(saved, replacing: original) == settings)
    }

    @Test func accountPayloadIsRefusedBeforeWriteOnOlderNode() throws {
        let writer = AccountSettingsFrameWriter()
        let result = AccountSettingsResult()
        let connection = RelayNodeConnection(profile: .init(name: "Accounts fixture", host: "owned.invalid"),
            attachedFrameWriter: writer, attachedGeneration: 3, protocolReady: false)
        let payload = Data(#"{"request_id":"owned-account-check","operation":"host_accounts","host_accounts":{"request":{"operation":"text_credential_save","credential_secret":"owned-invalid-placeholder"}}}"#.utf8)
        connection.request(payload: payload, requiredCapability: "host_accounts_v1") { result.accept($0) }
        connection.receiveAttachedFrame(.init(type: .status,
            payload: Data(#"{"state":"ready","capabilities":["node_mux_v1","host_rpc_v1"]}"#.utf8)), generation: 3)
        #expect(result.ready.wait(timeout: .now() + 2) == .success)
        #expect(writer.frames.filter { $0.type == .hostRequest }.isEmpty)
        let received = try #require(result.result)
        if case .failure(let error) = received, case .some(.unsupported) = error as? RelayHostRPCError {
            #expect(true)
        } else { Issue.record("Expected unsupported capability refusal") }
    }

    @Test func accountRequestNeedsNoPaneAndIsNotReplayed() throws {
        let writer = AccountSettingsFrameWriter()
        let result = AccountSettingsResult()
        let connection = RelayNodeConnection(profile: .init(name: "Accounts fixture", host: "owned.invalid"),
            attachedFrameWriter: writer, attachedGeneration: 2, protocolReady: false)
        let payload = Data(#"{"request_id":"owned-account-status","operation":"host_accounts","host_accounts":{"request":{"operation":"text_status"}}}"#.utf8)
        connection.request(payload: payload, requiredCapability: "host_accounts_v1") { result.accept($0) }
        let status = RelayWireFrame(type: .status,
            payload: Data(#"{"state":"ready","capabilities":["node_mux_v1","host_rpc_v1","host_accounts_v1"]}"#.utf8))
        connection.receiveAttachedFrame(status, generation: 2)
        connection.receiveAttachedFrame(status, generation: 2)
        let requests = writer.frames.filter { $0.type == .hostRequest }
        #expect(requests.count == 1)
        #expect(requests.first?.payload == payload)
        let object = try #require(try JSONSerialization.jsonObject(with: payload) as? [String: Any])
        #expect(object["session_id"] == nil && object["job_id"] == nil)
        connection.receiveAttachedFrame(.init(type: .hostResponse,
            payload: Data(#"{"request_id":"owned-account-status","result":{"ok":true}}"#.utf8)), generation: 2)
        #expect(result.ready.wait(timeout: .now() + 2) == .success)
    }

    @Test func intelligenceAvailabilityAndEmptyStatesAreExplicit() {
        #expect(RelayIntelligenceSettingsCopy.availabilityTitle("available") == "Available")
        #expect(RelayIntelligenceSettingsCopy.availabilityTitle("unavailable(reason: modelNotReady)") == "Unavailable")
        #expect(RelayIntelligenceSettingsCopy.availabilityDetail("unavailable(reason: modelNotReady)").contains("preparing"))
        #expect(RelayIntelligenceSettingsCopy.activityDetail(enabled: true, summaries: false, search: false).contains("both off"))
        #expect(RelayIntelligenceSettingsCopy.activityDetail(enabled: false, summaries: true, search: true).contains("intelligence is off"))
    }
}


extension RelayHostAccountsSettingsTests {
    @MainActor @Test func renderNativeSettingsWithoutScreenCapture() async throws {
        guard let path = ProcessInfo.processInfo.environment["RELAY_SETTINGS_RENDER_DIRECTORY"] else { return }
        #expect(RelayStateProfile.isIsolated)
        #expect(RelayStateProfile.configurationError == nil)
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        application.appearance = NSAppearance(named: .darkAqua)
        let preferences = RelayPreferences.shared
        preferences.intelligenceEnabled = true
        preferences.automaticAgentSummaries = false
        preferences.semanticAgentSearch = false
        preferences.decisionModelPath = ""
        preferences.decisionModelSHA256 = ""
        defer { RelaySettingsNavigation.shared.section = "general" }
        for section in ["general", "intelligence", "keyboard", "connections", "clients", "plugins", "advanced"] {
            RelaySettingsNavigation.shared.section = section
            try await render(RelaySettingsView(), size: .init(width: 940, height: 680),
                             to: directory.appendingPathComponent(section + ".png"))
        }
        var account = account("33333333333333333333333333333333")
        account.name = "Claude API"; account.dailyLimitMicrousd = 1_000_000
        account.monthlyLimitMicrousd = 5_000_000; account.maxRequestsPerDay = 10
        account.billingGroup = "owned-fixture"
        let editor = RelayHostRotationAccountEditor(
            service: .init(profile: .init(name: "Owned fixture", host: "owned.invalid")),
            account: account, onSave: { _ in }, onConfirmed: { _ in }, onCancel: {})
        try await render(editor, size: .init(width: 540, height: 720),
                         to: directory.appendingPathComponent("account-editor.png"))
    }

    @MainActor private func render<Content: View>(_ view: Content, size: NSSize, to url: URL) async throws {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        defer { window.close() }
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(250))
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(png.count > 5_000)
        try png.write(to: url, options: .withoutOverwriting)
    }
}

extension RelayHostAccountsSettingsTests {
    @Test func configureEnvelopeRequiresFreshHostConfigurationIdentity() throws {
        let request = RelayHostRotationTextRPC.Request(operation: .configure,
            id: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", settings: .init())
        #expect(throws: RelayHostRotationRPC.Failure.self) {
            try RelayHostRotationTextRPC.hostEnvelope(request)
        }
        let data = try RelayHostRotationTextRPC.hostEnvelope(request,
            expectedConfigurationID: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
        let envelope = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let forward = try #require(envelope["host_accounts"] as? [String: Any])
        #expect(forward["expected_configuration_id"] as? String == "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
        #expect(forward["pane_id"] == nil && forward["client_id"] == nil)
        #expect(throws: RelayHostRotationRPC.Failure.self) {
            try RelayHostRotationTextRPC.hostEnvelope(.init(operation: .status), expectedConfigurationID: "")
        }
        #expect(throws: RelayHostRotationRPC.Failure.self) {
            try RelayHostRotationTextRPC.hostEnvelope(request, expectedConfigurationID: "invalid")
        }
    }
}
