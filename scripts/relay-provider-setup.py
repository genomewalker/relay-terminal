#!/usr/bin/env python3
"""One portable Relay provider setup for macOS and Linux (Python 3.6+)."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ASSETS = None  # Replaced with the same embedded assets for every target host.
VERSION = 1
FILES = {
    'relay-prompt.bash': 'prompt.bash',
    'relay-cc-status.sh': 'cc-status.sh',
    'relay-claude-status.py': 'claude-status.py',
}


def assets():
    if ASSETS is not None:
        return {k: base64.b64decode(v) for k, v in ASSETS.items()}
    root = Path(__file__).resolve().parent
    names = list(FILES) + ['install-relay-shell-ui.py', 'repair-chitta-failure-event.py']
    return {name: (root / name).read_bytes() for name in names}


def bundle(payload):
    source = Path(__file__).read_text()
    encoded = {k: base64.b64encode(v).decode() for k, v in payload.items()}
    lines = source.splitlines(True)
    indices = [i for i, line in enumerate(lines) if line.startswith('ASSETS = ')]
    if len(indices) != 1:
        raise RuntimeError('Expected one bundle asset declaration')
    lines[indices[0]] = 'ASSETS = ' + repr(encoded) + '\n'
    return ''.join(lines).encode()


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def audit(payload):
    home = Path.home()
    files = []
    for name, destination in FILES.items():
        p = home / '.config/relay' / destination
        raw = p.read_bytes() if p.is_file() else None
        files.append({'file': destination, 'managed': raw == payload[name],
                      'sha256': digest(raw) if raw is not None else None})
    p = home / '.claude/settings.json'
    config = json.loads(p.read_text()) if p.exists() else {}
    status = config.get('statusLine') or {}
    command = status.get('command', '')
    launcher = 'bash "$HOME/.config/relay/cc-status.sh"'
    # The quota wrapper is an optional host capability around the SAME renderer.
    wrapped = False
    if '--statusline ' in command:
        try:
            command = base64.b64decode(command.split('--statusline ', 1)[1].split()[0]).decode()
            wrapped = True
        except (ValueError, UnicodeError):
            command = ''
    root = home / '.claude/plugins/cache/genomewalker-chitta/chitta/5.73.1'
    adapter = root / 'chitta-mcp/hook_client.py'
    repaired = adapter.is_file() and 'specific["hookEventName"] = "PostToolUseFailure"' in adapter.read_text()
    enabled = config.get('enabledPlugins', {}).get('chitta@genomewalker-chitta', False)
    report = {
        'schema_version': VERSION,
        'bundle_sha256': digest(bundle(payload)),
        'platform': sys.platform,
        'files': files,
        'statusline': {'managed': status.get('type') == 'command' and command == launcher,
                       'quota_capture': wrapped},
        'prompt_suggestions_enabled': config.get('promptSuggestionEnabled') is True,
        'hooks': {'user_event_count': len(config.get('hooks', {})),
                  'chitta_enabled': enabled, 'failure_adapter_repaired': repaired},
        'drift': any(not f['managed'] for f in files) or command != launcher or
                 config.get('promptSuggestionEnabled') is not True or (enabled and not repaired),
    }
    print(json.dumps(report, sort_keys=True))
    return report


def apply(payload):
    # Existing installer owns private backups, CAS guards, and user-setting preservation.
    with tempfile.TemporaryDirectory(prefix='relay-provider-setup-') as directory:
        root = Path(directory)
        for name, data in payload.items():
            (root / name).write_bytes(data)
        namespace = {'__name__': 'relay_setup_installer', '__file__': str(root / 'install-relay-shell-ui.py')}
        exec(compile(payload['install-relay-shell-ui.py'], namespace['__file__'], 'exec'), namespace)
        namespace['main']()
        config = json.loads((Path.home() / '.claude/settings.json').read_text())
        if config.get('enabledPlugins', {}).get('chitta@genomewalker-chitta', False):
            subprocess.run([sys.executable, str(root / 'repair-chitta-failure-event.py')], check=True)
        # Install exactly the same portable entry point and manifest on every host.
        destination = Path.home() / '.config/relay/provider-setup.py'
        namespace['replace_private'](destination, bundle(payload))
        manifest = {'schema_version': VERSION, 'bundle_sha256': digest(bundle(payload)),
                    'assets': {k: digest(v) for k, v in sorted(payload.items())}}
        namespace['replace_private'](destination.parent / 'provider-setup-manifest.json',
                                     (json.dumps(manifest, indent=2) + '\n').encode())
    return audit(payload)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['audit', 'apply', 'bundle'], nargs='?', default='audit')
    args = parser.parse_args()
    payload = assets()
    if args.action == 'bundle':
        sys.stdout.buffer.write(bundle(payload))
        return 0
    report = apply(payload) if args.action == 'apply' else audit(payload)
    return 1 if report['drift'] else 0


if __name__ == '__main__':
    sys.exit(main())
