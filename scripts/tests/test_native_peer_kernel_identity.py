import importlib.util
from pathlib import Path
import struct
import unittest
from types import SimpleNamespace
from unittest.mock import Mock, patch

path = Path(__file__).resolve().parents[2] / 'Sources/Relay/Resources/Rotation/pane_messaging.py'
spec = importlib.util.spec_from_file_location('native_peer_messaging', path)
messaging = importlib.util.module_from_spec(spec)
spec.loader.exec_module(messaging)

class NativePeerKernelIdentityTests(unittest.TestCase):
    def test_linux_without_python_constant_keeps_kernel_pid_and_uid(self):
        client = Mock()
        client.getsockopt.return_value = struct.pack('3i', 123, messaging.UID, 42)
        with patch.object(messaging.sys, 'platform', 'linux'), patch.object(messaging, 'socket', SimpleNamespace(SOL_SOCKET=1)):
            self.assertEqual(messaging.native_peer_owner(client), (123, messaging.UID))
            client.getsockopt.assert_called_once_with(1, 17, 12)

    def test_linux_uses_exported_peercred_option_when_present(self):
        with patch.object(messaging.sys, 'platform', 'linux'), patch.object(messaging, 'socket', SimpleNamespace(SO_PEERCRED=17)):
            self.assertEqual(messaging.linux_peercred_option(), 17)

    def test_linux_numeric_fallback_never_applies_to_other_platforms(self):
        for platform in ['darwin', 'win32', 'freebsd']:
            with patch.object(messaging.sys, 'platform', platform):
                with self.assertRaises(ValueError): messaging.linux_peercred_option()

    def test_darwin_uses_kernel_pid_and_uid(self):
        client = Mock()
        client.getsockopt.side_effect = [struct.pack('II', 0, 501) + bytes(68), 123]
        with patch.object(messaging.sys, 'platform', 'darwin'):
            self.assertEqual(messaging.native_peer_owner(client), (123, 501))
        self.assertEqual(client.getsockopt.call_args_list[0].args, (0, 1, 76))
        self.assertEqual(client.getsockopt.call_args_list[1].args, (0, 2))

    def test_darwin_rejects_missing_or_invalid_credentials(self):
        for credentials, pid in [(b'', 123), (struct.pack('II', 1, 501), 123), (struct.pack('II', 0, 501), 0)]:
            client = Mock()
            client.getsockopt.side_effect = [credentials, pid]
            with patch.object(messaging.sys, 'platform', 'darwin'):
                with self.assertRaises(ValueError): messaging.native_peer_owner(client)

    def test_unsupported_platform_rejects(self):
        with patch.object(messaging.sys, 'platform', 'unsupported'):
            with self.assertRaises(ValueError): messaging.native_peer_owner(Mock())

    def test_authentication_checks_kernel_owner_and_rechecks_identity(self):
        endpoint = dict(transport='native_peer_socket', socketPID=123, socketStart='same', pid=99, socketPath='/private/socket', socketIdentity='inode')
        for owner in [(124, messaging.UID), (123, messaging.UID + 1)]:
            discovery = dict(identity=Mock(return_value='same'), ancestors=Mock(return_value=[123,99]), inventory=Mock(return_value={}))
            with patch.object(messaging, 'socket_identity', return_value='inode'), patch.object(messaging.socket, 'socket'), patch.object(messaging, 'native_peer_owner', return_value=owner):
                with self.assertRaisesRegex(ValueError, 'kernel owner mismatch'): messaging.authenticate_native_peer(discovery, endpoint)
        discovery = dict(identity=Mock(side_effect=['same','changed']), ancestors=Mock(return_value=[123,99]), inventory=Mock(return_value={}))
        with patch.object(messaging, 'socket_identity', return_value='inode'), patch.object(messaging.socket, 'socket'), patch.object(messaging, 'native_peer_owner', return_value=(123,messaging.UID)):
            with self.assertRaisesRegex(ValueError, 'changed during authentication'): messaging.authenticate_native_peer(discovery, endpoint)

if __name__ == '__main__': unittest.main()
