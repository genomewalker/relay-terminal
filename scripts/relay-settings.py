#!/usr/bin/env python3
"""Read and update the running Relay settings without UI automation."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import urllib.error
import urllib.request
import uuid


def request(method, payload=None, path="/api/settings"):
    headers = json.loads(subprocess.check_output([
        '/Applications/Relay.app/Contents/MacOS/relay-mcp', '--use-relay-token', '--print-http-headers'], text=True, timeout=10))
    headers = {'X-Relay-Token': headers['Authorization'].removeprefix('Bearer '), 'Content-Type': 'application/json'}
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request('http://127.0.0.1:47471' + path, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=15) as response:
            return json.loads(response.read(65537))
    except urllib.error.HTTPError as error:
        raise RuntimeError('Relay rejected the settings request: ' + error.read(4096).decode(errors='replace')) from None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='action', required=True)
    get = sub.add_parser('get'); get.add_argument('key', nargs='?')
    sub.add_parser('schema')
    sub.add_parser('ai-status')
    sub.add_parser('ai-check')
    set_cmd = sub.add_parser('set'); set_cmd.add_argument('key'); set_cmd.add_argument('value')
    update = sub.add_parser('update'); update.add_argument('--file', required=True, type=Path)
    for cmd in (set_cmd, update):
        cmd.add_argument('--request-id', default=None)
        cmd.add_argument('--expected-revision', default=None)
    args = parser.parse_args()
    if args.action in ('ai-status', 'ai-check'):
        result = request('POST' if args.action == 'ai-check' else 'GET', path='/api/intelligence/check' if args.action == 'ai-check' else '/api/intelligence/status')
        print(json.dumps(result, indent=2, sort_keys=True)); return
    current = request('GET')
    if args.action == 'schema':
        result = current['definitions']
    elif args.action == 'get':
        result = current['values'][args.key] if args.key else current
    else:
        if args.action == 'set':
            try: value = json.loads(args.value)
            except json.JSONDecodeError: value = args.value
            changes = {args.key: value}
        else:
            if args.file.stat().st_size > 32768:
                raise ValueError('Settings update file exceeds 32 KiB')
            changes = json.loads(args.file.read_text())
        request_id = args.request_id or str(uuid.uuid4())
        # Print the stable ID before dispatch so an ambiguous result can be
        # inspected/repeated with the same ID; never automatically retry a write.
        print('Settings request:', request_id, file=sys.stderr)
        print('Expected revision:', args.expected_revision or current['revision'], file=sys.stderr)
        result = request('POST', dict(instance=current['instance'], request_id=request_id,
            expected_revision=args.expected_revision or current['revision'], changes=changes))
    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == '__main__':
    try: main()
    except (KeyError, ValueError, RuntimeError, OSError) as error:
        print(str(error), file=sys.stderr); sys.exit(1)
