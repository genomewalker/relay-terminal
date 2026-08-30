import CryptoKit
import Foundation
import SwiftUI

enum RelaydHostState: String, Equatable, Sendable {
    case unknown
    case checking
    case missing
    case ready
    case outdated
    case installing
    case unreachable
    case failed
}

struct RelaydHostReport: Equatable, Sendable {
    var state: RelaydHostState = .unknown
    var architecture = "—"
    var version: String?
    var liveVersion: String?
    var protocolVersion: Int?
    var supervisorPID: Int?
    var sessionCount = 0
    var paneCount = 0
    var runningPaneCount = 0
    var recoverablePaneCount = 0
    var logLines: [String] = []
    var message: String?
    var checkedAt: Date?
}

struct RelaydManagerEvent: Identifiable, Equatable, Sendable {
    let id = UUID()
    let occurredAt: Date
    let message: String
    let kind: RelaydHostState
}

enum RelaydManagementError: LocalizedError, Equatable {
    case invalidResponse
    case commandFailed(String)
    case unsupportedArchitecture(String)
    case bundledBinaryMissing(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "The host returned an invalid relayd status response."
        case .commandFailed(let message):
            message
        case .unsupportedArchitecture(let architecture):
            "Relay does not include a relayd binary for remote architecture \(architecture)."
        case .bundledBinaryMissing(let architecture):
            "This Relay build does not include relayd for Linux \(architecture)."
        }
    }
}

enum RelaydStatusParser {
    static let catalogBegin = "RELAYD_CATALOG_BEGIN"
    static let catalogEnd = "RELAYD_CATALOG_END"
    static let logBegin = "RELAYD_LOG_BEGIN"
    static let logEnd = "RELAYD_LOG_END"

    static func parse(_ data: Data, expectedVersion: String) throws -> RelaydHostReport {
        guard let text = String(data: data, encoding: .utf8) else {
            throw RelaydManagementError.invalidResponse
        }
        let lines = text.components(separatedBy: .newlines)
        let statusFields = lines.reversed()
            .map { $0.components(separatedBy: "\t") }
            .first { $0.first == "RELAYD_STATUS" }
        let missingFields = lines.reversed()
            .map { $0.components(separatedBy: "\t") }
            .first { $0.first == "RELAYD_MISSING" }
        if statusFields == nil, let fields = missingFields, fields.count >= 2 {
            let architecture = fields.count >= 3 ? fields[2] : fields[1]
            return RelaydHostReport(
                state: .missing,
                architecture: architecture,
                message: "relayd is not installed in ~/.local/bin.",
                checkedAt: Date()
            )
        }
        guard let fields = statusFields else {
            throw RelaydManagementError.invalidResponse
        }
        let nonce: String?
        let architecture: String
        let version: String
        let liveVersion: String?
        let protocolVersion: Int?
        let supervisorPID: Int?
        let catalogHealthy: Bool
        if fields.count >= 8 {
            nonce = fields[1]
            architecture = fields[2]
            version = normalizedVersion(fields[3])
            liveVersion = fields[4] == "stopped" ? nil : normalizedVersion(fields[4])
            protocolVersion = Int(fields[5]).flatMap { $0 > 0 ? $0 : nil }
            supervisorPID = supervisorPIDValue(fields[6])
            catalogHealthy = fields.count < 9 || fields[8] == "1"
        } else if fields.count >= 5 {
            nonce = nil
            architecture = fields[1]
            version = normalizedVersion(fields[2])
            supervisorPID = supervisorPIDValue(fields[3])
            liveVersion = supervisorPID == nil ? nil : version
            protocolVersion = nil
            catalogHealthy = true
        } else {
            throw RelaydManagementError.invalidResponse
        }
        let catalogStart = nonce.map { "\(catalogBegin)\t\($0)" } ?? catalogBegin
        let catalogFinish = nonce.map { "\(catalogEnd)\t\($0)" } ?? catalogEnd
        let logStart = nonce.map { "\(logBegin)\t\($0)" } ?? logBegin
        let logFinish = nonce.map { "\(logEnd)\t\($0)" } ?? logEnd
        guard let catalogRange = section(
            in: text, begin: catalogStart, end: catalogFinish
        ), let catalogData = catalogRange.data(using: .utf8),
              let catalog = try? JSONDecoder().decode(RemoteCatalogSnapshot.self, from: catalogData) else {
            throw RelaydManagementError.invalidResponse
        }
        let logs = section(in: text, begin: logStart, end: logFinish)?
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .suffix(80)
            .map { RelayDiagnostics.redact($0) } ?? []
        let running = catalog.panes.count { $0.state == "running" }
        let recoverable = catalog.panes.count(where: \.recoverable)
        let installedOrder = compareVersions(version, expectedVersion)
        let liveIsCurrent = liveVersion == nil || compareVersions(liveVersion!, expectedVersion) != .orderedAscending
        let state: RelaydHostState = installedOrder != .orderedAscending && liveIsCurrent && catalogHealthy
            ? .ready : .outdated
        let message: String?
        if !catalogHealthy {
            message = "relayd could not read its session catalog. Reinstall to repair it."
        } else if installedOrder == .orderedAscending {
            message = "Installed version \(version); Relay includes \(expectedVersion)."
        } else if installedOrder == .orderedDescending {
            message = "The host has newer relayd \(version). This app will not downgrade it."
        } else if let liveVersion, liveVersion != expectedVersion {
            message = "The running supervisor is \(liveVersion); Relay includes \(expectedVersion)."
        } else if supervisorPID == nil {
            message = "Installed; the supervisor starts with the next session."
        } else {
            message = nil
        }
        return RelaydHostReport(
            state: state,
            architecture: architecture,
            version: version,
            liveVersion: liveVersion,
            protocolVersion: protocolVersion,
            supervisorPID: supervisorPID,
            sessionCount: catalog.sessions.count,
            paneCount: catalog.panes.count,
            runningPaneCount: running,
            recoverablePaneCount: recoverable,
            logLines: Array(logs),
            message: message,
            checkedAt: Date()
        )
    }

    private static func normalizedVersion(_ value: String) -> String {
        value.replacingOccurrences(of: "relayd ", with: "")
    }

    private static func supervisorPIDValue(_ value: String) -> Int? {
        Int(value).flatMap { $0 > 0 ? $0 : nil }
    }

    private static func compareVersions(_ left: String, _ right: String) -> ComparisonResult {
        guard let leftParts = numericVersion(left), let rightParts = numericVersion(right) else {
            return left == right ? .orderedSame : .orderedAscending
        }
        let count = max(leftParts.count, rightParts.count)
        for index in 0..<count {
            let lhs = index < leftParts.count ? leftParts[index] : 0
            let rhs = index < rightParts.count ? rightParts[index] : 0
            if lhs < rhs { return .orderedAscending }
            if lhs > rhs { return .orderedDescending }
        }
        return .orderedSame
    }

    private static func numericVersion(_ value: String) -> [Int]? {
        let core = value.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            .split(separator: "-", maxSplits: 1).first.map(String.init) ?? value
        let parts = core.split(separator: ".")
        guard !parts.isEmpty else { return nil }
        let numbers = parts.compactMap { Int($0) }
        return numbers.count == parts.count ? numbers : nil
    }

    private static func section(in text: String, begin: String, end: String) -> String? {
        guard let beginRange = text.range(of: begin),
              let endRange = text.range(of: end, range: beginRange.upperBound..<text.endIndex) else {
            return nil
        }
        return text[beginRange.upperBound..<endRange.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum RelaydRemoteClient {
    static let expectedVersion = Bundle.main.infoDictionary?["RelaydVersion"] as? String ?? "0.5.2"

    static func check(profile: ConnectionProfile) async throws -> RelaydHostReport {
        try await Task.detached(priority: .userInitiated) {
            let result = try runSSH(profile: profile, script: statusScript, timeout: 15)
            guard result.status == 0 else {
                let message = result.error.trimmingCharacters(in: .whitespacesAndNewlines)
                throw RelaydManagementError.commandFailed(
                    message.isEmpty ? "Could not check relayd on \(profile.name)." : message
                )
            }
            return try RelaydStatusParser.parse(result.output, expectedVersion: expectedVersion)
        }.value
    }

    static func install(profile: ConnectionProfile, architecture: String) async throws {
        try await Task.detached(priority: .userInitiated) {
            let goArchitecture: String
            switch architecture.lowercased() {
            case "x86_64", "amd64": goArchitecture = "amd64"
            case "aarch64", "arm64": goArchitecture = "arm64"
            default: throw RelaydManagementError.unsupportedArchitecture(architecture)
            }
            let name = "relayd-linux-\(goArchitecture)"
            guard let url = Bundle.main.resourceURL?.appendingPathComponent(name),
                  FileManager.default.isReadableFile(atPath: url.path),
                  let binary = try? Data(contentsOf: url), !binary.isEmpty else {
                throw RelaydManagementError.bundledBinaryMissing(goArchitecture)
            }
            let hash = SHA256.hash(data: binary).map { String(format: "%02x", $0) }.joined()
            let script = installScript(expectedHash: hash, architecture: goArchitecture)
            let result = try runSSH(profile: profile, script: script, input: binary, timeout: 30)
            guard result.status == 0 else {
                let message = result.error.trimmingCharacters(in: .whitespacesAndNewlines)
                throw RelaydManagementError.commandFailed(
                    message.isEmpty ? "Could not install relayd on \(profile.name)." : message
                )
            }
        }.value
    }

    private static let statusScript = #"""
set -u
relay_bin="$HOME/.local/bin/relayd"
arch="$(uname -m 2>/dev/null || printf unknown)"
nonce="relay-status-$$-$(date +%s 2>/dev/null || printf 0)"
if [ ! -x "$relay_bin" ]; then
    printf 'RELAYD_MISSING\t%s\t%s\n' "$nonce" "$arch"
    exit 0
fi
version="$($relay_bin --version 2>/dev/null || printf unknown)"
if [ -n "${XDG_RUNTIME_DIR:-}" ]; then
    relay_socket="$XDG_RUNTIME_DIR/relayd.sock"
else
    relay_socket="/tmp/relay-$(id -u)/relayd.sock"
fi
live_version=stopped
live_protocol=0
relay_pid=0
catalog_ok=1
catalog_output="$($relay_bin sessions 2>/dev/null)" || {
    catalog_ok=0
    catalog_output='{"schema":1,"revision":0,"panes":[],"workspace_states":{}}'
}
live_line="$($relay_bin live-status --socket "$relay_socket" 2>/dev/null || printf RELAYD_STOPPED)"
case "$live_line" in
    RELAYD_LIVE*)
        old_ifs="$IFS"
        tab="$(printf '\t')"
        IFS="$tab"
        set -- $live_line
        IFS="$old_ifs"
        if [ "$#" -ge 4 ]; then
            live_version="$2"
            live_protocol="$3"
            relay_pid="$4"
        fi
        ;;
esac
printf 'RELAYD_STATUS\t%s\t%s\t%s\t%s\t%s\t%s\t2\t%s\n' \
    "$nonce" "$arch" "$version" "$live_version" "$live_protocol" "$relay_pid" "$catalog_ok"
printf 'RELAYD_CATALOG_BEGIN\t%s\n' "$nonce"
printf '%s\n' "$catalog_output"
printf 'RELAYD_CATALOG_END\t%s\nRELAYD_LOG_BEGIN\t%s\n' "$nonce" "$nonce"
tail -n 80 "$(dirname "$relay_socket")/relayd.log" 2>/dev/null || true
printf 'RELAYD_LOG_END\t%s\n' "$nonce"
"""#

    private static func installScript(expectedHash: String, architecture: String) -> String {
        #"""
set -eu
umask 077
bin_dir="$HOME/.local/bin"
relay_root="$HOME/.local/share/relay"
payload_dir="$relay_root/bin"
shim_dir="$HOME/.local/share/relay/shims"
lock_dir="$relay_root/install.lock"
mkdir -p "$bin_dir" "$payload_dir" "$shim_dir"
lock_wait=0
while ! mkdir "$lock_dir" 2>/dev/null; do
    lock_wait=$((lock_wait + 1))
    if [ "$lock_wait" -ge 300 ]; then
        printf 'Another Relay installation still owns %s. Retry after it finishes.\n' "$lock_dir" >&2
        exit 1
    fi
    sleep 0.1
done
temporary=
launcher_temporary=
claude_shim_temporary=
codex_shim_temporary=
trap 'rm -f "$temporary" "$launcher_temporary" "$claude_shim_temporary" "$codex_shim_temporary"; rmdir "$lock_dir" 2>/dev/null || true' EXIT HUP INT TERM
temporary="$(mktemp "$payload_dir/.relayd-install-#(architecture).XXXXXX")"
launcher_temporary="$(mktemp "$bin_dir/.relayd-launcher.XXXXXX")"
cat > "$temporary"
if command -v sha256sum >/dev/null 2>&1; then
    actual="$(sha256sum "$temporary" | awk '{print $1}')"
elif command -v shasum >/dev/null 2>&1; then
    actual="$(shasum -a 256 "$temporary" | awk '{print $1}')"
else
    printf 'No SHA-256 utility is available on this host.\n' >&2
    exit 1
fi
if [ "$actual" != "#(expectedHash)" ]; then
    printf 'Uploaded relayd checksum did not match the signed application resource.\n' >&2
    exit 1
fi
chmod 700 "$temporary"
mv -f "$temporary" "$payload_dir/relayd-linux-#(architecture)"
cat > "$launcher_temporary" <<'RELAY_LAUNCHER'
#!/bin/sh
set -eu
case "$(uname -m 2>/dev/null || printf unknown)" in
    x86_64|amd64) relay_arch=amd64 ;;
    aarch64|arm64) relay_arch=arm64 ;;
    *) printf 'relayd: unsupported architecture: %s\n' "$(uname -m 2>/dev/null || printf unknown)" >&2; exit 1 ;;
esac
relay_payload="$HOME/.local/share/relay/bin/relayd-linux-$relay_arch"
if [ ! -x "$relay_payload" ]; then
    printf 'relayd: the %s payload is not installed in this shared home; install it from this node first\n' "$relay_arch" >&2
    exit 1
fi
RELAY_INVOKED_AS="${RELAY_INVOKED_AS:-$(basename "$0")}"
export RELAY_INVOKED_AS
exec "$relay_payload" "$@"
RELAY_LAUNCHER
chmod 700 "$launcher_temporary"
mv -f "$launcher_temporary" "$bin_dir/relayd"
claude_shim_temporary="$(mktemp "$shim_dir/.claude-shim.XXXXXX")"
codex_shim_temporary="$(mktemp "$shim_dir/.codex-shim.XXXXXX")"
cat > "$claude_shim_temporary" <<'RELAY_CLAUDE_SHIM'
#!/bin/sh
set -eu
RELAY_INVOKED_AS=claude
export RELAY_INVOKED_AS
exec "$HOME/.local/bin/relayd" "$@"
RELAY_CLAUDE_SHIM
cat > "$codex_shim_temporary" <<'RELAY_CODEX_SHIM'
#!/bin/sh
set -eu
RELAY_INVOKED_AS=codex
export RELAY_INVOKED_AS
exec "$HOME/.local/bin/relayd" "$@"
RELAY_CODEX_SHIM
chmod 700 "$claude_shim_temporary" "$codex_shim_temporary"
mv -f "$claude_shim_temporary" "$shim_dir/claude"
mv -f "$codex_shim_temporary" "$shim_dir/codex"
printf 'relay-managed-v1\n' > "$relay_root/managed-v1"
if [ ! -e "$bin_dir/rcode" ] && [ ! -L "$bin_dir/rcode" ]; then
    ln -s "$bin_dir/relayd" "$bin_dir/rcode"
elif [ -L "$bin_dir/rcode" ]; then
    rcode_target="$(readlink "$bin_dir/rcode" 2>/dev/null || true)"
    case "$rcode_target" in
        "$bin_dir/relayd"|"$payload_dir/relayd-linux-amd64"|"$payload_dir/relayd-linux-arm64")
            ln -sfn "$bin_dir/relayd" "$bin_dir/rcode" ;;
        *) printf 'Relay left the existing rcode symlink unchanged: %s\n' "$rcode_target" >&2 ;;
    esac
else
    printf 'Relay left the existing ~/.local/bin/rcode command unchanged.\n' >&2
fi
"$bin_dir/relayd" --version
if ! "$bin_dir/relayd" upgrade-supervisor --force; then
    sleep 1
    "$bin_dir/relayd" upgrade-supervisor
fi
"""#
    }

    private static func runSSH(
        profile: ConnectionProfile,
        script: String,
        input: Data? = nil,
        timeout: TimeInterval
    ) throws -> (status: Int32, output: Data, error: String) {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        if input != nil { process.standardInput = Pipe() }
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8",
            "-o", "ConnectionAttempts=1", "-o", "ControlMaster=no", "-o", "ControlPath=none",
        ] + profile.sshConnectionArguments + ["sh", "-c", shellQuote(script)]
        process.standardOutput = output
        process.standardError = errors
        let captured = try ProcessCapture.run(
            process, output: output, errors: errors, input: input,
            timeout: timeout, maximumBytesPerStream: 2 << 20
        )
        return (
            process.terminationStatus,
            captured.standardOutput,
            String(decoding: captured.standardError, as: UTF8.self)
        )
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

@MainActor
final class RelaydManager: ObservableObject {
    static let shared = RelaydManager()

    @Published private(set) var reports: [String: RelaydHostReport] = [:]
    @Published private(set) var events: [String: [RelaydManagerEvent]] = [:]
    @Published var selectedHostKey: String?

    private let trustedDefaultsKey = "relay.relayd-trusted-hosts.v1"
    private var trustedHostKeys: Set<String>
    private var operations: [String: Task<Void, Never>] = [:]

    private init(defaults: UserDefaults = .standard) {
        trustedHostKeys = Set(defaults.stringArray(forKey: trustedDefaultsKey) ?? [])
    }

    func report(for profile: ConnectionProfile) -> RelaydHostReport {
        reports[profile.connectionKey] ?? RelaydHostReport()
    }

    func timeline(for profile: ConnectionProfile) -> [RelaydManagerEvent] {
        events[profile.connectionKey] ?? []
    }

    func isTrusted(_ profile: ConnectionProfile) -> Bool {
        trustedHostKeys.contains(profile.connectionKey)
    }

    func select(_ profile: ConnectionProfile) {
        selectedHostKey = profile.connectionKey
    }

    func check(_ profile: ConnectionProfile, allowAutomaticUpdate: Bool = true) {
        let key = profile.connectionKey
        guard operations[key] == nil else { return }
        var checking = report(for: profile)
        checking.state = .checking
        checking.message = nil
        reports[key] = checking
        append("Checking installation and remote sessions", kind: .checking, for: profile)
        operations[key] = Task { [weak self] in
            var startAutomaticUpdate = false
            defer {
                self?.operations[key] = nil
                if startAutomaticUpdate {
                    self?.install(profile, explicitlyAuthorized: false)
                }
            }
            do {
                let report = try await RelaydRemoteClient.check(profile: profile)
                self?.reports[key] = report
                self?.append(
                    report.state == .missing ? "relayd is not installed" : "Status received from relayd \(report.version ?? "")",
                    kind: report.state, for: profile
                )
                if allowAutomaticUpdate, report.state == .outdated,
                   self?.isTrusted(profile) == true,
                   RelayPreferences.shared.automaticallyUpdateRelayd {
                    startAutomaticUpdate = true
                }
            } catch {
                let message = error.localizedDescription
                let failure = SSHConnectionFailure.diagnose(message)
                let state: RelaydHostState = failure.kind == .networkRoute ? .unreachable : .failed
                self?.reports[key] = RelaydHostReport(
                    state: state, message: message, checkedAt: Date()
                )
                self?.append(message, kind: state, for: profile)
            }
        }
    }

    func install(
        _ profile: ConnectionProfile,
        explicitlyAuthorized: Bool = true,
        retrying: Bool = false
    ) {
        let key = profile.connectionKey
        guard operations[key] == nil else { return }
        let current = report(for: profile)
        guard current.state == .missing || current.state == .outdated
                || (retrying && current.state == .failed && current.architecture != "—") else { return }
        var installing = current
        installing.state = .installing
        installing.message = "Uploading and verifying the user-scoped helper…"
        reports[key] = installing
        append(
            explicitlyAuthorized ? "Installation authorized" : "Updating approved host",
            kind: .installing, for: profile
        )
        operations[key] = Task { [weak self] in
            var recheckAfterInstall = false
            defer {
                self?.operations[key] = nil
                if recheckAfterInstall {
                    self?.check(profile, allowAutomaticUpdate: false)
                }
            }
            do {
                try await RelaydRemoteClient.install(profile: profile, architecture: current.architecture)
                self?.trust(profile)
                self?.append("Installed, checksum verified, and supervisor started", kind: .ready, for: profile)
                recheckAfterInstall = true
            } catch {
                var report = current
                report.state = .failed
                report.message = error.localizedDescription
                report.checkedAt = Date()
                self?.reports[key] = report
                self?.append(error.localizedDescription, kind: .failed, for: profile)
            }
        }
    }

    func forgetTrust(_ profile: ConnectionProfile) {
        trustedHostKeys.remove(profile.connectionKey)
        persistTrust()
    }

    private func trust(_ profile: ConnectionProfile) {
        trustedHostKeys.insert(profile.connectionKey)
        persistTrust()
    }

    private func persistTrust() {
        UserDefaults.standard.set(Array(trustedHostKeys).sorted(), forKey: trustedDefaultsKey)
    }

    private func append(_ message: String, kind: RelaydHostState, for profile: ConnectionProfile) {
        let key = profile.connectionKey
        var timeline = events[key] ?? []
        timeline.append(RelaydManagerEvent(occurredAt: Date(), message: RelayDiagnostics.redact(message), kind: kind))
        if timeline.count > 40 { timeline.removeFirst(timeline.count - 40) }
        events[key] = timeline
    }
}

extension RelaydHostState {
    var label: String {
        switch self {
        case .unknown: "Not checked"
        case .checking: "Checking"
        case .missing: "Not installed"
        case .ready: "Ready"
        case .outdated: "Update available"
        case .installing: "Installing"
        case .unreachable: "Host unavailable"
        case .failed: "Needs attention"
        }
    }

    var symbol: String {
        switch self {
        case .unknown: "questionmark.circle"
        case .checking: "ellipsis.circle"
        case .missing: "arrow.down.circle"
        case .ready: "checkmark.circle.fill"
        case .outdated: "arrow.trianglehead.2.clockwise.rotate.90.circle"
        case .installing: "arrow.down.circle.fill"
        case .unreachable: "network.slash"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    var color: Color {
        switch self {
        case .ready: RelayTheme.mint
        case .missing, .outdated, .installing: RelayTheme.blue
        case .unreachable, .failed: RelayTheme.coral
        case .unknown, .checking: RelayTheme.textMuted
        }
    }
}

struct RelaydFirstRunView: View {
    let reviewHosts: () -> Void
    let continueWithoutReview: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 25, weight: .medium))
                    .foregroundStyle(RelayTheme.mint)
                    .frame(width: 48, height: 48)
                    .background(RelayTheme.mint.opacity(0.1), in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 5) {
                    Text("Remote sessions use relayd")
                        .font(.system(size: 19, weight: .semibold))
                    Text("A small helper keeps shells running on each remote host while Relay draws the interface on this Mac.")
                        .font(.system(size: 12))
                        .foregroundStyle(RelayTheme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(22)

            Divider().overlay(RelayTheme.line.opacity(0.45))

            VStack(alignment: .leading, spacing: 16) {
                firstRunRow(
                    symbol: "lock.shield",
                    title: "You authorize installation",
                    detail: "Relay checks the remote home first. If relayd is missing, installation waits for you to click Install relayd."
                )
                firstRunRow(
                    symbol: "person.crop.circle.badge.checkmark",
                    title: "One shared-home copy",
                    detail: "The binary is installed at ~/.local/bin/relayd with user-only permissions and reused by nodes sharing that home. Relay never uses sudo."
                )
                firstRunRow(
                    symbol: "checkmark.seal",
                    title: "Verified before activation",
                    detail: "Relay uploads the binary included in the signed app, verifies SHA-256, then replaces the helper atomically."
                )
                firstRunRow(
                    symbol: "terminal",
                    title: "Relay installs its terminal definition",
                    detail: "Normal shells use xterm-relay only after the host can resolve it, with xterm-256color as a safe fallback. Sudo compatibility is shown in Settings and never requests elevation silently."
                )
            }
            .padding(22)

            Divider().overlay(RelayTheme.line.opacity(0.45))

            HStack {
                Text("SSH keys, agents, ProxyJump and known_hosts remain the authorization layer.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(RelayTheme.textMuted)
                Spacer()
                Button("Not now", action: continueWithoutReview)
                Button("Review remote hosts", action: reviewHosts)
                    .buttonStyle(.borderedProminent)
                    .tint(RelayTheme.accent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(18)
        }
        .frame(width: 590)
        .foregroundStyle(RelayTheme.text)
        .background(RelayTheme.sidebar)
        .preferredColorScheme(.dark)
    }

    private func firstRunRow(symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(RelayTheme.blue)
                .frame(width: 25, height: 25)
                .background(RelayTheme.elevated, in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(RelayTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct RelaydManagerView: View {
    @ObservedObject var profileStore: ProfileStore
    let preferredProfile: ConnectionProfile?
    @ObservedObject private var manager = RelaydManager.shared
    @ObservedObject private var preferences = RelayPreferences.shared
    @Environment(\.dismiss) private var dismiss

    private var profiles: [ConnectionProfile] {
        profileStore.connectableHosts.filter { $0.kind == .ssh }
    }

    private var selectedProfile: ConnectionProfile? {
        let key = manager.selectedHostKey
        return profiles.first { $0.connectionKey == key } ?? profiles.first
    }

    var body: some View {
        HStack(spacing: 0) {
            hostRail
                .frame(width: 220)
            Divider().overlay(RelayTheme.line.opacity(0.5))
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 860, height: 610)
        .foregroundStyle(RelayTheme.text)
        .background(RelayTheme.canvas)
        .preferredColorScheme(.dark)
        .onAppear {
            profileStore.refreshSSHConfig()
            if let preferredProfile { manager.select(preferredProfile) }
            else if manager.selectedHostKey == nil, let first = profiles.first { manager.select(first) }
            if let selectedProfile { manager.check(selectedProfile) }
        }
    }

    private var hostRail: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Remote helpers")
                    .font(.system(size: 15, weight: .semibold))
                Text("One shared binary · one supervisor per node")
                    .font(.system(size: 10.5))
                    .foregroundStyle(RelayTheme.textMuted)
            }
            .padding(18)

            Divider().overlay(RelayTheme.line.opacity(0.4))

            if profiles.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 18))
                        .foregroundStyle(RelayTheme.textFaint)
                    Text("No SSH hosts found")
                        .font(.system(size: 11.5, weight: .semibold))
                    Text("Add a host to ~/.ssh/config or save one from Connect.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(RelayTheme.textMuted)
                }
                .padding(18)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(profiles) { profile in
                            let report = manager.report(for: profile)
                            Button {
                                manager.select(profile)
                                manager.check(profile)
                            } label: {
                                HStack(spacing: 9) {
                                    Circle().fill(report.state.color).frame(width: 6, height: 6)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(profile.name)
                                            .font(.system(size: 11.5, weight: .medium))
                                            .lineLimit(1)
                                        Text(report.state.label)
                                            .font(.system(size: 9.5))
                                            .foregroundStyle(RelayTheme.textMuted)
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 10)
                                .frame(height: 44)
                                .contentShape(Rectangle())
                                .background(
                                    manager.selectedHostKey == profile.connectionKey
                                        ? RelayTheme.elevated : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 9)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(8)
                }
            }
            Spacer(minLength: 0)
        }
        .background(RelayTheme.sidebar)
    }

    @ViewBuilder
    private var detail: some View {
        if let profile = selectedProfile {
            hostDetail(profile)
        } else {
            VStack(spacing: 9) {
                Image(systemName: "server.rack")
                    .font(.system(size: 23))
                    .foregroundStyle(RelayTheme.textFaint)
                Text("Select an SSH host")
                    .font(.system(size: 13, weight: .semibold))
            }
        }
    }

    private func hostDetail(_ profile: ConnectionProfile) -> some View {
        let report = manager.report(for: profile)
        let timeline = manager.timeline(for: profile)
        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(profile.name)
                            .font(.system(size: 17, weight: .semibold))
                        Label(report.state.label, systemImage: report.state.symbol)
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(report.state.color)
                    }
                    Text(profile.subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(RelayTheme.textMuted)
                }
                Spacer()
                Button("Check now") { manager.check(profile) }
                    .disabled(report.state == .checking || report.state == .installing)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .frame(height: 70)

            Divider().overlay(RelayTheme.line.opacity(0.45))

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let message = report.message {
                        Label(message, systemImage: report.state.symbol)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(report.state.color)
                            .padding(.horizontal, 11)
                            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                            .background(report.state.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
                    }

                    metrics(report)

                    HStack(spacing: 9) {
                        Image(systemName: manager.isTrusted(profile) ? "checkmark.shield" : "shield")
                            .foregroundStyle(manager.isTrusted(profile) ? RelayTheme.mint : RelayTheme.textMuted)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(manager.isTrusted(profile) ? "Updates approved from this host" : "Installation not yet approved")
                                .font(.system(size: 10.5, weight: .semibold))
                            Text("Automatic updates apply only after one explicit installation approval.")
                                .font(.system(size: 9.5))
                                .foregroundStyle(RelayTheme.textMuted)
                        }
                        Spacer()
                        if manager.isTrusted(profile) {
                            Button("Forget approval") { manager.forgetTrust(profile) }
                                .buttonStyle(.borderless)
                                .font(.system(size: 10.5))
                        }
                        Toggle("Automatic updates", isOn: $preferences.automaticallyUpdateRelayd)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .font(.system(size: 10.5))
                    }
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)
                    .background(RelayTheme.surface, in: RoundedRectangle(cornerRadius: 10))

                    if report.state == .missing || report.state == .outdated
                        || (report.state == .failed && report.architecture != "—") {
                        installationCard(profile: profile, report: report)
                    }

                    VStack(alignment: .leading, spacing: 9) {
                        sectionLabel("Connection timeline")
                        if timeline.isEmpty {
                            Text("Checks and installation steps appear here.")
                                .font(.system(size: 10.5))
                                .foregroundStyle(RelayTheme.textMuted)
                        } else {
                            ForEach(timeline.suffix(8)) { event in
                                HStack(alignment: .top, spacing: 9) {
                                    Circle().fill(event.kind.color).frame(width: 6, height: 6).padding(.top, 4)
                                    Text(event.occurredAt, style: .time)
                                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                                        .foregroundStyle(RelayTheme.textFaint)
                                        .frame(width: 54, alignment: .leading)
                                    Text(event.message)
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(RelayTheme.textMuted)
                                        .textSelection(.enabled)
                                    Spacer()
                                }
                            }
                        }
                    }
                    .padding(13)
                    .background(RelayTheme.surface, in: RoundedRectangle(cornerRadius: 11))

                    VStack(alignment: .leading, spacing: 9) {
                        HStack {
                            sectionLabel("relayd log")
                            Spacer()
                            Text("last 80 lines")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(RelayTheme.textFaint)
                        }
                        ScrollView(.horizontal) {
                            Text(report.logLines.isEmpty ? "No supervisor log output." : report.logLines.joined(separator: "\n"))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(RelayTheme.textMuted)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, minHeight: 76, alignment: .topLeading)
                        }
                    }
                    .padding(13)
                    .background(RelayTheme.surface, in: RoundedRectangle(cornerRadius: 11))
                }
                .padding(20)
            }
        }
    }

    private func metrics(_ report: RelaydHostReport) -> some View {
        HStack(spacing: 8) {
            metric("Version", report.version ?? "—")
            metric(
                "Supervisor",
                report.supervisorPID.map { "\(report.liveVersion ?? "unknown") · \($0)" } ?? "Stopped"
            )
            metric("Sessions", String(report.sessionCount))
            metric("Panes", "\(report.runningPaneCount)/\(report.paneCount)")
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.system(size: 8.5, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(RelayTheme.textFaint)
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(RelayTheme.text)
                .lineLimit(1)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RelayTheme.surface, in: RoundedRectangle(cornerRadius: 10))
    }

    private func installationCard(profile: ConnectionProfile, report: RelaydHostReport) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: "lock.shield")
                    .foregroundStyle(RelayTheme.blue)
                    .frame(width: 28, height: 28)
                    .background(RelayTheme.blue.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 3) {
                    Text(installationTitle(for: report))
                        .font(.system(size: 12, weight: .semibold))
                    Text("Installs an architecture-selecting launcher, this node’s signed payload, and Relay-owned Claude/Codex shims. An existing rcode command is preserved. No sudo, service, or network port.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(RelayTheme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            HStack {
                Text("Linux \(report.architecture)  ·  relayd \(RelaydRemoteClient.expectedVersion)  ·  SHA-256 verified")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(RelayTheme.textFaint)
                Spacer()
                Button(installationButtonTitle(for: report)) {
                    manager.install(profile, explicitlyAuthorized: true, retrying: report.state == .failed)
                }
                .buttonStyle(.borderedProminent)
                .tint(RelayTheme.accent)
            }
        }
        .padding(14)
        .background(RelayTheme.elevated, in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(RelayTheme.blue.opacity(0.25)) }
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(RelayTheme.text)
    }

    private func installationTitle(for report: RelaydHostReport) -> String {
        if report.state == .failed { return "Retry relayd installation" }
        return report.state == .missing ? "Install relayd in the shared home" : "Update shared relayd binary"
    }

    private func installationButtonTitle(for report: RelaydHostReport) -> String {
        if report.state == .failed { return "Retry installation" }
        return report.state == .missing ? "Install relayd" : "Update relayd"
    }
}

extension Notification.Name {
    static let relayManageRelayd = Notification.Name("relay.manage-relayd")
}
