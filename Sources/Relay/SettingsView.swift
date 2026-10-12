import SwiftUI
import AppKit

struct RelaySettingsView: View {
    @ObservedObject private var preferences = RelayPreferences.shared
    @ObservedObject private var navigation = RelaySettingsNavigation.shared
    @State private var showingKeyBindings = false
    @State private var showingPlugins = false
    @State private var showingCallers = false
    @State private var terminfoStatus = RelayTerminfo.status
    @State private var intelligenceAvailability = "checking"
    @State private var decisionModelStatus: String?

    private let sections: [(id: String, title: String, icon: String)] = [
        ("general", "Appearance", "paintbrush"),
        ("keyboard", "Keyboard", "keyboard"),
        ("accounts", "Accounts", "person.crop.circle"),
        ("intelligence", "Intelligence", "sparkles"),
        ("connections", "Connections", "server.rack"),
        ("clients", "Clients", "person.2"),
        ("plugins", "Plugins", "puzzlepiece.extension"),
        ("advanced", "Advanced", "gearshape.2")
    ]

    private var selectedTitle: String {
        sections.first(where: { $0.id == navigation.section })?.title ?? "Appearance"
    }
    private var selectedDescription: String {
        switch navigation.section {
        case "keyboard": "Customize shortcuts for sessions, tabs and panes."
        case "accounts": "Manage accounts shared by every tab on a host."
        case "intelligence": "Optional features that use models on this Mac."
        case "connections": "Manage Relay helpers and remote sessions."
        case "clients": "Control which clients can work with Relay."
        case "plugins": "Manage extensions for your workspace."
        case "advanced": "Terminal compatibility and diagnostics."
        default: "Choose how your terminal and workspace look."
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Settings")
                    .font(RelayTheme.font(size: 17, weight: .semibold))
                    .padding(.horizontal, 12).padding(.top, 12)
                VStack(spacing: 4) {
                    ForEach(sections, id: \.id) { section in
                        Button { navigation.section = section.id } label: {
                            Label(section.title, systemImage: section.icon)
                                .font(RelayTheme.font(size: 13, weight: .medium))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12).padding(.vertical, 10)
                                .contentShape(Rectangle())
                                .background(navigation.section == section.id ? RelayTheme.blue.opacity(0.15) : .clear,
                                    in: RoundedRectangle(cornerRadius: 8))
                                .foregroundStyle(navigation.section == section.id ? RelayTheme.blue : RelayTheme.text)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("relay.settings.section." + section.id)
                        .accessibilityAddTraits(navigation.section == section.id ? .isSelected : [])
                    }
                }
                Spacer()
                Text("Relay")
                    .font(RelayTheme.font(size: 11))
                    .foregroundStyle(RelayTheme.textMuted)
                    .padding(12)
            }
            .padding(12).frame(width: 176).background(RelayTheme.sidebar)
            Divider().overlay(RelayTheme.line.opacity(0.45))
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(selectedTitle).font(RelayTheme.font(size: 22, weight: .semibold))
                    Text(selectedDescription).font(RelayTheme.font(size: 13))
                        .foregroundStyle(RelayTheme.textMuted)
                }
                .padding(26)
                Divider().overlay(RelayTheme.line.opacity(0.4))
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) { sectionContent }
                        .padding(26).frame(maxWidth: .infinity, alignment: .leading)
                }
                if navigation.section != "accounts" {
                    Text("Preferences apply immediately.")
                        .font(RelayTheme.font(size: 11))
                        .foregroundStyle(RelayTheme.textMuted)
                        .padding(.horizontal, 26).padding(.vertical, 12)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: 940, height: 680)
        .foregroundStyle(RelayTheme.text)
        .background(RelayTheme.canvas)
        .background(RelayStandardWindowMarker().frame(width: 0, height: 0))
        .relaySurface()
        .sheet(isPresented: $showingKeyBindings) { RelayKeyBindingsView() }
        .sheet(isPresented: $showingPlugins) { RelayPluginSettingsView() }
        .sheet(isPresented: $showingCallers) { RelayCallerManagementView() }
        .onAppear { terminfoStatus = RelayTerminfo.status }
    }

    @ViewBuilder private var sectionContent: some View {
        switch navigation.section {
        case "accounts": RelayHostAccountsSettingsView()
        case "keyboard": keyboardSettings
        case "intelligence": intelligenceSettings
        case "connections": connectionsSettings
        case "clients": clientSettings
        case "plugins": pluginSettings
        case "advanced": advancedSettings
        default: appearanceSettings
        }
    }

    private var appearanceSettings: some View {
        VStack(alignment: .leading, spacing: 22) {
HStack(alignment: .top, spacing: 22) {
                settingSection("Terminal") {
                    TextField("Font family", text: $preferences.fontFamily)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, RelayTheme.spacing(10))
                        .frame(height: 32)
                        .background(RelayTheme.elevated, in: RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(8), style: .continuous))
                    if preferences.isUsingFontFallback {
                        Text("Font not installed — using Menlo")
                            .font(RelayTheme.font(size: 11))
                            .foregroundStyle(RelayTheme.coral)
                    }
                    valueSlider("Size", value: $preferences.fontSize, range: 9...24, suffix: "pt")
                    valueSlider("Padding", value: $preferences.terminalPadding, range: 0...20, suffix: "px")
                    Toggle("Blink cursor", isOn: $preferences.cursorBlink)
                }
                    .frame(maxWidth: .infinity)
                preview.frame(width: 260)
            }
settingSection("Workspace") {
                    Picker("Palette", selection: $preferences.palette) {
                        ForEach(RelayTerminalPalette.allCases) { palette in
                            Text(palette.label).tag(palette)
                        }
                    }
                    .pickerStyle(.segmented)
                    Toggle("Compact interface", isOn: $preferences.compactInterface)
                    Toggle("Hide navigator in full screen", isOn: $preferences.hideSidebarInFullScreen)
                }
settingSection("Images") {
                    Toggle("Show images generated by agents", isOn: $preferences.showArtifactPreviews)
                    Picker("Presentation", selection: $preferences.artifactPresentation) {
                        ForEach(RelayArtifactPresentation.allCases) { presentation in
                            Text(presentation.label).tag(presentation)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(!preferences.showArtifactPreviews)
                    Text("Relay securely fetches image files referenced by Codex and Claude from the connected node.")
                        .font(RelayTheme.font(size: 11))
                        .foregroundStyle(RelayTheme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
        }
    }
    private var keyboardSettings: some View { settingSection("Keyboard") {
                    Button {
                        showingKeyBindings = true
                    } label: {
                        HStack(spacing: RelayTheme.spacing(9)) {
                            Image(systemName: "keyboard")
                                .foregroundStyle(RelayTheme.blue)
                            Text("Customize shortcuts")
                                .font(RelayTheme.font(size: 11.5, weight: .medium))
                            Spacer()
                            Text(preferences.keyBinding(for: .closePane).displayName)
                                .font(RelayTheme.font(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(RelayTheme.textMuted)
                            Image(systemName: "chevron.right")
                                .font(RelayTheme.font(size: 9, weight: .medium))
                                .foregroundStyle(RelayTheme.textMuted)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Text("Shortcuts are checked for conflicts and update menus immediately.")
                        .font(RelayTheme.font(size: 11))
                        .foregroundStyle(RelayTheme.textMuted)
                } }
    private var connectionsSettings: some View { settingSection("Remote sessions") {
                    Toggle("Update relayd on approved hosts", isOn: $preferences.automaticallyUpdateRelayd)
                    Button {
                        NotificationCenter.default.post(name: .relayManageRelayd, object: nil)
                    } label: {
                        HStack(spacing: RelayTheme.spacing(9)) {
                            Image(systemName: "server.rack")
                                .foregroundStyle(RelayTheme.mint)
                            Text("Check relayd and remote sessions")
                                .font(RelayTheme.font(size: 11.5, weight: .medium))
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(RelayTheme.font(size: 9, weight: .medium))
                                .foregroundStyle(RelayTheme.textMuted)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Text("Relay asks before the first installation in a shared home. Nodes reuse that binary while keeping separate supervisors and sockets. Approved SSH hosts can apply verified updates automatically.")
                        .font(RelayTheme.font(size: 11))
                        .foregroundStyle(RelayTheme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                } }
    private var clientSettings: some View { settingSection("Clients") {
                    Button("Manage clients…") { showingCallers = true }
                        .accessibilityIdentifier("relay.callers.open")
                    Text("Name clients, pause their actions and review recent activity.")
                        .font(RelayTheme.font(size: 11)).foregroundStyle(RelayTheme.textMuted)
                } }
    private var pluginSettings: some View { settingSection("Plugins") {
                    Button("Manage plugins…") { showingPlugins = true }
                    Text("Review and install declarative packages from GitHub releases. Experimental; executable plugins are not enabled.")
                        .font(RelayTheme.font(size: 11))
                        .foregroundStyle(RelayTheme.textMuted)
                } }
    private var advancedSettings: some View { settingSection("Terminal compatibility") {
                    HStack(spacing: RelayTheme.spacing(9)) {
                        Image(systemName: terminfoStatus.usesRelayEntry
                            ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(terminfoStatus.usesRelayEntry
                                ? RelayTheme.mint : RelayTheme.coral)
                        VStack(alignment: .leading, spacing: RelayTheme.spacing(2)) {
                            Text(terminfoStatus.activeTerm)
                                .font(RelayTheme.font(size: 11.5, weight: .medium, design: .monospaced))
                            Text("SHA-256  \(String(terminfoStatus.hash.prefix(12)))")
                                .font(RelayTheme.font(size: 11, design: .monospaced))
                                .foregroundStyle(RelayTheme.textMuted)
                        }
                        Spacer()
                        Button("Recheck") { terminfoStatus = RelayTerminfo.bootstrap() }
                            .font(RelayTheme.font(size: 10.5, weight: .medium))
                    }
                    Text(terminfoStatus.message)
                        .font(RelayTheme.font(size: 11))
                        .foregroundStyle(RelayTheme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    if !terminfoStatus.installedForSystemPrograms {
                        HStack(spacing: RelayTheme.spacing(10)) {
                            Button("Copy sudo fallback") {
                                copyToPasteboard(RelayTerminfo.sudoCompatibilityCommand)
                            }
                            if let command = RelayTerminfo.privilegedInstallCommand {
                                Button("Copy one-time install") {
                                    copyToPasteboard(command)
                                }
                            }
                        }
                        .font(RelayTheme.font(size: 10.5, weight: .medium))
                        Text("Relay never requests administrator access automatically. The fallback keeps sudo programs usable; the optional install makes xterm-relay visible to root.")
                            .font(RelayTheme.font(size: 11))
                            .foregroundStyle(RelayTheme.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } }

    private var intelligenceSettings: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Apple on-device model", systemImage: "cpu")
                        .font(RelayTheme.font(size: 14, weight: .medium))
                    Spacer()
                    Text(RelayIntelligenceSettingsCopy.availabilityTitle(intelligenceAvailability))
                        .font(RelayTheme.font(size: 12, weight: .medium))
                        .foregroundStyle(intelligenceAvailability == "available" ? RelayTheme.mint : RelayTheme.textMuted)
                }
                Text(RelayIntelligenceSettingsCopy.availabilityDetail(intelligenceAvailability))
                    .font(RelayTheme.font(size: 12)).foregroundStyle(RelayTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Refresh availability") { Task { await refreshIntelligenceAvailability() } }
                    .controlSize(.small)
            }
            .padding(16)
            .background(RelayTheme.surface, in: RoundedRectangle(cornerRadius: 10))
            .accessibilityIdentifier("relay.settings.intelligence.availability")

            settingSection("On-device features") {
                Toggle("Use on-device intelligence", isOn: $preferences.intelligenceEnabled)
                    .accessibilityIdentifier("relay.settings.intelligence.enabled")
                Text(preferences.intelligenceEnabled
                    ? "Enabled for activity ranking and session advice when the model is available."
                    : "Off. Your activity history, agents and ordinary search remain available.")
                    .font(RelayTheme.font(size: 12)).foregroundStyle(RelayTheme.textMuted)
                Toggle("Summarize completed work", isOn: $preferences.automaticAgentSummaries)
                    .disabled(!preferences.intelligenceEnabled)
                Text("Add a short summary after an agent completes work.")
                    .font(RelayTheme.font(size: 12)).foregroundStyle(RelayTheme.textMuted)
                Toggle("Search activity by meaning", isOn: $preferences.semanticAgentSearch)
                    .disabled(!preferences.intelligenceEnabled)
                Text("Find related agent activity even when the words differ.")
                    .font(RelayTheme.font(size: 12)).foregroundStyle(RelayTheme.textMuted)
            }

            settingSection("Where results appear") {
                Text("Summaries and search appear in agent activity. Session advice appears when Relay observes a session that needs attention.")
                Text(RelayIntelligenceSettingsCopy.activityDetail(
                    enabled: preferences.intelligenceEnabled,
                    summaries: preferences.automaticAgentSummaries,
                    search: preferences.semanticAgentSearch))
                    .foregroundStyle(RelayTheme.textMuted)
            }

            DisclosureGroup("Advanced · custom decision model") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("This optional model uses numeric session evidence to advise the supervisor. Apple’s model does not require an additional file.")
                        .font(RelayTheme.font(size: 12)).foregroundStyle(RelayTheme.textMuted)
                    TextField("Local model file path", text: $preferences.decisionModelPath)
                    HStack {
                        Button("Choose file…") {
                            let panel = RelayTheme.openPanel()
                            panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
                            if panel.runModal() == .OK, let url = panel.url {
                                preferences.decisionModelPath = url.path
                                decisionModelStatus = "File selected. Enter its trusted digest, then load it."
                            }
                        }
                        Spacer()
                    }
                    TextField("Trusted SHA-256 digest", text: $preferences.decisionModelSHA256)
                    Button("Load custom model") {
                        let path = preferences.decisionModelPath
                        let digest = preferences.decisionModelSHA256
                        Task {
                            decisionModelStatus = await RelaySupervisorIntelligenceService.shared
                                .configureLocalModel(path: path, sha256: digest, force: true)
                        }
                    }
                    .disabled(preferences.decisionModelPath.isEmpty || preferences.decisionModelSHA256.isEmpty)
                    Text(preferences.decisionModelPath.isEmpty
                         ? "No custom model selected. This is optional."
                         : decisionModelStatus ?? "A custom model is configured. Its file and digest are checked before use.")
                        .font(RelayTheme.font(size: 12)).foregroundStyle(RelayTheme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .textFieldStyle(.roundedBorder).padding(.top, 12)
            }
            Text("These models run on this Mac. They do not use your API accounts. Model advice does not grant permission to change a session.")
                .font(RelayTheme.font(size: 12)).foregroundStyle(RelayTheme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task { await refreshIntelligenceAvailability() }
    }

    private func refreshIntelligenceAvailability() async {
        intelligenceAvailability = await DesktopRouteRecoveryPlanner.shared.status().availability
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: RelayTheme.spacing(16)) {
            Text("Terminal preview")
                .font(RelayTheme.font(size: 12, weight: .medium))
                .foregroundStyle(RelayTheme.textMuted)
            VStack(spacing: RelayTheme.spacing(0)) {
                HStack(spacing: RelayTheme.spacing(7)) {
                    Circle().fill(RelayTheme.mint).frame(width: 6, height: 6)
                    Text("Sample terminal")
                        .font(RelayTheme.font(size: 11, weight: .medium))
                    Spacer()
                    Text("Preview")
                        .font(RelayTheme.font(size: 11, weight: .medium))
                        .foregroundStyle(RelayTheme.mint)
                }
                .padding(.horizontal, RelayTheme.spacing(12))
                .frame(height: 34)
                .background(RelayTheme.surface)

                VStack(alignment: .leading, spacing: RelayTheme.spacing(8)) {
                    Text("$ codex")
                    Text("› build the next experiment")
                        .foregroundStyle(RelayTheme.textMuted)
                    Text("● Working on a task")
                        .foregroundStyle(RelayTheme.mint)
                    Text("_")
                        .foregroundStyle(RelayTheme.blue)
                }
                .font(.custom(preferences.resolvedFontFamily, size: preferences.fontSize))
                .padding(preferences.terminalPadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color(hex: UInt32(preferences.palette.background, radix: 16) ?? 0x0B1018))
            }
            .clipShape(RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(8), style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(8)).stroke(RelayTheme.line.opacity(0.55)) }
        }
        .frame(height: 215)
    }



    private func settingSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(RelayTheme.font(size: 14, weight: .medium))
            VStack(alignment: .leading, spacing: 12) { content() }
                .font(RelayTheme.font(size: 13))
            Rectangle().fill(RelayTheme.line.opacity(0.5)).frame(height: 1).padding(.top, 8)
        }
    }

    private func valueSlider(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, suffix: String) -> some View {
        HStack(spacing: RelayTheme.spacing(10)) {
            Text(label).font(RelayTheme.font(size: 11.5)).frame(width: 48, alignment: .leading)
            Slider(value: value, in: range, step: 0.5).tint(RelayTheme.blue)
            Text("\(value.wrappedValue, specifier: "%.1f") \(suffix)")
                .font(RelayTheme.font(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(RelayTheme.textMuted)
                .frame(width: 57, alignment: .trailing)
        }
    }

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}


private struct RelayKeyBindingsView: View {
    @ObservedObject private var preferences = RelayPreferences.shared
    @Environment(\.dismiss) private var dismiss
    @State private var conflictMessage: String?

    private let sections = ["Sessions", "Tabs", "Panes", "Workspace"]

    var body: some View {
        VStack(spacing: RelayTheme.spacing(0)) {
            HStack(spacing: RelayTheme.spacing(12)) {
                VStack(alignment: .leading, spacing: RelayTheme.spacing(3)) {
                    Text("Keybindings")
                        .font(RelayTheme.font(size: 18, weight: .medium))
                    Text("Click a shortcut, then press a new key combination.")
                        .font(RelayTheme.font(size: 11.5))
                        .foregroundStyle(RelayTheme.textMuted)
                }
                Spacer()
                Button("Reset all") {
                    preferences.resetAllKeyBindings()
                    conflictMessage = nil
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, RelayTheme.spacing(22))
            .frame(height: 70)

            Divider().overlay(RelayTheme.line.opacity(0.5))

            ScrollView {
                LazyVStack(alignment: .leading, spacing: RelayTheme.spacing(18)) {
                    if let conflictMessage {
                        Label(conflictMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(RelayTheme.font(size: 11))
                            .foregroundStyle(RelayTheme.coral)
                            .padding(.horizontal, RelayTheme.spacing(12))
                            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                            .background(RelayTheme.coral.opacity(0.09), in: RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(9)))
                    }

                    ForEach(sections, id: \.self) { section in
                        VStack(alignment: .leading, spacing: RelayTheme.spacing(7)) {
                            Text(section)
                                .font(RelayTheme.font(size: 11, weight: .medium))
                                .foregroundStyle(RelayTheme.textMuted)
                                .textCase(.uppercase)
                                .tracking(0.5)

                            VStack(spacing: RelayTheme.spacing(0)) {
                                let commands = RelayCommand.allCases.filter { $0.section == section }
                                ForEach(Array(commands.enumerated()), id: \.element.id) { index, command in
                                    keyBindingRow(command)
                                    if index < commands.count - 1 {
                                        Divider().overlay(RelayTheme.line.opacity(0.35))
                                    }
                                }
                            }
                            .background(RelayTheme.surface, in: RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(8), style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(8), style: .continuous)
                                    .stroke(RelayTheme.line.opacity(0.45))
                            }
                        }
                    }
                }
                .padding(RelayTheme.spacing(22))
            }
        }
        .frame(width: 590, height: 560)
        .foregroundStyle(RelayTheme.text)
        .background(RelayTheme.sidebar)
        .relaySurface()
    }

    private func keyBindingRow(_ command: RelayCommand) -> some View {
        HStack(spacing: RelayTheme.spacing(12)) {
            Text(command.label)
                .font(RelayTheme.font(size: 11.5))
            Spacer()
            if preferences.keyBindings[command.rawValue] != nil {
                Button {
                    preferences.resetKeyBinding(command)
                    conflictMessage = nil
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(RelayTheme.font(size: 10, weight: .medium))
                        .foregroundStyle(RelayTheme.textMuted)
                }
                .buttonStyle(.plain)
                .help("Restore default")
            }
            RelayShortcutRecorderButton(binding: preferences.keyBinding(for: command)) { candidate in
                if let reserved = RelayKeyBindingStorage.reservedConflictName(for: candidate) {
                    conflictMessage = "\(candidate.displayName) is reserved by macOS/Relay for \(reserved)."
                    NSSound.beep()
                } else if let conflict = preferences.setKeyBinding(candidate, for: command) {
                    conflictMessage = "\(candidate.displayName) is already assigned to \(conflict.label)."
                    NSSound.beep()
                } else {
                    conflictMessage = nil
                }
            }
        }
        .padding(.horizontal, RelayTheme.spacing(12))
        .frame(height: 40)
    }
}

private struct RelayShortcutRecorderButton: View {
    let binding: RelayKeyBinding
    let onCapture: (RelayKeyBinding) -> Void
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            beginRecording()
        } label: {
            Text(isRecording ? "Type shortcut…" : binding.displayName)
                .font(RelayTheme.font(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(isRecording ? RelayTheme.canvas : RelayTheme.text)
                .frame(minWidth: 74)
                .padding(.horizontal, RelayTheme.spacing(8))
                .frame(height: 25)
                .background(
                    isRecording ? RelayTheme.blue : RelayTheme.elevated,
                    in: RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(6), style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(6), style: .continuous)
                        .stroke(isRecording ? RelayTheme.blue : RelayTheme.line.opacity(0.6))
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Shortcut: \(binding.displayName)")
        .onDisappear { stopRecording() }
    }

    private func beginRecording() {
        guard !isRecording else { return }
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                stopRecording()
                return nil
            }
            guard let candidate = RelayKeyBinding(event: event) else {
                NSSound.beep()
                return nil
            }
            onCapture(candidate)
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
    }
}
