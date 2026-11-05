import Foundation

struct RelayShellRecoveryInput: Codable, Equatable, Sendable {
    let instance: UUID
    let requestID: UUID
    let text: String
    let workerPID: Int
    let workerStart: String
    let shellPID: Int
    let shellStart: String

    var isValid: Bool {
        workerPID > 1 && shellPID > 1 &&
        UInt64(workerStart) != nil && UInt64(shellStart) != nil &&
        !text.isEmpty && text.utf8.count <= 16_384 &&
        text.unicodeScalars.allSatisfy { $0.value >= 32 && $0.value != 127 }
    }
}

/// The host-side proof that a retained Bash pane still belongs to its worker:
/// the worker manifest names both PIDs, each /proc/PID/stat start time (field
/// 19 after the last ')', so comm may hold spaces or ')') matches, the shell's
/// parent is the worker, the shell leads its terminal's foreground group, and
/// its executable ends in /bash. POSIX sh and awk only; relayd runs it with
/// /bin/sh -lc. Prints {"verified": true|false, "pane_id": ...}.
///
/// Only a lowercase UUID and canonical decimal integers are interpolated, and
/// only after validation. Unreadable or non-UTF-8 files, invalid manifest
/// JSON, and short stat records all verify false. A manifest PID must be a
/// JSON integer literal equal to the expected PID (a float such as 123.0 is
/// refused, which can only make verification stricter).
enum RelayShellRecoveryProof {
    /// `procRoot` exists for fixture tests; production always uses /proc.
    static func command(paneID: UUID, input: RelayShellRecoveryInput, procRoot: String = "/proc") -> String? {
        let pane = paneID.uuidString.lowercased()
        let integer = #"^[0-9]{1,20}$"#
        guard input.workerPID > 1, input.shellPID > 1,
              pane.range(of: #"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#,
                         options: .regularExpression) != nil,
              input.workerStart.range(of: integer, options: .regularExpression) != nil,
              input.shellStart.range(of: integer, options: .regularExpression) != nil,
              procRoot.range(of: #"^/[A-Za-z0-9._/-]{0,200}$"#, options: .regularExpression) != nil else { return nil }
        return #"""
        RELAY_PROOF_PANE=\#(pane) RELAY_PROOF_WORKER=\#(input.workerPID) RELAY_PROOF_WORKER_START=\#(input.workerStart) \
        RELAY_PROOF_SHELL=\#(input.shellPID) RELAY_PROOF_SHELL_START=\#(input.shellStart) \
        RELAY_PROOF_MANIFEST="$HOME/.local/state/relay/workers/\#(pane).json" RELAY_PROOF_PROC=\#(procRoot)
        export RELAY_PROOF_PANE RELAY_PROOF_WORKER RELAY_PROOF_WORKER_START RELAY_PROOF_SHELL RELAY_PROOF_SHELL_START \
            RELAY_PROOF_MANIFEST RELAY_PROOF_PROC
        relay_proof_exe=$(readlink "$RELAY_PROOF_PROC/$RELAY_PROOF_SHELL/exe" && echo x) || relay_proof_exe=
        relay_proof_exe=${relay_proof_exe%x}; relay_proof_exe=${relay_proof_exe%"
        "}
        relay_proof=false
        case $relay_proof_exe in */bash)
            if LC_ALL=C awk '\#(awkProgram)' </dev/null; then relay_proof=true; fi;;
        esac
        printf '{"verified": %s, "pane_id": "%s"}\n' "$relay_proof" "$RELAY_PROOF_PANE"
        """#
    }

    /// Exit 0 only when the manifest and both stat records match.
    static let awkProgram = #"""
    function slurp(path,   line, r, out) {
        out = ""
        while ((r = (getline line < path)) > 0) out = out line "\n"
        if (r < 0) exit 1
        close(path)
        return out
    }
    function utf8(t,   i, n, c, k, need, lo, hi) {
        n = length(t); i = 1
        while (i <= n) {
            c = ord[substr(t, i, 1)]
            if (c < 128) { i++; continue }
            if (c >= 194 && c <= 223) need = 1
            else if (c >= 224 && c <= 239) need = 2
            else if (c >= 240 && c <= 244) need = 3
            else return 0
            lo = 128; hi = 191
            if (c == 224) lo = 160
            else if (c == 237) hi = 159
            else if (c == 240) lo = 144
            else if (c == 244) hi = 143
            if (i + need > n) return 0
            c = ord[substr(t, i + 1, 1)]
            if (c < lo || c > hi) return 0
            for (k = 2; k <= need; k++) { c = ord[substr(t, i + k, 1)]; if (c < 128 || c > 191) return 0 }
            i += need + 1
        }
        return 1
    }
    function skip() { while (pos <= n && index(" \t\n\r", substr(s, pos, 1)) > 0) pos++ }
    function hex(h,   i, v) {
        v = 0
        for (i = 1; i <= 4; i++) v = v * 16 + index("0123456789abcdef", tolower(substr(h, i, 1))) - 1
        return v
    }
    function jstring(   c, k, out) {
        pos++; out = ""
        while (pos <= n) {
            c = substr(s, pos, 1)
            if (c == "\"") { pos++; str = out; return 1 }
            if (c == "\\") {
                c = substr(s, pos + 1, 1)
                if (c == "u") {
                    if (substr(s, pos + 2, 4) !~ /^[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]$/) return 0
                    k = hex(substr(s, pos + 2, 4))
                    out = out ((k > 0 && k < 128) ? sprintf("%c", k) : "\001")
                    pos += 6; continue
                }
                k = (c == "") ? 0 : index("\"\\/bfnrt", c)
                if (k == 0) return 0
                out = out substr("\"\\/\b\f\n\r\t", k, 1); pos += 2; continue
            }
            if (ord[c] < 32) return 0
            out = out c; pos++
        }
        return 0
    }
    function value(depth,   c) {
        skip()
        if (pos > n) return 0
        c = substr(s, pos, 1)
        if (c == "{") return members(depth, "}")
        if (c == "[") return members(depth, "]")
        if (c == "\"") { kind = "s"; return jstring() }
        kind = "l"
        if (substr(s, pos, 4) == "null" || substr(s, pos, 4) == "true") { pos += 4; return 1 }
        if (substr(s, pos, 5) == "false") { pos += 5; return 1 }
        if (match(substr(s, pos), /^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][-+]?[0-9]+)?/)) {
            tok = substr(s, pos, RLENGTH); pos += RLENGTH
            kind = (tok ~ /^-?[0-9]+$/) ? "i" : "f"
            return 1
        }
        if (substr(s, pos, 3) == "NaN") { pos += 3; return 1 }
        if (substr(s, pos, 8) == "Infinity") { pos += 8; return 1 }
        if (substr(s, pos, 9) == "-Infinity") { pos += 9; return 1 }
        return 0
    }
    function members(depth, close_char,   c, key) {
        pos++; skip()
        if (substr(s, pos, 1) == close_char) { pos++; kind = "c"; return 1 }
        while (1) {
            if (close_char == "}") {
                skip()
                if (substr(s, pos, 1) != "\"" || !jstring()) return 0
                key = str
                skip()
                if (substr(s, pos, 1) != ":") return 0
                pos++
            }
            if (!value(depth + 1)) return 0
            if (depth == 0 && close_char == "}") top[key] = (kind == "i") ? tok : "\001"
            skip(); c = substr(s, pos, 1)
            if (c == close_char) { pos++; kind = "c"; return 1 }
            if (c != ",") return 0
            pos++
        }
    }
    function stat(path, f,   t) {
        t = slurp(path)
        if (!utf8(t) || !match(t, /\)[^)]*$/)) exit 1
        return split(substr(t, RSTART + 1), f)
    }
    BEGIN {
        for (i = 1; i < 256; i++) ord[sprintf("%c", i)] = i
        s = slurp(ENVIRON["RELAY_PROOF_MANIFEST"]); n = length(s); pos = 1
        if (!utf8(s)) exit 1
        skip()
        if (substr(s, pos, 1) != "{" || !value(0)) exit 1
        skip()
        if (pos <= n) exit 1
        if (!("worker_pid" in top) || (top["worker_pid"] "") != (ENVIRON["RELAY_PROOF_WORKER"] "")) exit 1
        if (!("shell_pid" in top) || (top["shell_pid"] "") != (ENVIRON["RELAY_PROOF_SHELL"] "")) exit 1
        if (stat(ENVIRON["RELAY_PROOF_PROC"] "/" ENVIRON["RELAY_PROOF_WORKER"] "/stat", worker) < 20) exit 1
        if (stat(ENVIRON["RELAY_PROOF_PROC"] "/" ENVIRON["RELAY_PROOF_SHELL"] "/stat", shell) < 20) exit 1
        if ((worker[20] "") != (ENVIRON["RELAY_PROOF_WORKER_START"] "")) exit 1
        if ((shell[20] "") != (ENVIRON["RELAY_PROOF_SHELL_START"] "")) exit 1
        if (shell[2] !~ /^[-+]?[0-9]+$/ || shell[2] + 0 != ENVIRON["RELAY_PROOF_WORKER"] + 0) exit 1
        if (shell[6] !~ /^[-+]?[0-9]+$/ || shell[6] + 0 != ENVIRON["RELAY_PROOF_SHELL"] + 0) exit 1
        exit 0
    }
    """#
}
