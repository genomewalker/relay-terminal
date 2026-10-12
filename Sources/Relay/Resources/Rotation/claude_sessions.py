#!/usr/bin/env python3
"""Read-only view of `claude agents --json` (verified on Claude Code 2.1.283).

Matches one exact session incarnation (sessionId, pid, startedAt) and reports
whether it is idle. It never launches, stops or signals anything; argv handling
belongs to relayd's agentlaunch.

Usage: claude_sessions.py <session_id> [--pid N] [--started-at MS] [< agents.json]
"""
import json
import subprocess
import sys


def snapshot(timeout=30):
    out = subprocess.run(["claude", "agents", "--json"], capture_output=True, text=True, timeout=timeout, check=True)
    return parse(out.stdout)


def parse(text):
    entries = json.loads(text)
    if not isinstance(entries, list) or not all(isinstance(e, dict) for e in entries):
        raise ValueError("claude agents --json did not return a list of objects")
    return entries


def incarnation(entry):
    return {"session_id": entry.get("sessionId"), "pid": entry.get("pid"), "started_at_ms": entry.get("startedAt"),
            "kind": entry.get("kind"), "short_id": entry.get("id"), "cwd": entry.get("cwd")}


def idle(entry):
    """True only for status "idle" with nothing awaited; None when status is absent."""
    status = entry.get("status")
    if status is None:
        return None
    return status == "idle" and not entry.get("waitingFor")


def match(entries, session_id, pid=None, started_at_ms=None):
    """The single entry for this incarnation, or (None, reason). Duplicates are ambiguous."""
    same = [e for e in entries if e.get("sessionId") == session_id]
    if not same:
        return None, "session not listed"
    if len(same) > 1:
        return None, "session listed more than once"
    e = same[0]
    if pid is not None and e.get("pid") != pid:
        return None, "pid differs: a different incarnation" if "pid" in e else "pid not reported"
    if started_at_ms is not None and e.get("startedAt") != started_at_ms:
        return None, "startedAt differs: a different incarnation"
    return e, "matched"


def main(argv):
    if len(argv) < 2:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 2
    opt = lambda name: int(argv[argv.index(name) + 1]) if name in argv else None
    entries = snapshot() if sys.stdin.isatty() else parse(sys.stdin.read())
    entry, reason = match(entries, argv[1], opt("--pid"), opt("--started-at"))
    print(json.dumps({"match": incarnation(entry) if entry else None, "idle": idle(entry) if entry else None,
                      "reason": reason}))
    return 0 if entry else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
