"""Opt-in live signed-backend test. Requires websockets and existing login.

Creates only an isolated temporary session; never attaches to desktop threads.
"""
import asyncio
import json
import os
import subprocess
import tempfile
import argparse
from pathlib import Path

import websockets


async def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", default=os.environ.get("RELAY_TEST_CODEX_BINARY"))
    args = parser.parse_args()
    candidates = [Path(args.binary)] if args.binary else [
        Path("/Applications/Codex.app/Contents/Resources/codex"),
        Path("/Applications/ChatGPT.app/Contents/Resources/codex"),
        Path.home() / ".local/bin/codex",
    ]
    binary = next((str(path) for path in candidates if path.is_file() and os.access(path, os.X_OK)), None)
    if binary is None:
        parser.error("no installed Codex backend; pass --binary /absolute/path/to/codex")
    with tempfile.TemporaryDirectory(prefix="relay-shared-", dir="/tmp") as tmp:
        Path(tmp, "auth.json").symlink_to(Path.home() / ".codex/auth.json")
        env = dict(os.environ, CODEX_HOME=tmp)
        socket = tmp + "/server.sock"
        process = subprocess.Popen(
            [binary, "app-server", "--listen", "unix://" + socket],
            env=env, cwd=tmp, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        try:
            for _ in range(100):
                if os.path.exists(socket):
                    break
                if process.poll() is not None:
                    raise RuntimeError("server exited before readiness")
                await asyncio.sleep(.05)
            # This server rejects permessage-deflate negotiation.
            async with websockets.unix_connect(socket, compression=None) as a, \
                    websockets.unix_connect(socket, compression=None) as b:
                async def rpc(ws, identifier, method, params):
                    await ws.send(json.dumps(dict(id=identifier, method=method, params=params)))
                    while True:
                        response = json.loads(await asyncio.wait_for(ws.recv(), 20))
                        if response.get("id") == identifier:
                            if "error" in response:
                                raise RuntimeError(response["error"])
                            return response["result"]

                for ws in (a, b):
                    await rpc(ws, 1, "initialize", {
                        "clientInfo": {"name": "relay_shared_test", "version": "0.1"},
                        "capabilities": {"experimentalApi": True},
                    })
                    await ws.send('{"method":"initialized"}')
                result = await rpc(a, 2, "thread/start", {
                    "cwd": tmp, "model": "gpt-6-astra",
                    "sandbox": "read-only", "approvalPolicy": "never",
                    "developerInstructions": "Connectivity test. Never call tools. Echo the exact contents of each external tool output, verbatim.",
                })
                thread = result["thread"]["id"]
                await rpc(a, 10, "turn/start", {
                    "threadId": thread,
                    "input": [{"type": "text", "text": "We are testing message delivery. Reply READY now. For subsequent relay_peer tool outputs, echo their exact token verbatim. Never use tools."}],
                })
                async with asyncio.timeout(60):
                    while True:
                        event = json.loads(await a.recv())
                        if event.get("method") == "turn/completed":
                            break
                # Delivery alone does not subscribe a second client to replies.
                await rpc(b, 2, "thread/resume", {"threadId": thread})
                turns = []
                for ws, number, token in ((a, 3, "RELAY_SHARED_A"), (b, 3, "RELAY_SHARED_B")):
                    result = await rpc(ws, number, "turn/start", {
                        "threadId": thread, "input": [],
                        "toolOutput": {"name": "relay_peer", "output": token},
                    })
                    turns.append(result["turn"]["id"])
                assert turns[0] == turns[1], "message did not join active turn"

                async def collect(ws):
                    text = []
                    async with asyncio.timeout(60):
                        async for raw in ws:
                            event = json.loads(raw)
                            if event.get("method") == "item/completed":
                                item = event["params"]["item"]
                                if item.get("type") == "agentMessage":
                                    text.append(item["text"])
                            if event.get("method") == "turn/completed":
                                assert event["params"]["turn"]["status"] == "completed"
                                return "\n".join(text)
                    raise RuntimeError("stream closed")
                results = await asyncio.gather(collect(a), collect(b))
                for index, text in enumerate(results):
                    assert all(token in text for token in ("RELAY_SHARED_A", "RELAY_SHARED_B")), text
                    print(f"PASS client {index}: both reply tokens; completed notification")
        finally:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


if __name__ == "__main__":
    asyncio.run(main())
