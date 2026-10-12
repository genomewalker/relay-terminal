#!/usr/bin/env python3
"""Package canonical provider adapters into relayd's offline runtime."""
from pathlib import Path

root = Path(__file__).resolve().parent.parent
source = root / 'Sources/Relay/Resources/Rotation'
target = root / 'remote/relayd/internal/daemon/communication_runtime'
target.mkdir(parents=True, exist_ok=True)
for name in ('agent_conversation.py', 'pane_messaging.py'):
    data = (source / name).read_bytes()
    path = target / name
    if not path.exists() or path.read_bytes() != data:
        path.write_bytes(data)
