#!/usr/bin/env python3
"""Read-only conversation snapshot. Exact process/open-file binding; no cwd fallback.
Runs through authenticated host execution, separate from AgentEvent status journals.
Never starts/resumes an agent or writes its transcript. Output is bounded JSON.
"""
import argparse, base64, binascii, datetime, hashlib, json, os, pathlib, re, selectors, stat, subprocess, sys, time

UID = os.getuid()
HOME = pathlib.Path.home()
MAX_SCAN = 64 << 20
MAX_LINE = 16 << 20
MAX_BODY = 128 << 10
MAX_OUTPUT = 512 << 10
ID = re.compile(r"^[A-Za-z0-9_-]{1,128}$")
UUID = re.compile(r"^[0-9a-fA-F-]{32,36}$")
ENV = dict(os.environ, LC_ALL="C", LANG="C", TZ="UTC")

class Unbound(Exception): pass

def run(args, timeout=4):
    # Bounded pipe capture prevents a malformed process/file inventory from exhausting memory.
    with subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                          stderr=subprocess.DEVNULL, env=ENV) as process:
        selector = selectors.DefaultSelector(); selector.register(process.stdout, selectors.EVENT_READ)
        data = bytearray(); deadline = time.monotonic() + timeout
        try:
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0 or not selector.select(remaining): raise subprocess.TimeoutExpired(args, timeout)
                chunk = os.read(process.stdout.fileno(), 65536)
                if not chunk: break
                data.extend(chunk)
                if len(data) > 2 << 20: raise Unbound("Process inventory exceeded its limit.")
            process.wait(timeout=max(.01, deadline-time.monotonic()))
        except BaseException:
            process.kill(); process.wait(); raise
        finally: selector.close()
        if process.returncode not in (0, 1): raise Unbound("Process discovery is unavailable.")
        return data.decode("utf-8", "replace")

def identity(pid):
    if sys.platform.startswith("linux"):
        path = pathlib.Path("/proc") / str(pid)
        if path.stat().st_uid != UID: raise Unbound("Process owner changed.")
        line = (path / "stat").read_text()
        fields = line[line.rfind(")") + 2:].split()
        return "linux:" + fields[19]
    line = run(["/bin/ps", "-p", str(pid), "-o", "uid=,lstart="]).strip().split(None, 1)
    if len(line) != 2 or int(line[0]) != UID: raise Unbound("Process owner changed.")
    return "darwin:" + line[1]

def epoch(pid):
    if sys.platform.startswith("linux"):
        with open("/proc/stat") as stream:
            boot = next(int(line.split()[1]) for line in stream if line.startswith("btime "))
        return boot + int(identity(pid).split(":", 1)[1]) / os.sysconf("SC_CLK_TCK")
    return datetime.datetime.strptime(identity(pid)[7:], "%a %b %d %H:%M:%S %Y").replace(tzinfo=datetime.timezone.utc).timestamp()

def inventory():
    text = run(["/bin/ps", "-u", str(UID), "-o", "pid=,ppid=,uid=,comm="])
    result = {}
    for line in text.splitlines():
        fields = line.split(None, 3)
        if len(fields) != 4: continue
        try: pid, parent, uid = map(int, fields[:3])
        except ValueError: continue
        if uid == UID and pid > 1: result[pid] = (parent, fields[3])
    if len(result) > 16384: raise Unbound("Process inventory exceeded its limit.")
    return result

def private_file(path, limit):
    fd = os.open(str(path), os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    with os.fdopen(fd, "rb") as stream:
        info = os.fstat(stream.fileno())
        if info.st_uid != UID or info.st_mode & 0o022 or not stat.S_ISREG(info.st_mode) or info.st_size > limit:
            raise Unbound("The source file is not an owner-controlled regular file.")
        return stream.read(limit + 1), info

def root_for_pane(pane):
    state = pathlib.Path(os.environ.get("XDG_STATE_HOME", HOME / ".local/state")) / "relay/workers"
    recovered = list(state.glob("recovered-*/" + pane + ".json"))[:3]
    paths = recovered or [state / (pane + ".json")]
    if len(paths) != 1: raise Unbound("Multiple recovered workers claim this pane.")
    data, _ = private_file(paths[0], 65536)
    record = json.loads(data)
    if record.get("session_id") != pane or record.get("state") != "running": raise Unbound("No live durable worker owns this pane.")
    worker, shell = int(record["worker_pid"]), int(record["shell_pid"])
    if sys.platform.startswith("linux") and identity(worker) != "linux:" + str(record["worker_start_time"]):
        raise Unbound("The worker process incarnation changed.")
    processes = inventory()
    if shell not in processes or worker not in ancestors(shell, processes): raise Unbound("The pane shell is not owned by its worker.")
    return shell

def ancestors(pid, processes):
    result = []
    while pid > 1 and pid in processes and len(result) < 64:
        if pid in result: raise Unbound("Invalid process ancestry.")
        result.append(pid); pid = processes[pid][0]
    return result

def provider(name):
    name = pathlib.Path(name).name.lower()
    if name in ("codex", "codex.exe"): return "codex"
    if name in ("claude", "claude.exe"): return "claude"
    return None

def agent(root):
    processes = inventory()
    if root not in processes: raise Unbound("The pane foreground process is no longer running.")
    candidates = {pid: provider(row[1]) for pid, row in processes.items() if root in ancestors(pid, processes) and provider(row[1])}
    # Nested subagents/wrappers never replace the top-level provider binding.
    top = [(pid, kind) for pid, kind in candidates.items() if not any(parent in candidates for parent in ancestors(pid, processes)[1:])]
    if len(top) != 1: raise Unbound("An exact, unique foreground agent is required.")
    return top[0]

def open_paths(pid):
    if sys.platform.startswith("linux"):
        result = []
        for item in list((pathlib.Path("/proc") / str(pid) / "fd").iterdir())[:8192]:
            try: result.append(pathlib.Path(os.readlink(item)))
            except OSError: pass
        return result
    data = run(["/usr/sbin/lsof", "-a", "-p", str(pid), "-u", str(UID), "-Fn"])
    return [pathlib.Path(line[1:]) for line in data.splitlines() if line.startswith("n/")]

def metadata(path, kind):
    fd = os.open(str(path), os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    with os.fdopen(fd, "rb") as stream:
        info = os.fstat(stream.fileno())
        if info.st_uid != UID or info.st_mode & 0o022 or not stat.S_ISREG(info.st_mode): return None
        for _ in range(16):
            line = stream.readline(MAX_LINE + 1)
            if not line or len(line) > MAX_LINE: return None
            try: row = json.loads(line)
            except ValueError: return None
            if not isinstance(row, dict): return None
            if kind == "codex" and row.get("type") == "session_meta":
                payload = row.get("payload", {})
                if isinstance(payload.get("source"), dict): return None
                sid = payload.get("id", "")
                return sid if isinstance(sid, str) and UUID.fullmatch(sid) else None
            if kind == "claude" and not row.get("isSidechain"):
                sid = row.get("sessionId", "")
                if isinstance(sid, str) and UUID.fullmatch(sid): return sid
    return None

def transcript(pid, kind):
    base = HOME / (".codex/sessions" if kind == "codex" else ".claude/projects")
    if kind == "codex" and os.environ.get("CODEX_HOME"): base = pathlib.Path(os.environ["CODEX_HOME"]) / "sessions"
    resolved = base.resolve()
    candidates = {}
    for path in open_paths(pid):
        try:
            path.resolve().relative_to(resolved)
            if path.suffix != ".jsonl": continue
            sid = metadata(path, kind)
            if sid: candidates[str(path.resolve())] = sid
        except (OSError, ValueError): pass
    if kind == "claude" and not candidates:
        registry = HOME / ".claude/sessions" / (str(pid) + ".json")
        try:
            data, info = private_file(registry, 65536)
            record = json.loads(data); sid = record.get("sessionId", record.get("session_id", ""))
            if not isinstance(sid, str) or not UUID.fullmatch(sid) or info.st_mtime + 1 < epoch(pid): raise Unbound("Stale session registry.")
            for path in list(base.glob("*/" + sid + ".jsonl"))[:3]:
                if metadata(path, kind) == sid: candidates[str(path.resolve())] = sid
        except (OSError, ValueError, Unbound): pass
    if len(candidates) != 1: raise Unbound("No unique transcript is bound to the running process. No directory fallback was used.")
    path, session = next(iter(candidates.items()))
    return pathlib.Path(path), session

def recheck_transcript(pid, kind, path, session, verified):
    # Process incarnation alone cannot prove that a TUI still displays this thread.
    # Authenticated transcript bindings are rechecked separately by their revision.
    if verified and verified.get("transcript_path"):
        if pathlib.Path(verified["transcript_path"]).resolve() != path.resolve() or metadata(path, kind) != session:
            raise Unbound("Authenticated transcript session changed during the read; refresh.")
        return
    current_path, current_session = transcript(pid, kind)
    if current_path.resolve() != path.resolve() or current_session != session:
        raise Unbound("The frontend changed its bound transcript during the read; refresh.")

def string(value): return value if isinstance(value, str) else ""
def text_blocks(content):
    if isinstance(content, str): return content, []
    text, tools = [], []
    if isinstance(content, list):
        for block in content[:256]:
            if not isinstance(block, dict): continue
            kind = block.get("type")
            if kind in ("text", "input_text", "output_text"): text.append(string(block.get("text")))
            elif kind == "tool_use": tools.append((string(block.get("name")), "requested", json.dumps(block.get("input", {}), ensure_ascii=False)[:8192]))
            elif kind == "tool_result": tools.append((string(block.get("tool_use_id")), "failed" if block.get("is_error") else "completed", text_blocks(block.get("content"))[0][:32768]))
            elif kind in ("image", "input_image"): text.append("[Image attached in provider transcript]")
    return "\n".join(text), tools

def embedded_image(block):
    if not isinstance(block, dict) or block.get("type") not in ("image", "input_image"): return "", ""
    source = block.get("source", {})
    mime, encoded = "", ""
    if isinstance(source, dict) and source.get("type") == "base64":
        mime, encoded = string(source.get("media_type")), string(source.get("data"))
    else:
        url = block.get("image_url", "")
        if isinstance(url, dict): url = url.get("url", "")
        if isinstance(url, str) and url.startswith("data:") and ";base64," in url:
            mime, encoded = url[5:].split(";base64,", 1)
    if mime not in ("image/png", "image/jpeg", "image/gif", "image/webp") or not encoded or len(encoded) > 12 << 20: return "", ""
    return mime, encoded

def image_attachments(content, offset):
    # References keep full image bytes out of the frequently refreshed snapshot.
    if not isinstance(content, list): return []
    images = []
    for index, block in enumerate(content[:256]):
        mime, encoded = embedded_image(block)
        if not encoded: continue
        images.append({"mime": mime, "offset": offset, "index": index,
                       "digest": hashlib.sha256(encoded.encode()).hexdigest()})
        if len(images) == 16: break
    return images

def parse(row, kind, session, offset, tool_names):
    result = []
    stable = string(row.get("uuid")) or str(offset)
    role, text, tools = None, "", []
    content = None
    if kind == "claude":
        if row.get("sessionId") != session or row.get("isSidechain"): return []
        if row.get("type") not in ("user", "assistant"): return []
        content = (row.get("message") or {}).get("content")
        if isinstance(content, list):
            for block in content[:256]:
                if not isinstance(block, dict) or block.get("type") != "tool_use": continue
                call_id, name = string(block.get("id")), string(block.get("name"))
                if call_id and name and len(call_id.encode()) <= 256 and len(name.encode()) <= 256:
                    tool_names[call_id] = name
                    while len(tool_names) > 4096: tool_names.pop(next(iter(tool_names)))
        role = row["type"]; text, tools = text_blocks(content)
        tools = [(tool_names.get(name, "Tool result") if status in ("completed", "failed") else name,
                  status, summary) for name, status, summary in tools]
    elif row.get("type") == "response_item":
        payload = row.get("payload", {})
        if not isinstance(payload, dict): return []
        stable = string(payload.get("id")) or stable
        if payload.get("type") == "message" and payload.get("role") in ("user", "assistant"):
            role = payload["role"]; text, tools = text_blocks(payload.get("content"))
        elif payload.get("type") in ("function_call", "function_call_output"):
            stable = (string(payload.get("call_id")) or stable) + ":" + payload["type"]
            tools = [(string(payload.get("name")) or "Tool result", "completed" if payload["type"] == "function_call_output" else "requested", string(payload.get("output", payload.get("arguments")))[:32768])]
    elif row.get("type") == "event_msg":
        payload = row.get("payload", {})
        if payload.get("type") == "plan_update": tools = [("Plan", "updated", json.dumps(payload.get("plan", []), ensure_ascii=False)[:8192])]
    images = image_attachments(content, offset)
    if (text or images) and role and len(text.encode()) <= MAX_BODY:
        if images: text = text.replace("[Image attached in provider transcript]", "", len(images)).strip()
        result.append({"id": stable, "role": role, "text": text, "images": images, "revision": offset + 1})
    for index, (name, status, summary) in enumerate(tools[:64]):
        result.append({"id": stable + ":tool:" + str(index), "role": "tool", "text": summary, "tool_name": name, "tool_status": status, "revision": offset + 1})
    return result

def authenticated_binding(binary, pane, pid, kind):
    if not binary: return None
    try:
        value = json.loads(run([binary, "agent-binding", pane], timeout=5))
        producer = value.get("producer", {})
        if value.get("version") != 1 or producer.get("pane_id") != pane or producer.get("process_id") != pid or producer.get("provider") != kind:
            raise Unbound("Authenticated producer does not match this conversation.")
        if not isinstance(producer.get("process_start"), int) or producer["process_start"] <= 0 or not ID.fullmatch(value.get("session_id", "")):
            raise Unbound("Invalid authenticated session binding.")
        # Fresh native observations carry different timestamps; the revision,
        # producer, session, transcript and kernel endpoint define identity.
        value.pop("observed_at", None)
        return value
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return None  # Older hosts remain read-only through their existing exact discovery.

def stock_proxy_identity(verified):
    """Identity from Relay's live kernel verified stock App Server proxy."""
    if not verified or verified.get("source") != "stock_app_server_proxy": return None
    proof = verified.get("stock_proxy", {})
    endpoint = verified.get("native_endpoint", {})
    fields = ("proxy_pid", "proxy_start", "control_device", "control_inode", "connection", "selection")
    if (not isinstance(proof, dict) or not isinstance(endpoint, dict)
            or any(not isinstance(proof.get(key), int) or isinstance(proof.get(key), bool) or proof[key] <= 0 for key in fields)
            or not isinstance(proof.get("control_socket"), str) or not proof["control_socket"].startswith("/")
            or not isinstance(endpoint.get("socket"), str) or not endpoint["socket"].startswith("/")
            or not isinstance(endpoint.get("daemon_pid"), int) or endpoint["daemon_pid"] <= 1
            or not isinstance(endpoint.get("daemon_start"), int) or endpoint["daemon_start"] <= 0
            or not re.fullmatch(r"[0-9a-f]{64}", verified.get("revision", ""))):
        raise Unbound("The stock App Server proxy has no live identity proof.")
    return "stock-proxy:" + verified["revision"]

def native_process_start(binary, pane, pid, kind):
    if not binary or kind != "codex": return None
    try:
        value = json.loads(run([binary, "agent-process-identity", pane, str(pid), kind], timeout=5))
        start = value.get("process_start")
        return start if isinstance(start, int) and not isinstance(start, bool) and start > 0 else None
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return None

def codex_lifecycle(row):
    if row.get("type") != "event_msg": return None
    payload = row.get("payload")
    if not isinstance(payload, dict): return None
    event = payload.get("type")
    state = {"task_started": "active", "turn_started": "active", "user_message": "active",
             "task_complete": "quiet", "turn_complete": "quiet",
             "turn_aborted": "stop_observed"}.get(event)
    timestamp = row.get("timestamp")
    if state is None or not isinstance(timestamp, str): return None
    try:
        # Hosts still running Python 3.6 have no datetime.fromisoformat.
        try: observed = datetime.datetime.strptime(timestamp, "%Y-%m-%dT%H:%M:%S.%fZ")
        except ValueError: observed = datetime.datetime.strptime(timestamp, "%Y-%m-%dT%H:%M:%SZ")
        if observed.replace(tzinfo=datetime.timezone.utc).timestamp() > time.time() + 60: return None
    except (ValueError, OverflowError): return None
    return state, timestamp

def binding_only(pane, root, binary):
    """Fresh bounded identity read for reconnect editing; no transcript history scan."""
    if not binary: raise Unbound("A kernel identity reader is required.")
    root = root or root_for_pane(pane)
    root_start = identity(root)
    pid, kind = agent(root)
    start = identity(pid)
    verified = authenticated_binding(binary, pane, pid, kind)
    proxy_identity = stock_proxy_identity(verified)
    if proxy_identity and not verified.get("transcript_path"):
        kernel = json.loads(run([binary, "agent-process-identity", pane, str(pid), kind], timeout=5))
        kernel_start = kernel.get("process_start")
        if not isinstance(kernel_start, int) or isinstance(kernel_start, bool) or kernel_start <= 0:
            raise Unbound("Kernel process identity is unavailable.")
        if (identity(root) != root_start or identity(pid) != start or root not in ancestors(pid, inventory())
                or authenticated_binding(binary, pane, pid, kind) != verified
                or json.loads(run([binary, "agent-process-identity", pane, str(pid), kind], timeout=5)).get("process_start") != kernel_start):
            raise Unbound("The live stock proxy binding changed.")
        return {"version": 1, "binding": {"pane_id": pane, "provider": kind,
            "process_id": pid, "process_start": "kernel:" + str(kernel_start),
            "session_id": verified["session_id"], "source_identity": proxy_identity}}
    if verified and verified.get("transcript_path"):
        path = pathlib.Path(verified["transcript_path"])
        session = verified["session_id"]
        if metadata(path, kind) != session: raise Unbound("Authenticated transcript session changed.")
    else:
        path, session = transcript(pid, kind)
    kernel = json.loads(run([binary, "agent-process-identity", pane, str(pid), kind], timeout=5))
    kernel_start = kernel.get("process_start")
    if not isinstance(kernel_start, int) or isinstance(kernel_start, bool) or kernel_start <= 0:
        raise Unbound("Kernel process identity is unavailable.")
    fd = os.open(str(path), os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    with os.fdopen(fd, "rb") as stream:
        info = os.fstat(stream.fileno())
        if info.st_uid != UID or info.st_mode & 0o022 or not stat.S_ISREG(info.st_mode):
            raise Unbound("Transcript ownership changed.")
        after = path.stat()
        if (info.st_dev, info.st_ino) != (after.st_dev, after.st_ino):
            raise Unbound("Transcript identity changed.")
    if identity(root) != root_start or identity(pid) != start or root not in ancestors(pid, inventory()):
        raise Unbound("The bound process changed during the read.")
    recheck_transcript(pid, kind, path, session, verified)
    after_kernel = json.loads(run([binary, "agent-process-identity", pane, str(pid), kind], timeout=5))
    if after_kernel.get("process_start") != kernel_start:
        raise Unbound("Kernel process identity changed.")
    if verified and authenticated_binding(binary, pane, pid, kind) != verified:
        raise Unbound("Authenticated binding changed.")
    return {"version": 1, "binding": {"pane_id": pane, "provider": kind,
        "process_id": pid, "process_start": "kernel:" + str(kernel_start),
        "session_id": session, "source_identity": str(info.st_dev) + ":" + str(info.st_ino)}}

def snapshot(pane, root, binary=None, before=None, expected_source=None, expected_session=None):
    root = root or root_for_pane(pane)
    root_start = identity(root)
    pid, kind = agent(root); start = identity(pid)
    verified = authenticated_binding(binary, pane, pid, kind)
    native_start = native_process_start(binary, pane, pid, kind) if not verified else None
    if verified and verified.get("transcript_path"):
        path = pathlib.Path(verified["transcript_path"])
        session = verified["session_id"]
        if metadata(path, kind) != session: raise Unbound("Authenticated transcript session changed.")
    else:
        path, session = transcript(pid, kind)
        if verified and session != verified["session_id"]: raise Unbound("Authenticated session differs from the open transcript.")
    items = []; retained = 0; tool_names = {}; native_state = None
    fd = os.open(str(path), os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    with os.fdopen(fd, "rb") as stream:
        info = os.fstat(stream.fileno())
        if info.st_uid != UID or info.st_mode & 0o022 or not stat.S_ISREG(info.st_mode): raise Unbound("Transcript ownership changed.")
        source_identity = str(info.st_dev) + ":" + str(info.st_ino)
        if expected_source and (source_identity != expected_source or session != expected_session):
            raise Unbound("The history source changed; return to the latest conversation.")
        end = info.st_size if before is None else min(before, info.st_size)
        scan_start = max(0, end - MAX_SCAN)
        discarding = False; omitted = False
        if scan_start:
            stream.seek(scan_start); discarding = not stream.readline(MAX_LINE + 1).endswith(b"\n")
        while stream.tell() < end:
            offset = stream.tell(); line = stream.readline(MAX_LINE + 1)
            if len(line) > MAX_LINE or discarding:
                discarding = not line.endswith(b"\n"); continue
            if not line.endswith(b"\n") or stream.tell() > end: break
            try: row = json.loads(line)
            except ValueError: continue
            if not isinstance(row, dict): continue
            if native_start is not None:
                state = codex_lifecycle(row)
                if state is not None: native_state = (state, offset)
            for item in parse(row, kind, session, offset, tool_names):
                size = len(json.dumps(item, ensure_ascii=False).encode())
                items.append((item, size)); retained += size
            while retained > MAX_OUTPUT - 8192 or len(items) > 256:
                removed_revision = items[0][0]["revision"]
                while items and items[0][0]["revision"] == removed_revision:
                    retained -= items.pop(0)[1]
                omitted = True
        after = path.stat()
        if (after.st_dev, after.st_ino) != (info.st_dev, info.st_ino) or after.st_size < info.st_size: raise Unbound("Transcript rotated during the read; refresh to resynchronize.")
    if identity(root) != root_start or identity(pid) != start or root not in ancestors(pid, inventory()): raise Unbound("The bound process changed during the read.")
    recheck_transcript(pid, kind, path, session, verified)
    control = None
    if verified:
        after_binding = authenticated_binding(binary, pane, pid, kind)
        if after_binding != verified: raise Unbound("Authenticated binding changed during the read; refresh.")
        start = "kernel:" + str(verified["producer"]["process_start"])
        control = {"lifecycle": verified.get("lifecycle", "unknown"), "revision": verified.get("revision", ""), "observed_at": verified.get("observed_at", "")}
    elif native_start is not None:
        if native_process_start(binary, pane, pid, kind) != native_start:
            raise Unbound("Original CLI process changed during the read.")
        start = "kernel:" + str(native_start)
        if native_state is not None:
            (state, observed), offset = native_state
            control = {"lifecycle": state,
                       "revision": hashlib.sha256((str(info.st_dev) + ":" + str(info.st_ino) + ":" + str(offset) + ":" + str(native_start)).encode()).hexdigest(),
                       "observed_at": observed}
    source_identity = str(info.st_dev) + ":" + str(info.st_ino)
    for item, size in items:
        for image in item.get("images", []):
            proof = dict(image, process_id=pid, process_start=start, session_id=session, source_identity=source_identity)
            image["reference"] = base64.b64encode(json.dumps(proof, separators=(",", ":")).encode()).decode("ascii")
    retained = sum(len(json.dumps(item, ensure_ascii=False).encode()) for item, size in items)
    while items and retained > MAX_OUTPUT - 8192:
        removed_revision = items[0][0]["revision"]
        while items and items[0][0]["revision"] == removed_revision:
            retained -= len(json.dumps(items.pop(0)[0], ensure_ascii=False).encode())
        omitted = True
    oldest = items[0][0]["revision"] - 1 if items else scan_start
    has_older = oldest > 0 and (omitted or scan_start > 0)
    return {"version": 1, "history": {"before": oldest if has_older else None, "historical": before is not None}, "control": control if before is None else None, "binding": {"pane_id": pane, "provider": kind, "process_id": pid, "process_start": start, "session_id": session, "source_identity": str(info.st_dev) + ":" + str(info.st_ino)}, "directory": str(path.parent), "items": [item for item, size in items], "source_revision": info.st_size}

def attachment(pane, root, binary, reference):
    if len(reference) > 4096: raise Unbound("Invalid image reference.")
    proof = json.loads(base64.b64decode(reference, validate=True))
    root = root or root_for_pane(pane); root_start = identity(root)
    pid, kind = agent(root); start = identity(pid)
    verified = authenticated_binding(binary, pane, pid, kind)
    if verified and verified.get("transcript_path"):
        path = pathlib.Path(verified["transcript_path"]); session = verified["session_id"]
        if metadata(path, kind) != session: raise Unbound("Transcript session changed.")
    else: path, session = transcript(pid, kind)
    native_start = native_process_start(binary, pane, pid, kind) if not verified else None
    expected_start = "kernel:" + str(verified["producer"]["process_start"]) if verified else ("kernel:" + str(native_start) if native_start is not None else start)
    if proof.get("process_id") != pid or proof.get("process_start") != expected_start or proof.get("session_id") != session:
        raise Unbound("Image reference belongs to a different process or session.")
    offset, index = proof.get("offset"), proof.get("index")
    if not isinstance(offset, int) or offset < 0 or not isinstance(index, int) or not 0 <= index < 256: raise Unbound("Invalid image location.")
    fd = os.open(str(path), os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    with os.fdopen(fd, "rb") as stream:
        info = os.fstat(stream.fileno())
        if info.st_uid != UID or info.st_mode & 0o022 or not stat.S_ISREG(info.st_mode) or proof.get("source_identity") != str(info.st_dev) + ":" + str(info.st_ino):
            raise Unbound("Image source identity changed.")
        stream.seek(offset); line = stream.readline(MAX_LINE + 1)
        if len(line) > MAX_LINE or not line.endswith(b"\n"): raise Unbound("Image source exceeds its limit.")
        row = json.loads(line)
        content = (row.get("message") or {}).get("content") if kind == "claude" else (row.get("payload") or {}).get("content")
        if kind == "claude" and (row.get("sessionId") != session or row.get("isSidechain")): raise Unbound("Image session changed.")
        if not isinstance(content, list) or index >= len(content): raise Unbound("Image source changed.")
        mime, encoded = embedded_image(content[index])
        if not encoded or mime != proof.get("mime") or hashlib.sha256(encoded.encode()).hexdigest() != proof.get("digest"): raise Unbound("Image bytes changed.")
        raw = base64.b64decode(encoded, validate=True)
        if not raw or len(raw) > 8 << 20: raise Unbound("Image exceeds the 8 MiB preview limit.")
        after = path.stat()
        if (after.st_dev, after.st_ino) != (info.st_dev, info.st_ino): raise Unbound("Image source rotated.")
    if identity(root) != root_start or identity(pid) != start or root not in ancestors(pid, inventory()): raise Unbound("Image process changed.")
    recheck_transcript(pid, kind, path, session, verified)
    if verified and authenticated_binding(binary, pane, pid, kind) != verified: raise Unbound("Image binding changed.")
    return {"version": 1, "mime": mime, "data": base64.b64encode(raw).decode("ascii")}

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--pane", required=True); parser.add_argument("--root-pid", type=int, default=0)
    parser.add_argument("--binding-daemon"); parser.add_argument("--attachment")
    parser.add_argument("--binding-only", action="store_true")
    parser.add_argument("--before", type=int); parser.add_argument("--source-identity"); parser.add_argument("--session")
    args = parser.parse_args()
    if not ID.fullmatch(args.pane) or args.root_pid < 0: raise Unbound("Invalid pane selector.")
    if args.before is not None and (args.before <= 0 or not args.source_identity or not args.session): raise Unbound("Invalid history cursor.")
    try:
        if args.binding_only: value = binding_only(args.pane, args.root_pid, args.binding_daemon)
        elif args.attachment: value = attachment(args.pane, args.root_pid, args.binding_daemon, args.attachment)
        else: value = snapshot(args.pane, args.root_pid, args.binding_daemon, args.before, args.source_identity, args.session)
    except (OSError, ValueError, KeyError, Unbound, subprocess.TimeoutExpired) as error:
        value = {"version": 1, "unbound": str(error)[:240]}
    output = json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode()
    if len(output) > ((12 << 20) if args.attachment else MAX_OUTPUT): output = b'{"version":1,"unbound":"Conversation exceeds the snapshot limit."}'
    sys.stdout.buffer.write(output + b"\n")

if __name__ == "__main__": main()
