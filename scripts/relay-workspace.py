#!/usr/bin/env python3
"""Authenticated CLI for a captured Relay workspace. Never retries mutations."""
import argparse
import base64
import json
import os
from pathlib import Path
import subprocess
import sys
import urllib.request
import urllib.error
import uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    target = parser.add_mutually_exclusive_group(required=True)
    target.add_argument('--tab', help='Exact Relay tab UUID')
    target.add_argument('--pane', help='Exact Relay pane UUID; resolves its existing tab')
    target.add_argument('--host', help='Exact configured Relay host alias or This Mac')
    parser.add_argument('--directory', default='/', help='Absolute working directory with --host')
    parser.add_argument('operation', choices=['context', 'screen', 'request', 'exec', 'image'])
    parser.add_argument('arguments', nargs='*')
    args = parser.parse_args()
    helper = Path(os.environ.get('RELAY_MCP_BINARY', '/Applications/Relay.app/Contents/MacOS/relay-mcp'))
    headers = json.loads(subprocess.check_output([str(helper), '--use-relay-token', '--print-http-headers']))
    headers = {'X-Relay-Token': headers['Authorization'].removeprefix('Bearer '),
               'Content-Type': 'application/json',
               **({'X-Relay-Caller-Token': headers['X-Relay-Caller-Token']}
                  if headers.get('X-Relay-Caller-Token') else {})}
    if os.environ.get('RELAY_CALLER_TOKEN'):
        headers['X-Relay-Caller-Token'] = os.environ['RELAY_CALLER_TOKEN']

    def read_request(path, body=None):
        request = urllib.request.Request('http://127.0.0.1:47471' + path,
            data=json.dumps(body).encode() if body is not None else None, headers=headers)
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                data = response.read(8 * 1024 * 1024 + 1)
        except urllib.error.HTTPError as error:
            detail = error.read(4096).decode(errors='replace')
            raise RuntimeError('Relay HTTP %s: %s' % (error.code, detail)) from None
        if len(data) > 8 * 1024 * 1024:
            raise RuntimeError('Response exceeded CLI limit')
        answer = json.loads(data)
        if answer.get('error'):
            raise RuntimeError(answer['error'])
        return answer

    def post(path, body):
        return read_request(path, body)

    # Discover location once, without changing focus or injecting terminal input.
    # Tab and pane UUIDs have the same shape, so a pane passed as --tab used to
    # produce an opaque HTTP 400 despite referring to a real sibling terminal.
    pane = None
    if args.pane or args.tab:
        supplied = args.pane or args.tab
        try:
            identifier = str(uuid.UUID(supplied))
        except ValueError:
            parser.error('An exact pane or tab UUID is required')
        state = read_request('/api/state')
        tabs = [tab for session in state['sessions'] for tab in session['tabs']]
        matches = [(tab, item) for tab in tabs for item in tab['panes'] if item['id'].lower() == identifier]
        tab_matches = [tab for tab in tabs if tab['id'].lower() == identifier]
        if args.pane or not tab_matches:
            if len(matches) != 1:
                parser.error('Pane is absent or ambiguous in the current Relay workspace')
            tab, pane = matches[0]
            args.tab = tab['id']
        elif len(tab_matches) == 1:
            args.tab = tab_matches[0]['id']
            if args.operation == 'screen':
                parser.error('screen requires --pane; a tab can contain several terminals')
        else:
            parser.error('Tab is absent or ambiguous in the current Relay workspace')

    if args.operation == 'screen':
        if pane is None:
            parser.error('screen requires --pane with an existing terminal UUID')
        if args.arguments:
            parser.error('screen takes no additional arguments')
        answer = read_request('/api/panes/' + pane['id'] + '/viewport')
        answer.update(tab_id=args.tab, connection=pane['connection'], phase=pane['phase'])
        answer['untrusted_output'] = True
        if not answer.get('text'):
            answer['availability'] = 'empty_or_unmounted_viewport'
            answer['message'] = 'No rendered screen is available; this does not prove the worker is stuck. No input was sent.'
        print(json.dumps(answer))
        return 0

    if args.host:
        if not args.directory.startswith('/') or '\0' in args.directory:
            parser.error('--directory must be an absolute path')
        context = dict(host=args.host, directory=args.directory, binding='explicit_cli')
    else:
        context = post('/api/workspace/context', {'tab_id': args.tab})
    if args.operation == 'context':
        print(json.dumps(context))
        return 0

    def host_request(fields):
        fields = dict(fields, host=context['host'], cwd=context['directory'],
                      request_id='rpc-' + uuid.uuid4().hex)
        return post('/api/host/request', fields)['result']

    if args.operation == 'image':
        if not args.tab:
            parser.error('image requires --tab with a captured workspace context')
        if len(args.arguments) != 1:
            parser.error('image requires one path')
        # The native endpoint captures its own context once for the transfer.
        image = post('/api/workspace/image', {'tab_id': args.tab, 'path': args.arguments[0]})
        sys.stdout.buffer.write(base64.b64decode(image['data'], validate=True))
        return 0
    if args.operation == 'request':
        if len(args.arguments) > 1:
            parser.error('request takes one JSON object or reads stdin')
        raw = args.arguments[0] if args.arguments else sys.stdin.read(1048577)
        if len(raw.encode()) > 1048576:
            raise RuntimeError('Request too large')
        fields = json.loads(raw)
        if not isinstance(fields, dict):
            parser.error('request requires a JSON object')
        print(json.dumps(host_request(fields)))
        return 0
    if not args.arguments:
        parser.error('exec requires an executable and arguments')
    job_id = 'job-' + uuid.uuid4().hex
    # Print the durable ID before dispatch, including when the outcome is unknown.
    print(json.dumps(dict(job_id=job_id, **context)), file=sys.stderr, flush=True)
    started = host_request(dict(operation='exec', job_id=job_id, argv=args.arguments))
    if started['state'] not in ('running', 'exited'):
        raise RuntimeError('Execution was not admitted; inspect job ' + job_id)
    offsets = dict(stdout_offset=0, stderr_offset=0)
    while True:
        result = host_request(dict(operation='status', job_id=job_id, wait_millis=15000, **offsets))
        for name, stream in [('stdout', sys.stdout.buffer), ('stderr', sys.stderr.buffer)]:
            stream.write(base64.b64decode(result.get(name) or '', validate=True))
            stream.flush()
            offsets[name + '_offset'] = result[name + '_offset']
        state = result['job']['state']
        if state == 'unknown_after_daemon_restart':
            raise RuntimeError('Outcome unknown; inspect job ' + job_id + '; do not replay')
        if state in ('exited', 'failed') and not result.get('stdout') and not result.get('stderr'):
            return result['job'].get('exit_code', 1)


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception as error:
        print('Relay: ' + str(error), file=sys.stderr)
        sys.exit(1)
