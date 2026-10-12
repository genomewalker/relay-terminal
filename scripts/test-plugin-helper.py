#!/usr/bin/env python3
"""Read-only smoke checks against a disposable fixture and a staged helper.

Usage: test-plugin-helper.py HELPER FIXTURE [--ssh HOST]
Fixture contains package.json, pnpm-lock.yaml, table.csv, empty.txt; optionally
initialize/stage it in Git first. Never use a real project for this smoke check.
No scheduler mutations or shell command contributions are invoked.
"""
import argparse
import base64
import hashlib
import json
import subprocess


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("helper")
    parser.add_argument("fixture")
    parser.add_argument("--ssh")
    args = parser.parse_args()
    if not args.helper.startswith("/tmp/") or not args.fixture.startswith("/tmp/"):
        parser.error("use explicit disposable /tmp paths only")
    command = [args.helper, "plugin"]
    if args.ssh:
        import shlex
        command = ["ssh", "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", args.ssh,
                   shlex.join(command)]

    def request(operation, path="", **fields):
        result = subprocess.run(command, input=json.dumps({"operation": operation, "root": args.fixture, "path": path, **fields}),
                                capture_output=True, text=True, timeout=15, check=True)
        return json.loads(result.stdout)

    listing = request("artifacts")
    assert "table.csv" in listing["entries"] and "empty.txt" in listing["entries"]
    for operation, path in [("artifacts", "table.csv"), ("transfers", "empty.txt")]:
        result = request(operation, path)
        data = base64.b64decode(result["content"], validate=True)
        assert hashlib.sha256(data).hexdigest() == result["sha256"]
        assert result["text"] == path
        if path == "empty.txt":
            assert data == b""
    projects = request("projectActions")
    assert any("Detected pnpm lockfile" in item for item in projects["entries"])
    review = request("gitReview")
    assert "Worktree and Git directory:" in review["text"] and "table.csv" in review["entries"]
    diff = request("gitReview", "table.csv")
    assert "Staged changes:" in diff["text"] and "table.csv" in diff["text"]
    for path in ["../outside", "/etc/passwd"]:
        try:
            request("transfers", path)
        except subprocess.CalledProcessError:
            pass
        else:
            raise AssertionError("accepted outside path")
    for path in ["table.csv", "empty.txt"]:
        metadata = request("transfers", path, transfer={"mode": "stat", "version": "", "offset": 0})["transfer"]
        offset = 0
        digest = hashlib.sha256()
        while offset < metadata["size"]:
            chunk = request("transfers", path, transfer={"mode": "chunk", "version": metadata["version"], "offset": offset})
            data = base64.b64decode(chunk["content"], validate=True)
            assert 0 < len(data) <= 4 * 1024 * 1024
            assert hashlib.sha256(data).hexdigest() == chunk["sha256"]
            digest.update(data)
            offset += len(data)
        final = request("transfers", path, transfer={"mode": "verify", "version": metadata["version"], "offset": offset})
        assert digest.hexdigest() == final["transfer"]["sha256"]
    print(json.dumps({"target": args.ssh or "local", "checks": 10, "result": "passed"}))


if __name__ == "__main__":
    main()
