#!/usr/bin/env python3
"""Builds the CareerMP client archive and, optionally, the server release package.

    python3 tools/build.py            rebuild Resources/Client/CareerMP.zip
    python3 tools/build.py --check    exit non-zero if the committed archive is stale
    python3 tools/build.py --package  also write dist/CareerMP-<version>.zip

The archive is reproducible: entries are sorted, named relative to the source folder
with "/" separators, dated 1980-01-01, and text files are stored with LF line endings,
so the same sources give the same bytes on any machine. Run from anywhere; paths are
resolved from the repository root. Needs only the Python 3 standard library.
"""
import argparse
import io
import json
import os
import sys
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CLIENT_SOURCE = os.path.join("Resources", "Client", "CareerMP")
CLIENT_ARCHIVE = "Resources/Client/CareerMP.zip"
SERVER_PLUGIN = "Resources/Server/CareerMP/careerMP.lua"
CLIENT_VERSION = "Resources/Server/CareerMP/versions/client.json"
SERVER_VERSION = "Resources/Server/CareerMP/versions/server.json"
PACKAGE_FILES = [CLIENT_ARCHIVE, SERVER_PLUGIN, CLIENT_VERSION, SERVER_VERSION]

TEXT_EXTENSIONS = (".lua", ".js", ".json", ".css", ".html")
FIXED_DATE = (1980, 1, 1, 0, 0, 0)
FILE_MODE = 0o100644 << 16
DIR_MODE = (0o040755 << 16) | 0x10


class BuildError(Exception):
    pass


def repo_path(rel):
    return os.path.join(ROOT, rel)


def read_bytes(rel):
    with open(repo_path(rel), "rb") as f:
        return f.read()


def collect_client_entries():
    """Returns [(name, data)] for the client archive; directories have data None."""
    source = repo_path(CLIENT_SOURCE)
    if not os.path.isdir(source):
        raise BuildError(f"client source folder not found: {CLIENT_SOURCE}")
    entries = []
    for root, dirs, files in os.walk(source):
        dirs.sort()
        rel_root = os.path.relpath(root, source).replace(os.sep, "/")
        if rel_root != ".":
            entries.append((rel_root + "/", None))
        for name in sorted(files):
            rel = name if rel_root == "." else f"{rel_root}/{name}"
            with open(os.path.join(root, name), "rb") as f:
                data = f.read()
            if name.lower().endswith(TEXT_EXTENSIONS):
                data = data.replace(b"\r\n", b"\n")
            entries.append((rel, data))
    if not any(data is not None for _, data in entries):
        raise BuildError(f"client source folder is empty: {CLIENT_SOURCE}")
    return sorted(entries, key=lambda entry: entry[0])


def write_zip(entries):
    """Returns the bytes of a reproducible zip holding entries [(name, data)]."""
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as archive:
        for name, data in entries:
            info = zipfile.ZipInfo(name, date_time=FIXED_DATE)
            info.create_system = 3
            if data is None:
                info.external_attr = DIR_MODE
                info.compress_type = zipfile.ZIP_STORED
                archive.writestr(info, b"")
            else:
                info.external_attr = FILE_MODE
                info.compress_type = zipfile.ZIP_DEFLATED
                archive.writestr(info, data, compresslevel=6)
    return buffer.getvalue()


def stale_entries(entries):
    """Names that differ between the committed archive and the sources."""
    path = repo_path(CLIENT_ARCHIVE)
    if not os.path.exists(path):
        return [CLIENT_ARCHIVE + " (missing)"]
    with zipfile.ZipFile(path) as archive:
        committed = {name: (None if name.endswith("/") else archive.read(name)) for name in archive.namelist()}
    expected = dict(entries)
    return sorted(name for name in set(committed) | set(expected) if committed.get(name, 0) != expected.get(name, 0))


def read_version(rel):
    if not os.path.exists(repo_path(rel)):
        raise BuildError(f"version file not found: {rel}")
    try:
        with open(repo_path(rel), encoding="utf-8") as f:
            data = json.load(f)
        return "{major}.{minor}.{revision}".format(**data)
    except (ValueError, KeyError) as e:
        raise BuildError(f"version file is not valid: {rel} ({e})")


def build_package():
    version = read_version(CLIENT_VERSION)
    read_version(SERVER_VERSION)
    for rel in PACKAGE_FILES:
        if not os.path.exists(repo_path(rel)):
            raise BuildError(f"package file not found: {rel}")
    package = write_zip([(rel, read_bytes(rel)) for rel in PACKAGE_FILES])
    out_dir = repo_path("dist")
    os.makedirs(out_dir, exist_ok=True)
    out = os.path.join(out_dir, f"CareerMP-{version}.zip")
    with open(out, "wb") as f:
        f.write(package)
    return os.path.relpath(out, ROOT)


def main():
    parser = argparse.ArgumentParser(description="Build the CareerMP client archive and release package.")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--check", action="store_true", help="fail if the committed client archive is stale")
    mode.add_argument("--package", action="store_true", help="also write dist/CareerMP-<version>.zip")
    args = parser.parse_args()

    try:
        entries = collect_client_entries()
        if args.check:
            stale = stale_entries(entries)
            if stale:
                print(f"{CLIENT_ARCHIVE} does not match {CLIENT_SOURCE}; run python3 tools/build.py. Differs:",
                      file=sys.stderr)
                for name in stale:
                    print(f"  {name}", file=sys.stderr)
                return 1
            print(f"{CLIENT_ARCHIVE} matches its sources")
            return 0
        with open(repo_path(CLIENT_ARCHIVE), "wb") as f:
            f.write(write_zip(entries))
        print(f"wrote {CLIENT_ARCHIVE}")
        if args.package:
            print(f"wrote {build_package()}")
        return 0
    except BuildError as e:
        print(f"build failed: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
