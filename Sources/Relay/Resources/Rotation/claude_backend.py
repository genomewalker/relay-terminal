#!/usr/bin/env python3
"""Claude backend for the Relay rotation executor (Claude Code 2.1.283).

The executor keeps the ledger sequence (claim, capsule_save, intent, bind, enroll,
ack) and its durable journal. This module performs the Claude-specific steps:

  launch_argv    fresh argv plus a session id derived from the intent, so a lost
                 start is recovered by exact lookup, never by relaunch
  confirm        that id is listed by `claude agents --json`, in the given pane
  deliver        type a prompt at most once (receipt first, continuation after ack)
  await_receipt  in the new session's own transcript, the output of the exact
                 approved receipt command: the printed capsule, whose recomputed
                 SHA-256 is the fenced one, and the receipt line
  retire         type /exit into the old session's pane, only after the guards pass

Pane I/O belongs to relayd, injected as `transport` with send(pane, text) and
pane_pid(pane). The new session runs `claude_backend.py receipt ...` itself.
"""
import hashlib
import json
import shlex
import subprocess
import sys
import time
import uuid
from pathlib import Path

from claude_sessions import idle, match, snapshot

NAMESPACE = uuid.UUID("5f1b7c1e-3a0e-4d2b-9a57-2c4f1f0e9b11")
PROJECTS = Path.home() / ".claude" / "projects"
CLI = str(Path.home() / ".claude" / "bin" / "chitta")


def session_id_for(intent_id):
    return str(uuid.uuid5(NAMESPACE, intent_id))


def launch_argv(fresh_argv, intent_id):
    """`fresh_argv` must already be filtered by relayd's agentlaunch."""
    if any(a == "--session-id" or a.startswith("--session-id=") for a in fresh_argv):
        raise ValueError("fresh argv still carries a session id")
    return [*fresh_argv, "--session-id", session_id_for(intent_id)]


def wait_for(probe, timeout_s, interval_s=2.0, clock=time.monotonic, sleep=time.sleep):
    deadline = clock() + timeout_s
    while True:
        result = probe()
        if result is not None or clock() >= deadline:
            return result
        sleep(interval_s)


def ledger(op, args, cli=CLI):
    request = {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
               "params": {"name": "ledger_op", "arguments": {"op": op, "args": {"v": 1, **args}}}}
    out = subprocess.run([cli], input=json.dumps(request) + "\n", capture_output=True, text=True, timeout=60)
    result = json.loads(out.stdout)["result"]
    if result.get("isError"):
        raise RuntimeError(result["content"][0]["text"])
    return result["structured"]["value"]


def capsule_digest(capsule):
    canonical = json.dumps(capsule, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return hashlib.sha256(canonical.encode()).hexdigest()


def receipt_line(intent_id, new_session_id, revision, digest):
    return f"RELAY-RECEIPT intent={intent_id} session={new_session_id} revision={revision} sha256={digest}"


def marker(kind, intent_id):
    return f"[relay {kind} {intent_id}]"


def receipt_command(intent_id, old_session_id, new_session_id, revision, project_dir):
    """The only command whose output counts as a receipt; matched verbatim in the transcript."""
    return " ".join(shlex.quote(a) for a in (
        "python3", str(Path(__file__).resolve()), "receipt", "--old", old_session_id, "--intent", intent_id,
        "--new", new_session_id, "--revision", str(revision), "--project-dir", project_dir))


def receipt_prompt(intent_id, command):
    """First turn is receipt-only; the executor sends the continuation after ack and retirement."""
    return (f"{marker('receipt', intent_id)} Run exactly this command with the Bash tool and nothing else: {command} "
            f"Then reply only \"receipt done\" and stop. Do not start any project work yet.")


def continuation_prompt(intent_id):
    return (f"{marker('continue', intent_id)} The rotation is complete. Continue from the next_action of the "
            f"capsule printed above.")


def confirm(intent_id, transport, pane, agents=snapshot, **wait):
    """The new incarnation, only if listed under the derived id and running in `pane`."""
    sid = session_id_for(intent_id)
    entry = wait_for(lambda: match(agents(), sid)[0], **wait)
    if entry is None or transport.pane_pid(pane) != entry.get("pid"):
        return None
    return entry


def transcript_entries(session_id, root=PROJECTS):
    paths = list(Path(root).glob(f"*/{session_id}.jsonl"))
    if len(paths) != 1:
        return []
    out = []
    for line in paths[0].read_text(errors="replace").splitlines():
        try:
            e = json.loads(line)
        except ValueError:
            continue
        if not e.get("isSidechain") and e.get("sessionId") == session_id:
            out.append(e)
    return out


def _blocks(e, role):
    content = (e.get("message") or {}).get("content") if e.get("type") == role else None
    if isinstance(content, str):
        return [{"type": "text", "text": content}]
    return [b for b in content if isinstance(b, dict)] if isinstance(content, list) else []


def _result_text(block):
    inner = block.get("content")
    return inner if isinstance(inner, str) else "".join(b.get("text", "") for b in inner or [] if isinstance(b, dict))


def delivered(session_id, tag, root=PROJECTS):
    return any(tag in b.get("text", "") for e in transcript_entries(session_id, root) for b in _blocks(e, "user")
               if b.get("type") == "text")


def deliver(transport, pane, session_id, tag, prompt, root=PROJECTS):
    """At most once per tag. The executor journals the send before calling this; after a
    restart it never calls deliver again for that tag, only waits."""
    if delivered(session_id, tag, root):
        return "already delivered"
    transport.send(pane, prompt)
    return "sent"


def verify_receipt(entries, command, expected_line, expected_digest):
    """True only for the output of an assistant Bash call whose command is exactly `command`,
    ending in the expected line, with a printed capsule whose recomputed digest matches."""
    calls = {b["id"] for e in entries for b in _blocks(e, "assistant")
             if b.get("type") == "tool_use" and b.get("name") == "Bash" and (b.get("input") or {}).get("command") == command}
    for e in entries:
        for b in _blocks(e, "user"):
            if b.get("type") != "tool_result" or b.get("is_error") or b.get("tool_use_id") not in calls:
                continue
            lines = _result_text(b).rstrip("\n").split("\n")
            if lines[-1] != expected_line:
                continue
            try:
                capsule = json.loads("\n".join(lines[:-1]))
            except ValueError:
                continue
            if isinstance(capsule, dict) and capsule_digest(capsule) == expected_digest:
                return True
    return False


def await_receipt(new_session_id, command, expected_line, expected_digest, transport, pane, incarnation,
                  agents=snapshot, status=lambda s: ledger("rotation_status", {"session_id": s}), root=PROJECTS, **wait):
    """Receipt verified in the new session's own transcript, by the same incarnation in the same
    pane, and the ledger shows it Relay-owned with a completed turn."""
    def probe():
        if not verify_receipt(transcript_entries(new_session_id, root), command, expected_line, expected_digest):
            return None
        if match(agents(), new_session_id, incarnation["pid"], incarnation["started_at_ms"])[0] is None:
            return None
        if transport.pane_pid(pane) != incarnation["pid"]:
            return None
        s = status(new_session_id)
        return s if s.get("owner") == "relay" and s.get("turn_seq", 0) >= 1 else None
    return wait_for(probe, **wait)


def retire_preflight(old, pane_pid, agents=snapshot, status=lambda s: ledger("rotation_status", {"session_id": s})):
    """(True, "ok") only for the exact, idle, Relay-owned incarnation whose pid owns the pane."""
    if status(old["session_id"]).get("owner") != "relay":
        return False, "old session is not Relay-owned"
    entry, why = match(agents(), old["session_id"], old["pid"], old["started_at_ms"])
    if entry is None:
        return False, f"old session not verified: {why}"
    if idle(entry) is not True:
        return False, "old session is not idle"
    if pane_pid != old["pid"]:
        return False, "pane does not belong to the old session's process"
    return True, "ok"


def exited(old, agents=snapshot):
    """Whether the old incarnation is gone, and if not, what it is doing."""
    entry = match(agents(), old["session_id"], old["pid"])[0]
    if entry is None:
        return True, "exited"
    return False, "busy after /exit: input reached a turn" if idle(entry) is False else "still listed after /exit"


def retire(transport, pane, old, agents=snapshot, status=lambda s: ledger("rotation_status", {"session_id": s}),
           **wait):
    """Type /exit once, only after retire_preflight passes. Never retypes or signals."""
    ok, why = retire_preflight(old, transport.pane_pid(pane), agents, status)
    if not ok:
        return False, why
    transport.send(pane, "/exit")
    if wait_for(lambda: True if exited(old, agents)[0] else None, **wait):
        return True, "exited"
    return exited(old, agents)


def receipt_cli(argv, get=ledger):
    """Run by the NEW session: fetch the fenced capsule, print it, print the receipt line."""
    opt = lambda name: argv[argv.index(name) + 1]
    reply = get("capsule_get", {"project_dir": opt("--project-dir"), "session_id": opt("--old")})
    capsule = reply.get("capsule") or {}
    if reply.get("status") != "ok" or str(capsule.get("revision")) != opt("--revision"):
        print(f"RELAY-RECEIPT-REFUSED status={reply.get('status')} revision={capsule.get('revision')}")
        return 1
    print(json.dumps(capsule, indent=2, sort_keys=True, ensure_ascii=False))
    print(receipt_line(opt("--intent"), opt("--new"), capsule["revision"], capsule_digest(capsule)))
    return 0


MAX_REQUEST = 1 << 20


def handle(req, agents=snapshot, status=lambda s: ledger("rotation_status", {"session_id": s}), root=PROJECTS):
    """One stateless operation for the Relay executor. It never launches, types, waits or
    signals: it returns what to launch or type, or checks what Relay reports."""
    op = req.get("op")
    if op == "plan_start":
        sid = session_id_for(req["intent_id"])
        return {"session_id": sid, "argv": launch_argv(req["fresh_argv"], req["intent_id"]), "cwd": req["cwd"]}
    if op == "confirm":
        entry = match(agents(), session_id_for(req["intent_id"]))[0]
        if entry is None:
            return {"confirmed": False, "reason": "not listed"}
        if req["pane_pid"] != entry.get("pid"):
            return {"confirmed": False, "reason": "pane does not run the new session"}
        return {"confirmed": True, "incarnation": {"session_id": entry["sessionId"], "pid": entry["pid"],
                                                   "started_at_ms": entry["startedAt"]}}
    if op == "receipt_plan":
        sid = session_id_for(req["intent_id"])
        capsule = req["capsule"]
        cmd = receipt_command(req["intent_id"], req["old_session_id"], sid, capsule["revision"], req["project_dir"])
        digest = capsule_digest(capsule)
        return {"tag": marker("receipt", req["intent_id"]), "prompt": receipt_prompt(req["intent_id"], cmd),
                "command": cmd, "expected_digest": digest,
                "expected_line": receipt_line(req["intent_id"], sid, capsule["revision"], digest)}
    if op == "continuation_plan":
        return {"tag": marker("continue", req["intent_id"]), "prompt": continuation_prompt(req["intent_id"])}
    if op == "delivered":
        return {"delivered": delivered(req["session_id"], req["tag"], root)}
    if op == "verify_receipt":
        inc = req["incarnation"]
        if not verify_receipt(transcript_entries(inc["session_id"], root), req["command"], req["expected_line"],
                              req["expected_digest"]):
            return {"verified": False, "reason": "no matching receipt in the transcript"}
        if match(agents(), inc["session_id"], inc["pid"], inc["started_at_ms"])[0] is None or req["pane_pid"] != inc["pid"]:
            return {"verified": False, "reason": "incarnation or pane changed"}
        s = status(inc["session_id"])
        if s.get("owner") != "relay" or s.get("turn_seq", 0) < 1:
            return {"verified": False, "reason": "not Relay-owned or no completed turn"}
        return {"verified": True, "turn_seq": s["turn_seq"]}
    if op == "retire_preflight":
        ok, why = retire_preflight(req["old"], req["pane_pid"], agents, status)
        return {"allowed": ok, "reason": why, "text": "/exit" if ok else None}
    if op == "retired":
        gone, why = exited(req["old"], agents)
        return {"retired": gone, "reason": why}
    raise ValueError(f"unknown op {op!r}")


def serve(stdin=sys.stdin, stdout=sys.stdout, **deps):
    """`claude_backend.py op < request.json`: one bounded JSON request, one JSON response."""
    raw = stdin.read(MAX_REQUEST + 1)
    try:
        if len(raw) > MAX_REQUEST:
            raise ValueError("request exceeds 1 MiB")
        req = json.loads(raw)
        if not isinstance(req, dict):
            raise ValueError("request must be a JSON object")
        out, rc = {"v": 1, "ok": True, **handle(req, **deps)}, 0
    except (ValueError, KeyError, TypeError, RuntimeError, subprocess.SubprocessError) as e:
        out, rc = {"v": 1, "ok": False, "error": f"{type(e).__name__}: {e}"}, 1
    stdout.write(json.dumps(out) + "\n")
    return rc


if __name__ == "__main__":
    mode = sys.argv[1:2]
    sys.exit(receipt_cli(sys.argv) if mode == ["receipt"] else serve() if mode == ["op"] else 2)
