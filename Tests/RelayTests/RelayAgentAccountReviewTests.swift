import Foundation
import Testing
@testable import Relay

/// Regression tests for the account review findings: the default account
/// clears an inherited override, a pane a plan creates uses its source
/// pane's workspace account, and MCP previews are scoped to their host.
@Suite("Agent account review regressions")
@MainActor struct RelayAgentAccountReviewTests {
    @Test("A created pane uses the owner of its source pane for account routing")
    func createdPaneUsesSourceWorkspaceAccount() throws {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.shutdown() }
        let paneA = try #require(workspace.activePane)
        let tabA = try #require(workspace.tabID(containingPane: paneA.id))
        let ownerA = workspace.createWorkspace(named: "Review A")
        try workspace.moveTab(tabA, toWorkspace: ownerA)
        workspace.newTab(profile: .local)
        let paneB = try #require(workspace.activePane)
        let tabB = try #require(workspace.tabID(containingPane: paneB.id))
        let ownerB = workspace.createWorkspace(named: "Review B")
        try workspace.moveTab(tabB, toWorkspace: ownerB)
        workspace.revealPane(paneA.id)
        let routing = RelayAgentAccountRouting.shared
        routing.setWorkspace(ownerA, provider: "claude", label: "work")
        routing.setWorkspace(ownerB, provider: "claude", label: "personal")
        defer {
            routing.setWorkspace(ownerA, provider: "claude", label: nil)
            routing.setWorkspace(ownerB, provider: "claude", label: nil)
        }
        let snapshot = RelayAssistantSnapshot.capture(workspace)
        let payload: [String: RelayPaneHealthJSON] = ["steps": .array([
            .object(["op": .string("new_tab"), "pane": .string(paneB.id.uuidString.lowercased())]),
            .object(["op": .string("split"), "pane": .string("step:1"), "direction": .string("right")]),
            .object(["op": .string("start_agent"), "pane": .string("step:1"), "agent": .string("claude")]),
            .object(["op": .string("start_agent"), "pane": .string("step:2"), "agent": .string("claude")]),
            .object(["op": .string("start_agent"), "pane": .string(paneA.id.uuidString.lowercased()), "agent": .string("claude")])
        ])]
        guard case .success(let steps) = RelayAssistantPlan.validate(payload, snapshot: snapshot) else {
            Issue.record("The cross-workspace plan fixture was refused before account selection")
            return
        }
        // A created pane, also one split from a created pane, is owned by the
        // existing pane the chain starts from; an existing pane by itself.
        #expect(steps[2].ownerPane == paneB.id && steps[3].ownerPane == paneB.id && steps[4].ownerPane == paneA.id)
        let harness = RelayAssistantHarness(workspace: workspace)
        #expect(workspace.accountWorkspaceID(containingPane: paneA.id) == ownerA)
        #expect(workspace.defaultAgentAccount("claude", forPane: paneB.id)?.label == "personal")
        #expect(harness.launchAccount(steps[2], snapshot: snapshot, workspace: workspace).account?.label == "personal")
        #expect(harness.launchAccount(steps[3], snapshot: snapshot, workspace: workspace).account?.label == "personal")
        #expect(harness.launchAccount(steps[4], snapshot: snapshot, workspace: workspace).account?.label == "work")
        // Without a known owner the default is refused, never guessed from
        // the selected pane.
        var orphan = steps[2]
        orphan.ownerPane = nil
        let refused = harness.launchAccount(orphan, snapshot: snapshot, workspace: workspace)
        #expect(refused.account == nil && refused.refusal != nil)
    }

    @Test("Every account launch runs the exact managed launcher and selects only its own account")
    func launchesPinTheManagedLauncher() throws {
        // An environment activator prepends its own directory to PATH after
        // shell startup, and the default account's `env -u` would bypass
        // Relay's codex shell function: the typed command names the file.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("relay-launcher-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let shims = root.appendingPathComponent(".local/share/relay/shims"), other = root.appendingPathComponent("environment")
        func run(_ script: String, variable: String) throws -> (Int32, String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["--noprofile", "--norc", "-c", script]
            process.environment = ["HOME": root.path, "PATH": shims.path + ":/usr/bin:/bin", variable: "/synthetic/personal"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }
        for provider in ["claude", "codex"] {
            let work = RelayAgentAccount(provider: provider, label: "work", dir: "")
            let personal = RelayAgentAccount(provider: provider, label: "personal", dir: "~/.\(provider)-personal")
            for (directory, marker) in [(shims, "managed"), (other, "unmanaged")] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let file = directory.appendingPathComponent(provider)
                try Data("#!/bin/sh\nprintf '\(marker):%s\\n' \"${\(work.variable)+set}\"\n".utf8).write(to: file)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
            }
            let function = provider == "codex" ? "function codex { command '\(shims.appendingPathComponent("codex").path)' \"$@\"; }\n" : ""
            let prefix = function + "export PATH='\(other.path):/usr/bin:/bin'\n"
            for (account, expected) in [(work, "managed:\n"), (personal, "managed:set\n")] {
                let (status, output) = try run(prefix + account.launchCommand(provider), variable: account.variable)
                #expect(status == 0 && output == expected, "\(provider) \(account.label): \(output)")
            }
            // A missing launcher fails; it never falls back to PATH.
            try FileManager.default.removeItem(at: shims.appendingPathComponent(provider))
            for account in [work, personal] {
                let (status, output) = try run(prefix + account.launchCommand(provider), variable: account.variable)
                #expect(status != 0 && !output.contains("unmanaged"), "\(provider) \(account.label) fell back to PATH")
            }
        }
    }

    @Test("A login runs the provider's own CLI with only its account, never Relay's launcher or a shell alias")
    func loginRunsTheProvidersOwnLogin() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("relay-login-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let shims = root.appendingPathComponent(".local/share/relay/shims"), bin = root.appendingPathComponent("bin")
        func run(_ script: String, path: String, variable: String) throws -> (Int32, String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["--noprofile", "--norc", "-O", "expand_aliases", "-c", script]
            process.environment = ["HOME": root.path, "PATH": path, variable: "/synthetic/inherited"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }
        for provider in ["claude", "codex"] {
            let work = RelayAgentAccount(provider: provider, label: "work", dir: "")
            let personal = RelayAgentAccount(provider: provider, label: "personal", dir: "~/.\(provider)-personal")
            // Each program prints its name, the account variable and its arguments.
            for (directory, marker) in [(shims, "managed"), (bin, "provider")] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let file = directory.appendingPathComponent(provider)
                try Data("#!/bin/sh\nprintf '\(marker):%s:%s\\n' \"${\(work.variable)-unset}\" \"$*\"\n".utf8).write(to: file)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
            }
            // A shell alias or function of the provider's name never runs.
            let shadow = "function \(provider) { echo shadowed; }\nalias \(provider)='echo shadowed'\n"
            let executable = bin.appendingPathComponent(provider).path
            for remote in [false, true] {
                let arguments = provider == "codex" ? (remote ? "login --device-auth" : "login") : "auth login"
                for (account, value) in [(work, "unset"), (personal, root.path + "/.\(provider)-personal")] {
                    // Relay's launcher first in PATH (a relayd pane) never runs:
                    // the CLI relayd resolved does, by its absolute path.
                    let (status, output) = try run(shadow + account.loginCommand(executable: executable, remote: remote),
                                                   path: shims.path + ":/usr/bin:/bin", variable: account.variable)
                    #expect(status == 0 && output == "provider:\(value):\(arguments)\n", "\(provider) \(account.label): \(output)")
                }
                // Signing in again: the provider's own logout, then its login, same account.
                let logout = provider == "codex" ? "logout" : "auth logout"
                let (status, output) = try run(shadow + personal.loginCommand(executable: executable, remote: remote, replacing: true),
                                               path: shims.path + ":/usr/bin:/bin", variable: personal.variable)
                let value = root.path + "/.\(provider)-personal"
                #expect(status == 0 && output == "provider:\(value):\(logout)\nprovider:\(value):\(arguments)\n", "\(provider): \(output)")
            }
        }
    }

    @Test("The chosen host in Settings › Agent Accounts survives a refresh of the SSH config")
    func hostChoiceSurvivesSSHConfigRefresh() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("relay-ssh-config-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let alias = "relay-review-" + UUID().uuidString.prefix(8).lowercased()
        let config = root.appendingPathComponent("config")
        try Data("Host \(alias)\n    HostName \(alias).invalid\nHost relay-review-other\n".utf8).write(to: config)
        let store = ProfileStore()
        store.refreshSSHConfig(configURL: config)
        let chosen = try #require(RelayAgentAccountsSettingsView.hosts(store).first { $0.host == alias })
        let selection = RelayAgentAccountsSettingsView.selectionKey(chosen)
        // The session monitor, relayd management and the side panel refresh
        // the SSH config at any time; each refresh makes new profile ids.
        store.refreshSSHConfig(configURL: config)
        let hosts = RelayAgentAccountsSettingsView.hosts(store)
        let refreshed = try #require(hosts.first { $0.host == alias })
        #expect(refreshed.id != chosen.id)
        let shown = RelayAgentAccountsSettingsView.host(selection, in: hosts)
        #expect(shown.kind == .ssh && shown.host == alias, "the choice fell back to \(shown.name)")
        #expect(RelayAgentAccountDirectory.hostKey(shown) == RelayAgentAccountDirectory.hostKey(chosen))
        // This Mac stays This Mac, and an unknown or absent choice shows it.
        #expect(RelayAgentAccountsSettingsView.host(RelayAgentAccountsSettingsView.selectionKey(.local), in: hosts).kind == .local)
        #expect(RelayAgentAccountsSettingsView.host(nil, in: hosts).kind == .local)
        #expect(Set(hosts.map(RelayAgentAccountsSettingsView.selectionKey)).count == hosts.count)
    }

    @Test("Miko's default-account launch unsets the variable and says so")
    func assistantDefaultLaunchUnsets() async {
        let work = RelayAgentAccount(provider: "claude", label: "work", dir: "")
        let stat: (String) async -> [String: Any]? = { _ in ["directory": false, "version": "shim1"] }
        let launch = await RelayAssistantLaunch.resolve(agent: "claude", account: work, stat: stat, read: { _, _, _ in nil })
        let pinned = #"env -u CLAUDE_CONFIG_DIR "$HOME"/.local/share/relay/shims/claude"#
        #expect(launch.typed == pinned)
        #expect(launch.resolved.hasPrefix(pinned + " → relayd") && launch.resolved.hasSuffix("(account work)"))
        let plain = await RelayAssistantLaunch.resolve(agent: "claude", account: nil, stat: stat, read: { _, _, _ in nil })
        #expect(launch.fingerprint != plain.fingerprint && !plain.typed.contains("env -u"))
        // Without the managed launcher on the host nothing is offered to run.
        let missing = await RelayAssistantLaunch.resolve(agent: "claude", account: work, stat: { _ in nil }, read: { _, _, _ in nil })
        #expect(missing.blockedReason != nil)
    }

    @Test("A Settings save clears the dirty state only for the same host and the saved edits")
    func saveCompletionIsScoped() {
        let saved = [RelayAgentAccount(provider: "claude", label: "work", dir: "")]
        let settings: [String: RelayAgentAccountSyncSettings] = ["claude:work": .init()]
        #expect(RelayAgentAccountsSettingsView.saveClearsDirty(started: 3, current: 3, saved: saved, savedSettings: settings,
                                                                shown: saved, shownSettings: settings))
        // Another host is shown now.
        #expect(!RelayAgentAccountsSettingsView.saveClearsDirty(started: 3, current: 4, saved: saved, savedSettings: settings,
                                                                 shown: saved, shownSettings: settings))
        // The user edited again while the save ran.
        let edited = saved + [RelayAgentAccount(provider: "claude", label: "personal", dir: "~/.claude-personal")]
        #expect(!RelayAgentAccountsSettingsView.saveClearsDirty(started: 3, current: 3, saved: saved, savedSettings: settings,
                                                                 shown: edited, shownSettings: settings))
        var excluded = settings
        excluded["claude:work"]?.mcpExclude = ["db"]
        #expect(!RelayAgentAccountsSettingsView.saveClearsDirty(started: 3, current: 3, saved: saved, savedSettings: settings,
                                                                 shown: saved, shownSettings: excluded))
    }

    @Test("MCP previews are scoped to their host and exact account and fenced by generation")
    func previewCacheIsHostScoped() {
        let account = RelayAgentAccount(provider: "codex", label: "personal", dir: "~/.codex-personal")
        let preview = RelayAgentAccountMCPPreview(provider: "codex", label: "personal", servers: [], fingerprint: String(repeating: "a", count: 64))
        var cache = RelayAgentAccountPreviewCache()
        let stored1 = cache.store(preview, host: "local", account: account, generation: cache.generation)
        #expect(stored1)
        #expect(cache.preview(host: "local", account: account) == preview)
        #expect(cache.preview(host: "ssh:dandy-07", account: account) == nil)
        // Same label, another directory: not the reviewed account.
        let moved = RelayAgentAccount(provider: "codex", label: "personal", dir: "~/.codex-other")
        #expect(cache.preview(host: "local", account: moved) == nil)
        // A mapping change drops the preview and fences answers in flight.
        let inFlight = cache.generation
        cache.retain([moved], host: "local")
        #expect(cache.preview(host: "local", account: account) == nil)
        let stored2 = cache.store(preview, host: "local", account: account, generation: inFlight)
        #expect(!stored2)
        // A host change drops everything.
        let stored3 = cache.store(preview, host: "local", account: account, generation: cache.generation)
        #expect(stored3)
        let beforeHostChange = cache.generation
        cache.reset()
        #expect(cache.preview(host: "local", account: account) == nil)
        let stored4 = cache.store(preview, host: "ssh:dandy-07", account: account, generation: beforeHostChange)
        #expect(!stored4)
        // An answer for another account is never filed under this one.
        let other = RelayAgentAccountMCPPreview(provider: "codex", label: "other", servers: [])
        let stored5 = cache.store(other, host: "local", account: account, generation: cache.generation)
        #expect(!stored5)
        // A sync uses its preview up: the next one needs a fresh review.
        let stored6 = cache.store(preview, host: "local", account: account, generation: cache.generation)
        #expect(stored6)
        cache.remove(host: "local", account: account)
        #expect(cache.preview(host: "local", account: account) == nil)
    }
}
