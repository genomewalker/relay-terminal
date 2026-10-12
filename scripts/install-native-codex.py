#!/usr/bin/env python3
"""Install native Codex and its companion executables without touching running agents."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--codex', type=Path, required=True)
    parser.add_argument('--worker', type=Path, required=True)
    parser.add_argument('--code-mode-host', type=Path)
    parser.add_argument('--expected-manifest', type=Path,
                        help='Require staged executable hashes to match this acceptance manifest')
    parser.add_argument('--stage-only', action='store_true',
                        help='Prepare and hash the bundle without activating it')
    args = parser.parse_args()
    sources = {'codex': args.codex.resolve(), 'codex-peer-worker': args.worker.resolve()}
    sources['codex-code-mode-host'] = (args.code_mode_host or
                                      args.codex.resolve().with_name('codex-code-mode-host')).resolve()
    for name, source in sources.items():
        if not source.is_file() or not os.access(source, os.X_OK):
            raise RuntimeError('Missing executable: ' + name)
    version = subprocess.check_output([str(sources['codex']), '--version'], universal_newlines=True, timeout=15).strip()
    match = re.fullmatch(r'codex-cli (\d+\.\d+\.\d+)', version)
    if not match:
        raise RuntimeError('Unexpected Codex version: ' + version)
    upstream_version = match.group(1)
    parent = Path.home() / '.local/share/relay'
    parent.mkdir(parents=True, mode=0o700, exist_ok=True)
    destination = parent / 'native-codex'
    if destination.exists() and not destination.is_symlink():
        raise RuntimeError('Refusing to replace an unmanaged native-codex directory')
    stage = Path(tempfile.mkdtemp(prefix='native-codex-' + upstream_version + '-', dir=parent))
    try:
        hashes = {}
        for name, source in sources.items():
            target = stage / name
            shutil.copyfile(source, target)
            target.chmod(0o700)
            digest = hashlib.sha256()
            with target.open('rb') as stream:
                for block in iter(lambda: stream.read(1024 * 1024), b''):
                    digest.update(block)
            hashes[name] = digest.hexdigest()
        if args.expected_manifest:
            expected = json.loads(args.expected_manifest.read_text())
            if expected.get('files') != hashes:
                raise RuntimeError('Staged executable hashes differ from acceptance manifest')
        manifest = stage / 'installed.json'
        manifest.write_text(json.dumps({'version': upstream_version + '-relay-native-1',
                                        'native_inbox_protocol': 1, 'files': hashes,
                                        'platform': platform.system(), 'arch': platform.machine()}, indent=2) + '\n')
        manifest.chmod(0o600)
        for file in [stage / name for name in sources] + [manifest]:
            with file.open('rb') as stream:
                os.fsync(stream.fileno())
        directory_fd = os.open(stage, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
        if not args.stage_only:
            link = parent / (stage.name + '.link')
            link.symlink_to(stage.name)
            os.replace(link, destination)
            parent_fd = os.open(parent, os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(parent_fd)
            finally:
                os.close(parent_fd)
        print(json.dumps({'installed': str(stage if args.stage_only else destination),
                          'activated': not args.stage_only, 'version': version,
                          'running_agents_changed': False}))
    except BaseException:
        if not destination.is_symlink() or destination.resolve() != stage.resolve():
            shutil.rmtree(stage)
        raise


if __name__ == '__main__':
    main()
