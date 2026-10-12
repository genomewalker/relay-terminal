import copy
import importlib.util
import json
from pathlib import Path
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[2]
def module(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / ("Sources/Relay/Resources/Rotation/" + name + ".py"))
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result

reader = module("agent_conversation")
messaging = module("pane_messaging")

def binding():
    return {"version": 1, "source": "stock_app_server_proxy", "session_id": "chosen",
        "transcript_path": "", "revision": "a" * 64,
        "producer": {"pane_id": "pane", "provider": "codex", "process_id": 22, "process_start": 7},
        "stock_proxy": {"proxy_pid": 31, "proxy_start": 9, "control_socket": "/binding.sock",
            "control_device": 1, "control_inode": 2, "connection": 1, "selection": 3},
        "native_endpoint": {"socket": "/backend.sock", "daemon_pid": 44, "daemon_start": 12}}

class StockProxyTests(unittest.TestCase):
    def test_proxy_proof_requires_live_kernel_fields(self):
        value = binding()
        self.assertEqual(reader.stock_proxy_identity(value), "stock-proxy:" + "a" * 64)
        for field in ("proxy_pid", "proxy_start", "control_inode", "connection", "selection"):
            broken = copy.deepcopy(value)
            broken["stock_proxy"][field] = 0
            with self.assertRaises(reader.Unbound):
                reader.stock_proxy_identity(broken)
        self.assertIsNone(reader.stock_proxy_identity({"source": "historical_cache"}))

    def test_binding_only_can_identify_unwritten_stock_thread(self):
        value = binding()
        with patch.object(reader, "identity", return_value="same"), patch.object(reader, "agent", return_value=(22, "codex")), \
             patch.object(reader, "inventory", return_value={}), patch.object(reader, "ancestors", return_value=[11]), \
             patch.object(reader, "authenticated_binding", return_value=value), \
             patch.object(reader, "run", return_value=json.dumps({"process_start": 7})), \
             patch.object(reader, "transcript", side_effect=AssertionError("must not guess history")):
            result = reader.binding_only("pane", 11, "reader")
        self.assertEqual(result["binding"]["session_id"], "chosen")
        self.assertEqual(result["binding"]["source_identity"], "stock-proxy:" + "a" * 64)

    def test_binding_only_rejects_proxy_revision_change(self):
        first = binding(); second = binding(); second["revision"] = "b" * 64
        with patch.object(reader, "identity", return_value="same"), patch.object(reader, "agent", return_value=(22, "codex")), \
             patch.object(reader, "inventory", return_value={}), patch.object(reader, "ancestors", return_value=[11]), \
             patch.object(reader, "authenticated_binding", side_effect=[first, second]), \
             patch.object(reader, "run", return_value=json.dumps({"process_start": 7})):
            with self.assertRaisesRegex(reader.Unbound, "binding changed"):
                reader.binding_only("pane", 11, "reader")

    def test_unwritten_proxy_does_not_fabricate_history(self):
        with patch.object(reader, "identity", return_value="same"), patch.object(reader, "agent", return_value=(22, "codex")), \
             patch.object(reader, "authenticated_binding", return_value=binding()), \
             patch.object(reader, "transcript", side_effect=reader.Unbound("No real history")):
            with self.assertRaisesRegex(reader.Unbound, "No real history"):
                reader.snapshot("pane", 11, "reader")

    def test_discovery_uses_confirmed_stock_backend_without_transcript(self):
        value = binding()
        discovery = {"identity": lambda pid: "same", "agent": lambda root: (22, "codex"),
            "authenticated_binding": lambda *args: value, "stock_proxy_identity": reader.stock_proxy_identity}
        client = Mock()
        client.rpc.side_effect = [{"data": ["chosen"]}, {"thread": {"id": "chosen", "path": "/not-written"}}]
        with patch.object(messaging, "peer_records", return_value=[]), patch.object(messaging, "socket_identity", return_value="fixture"), \
             patch.object(messaging, "UnixWebSocket", return_value=client):
            result = messaging.discover(discovery, "pane", 11, "reader")
        self.assertEqual(result["transport"], "codex_app_server_message")
        self.assertEqual(result["socketPID"], 44)
        self.assertEqual(result["transcriptIdentity"], "")
        self.assertEqual([c.args[0] for c in client.rpc.call_args_list], ["thread/loaded/list", "thread/read"])

    def test_discovery_rejects_proxy_without_proof(self):
        value = binding(); value.pop("stock_proxy")
        discovery = {"identity": lambda pid: "same", "agent": lambda root: (22, "codex"),
            "authenticated_binding": lambda *args: value, "stock_proxy_identity": reader.stock_proxy_identity}
        with patch.object(messaging, "peer_records", return_value=[]):
            with self.assertRaises(reader.Unbound):
                messaging.discover(discovery, "pane", 11, "reader")

if __name__ == "__main__":
    unittest.main()
