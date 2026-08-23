#!/usr/bin/env python3
"""Generate schema-3 plugin and website catalogs from plugin.json."""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import tempfile
import zipfile
from datetime import datetime, timezone
from pathlib import Path

from plugin_source_manifest import load_known_plugin_ids, validate_and_project_manifest


SCHEMA3_MINIMUM_HOST_VERSION = "1.2.1"


def version_tuple(value: str) -> tuple[int, ...]:
    try:
        return tuple(int(component) for component in value.split("."))
    except ValueError as error:
        raise SystemExit(f"Invalid minimum host version: {value}") from error


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=("debug", "release"), required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--package", type=Path, action="append", required=True)
    parser.add_argument("--base-url")
    parser.add_argument("--release-notes-url")
    parser.add_argument("--catalog-id", default="com.ggbond.mactools.plugins")
    parser.add_argument("--minimum-host-version")
    parser.add_argument("--plugin-kit-version", type=int)
    parser.add_argument("--plugins-root", type=Path, default=Path("Plugins"))
    parser.add_argument("--website-output", type=Path)
    parser.add_argument("--generated-at")
    return parser.parse_args()


def directory_metrics(path: Path) -> tuple[str, int]:
    digest = hashlib.sha256()
    size = 0
    files = sorted(
        candidate for candidate in path.rglob("*")
        if candidate.is_file()
        and not any(part.startswith(".") for part in candidate.relative_to(path).parts)
    )
    for file_path in files:
        relative = file_path.relative_to(path).as_posix()
        data = file_path.read_bytes()
        digest.update(relative.encode("utf-8"))
        digest.update(b"\0")
        digest.update(data)
        digest.update(b"\0")
        size += len(data)
    return digest.hexdigest(), size


def file_metrics(path: Path) -> tuple[str, int]:
    digest = hashlib.sha256()
    size = 0
    with path.open("rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(chunk)
            size += len(chunk)
    return digest.hexdigest(), size


def package_root(path: Path) -> tuple[Path, tempfile.TemporaryDirectory | None]:
    if path.suffix != ".zip":
        return path, None
    temporary = tempfile.TemporaryDirectory(prefix="mactools-plugin-catalog-")
    with zipfile.ZipFile(path) as archive:
        archive.extractall(temporary.name)
    roots = [candidate for candidate in Path(temporary.name).iterdir() if candidate.name.endswith(".mactoolsplugin")]
    if len(roots) != 1:
        temporary.cleanup()
        raise SystemExit(f"{path} must contain exactly one .mactoolsplugin root")
    return roots[0], temporary


def source_manifest_path(plugins_root: Path, plugin_id: str, packaged_path: Path) -> Path:
    matches = []
    if plugins_root.is_dir():
        candidates = list(plugins_root.glob("*/plugin.json"))
        if (plugins_root / "plugin.json").is_file():
            candidates.append(plugins_root / "plugin.json")
        for path in candidates:
            manifest = json.loads(path.read_text(encoding="utf-8"))
            if manifest.get("id") == plugin_id:
                matches.append(path)
    if len(matches) == 1:
        return matches[0]
    return packaged_path


def main() -> None:
    args = parse_args()
    if args.mode == "release" and not args.base_url:
        raise SystemExit("--base-url is required in release mode")
    minimum_host_version = args.minimum_host_version or (
        SCHEMA3_MINIMUM_HOST_VERSION if args.mode == "release" else "0.1.0"
    )
    if args.mode == "release" and version_tuple(minimum_host_version) < version_tuple(
        SCHEMA3_MINIMUM_HOST_VERSION
    ):
        raise SystemExit(
            "Schema 3 release catalogs require MacTools "
            f"{SCHEMA3_MINIMUM_HOST_VERSION} or later."
        )
    known_plugin_ids = load_known_plugin_ids(args.plugins_root) if args.plugins_root.is_dir() else set()
    entries = []
    website_plugins = []
    plugin_kit_versions = set()
    temporary_directories = []
    try:
        for raw_path in args.package:
            package_path = raw_path.expanduser().resolve()
            if not package_path.exists():
                raise SystemExit(f"Package not found: {package_path}")
            root, temporary = package_root(package_path)
            if temporary is not None:
                temporary_directories.append(temporary)
            packaged_manifest_path = root / "plugin.json"
            if not packaged_manifest_path.is_file():
                raise SystemExit(f"Missing plugin.json: {root}")
            packaged_manifest = json.loads(packaged_manifest_path.read_text(encoding="utf-8"))
            plugin_id = packaged_manifest["id"]
            source_path = source_manifest_path(args.plugins_root, plugin_id, packaged_manifest_path)
            source_manifest = json.loads(source_path.read_text(encoding="utf-8"))
            projected, assets = validate_and_project_manifest(
                source_manifest,
                source_path,
                known_plugin_ids or {plugin_id},
            )
            manifest_plugin_kit_version = int(packaged_manifest["pluginKitVersion"])
            plugin_kit_versions.add(manifest_plugin_kit_version)
            if args.plugin_kit_version is not None and manifest_plugin_kit_version != args.plugin_kit_version:
                raise SystemExit(
                    f"{packaged_manifest_path} uses pluginKitVersion {manifest_plugin_kit_version}, "
                    f"but --plugin-kit-version is {args.plugin_kit_version}"
                )
            digest, size = directory_metrics(package_path) if package_path.is_dir() else file_metrics(package_path)
            package_url = (
                package_path.as_uri()
                if args.mode == "debug"
                else args.base_url.rstrip("/") + "/" + package_path.name
            )
            entry = {
                "id": plugin_id,
                "displayName": projected.get("displayName", plugin_id),
                "summary": projected.get("summary", projected.get("displayName", plugin_id)),
                "localizedMetadata": projected.get("localizedMetadata"),
                "version": packaged_manifest["version"],
                "minimumHostVersion": packaged_manifest.get("minHostVersion", minimum_host_version),
                "pluginKitVersion": manifest_plugin_kit_version,
                "capabilities": packaged_manifest.get("capabilities", {
                    "primaryPanel": False, "componentPanel": False, "settings": "none"
                }),
                "permissions": packaged_manifest.get("permissions", []),
                "package": {"url": package_url, "sha256": digest, "size": size},
                "releaseNotesURL": projected.get("releaseNotesURL") or args.release_notes_url,
                "category": projected.get("category"),
                "releaseChannel": projected.get("releaseChannel"),
            }
            for section in (
                "presentation", "discovery", "requirements", "privacy",
                "actions", "setup", "relationships",
            ):
                if section in projected:
                    entry[section] = projected[section]
            entries.append(entry)
            website_entry = {
                key: value for key, value in entry.items()
                if key not in {"package", "releaseChannel"}
            }
            website_plugins.append((website_entry, assets))

        if args.plugin_kit_version is None:
            if len(plugin_kit_versions) != 1:
                raise SystemExit(
                    "Packages must use one pluginKitVersion: "
                    + ", ".join(map(str, sorted(plugin_kit_versions)))
                )
            catalog_plugin_kit_version = next(iter(plugin_kit_versions))
        else:
            catalog_plugin_kit_version = args.plugin_kit_version
        catalog = {
            "schemaVersion": 3,
            "catalogID": args.catalog_id,
            "generatedAt": args.generated_at or datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
            "minimumHostVersion": minimum_host_version,
            "pluginKitVersion": catalog_plugin_kit_version,
            "plugins": sorted(entries, key=lambda entry: entry["id"]),
            "revoked": [],
        }
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(
            json.dumps(catalog, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )

        if args.website_output is not None:
            assets_root = args.website_output.parent / "assets"
            website_values = []
            for website_entry, assets in sorted(website_plugins, key=lambda value: value[0]["id"]):
                for asset in assets:
                    destination_name = f"{asset.catalog['sha256']}{asset.source.suffix.lower()}"
                    assets_root.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(asset.source, assets_root / destination_name)
                    for screenshot in website_entry.get("presentation", {}).get("screenshots", []):
                        if screenshot["id"] == asset.catalog["id"]:
                            screenshot["path"] = f"assets/{destination_name}"
                website_values.append(website_entry)
            website = {"schemaVersion": 1, "plugins": website_values}
            args.website_output.parent.mkdir(parents=True, exist_ok=True)
            args.website_output.write_text(
                json.dumps(website, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
                encoding="utf-8",
            )
    finally:
        for temporary in temporary_directories:
            temporary.cleanup()


if __name__ == "__main__":
    main()
