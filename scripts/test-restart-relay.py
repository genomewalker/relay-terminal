import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('restart', Path(__file__).with_name('restart-relay.py'))
restart = importlib.util.module_from_spec(spec)
spec.loader.exec_module(restart)

class RestartTests(unittest.TestCase):
    def test_process_selection_excludes_workers(self):
        rows = ' 1 /Applications/Relay.app/Contents/MacOS/Relay\n 2 /Applications/Relay.app/Contents/MacOS/relayd\n 3 /tmp/Other.app/Contents/MacOS/Relay\n'
        with patch.object(restart.subprocess, 'check_output', return_value=rows):
            self.assertEqual(restart.app_pids(Path('/Applications/Relay.app')), [1])

    def test_no_running_app_does_not_launch_it_to_quit(self):
        with patch.object(restart, 'app_pids', return_value=[]), patch.object(restart.subprocess, 'run') as run:
            restart.quit_app(Path('/Applications/Relay.app'), 1)
            run.assert_not_called()

if __name__ == '__main__':
    unittest.main()
