
import ast
import hmac
import http.server
import io
import json
from pathlib import Path
import re
import threading
import types
import unittest

SOURCE = Path(__file__).resolve().parents[1] / "relay-remote-mcp-bridge.py"
tree = ast.parse(SOURCE.read_text())
handler_node = next(n for n in tree.body if isinstance(n, ast.ClassDef) and n.name == "Handler")

class BridgeRoutesTests(unittest.TestCase):
    source = "5a30d83a-5222-48f3-93c7-42fa687d901b"
    target = "1652a003-70e9-4614-addb-68564fa8383b"
    foreign = "9ef1b226-5993-48ff-8f6a-2a93f3c7ce3b"

    def request(self, method, pane, operation, payload=None, token="fixture"):
        forwarded = []
        def desktop(method, path, body=None, caller=None):
            forwarded.append((method, path, body, caller))
            return 200, b'{"status":"fixture_only"}'
        scope = {self.source, self.target}
        namespace = dict(hmac=hmac, http=http, json=json, re=re, lock=threading.Lock(),
            receipts=set(), cap="fixture", args=types.SimpleNamespace(host="dandy-07"),
            state=lambda caller: ({}, scope, {}),
            desktop=desktop, saved_pair=lambda *args: False,
            DesktopRejected=type("DesktopRejected", (Exception,), {}))
        exec(compile(ast.Module(body=[handler_node], type_ignores=[]), str(SOURCE), "exec"), namespace)
        handler = object.__new__(namespace["Handler"])
        raw = json.dumps(payload).encode() if payload is not None else b""
        handler.command = method
        handler.path = "/api/panes/" + pane + "/" + operation
        handler.headers = {"x-relay-token": token, "X-Relay-Caller-Token": "fixture_client",
                           "Content-Length": str(len(raw))}
        handler.rfile = io.BytesIO(raw)
        responses = []
        handler.reply = lambda status, body: responses.append((status, body))
        handler.handle_request()
        self.assertEqual(len(responses), 1)
        return responses[0][0], forwarded, namespace["receipts"]

    def direct(self):
        return dict(instance="12345678-1234-1234-1234-123456789abc",
                    requestID="aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", text="fixture")

    def test_agent_binding_uses_existing_host_scope(self):
        status, forwarded, _ = self.request("GET", self.target, "agent-binding")
        self.assertEqual(status, 200)
        self.assertEqual(forwarded[0][0:2], ("GET", "/api/panes/" + self.target + "/agent-binding"))

    def test_agent_binding_foreign_host_stays_refused(self):
        status, forwarded, _ = self.request("GET", self.foreign, "agent-binding")
        self.assertEqual(status, 403)
        self.assertEqual(forwarded, [])

    def test_direct_input_is_forwarded_once_and_receipt_is_scoped(self):
        status, forwarded, receipts = self.request("POST", self.target, "input-direct", self.direct())
        self.assertEqual(status, 200)
        self.assertEqual(len(forwarded), 1)
        self.assertEqual(json.loads(forwarded[0][2]), self.direct())
        self.assertEqual(receipts, {self.direct()["requestID"]})

    def test_direct_input_foreign_host_stays_refused(self):
        status, forwarded, _ = self.request("POST", self.foreign, "input-direct", self.direct())
        self.assertEqual(status, 403)
        self.assertEqual(forwarded, [])

    def test_direct_input_rejects_invalid_request_identity(self):
        request = self.direct()
        request["requestID"] = "invalid"
        status, forwarded, _ = self.request("POST", self.target, "input-direct", request)
        self.assertEqual(status, 400)
        self.assertEqual(forwarded, [])

    def test_direct_input_keeps_body_limit(self):
        request = self.direct()
        request["text"] = "x" * 70001
        status, forwarded, _ = self.request("POST", self.target, "input-direct", request)
        self.assertEqual(status, 413)
        self.assertEqual(forwarded, [])

    def test_direct_input_is_post_only(self):
        status, forwarded, _ = self.request("GET", self.target, "input-direct")
        self.assertEqual(status, 403)
        self.assertEqual(forwarded, [])

    def test_binding_read_does_not_allow_writes(self):
        status, forwarded, _ = self.request("POST", self.target, "agent-binding", self.direct())
        self.assertEqual(status, 403)
        self.assertEqual(forwarded, [])

    def test_legacy_input_request_remains_available(self):
        status, forwarded, _ = self.request("POST", self.target, "input-request", self.direct())
        self.assertEqual(status, 200)
        self.assertEqual(len(forwarded), 1)

    def test_bridge_credential_still_required(self):
        status, forwarded, _ = self.request("GET", self.target, "agent-binding", token="wrong")
        self.assertEqual(status, 401)
        self.assertEqual(forwarded, [])

if __name__ == "__main__":
    unittest.main()
