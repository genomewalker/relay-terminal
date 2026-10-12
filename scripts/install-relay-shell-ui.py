#!/usr/bin/env python3
"""Install shared Relay prompt and cc-status launcher, preserving other settings."""
import base64
import json
import os
from pathlib import Path
import re
import stat
import tempfile
import time


def replace_private(path, data):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    original = None
    if path.exists() or path.is_symlink():
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        with os.fdopen(fd, 'rb') as stream:
            info = os.fstat(stream.fileno())
            if info.st_uid != os.getuid() or not stat.S_ISREG(info.st_mode):
                raise RuntimeError('Destination must be an owned regular file')
            original = stream.read(2 << 20)
        if original == data:
            return
        backup = path.parent / 'backups'
        backup.mkdir(mode=0o700, exist_ok=True)
        target = backup / (path.name + '-shell-ui-' + time.strftime('%Y%m%d-%H%M%S') + '-' + str(os.getpid()))
        with target.open('xb') as stream:
            os.chmod(target, 0o600)
            stream.write(original)
            stream.flush()
            os.fsync(stream.fileno())
    fd, temporary = tempfile.mkstemp(prefix='.' + path.name + '-', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        if original is not None:
            current = path.lstat()
            if current.st_ino != info.st_ino or current.st_mtime_ns != info.st_mtime_ns:
                raise RuntimeError('Destination changed during installation')
        elif path.exists() or path.is_symlink():
            raise RuntimeError('Destination appeared during installation')
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def main():
    source = Path(__file__).resolve().parent
    home = Path.home()
    for filename, destination in [('relay-prompt.bash', 'prompt.bash'), ('relay-cc-status.sh', 'cc-status.sh')]:
        replace_private(home / '.config/relay' / destination, (source / filename).read_bytes())
    settings = home / '.claude/settings.json'
    if not settings.exists():
        raise RuntimeError('Existing Claude settings are required')
    raw = settings.read_bytes()
    data = json.loads(raw)
    status = data.get('statusLine')
    if not isinstance(status, dict) or status.get('type') != 'command':
        raise RuntimeError('Existing command status line required')
    command = status.get('command', '')
    if 'cc-status' not in command and '--statusline' not in command:
        raise RuntimeError('Refusing to replace an unrelated status line')
    launcher = 'bash "$HOME/.config/relay/cc-status.sh"'
    if '--statusline' in command:
        encoded = base64.b64encode(launcher.encode()).decode()
        command, count = re.subn(r'(--statusline\s+)[A-Za-z0-9+/=]+', lambda match: match[1] + encoded, command)
        if count != 1:
            raise RuntimeError('Unknown status line wrapper format')
        status['command'] = command
    else:
        status['command'] = launcher
    # User preference: keep provider-generated prompt suggestions. Relay must
    # distinguish their rendered style from actual input during delivery.
    data['promptSuggestionEnabled'] = True
    if settings.read_bytes() != raw:
        raise RuntimeError('Claude settings changed during installation')
    replace_private(settings, (json.dumps(data, indent=2, ensure_ascii=False) + '\n').encode())
    # The current helper supplies Relay hooks only. Preserve the user's footer.
    shim = home / '.local/share/relay/shims/claude'
    thin = '#!/bin/sh\nset -eu\nRELAY_INVOKED_AS=claude\nexport RELAY_INVOKED_AS\nexec "$HOME/.local/bin/relayd" "$@"\n'
    managed = thin.replace('"$@"', '--settings "$HOME/.config/relay/claude-hooks-status.json" "$@"')
    if shim.exists() and shim.read_text() == managed:
        hooks = home / '.relay/claude-hooks.json'
        config = json.loads(hooks.read_text()) if hooks.exists() else {}
        if set(config) != {'hooks'}:
            raise RuntimeError('Upgrade the Relay helper before removing legacy launcher settings')
        replace_private(shim, thin.encode())
        shim.chmod(0o700)
    print('Shared prompt and cc-status launcher installed; other Claude settings preserved.')


if __name__ == '__main__':
    main()
