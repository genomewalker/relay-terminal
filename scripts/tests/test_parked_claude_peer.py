import importlib.util
import json
import os
from pathlib import Path
import re
import socket
import tempfile
import unittest
from unittest.mock import Mock, patch

path = Path(__file__).resolve().parents[2] / 'Sources/Relay/Resources/Rotation/pane_messaging.py'
spec = importlib.util.spec_from_file_location('parked_peer_messaging', path)
messaging = importlib.util.module_from_spec(spec)
spec.loader.exec_module(messaging)

class ParkedClaudePeerTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.home = Path(self.directory.name)
        self.registry = self.home / '.claude/sessions'
        self.registry.mkdir(parents=True, mode=0o700)
        self.pid = os.getpid()
        self.socket_path = self.home / 'peer.sock'
        self.server = socket.socket(socket.AF_UNIX)
        self.server.bind(str(self.socket_path))
        self.server.listen(32)
        os.chmod(self.socket_path, 0o600)
        self.row = dict(pid=self.pid, procStart='fixture-current', kind='bg', entrypoint='cli',
                        peerProtocol=1, jobId='5577ee9d', sessionId='5577ee9d-5e02-4ca8-b208-74360e3f65d1',
                        messagingSocketPath=str(self.socket_path))
        self.record = self.registry / (str(self.pid)+'.json')
        self.write_row()
        self.peer = dict(pid=self.pid, process_start='fixture-current', job_id='5577ee9d',
                         frontend_session='009f406d-c23a-483c-b212-3f4e7461be26',
                         socket=str(self.socket_path), socket_identity=messaging.socket_identity(str(self.socket_path)))
        self.verified = dict(source='native_parked_job_kernel_owner', native_peer=self.peer,
                             session_id=self.row['sessionId'])
        self.discovery = dict(UUID=re.compile(r'^[a-fA-F0-9-]{36}$'), identity=Mock(return_value='fixture:fixture-current'))
        self.home_patch = patch.object(messaging, 'HOME', self.home)
        self.home_patch.start()

    def tearDown(self):
        self.home_patch.stop()
        self.server.close()
        self.directory.cleanup()

    def write_row(self):
        self.record.write_text(json.dumps(self.row))
        os.chmod(self.record, 0o600)

    def test_parked_inbox_uses_published_job_and_real_kernel_owner(self):
        row, start, identity = messaging.parked_claude_peer(self.discovery, self.verified)
        self.assertEqual(row['pid'], self.pid)
        self.assertEqual(start, 'fixture:fixture-current')
        self.assertEqual(identity, self.peer['socket_identity'])

    def test_parked_inbox_rejects_wrong_session_job_kind_and_incarnation(self):
        for key, value in [('jobId', 'aaaaaaaa'), ('sessionId', 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'),
                           ('kind', 'interactive'), ('procStart', 'stale')]:
            with self.subTest(key=key):
                old = self.row[key]; self.row[key] = value; self.write_row()
                with self.assertRaisesRegex(ValueError, 'publication changed'):
                    messaging.parked_claude_peer(self.discovery, self.verified)
                self.row[key] = old; self.write_row()

    def test_parked_inbox_rejects_foreign_kernel_owner(self):
        with patch.object(messaging, 'native_peer_owner', return_value=(self.pid+1, messaging.UID)):
            with self.assertRaisesRegex(ValueError, 'kernel owner mismatch'):
                messaging.parked_claude_peer(self.discovery, self.verified)

    def test_parked_frontend_never_falls_back_to_dormant_inbox(self):
        self.row['parkedJobId'] = '5577ee9d'; self.write_row()
        discovery = dict(root_for_pane=Mock(return_value=42), identity=Mock(return_value='fixture:current'),
                         agent=Mock(return_value=(self.pid, 'claude')), authenticated_binding=Mock(return_value=None))
        with patch.object(messaging, 'peer_records', side_effect=AssertionError('dormant inbox fallback')):
            with self.assertRaisesRegex(ValueError, 'no verified background attachment'):
                messaging.discover(discovery, '800c06ef-203f-4401-bf7a-c67b15985f33', 42, 'helper')

    def test_native_attachment_authenticates_background_outside_bootstrap_ancestry(self):
        frontend = self.pid+10000000
        front_path = self.registry / (str(frontend)+'.json')
        front = dict(pid=frontend, kind='interactive', entrypoint='cli',
                     parkedJobId='5577ee9d', sessionId=self.peer['frontend_session'], procStart='front-current')
        front_path.write_text(json.dumps(front)); os.chmod(front_path, 0o600)
        self.discovery.update(ancestors=Mock(return_value=[self.pid, 123]), inventory=Mock(return_value={}))
        endpoint = dict(transport='native_peer_socket', pid=frontend, start='fixture:front-current',
                        socketPID=self.pid, socketStart='fixture:fixture-current',
                        socketPath=str(self.socket_path), socketIdentity=self.peer['socket_identity'],
                        provider='claude', sessionID=self.row['sessionId'],
                        bindingSource='native_parked_job_kernel_owner', nativePeer=self.peer)
        self.assertTrue(messaging.authenticate_native_peer(self.discovery, endpoint))
        front['parkedJobId'] = 'aaaaaaaa'; front_path.write_text(json.dumps(front))
        with self.assertRaisesRegex(ValueError, 'foreground publication changed'):
            messaging.authenticate_native_peer(self.discovery, endpoint)

if __name__ == '__main__':
    unittest.main()
