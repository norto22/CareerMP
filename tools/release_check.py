#!/usr/bin/env python3
"""Checks that a release pull request is consistent before it is merged.

    TITLE=v0.2.0 python3 tools/release_check.py --base <server.json from main>
    TITLE=v0.2.0 python3 tools/release_check.py

The title is read from the TITLE environment variable, never from the command line, so
it is only ever data. Rules:
  - the title is vMAJOR.MINOR.REVISION;
  - versions/client.json and versions/server.json both carry that version and the
    norto22/Mileage lineage;
  - with --base, the version is strictly higher than the base server.json, because
    installed servers refuse to downgrade.
Exits non-zero naming every rule that failed.
"""
import argparse
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LINEAGE = "norto22/Mileage"
VERSION_FILES = [
    "Resources/Server/Mileage/versions/client.json",
    "Resources/Server/Mileage/versions/server.json",
]
TITLE_PATTERN = re.compile(r"v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)")


def read_version(path):
    """Returns ((major, minor, revision), lineage). Each part must be a non-negative JSON
    integer: the server's updater compares them as numbers, and the package is named
    from them."""
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    parts = []
    for key in ("major", "minor", "revision"):
        value = data[key]
        if type(value) is not int or value < 0:
            raise ValueError(f"{key} must be a non-negative whole number, got {value!r}")
        parts.append(value)
    return tuple(parts), data.get("lineage")


def describe(version):
    return ".".join(str(part) for part in version)


def title_version(title):
    """Returns (version, error) for the pull request title."""
    if title is None:
        return None, "TITLE is not set"
    match = TITLE_PATTERN.fullmatch(title)
    if not match:
        return None, f"title must be vX.X.X, for example v0.2.0 (got {title!r})"
    return tuple(int(part) for part in match.groups()), None


def version_file_errors(version):
    errors = []
    for rel in VERSION_FILES:
        try:
            found, lineage = read_version(os.path.join(ROOT, rel))
        except (OSError, ValueError, KeyError, TypeError) as e:
            errors.append(f"{rel} cannot be read ({e})")
            continue
        if found != version:
            errors.append(f"{rel} is {describe(found)}, the title says {describe(version)}; the version files must match the title")
        if lineage != LINEAGE:
            errors.append(f"{rel} lineage is {lineage!r}, expected {LINEAGE!r}")
    return errors


def base_errors(version, base_path):
    try:
        base, _ = read_version(base_path)
    except (OSError, ValueError, KeyError, TypeError) as e:
        return [f"base version {base_path} cannot be read ({e})"]
    if version <= base:
        return [f"{describe(version)} must be higher than {describe(base)} on the base branch; servers refuse to downgrade"]
    return []


def main():
    parser = argparse.ArgumentParser(description="Check a release pull request.")
    parser.add_argument("--base", help="server.json from the branch being merged into")
    args = parser.parse_args()

    title = os.environ.get("TITLE")
    version, error = title_version(title)
    if error:
        print(f"release check failed: {error}", file=sys.stderr)
        return 1

    errors = version_file_errors(version)
    if args.base:
        errors += base_errors(version, args.base)

    if errors:
        for error in errors:
            print(f"release check failed: {error}", file=sys.stderr)
        return 1
    print(f"release check passed for {title}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
