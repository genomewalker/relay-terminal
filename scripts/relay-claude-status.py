#!/usr/bin/python3
"""Keep legacy Relay status capture and display the shared Claude footer."""
import os
from pathlib import Path
import subprocess
import sys

raw = sys.stdin.buffer.read(65537)
if len(raw) > 65536:
    sys.exit('Claude status input exceeds bound')
home = Path.home()
pane = os.environ.get('RELAY_SESSION', '')
if pane:
    try:
        subprocess.run([str(home / '.local/bin/relayd'), 'claude-status-capture', '--pane', pane],
                       input=raw, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=4)
    except (OSError, subprocess.TimeoutExpired):
        pass
try:
    result = subprocess.run(['bash', str(home / '.config/relay/cc-status.sh')], input=raw, timeout=8)
    sys.exit(result.returncode)
except (OSError, subprocess.TimeoutExpired):
    sys.exit('Claude status renderer unavailable')
