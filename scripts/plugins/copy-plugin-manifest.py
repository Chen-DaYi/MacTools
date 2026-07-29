#!/usr/bin/env python3
"""Copy a plugin manifest, normalizing Debug compatibility to the local host."""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import shutil


MARKETING_VERSION_PATTERN = re.compile(
    r"^\s*MARKETING_VERSION\s*=\s*(\S+)\s*$",
    re.MULTILINE,
)


def development_host_version(config_path: pathlib.Path) -> str:
    match = MARKETING_VERSION_PATTERN.search(config_path.read_text(encoding="utf-8"))
    if match is None:
        raise ValueError(f"Unable to determine MARKETING_VERSION from {config_path}")
    return match.group(1)


def copy_manifest(
    source: pathlib.Path,
    destination: pathlib.Path,
    configuration: str,
    app_version_config: pathlib.Path,
) -> None:
    if configuration != "Debug":
        shutil.copy2(source, destination)
        return

    manifest = json.loads(source.read_text(encoding="utf-8"))
    manifest["minHostVersion"] = development_host_version(app_version_config)
    destination.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    copy_parser = subparsers.add_parser("copy")
    copy_parser.add_argument("--source", type=pathlib.Path, required=True)
    copy_parser.add_argument("--destination", type=pathlib.Path, required=True)
    copy_parser.add_argument("--configuration", required=True)
    copy_parser.add_argument("--app-version-config", type=pathlib.Path, required=True)

    version_parser = subparsers.add_parser("host-version")
    version_parser.add_argument("--app-version-config", type=pathlib.Path, required=True)

    args = parser.parse_args()
    if args.command == "host-version":
        print(development_host_version(args.app_version_config))
        return

    copy_manifest(
        source=args.source,
        destination=args.destination,
        configuration=args.configuration,
        app_version_config=args.app_version_config,
    )


if __name__ == "__main__":
    main()
