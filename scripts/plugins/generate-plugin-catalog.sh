#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage:
  generate-plugin-catalog.sh --mode debug --output catalog.dev.json --package Demo.mactoolsplugin [--package More.mactoolsplugin]
  generate-plugin-catalog.sh --mode release --base-url https://github.com/owner/repo/releases/download/tag --output catalog.json --package Demo.mactoolsplugin.zip

Options:
  --mode debug|release          Debug uses file:// package URLs; release uses --base-url.
  --output PATH                 Catalog JSON output path.
  --package PATH                .mactoolsplugin directory or .mactoolsplugin.zip. Repeatable.
  --base-url URL                Release asset base URL.
  --release-notes-url URL       Optional release notes URL used when plugin.json omits one.
  --catalog-id ID               Defaults to com.ggbond.mactools.plugins.
  --minimum-host-version VER    Defaults to 0.15.2.
  --plugin-kit-version INT      Override catalog PluginKit version; defaults to package manifests.

The script does not sign the catalog. Run sign-plugin-catalog.sh for release catalogs.
USAGE
}

MODE=""
OUTPUT=""
BASE_URL=""
RELEASE_NOTES_URL=""
CATALOG_ID="com.ggbond.mactools.plugins"
MINIMUM_HOST_VERSION="0.15.2"
PLUGIN_KIT_VERSION=""
PACKAGES=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode)
            MODE="${2:-}"
            shift 2
            ;;
        --output)
            OUTPUT="${2:-}"
            shift 2
            ;;
        --package)
            PACKAGES+=("${2:-}")
            shift 2
            ;;
        --base-url)
            BASE_URL="${2:-}"
            shift 2
            ;;
        --release-notes-url)
            RELEASE_NOTES_URL="${2:-}"
            shift 2
            ;;
        --catalog-id)
            CATALOG_ID="${2:-}"
            shift 2
            ;;
        --minimum-host-version)
            MINIMUM_HOST_VERSION="${2:-}"
            shift 2
            ;;
        --plugin-kit-version)
            PLUGIN_KIT_VERSION="${2:-}"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

if [[ "$MODE" != "debug" && "$MODE" != "release" ]]; then
    echo "--mode must be debug or release." >&2
    exit 1
fi

if [[ -z "$OUTPUT" || ${#PACKAGES[@]} -eq 0 ]]; then
    echo "--output and at least one --package are required." >&2
    usage >&2
    exit 1
fi

if [[ "$MODE" == "release" && -z "$BASE_URL" ]]; then
    echo "--base-url is required in release mode." >&2
    exit 1
fi

python3 - "$MODE" "$OUTPUT" "$BASE_URL" "$RELEASE_NOTES_URL" "$CATALOG_ID" "$MINIMUM_HOST_VERSION" "$PLUGIN_KIT_VERSION" "${PACKAGES[@]}" <<'PY'
import hashlib
import json
import pathlib
import sys
import tempfile
import zipfile
from datetime import datetime, timezone

mode, output, base_url, release_notes_url, catalog_id, minimum_host_version, plugin_kit_version, *packages = sys.argv[1:]
requested_plugin_kit_version = int(plugin_kit_version) if plugin_kit_version else None

def directory_metrics(path: pathlib.Path):
    h = hashlib.sha256()
    size = 0
    for file_path in sorted(p for p in path.rglob("*") if p.is_file() and not any(part.startswith(".") for part in p.relative_to(path).parts)):
        rel = file_path.relative_to(path).as_posix()
        data = file_path.read_bytes()
        h.update(rel.encode("utf-8"))
        h.update(b"\0")
        h.update(data)
        h.update(b"\0")
        size += len(data)
    return h.hexdigest(), size

def file_metrics(path: pathlib.Path):
    h = hashlib.sha256()
    size = 0
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
            size += len(chunk)
    return h.hexdigest(), size

def package_root(path: pathlib.Path):
    if path.suffix == ".zip":
        temp = pathlib.Path(tempfile.mkdtemp(prefix="mactools-plugin-catalog-"))
        with zipfile.ZipFile(path) as zf:
            zf.extractall(temp)
        roots = [p for p in temp.iterdir() if p.name.endswith(".mactoolsplugin")]
        if len(roots) != 1:
            raise SystemExit(f"{path} must contain exactly one .mactoolsplugin root")
        return roots[0]
    return path

entries = []
plugin_kit_versions = set()
for raw in packages:
    package_path = pathlib.Path(raw).expanduser().resolve()
    if not package_path.exists():
        raise SystemExit(f"Package not found: {package_path}")

    root = package_root(package_path)
    manifest_path = root / "plugin.json"
    if not manifest_path.exists():
        raise SystemExit(f"Missing plugin.json: {root}")

    manifest = json.loads(manifest_path.read_text())
    if "pluginKitVersion" not in manifest:
        raise SystemExit(f"Missing pluginKitVersion: {manifest_path}")
    manifest_plugin_kit_version = int(manifest["pluginKitVersion"])
    plugin_kit_versions.add(manifest_plugin_kit_version)
    if requested_plugin_kit_version is not None and manifest_plugin_kit_version != requested_plugin_kit_version:
        raise SystemExit(
            f"{manifest_path} uses pluginKitVersion {manifest_plugin_kit_version}, "
            f"but --plugin-kit-version is {requested_plugin_kit_version}"
        )
    digest, size = directory_metrics(package_path) if package_path.is_dir() else file_metrics(package_path)
    if mode == "debug":
        url = package_path.as_uri()
    else:
        url = base_url.rstrip("/") + "/" + package_path.name

    entries.append({
        "id": manifest["id"],
        "displayName": manifest.get("displayName", manifest["id"]),
        "summary": manifest.get("summary", manifest.get("displayName", manifest["id"])),
        "localizedMetadata": manifest.get("localizedMetadata"),
        "version": manifest["version"],
        "minimumHostVersion": manifest.get("minHostVersion", minimum_host_version),
        "pluginKitVersion": manifest_plugin_kit_version,
        "capabilities": manifest.get("capabilities", {
            "primaryPanel": False,
            "componentPanel": False,
            "configuration": False,
        }),
        "permissions": manifest.get("permissions", []),
        "package": {
            "url": url,
            "sha256": digest,
            "size": size,
        },
        "releaseNotesURL": manifest.get("releaseNotesURL") or release_notes_url or None,
        "category": manifest.get("category"),
        "releaseChannel": manifest.get("releaseChannel"),
    })

if requested_plugin_kit_version is None:
    if len(plugin_kit_versions) != 1:
        raise SystemExit(
            "Packages must use one pluginKitVersion: "
            + ", ".join(str(version) for version in sorted(plugin_kit_versions))
        )
    catalog_plugin_kit_version = next(iter(plugin_kit_versions))
else:
    catalog_plugin_kit_version = requested_plugin_kit_version

catalog = {
    "schemaVersion": 1,
    "catalogID": catalog_id,
    "generatedAt": datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
    "minimumHostVersion": minimum_host_version,
    "pluginKitVersion": catalog_plugin_kit_version,
    "plugins": sorted(entries, key=lambda entry: entry["id"]),
    "revoked": [],
}

output_path = pathlib.Path(output)
output_path.parent.mkdir(parents=True, exist_ok=True)
output_path.write_text(json.dumps(catalog, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
PY
