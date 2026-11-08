import CryptoKit
import Foundation
import SwiftUI

enum RelaydHostState: String, Codable, Equatable, Sendable {
    case unknown
    case checking
    case missing
    case ready
    case outdated
    case installing
    case unreachable
    case failed
}

struct RelaydHostReport: Codable, Equatable, Sendable {
    var state: RelaydHostState = .unknown
    var architecture = "—"
    var version: String?
    var payloadHash: String?
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

    static func parse(
        _ data: Data,
        expectedVersion: String,
        expectedPayloadHashes: [String: String] = [:]
    ) throws -> RelaydHostReport {
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
        let payloadHash: String?
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
            payloadHash = fields.count >= 10 && fields[9] != "unknown"
                ? fields[9].lowercased() : nil
        } else if fields.count >= 5 {
            nonce = nil
            architecture = fields[1]
            version = normalizedVersion(fields[2])
            supervisorPID = supervisorPIDValue(fields[3])
            liveVersion = supervisorPID == nil ? nil : version
            protocolVersion = nil
            catalogHealthy = true
            payloadHash = nil
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
        let expectedPayloadHash = expectedPayloadHashes[normalizedArchitecture(architecture)]?.lowercased()
        // A semantic version identifies the wire contract, not the exact
        // daemon build. Development and patched release builds may retain the
        // same version, so compare the signed app payload before declaring a
        // trusted host current. Never use a hash mismatch to downgrade a
        // genuinely newer remote version.
        let payloadIsCurrent = expectedPayloadHash == nil ||
            installedOrder == .orderedDescending ||
            payloadHash == expectedPayloadHash
        let state: RelaydHostState = installedOrder != .orderedAscending &&
            liveIsCurrent && catalogHealthy && payloadIsCurrent
            ? .ready : .outdated
        let message: String?
        if !catalogHealthy {
            message = "relayd could not read its session catalog. Reinstall to repair it."
        } else if installedOrder == .orderedAscending {
            message = "Installed version \(version); Relay includes \(expectedVersion)."
        } else if installedOrder == .orderedDescending {
            message = "The host has newer relayd \(version). This app will not downgrade it."
        } else if !payloadIsCurrent {
            message = "Installed relayd \(version) is a different build from the helper included with this app."
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
            payloadHash: payloadHash,
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

    private static func normalizedArchitecture(_ value: String) -> String {
        switch value.lowercased() {
        case "x86_64", "amd64": "amd64"
        case "aarch64", "arm64": "arm64"
        default: value.lowercased()
        }
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
            let expectedPayloadHashes = bundledPayloadHashes()
            let result = try await RelayHostExecution.capture(profile: profile,
                command: statusScript, timeout: 15, maximumBytes: 2 << 20, directory: "/")
            guard result.exitCode == 0 else {
                let message = String(decoding: result.stderr, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw RelaydManagementError.commandFailed(
                    message.isEmpty ? "Could not check relayd on \(profile.name)." : message
                )
            }
            return try RelaydStatusParser.parse(
                result.stdout,
                expectedVersion: expectedVersion,
                expectedPayloadHashes: expectedPayloadHashes
            )
        }.value
    }

    private static func bundledPayloadHashes() -> [String: String] {
        ["amd64", "arm64"].reduce(into: [String: String]()) { hashes, architecture in
            let name = "relayd-linux-\(architecture)"
            guard let url = Bundle.main.resourceURL?.appendingPathComponent(name),
                  let binary = try? Data(contentsOf: url), !binary.isEmpty else { return }
            hashes[architecture] = SHA256.hash(data: binary)
                .map { String(format: "%02x", $0) }
                .joined()
        }
    }

    static func install(profile: ConnectionProfile, architecture: String) async throws {
        try await Task.detached(priority: .userInitiated) {
            let goArchitecture: String
            switch architecture.lowercased() {
            case "x86_64", "amd64": goArchitecture = "amd64"
            case "aarch64", "arm64": goArchitecture = "arm64"
            default: throw RelaydManagementError.unsupportedArchitecture(architecture)
            }
            let binary = try installationArchive(architecture: goArchitecture)
            let hash = SHA256.hash(data: binary).map { String(format: "%02x", $0) }.joined()
            let script = installScript(expectedHash: hash, architecture: goArchitecture)
            // Replacing a supervisor is normally immediate, but a loaded HPC
            // login node can take tens of seconds to schedule the new daemon
            // and answer its authenticated probe. Keep the UI operation
            // bounded without turning a successful handoff into a false
            // installation failure.
            let result = try runSSH(profile: profile, script: script, input: binary, timeout: 300)
            guard result.status == 0 else {
                let message = result.error.trimmingCharacters(in: .whitespacesAndNewlines)
                throw RelaydManagementError.commandFailed(
                    message.isEmpty ? "Could not install relayd on \(profile.name)." : message
                )
            }
        }.value
    }

    // Kept equal to the native helperbundle catalogue by its Go integration check.
    static let nativeHelperNames: [String] = [
        "relay-connection",
        "relay-workspace",
        "relay-codex-session",
        "relay-mcp-desktop",
        "relay-settings",
        "relay-check-website",
        "relay-provider-setup",
        "relay-install-shell-ui",
        "relay-repair-chitta-failure",
        "relay-codex-mcp-health",
        "relay-remote-mcp-bridge",
        "relay-build-codehost",
        "relay-install-codex",
        "relay-repair-codehost",
        "relay-client",
    ]

    private static func installationArchive(architecture: String) throws -> Data {
        let names = ["relayd-linux-\(architecture)", "relay-mcp-linux-\(architecture)",
                     "relay-peer-link-linux-\(architecture)", "relay-release.json"] + nativeHelperNames.map { "\($0)-linux-\(architecture)" }
        guard let resources = Bundle.main.resourceURL else {
            throw RelaydManagementError.bundledBinaryMissing(architecture)
        }
        for name in names {
            guard FileManager.default.isReadableFile(atPath: resources.appendingPathComponent(name).path) else {
                throw RelaydManagementError.bundledBinaryMissing(name)
            }
        }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-cf", "-", "-C", resources.path] + names
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let archive = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, !archive.isEmpty else {
            throw RelaydManagementError.commandFailed("Could not package the bundled Relay helpers.")
        }
        return archive
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
case "$arch" in
    x86_64|amd64) payload_arch=amd64 ;;
    aarch64|arm64) payload_arch=arm64 ;;
    *) payload_arch=unknown ;;
esac
payload="$HOME/.local/share/relay/bin/relayd-linux-$payload_arch"
payload_hash=unknown
if [ -r "$payload" ]; then
    if command -v sha256sum >/dev/null 2>&1; then
        payload_hash="$(sha256sum "$payload" | awk '{print $1}')"
    elif command -v shasum >/dev/null 2>&1; then
        payload_hash="$(shasum -a 256 "$payload" | awk '{print $1}')"
    fi
fi
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
printf 'RELAYD_STATUS\t%s\t%s\t%s\t%s\t%s\t%s\t3\t%s\t%s\n' \
    "$nonce" "$arch" "$version" "$live_version" "$live_protocol" "$relay_pid" "$catalog_ok" "$payload_hash"
printf 'RELAYD_CATALOG_BEGIN\t%s\n' "$nonce"
printf '%s\n' "$catalog_output"
printf 'RELAYD_CATALOG_END\t%s\nRELAYD_LOG_BEGIN\t%s\n' "$nonce" "$nonce"
tail -n 80 "$(dirname "$relay_socket")/relayd.log" 2>/dev/null || true
printf 'RELAYD_LOG_END\t%s\n' "$nonce"
"""#

    static func installScript(expectedHash: String, architecture: String) -> String {
        #"""
set -eu
umask 077
bin_dir="$HOME/.local/bin"
relay_root="$HOME/.local/share/relay"
payload_dir="$relay_root/bin"
shim_dir="$HOME/.local/share/relay/shims"
lock_dir="$relay_root/install.lock"
case "$(uname -s 2>/dev/null || printf unknown)" in
    Linux) shim_move_flag=-fT ;;
    Darwin) shim_move_flag=-fh ;;
    *) printf 'Relay installation: unsupported host operating system\n' >&2; exit 1 ;;
esac
if [ -d "$shim_dir/relay-native-tool" ] && [ ! -L "$shim_dir/relay-native-tool" ]; then
    printf 'Relay native tool path is a directory; leaving it unchanged.\n' >&2
    exit 1
fi
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
stage_dir=
launcher_temporary=
tool_launcher_temporary=
link_temporary=
trap 'rm -f "$temporary" "$launcher_temporary" "$tool_launcher_temporary" "$link_temporary"; if [ -n "$stage_dir" ]; then rm -rf "$stage_dir"; fi; rmdir "$lock_dir" 2>/dev/null || true' EXIT HUP INT TERM
temporary="$(mktemp "$payload_dir/.relayd-install-\#(architecture).XXXXXX")"
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
if [ "$actual" != "\#(expectedHash)" ]; then
    printf 'Uploaded Relay helpers checksum did not match the signed application resources.\n' >&2
    exit 1
fi
stage_dir="$(mktemp -d "$payload_dir/.relay-install.XXXXXX")"
tar -xf "$temporary" -C "$stage_dir"
for helper in relayd relay-mcp relay-peer-link \#(nativeHelperNames.joined(separator: " ")); do
    payload="$helper-linux-\#(architecture)"
    if [ ! -f "$stage_dir/$payload" ] || [ ! -s "$stage_dir/$payload" ] || [ -L "$stage_dir/$payload" ]; then
        printf 'The bundled %s payload is missing or invalid.\n' "$helper" >&2
        exit 1
    fi
done
if [ ! -f "$stage_dir/relay-release.json" ] || [ ! -s "$stage_dir/relay-release.json" ] || [ -L "$stage_dir/relay-release.json" ]; then
    printf 'The bundled Relay release manifest is missing or invalid.\n' >&2
    exit 1
fi
# Validate every final publication entry before replacing any payload. A
# symlink is replaced as an entry; its target is never a publication directory.
relay_check_destination() {
    if [ ! -L "$1" ] && { [ -d "$1" ] || { [ -e "$1" ] && [ ! -f "$1" ]; }; }; then
        printf 'Relay installation destination is not a file or symlink: %s\n' "$1" >&2
        return 1
    fi
}
for helper in relayd relay-mcp relay-peer-link \#(nativeHelperNames.joined(separator: " ")); do
    relay_check_destination "$payload_dir/$helper-linux-\#(architecture)"
done
# The app runs the peer helper from peer-network/; nothing else updates it.
peer_dir="$relay_root/peer-network"
mkdir -p "$peer_dir"
for relay_destination in "$relay_root/relay-release.json" "$bin_dir/relayd" "$shim_dir/relay-native-tool" \
    "$payload_dir/relayd-communication" "$payload_dir/relayd-verified" \
    "$payload_dir/relay-mcp-communication" "$payload_dir/relay-mcp" "$payload_dir/relay-peer-link" "$peer_dir/relay-peer-link"; do
    relay_check_destination "$relay_destination"
done
for helper in relayd relay-mcp relay-peer-link \#(nativeHelperNames.joined(separator: " ")); do
    payload="$helper-linux-\#(architecture)"
    chmod 700 "$stage_dir/$payload"
    mv "$shim_move_flag" "$stage_dir/$payload" "$payload_dir/$payload"
done
mv "$shim_move_flag" "$stage_dir/relay-release.json" "$relay_root/relay-release.json"
relay_publish_link() {
    link_temporary="$(mktemp "$payload_dir/.relay-link.XXXXXX")"
    rm -f "$link_temporary"
    ln -s "$1" "$link_temporary"
    mv "$shim_move_flag" "$link_temporary" "$2"
    link_temporary=
}
relay_publish_link "relayd-linux-\#(architecture)" "$payload_dir/relayd-communication"
relay_publish_link "relayd-linux-\#(architecture)" "$payload_dir/relayd-work-communication"
relay_publish_link "relayd-linux-\#(architecture)" "$payload_dir/relayd-verified"
relay_publish_link "relay-mcp-linux-\#(architecture)" "$payload_dir/relay-mcp-communication"
relay_publish_link "relay-mcp-linux-\#(architecture)" "$payload_dir/relay-mcp"
relay_publish_link "relay-peer-link-linux-\#(architecture)" "$payload_dir/relay-peer-link"
if [ -f "$peer_dir/relay-peer-link" ] && [ ! -L "$peer_dir/relay-peer-link" ]; then
    cp -p "$peer_dir/relay-peer-link" "$peer_dir/relay-peer-link.before-install"
fi
relay_publish_link "../bin/relay-peer-link-linux-\#(architecture)" "$peer_dir/relay-peer-link"
# A shared home can be mounted by different CPU architectures. Administrative
# commands select this node's payload at invocation, as the daemon launcher does.
tool_launcher_temporary="$(mktemp "$shim_dir/.relay-native-tool.XXXXXX")"
cat > "$tool_launcher_temporary" <<'RELAY_NATIVE_TOOL'
#!/bin/sh
set -eu
case "$(uname -m 2>/dev/null || printf unknown)" in
    x86_64|amd64) relay_arch=amd64 ;;
    aarch64|arm64) relay_arch=arm64 ;;
    *) printf 'Relay tool: unsupported architecture\n' >&2; exit 1 ;;
esac
relay_tool="$(basename "$0")"
case "$relay_tool" in
    \#(nativeHelperNames.joined(separator: "|"))) ;;
    *) printf 'Unknown Relay tool\n' >&2; exit 1 ;;
esac
exec "$HOME/.local/share/relay/bin/$relay_tool-linux-$relay_arch" "$@"
RELAY_NATIVE_TOOL
chmod 700 "$tool_launcher_temporary"
mv "$shim_move_flag" "$tool_launcher_temporary" "$shim_dir/relay-native-tool"
for helper in \#(nativeHelperNames.joined(separator: " ")); do
    command_path="$bin_dir/$helper"
    if [ ! -e "$command_path" ] && [ ! -L "$command_path" ]; then
        ln -s "$shim_dir/relay-native-tool" "$command_path"
    elif [ -L "$command_path" ] && [ "$(readlink "$command_path")" = "$shim_dir/relay-native-tool" ]; then
        ln -sfn "$shim_dir/relay-native-tool" "$command_path"
    else
        printf 'Relay left the existing %s command unchanged.\n' "$helper" >&2
    fi
done
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
mv "$shim_move_flag" "$launcher_temporary" "$bin_dir/relayd"
# relayd installs or repairs its own claude/codex launchers: missing ones are
# written, stale Relay ones fixed, and any file Relay did not write is kept.
if ! "$bin_dir/relayd" agent-launchers --repair >/dev/null; then
    printf 'Relay could not install its claude/codex launchers on this host; Settings > Agent Accounts shows why.\n' >&2
fi
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
if ! "$bin_dir/relayd" upgrade-supervisor --force --archive-host-jobs; then
    sleep 1
    "$bin_dir/relayd" upgrade-supervisor
fi
# Move live pane workers onto the new relayd in place (same PID, shell and
# PTY), detached so a host with many panes does not hold this install open.
# Workers already on it and legacy workers are left as they are; busy panes
# (mid-edit or mid-rotation) are retried 10 times, 30 s apart. The receipt
# lists each pane's result.
receipt="$relay_root/upgrade-workers-last.json"
( nohup sh -c '"$1" upgrade-workers > "$2.tmp" 2>&1; mv -f "$2.tmp" "$2"' upgrade-workers "$bin_dir/relayd" "$receipt" \
    </dev/null >/dev/null 2>&1 & )
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
        ] + profile.sshConnectionArguments + ["sh", "-c", ShellQuoting.quote(script)]
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

    /// Runs `script` in its own SSH session, outside relayd's host jobs, so it
    /// can restart the supervisor those jobs run under.
    static func runDirect(profile: ConnectionProfile, script: String, timeout: TimeInterval)
        throws -> (status: Int32, output: String, error: String) {
        let result = try runSSH(profile: profile, script: script, timeout: timeout)
        return (result.status, String(decoding: result.output, as: UTF8.self), result.error)
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
    private let updateProgress: RelaydHostUpdateProgress
    private let remoteCheck: @MainActor (ConnectionProfile) async throws -> RelaydHostReport

    /// Tests pass their own progress store and remote check.
    init(defaults: UserDefaults = .standard, progress: RelaydHostUpdateProgress = .shared,
         remoteCheck: @escaping @MainActor (ConnectionProfile) async throws -> RelaydHostReport = { try await RelaydRemoteClient.check(profile: $0) }) {
        trustedHostKeys = Set(defaults.stringArray(forKey: trustedDefaultsKey) ?? [])
        updateProgress = progress
        self.remoteCheck = remoteCheck
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

    func checkForRequest(_ profile: ConnectionProfile) async -> RelaydHostReport? {
        let key = profile.connectionKey
        guard operations[key] == nil else { return nil }
        check(profile, allowAutomaticUpdate: false)
        if let operation = operations[key] { await operation.value }
        return reports[key]
    }

    func check(_ profile: ConnectionProfile, allowAutomaticUpdate: Bool = true) {
        let key = profile.connectionKey
        RelayHostRegistry.shared.register(profile, origin: "Relay installation manager")
        guard operations[key] == nil else { return }
        let checkStarted = Date()
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
                guard let check = self?.remoteCheck else { return }
                let report = try await check(profile)
                self?.reports[key] = report
                self?.updateProgress.checkCompleted(key: key, startedAt: checkStarted)
                RelayHostRegistry.shared.observe(report, profile: profile)
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
                let report = RelaydHostReport(
                    state: state, message: message, checkedAt: Date()
                )
                self?.reports[key] = report
                self?.updateProgress.checkCompleted(key: key, startedAt: checkStarted)
                RelayHostRegistry.shared.observeFailedCheck(report, profile: profile)
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
        RelayHostRegistry.shared.register(profile, origin: "Relay installation manager")
        guard operations[key] == nil else { return }
        let current = report(for: profile)
        guard current.state == .missing || current.state == .outdated
                || (retrying && current.state == .failed && current.architecture != "—") else { return }
        updateProgress.installStarted(key: key)
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
                RelayHostRegistry.shared.observe(report, profile: profile)
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
        RelayStateProfile.defaults.set(Array(trustedHostKeys).sorted(), forKey: trustedDefaultsKey)
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
        VStack(spacing: RelayTheme.spacing(0)) {
            HStack(alignment: .top, spacing: RelayTheme.spacing(16)) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(RelayTheme.font(size: 25, weight: .medium))
                    .foregroundStyle(RelayTheme.mint)
                    .frame(width: 48, height: 48)
                    .background(RelayTheme.mint.opacity(0.1), in: RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(13)))
                VStack(alignment: .leading, spacing: RelayTheme.spacing(5)) {
                    Text("Remote sessions use relayd")
                        .font(RelayTheme.font(size: 19, weight: .semibold))
                    Text("A small helper keeps shells running on each remote host while Relay draws the interface on this Mac.")
                        .font(RelayTheme.font(size: 12))
                        .foregroundStyle(RelayTheme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(RelayTheme.spacing(22))

            Divider().overlay(RelayTheme.line.opacity(0.45))

            VStack(alignment: .leading, spacing: RelayTheme.spacing(16)) {
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
            .padding(RelayTheme.spacing(22))

            Divider().overlay(RelayTheme.line.opacity(0.45))

            HStack {
                Text("SSH keys, agents, ProxyJump and known_hosts remain the authorization layer.")
                    .font(RelayTheme.font(size: 10.5))
                    .foregroundStyle(RelayTheme.textMuted)
                Spacer()
                Button("Not now", action: continueWithoutReview)
                Button("Review remote hosts", action: reviewHosts)
                    .buttonStyle(RelayPrimaryButtonStyle())
                    .tint(RelayTheme.accent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(RelayTheme.spacing(18))
        }
        .frame(width: 590)
        .foregroundStyle(RelayTheme.text)
        .background(RelayTheme.sidebar)
        .relaySurface()
    }

    private func firstRunRow(symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: RelayTheme.spacing(12)) {
            Image(systemName: symbol)
                .font(RelayTheme.font(size: 13, weight: .semibold))
                .foregroundStyle(RelayTheme.blue)
                .frame(width: 25, height: 25)
                .background(RelayTheme.elevated, in: RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(7)))
            VStack(alignment: .leading, spacing: RelayTheme.spacing(3)) {
                Text(title).font(RelayTheme.font(size: 12, weight: .semibold))
                Text(detail)
                    .font(RelayTheme.font(size: 10.5))
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
    @ObservedObject private var updates = RelaydHostUpdateProgress.shared
    @Environment(\.dismiss) private var dismiss

    private var profiles: [ConnectionProfile] {
        profileStore.connectableHosts.filter { $0.kind == .ssh }
    }

    private var selectedProfile: ConnectionProfile? {
        let key = manager.selectedHostKey
        return profiles.first { $0.connectionKey == key } ?? profiles.first
    }

    var body: some View {
        HStack(spacing: RelayTheme.spacing(0)) {
            hostRail
                .frame(width: 220)
            Divider().overlay(RelayTheme.line.opacity(0.5))
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 860, height: 610)
        .foregroundStyle(RelayTheme.text)
        .background(RelayTheme.canvas)
        .relaySurface()
        .onAppear {
            profileStore.refreshSSHConfig()
            if let preferredProfile { manager.select(preferredProfile) }
            else if manager.selectedHostKey == nil, let first = profiles.first { manager.select(first) }
            if let selectedProfile { manager.check(selectedProfile) }
        }
    }

    private var hostRail: some View {
        VStack(alignment: .leading, spacing: RelayTheme.spacing(0)) {
            VStack(alignment: .leading, spacing: RelayTheme.spacing(3)) {
                Text("Remote helpers")
                    .font(RelayTheme.font(size: 15, weight: .semibold))
                Text("One shared binary · one supervisor per node")
                    .font(RelayTheme.font(size: 10.5))
                    .foregroundStyle(RelayTheme.textMuted)
            }
            .padding(RelayTheme.spacing(18))

            Divider().overlay(RelayTheme.line.opacity(0.4))

            if profiles.isEmpty {
                VStack(alignment: .leading, spacing: RelayTheme.spacing(8)) {
                    Image(systemName: "server.rack")
                        .font(RelayTheme.font(size: 18))
                        .foregroundStyle(RelayTheme.textFaint)
                    Text("No SSH hosts found")
                        .font(RelayTheme.font(size: 11.5, weight: .semibold))
                    Text("Add a host to ~/.ssh/config or save one from Connect.")
                        .font(RelayTheme.font(size: 10.5))
                        .foregroundStyle(RelayTheme.textMuted)
                }
                .padding(RelayTheme.spacing(18))
            } else {
                ScrollView {
                    LazyVStack(spacing: RelayTheme.spacing(4)) {
                        ForEach(profiles) { profile in
                            let report = manager.report(for: profile)
                            Button {
                                manager.select(profile)
                                manager.check(profile)
                            } label: {
                                HStack(spacing: RelayTheme.spacing(9)) {
                                    Circle().fill(report.state.color).frame(width: 6, height: 6)
                                    VStack(alignment: .leading, spacing: RelayTheme.spacing(2)) {
                                        Text(profile.name)
                                            .font(RelayTheme.font(size: 11.5, weight: .medium))
                                            .lineLimit(1)
                                        Text(report.state.label)
                                            .font(RelayTheme.font(size: 9.5))
                                            .foregroundStyle(RelayTheme.textMuted)
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, RelayTheme.spacing(10))
                                .frame(height: 44)
                                .contentShape(Rectangle())
                                .background(
                                    manager.selectedHostKey == profile.connectionKey
                                        ? RelayTheme.elevated : Color.clear,
                                    in: RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(9))
                                )
                            }
                            .buttonStyle(.plain)
                            if let update = updates.entry(forKey: profile.connectionKey) {
                                updateRow(update, profile: profile)
                            }
                        }
                    }
                    .padding(RelayTheme.spacing(8))
                }
            }
            Spacer(minLength: 0)
        }
        .background(RelayTheme.sidebar)
    }

    /// The host's relayd update: elapsed time while it runs, then its
    /// outcome. Details opens this host's detail. A sibling of the host
    /// button, not inside it, so its own button stays clickable.
    private func updateRow(_ entry: RelaydHostUpdateProgress.Entry, profile: ConnectionProfile) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let row = RelaydHostUpdateRow(entry: entry, now: context.date)
            HStack(alignment: .firstTextBaseline, spacing: RelayTheme.spacing(6)) {
                if entry.phase == .updating { ProgressView().controlSize(.mini) }
                Text(row.text)
                    .font(RelayTheme.font(size: 9.5))
                    .foregroundStyle(row.tone == .success ? RelayTheme.success
                        : row.tone == .failure ? RelayTheme.red : RelayTheme.textMuted)
                    .lineLimit(3)
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .leading)
                if row.showsDetails {
                    // Select only: a check could collide with a still-running install.
                    Button("Details") { manager.select(profile) }
                    .buttonStyle(.link)
                    .font(RelayTheme.font(size: 9.5))
                }
            }
            .padding(.horizontal, RelayTheme.spacing(10))
            .padding(.bottom, RelayTheme.spacing(4))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("relayd.update." + profile.connectionKey)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let profile = selectedProfile {
            hostDetail(profile)
        } else {
            VStack(spacing: RelayTheme.spacing(9)) {
                Image(systemName: "server.rack")
                    .font(RelayTheme.font(size: 23))
                    .foregroundStyle(RelayTheme.textFaint)
                Text("Select an SSH host")
                    .font(RelayTheme.font(size: 13, weight: .semibold))
            }
        }
    }

    private func hostDetail(_ profile: ConnectionProfile) -> some View {
        let report = manager.report(for: profile)
        let timeline = manager.timeline(for: profile)
        return VStack(spacing: RelayTheme.spacing(0)) {
            HStack(spacing: RelayTheme.spacing(12)) {
                VStack(alignment: .leading, spacing: RelayTheme.spacing(3)) {
                    HStack(spacing: RelayTheme.spacing(7)) {
                        Text(profile.name)
                            .font(RelayTheme.font(size: 17, weight: .semibold))
                        Label(report.state.label, systemImage: report.state.symbol)
                            .font(RelayTheme.font(size: 9.5, weight: .semibold))
                            .foregroundStyle(report.state.color)
                    }
                    Text(profile.subtitle)
                        .font(RelayTheme.font(size: 10.5))
                        .foregroundStyle(RelayTheme.textMuted)
                }
                Spacer()
                Button("Check now") { manager.check(profile) }
                    .disabled(report.state == .checking || report.state == .installing)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, RelayTheme.spacing(20))
            .frame(height: 70)

            Divider().overlay(RelayTheme.line.opacity(0.45))

            ScrollView {
                VStack(alignment: .leading, spacing: RelayTheme.spacing(16)) {
                    if let message = report.message {
                        Label(message, systemImage: report.state.symbol)
                            .font(RelayTheme.font(size: 10.5, weight: .medium))
                            .foregroundStyle(report.state.color)
                            .padding(.horizontal, RelayTheme.spacing(11))
                            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                            .background(report.state.color.opacity(0.08), in: RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(9)))
                    }

                    metrics(report)

                    HStack(spacing: RelayTheme.spacing(9)) {
                        Image(systemName: manager.isTrusted(profile) ? "checkmark.shield" : "shield")
                            .foregroundStyle(manager.isTrusted(profile) ? RelayTheme.mint : RelayTheme.textMuted)
                        VStack(alignment: .leading, spacing: RelayTheme.spacing(2)) {
                            Text(manager.isTrusted(profile) ? "Updates approved from this host" : "Installation not yet approved")
                                .font(RelayTheme.font(size: 10.5, weight: .semibold))
                            Text("Automatic updates apply only after one explicit installation approval.")
                                .font(RelayTheme.font(size: 9.5))
                                .foregroundStyle(RelayTheme.textMuted)
                        }
                        Spacer()
                        if manager.isTrusted(profile) {
                            Button("Forget approval") { manager.forgetTrust(profile) }
                                .buttonStyle(.borderless)
                                .font(RelayTheme.font(size: 10.5))
                        }
                        Toggle("Automatic updates", isOn: $preferences.automaticallyUpdateRelayd)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .font(RelayTheme.font(size: 10.5))
                    }
                    .padding(.horizontal, RelayTheme.spacing(12))
                    .frame(minHeight: 44)
                    .background(RelayTheme.surface, in: RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(10)))

                    if report.state == .missing || report.state == .outdated
                        || (report.state == .failed && report.architecture != "—") {
                        installationCard(profile: profile, report: report)
                    }

                    VStack(alignment: .leading, spacing: RelayTheme.spacing(9)) {
                        sectionLabel("Connection timeline")
                        if timeline.isEmpty {
                            Text("Checks and installation steps appear here.")
                                .font(RelayTheme.font(size: 10.5))
                                .foregroundStyle(RelayTheme.textMuted)
                        } else {
                            ForEach(timeline.suffix(8)) { event in
                                HStack(alignment: .top, spacing: RelayTheme.spacing(9)) {
                                    Circle().fill(event.kind.color).frame(width: 6, height: 6).padding(.top, RelayTheme.spacing(4))
                                    Text(event.occurredAt, style: .time)
                                        .font(RelayTheme.font(size: 9.5, weight: .medium, design: .monospaced))
                                        .foregroundStyle(RelayTheme.textFaint)
                                        .frame(width: 54, alignment: .leading)
                                    Text(event.message)
                                        .font(RelayTheme.font(size: 10.5))
                                        .foregroundStyle(RelayTheme.textMuted)
                                        .textSelection(.enabled)
                                    Spacer()
                                }
                            }
                        }
                    }
                    .padding(RelayTheme.spacing(13))
                    .background(RelayTheme.surface, in: RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(11)))

                    VStack(alignment: .leading, spacing: RelayTheme.spacing(9)) {
                        HStack {
                            sectionLabel("relayd log")
                            Spacer()
                            Text("last 80 lines")
                                .font(RelayTheme.font(size: 9, design: .monospaced))
                                .foregroundStyle(RelayTheme.textFaint)
                        }
                        ScrollView(.horizontal) {
                            Text(report.logLines.isEmpty ? "No supervisor log output." : report.logLines.joined(separator: "\n"))
                                .font(RelayTheme.font(size: 10, design: .monospaced))
                                .foregroundStyle(RelayTheme.textMuted)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, minHeight: 76, alignment: .topLeading)
                        }
                    }
                    .padding(RelayTheme.spacing(13))
                    .background(RelayTheme.surface, in: RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(11)))
                }
                .padding(RelayTheme.spacing(20))
            }
        }
    }

    private func metrics(_ report: RelaydHostReport) -> some View {
        HStack(spacing: RelayTheme.spacing(8)) {
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
        VStack(alignment: .leading, spacing: RelayTheme.spacing(4)) {
            Text(label.uppercased())
                .font(RelayTheme.font(size: 8.5, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(RelayTheme.textFaint)
            Text(value)
                .font(RelayTheme.font(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(RelayTheme.text)
                .lineLimit(1)
        }
        .padding(RelayTheme.spacing(11))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RelayTheme.surface, in: RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(10)))
    }

    private func installationCard(profile: ConnectionProfile, report: RelaydHostReport) -> some View {
        VStack(alignment: .leading, spacing: RelayTheme.spacing(11)) {
            HStack(alignment: .top, spacing: RelayTheme.spacing(11)) {
                Image(systemName: "lock.shield")
                    .foregroundStyle(RelayTheme.blue)
                    .frame(width: 28, height: 28)
                    .background(RelayTheme.blue.opacity(0.09), in: RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(8)))
                VStack(alignment: .leading, spacing: RelayTheme.spacing(3)) {
                    Text(installationTitle(for: report))
                        .font(RelayTheme.font(size: 12, weight: .semibold))
                    Text("Installs an architecture-selecting launcher, this node’s signed payload, and Relay-owned Claude/Codex launchers. An existing rcode command, and any launcher Relay did not write, is preserved. No sudo, service, or network port.")
                        .font(RelayTheme.font(size: 10.5))
                        .foregroundStyle(RelayTheme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            HStack {
                Text("Linux \(report.architecture)  ·  relayd \(RelaydRemoteClient.expectedVersion)  ·  SHA-256 verified")
                    .font(RelayTheme.font(size: 9.5, design: .monospaced))
                    .foregroundStyle(RelayTheme.textFaint)
                Spacer()
                Button(installationButtonTitle(for: report)) {
                    manager.install(profile, explicitlyAuthorized: true, retrying: report.state == .failed)
                }
                .buttonStyle(RelayPrimaryButtonStyle())
                .tint(RelayTheme.accent)
            }
        }
        .padding(RelayTheme.spacing(14))
        .background(RelayTheme.elevated, in: RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(12)))
        .overlay { RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(12)).stroke(RelayTheme.blue.opacity(0.25)) }
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(RelayTheme.font(size: 10.5, weight: .semibold))
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
