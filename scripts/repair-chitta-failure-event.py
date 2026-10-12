#!/usr/bin/env python3
"""Repair the installed Claude post-tool event adapter, with a private backup."""
import hashlib
import os
from pathlib import Path
import stat
import tempfile

p = Path.home() / '.claude/plugins/cache/genomewalker-chitta/chitta/5.73.1/chitta-mcp/hook_client.py'
info = p.lstat()
if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
    raise RuntimeError('Expected an owned regular adapter file')
raw = p.read_bytes()
source = raw.decode()
anchor = '    client.apply(plan)\n    if plan.get("provenance"):'
replacement = '''    # The same daemon policy handles successful and failed tool calls.
    # Claude validates the output discriminator against the incoming event.
    if raw.get("hook_event_name") == "PostToolUseFailure":
        try:
            rendered = json.loads(plan["stdout"])
        except (ValueError, TypeError):
            rendered = None
        if isinstance(rendered, dict):
            specific = rendered.get("hookSpecificOutput")
            if isinstance(specific, dict) and specific.get("hookEventName") == "PostToolUse":
                specific["hookEventName"] = "PostToolUseFailure"
                plan["stdout"] = json.dumps(rendered, ensure_ascii=False) + "\\n"
    client.apply(plan)
    if plan.get("provenance"):'''
if replacement in source:
    print('Already repaired', hashlib.sha256(raw).hexdigest())
else:
    if source.count(anchor) != 1:
        raise RuntimeError('Adapter anchor is ambiguous or changed')
    updated = source.replace(anchor, replacement).encode()
    backup = Path.home() / '.config/relay/backups/chitta-failure-event-20261004'
    backup.mkdir(mode=0o700, parents=True, exist_ok=True)
    with (backup / ('hook_client-' + hashlib.sha256(raw).hexdigest() + '.py')).open('xb') as f:
        os.chmod(f.name, 0o600)
        f.write(raw)
        f.flush()
        os.fsync(f.fileno())
    fd, tmp = tempfile.mkstemp(prefix='.hook-client-', dir=str(p.parent))
    try:
        with os.fdopen(fd, 'wb') as f:
            f.write(updated)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, stat.S_IMODE(info.st_mode))
        if p.read_bytes() != raw or p.lstat().st_ino != info.st_ino:
            raise RuntimeError('Adapter changed during repair')
        os.replace(tmp, str(p))
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)
    print('Repaired', str(p), hashlib.sha256(updated).hexdigest(), 'backup', str(backup))
