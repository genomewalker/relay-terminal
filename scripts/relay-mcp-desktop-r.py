#!/usr/bin/python3
"""Linux host entrypoint for the existing scoped Relay desktop MCP adapter.

Use an explicit interpreter: agent/project PATH can select a Conda Python
whose shared libraries are unavailable in the MCP launch environment. The
per-client wrapper supplies RELAY_MCP_CALLER_TOKEN; this entrypoint preserves it.
"""
import json
import os
from pathlib import Path

config = json.loads((Path.home() / '.relay-mcp-desktop.json').read_text())
os.environ['RELAY_MCP_TOKEN'] = config['token']
os.environ['RELAY_MCP_PORT'] = str(config['port'])
helper = str(Path.home() / '.local/bin/relay-mcp')
os.execv(helper, ['relay-mcp'])
