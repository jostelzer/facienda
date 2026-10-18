#!/usr/bin/env python3
"""Bind a prepared release archive and its notes to a committed version."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import sys


VERSION = re.compile(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)")
FILES = ("Facienda.zip", "notes.md")


def project_version(text):
    versions = re.findall(r"^\s*MARKETING_VERSION:\s*['\"]?([0-9.]+)['\"]?\s*$", text, re.M)
    if len(versions) != 1 or not VERSION.fullmatch(versions[0]):
        raise ValueError("project.yml must define one MARKETING_VERSION in X.Y.Z form.")
    return versions[0]


def digest(path):
    with path.open("rb") as stream:
        value = hashlib.sha256()
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
        return value.hexdigest()


def validate(data):
    if data.get("schema") != 1 or not re.fullmatch(r"[0-9a-f]{40}", data.get("commit", "")):
        raise ValueError("Invalid prepared release commit or schema.")
    if not VERSION.fullmatch(data.get("version", "")) or not re.fullmatch(r"[0-9]{14}", data.get("build", "")):
        raise ValueError("Invalid prepared release version or build number.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("version")
    record = commands.add_parser("record")
    record.add_argument("directory", type=Path)
    for key in ("commit", "version", "build"):
        record.add_argument(f"--{key}", required=True)
    verify = commands.add_parser("verify")
    verify.add_argument("directory", type=Path)
    newer = commands.add_parser("newer")
    newer.add_argument("version")
    args = parser.parse_args()
    if args.command == "version":
        print(project_version(sys.stdin.read()))
    elif args.command == "newer":
        current = tuple(map(int, args.version.split(".")))
        for tag in sys.stdin.read().splitlines():
            version = tag.removeprefix("v")
            if VERSION.fullmatch(version) and current <= tuple(map(int, version.split("."))):
                raise ValueError(f"{args.version} must be newer than {tag}.")
    elif args.command == "record":
        data = dict(schema=1, commit=args.commit, version=args.version, build=args.build)
        validate(data)
        data["sha256"] = {name: digest(args.directory / name) for name in FILES}
        with (args.directory / "release.json").open("x") as stream:
            json.dump(data, stream, indent=2)
            stream.write("\n")
    else:
        data = json.loads((args.directory / "release.json").read_text())
        validate(data)
        for name in FILES:
            if data.get("sha256", {}).get(name) != digest(args.directory / name):
                raise ValueError(f"Prepared {name} has changed; prepare the release again.")
        print(data["commit"], data["version"], data["build"])


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, TypeError) as error:
        sys.exit(str(error))
