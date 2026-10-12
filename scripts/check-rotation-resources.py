#!/usr/bin/env python3
"""Fail a release build if its embedded rotation resources have drifted."""
import hashlib
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[1]
pairs = (("policy.py", "host_rotation_policy.py"), ("text_backend.py", "host_rotation_text.py"))
for canonical, embedded in pairs:
    source = (root / "Sources/Relay/Resources/Rotation" / canonical).read_bytes()
    target = (root / "remote/relayd/internal/daemon" / embedded).read_bytes()
    if source != target:
        sys.exit("Rotation resource mismatch: " + canonical + " / " + embedded)
    if canonical == "policy.py":
        code = (root / "remote/relayd/internal/daemon/host_rotation.go").read_text()
        match = re.search(r'const hostRotationPolicySHA = "([a-f0-9]{64})"', code)
        if match is None or hashlib.sha256(source).hexdigest() != match[1]:
            sys.exit("Rotation policy digest does not match its reviewed pin")
print("Rotation release resources match their canonical source and policy pin.")
