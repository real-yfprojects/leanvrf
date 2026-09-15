#!/usr/bin/env python3
"""Structural check of toolchain.lock, run by pre-commit (and therefore CI).

Usage: check-toolchain-lock.py [toolchain.lock]

Everything here is also enforced at run time -- provision-toolchain.sh refuses
malformed hashes and non-https URLs, build-tools.yml refuses tool URLs that do
not point at the release tag -- but a hand-edited lockfile should fail on the
maintainer's machine, not in a prover's verification run. Python rather than
bash+jq only so that the hook runs wherever pre-commit does; nothing is
downloaded, this reads the file and the patches/ directory.
"""

import json
import re
import sys
from pathlib import Path

SHA256 = re.compile(r"^[a-f0-9]{64}$")
COMMIT = re.compile(r"^[a-f0-9]{40}$")
HTTPS = re.compile(r"^https://[^\s\x00-\x1f@]+$")
NAME = re.compile(r"^[A-Za-z0-9_.-]+$")  # provision-toolchain.sh
RELEASE_TAG = re.compile(r"^[A-Za-z0-9._-]+$")  # build-tools.yml


def main() -> int:
    lock = Path(sys.argv[1] if len(sys.argv) > 1 else "toolchain.lock")
    if not lock.is_file():
        print(f"Error: {lock} not found", file=sys.stderr)
        return 1
    root = lock.resolve().parent  # patches are relative to the lockfile (build-tools.sh)
    errors = []

    def fail(msg: str) -> None:
        errors.append(msg)

    try:
        data = json.loads(lock.read_text(encoding="utf-8"))
    except (ValueError, UnicodeDecodeError) as exc:
        print(f"Error: {lock} is not valid JSON: {exc}", file=sys.stderr)
        return 1

    def get(obj, key, default=""):
        return obj.get(key, default) if isinstance(obj, dict) else default

    release_tag = str(get(data, "release_tag"))
    if not RELEASE_TAG.match(release_tag):
        fail(f"release_tag '{release_tag}' is malformed")

    # .lean and every build toolchain: https URL plus sha256.
    artifacts = {".lean": get(data, "lean", {})}
    for key, value in get(data, "build_toolchains", {}).items():
        if key != "$comment":
            artifacts[f".build_toolchains.{key}"] = value
    for path, entry in artifacts.items():
        url, sha = str(get(entry, "url")), str(get(entry, "sha256"))
        if not HTTPS.match(url):
            fail(f"{path}.url '{url}' is not an https URL")
        if not SHA256.match(sha):
            fail(f"{path}.sha256 is not 64 lowercase hex characters")

    # Every tool: name shape, source commit, release URL derived from
    # release_tag, sha256, and patches that exist in this repository.
    for i, tool in enumerate(get(data, "tools", [])):
        name = str(get(tool, "name"))
        label = f"tools[{i}] ({name})"
        if not NAME.match(name):
            fail(f"tools[{i}].name '{name}' is malformed")
        if not COMMIT.match(str(get(tool, "commit"))):
            fail(f"{label}: commit is not a full lowercase SHA-1")
        url = str(get(tool, "url"))
        if not HTTPS.match(url):
            fail(f"{label}: url '{url}' is not an https URL")
        expected = re.compile(
            r"^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/releases/download/"
            + re.escape(release_tag) + "/" + re.escape(name) + "$"
        )
        if not expected.match(url):
            fail(f"{label}: url does not end in /releases/download/{release_tag}/{name}")
        if not SHA256.match(str(get(tool, "sha256"))):
            fail(f"{label}: sha256 is not 64 lowercase hex characters")
        for patch in get(tool, "patches", []) or []:
            patch = str(patch)
            if not patch.startswith("patches/") or ".." in patch.split("/"):
                fail(f"{label}: patch '{patch}' must be a path under patches/")
            elif not (root / patch).is_file():
                fail(f"{label}: patch '{patch}' does not exist")

    for msg in errors:
        print(f"Error: {msg}", file=sys.stderr)
    if errors:
        print(f"{lock}: {len(errors)} problem(s)", file=sys.stderr)
        return 1
    print(f"{lock}: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
