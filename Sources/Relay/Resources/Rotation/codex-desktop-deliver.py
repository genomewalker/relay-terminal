"""One-shot ingress for a trusted Relay parent; not a network/auth endpoint.

Reads one bounded JSON envelope from stdin. Never resumes a task, retries a
message, launches a backend, or turns collaborator content into user input.
Requires websockets. A lost response means UNKNOWN, not safe to retry.
"""
import argparse
import asyncio
import json
import os
from pathlib import Path
import stat
import sys

import websockets

LIMIT = 65536


def params(thread, envelope):
    if not isinstance(envelope, dict):
        raise ValueError("envelope must be an object")
    if not isinstance(thread, str) or not thread.strip():
        raise ValueError("exact desktop task required")
    for key in ("id", "sender", "content"):
        if not isinstance(envelope.get(key), str) or not envelope[key].strip():
            raise ValueError("id, authenticated sender and content required")
    body = json.dumps({k: envelope[k] for k in ("id", "sender", "content")})
    if len(body.encode()) > LIMIT:
        raise ValueError("message too large")
    return {"threadId": thread, "input": [], "toolOutput": {
        "namespace": "relay", "name": "peer_message", "output": body}}


def check_socket(path):
    path = os.path.abspath(path)
    info = os.lstat(path)
    if stat.S_ISLNK(info.st_mode):
        parent = os.lstat(os.path.dirname(path))
        if (info.st_uid != os.getuid() or not stat.S_ISDIR(parent.st_mode)
                or parent.st_uid != os.getuid() or stat.S_IMODE(parent.st_mode) != 0o700):
            raise ValueError("unsafe desktop socket link")
        linked = os.readlink(path)
        path = os.path.abspath(os.path.join(os.path.dirname(path), linked))
        target_parent = os.lstat(os.path.dirname(path))
        if (not stat.S_ISDIR(target_parent.st_mode) or target_parent.st_uid != os.getuid()
                or stat.S_IMODE(target_parent.st_mode) != 0o700):
            raise ValueError("unsafe desktop socket directory")
        info = os.lstat(path)
    if (not stat.S_ISSOCK(info.st_mode) or info.st_uid != os.getuid()
            or stat.S_IMODE(info.st_mode) != 0o600):
        raise ValueError("server socket must be owned by this user, mode 0600")
    return path


async def deliver(path, thread, envelope):
    payload = params(thread, envelope)
    path = check_socket(path)
    dispatched = False
    try:
        async with asyncio.timeout(15):
            async with websockets.unix_connect(path, compression=None,
                                                max_size=2**20) as ws:
                async def rpc(ident, method, args):
                    await ws.send(json.dumps({"id": ident, "method": method, "params": args}))
                    async for raw in ws:
                        reply = json.loads(raw)
                        if reply.get("id") == ident:
                            if "error" in reply:
                                raise RuntimeError("server rejected request: " + str(reply["error"]))
                            return reply["result"]
                    raise ConnectionError("server disconnected")

                await rpc(1, "initialize", {"clientInfo": {
                    "name": "relay_desktop_ingress", "version": "0.1"},
                    "capabilities": {"experimentalApi": True}})
                loaded = await rpc(2, "thread/loaded/list", {})
                if thread not in loaded.get("data", []):
                    raise ValueError("task not loaded; delivery refused (no implicit resume)")
                dispatched = True
                result = await rpc(3, "turn/start", payload)
                return {"messageId": envelope["id"], "receipt": "admitted",
                        "turnId": result["turn"]["id"]}
    except Exception as error:
        return {"messageId": envelope["id"],
                "receipt": "unknown" if dispatched else "not_sent",
                "error": str(error), "retrySafe": False}


async def sender_permission_class(path, thread):
    """Attest the exact loaded task from its latest recorded runtime context."""
    path = check_socket(path)
    async with asyncio.timeout(15):
        async with websockets.unix_connect(path, compression=None, max_size=2**20) as ws:
            async def rpc(ident, method, args):
                await ws.send(json.dumps(dict(id=ident, method=method, params=args)))
                async for raw in ws:
                    reply = json.loads(raw)
                    if reply.get('id') == ident:
                        if 'error' in reply:
                            raise ValueError('Sender permission discovery rejected')
                        return reply['result']
                raise ConnectionError('Desktop disconnected')
            await rpc(1, 'initialize', {'clientInfo': {'name': 'relay_permission_attestation', 'version': '0.1'},
                                      'capabilities': {'experimentalApi': True}})
            if thread not in (await rpc(2, 'thread/loaded/list', {})).get('data', []):
                raise ValueError('Sender task is not loaded')
            item = (await rpc(3, 'thread/read', {'threadId': thread, 'includeTurns': False}))['thread']
            if item.get('id') != thread:
                raise ValueError('Sender task identity changed')
            root = (Path.home() / '.codex/sessions').resolve()
            context_path = Path(item['path'])
            if context_path.is_symlink() or not context_path.resolve().is_relative_to(root):
                raise ValueError('Invalid sender context path')
            info = context_path.stat()
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o022:
                raise ValueError('Unsafe sender context')
            with context_path.open('rb') as source:
                source.seek(max(0, info.st_size - (8 << 20)))
                lines = source.read(8 << 20).splitlines()
            for line in reversed(lines):
                try:
                    record = json.loads(line)
                except (ValueError, UnicodeError):
                    continue
                if record.get('type') != 'turn_context':
                    continue
                context = record.get('payload', {})
                policy = context.get('approval_policy')
                if policy == 'never' and context.get('sandbox_policy', {}).get('type') == 'danger-full-access':
                    return 'bypass'
                if policy in ('on-request', 'on-failure', 'untrusted'):
                    return 'prompting'
                return None
            return None


async def loaded_tasks(path):
    """Enumerate loaded IDs only. Never read history or resume a task."""
    path = check_socket(path)
    async with asyncio.timeout(15):
        async with websockets.unix_connect(path, compression=None, max_size=2**20) as ws:
            for ident, method, args in [
                (1, 'initialize', {'clientInfo': {'name': 'relay_task_picker', 'version': '0.1'},
                                   'capabilities': {'experimentalApi': True}}),
                (2, 'thread/loaded/list', {})]:
                await ws.send(json.dumps(dict(id=ident, method=method, params=args)))
                async for raw in ws:
                    reply = json.loads(raw)
                    if reply.get('id') == ident:
                        if 'error' in reply:
                            raise ValueError('Desktop task discovery was rejected')
                        break
                else:
                    raise ConnectionError('Desktop disconnected')
            rows = reply['result']['data']
            if not isinstance(rows, list) or len(rows) > 128 or any(
                    not isinstance(x, str) or not 1 <= len(x) <= 110 for x in rows):
                raise ValueError('Desktop task list is invalid or exceeds 128 tasks')
            return sorted(set(rows))


async def loaded_task_details(path):
    """Read names and activity for loaded tasks only, without loading turns."""
    path = check_socket(path)
    async with asyncio.timeout(15):
        async with websockets.unix_connect(path, compression=None, max_size=2**20) as ws:
            async def rpc(ident, method, params):
                await ws.send(json.dumps(dict(id=ident, method=method, params=params)))
                async for raw in ws:
                    reply = json.loads(raw)
                    if reply.get('id') == ident:
                        if 'error' in reply:
                            raise ValueError('Desktop task metadata was rejected')
                        return reply['result']
                raise ConnectionError('Desktop disconnected')

            await rpc(1, 'initialize', {'clientInfo': {'name': 'relay_network', 'version': '0.1'},
                                        'capabilities': {'experimentalApi': True}})
            rows = (await rpc(2, 'thread/loaded/list', {})).get('data')
            if not isinstance(rows, list) or len(rows) > 128 or any(
                    not isinstance(x, str) or not 1 <= len(x) <= 110 for x in rows):
                raise ValueError('Desktop task list is invalid')
            details = []
            for ident, thread in enumerate(sorted(set(rows)), 3):
                try:
                    item = (await rpc(ident, 'thread/read',
                                      {'threadId': thread, 'includeTurns': False}))['thread']
                    if item.get('id') != thread:
                        raise ValueError('Desktop task identity changed')
                    name = item.get('name')
                    if not isinstance(name, str) or not name.strip() or len(name) > 180 or any(
                            ord(ch) < 32 or ord(ch) == 127 for ch in name):
                        name = None
                    status = item.get('status', {}).get('type')
                    if status not in ('active', 'idle'):
                        status = 'unknown'
                except (KeyError, TypeError, ValueError):
                    name, status = None, 'unknown'
                details.append(dict(id=thread, name=name, status=status))
            return details


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--socket", required=True)
    parser.add_argument("--thread", required=True)
    args = parser.parse_args()
    try:
        raw = sys.stdin.buffer.read(LIMIT + 1)
        if len(raw) > LIMIT:
            raise ValueError("envelope too large")
        result = asyncio.run(deliver(args.socket, args.thread, json.loads(raw)))
    except Exception as error:
        result = {"receipt": "not_sent", "error": str(error), "retrySafe": False}
    print(json.dumps(result))
    sys.exit(0 if result["receipt"] == "admitted" else 1)
