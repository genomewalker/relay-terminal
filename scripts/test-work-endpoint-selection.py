
import asyncio
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import AsyncMock, patch

ROOT = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("route", ROOT / "relay-desktop-route.py")
route = importlib.util.module_from_spec(spec)
spec.loader.exec_module(route)
ingress = route.ingress

def ref(thread="selected", pid=42):
    return dict(schema=1, thread=thread, hostId="local", socket=str(ingress.WORK_SOCKET),
                appPath=ingress.WORK_APP, appPID=pid, appStart="Mon Oct 12 06:35:52 2026",
                ownerClientId="12345678-1234-1234-1234-123456789abc")

class SelectionTests(unittest.TestCase):
    def test_inspect_exact_work_task_is_read_only(self):
        selected = ref()
        with patch.object(ingress, "inspect_work_task", AsyncMock(return_value=selected)) as owner, \
             patch.object(ingress, "_commit_work_ref") as commit:
            result = asyncio.run(ingress.inspect_loaded_task(str(ingress.LEGACY_SOCKET), "selected"))
        owner.assert_awaited_once_with("selected")
        commit.assert_not_called()
        self.assertEqual(result["ref"], selected)

    def test_private_fixture_never_uses_global_work_socket(self):
        with patch.object(ingress, "inspect_work_task", AsyncMock()) as owner, \
             patch.object(ingress, "_loaded_app_server_tasks", AsyncMock(return_value=["selected"])) as legacy:
            result = asyncio.run(ingress.inspect_loaded_task("/tmp/private-fixture", "selected"))
        owner.assert_not_called()
        legacy.assert_awaited_once_with("/tmp/private-fixture")
        self.assertEqual(result["transport"], "app_server")

    def test_unavailable_exact_task_never_resumes_or_commits(self):
        with patch.object(ingress, "inspect_work_task", AsyncMock(side_effect=ValueError("unavailable"))), \
             patch.object(ingress, "_loaded_app_server_tasks", AsyncMock(return_value=["different"])), \
             patch.object(ingress, "_commit_work_ref") as commit:
            with self.assertRaises(ValueError):
                asyncio.run(ingress.inspect_loaded_task(str(ingress.LEGACY_SOCKET), "selected"))
        commit.assert_not_called()

    def test_prepare_captures_expected_selected_identity(self):
        before, after = ref(pid=1), ref(pid=2)
        with patch.object(ingress, "work_ref", return_value=before), \
             patch.object(ingress, "inspect_loaded_task", AsyncMock(return_value=dict(id="selected", transport="work_ipc", ref=after))), \
             patch.object(ingress, "_commit_work_ref") as commit:
            asyncio.run(ingress.prepare_loaded_task(str(ingress.LEGACY_SOCKET), "selected"))
        commit.assert_called_once_with(after, before)

    def test_commit_add_refresh_cas_preserves_other_tasks(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(ingress, "WORK_ROOT", Path(tmp)), \
             patch.object(ingress, "_work_process"):
            other, old, new = ref("other"), ref(pid=1), ref(pid=2)
            ingress._commit_work_ref(other, None)
            ingress._commit_work_ref(old, None)
            ingress._commit_work_ref(new, old)
            self.assertEqual(ingress._read_work_ref(Path(tmp)/"other.json"), other)
            self.assertEqual(ingress._read_work_ref(Path(tmp)/"selected.json"), new)
            with self.assertRaises(ValueError):
                ingress._commit_work_ref(old, old)
            self.assertEqual(ingress._read_work_ref(Path(tmp)/"selected.json"), new)
            self.assertEqual((Path(tmp)/"selected.json").stat().st_mode & 0o777, 0o600)

    def test_registry_cap_is_enforced_under_lock(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(ingress, "WORK_ROOT", Path(tmp)), \
             patch.object(ingress, "_work_process"):
            for i in range(16):
                ingress._commit_work_ref(ref("task"+str(i)), None)
            with self.assertRaises(ValueError):
                ingress._commit_work_ref(ref("seventeenth"), None)
            self.assertFalse((Path(tmp)/"seventeenth.json").exists())

    def test_commit_rechecks_app_incarnation_before_write(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(ingress, "WORK_ROOT", Path(tmp)), \
             patch.object(ingress, "_work_process", side_effect=ValueError("changed")):
            with self.assertRaises(ValueError):
                ingress._commit_work_ref(ref(), None)
            self.assertFalse((Path(tmp)/"selected.json").exists())

    def test_owner_pin_and_untrusted_input_support_remain_required(self):
        ipc = ingress.WorkIPC(ref())
        with patch.object(ipc, "request", AsyncMock(return_value=dict(
                handledByClientId="aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
                result=dict(supportsUntrustedAppInput=True)))):
            with self.assertRaises(ValueError):
                asyncio.run(ipc.owner())
        with patch.object(ipc, "request", AsyncMock(return_value=dict(
                handledByClientId=ref()["ownerClientId"], result=dict(supportsUntrustedAppInput=False)))):
            with self.assertRaises(ValueError):
                asyncio.run(ipc.owner(require_pin=False))

    def test_cli_preflight_and_uncertain_dispatch_have_one_distinct_response(self):
        for dispatched, receipt in ((False, "not_sent"), (True, "unknown")):
            async def fail(c, path, mode, delivery):
                delivery["dispatched"] = dispatched
                raise ValueError("private diagnostic")
            output = io.StringIO()
            with patch.object(sys, "argv", ["route", "send", "--config", "/tmp/private-fixture"]), \
                 patch.object(route, "read_private", return_value={}), \
                 patch.object(route, "run", side_effect=fail), contextlib.redirect_stdout(output):
                with self.assertRaises(SystemExit):
                    asyncio.run(route.main())
            value = json.loads(output.getvalue())
            self.assertEqual(value["receipt"], receipt)
            self.assertFalse(value["retrySafe"])
            self.assertNotIn("private diagnostic", output.getvalue())

if __name__ == "__main__":
    unittest.main()
