import AppKit
import Carbon.HIToolbox
import Combine

/// A system-wide shortcut for the Relay assistant. Space is not representable
/// by RelayKeyBinding (which records printable keys for menu equivalents), so
/// the global hotkey stores its virtual key code directly.
struct RelayAssistantHotkey: Codable, Equatable, Hashable, Sendable {
    let keyCode: UInt32
    let control: Bool
    let option: Bool
    let command: Bool
    let shift: Bool

    /// ⌥Space and ⌃⌥Space belong to ChatGPT, Raycast, Alfred and macOS input
    /// source switching. A Command chord is never delivered to terminal
    /// programs, so it cannot shadow a key an agent or shell expects.
    static let defaultValue = Self(keyCode: UInt32(kVK_ANSI_R), control: true, option: true, command: true, shift: false)
    /// The phase 1 default, saved automatically by earlier builds.
    static let legacyDefault = Self(keyCode: UInt32(kVK_Space), control: true, option: true, command: false, shift: false)
    static let presets: [Self] = [
        defaultValue,
        Self(keyCode: UInt32(kVK_ANSI_A), control: true, option: true, command: true, shift: false),
        Self(keyCode: UInt32(kVK_Space), control: true, option: true, command: true, shift: false),
        Self(keyCode: UInt32(kVK_Space), control: true, option: false, command: true, shift: true),
        legacyDefault,
    ]

    var valid: Bool { keyCode <= 0x7F && (control || option || command) }

    var carbonModifiers: UInt32 {
        var value: UInt32 = 0
        if control { value |= UInt32(controlKey) }
        if option { value |= UInt32(optionKey) }
        if command { value |= UInt32(cmdKey) }
        if shift { value |= UInt32(shiftKey) }
        return value
    }

    var displayName: String {
        var text = (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "")
        switch Int(keyCode) {
        case kVK_Space: text += "Space"
        case kVK_ANSI_A: text += "A"
        case kVK_ANSI_R: text += "R"
        default: text += "key \(keyCode)"
        }
        return text
    }
}

enum RelayAssistantHotkeyStorage {
    static let enabledKey = "relay.settings.assistant-hotkey-enabled"
    static let hotkeyKey = "relay.settings.assistant-hotkey.v2"
    static let legacyHotkeyKey = "relay.settings.assistant-hotkey.v1"

    static func load(from defaults: UserDefaults) -> (enabled: Bool, hotkey: RelayAssistantHotkey) {
        let enabled = defaults.object(forKey: enabledKey) as? Bool ?? true
        func decode(_ key: String) -> RelayAssistantHotkey? {
            defaults.data(forKey: key)
                .flatMap { try? JSONDecoder().decode(RelayAssistantHotkey.self, from: $0) }
                .flatMap { $0.valid ? $0 : nil }
        }
        // Earlier builds saved their ⌃⌥Space default whether or not it was
        // chosen; only a different saved shortcut was the user's choice.
        let legacy = decode(legacyHotkeyKey).flatMap { $0 == .legacyDefault ? nil : $0 }
        return (enabled, decode(hotkeyKey) ?? legacy ?? .defaultValue)
    }

    static func save(enabled: Bool, hotkey: RelayAssistantHotkey, to defaults: UserDefaults) {
        defaults.set(enabled, forKey: enabledKey)
        if let data = try? JSONEncoder().encode(hotkey) { defaults.set(data, forKey: hotkeyKey) }
    }
}

/// Owners Carbon's exclusive registration cannot see: macOS symbolic hotkeys
/// are consumed by the window server, and launchers such as ChatGPT capture
/// keys with event taps. Reads only public APIs and running-app identity;
/// never another app's private preferences.
enum RelayAssistantHotkeyConflicts {
    struct SymbolicHotkey: Equatable {
        let keyCode: Int
        let modifiers: UInt32
        let enabled: Bool
    }

    /// Default global shortcuts of launchers, checked only while they run.
    static let launchers: [(bundleID: String, name: String, hotkeys: [RelayAssistantHotkey])] = {
        func space(control: Bool = false, option: Bool = false, command: Bool = false) -> RelayAssistantHotkey {
            RelayAssistantHotkey(keyCode: UInt32(kVK_Space), control: control, option: option, command: command, shift: false)
        }
        return [
            ("com.openai.chat", "ChatGPT", [space(option: true), space(control: true, option: true)]),
            ("com.raycast.macos", "Raycast", [space(option: true), space(command: true)]),
            ("com.runningwithcrayons.Alfred", "Alfred", [space(option: true), space(command: true)]),
        ]
    }()

    /// Carbon modifier bits for either encoding the system uses
    /// (Carbon event modifiers, or NSEvent device-independent flags).
    static func carbonModifiers(_ value: UInt32) -> UInt32 {
        guard value & 0x1E_0000 != 0 else { return value & UInt32(cmdKey | shiftKey | optionKey | controlKey) }
        var result: UInt32 = 0
        if value & (1 << 17) != 0 { result |= UInt32(shiftKey) }
        if value & (1 << 18) != 0 { result |= UInt32(controlKey) }
        if value & (1 << 19) != 0 { result |= UInt32(optionKey) }
        if value & (1 << 20) != 0 { result |= UInt32(cmdKey) }
        return result
    }

    static func systemOwns(_ hotkey: RelayAssistantHotkey, in entries: [SymbolicHotkey]) -> Bool {
        entries.contains {
            $0.enabled && $0.keyCode == Int(hotkey.keyCode) && carbonModifiers($0.modifiers) == hotkey.carbonModifiers
        }
    }

    static func launcherOwner(_ hotkey: RelayAssistantHotkey, running bundleIDs: Set<String>) -> String? {
        launchers.first { bundleIDs.contains($0.bundleID) && $0.hotkeys.contains(hotkey) }?.name
    }

    static func systemHotkeys() -> [SymbolicHotkey] {
        var array: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&array) == noErr, let entries = array?.takeRetainedValue() as? [[String: Any]] else { return [] }
        return entries.compactMap { entry in
            guard let code = (entry[kHISymbolicHotKeyCode as String] as? NSNumber)?.intValue,
                  let modifiers = (entry[kHISymbolicHotKeyModifiers as String] as? NSNumber)?.uint32Value else { return nil }
            let enabled = (entry[kHISymbolicHotKeyEnabled as String] as? NSNumber)?.boolValue ?? true
            return SymbolicHotkey(keyCode: code, modifiers: modifiers, enabled: enabled)
        }
    }

    /// The owner that would receive this shortcut before Relay, if known.
    @MainActor static func owner(of hotkey: RelayAssistantHotkey) -> (name: String, certain: Bool)? {
        if systemOwns(hotkey, in: systemHotkeys()) { return ("a macOS system shortcut", true) }
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        return launcherOwner(hotkey, running: running).map { ($0, false) }
    }
}

private let relayAssistantHotkeySignature: OSType = 0x524C_4153 // "RLAS"

/// Toolbar, menu-bar item and global hotkey all call the same toggle.
@MainActor final class RelayAssistantEntryPoints: ObservableObject {
    enum HotkeyStatus: Equatable {
        case disabled
        case registered(String)
        case conflict(String, owner: String?)
        /// Registered, but a running app that usually captures it first.
        case likelyConflict(String, owner: String)
        case failed(String, OSStatus)

        var notice: String? {
            switch self {
            case .conflict(let name, let owner?): "\(name) is used by \(owner), so the Relay assistant shortcut is not active. Choose another shortcut in Settings › Intelligence."
            case .conflict(let name, nil): "\(name) is already used by another app, so the Relay assistant shortcut is not active. Choose another shortcut in Settings › Intelligence."
            case .likelyConflict(let name, let owner): "\(name) is also \(owner)'s shortcut, and \(owner) usually receives it first. Choose another shortcut in Settings › Intelligence, or use Test shortcut."
            case .failed(let name, let status): "The Relay assistant shortcut \(name) could not be registered (error \(status)). Choose another shortcut in Settings › Intelligence."
            default: nil
            }
        }
    }

    /// Result of pressing the shortcut while Settings waits for it.
    enum HotkeyTest: Equatable {
        case idle
        case waiting(String)
        case received(String)
        case taken(String, by: String)
        case notReceived(String)

        var message: String? {
            switch self {
            case .idle: nil
            case .waiting(let name): "Press \(name) now…"
            case .received(let name): "\(name) works: Relay received it."
            case .taken(let name, let app): "\(name) opened \(app) instead of Relay. Choose another shortcut."
            case .notReceived(let name): "Relay did not receive \(name). Another app or a system shortcut may own it; choose another shortcut."
            }
        }
    }

    static let shared = RelayAssistantEntryPoints()
    @Published private(set) var hotkeyStatus: HotkeyStatus = .disabled
    @Published private(set) var hotkeyTest: HotkeyTest = .idle
    var testingHotkey: Bool { if case .waiting = hotkeyTest { true } else { false } }
    private var testObserver: NSObjectProtocol?
    private var testTimeout: Task<Void, Never>?

    private var toggle: (() -> Void)?
    private var statusItem: NSStatusItem?
    private var hotkeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var subscription: AnyCancellable?
    private var notifiedConflict: RelayAssistantHotkey?

    func start(toggle: @escaping () -> Void) {
        guard !RelayLaunchMode.isRunningTests, self.toggle == nil else { return }
        self.toggle = toggle
        installStatusItem()
        installHandler()
        let preferences = RelayPreferences.shared
        subscription = preferences.$assistantHotkeyEnabled.combineLatest(preferences.$assistantHotkey)
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled, hotkey in
                MainActor.assumeIsolated { self?.register(enabled: enabled, hotkey: hotkey) }
            }
    }

    func stop() {
        subscription = nil
        unregister()
        if let handlerRef { RemoveEventHandler(handlerRef) }
        handlerRef = nil
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
        toggle = nil
    }

    func activateAndToggle() {
        NSApp.activate(ignoringOtherApps: true)
        toggle?()
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Relay assistant")
            button.toolTip = "Relay assistant"
            button.target = self
            button.action = #selector(statusItemClicked)
            button.setAccessibilityIdentifier("relay.assistant.status-item")
        }
        statusItem = item
    }

    @objc private func statusItemClicked() { activateAndToggle() }

    private func installHandler() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard status == noErr, identifier.signature == relayAssistantHotkeySignature else {
                return OSStatus(eventNotHandledErr)
            }
            let owner = Unmanaged<RelayAssistantEntryPoints>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { MainActor.assumeIsolated { owner.hotkeyPressed() } }
            return noErr
        }, 1, &type, context, &handlerRef)
    }

    private func hotkeyPressed() {
        if case .waiting(let name) = hotkeyTest {
            finishTest(.received(name))
        } else {
            activateAndToggle()
        }
    }

    /// Waits a few seconds for the shortcut. Relay receiving it proves
    /// ownership; another app activating instead names the thief.
    func testHotkey() {
        let preferences = RelayPreferences.shared
        let name = preferences.assistantHotkey.displayName
        guard preferences.assistantHotkeyEnabled else { return }
        if case .conflict = hotkeyStatus { finishTest(.notReceived(name)); return }
        finishTest(.waiting(name))
        let ownBundle = Bundle.main.bundleIdentifier
        testObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard let app, app.bundleIdentifier != ownBundle else { return }
            let thief = app.localizedName ?? app.bundleIdentifier ?? "another app"
            MainActor.assumeIsolated {
                guard let self, case .waiting(let name) = self.hotkeyTest else { return }
                self.finishTest(.taken(name, by: thief))
            }
        }
        testTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled, let self, case .waiting(let name) = self.hotkeyTest else { return }
            self.finishTest(.notReceived(name))
        }
    }

    private func finishTest(_ result: HotkeyTest) {
        if let testObserver { NSWorkspace.shared.notificationCenter.removeObserver(testObserver) }
        testObserver = nil
        if case .waiting = result {} else { testTimeout?.cancel(); testTimeout = nil }
        hotkeyTest = result
        if case .taken(let name, let app) = result {
            RelayDiagnostics.shared.record(category: "assistant", name: "hotkey-taken", details: ["owner": app])
            hotkeyStatus = .likelyConflict(name, owner: app)
            updateStatusItem()
        }
    }

    private func unregister() {
        if let hotkeyRef { UnregisterEventHotKey(hotkeyRef) }
        hotkeyRef = nil
    }

    private func register(enabled: Bool, hotkey: RelayAssistantHotkey) {
        unregister()
        hotkeyTest = .idle
        guard enabled, hotkey.valid else { hotkeyStatus = .disabled; updateStatusItem(); return }
        let owner = RelayAssistantHotkeyConflicts.owner(of: hotkey)
        if let owner, owner.certain {
            // The window server consumes system shortcuts before any app.
            hotkeyStatus = .conflict(hotkey.displayName, owner: owner.name)
            RelayDiagnostics.shared.record(category: "assistant", name: "hotkey-unavailable",
                                           details: ["owner": owner.name])
            if notifiedConflict != hotkey { notifiedConflict = hotkey; presentNotice() }
            updateStatusItem()
            return
        }
        var reference: EventHotKeyRef?
        // Exclusive: fail visibly instead of sharing a combination another app owns.
        let status = RegisterEventHotKey(hotkey.keyCode, hotkey.carbonModifiers,
            EventHotKeyID(signature: relayAssistantHotkeySignature, id: 1), GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive), &reference)
        if status == noErr, let reference {
            hotkeyRef = reference
            if let owner {
                hotkeyStatus = .likelyConflict(hotkey.displayName, owner: owner.name)
                if notifiedConflict != hotkey { notifiedConflict = hotkey; presentNotice() }
            } else {
                hotkeyStatus = .registered(hotkey.displayName)
                notifiedConflict = nil
            }
        } else {
            hotkeyStatus = status == OSStatus(eventHotKeyExistsErr)
                ? .conflict(hotkey.displayName, owner: nil) : .failed(hotkey.displayName, status)
            RelayDiagnostics.shared.record(category: "assistant", name: "hotkey-unavailable",
                                           details: ["status": String(status)])
            if notifiedConflict != hotkey {
                notifiedConflict = hotkey
                presentNotice()
            }
        }
        updateStatusItem()
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        switch hotkeyStatus {
        case .registered(let name): button.toolTip = "Relay assistant · " + name
        case .likelyConflict(let name, let owner): button.toolTip = "Relay assistant · \(name) (may open \(owner))"
        case .disabled: button.toolTip = "Relay assistant"
        default: button.toolTip = "Relay assistant · shortcut unavailable"
        }
    }

    /// A visible, non-blocking notice; never a silent failure.
    private func presentNotice() {
        guard let notice = hotkeyStatus.notice else { return }
        Task { @MainActor in
            let alert = RelayTheme.alert()
            if case .likelyConflict = hotkeyStatus {
                alert.messageText = "Relay assistant shortcut may not work"
            } else {
                alert.messageText = "Relay assistant shortcut unavailable"
            }
            alert.informativeText = notice
            alert.addButton(withTitle: "OK")
            if let window = NSApp.windows.first(where: { $0.identifier == .relayWorkspaceWindow && $0.isVisible }) {
                alert.beginSheetModal(for: window)
            } else {
                alert.runModal()
            }
        }
    }
}
