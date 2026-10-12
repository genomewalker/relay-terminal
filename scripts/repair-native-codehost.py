#!/usr/bin/env python3
"""Add a missing matching tool host to an existing immutable Codex installation."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

root = Path(sys.argv[1]).resolve()
source = Path(sys.argv[2]).resolve()
name = 'codex-code-mode-host'
manifest = root / 'installed.json'
original = manifest.read_bytes()
record = json.loads(original)
if record.get('version') != '0.160.0-relay-native-1':
    raise RuntimeError('Unsupported installation')

def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()

for executable in ['codex', 'codex-peer-worker']:
    if digest(root / executable) != record['files'][executable]:
        raise RuntimeError('Existing installation checksum mismatch: ' + executable)
if not source.is_file() or not os.access(str(source), os.X_OK):
    raise RuntimeError('Missing matching host build')
subprocess.check_call([str(source), '--help'], stdout=subprocess.DEVNULL, timeout=15)
expected = digest(source)
destination = root / name
if (record['files'].get(name) == expected and destination.is_file()
        and not destination.is_symlink() and digest(destination) == expected):
    print(json.dumps({'installation': str(root), 'added': name, 'sha256': expected,
                      'already_repaired': True, 'existing_executables_unchanged': True}))
    sys.exit(0)
if destination.exists() or destination.is_symlink():
    if destination.is_symlink() or digest(destination) != expected:
        raise RuntimeError('Refusing to replace a different existing tool host')
else:
    fd, temporary = tempfile.mkstemp(prefix='.codehost-', dir=str(root))
    os.close(fd)
    try:
        shutil.copyfile(str(source), temporary)
        os.chmod(temporary, 0o700)
        if digest(Path(temporary)) != expected:
            raise RuntimeError('Copied tool host checksum mismatch')
        os.link(temporary, str(destination))
    finally:
        os.unlink(temporary)
if manifest.read_bytes() != original:
    raise RuntimeError('Installation manifest changed during repair')
backup = root / 'installed.before-codehost.json'
with backup.open('xb') as stream:
    stream.write(original)
os.chmod(str(backup), 0o600)
record['files'][name] = expected
fd, temporary = tempfile.mkstemp(prefix='.manifest-', dir=str(root))
with os.fdopen(fd, 'w') as stream:
    json.dump(record, stream, indent=2)
    stream.write('\n')
    stream.flush()
    os.fsync(stream.fileno())
os.replace(temporary, str(manifest))
print(json.dumps({'installation': str(root), 'added': name, 'sha256': expected,
                  'existing_executables_unchanged': True}))
