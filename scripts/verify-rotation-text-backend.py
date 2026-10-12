#!/usr/bin/env python3
"""Offline checks for capsule text security/recovery. Never calls a provider."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import sqlite3
import selectors
import signal
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SOURCE = Path(os.environ.get("RELAY_TEXT_TEST_SOURCE", ROOT / "Sources/Relay/Resources/Rotation/text_backend.py"))
spec = importlib.util.spec_from_file_location("rotation_text", SOURCE)
text = importlib.util.module_from_spec(spec)
spec.loader.exec_module(text)
SETTINGS = {"enabled": True, "providers": ["anthropic_api"], "daily_limit_microusd": 5_000_000,
            "monthly_limit_microusd": 10_000_000, "max_requests_per_day": 10}
DRAFT = {"summary": "Task state.", "decisions": [], "constraints": [], "pending_work": ["Finish."],
         "next_action": "Continue.", "uncertainties": []}


def request(number=1, evidence="User asked for a factual capsule."):
    return {"v": 1, "operation_id": f"{number:032x}", "evidence": evidence,
            "binding": {"session_id": "session-1", "client": "claude", "turn_seq": number}}


def success(req, provider="anthropic_api"):
    return {"v": 1, "operation_id": req["operation_id"], "status": "draft", "provider": provider,
            "model": text.API_MODEL, "binding": req["binding"], "draft": DRAFT,
            "source_sha256": hashlib.sha256(req["evidence"].encode()).hexdigest(),
            "usage": {"input_tokens": 1000, "output_tokens": 200}}


class TextSecurityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="relay-text-offline-")
        self.root = Path(self.temp.name) / "journal"
        self.calls = 0
        def execute(req):
            self.calls += 1
            # A separate connection observes the committed reservation.
            other = text.TextJournal(self.root, execute=lambda _: self.fail("unexpected call"))
            try:
                self.assertEqual(other.status(req["operation_id"])["status"], "pending")
                self.assertEqual(other.status()["charged_today_microusd"], text.API_RESERVATION_MICROUSD)
            finally:
                other.close()
            return success(req)
        self.journal = text.TextJournal(self.root, execute=execute)

    def tearDown(self):
        self.journal.close()
        self.temp.cleanup()

    def configure(self, **updates):
        return self.journal.configure("a"*32, {**SETTINGS, **updates})

    def assertCode(self, code, operation):
        with self.assertRaises(text.DraftError) as caught:
            operation()
        self.assertEqual(caught.exception.code, code)

    def test_disabled_and_no_secret_settings(self):
        self.assertCode("text_backend_disabled", lambda: self.journal.submit(request()))
        self.assertCode("invalid_settings", lambda: self.configure(api_key="do-not-store"))
        self.assertEqual(self.calls, 0)

    def test_durable_reservation_settlement_and_replay(self):
        self.configure()
        result = self.journal.submit(request())
        self.assertEqual(result["status"], "complete")
        self.assertEqual(result["charged_microusd"], 200)
        self.assertEqual(self.journal.submit(request()), result)
        self.assertEqual(self.calls, 1)
        self.assertCode("operation_identity_conflict",
                        lambda: self.journal.submit(request(evidence="Changed evidence")))
        duplicate = request()
        duplicate["operation_id"] = "b"*32
        self.assertCode("operation_identity_conflict", lambda: self.journal.submit(duplicate))

    def test_config_replay_never_reverts_later_setting(self):
        self.configure()
        self.journal.configure("b"*32, {**SETTINGS, "enabled": False})
        self.configure()
        self.assertFalse(self.journal.status()["settings"]["enabled"])
        self.assertCode("operation_identity_conflict", lambda: self.configure(max_requests_per_day=1))

    def test_configuration_receipt_tracks_current_saved_settings(self):
        self.assertEqual(self.journal.status()["configuration_id"], "")
        saved = self.configure()
        self.assertEqual(saved["configuration_id"], "a"*32)
        other = text.TextJournal(self.root)
        try:
            self.assertEqual(other.status()["configuration_id"], "a"*32)
            settings = {**SETTINGS, "enabled": False, "providers": ["codex_account", "claude_account"],
                        "codex_model": "fixture-model", "claude_path": "/owned/claude"}
            current = other.configure("b"*32, settings)
            self.assertEqual(current["configuration_id"], "b"*32)
            replay = self.configure()
            self.assertEqual(replay["configuration_id"], "b"*32)
            self.assertEqual(replay["settings"], settings)
            self.assertEqual(self.calls, 0)
        finally:
            other.close()

    def test_uncertain_blocks_then_abandon_keeps_charge(self):
        self.configure()
        self.journal.execute = lambda req: {"v": 1, "operation_id": req["operation_id"],
                                            "status": "failed", "code": "request_outcome_unknown"}
        result = self.journal.submit(request())
        self.assertEqual(result["status"], "uncertain")
        self.assertCode("reconciliation_required", lambda: self.journal.submit(request(2)))
        self.journal.abandon(request()["operation_id"])
        self.assertEqual(self.journal.submit(request())["status"], "abandoned")
        self.assertEqual(self.journal.status()["charged_today_microusd"], text.API_RESERVATION_MICROUSD)

    def test_limits_persist_across_connections(self):
        self.configure(max_requests_per_day=1)
        self.journal.submit(request())
        other = text.TextJournal(self.root, execute=lambda _: self.fail("limit bypass"))
        try:
            self.assertCode("spending_limit", lambda: other.submit(request(2)))
        finally:
            other.close()

    def test_spending_reservation_not_just_settled_amount(self):
        self.configure(daily_limit_microusd=1_000_000)
        self.journal.submit(request())
        self.assertCode("spending_limit", lambda: self.journal.submit(request(2)))
        self.assertEqual(self.calls, 1)

    def test_cross_connection_single_flight(self):
        self.configure()
        entered, release = threading.Event(), threading.Event()
        result, failures = [], []
        def worker():
            other = text.TextJournal(self.root, execute=lambda req: (
                entered.set(), release.wait(3), success(req))[-1])
            try:
                result.append(other.submit(request()))
            except BaseException as error:
                failures.append(error)
            finally:
                other.close()
        thread = threading.Thread(target=worker)
        thread.start()
        try:
            self.assertTrue(entered.wait(3))
            self.assertCode("reconciliation_required", lambda: self.journal.submit(request(2)))
        finally:
            release.set()
            thread.join(3)
        self.assertFalse(thread.is_alive())
        self.assertFalse(failures)
        self.assertEqual(result[0]["status"], "complete")

    def test_actual_process_exit_leaves_pending_without_replay(self):
        self.configure()
        code = """import importlib.util,json,os,sys
s=importlib.util.spec_from_file_location('text',sys.argv[1])
m=importlib.util.module_from_spec(s);s.loader.exec_module(m)
j=m.TextJournal(sys.argv[2],execute=lambda request: os._exit(23))
j.submit(json.loads(sys.argv[3]))
"""
        done = subprocess.run([sys.executable, "-I", "-S", "-c", code, str(SOURCE),
                               str(self.root), json.dumps(request())],
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10)
        self.assertEqual(done.returncode, 23)
        self.assertEqual(self.journal.status(request()["operation_id"])["status"], "pending")
        self.assertEqual(self.journal.submit(request())["status"], "pending")
        self.assertEqual(self.calls, 0)

    def test_private_files_and_no_evidence_persistence(self):
        self.configure()
        marker = "original transcript marker 987654321"
        self.journal.submit(request(evidence=marker))
        self.assertEqual((self.root.stat().st_mode & 0o777), 0o700)
        self.assertEqual(((self.root / "operations.sqlite3").stat().st_mode & 0o777), 0o600)
        self.assertNotIn(marker.encode(), (self.root / "operations.sqlite3").read_bytes())
        shared = Path(self.temp.name) / "shared"
        shared.mkdir(mode=0o755)
        self.assertCode("journal_permissions", lambda: text.TextJournal(shared))
        linked = Path(self.temp.name) / "linked"
        linked.mkdir(mode=0o700)
        (linked / "operations.sqlite3").symlink_to(self.root / "operations.sqlite3")
        self.assertCode("journal_permissions", lambda: text.TextJournal(linked))

    def test_config_injection_and_invalid_input(self):
        self.configure()
        bad = request()
        bad["config"] = {"claude_path": "/untrusted/executable"}
        self.assertCode("invalid_request", lambda: self.journal.submit(bad))
        bad = request(evidence="x"*(text.MAX_SOURCE + 1))
        self.assertCode("invalid_evidence", lambda: self.journal.submit(bad))
        self.assertEqual(self.calls, 0)

    def test_redaction_and_no_fallback_after_submission(self):
        secret = "sk-ant-test-abcdefghijklmnopqrstuvwxyz"
        source = f"api_key={secret} password=verysecretvalue Keep the goal."
        with patch.dict(os.environ, {"ANTHROPIC_API_KEY": secret}, clear=True):
            clean, count = text.redact_evidence(source)
            self.assertNotIn(secret, clean)
            self.assertNotIn("verysecretvalue", clean)
            self.assertIn("Keep the goal.", clean)
            self.assertGreaterEqual(count, 2)
            with patch.object(text, "api_post", side_effect=text.DraftError("api_http_429")), \
                    patch.object(text, "account", side_effect=AssertionError("fallback after submission")):
                result = text.draft({**request(evidence=source), "config": {
                    "providers": ["anthropic_api", "claude_account"]}})
        self.assertEqual(result["code"], "api_http_429")
        self.assertNotIn(secret, json.dumps(result))

    def test_account_environment_and_flags(self):
        captured = []
        def cli(argv, prompt, cwd, timeout, environment):
            captured.append((argv, prompt, cwd, environment))
            return json.dumps({"subtype": "success", "is_error": False,
                               "structured_output": DRAFT}).encode()
        with patch.dict(os.environ, {"ANTHROPIC_API_KEY": "secret-api-value",
                                     "OPENAI_API_KEY": "other-api-value"}, clear=False), \
                patch.object(text, "cli_path", return_value="/owned/claude"), \
                patch.object(text, "run_cli", side_effect=cli):
            text.account("claude_account", "public evidence", {})
        argv, _, _, env = captured[0]
        self.assertIn("--safe-mode", argv)
        self.assertIn("--no-session-persistence", argv)
        self.assertEqual(argv[argv.index("--tools") + 1], "")
        self.assertNotIn("ANTHROPIC_API_KEY", env)
        self.assertNotIn("OPENAI_API_KEY", env)

    def test_redirect_and_bad_response_are_not_followed_or_echoed(self):
        class Response:
            status = 302
            def read1(self, _):
                raise AssertionError("must not read redirect body")
        class Connection:
            def __init__(self, host, port, **kwargs):
                self.sock = None
                self.host, self.port = host, port
            def connect(self): pass
            def request(self, method, path, **kwargs):
                self.sent = (method, path)
            def getresponse(self): return Response()
            def close(self): pass
        with patch.object(text.http.client, "HTTPSConnection", Connection):
            self.assertCode("api_http_302", lambda: text.api_post(b"{}", "never-log-this-key"))


    def test_sigterm_reaps_started_cli_and_preserves_uncertain_operation(self):
        ready = Path(self.temp.name) / "ready"
        os.mkfifo(ready, 0o600)
        executable = Path(self.temp.name) / "model"
        executable.write_text("#!" + sys.executable + "\n" +
            "import os,sys,json,signal\n" +
            "sys.stdin.read()\n" +
            "blocked = signal.SIGTERM in signal.pthread_sigmask(signal.SIG_BLOCK, [])\n" +
            "with open(" + repr(str(ready)) + ", 'w') as f: "
            "f.write(json.dumps({'pid':os.getpid(),'term_blocked':blocked})+'\\n'); f.flush()\n" +
            "signal.pause()\n")
        executable.chmod(0o700)
        settings = dict(SETTINGS, providers=["codex_account"], codex_model="fixture",
                        codex_path=str(executable))
        journal = text.TextJournal(self.root)
        journal.configure("a" * 32, settings)
        journal.close()
        environment = {k: os.environ[k] for k in ("HOME", "PATH", "LANG", "LC_ALL") if k in os.environ}
        command = None
        child = None
        fd = os.open(ready, os.O_RDONLY | os.O_NONBLOCK)
        try:
            command = subprocess.Popen([sys.executable, "-I", "-S", str(SOURCE),
                "--state-dir", str(self.root), "--operation", "submit"],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                env=environment)
            command.stdin.write(json.dumps(request()).encode())
            command.stdin.close()
            command.stdin = None
            with selectors.DefaultSelector() as selector:
                selector.register(fd, selectors.EVENT_READ)
                self.assertTrue(selector.select(15), "fixture CLI never started")
                record = json.loads(os.read(fd, 4096))
            child = record["pid"]
            self.assertFalse(record["term_blocked"], "CLI inherited blocked cancellation")
            command.terminate()
            output, diagnostics = command.communicate(timeout=10)
            self.assertEqual(command.returncode, 0, diagnostics.decode())
            result = json.loads(output)
            self.assertEqual(result["status"], "uncertain")
            self.assertEqual(result["result"]["code"], "request_outcome_unknown")
            with self.assertRaises(ProcessLookupError):
                os.kill(child, 0)
            def no_replay(_):
                self.fail("cancelled operation invoked the model again")
            journal = text.TextJournal(self.root, execute=no_replay)
            try:
                self.assertEqual(journal.submit(request()), result)
                self.assertEqual(journal.status()["requests_today"], 1)
                self.assertCode("reconciliation_required", lambda: journal.submit(request(2)))
            finally:
                journal.close()
        finally:
            os.close(fd)
            if command is not None and command.poll() is None:
                command.kill()
                command.wait(timeout=5)
            if child is not None:
                try:
                    os.kill(child, signal.SIGKILL)
                except ProcessLookupError:
                    pass

    def test_cancellation_during_cli_start_reaps_acquired_child(self):
        original = text.subprocess.Popen
        started = []
        previous = signal.getsignal(signal.SIGTERM)
        def start(*args, **kwargs):
            process = original(*args, **kwargs)
            started.append(process)
            text._cancel_request(signal.SIGTERM, None)
            return process
        try:
            with patch.object(text.subprocess, "Popen", start):
                self.assertCode("request_outcome_unknown", lambda: text.run_cli(
                    [sys.executable, "-c", "import signal; signal.pause()"],
                    b"fixture", self.temp.name, 10, {}))
            self.assertEqual(len(started), 1)
            self.assertIsNotNone(started[0].returncode)
            self.assertFalse(text._cli_starting)
        finally:
            signal.signal(signal.SIGTERM, previous)
            text._cancel_pending = False
            for process in started:
                if process.poll() is None:
                    process.kill()
                    process.wait(timeout=5)

    def test_source_and_embedded_security_policy_match(self):
        embedded = ROOT / "remote/relayd/internal/daemon/host_rotation_text.py"
        if embedded.exists():
            self.assertEqual(SOURCE.read_bytes(), embedded.read_bytes())


if __name__ == "__main__":
    unittest.main(verbosity=2)
