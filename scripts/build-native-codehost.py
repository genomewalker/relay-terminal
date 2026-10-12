#!/usr/bin/env python3
"""Build the matching Codex tool host with Codex's verified V8 release assets."""
import argparse
import hashlib
import os
from pathlib import Path
import subprocess
import urllib.request

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('root', type=Path)
parser.add_argument('target')
parser.add_argument('--native-bundle', action='store_true',
                    help='Build Codex, its peer worker and tool host together')
args = parser.parse_args()
root = args.root.resolve()
target = args.target
profile = 'ptrcomp_sandbox_release_' + target
version = '150.4.0'
cache = root / '.relay-codehost-v8' / target
cache.mkdir(parents=True, exist_ok=True)
manifest_name = 'rusty_v8_' + profile + '.sha256'
trusted = root / 'third_party/v8/rusty_v8_150_4_0_release_manifests.sha256'
expected = {}
for line in trusted.read_text().splitlines():
    digest, name = line.split(None, 1)
    expected[name.strip()] = digest
base = 'https://github.com/openai/codex/releases/download/rusty-v8-v' + version + '/'

def fetch(name, digest):
    destination = cache / name
    if destination.exists() and hashlib.sha256(destination.read_bytes()).hexdigest() == digest:
        return destination
    temporary = destination.with_suffix(destination.suffix + '.partial')
    subprocess.check_call(['curl', '-fsSL', base + name, '-o', str(temporary)])
    if hashlib.sha256(temporary.read_bytes()).hexdigest() != digest:
        raise RuntimeError('Checksum mismatch: ' + name)
    os.replace(str(temporary), str(destination))
    return destination

manifest = fetch(manifest_name, expected[manifest_name])
files = {}
for line in manifest.read_text().splitlines():
    digest, name = line.split(None, 1)
    name = name.strip()
    if Path(name).name != name:
        raise RuntimeError('Invalid artifact name')
    files[name] = fetch(name, digest)
archive = 'librusty_v8_' + profile + '.a.gz'
binding = 'src_binding_' + profile + '.rs'
if set(files) != {archive, binding}:
    raise RuntimeError('Unexpected V8 artifact set')
env = dict(os.environ, RUSTY_V8_ARCHIVE=str(files[archive]),
           RUSTY_V8_SRC_BINDING_PATH=str(files[binding]))
build = ['cargo', 'build', '--release']
if args.native_bundle:
    for binary in ['codex', 'codex-peer-worker', 'codex-code-mode-host']:
        build.extend(['--bin', binary])
else:
    build.extend(['-p', 'codex-code-mode-host'])
subprocess.check_call(build,
                      cwd=str(root / 'codex-rs'), env=env)
