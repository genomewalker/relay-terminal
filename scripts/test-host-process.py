#!/usr/bin/env python3
"""Isolated recovery tests: no live host, service, agent, or mailbox mutations."""
import base64
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch

spec = importlib.util.spec_from_file_location('host_adapter', Path(__file__).with_name('relay-host-process.py'))
adapter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(adapter)

class AdapterTests(unittest.TestCase):
    def fixture(self, tmp, offset=0):
        with patch.object(adapter.Path, 'home', return_value=Path(tmp)):
            checkpoint = adapter.ListenerCheckpoint('host', ['listener'])
            checkpoint.state.update(purpose='peer_listener', stdout_offset=offset)
            checkpoint.save()
            path, job = checkpoint.path, checkpoint.job_id
            adapter.os.close(checkpoint.lock_fd)
            return path, job

    def test_running_listener_resumes_same_job_without_exec(self):
        with tempfile.TemporaryDirectory() as tmp:
            path, job = self.fixture(tmp, offset=50)
            ready = base64.b64encode(b'{"type":"ready","pid":9}\n').decode()
            transport = Mock(host='host')
            transport.request.side_effect = [
                {'job': {'state': 'running'}},
                {'job': {'state': 'running', 'pid': 9}, 'stdout': ready},
                KeyboardInterrupt()]
            with patch.object(adapter.Path, 'home', return_value=Path(tmp)), \
                 patch.object(adapter.signal, 'signal'), patch.object(adapter, 'emit') as emit:
                with self.assertRaises(KeyboardInterrupt):
                    adapter.listen(transport, ['listener'], True)
            self.assertEqual([c.args[1] for c in transport.request.call_args_list], ['status'] * 3)
            self.assertTrue(all(c.args[0] == job for c in transport.request.call_args_list))
            self.assertEqual(json.loads(path.read_text())['stdout_offset'], 50)
            emit.assert_called_once_with({'type': 'ready', 'pid': 9})

    def test_ambiguous_job_does_not_reexecute(self):
        with tempfile.TemporaryDirectory() as tmp:
            path, job = self.fixture(tmp)
            transport = Mock(host='host')
            transport.request.return_value = {'job': {'state': 'unknown_after_daemon_restart'}, 'process_state': 'unknown'}
            with patch.object(adapter.Path, 'home', return_value=Path(tmp)), patch.object(adapter.signal, 'signal'):
                with self.assertRaisesRegex(RuntimeError, 'no automatic replay'):
                    adapter.listen(transport, ['listener'], True)
            transport.request.assert_called_once_with(job, 'status')
            self.assertEqual(json.loads(path.read_text())['job_id'], job)

    def test_offset_advances_only_after_parent_ack(self):
        for acknowledged in (False, True):
            with self.subTest(acknowledged=acknowledged), tempfile.TemporaryDirectory() as tmp:
                path, job = self.fixture(tmp)
                frame = b'{"type":"message","id":"m1"}\n'
                transport = Mock(host='host')
                transport.request.side_effect = [
                    {'job': {'state': 'running'}},
                    {'job': {'state': 'running', 'pid': 9}, 'stdout': base64.b64encode(b'{"type":"ready","pid":9}\n').decode()},
                    {'job': {'state': 'running'}, 'stdout': base64.b64encode(frame).decode(), 'stdout_offset': len(frame), 'stderr_offset': 0},
                    KeyboardInterrupt()]
                with patch.object(adapter.Path, 'home', return_value=Path(tmp)), \
                     patch.object(adapter.signal, 'signal'), patch.object(adapter, 'emit'), \
                     patch.object(adapter, 'wait_parent_ack', side_effect=None if acknowledged else RuntimeError('detached')) as ack:
                    with self.assertRaises(KeyboardInterrupt if acknowledged else RuntimeError):
                        adapter.listen(transport, ['listener'], True)
                ack.assert_called_once_with(len(frame))
                self.assertEqual(json.loads(path.read_text())['stdout_offset'], len(frame) if acknowledged else 0)

if __name__ == '__main__':
    unittest.main()
