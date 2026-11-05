import AppKit
import CryptoKit
import Foundation

enum RelayRemoteInstallError: LocalizedError, Equatable {
    case failed(String)
    /// A host script that refused or failed, with the receipt it printed.
    case refused(String, receipt: [String: String])
    var errorDescription: String? {
        switch self {
        case .failed(let message), .refused(let message, _): return message
        }
    }
}

/// One upload, relayd install or relayd rollback a tool asked Relay to run on
/// a host. Every value that reaches a remote script matches a strict pattern.
struct RelayRemoteInstallRequest: Equatable, Sendable {
    enum Action: String, Sendable { case upload, install, rollback }
    let requestID: UUID
    let action: Action
    let host: String
    var localPath: String?
    var remoteDirectory: String?
    var sha256: String?
    var version: String?
    var architecture = "amd64"
    var installID: String?
    var upgradeWorkers = false
    var upgradeSupervisor = false
    var allowSharedHome = false

    /// The install this request creates, or the one a rollback undoes.
    var installJobID: String {
        action == .rollback ? installID ?? "" : "install-" + requestID.uuidString.lowercased()
    }

    static let maximumUploadBytes: Int64 = 1 << 30
    static let relaydDirectory = "~/.local/share/relay/bin"

    static func parse(_ object: [String: Any]) throws -> Self {
        func invalid(_ message: String) -> Error { RelayRemoteInstallError.failed(message) }
        let allowed: Set<String> = ["host", "request_id", "action", "local_path", "remote_directory", "sha256", "version",
                                    "architecture", "install_id", "upgrade_workers", "upgrade_supervisor", "allow_shared_home"]
        guard Set(object.keys).isSubset(of: allowed) else { throw invalid("Unknown remote install field") }
        guard let host = object["host"] as? String, !host.isEmpty, host != "This Mac",
              let rawID = object["request_id"] as? String, let requestID = UUID(uuidString: rawID),
              let rawAction = object["action"] as? String, let action = Action(rawValue: rawAction) else {
            throw invalid("Exact remote host, request_id and action required")
        }
        func flag(_ key: String) throws -> Bool {
            guard let value = object[key] else { return false }
            guard let flag = value as? Bool else { throw invalid("\(key) must be true or false") }
            return flag
        }
        func text(_ key: String, _ pattern: String) throws -> String? {
            guard let value = object[key] else { return nil }
            guard let text = value as? String, text.range(of: pattern, options: .regularExpression) != nil else {
                throw invalid("Invalid \(key)")
            }
            return text
        }
        var request = Self(requestID: requestID, action: action, host: host)
        request.localPath = try text("local_path", #"^/[^\x00\n]{0,4095}$"#)
        request.remoteDirectory = try text("remote_directory", #"^(/|~/)[^\x00\n]{0,4095}$"#)
        request.sha256 = try text("sha256", "^[0-9a-f]{64}$")
        request.version = try text("version", "^[0-9A-Za-z][0-9A-Za-z.+_-]{0,39}$")
        request.architecture = try text("architecture", "^(amd64|arm64)$") ?? "amd64"
        request.installID = try text("install_id", "^install-[0-9a-f-]{36}$")
        request.upgradeWorkers = try flag("upgrade_workers")
        request.upgradeSupervisor = try flag("upgrade_supervisor")
        request.allowSharedHome = try flag("allow_shared_home")
        switch action {
        case .upload:
            guard request.localPath != nil, request.remoteDirectory != nil, request.version == nil, request.installID == nil,
                  !request.upgradeWorkers, !request.upgradeSupervisor, !request.allowSharedHome else {
                throw invalid("An upload takes local_path, remote_directory and an optional sha256")
            }
        case .install:
            guard request.localPath != nil, request.sha256 != nil, request.remoteDirectory == nil, request.installID == nil else {
                throw invalid("An install takes local_path and its expected sha256")
            }
        case .rollback:
            guard request.installID != nil, request.localPath == nil, request.sha256 == nil, request.remoteDirectory == nil,
                  request.version == nil, !request.upgradeWorkers, !request.allowSharedHome else {
                throw invalid("A rollback takes the install_id it undoes")
            }
        }
        return request
    }

    /// What the approval sheet says. The user approves this exact host and file.
    func approval(size: Int64?) -> (title: String, detail: String, button: String) {
        let bytes = size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "unknown size"
        switch action {
        case .upload:
            return ("Upload a file to \(host)?",
                    "\(localPath ?? "") (\(bytes)) will be copied to \(remoteDirectory ?? "") on \(host). Nothing is run. Approval expires in two minutes.",
                    "Upload")
        case .install:
            var detail = "\(localPath ?? "") (\(bytes), SHA-256 \(sha256 ?? "")) replaces relayd-linux-\(architecture) on \(host). The current relayd is kept as a backup."
            detail += upgradeWorkers ? " Running workers will be upgraded." : " Running workers are not touched."
            if upgradeSupervisor { detail += " The supervisor restarts on the new relayd." }
            detail += allowSharedHome
                ? " If that folder is on shared storage, every host that mounts it gets this relayd."
                : " If that folder is on shared storage, the install stops without changing anything."
            return ("Install relayd on \(host)?", detail + " Approval expires in two minutes.", "Install relayd")
        case .rollback:
            var detail = "Restores the relayd that \(installID ?? "") replaced, only if that install is still the one in place."
            if upgradeSupervisor { detail += " The supervisor restarts on the restored relayd." }
            return ("Roll back relayd on \(host)?",
                    detail + " Running workers are not touched. Approval expires in two minutes.",
                    "Roll back")
        }
    }

    /// Refuses a local file whose SHA-256 differs from the one the request states.
    func verify(_ file: RelayRemoteInstallRunner.LocalFile?) throws {
        guard let expected = sha256 else { return }
        guard let file, file.sha256 == expected else {
            throw RelayRemoteInstallError.failed("\(localPath ?? "") has SHA-256 \(file?.sha256 ?? "unknown"), not the expected \(expected)")
        }
    }
}

/// Generates the scripts relayd runs for an install or rollback. They use only
/// POSIX sh and the target's own tools, and each writes a receipt named by its
/// job ID first, so a resent job returns its receipt instead of acting twice.
enum RelayRemoteInstallScript {
    static func stagedName(_ job: String) -> String { ".relayd-install-" + job }

    /// One single-quoted sh word.
    static func quoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'" }

    private static let prelude = #"""
set -u
umask 077
bin="$HOME/.local/share/relay/bin"
state="$HOME/.local/state/relay/relayd-installs"
target="$bin/relayd-linux-$arch"
recovery=""
undo=""
json() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\000-\037'; }
fail() { printf '{"ok":"false","job_id":"%s","error":"%s"%s}\n' "$job" "$(json "$1")" "$recovery"; exit 1; }
digest() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }
# Writes $2 to $1 atomically and returns its status; a fail inside a pipeline
# would end only that pipeline's subshell, never this script.
publish() { tmp="$1.tmp.$$"; printf '%s\n' "$2" > "$tmp" && mv -f "$tmp" "$1" || { rm -f "$tmp"; return 1; }; }
# Once relayd has changed, every failure receipt says what changed and how to undo it,
# and an ok receipt names the undo record, for a later step that fails.
changed() {
    recovery=$(printf ',"target_changed":"true","target":"%s","backup":"%s","recovery_record":"%s","install_id":"%s"' "$(json "$target")" "$(json "$backup")" "$(json "$state/$job.env")" "$job")
    undo=$(printf ',"recovery_record":"%s","install_id":"%s"' "$(json "$state/$job.env")" "$job")
}
failed=""
failures=""
exits=""
# Runs one requested upgrade on the new relayd. A failure does not stop the
# other requested steps; it is recorded so the receipt names every one. Its
# output is kept in a new private directory beside the receipt, so no existing
# link can redirect it, and its stderr also goes to the job's, so the receipt
# can quote why it failed. Without that directory the step does not run.
step() {
    name=$1; shift
    if dir=$(mktemp -d "$logs.$name.XXXXXX" 2>/dev/null) && [ -d "$dir" ] && [ ! -L "$dir" ]; then
        "$target" "$@" >"$dir/out" 2>"$dir/err"
        code=$?
        cat "$dir/err" >&2
    else
        dir=""
        code=125
    fi
    if [ "$code" = 0 ]; then eval "$name=upgraded"; return 0; fi
    eval "$name=failed"
    failed="$failed${failed:+,}$name"
    failures="$failures${failures:+, }$name (exit $code)"
    # The last 2 KB, printable ASCII only, so the receipt stays one valid JSON line.
    tail="cannot create a private log directory for $name; it was not run"
    [ -z "$dir" ] || tail=$(tail -c 2048 "$dir/err" | LC_ALL=C tr -c '\040-\176' ' ')
    exits="$exits,\"${name}_exit\":\"$code\",\"${name}_stderr\":\"$(json "$tail")\""
}
# The receipt's outcome: ok, or the failed steps with what changed and how to undo it.
outcome() {
    if [ -z "$failed" ]; then printf '"ok":"true"%s' "$undo"; return 0; fi
    printf '"ok":"false","error":"%s","failed_step":"%s"%s%s' "$(json "relayd $1, but the requested upgrade failed: $failures")" "$failed" "$exits" "$recovery"
}
# Prints the published receipt; the script fails unless every requested step succeeded.
finish() { cat "$receipt"; [ -z "$failed" ]; }
mkdir -p "$state" || fail "cannot create $state"
"""#

    /// `staged` is the exact path relayd committed the upload to.
    static func install(_ request: RelayRemoteInstallRequest, staged: String) -> String {
        let job = request.installJobID
        return """
        job='\(job)'
        arch='\(request.architecture)'
        expected='\(request.sha256 ?? "")'
        version='\(request.version ?? "")'
        upgrade_workers=\(request.upgradeWorkers ? 1 : 0)
        upgrade_supervisor=\(request.upgradeSupervisor ? 1 : 0)
        allow_shared=\(request.allowSharedHome ? 1 : 0)
        staged=\(quoted(staged))
        \(prelude)
        receipt="$state/$job.json"
        logs="$state/$job"
        record() { printf 'target=%s\\nbackup=%s\\ninstalled=%s' "$target" "$backup" "$1"; }
        if [ -f "$receipt" ]; then cat "$receipt"; grep -q '^{"ok":"true"' "$receipt"; exit; fi
        case "$(uname -m)" in x86_64|amd64) machine=amd64 ;; aarch64|arm64) machine=arm64 ;; *) machine=unknown ;; esac
        [ "$machine" = "$arch" ] || fail "host architecture $machine does not match relayd-linux-$arch"
        [ "$(cd "$bin" 2>/dev/null && pwd -P)" = "$(dirname "$staged")" ] || fail "the upload landed in $(dirname "$staged"), not $bin"
        [ -f "$staged" ] && [ ! -L "$staged" ] || fail "staged upload $staged is missing"
        actual=$(digest "$staged")
        [ "$actual" = "$expected" ] || fail "staged SHA-256 $actual does not match $expected"
        chmod 0755 "$staged" || fail "cannot make $staged executable"
        reported=$("$staged" version 2>/dev/null | head -n 1)
        case "$reported" in "relayd "*) ;; *) fail "staged file is not relayd: $reported" ;; esac
        [ -z "$version" ] || [ "$reported" = "relayd $version" ] || fail "staged file reports $reported, not relayd $version"
        fstype=$(stat -f -c %T "$bin" 2>/dev/null || echo unknown)
        source=$(findmnt -n -o SOURCE -T "$bin" 2>/dev/null || true)
        shared=false
        case "$fstype" in nfs*|cifs|smb*|fuse*|lustre|gpfs|ceph|afs|beegfs*|panfs|isilon*) shared=true ;; esac
        [ "$shared" = false ] || [ "$allow_shared" = 1 ] || fail "$bin is on shared storage ($fstype $source), so every host that mounts it would run this relayd. Nothing was changed; resend with allow_shared_home to accept that."
        previous=""
        backup=""
        if [ -e "$target" ]; then
            previous=$(digest "$target")
            backup="$target.before-$job"
            ln "$target" "$backup" 2>/dev/null || cp -p "$target" "$backup" || fail "cannot back up $target"
        fi
        publish "$state/$job.env" "$(record "$expected")" || fail "cannot write the recovery record $state/$job.env; relayd was not changed"
        mv -f "$staged" "$target" || fail "cannot move the staged relayd into place"
        changed
        installed=$(digest "$target")
        if [ "$installed" != "$expected" ]; then
            publish "$state/$job.env" "$(record "$installed")"
            fail "installed SHA-256 $installed does not match $expected"
        fi
        # This job runs under the supervisor an upgrade would replace, which owns
        # its exit status and output, so Relay restarts it only after this receipt.
        supervisor=skipped
        if [ "$upgrade_supervisor" = 1 ]; then supervisor=pending; fi
        workers=skipped
        if [ "$upgrade_workers" = 1 ]; then step workers upgrade-workers; fi
        publish "$receipt" "$(printf '{%s,"job_id":"%s","action":"install","target":"%s","backup":"%s","previous_sha256":"%s","sha256":"%s","version":"%s","filesystem":"%s","mount_source":"%s","shared_storage":"%s","supervisor":"%s","workers":"%s"}' \\
            "$(outcome "was installed")" "$job" "$(json "$target")" "$(json "$backup")" "$previous" "$installed" "$(json "$reported")" "$(json "$fstype")" "$(json "$source")" "$shared" "$supervisor" "$workers")" || fail "cannot write receipt $receipt"
        finish
        """
    }

    static func rollback(_ request: RelayRemoteInstallRequest) -> String {
        """
        job='\(request.installJobID)'
        arch='\(request.architecture)'
        upgrade_supervisor=\(request.upgradeSupervisor ? 1 : 0)
        \(prelude)
        receipt="$state/$job.rollback.json"
        logs="$state/$job.rollback"
        if [ -f "$receipt" ]; then cat "$receipt"; grep -q '^{"ok":"true"' "$receipt"; exit; fi
        [ -f "$state/$job.env" ] || fail "no install receipt for $job on this host"
        recorded=$(sed -n 's/^target=//p' "$state/$job.env")
        backup=$(sed -n 's/^backup=//p' "$state/$job.env")
        installed=$(sed -n 's/^installed=//p' "$state/$job.env")
        [ "$recorded" = "$target" ] || fail "$job installed $recorded, not $target"
        [ -n "$backup" ] && [ -f "$backup" ] || fail "$job replaced nothing, so there is no backup to restore"
        current=$(digest "$target")
        [ "$current" = "$installed" ] || fail "relayd changed after $job (now $current); nothing was rolled back"
        cp -p "$backup" "$target.rollback-$job" && mv -f "$target.rollback-$job" "$target" || fail "cannot restore $backup"
        changed
        restored=$(digest "$target")
        supervisor=skipped
        if [ "$upgrade_supervisor" = 1 ]; then supervisor=pending; fi
        publish "$receipt" "$(printf '{%s,"job_id":"%s","action":"rollback","target":"%s","backup":"%s","replaced_sha256":"%s","sha256":"%s","supervisor":"%s","workers":"skipped"}' \\
            "$(outcome "was rolled back")" "$job" "$(json "$target")" "$(json "$backup")" "$installed" "$restored" "$supervisor")" || fail "cannot write receipt $receipt"
        finish
        """
    }

    /// Restarts the supervisor on the relayd that `kind` ("install" or
    /// "rollback") left in place, only while it is still the one with
    /// `sha256`. Run in its own SSH session after that job's receipt.
    static func supervisor(_ request: RelayRemoteInstallRequest, kind: String, sha256: String) -> String {
        """
        job='\(request.installJobID)'
        arch='\(request.architecture)'
        kind=\(quoted(kind))
        expected=\(quoted(sha256))
        \(prelude)
        logs="$state/$job.$kind"
        receipt="$logs.supervisor.json"
        if [ -f "$receipt" ]; then cat "$receipt"; grep -q '^{"ok":"true"' "$receipt"; exit; fi
        backup=$(sed -n 's/^backup=//p' "$state/$job.env" 2>/dev/null)
        current=$(digest "$target")
        [ "$current" = "$expected" ] || fail "relayd changed after the $kind (now $current); the supervisor was not upgraded"
        changed
        supervisor=skipped
        step supervisor upgrade-supervisor --force
        # The check above is made before relayd runs. A relayd replaced while the
        # step ran is caught here; one swapped and restored within it is not.
        after=$(digest "$target")
        if [ "$after" != "$expected" ]; then
            supervisor=unknown
            failed="$failed${failed:+,}identity"
            failures="$failures${failures:+, }relayd changed while the supervisor restarted (now $after)"
        fi
        publish "$receipt" "$(printf '{%s,"job_id":"%s","action":"supervisor","target":"%s","sha256":"%s","supervisor":"%s"}' \\
            "$(outcome "\(kind == "rollback" ? "was rolled back" : "was installed")")" "$job" "$(json "$target")" "$current" "$supervisor")" || fail "cannot write receipt $receipt"
        finish
        """
    }
}

/// Moves a local file to a host over relayd's recoverable upload protocol and
/// runs install scripts there. `send` is one host RPC round trip.
enum RelayRemoteInstallRunner {
    typealias Send = @Sendable (Data) async throws -> Data
    /// Runs one script in its own SSH session, outside relayd's host jobs.
    typealias Direct = @Sendable (String) async throws -> (status: Int32, output: String, error: String)

    struct LocalFile: Equatable, Sendable {
        let size: Int64
        let sha256: String
    }

    /// Hashes a regular, non-symlink file no larger than the upload limit.
    static func inspect(_ path: String) throws -> LocalFile {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw RelayRemoteInstallError.failed("\(path) is not a regular file")
        }
        guard Int64(info.st_size) <= RelayRemoteInstallRequest.maximumUploadBytes else {
            throw RelayRemoteInstallError.failed("\(path) is larger than the 1 GB upload limit")
        }
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        var hasher = SHA256()
        var size: Int64 = 0
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
            size += Int64(chunk.count)
        }
        guard size == Int64(info.st_size) else { throw RelayRemoteInstallError.failed("\(path) changed while it was read") }
        return LocalFile(size: size, sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }

    static func call(_ object: [String: Any], send: Send) async throws -> [String: Any] {
        var object = object
        object["request_id"] = "rpc-" + UUID().uuidString.lowercased()
        let reply = try JSONSerialization.jsonObject(with: try await send(JSONSerialization.data(withJSONObject: object))) as? [String: Any]
        if let error = reply?["error"] as? String { throw RelayRemoteInstallError.failed(error) }
        guard let result = reply?["result"] as? [String: Any] else { throw RelayHostRPCError.invalidRequest }
        return result
    }

    /// Whether relayd's resolved `directory` is the folder the user approved:
    /// the same absolute path, or for `~/rest` a home folder ending in `/rest`.
    /// relayd resolves symlinks, so an approved path through one does not match.
    static func isApproved(_ directory: String, _ approved: String) -> Bool {
        func trimmed(_ path: String) -> String {
            var path = path
            while path.count > 1, path.hasSuffix("/") { path.removeLast() }
            return path
        }
        let directory = trimmed(directory), approved = trimmed(approved)
        guard directory.hasPrefix("/"), !directory.split(separator: "/").contains("..") else { return false }
        if approved.hasPrefix("~/") { return directory.hasSuffix(String(approved.dropFirst(1))) && approved.count > 2 }
        return directory == approved
    }

    /// Whether `committed` is `name` or the `stem (N)ext` name relayd picks
    /// when `name` already exists in the folder.
    static func isCommittedName(_ committed: String, for name: String) -> Bool {
        if committed == name { return true }
        let dot = name.lastIndex(of: ".")
        let stem = dot.map { String(name[..<$0]) } ?? name
        let ext = dot.map { String(name[$0...]) } ?? ""
        return (1..<1000).contains { committed == "\(stem) (\($0))\(ext)" }
    }

    /// Uploads `path` as `name` in `directory` and returns the committed remote
    /// path. Resending the same job resumes from relayd's checkpoint.
    static func upload(path: String, name: String, directory: String, expected: LocalFile, jobID: String,
                       send: Send) async throws -> String {
        // relayd resolves a folder from upload_pane only when path is empty;
        // here the folder is explicit, so no pane is involved.
        var receipt = try await call(["operation": "file_upload_begin", "job_id": jobID, "upload_pane": "host",
                                      "upload_name": name, "upload_size": expected.size,
                                      "upload_sha256": expected.sha256, "path": directory], send: send)
        // relayd answers with the folder it resolved before any byte is sent.
        guard let resolved = receipt["directory"] as? String, isApproved(resolved, directory) else {
            _ = try? await call(["operation": "file_upload_cancel", "job_id": jobID], send: send)
            throw RelayRemoteInstallError.failed(
                "relayd resolved \(directory) to \(receipt["directory"] as? String ?? "no folder"); nothing was uploaded. Resend with that exact folder to approve it.")
        }
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        // Every chunk must advance, so a whole file needs at most this many;
        // the bound stops a host that keeps answering without progress.
        let chunkLimit = Int((expected.size + (4 << 20) - 1) / (4 << 20))
        var chunks = 0
        while receipt["state"] as? String == "receiving" {
            guard let offset = (receipt["offset"] as? NSNumber)?.int64Value, offset >= 0, offset <= expected.size else {
                throw RelayHostRPCError.invalidRequest
            }
            if offset == expected.size {
                receipt = try await call(["operation": "file_upload_commit", "job_id": jobID], send: send)
                break
            }
            guard chunks < chunkLimit else {
                throw RelayRemoteInstallError.failed("Upload \(jobID) needed more than \(chunkLimit) chunks; query it before resending")
            }
            chunks += 1
            try handle.seek(toOffset: UInt64(offset))
            guard let bytes = try handle.read(upToCount: Int(min(4 << 20, expected.size - offset))), !bytes.isEmpty else {
                throw RelayRemoteInstallError.failed("\(path) is shorter than when it was hashed")
            }
            receipt = try await call(["operation": "file_upload_chunk", "job_id": jobID, "offset": offset,
                                      "data": bytes.base64EncodedString()], send: send)
            guard (receipt["offset"] as? NSNumber)?.int64Value == offset + Int64(bytes.count) else {
                throw RelayRemoteInstallError.failed("Upload \(jobID) did not advance; query it before resending")
            }
        }
        guard receipt["state"] as? String == "committed", receipt["sha256"] as? String == expected.sha256,
              let remote = receipt["path"] as? String else {
            throw RelayRemoteInstallError.failed("Upload \(jobID) ended as \(receipt["state"] as? String ?? "unknown")")
        }
        guard receipt["directory"] as? String == resolved, (remote as NSString).deletingLastPathComponent == resolved,
              isCommittedName((remote as NSString).lastPathComponent, for: name) else {
            throw RelayRemoteInstallError.failed("Upload \(jobID) was committed to \(remote), outside the approved \(resolved)")
        }
        return remote
    }

    /// Runs `script` once under `jobID` and returns the JSON receipt it prints.
    static func run(script: String, jobID: String, send: Send,
                    sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                    attempts: Int = 600) async throws -> [String: String] {
        _ = try await call(["operation": "exec", "job_id": jobID, "command": script], send: send)
        var output = Data()
        for _ in 0..<attempts {
            let status = try await call(["operation": "status", "job_id": jobID, "stdout_offset": output.count,
                                         "stderr_offset": 0], send: send)
            if let chunk = (status["stdout"] as? String).flatMap({ Data(base64Encoded: $0) }) { output.append(chunk) }
            if let job = status["job"] as? [String: Any], job["state"] as? String == "exited" {
                let last = String(decoding: output, as: UTF8.self).split(separator: "\n").last.map(String.init) ?? ""
                let code = (job["exit_code"] as? NSNumber)?.intValue
                guard let receipt = try? JSONSerialization.jsonObject(with: Data(last.utf8)) as? [String: String] else {
                    throw RelayRemoteInstallError.failed("\(jobID) exited with status \(code.map(String.init) ?? "unknown") without a receipt")
                }
                // A refusal or failure is never a completed action, whatever else the receipt says.
                guard code == 0, receipt["ok"] == "true" else {
                    throw RelayRemoteInstallError.refused(
                        receipt["error"] ?? "\(jobID) exited with status \(code.map(String.init) ?? "unknown")", receipt: receipt)
                }
                return receipt
            }
            try await sleep(.milliseconds(500))
        }
        throw RelayRemoteInstallError.failed("\(jobID) is still running; read its receipt later")
    }

    /// Restarts the supervisor once `kind`'s job has exited with an ok receipt.
    /// The job runs under that supervisor, which records its exit status and
    /// output, so the job never restarts it itself: `direct` runs the step in its
    /// own SSH session, which every other active host job still defers.
    static func upgradeSupervisor(_ request: RelayRemoteInstallRequest, after receipt: [String: String], kind: String,
                                  direct: Direct) async throws -> [String: String] {
        guard request.upgradeSupervisor else { return receipt }
        // Until the step's own receipt says otherwise, the install did not complete,
        // and every refusal keeps the job's receipt with what changed and how to undo it:
        // an ok job changed relayd, and its receipt names the undo record.
        var merged = receipt
        merged["ok"] = "false"
        merged["supervisor"] = "failed"
        merged["target_changed"] = "true"
        guard let sha = receipt["sha256"], sha.count == 64, sha.allSatisfy(\.isHexDigit) else {
            throw RelayRemoteInstallError.refused("The \(kind) receipt names no relayd SHA-256; the supervisor was not upgraded", receipt: merged)
        }
        let run: (status: Int32, output: String, error: String)
        do {
            run = try await direct(RelayRemoteInstallScript.supervisor(request, kind: kind, sha256: sha))
        } catch {
            merged["supervisor"] = "unknown"
            throw RelayRemoteInstallError.refused(
                "The supervisor upgrade session failed (\(error.localizedDescription)); read its receipt before retrying", receipt: merged)
        }
        let last = run.output.split(separator: "\n").last.map(String.init) ?? ""
        guard let upgrade = try? JSONSerialization.jsonObject(with: Data(last.utf8)) as? [String: String] else {
            merged["supervisor"] = "unknown"
            merged["supervisor_stderr"] = String(run.error.suffix(2048))
            throw RelayRemoteInstallError.refused(
                "The supervisor upgrade exited with status \(run.status) without a receipt", receipt: merged)
        }
        // Only the step's own outcome fields are taken, bounded; what was installed
        // and how to undo it stay as the job reported them.
        for key in ["supervisor", "supervisor_exit", "supervisor_stderr", "failed_step", "error"] {
            if let value = upgrade[key] { merged[key] = String(value.prefix(4096)) }
        }
        // Success is this job's supervisor receipt for the relayd it installed, not any ok line.
        guard run.status == 0, upgrade["ok"] == "true", upgrade["supervisor"] == "upgraded",
              upgrade["action"] == "supervisor", upgrade["job_id"] == request.installJobID, upgrade["sha256"] == sha else {
            if merged["supervisor"] == "upgraded" { merged["supervisor"] = "unknown" }
            throw RelayRemoteInstallError.refused(
                upgrade["error"].map { String($0.prefix(4096)) }
                    ?? "The supervisor upgrade exited with status \(run.status) without a matching receipt", receipt: merged)
        }
        merged["ok"] = "true"
        merged["target_changed"] = receipt["target_changed"]
        return merged
    }

    static func perform(_ request: RelayRemoteInstallRequest, file: LocalFile?, send: Send,
                        direct: Direct) async throws -> [String: String] {
        switch request.action {
        case .upload:
            guard let file, let path = request.localPath, let directory = request.remoteDirectory else { throw RelayHostRPCError.invalidRequest }
            try request.verify(file)
            let remote = try await upload(path: path, name: (path as NSString).lastPathComponent, directory: directory,
                                          expected: file, jobID: "upload-" + request.requestID.uuidString.lowercased(), send: send)
            return ["ok": "true", "action": "upload", "path": remote, "sha256": file.sha256, "size": String(file.size)]
        case .install:
            guard let file, let path = request.localPath, request.sha256 != nil else { throw RelayHostRPCError.invalidRequest }
            try request.verify(file)
            let job = request.installJobID
            let staged = try await upload(path: path, name: RelayRemoteInstallScript.stagedName(job),
                                          directory: RelayRemoteInstallRequest.relaydDirectory, expected: file, jobID: "upload-" + job, send: send)
            return try await finish(request, kind: "install", direct: direct) {
                try await run(script: RelayRemoteInstallScript.install(request, staged: staged), jobID: job, send: send)
            }
        case .rollback:
            return try await finish(request, kind: "rollback", direct: direct) {
                try await run(script: RelayRemoteInstallScript.rollback(request),
                              jobID: "rollback-" + request.requestID.uuidString.lowercased(), send: send)
            }
        }
    }

    /// Runs `job`, then the requested supervisor step. A job whose only failure
    /// was the worker upgrade left its relayd in place, so the supervisor still
    /// moves to it, and the install stays failed with both outcomes. Any other
    /// job failure skips the supervisor step.
    static func finish(_ request: RelayRemoteInstallRequest, kind: String, direct: Direct,
                       job: () async throws -> [String: String]) async throws -> [String: String] {
        let receipt: [String: String]
        do {
            receipt = try await job()
        } catch RelayRemoteInstallError.refused(let message, let failed)
            where request.upgradeSupervisor && failed["failed_step"] == "workers"
            && failed["supervisor"] == "pending" && failed["target_changed"] == "true" {
            var outcome: [String: String]
            var error = message
            do {
                outcome = try await upgradeSupervisor(request, after: failed, kind: kind, direct: direct)
            } catch RelayRemoteInstallError.refused(let supervisor, let both) {
                outcome = both
                outcome["failed_step"] = "workers,supervisor"
                error += "; " + supervisor
            }
            outcome["ok"] = "false"
            outcome["error"] = error
            throw RelayRemoteInstallError.refused(error, receipt: outcome)
        }
        return try await upgradeSupervisor(request, after: receipt, kind: kind, direct: direct)
    }
}

struct RelayRemoteInstallReceipt: Encodable, Sendable {
    let requestID: UUID
    let action: String
    let host: String
    var status: String
    var error: String?
    var result: [String: String]?
    enum CodingKeys: String, CodingKey { case requestID = "request_id", action, host, status, error, result }
}

/// Runs an upload, install or rollback only after the user approves that exact
/// request in Relay. A tool's own permission flags never stand in for this.
@MainActor final class RelayRemoteInstallControl {
    private let present: PeerNetworkApproval.Presenter
    private var requests: [UUID: RelayRemoteInstallRequest] = [:]
    private var receipts: [UUID: RelayRemoteInstallReceipt] = [:]
    private var pending = false

    init(present: PeerNetworkApproval.Presenter? = nil) {
        self.present = present ?? { alert, completion in
            guard let window = NSApp.keyWindow ?? NSApp.mainWindow ??
                    NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }),
                  window.attachedSheet == nil else { return false }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            alert.beginSheetModal(for: window, completionHandler: completion)
            return true
        }
    }

    func receipt(_ id: UUID) -> RelayRemoteInstallReceipt? { receipts[id] }

    func propose(_ request: RelayRemoteInstallRequest, file: RelayRemoteInstallRunner.LocalFile?,
                 send: @escaping RelayRemoteInstallRunner.Send,
                 direct: @escaping RelayRemoteInstallRunner.Direct) throws -> RelayRemoteInstallReceipt {
        if let old = receipts[request.requestID] {
            guard requests[request.requestID] == request else { throw RelayRemoteInstallError.failed("Conflicting request ID") }
            return old
        }
        guard !pending, receipts.count < 256 else { throw RelayRemoteInstallError.failed("Another remote install is awaiting approval") }
        // A file that is already not the stated build is refused before the user is asked.
        try request.verify(file)
        let initial = RelayRemoteInstallReceipt(requestID: request.requestID, action: request.action.rawValue,
                                                host: request.host, status: "awaiting_approval")
        requests[request.requestID] = request
        receipts[request.requestID] = initial
        pending = true
        let deadline = Date().addingTimeInterval(120)
        let text = request.approval(size: file?.size)
        let alert = RelayTheme.alert()
        alert.messageText = text.title
        alert.informativeText = text.detail
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: text.button)
        alert.buttons[0].keyEquivalent = "\r"
        alert.buttons[1].keyEquivalent = ""
        guard present(alert, { [weak self] response in
            guard let self, self.pending, self.receipts[request.requestID]?.status == "awaiting_approval" else { return }
            self.pending = false
            guard response == .alertSecondButtonReturn else { self.receipts[request.requestID]?.status = "cancelled"; return }
            guard Date() < deadline else { self.receipts[request.requestID]?.status = "expired"; return }
            self.receipts[request.requestID]?.status = "running"
            Task { @MainActor [weak self] in
                do {
                    let result = try await RelayRemoteInstallRunner.perform(request, file: file, send: send, direct: direct)
                    self?.receipts[request.requestID]?.result = result
                    self?.receipts[request.requestID]?.status = "completed"
                } catch {
                    if case .refused(_, let receipt) = error as? RelayRemoteInstallError {
                        self?.receipts[request.requestID]?.result = receipt
                    }
                    self?.receipts[request.requestID]?.error = error.localizedDescription
                    self?.receipts[request.requestID]?.status = "failed"
                }
            }
        }) else {
            pending = false
            requests.removeValue(forKey: request.requestID)
            receipts.removeValue(forKey: request.requestID)
            throw RelayRemoteInstallError.failed("Select Relay with no open dialog before requesting a remote install")
        }
        return initial
    }
}
