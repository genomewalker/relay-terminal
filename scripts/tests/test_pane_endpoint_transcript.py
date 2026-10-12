import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('pane_messaging', ROOT / 'Sources/Relay/Resources/Rotation/pane_messaging.py')
messaging = importlib.util.module_from_spec(spec)
spec.loader.exec_module(messaging)


class EndpointTranscriptGuards(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.path = Path(self.temporary.name) / 'transcript.jsonl'
        self.path.write_text('fixture')
        self.path.chmod(0o600)
        self.binding = {'session_id': 'first', 'transcript_path': str(self.path)}
        self.discovery = {
            'root_for_pane': lambda pane: 11,
            'identity': lambda pid: str(pid),
            'agent': lambda root: (22, 'claude'),
            'authenticated_binding': Mock(return_value=self.binding),
            'metadata': Mock(return_value='first'),
            'recheck_transcript': Mock(),
        }

    def discover(self, peers=None):
        with patch.object(messaging, 'peer_records', peers or Mock(return_value=[])):
            return messaging.discover(self.discovery, 'pane', 11, 'daemon')

    def test_stable_transcript_pins_identity(self):
        endpoint = self.discover()
        info = self.path.stat()
        self.assertEqual(endpoint['transcriptIdentity'], '{}:{}'.format(info.st_dev, info.st_ino))
        self.discovery['recheck_transcript'].assert_called_once()
        self.assertEqual(self.discovery['authenticated_binding'].call_count, 2)

    def test_wrong_session_rejected_before_discovery(self):
        self.discovery['metadata'].return_value = 'second'
        with self.assertRaisesRegex(ValueError, 'does not identify'):
            self.discover()

    def test_replaced_transcript_rejected(self):
        def replace(*unused):
            replacement = self.path.with_suffix('.new')
            replacement.write_text('replacement')
            replacement.chmod(0o600)
            replacement.replace(self.path)
            return []
        with self.assertRaisesRegex(ValueError, 'incarnation changed'):
            self.discover(Mock(side_effect=replace))

    def test_binding_revision_changed_rejected(self):
        self.discovery['authenticated_binding'].side_effect = [self.binding, dict(self.binding, revision='changed')]
        with self.assertRaisesRegex(ValueError, 'binding changed'):
            self.discover()

    def test_final_metadata_guard_is_used(self):
        self.discovery['recheck_transcript'].side_effect = ValueError('session changed during read')
        with self.assertRaisesRegex(ValueError, 'session changed during read'):
            self.discover()


if __name__ == '__main__':
    unittest.main()
