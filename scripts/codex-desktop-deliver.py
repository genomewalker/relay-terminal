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
    ref = work_ref(path, thread)
    if ref is not None:
        return await _deliver_work(ref, thread, envelope)
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
    ref = work_ref(path, thread)
    if ref is not None:
        async with WorkIPC(ref) as ipc:
            await ipc.owner()
        return None
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


async def _loaded_app_server_tasks(path):
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


async def _loaded_app_server_task_details(path):
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


# Work owns its live task through the desktop IPC router, rather than the
# standalone Codex daemon. Only explicitly registered task references are read.
# This registry contains endpoint identities, never credentials or chat history.
import ctypes
import re
import socket
import struct
import subprocess
import tempfile
import uuid

WORK_ROOT = Path.home() / ".local/share/relay/work-task-endpoints"
WORK_SOCKET = Path.home() / ".codex/ipc/ipc.sock"
LEGACY_SOCKET = Path.home() / ".codex/app-server-control/app-server-control.sock"
WORK_APP = "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT"
IDENTIFIER = re.compile(r"[A-Za-z0-9_][A-Za-z0-9_.-]{0,109}")
CLIENT_ID = re.compile(r"[0-9a-fA-F-]{36}")


def _private_work_root(create=False):
    if create:
        WORK_ROOT.mkdir(mode=0o700, parents=True, exist_ok=True)
    if not WORK_ROOT.exists():
        return False
    info = WORK_ROOT.lstat()
    if (not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid()
            or stat.S_IMODE(info.st_mode) != 0o700):
        raise ValueError("Unsafe Work endpoint directory")
    return True


def _validate_work_ref(ref):
    if (not isinstance(ref, dict) or ref.get("schema") != 1
            or not isinstance(ref.get("thread"), str) or not IDENTIFIER.fullmatch(ref["thread"])
            or ref.get("hostId") != "local" or ref.get("socket") != str(WORK_SOCKET)
            or ref.get("appPath") != WORK_APP
            or type(ref.get("appPID")) is not int or ref["appPID"] <= 0
            or not isinstance(ref.get("appStart"), str) or not 10 <= len(ref["appStart"]) <= 80
            or not isinstance(ref.get("ownerClientId"), str)
            or not CLIENT_ID.fullmatch(ref["ownerClientId"])):
        raise ValueError("Invalid Work endpoint identity")
    return ref


def _read_work_ref(path):
    if not _private_work_root():
        return None
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, "rb") as source:
        info = os.fstat(source.fileno())
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                or stat.S_IMODE(info.st_mode) != 0o600 or info.st_size > 16384):
            raise ValueError("Unsafe Work endpoint reference")
        ref = _validate_work_ref(json.loads(source.read(16385)))
    if path.name != ref["thread"] + ".json":
        raise ValueError("Work endpoint filename changed")
    return ref


def work_ref(path, thread):
    # Never apply a global fallback to a caller's private fixture/socket.
    if os.path.abspath(path) != str(LEGACY_SOCKET):
        return None
    if not isinstance(thread, str) or not IDENTIFIER.fullmatch(thread):
        raise ValueError("Exact Work task required")
    if not _private_work_root():
        return None
    ref_path = WORK_ROOT / (thread + ".json")
    try:
        return _read_work_ref(ref_path)
    except FileNotFoundError:
        return None


def work_refs(path):
    if os.path.abspath(path) != str(LEGACY_SOCKET) or not _private_work_root():
        return []
    paths = sorted(WORK_ROOT.glob("*.json"))
    if len(paths) > 16:
        raise ValueError("Work endpoint registry exceeds 16 explicitly selected tasks")
    return [_read_work_ref(p) for p in paths]


def _work_process(ref):
    result = subprocess.run(["/bin/ps", "-p", str(ref["appPID"]), "-o", "lstart="],
                            capture_output=True, text=True, timeout=3)
    if result.returncode or result.stdout.strip() != ref["appStart"]:
        raise ValueError("Work app process changed; explicitly refresh this endpoint")
    libc = ctypes.CDLL("/usr/lib/libproc.dylib")
    output = ctypes.create_string_buffer(4096)
    if libc.proc_pidpath(ref["appPID"], output, len(output)) <= 0:
        raise ValueError("Work app executable could not be verified")
    if os.fsdecode(output.value) != WORK_APP:
        raise ValueError("Work endpoint belongs to a different application")


class WorkIPC:
    """Bounded IPC client; exact task owner, no resume and no write replay."""

    def __init__(self, ref):
        self.ref = ref
        self.client_id = "initializing-client"
        self.reader = None
        self.writer = None

    async def __aenter__(self):
        _work_process(self.ref)
        directory = WORK_SOCKET.parent.lstat()
        if (not stat.S_ISDIR(directory.st_mode) or directory.st_uid != os.getuid()
                or stat.S_IMODE(directory.st_mode) != 0o700):
            raise ValueError("Unsafe Work IPC directory")
        path = check_socket(str(WORK_SOCKET))
        self.reader, self.writer = await asyncio.wait_for(asyncio.open_unix_connection(path), 3)
        try:
            sock = self.writer.get_extra_info("socket")
            peer_pid = struct.unpack("i", sock.getsockopt(0, 2, 4))[0]
            peer_uid, peer_gid = ctypes.c_uint(), ctypes.c_uint()
            libc = ctypes.CDLL(None)
            if (libc.getpeereid(sock.fileno(), ctypes.byref(peer_uid), ctypes.byref(peer_gid)) != 0
                    or peer_uid.value != os.getuid() or peer_pid != self.ref["appPID"]):
                raise ValueError("Work IPC peer identity changed")
            _work_process(self.ref)
            result = await self.request("initialize", {"clientType": "relay"}, version=0)
            self.client_id = result["result"]["clientId"]
            if not isinstance(self.client_id, str) or not CLIENT_ID.fullmatch(self.client_id):
                raise ValueError("Invalid Work IPC client identity")
            return self
        except BaseException:
            await self.__aexit__(None, None, None)
            raise

    async def __aexit__(self, *_):
        if self.writer is not None:
            self.writer.close()
            try:
                await asyncio.wait_for(self.writer.wait_closed(), 2)
            except (OSError, asyncio.TimeoutError):
                pass
            self.writer = None

    async def _send(self, value):
        raw = json.dumps(value, separators=(",", ":")).encode()
        if len(raw) > 131072:
            raise ValueError("Work IPC request exceeds the route limit")
        self.writer.write(struct.pack("<I", len(raw)) + raw)
        await self.writer.drain()

    async def _read(self):
        raw = await self.reader.readexactly(4)
        count = struct.unpack("<I", raw)[0]
        if count == 0 or count > 8 << 20:
            raise ValueError("Work IPC response exceeds the route limit")
        value = json.loads(await self.reader.readexactly(count))
        if not isinstance(value, dict):
            raise ValueError("Invalid Work IPC frame")
        return value

    async def request(self, method, params, *, version, target=None):
        request_id = str(uuid.uuid4())
        request = dict(type="request", requestId=request_id, sourceClientId=self.client_id,
                       method=method, params=params, version=version, timeoutMs=12000)
        if target is not None:
            request["targetClientId"] = target
        await self._send(request)
        async with asyncio.timeout(15):
            while True:
                message = await self._read()
                if message.get("type") == "client-discovery-request":
                    await self._send(dict(type="client-discovery-response",
                        requestId=message["requestId"], response=dict(canHandle=False)))
                # Unrelated broadcasts are discarded, never exposed or retained.
                if message.get("type") != "response" or message.get("requestId") != request_id:
                    continue
                if message.get("resultType") != "success":
                    raise ValueError("Work native request refused: " + str(message.get("error", "unknown")))
                if message.get("method") != method:
                    raise ValueError("Work native response method changed")
                if target is not None and message.get("handledByClientId") != target:
                    raise ValueError("Work native response owner changed")
                return message

    async def owner(self, require_pin=True):
        result = await self.request("thread-owner-discovery",
            dict(hostId="local", conversationId=self.ref["thread"]), version=1)
        owner = result.get("handledByClientId")
        if (not isinstance(owner, str) or not CLIENT_ID.fullmatch(owner)
                or result.get("result", {}).get("supportsUntrustedAppInput") is not True):
            raise ValueError("Work task does not expose a safe native owner")
        if require_pin and owner != self.ref["ownerClientId"]:
            raise ValueError("Work task owner changed; explicitly refresh this endpoint")
        return owner



def _current_work_ref(thread):
    """Read the current kernel-owned app incarnation; do not persist it."""
    if not isinstance(thread, str) or not IDENTIFIER.fullmatch(thread):
        raise ValueError("Exact requested Work task required")
    directory = WORK_SOCKET.parent.lstat()
    if (not stat.S_ISDIR(directory.st_mode) or directory.st_uid != os.getuid()
            or stat.S_IMODE(directory.st_mode) != 0o700):
        raise ValueError("Unsafe Work IPC directory")
    path = check_socket(str(WORK_SOCKET))
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as peer:
        peer.settimeout(3)
        peer.connect(path)
        pid = struct.unpack("i", peer.getsockopt(0, 2, 4))[0]
        uid, gid = ctypes.c_uint(), ctypes.c_uint()
        if (ctypes.CDLL(None).getpeereid(peer.fileno(), ctypes.byref(uid), ctypes.byref(gid)) != 0
                or uid.value != os.getuid() or pid <= 0):
            raise ValueError("Work IPC peer identity could not be verified")
        start = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "lstart="],
                               capture_output=True, text=True, timeout=3)
        if start.returncode:
            raise ValueError("Work app process is unavailable")
        ref = dict(schema=1, thread=thread, hostId="local", socket=str(WORK_SOCKET),
                   appPath=WORK_APP, appPID=pid, appStart=start.stdout.strip(),
                   ownerClientId="00000000-0000-0000-0000-000000000000")
        _validate_work_ref(ref)
        _work_process(ref)
        return ref


async def inspect_work_task(thread):
    ref = _current_work_ref(thread)
    async with WorkIPC(ref) as ipc:
        ref["ownerClientId"] = await ipc.owner(require_pin=False)
        _work_process(ref)
    return ref


def _commit_work_ref(ref, expected):
    """CAS only this selected task under the registry lock."""
    import fcntl
    _validate_work_ref(ref)
    _private_work_root(create=True)
    path = WORK_ROOT / (ref["thread"] + ".json")
    fd = os.open(WORK_ROOT / ".registry.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "a") as lock:
        info = os.fstat(lock.fileno())
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                or stat.S_IMODE(info.st_mode) != 0o600):
            raise ValueError("Unsafe Work registry lock")
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            current = _read_work_ref(path)
        except FileNotFoundError:
            current = None
        if current != expected:
            raise ValueError("Selected Work endpoint changed concurrently; refresh before connecting")
        if current is None and len(list(WORK_ROOT.glob("*.json"))) >= 16:
            raise ValueError("Work endpoint registry exceeds 16 explicitly selected tasks")
        _work_process(ref)
        if current == ref:
            return ref
        fd, temporary = tempfile.mkstemp(prefix=".work-ref-", dir=WORK_ROOT)
        try:
            with os.fdopen(fd, "wb") as target:
                target.write((json.dumps(ref, sort_keys=True) + "\n").encode())
                target.flush()
                os.fsync(target.fileno())
            if current is None:
                os.link(temporary, path, follow_symlinks=False)
            else:
                os.replace(temporary, path)
            directory_fd = os.open(WORK_ROOT, os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(directory_fd)
            finally:
                os.close(directory_fd)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
    return ref


async def inspect_loaded_task(path, thread):
    """Resolve one exact currently open task; no registration or resume."""
    if not isinstance(thread, str) or not IDENTIFIER.fullmatch(thread):
        raise ValueError("Exact desktop task required")
    if os.path.abspath(path) == str(LEGACY_SOCKET):
        try:
            ref = await inspect_work_task(thread)
            return dict(id=thread, transport="work_ipc", ref=ref)
        except (OSError, ValueError, RuntimeError, asyncio.TimeoutError, asyncio.IncompleteReadError):
            pass
    if thread not in await _loaded_app_server_tasks(path):
        raise ValueError("Selected desktop task is unavailable; no implicit resume")
    return dict(id=thread, transport="app_server")


async def prepare_loaded_task(path, thread):
    """Only an explicit connection action may refresh its selected endpoint."""
    expected = work_ref(path, thread)
    selected = await inspect_loaded_task(path, thread)
    if selected["transport"] == "work_ipc":
        _commit_work_ref(selected["ref"], expected)
    return selected


async def register_work_task(thread, app_pid, app_start):
    if not isinstance(thread, str) or not IDENTIFIER.fullmatch(thread):
        raise ValueError("Exact requested Work task required")
    ref = dict(schema=1, thread=thread, hostId="local", socket=str(WORK_SOCKET),
               appPath=WORK_APP, appPID=app_pid, appStart=app_start,
               ownerClientId="00000000-0000-0000-0000-000000000000")
    _validate_work_ref(ref)
    async with WorkIPC(ref) as ipc:
        ref["ownerClientId"] = await ipc.owner(require_pin=False)
    existing = work_ref(str(LEGACY_SOCKET), thread)
    if existing is not None and existing != ref:
        raise ValueError("Existing Work binding changed; explicit connection refresh required")
    return _commit_work_ref(ref, existing)


async def verify_loaded_task(path, thread):
    ref = work_ref(path, thread)
    if ref is not None:
        async with WorkIPC(ref) as ipc:
            await ipc.owner()
        return
    if thread not in await _loaded_app_server_tasks(path):
        raise ValueError("Task is not loaded; no implicit resume")


async def _loaded_work_tasks(path):
    async def live(ref):
        try:
            async with WorkIPC(ref) as ipc:
                await ipc.owner()
            return ref["thread"]
        except (OSError, ValueError, RuntimeError, asyncio.TimeoutError, asyncio.IncompleteReadError):
            return None
    rows = await asyncio.gather(*(live(ref) for ref in work_refs(path)))
    return [row for row in rows if row is not None]


async def _deliver_work(ref, thread, envelope):
    payload = params(thread, envelope)
    dispatched = False
    try:
        async with asyncio.timeout(20):
            async with WorkIPC(ref) as ipc:
                owner = await ipc.owner()
                request = dict(conversationId=thread, turnStart=dict(
                    request=payload, context=dict(useAppServerPermissionDefault=True,
                                                  inheritThreadSettings=True)))
                dispatched = True
                await ipc.request("thread-follower-start-turn", request,
                                  version=2, target=owner)
                return dict(messageId=envelope["id"], receipt="admitted", transport="work_ipc")
    except Exception as error:
        return dict(messageId=envelope["id"], receipt="unknown" if dispatched else "not_sent",
                    error=str(error), retrySafe=False)


async def loaded_tasks(path):
    work = await _loaded_work_tasks(path)
    try:
        legacy = await _loaded_app_server_tasks(path)
    except (FileNotFoundError, ConnectionRefusedError):
        if not work:
            raise
        legacy = []
    return sorted(set(legacy + work))


async def loaded_task_details(path):
    work = await _loaded_work_tasks(path)
    try:
        legacy = await _loaded_app_server_task_details(path)
    except (FileNotFoundError, ConnectionRefusedError):
        if not work:
            raise
        legacy = []
    ids = {row["id"] for row in legacy}
    return legacy + [dict(id=thread, name=None, status="unknown") for thread in work if thread not in ids]


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
