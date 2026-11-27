#!/usr/bin/env python3
"""Reads and bumps Logos's version, and tags releases.

The version lives in one place: CFBundleShortVersionString in
Resources/Info.plist. CFBundleVersion, the build number, goes up by one with
every release.

    release.py version           Print the version.
    release.py bump <part>       Bump patch, minor, or major, and print the new version.
    release.py released          Exit 0 when tag v<version> exists, 3 when it doesn't.
    release.py tag               Create and push the annotated tag v<version>.
"""

import plistlib
import subprocess
import sys
from pathlib import Path

PLIST = Path(__file__).resolve().parents[2] / "Resources" / "Info.plist"


def read():
    with PLIST.open("rb") as f:
        return plistlib.load(f)


def version():
    return read()["CFBundleShortVersionString"]


def bumped(current, part):
    major, minor, patch = (int(n) for n in current.split("."))
    if part == "major":
        return f"{major + 1}.0.0"
    if part == "minor":
        return f"{major}.{minor + 1}.0"
    if part == "patch":
        return f"{major}.{minor}.{patch + 1}"
    raise SystemExit(f"release.py: unknown part {part!r}; use patch, minor, or major")


def bump(part):
    plist = read()
    plist["CFBundleShortVersionString"] = bumped(plist["CFBundleShortVersionString"], part)
    plist["CFBundleVersion"] = str(int(plist["CFBundleVersion"]) + 1)
    with PLIST.open("wb") as f:
        plistlib.dump(plist, f, sort_keys=False)
    return plist["CFBundleShortVersionString"]


def git(*args):
    return subprocess.run(["git", *args], check=True, capture_output=True, text=True).stdout.strip()


def main(args):
    if args == ["version"]:
        print(version())
    elif len(args) == 2 and args[0] == "bump":
        print(bump(args[1]))
    elif args == ["released"]:
        tag = f"v{version()}"
        git("fetch", "--tags", "--quiet")
        return 0 if git("tag", "--list", tag) == tag else 3
    elif args == ["tag"]:
        tag = f"v{version()}"
        git("tag", "--annotate", tag, "--message", f"Logos {version()}")
        git("push", "origin", f"refs/tags/{tag}")
        print(tag)
    else:
        print(__doc__, file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
