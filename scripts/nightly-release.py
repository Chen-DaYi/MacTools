#!/usr/bin/env python3
"""Deterministic helpers for the public MacTools Nightly release workflow."""

from __future__ import annotations

import argparse
import json
import pathlib
import plistlib
import re
import sys
import xml.etree.ElementTree as ET
import xml.sax.saxutils as xml
from typing import Any, Dict, Iterable, List, Optional


VERSION_PATTERN = re.compile(
    r"^\s*(MARKETING_VERSION|CURRENT_PROJECT_VERSION)\s*=\s*(\S+)\s*$",
    re.MULTILINE,
)
BUILD_PATTERN = re.compile(r"^[0-9]+(?:\.[0-9]+)*$")
SHA_PATTERN = re.compile(r"^[0-9a-fA-F]{7,40}$")
NIGHTLY_TAG_PATTERN = re.compile(r"^nightly-([0-9]+)-([0-9]+)$")
REPOSITORY_PATTERN = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
RELEASE_DOWNLOAD_TAG_PATTERN = re.compile(
    r"/releases/download/(nightly-[0-9]+-[0-9]+)/"
)


def fail(message: str) -> None:
    raise SystemExit(message)


def validate_repository(repository: str) -> str:
    if not REPOSITORY_PATTERN.fullmatch(repository):
        fail("repository must use owner/name form")
    return repository


def read_app_version(config_path: pathlib.Path) -> Dict[str, str]:
    values = dict(VERSION_PATTERN.findall(config_path.read_text(encoding="utf-8")))
    if not values.get("MARKETING_VERSION"):
        fail(f"MARKETING_VERSION is missing from {config_path}")
    return values


def discover_plugin_metadata(source_dir: pathlib.Path) -> Dict[str, str]:
    manifests = sorted(source_dir.glob("*/plugin.json"))
    if not manifests:
        fail(f"No plugin manifests found under {source_dir}")

    versions = set()
    minimum_host_versions = []
    for manifest_path in manifests:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        versions.add(int(manifest["pluginKitVersion"]))
        minimum_host_versions.append(str(manifest["minHostVersion"]))
    if len(versions) != 1:
        fail("Nightly plugins must use exactly one PluginKit version")

    return {
        "PLUGIN_KIT_VERSION": str(next(iter(versions))),
        "PLUGIN_COUNT": str(len(manifests)),
        "PLUGIN_CATALOG_MINIMUM_HOST_VERSION": min(
            minimum_host_versions,
            key=version_components,
        ),
    }


def version_components(value: str) -> List[int]:
    components = []
    for component in value.split("."):
        match = re.match(r"^[0-9]+", component)
        components.append(int(match.group(0)) if match else 0)
    return components


def make_metadata(
    config_path: pathlib.Path,
    plugins_dir: pathlib.Path,
    repository: str,
    source_sha: str,
    run_number: str,
    run_attempt: str,
) -> Dict[str, str]:
    if not run_number.isdigit() or int(run_number) <= 0:
        fail("run number must be a positive integer")
    if not run_attempt.isdigit() or int(run_attempt) <= 0:
        fail("run attempt must be a positive integer")
    if not SHA_PATTERN.fullmatch(source_sha):
        fail("source SHA must contain 7 to 40 hexadecimal characters")
    validate_repository(repository)

    version = read_app_version(config_path)["MARKETING_VERSION"]
    build_number = f"{run_number}.{run_attempt}"
    tag = f"nightly-{run_number}-{run_attempt}"
    artifact_root = f"build/nightly/{tag}"
    metadata = {
        "SCHEME": "MacTools",
        "CONFIGURATION": "Nightly",
        "VERSION": version,
        "BUILD_NUMBER": build_number,
        "TAG": tag,
        "SOURCE_SHA": source_sha.lower(),
        "SHORT_SHA": source_sha[:8].lower(),
        "ARTIFACT_ROOT": artifact_root,
        "DMG_PATH": f"{artifact_root}/MacTools-Nightly.dmg",
        "SHA256_PATH": f"{artifact_root}/MacTools-Nightly.sha256",
        "PLUGIN_BUILD_DIR": f"{artifact_root}/PluginBuild",
        "PLUGIN_ASSETS_DIR": f"{artifact_root}/PluginAssets",
        "PLUGIN_CATALOG_PATH": f"{artifact_root}/catalog.json",
        "SIGNED_PLUGIN_CATALOG_PATH": f"{artifact_root}/catalog.signed.json",
        "PLUGIN_ASSET_BASE_URL": (
            f"https://github.com/{repository}/releases/download/{tag}"
        ),
        "PLUGIN_RELEASE_NOTES_URL": (
            f"https://github.com/{repository}/releases/tag/{tag}"
        ),
        "NIGHTLY_APPCAST_RELATIVE_PATH": "docs/nightly/appcast.xml",
    }
    metadata.update(discover_plugin_metadata(plugins_dir))
    metadata["NIGHTLY_PLUGIN_CATALOG_RELATIVE_PATH"] = (
        "docs/nightly/plugins/"
        f"v{metadata['PLUGIN_KIT_VERSION']}/catalog.json"
    )
    return metadata


def write_github_env(metadata: Dict[str, str], output_path: pathlib.Path) -> None:
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with output_path.open("a", encoding="utf-8") as output:
        for key, value in metadata.items():
            if "\n" in value or "\r" in value:
                fail(f"metadata value for {key} contains a newline")
            output.write(f"{key}={value}\n")


def write_release_notes(
    output_path: pathlib.Path,
    repository: str,
    version: str,
    build_number: str,
    source_sha: str,
) -> None:
    validate_repository(repository)
    if not BUILD_PATTERN.fullmatch(build_number):
        fail("build number must contain only numeric components")
    notes = f"""> [!WARNING]
> **MacTools Nightly is unstable.** It may contain unfinished features, regressions, or data-format changes. Keep the stable app installed and do not rely on Nightly for critical workflows.

This prerelease is an automated snapshot of the current MacTools source. It installs alongside stable MacTools and uses isolated preferences, Application Support data, plugins, URL routing, and update metadata.

- App version: `{version}`
- Nightly build: `{build_number}`
- Source commit: [`{source_sha}`](https://github.com/{repository}/commit/{source_sha})

To roll back, publish a known-good source commit as a new Nightly build. Signed assets for an existing Nightly tag are never replaced.
"""
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(notes, encoding="utf-8")


def write_appcast(
    output_path: pathlib.Path,
    repository: str,
    tag: str,
    version: str,
    build_number: str,
    signature: str,
    file_size: int,
    publication_date: str,
    release_notes: str,
) -> None:
    validate_repository(repository)
    if not NIGHTLY_TAG_PATTERN.fullmatch(tag):
        fail("Nightly tag must use nightly-<run>-<attempt>")
    if not BUILD_PATTERN.fullmatch(build_number):
        fail("build number must contain only numeric components")
    if file_size <= 0:
        fail("DMG file size must be positive")
    if not signature.strip():
        fail("Sparkle signature must not be empty")

    release_url = f"https://github.com/{repository}/releases/tag/{tag}"
    download_url = (
        f"https://github.com/{repository}/releases/download/"
        f"{tag}/MacTools-Nightly.dmg"
    )
    cdata_notes = release_notes.replace("]]>", "]]]]><![CDATA[>")
    content = f'''<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>MacTools Nightly Releases</title>
    <description>Unstable public Nightly updates for MacTools.</description>
    <language>en</language>
    <item>
      <title>MacTools Nightly {xml.escape(version)} ({xml.escape(build_number)})</title>
      <link>{xml.escape(release_url)}</link>
      <sparkle:version>{xml.escape(build_number)}</sparkle:version>
      <sparkle:shortVersionString>{xml.escape(version)}</sparkle:shortVersionString>
      <description sparkle:format="markdown"><![CDATA[{cdata_notes}]]></description>
      <sparkle:fullReleaseNotesLink>{xml.escape(release_url)}</sparkle:fullReleaseNotesLink>
      <pubDate>{xml.escape(publication_date)}</pubDate>
      <enclosure url="{xml.escape(download_url)}" length="{file_size}" type="application/octet-stream" sparkle:edSignature="{xml.escape(signature)}" />
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
    </item>
  </channel>
</rss>
'''
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(content, encoding="utf-8")
    ET.parse(output_path)


def verify_nightly_app(
    app_path: pathlib.Path,
    bundle_identifier_prefix: str,
    version: str,
    build_number: str,
    plugin_kit_version: int,
) -> None:
    if plugin_kit_version < 1:
        fail("PluginKit version must be positive")
    app_info_path = app_path / "Contents/Info.plist"
    extension_info_path = (
        app_path
        / "Contents/PlugIns/RightClickFinderSync.appex/Contents/Info.plist"
    )
    if not app_info_path.is_file() or not extension_info_path.is_file():
        fail(f"Nightly app or Finder Sync Info.plist is missing under {app_path}")

    with app_info_path.open("rb") as file:
        app_info = plistlib.load(file)
    with extension_info_path.open("rb") as file:
        extension_info = plistlib.load(file)

    expected_app_values = {
        "CFBundleDisplayName": "MacTools Nightly",
        "CFBundleIdentifier": f"{bundle_identifier_prefix}.mactools.nightly",
        "CFBundleShortVersionString": version,
        "CFBundleVersion": build_number,
        "MTApplicationSupportDirectoryName": "MacTools Nightly",
        "MTReleaseChannel": "nightly",
        "MTPluginCatalogURL": (
            "https://mactools.ggbond.app/nightly/plugins/"
            f"v{plugin_kit_version}/catalog.json"
        ),
        "MTRightClickConfigurationHomeRelativePath": (
            "Library/Application Support/MacTools Nightly/right-click-menu.json"
        ),
        "SUFeedURL": "https://mactools.ggbond.app/nightly/appcast.xml",
    }
    for key, expected in expected_app_values.items():
        if app_info.get(key) != expected:
            fail(f"Nightly app {key} is {app_info.get(key)!r}; expected {expected!r}")

    schemes = [
        scheme
        for item in app_info.get("CFBundleURLTypes", [])
        for scheme in item.get("CFBundleURLSchemes", [])
    ]
    if schemes != ["mactools-nightly"]:
        fail(f"Nightly URL schemes are {schemes!r}; expected ['mactools-nightly']")

    expected_extension_values = {
        "CFBundleDisplayName": "MacTools Nightly 右键工具",
        "CFBundleIdentifier": (
            f"{bundle_identifier_prefix}.mactools.nightly.right-click.finder-sync"
        ),
        "CFBundleShortVersionString": version,
        "CFBundleVersion": build_number,
        "MTRightClickHostURLScheme": "mactools-nightly",
        "MTRightClickToolbarItemName": "MacTools Nightly",
        "MTRightClickConfigurationHomeRelativePath": (
            "Library/Application Support/MacTools Nightly/right-click-menu.json"
        ),
    }
    for key, expected in expected_extension_values.items():
        if extension_info.get(key) != expected:
            fail(
                f"Nightly Finder Sync {key} is {extension_info.get(key)!r}; "
                f"expected {expected!r}"
            )


def verify_nightly_catalog(
    catalog_path: pathlib.Path,
    plugins_dir: pathlib.Path,
    repository: str,
    tag: str,
    build_number: str,
) -> None:
    validate_repository(repository)
    catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
    source_manifests = {
        json.loads(path.read_text(encoding="utf-8"))["id"]: json.loads(
            path.read_text(encoding="utf-8")
        )
        for path in plugins_dir.glob("*/plugin.json")
    }
    entries = {entry["id"]: entry for entry in catalog.get("plugins", [])}
    if set(entries) != set(source_manifests):
        missing = sorted(set(source_manifests) - set(entries))
        extra = sorted(set(entries) - set(source_manifests))
        fail(f"Nightly catalog plugin set differs; missing={missing}, extra={extra}")

    expected_url_prefix = (
        f"https://github.com/{repository}/releases/download/"
        f"{tag}/"
    )
    for plugin_id, entry in entries.items():
        source = source_manifests[plugin_id]
        source_major = str(source["version"]).split(".", maxsplit=1)[0]
        if entry["version"] != f"{source_major}.{build_number}":
            fail(f"Nightly version mismatch for {plugin_id}")
        if entry["pluginKitVersion"] != source["pluginKitVersion"]:
            fail(f"Nightly PluginKit mismatch for {plugin_id}")
        if not entry["package"]["url"].startswith(expected_url_prefix):
            fail(f"Nightly package URL mismatch for {plugin_id}")
    signature = catalog.get("signature") or {}
    if signature.get("algorithm") != "ed25519" or not signature.get("value"):
        fail("Nightly catalog is not signed with Ed25519")


def read_nightly_appcast_tag(appcast_path: pathlib.Path) -> str:
    try:
        root = ET.parse(appcast_path).getroot()
    except (ET.ParseError, OSError) as error:
        fail(f"Nightly appcast cannot be parsed: {appcast_path}: {error}")
    for enclosure in root.iter("enclosure"):
        match = RELEASE_DOWNLOAD_TAG_PATTERN.search(enclosure.attrib.get("url", ""))
        if match:
            return match.group(1)
    fail(f"Nightly appcast does not contain a valid release tag: {appcast_path}")


def stale_nightly_tags(
    releases: Iterable[Dict[str, Any]],
    keep: int,
    preserve_tags: Iterable[str] = (),
) -> List[str]:
    if keep < 1:
        fail("retention count must be positive")
    preserved = set(preserve_tags)
    for tag in preserved:
        if not NIGHTLY_TAG_PATTERN.fullmatch(tag):
            fail(f"preserved Nightly tag is invalid: {tag}")
    nightly = [
        release
        for release in releases
        if release.get("isPrerelease") is True
        and release.get("isDraft") is not True
        and NIGHTLY_TAG_PATTERN.fullmatch(str(release.get("tagName", "")))
    ]
    nightly.sort(key=lambda release: str(release.get("publishedAt", "")), reverse=True)
    return [
        str(release["tagName"])
        for release in nightly[keep:]
        if str(release["tagName"]) not in preserved
    ]


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser()
    subparsers = root.add_subparsers(dest="command", required=True)

    metadata = subparsers.add_parser("metadata")
    metadata.add_argument("--app-version-config", type=pathlib.Path, required=True)
    metadata.add_argument("--plugins-dir", type=pathlib.Path, required=True)
    metadata.add_argument("--repository", required=True)
    metadata.add_argument("--source-sha", required=True)
    metadata.add_argument("--run-number", required=True)
    metadata.add_argument("--run-attempt", required=True)
    metadata.add_argument("--github-env", type=pathlib.Path)

    notes = subparsers.add_parser("notes")
    notes.add_argument("--output", type=pathlib.Path, required=True)
    notes.add_argument("--repository", required=True)
    notes.add_argument("--version", required=True)
    notes.add_argument("--build-number", required=True)
    notes.add_argument("--source-sha", required=True)

    appcast = subparsers.add_parser("appcast")
    appcast.add_argument("--output", type=pathlib.Path, required=True)
    appcast.add_argument("--repository", required=True)
    appcast.add_argument("--tag", required=True)
    appcast.add_argument("--version", required=True)
    appcast.add_argument("--build-number", required=True)
    appcast.add_argument("--signature", required=True)
    appcast.add_argument("--file-size", required=True, type=int)
    appcast.add_argument("--publication-date", required=True)
    appcast.add_argument("--release-notes", type=pathlib.Path, required=True)

    verify_app = subparsers.add_parser("verify-app")
    verify_app.add_argument("--app", type=pathlib.Path, required=True)
    verify_app.add_argument("--bundle-identifier-prefix", required=True)
    verify_app.add_argument("--version", required=True)
    verify_app.add_argument("--build-number", required=True)
    verify_app.add_argument("--plugin-kit-version", required=True, type=int)

    verify_catalog = subparsers.add_parser("verify-catalog")
    verify_catalog.add_argument("--catalog", type=pathlib.Path, required=True)
    verify_catalog.add_argument("--plugins-dir", type=pathlib.Path, required=True)
    verify_catalog.add_argument("--repository", required=True)
    verify_catalog.add_argument("--tag", required=True)
    verify_catalog.add_argument("--build-number", required=True)

    stale_tags = subparsers.add_parser("stale-tags")
    stale_tags.add_argument("--input", type=pathlib.Path, required=True)
    stale_tags.add_argument("--keep", type=int, default=14)
    stale_tags.add_argument("--preserve-tag", action="append", default=[])

    appcast_tag = subparsers.add_parser("appcast-tag")
    appcast_tag.add_argument("--input", type=pathlib.Path, required=True)

    plugin_kit_version = subparsers.add_parser("plugin-kit-version")
    plugin_kit_version.add_argument("--plugins-dir", type=pathlib.Path, required=True)
    return root


def main() -> None:
    args = parser().parse_args()
    if args.command == "metadata":
        metadata = make_metadata(
            config_path=args.app_version_config,
            plugins_dir=args.plugins_dir,
            repository=args.repository,
            source_sha=args.source_sha,
            run_number=args.run_number,
            run_attempt=args.run_attempt,
        )
        if args.github_env:
            write_github_env(metadata, args.github_env)
        else:
            for key, value in metadata.items():
                print(f"{key}={value}")
    elif args.command == "notes":
        write_release_notes(
            args.output,
            args.repository,
            args.version,
            args.build_number,
            args.source_sha,
        )
    elif args.command == "appcast":
        write_appcast(
            output_path=args.output,
            repository=args.repository,
            tag=args.tag,
            version=args.version,
            build_number=args.build_number,
            signature=args.signature,
            file_size=args.file_size,
            publication_date=args.publication_date,
            release_notes=args.release_notes.read_text(encoding="utf-8"),
        )
    elif args.command == "verify-app":
        verify_nightly_app(
            args.app,
            args.bundle_identifier_prefix,
            args.version,
            args.build_number,
            args.plugin_kit_version,
        )
    elif args.command == "verify-catalog":
        verify_nightly_catalog(
            args.catalog,
            args.plugins_dir,
            args.repository,
            args.tag,
            args.build_number,
        )
    elif args.command == "stale-tags":
        releases = json.loads(args.input.read_text(encoding="utf-8"))
        for tag in stale_nightly_tags(releases, args.keep, args.preserve_tag):
            print(tag)
    elif args.command == "appcast-tag":
        print(read_nightly_appcast_tag(args.input))
    elif args.command == "plugin-kit-version":
        print(discover_plugin_metadata(args.plugins_dir)["PLUGIN_KIT_VERSION"])


if __name__ == "__main__":
    main()
