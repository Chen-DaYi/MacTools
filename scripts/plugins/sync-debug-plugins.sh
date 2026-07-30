#!/bin/zsh
set -euo pipefail

if [[ -z "${PYTHON3:-}" ]]; then
    if [[ -x /usr/bin/python3 ]]; then
        PYTHON3=/usr/bin/python3
    else
        PYTHON3=python3
    fi
fi
export PYTHON3

usage() {
    cat <<'USAGE'
Usage:
  sync-debug-plugins.sh --source-dir Plugins --products-dir build/DerivedData/Build/Products/Debug --output-dir build/LocalPlugins

Synchronizes Debug plugin bundles already built by the main MacTools scheme into
development .mactoolsplugin packages, generates a local debug catalog, and copies
the packages into the MacTools Dev installed plugin store.

This script does not run xcodebuild. Run it after the Debug app build.
USAGE
}

SOURCE_DIR=""
PRODUCTS_DIR=""
OUTPUT_DIR=""
INSTALL_DIR="$HOME/Library/Application Support/MacTools Dev/Plugins/Installed"
SKIP_INSTALL=0
PLUGIN_FILTERS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --source-dir)
            SOURCE_DIR="${2:-}"
            shift 2
            ;;
        --products-dir)
            PRODUCTS_DIR="${2:-}"
            shift 2
            ;;
        --output-dir)
            OUTPUT_DIR="${2:-}"
            shift 2
            ;;
        --install-dir)
            INSTALL_DIR="${2:-}"
            shift 2
            ;;
        --plugin)
            remaining_plugin_filters="${2:-}"
            while [[ -n "$remaining_plugin_filters" ]]; do
                raw_plugin_filter="${remaining_plugin_filters%%,*}"
                if [[ "$remaining_plugin_filters" == *,* ]]; then
                    remaining_plugin_filters="${remaining_plugin_filters#*,}"
                else
                    remaining_plugin_filters=""
                fi
                raw_plugin_filter="${raw_plugin_filter#"${raw_plugin_filter%%[![:space:]]*}"}"
                raw_plugin_filter="${raw_plugin_filter%"${raw_plugin_filter##*[![:space:]]}"}"
                [[ -n "$raw_plugin_filter" ]] && PLUGIN_FILTERS+=("$raw_plugin_filter")
            done
            shift 2
            ;;
        --skip-install)
            SKIP_INSTALL=1
            shift
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

if [[ -z "$SOURCE_DIR" || -z "$PRODUCTS_DIR" || -z "$OUTPUT_DIR" ]]; then
    usage >&2
    exit 1
fi

SOURCE_DIR="$(cd "$SOURCE_DIR" 2>/dev/null && pwd || true)"
if [[ -z "$SOURCE_DIR" || ! -d "$SOURCE_DIR" ]]; then
    echo "Plugin source directory not found: $SOURCE_DIR" >&2
    exit 1
fi

PRODUCTS_DIR="$(cd "$PRODUCTS_DIR" 2>/dev/null && pwd || true)"
if [[ -z "$PRODUCTS_DIR" || ! -d "$PRODUCTS_DIR" ]]; then
    echo "Debug build products directory not found. Run 'make build' first: $PRODUCTS_DIR" >&2
    exit 1
fi

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUTPUT_DIR="$(mkdir -p "$OUTPUT_DIR" && cd "$OUTPUT_DIR" && pwd)"
PACKAGES_DIR="$OUTPUT_DIR/Packages"
CATALOG_PATH="$OUTPUT_DIR/catalog.dev.json"
STATE_DIR="$OUTPUT_DIR/.sync-state"
MANIFEST_COPY_SCRIPT="$REPO_ROOT/scripts/plugins/copy-plugin-manifest.py"
APP_VERSION_CONFIG="$REPO_ROOT/Configs/AppVersion.xcconfig"
DEVELOPMENT_HOST_VERSION="$(
    "$PYTHON3" "$MANIFEST_COPY_SCRIPT" host-version \
        --app-version-config "$APP_VERSION_CONFIG"
)"

mkdir -p "$PACKAGES_DIR"
mkdir -p "$STATE_DIR"
if [[ "$SKIP_INSTALL" != "1" ]]; then
    mkdir -p "$INSTALL_DIR"
fi

copy_package_to_installed_store() {
    local package_path="$1"
    local plugin_id="$2"
    local destination="$INSTALL_DIR/$plugin_id.mactoolsplugin"
    local staging="$INSTALL_DIR/.$plugin_id.syncing.$$.mactoolsplugin"

    rm -rf "$staging"
    ditto "$package_path" "$staging"
    rm -rf "$destination"
    mv "$staging" "$destination"
}

discover_plugin_records() {
    local plugin_filters_serialized=""
    for plugin_filter in "${PLUGIN_FILTERS[@]-}"; do
        plugin_filters_serialized+=$'\n'"$plugin_filter"
    done

    "$PYTHON3" - "$SOURCE_DIR" "$PRODUCTS_DIR" "$plugin_filters_serialized" "$DEVELOPMENT_HOST_VERSION" <<'PY'
import hashlib
import json
import os
import pathlib
import sys

source_dir = pathlib.Path(sys.argv[1])
products_dir = pathlib.Path(sys.argv[2])
serialized_filters = sys.argv[3] if len(sys.argv) > 3 else ""
development_host_version = sys.argv[4]
filters = {item for item in serialized_filters.splitlines() if item}

def emit_error(message: str) -> None:
    print(message, file=sys.stderr)
    raise SystemExit(1)

def validate_field(value: str) -> str:
    if "\t" in value or "\n" in value:
        emit_error(f"Unsupported tab or newline in plugin sync field: {value!r}")
    return value

def discover_candidates() -> list[pathlib.Path]:
    if (source_dir / "plugin.json").is_file():
        return [source_dir]

    candidates = []
    for root, dirs, files in os.walk(source_dir):
        root_path = pathlib.Path(root)
        depth = len(root_path.relative_to(source_dir).parts)
        if depth >= 3:
            dirs[:] = []
        if "plugin.json" in files:
            candidates.append(root_path)

    return sorted(set(candidates), key=lambda path: path.name.lower())

def input_fingerprint(manifest: pathlib.Path, bundle: pathlib.Path) -> str:
    digest = hashlib.sha256()
    digest.update(b"debug-manifest-v1\0")
    digest.update(development_host_version.encode("utf-8"))
    digest.update(b"\0")

    def is_ignored(path: pathlib.Path) -> bool:
        relative_parts = path.relative_to(bundle).parts
        return "_CodeSignature" in relative_parts

    def update_file(label: str, path: pathlib.Path) -> None:
        stat = path.lstat()
        digest.update(label.encode("utf-8"))
        digest.update(b"\0file\0")
        digest.update(oct(stat.st_mode & 0o7777).encode("utf-8"))
        digest.update(b"\0")
        with path.open("rb") as file:
            for chunk in iter(lambda: file.read(1024 * 1024), b""):
                digest.update(chunk)
        digest.update(b"\0")

    def update_symlink(label: str, path: pathlib.Path) -> None:
        stat = path.lstat()
        digest.update(label.encode("utf-8"))
        digest.update(b"\0symlink\0")
        digest.update(oct(stat.st_mode & 0o7777).encode("utf-8"))
        digest.update(b"\0")
        digest.update(os.readlink(path).encode("utf-8"))
        digest.update(b"\0")

    update_file("plugin.json", manifest)

    for path in sorted(bundle.rglob("*"), key=lambda item: item.relative_to(bundle).as_posix()):
        if is_ignored(path):
            continue

        relative = path.relative_to(bundle).as_posix()
        if path.is_symlink():
            update_symlink(relative, path)
        elif path.is_file():
            update_file(relative, path)

    return digest.hexdigest()

records = []
for plugin_root in discover_candidates():
    manifest = plugin_root / "plugin.json"
    with manifest.open("r", encoding="utf-8") as file:
        data = json.load(file)

    plugin_id = data.get("id") or ""
    bundle_relative_path = data.get("bundleRelativePath") or ""
    if not plugin_id or not bundle_relative_path:
        emit_error(f"plugin.json must include id and bundleRelativePath: {manifest}")

    if filters and plugin_root.name not in filters and plugin_id not in filters:
        continue

    bundle_name = pathlib.Path(bundle_relative_path).name
    bundle_path = products_dir / bundle_name
    if not bundle_path.is_dir():
        emit_error(
            f"Built plugin bundle not found for {plugin_id}: {bundle_path}\n"
            "Run 'make build' and ensure the plugin target is included in the MacTools scheme."
        )

    records.append((
        str(plugin_root),
        str(manifest),
        plugin_id,
        bundle_relative_path,
        str(bundle_path),
        input_fingerprint(manifest, bundle_path),
    ))

if not records:
    if filters:
        emit_error(f"No plugin matched requested filters in {source_dir}: {' '.join(sorted(filters))}")
    emit_error(f"No plugins found in {source_dir}.")

for record in records:
    print("\t".join(validate_field(field) for field in record))
PY
}

state_file_for_plugin() {
    local plugin_id="$1"
    local safe_name
    safe_name="$(printf '%s' "$plugin_id" | tr -c 'A-Za-z0-9._-' '_')"
    printf '%s/%s.sha256\n' "$STATE_DIR" "$safe_name"
}

package_is_complete() {
    local package_path="$1"
    local bundle_relative_path="$2"

    [[ -f "$package_path/plugin.json" && -d "$package_path/$bundle_relative_path" ]]
}

packages=()
synced_count=0
installed_count=0
skipped_count=0

echo "Discovering Debug plugin bundles..."
if plugin_records="$(discover_plugin_records)"; then
    :
else
    discovery_status=$?
    exit "$discovery_status"
fi

echo "Synchronizing Debug plugin packages..."
while IFS=$'\t' read -r plugin_root manifest plugin_id bundle_relative_path bundle_path fingerprint; do
    [[ -n "$plugin_root" ]] || continue

    package_path="$PACKAGES_DIR/$plugin_id.mactoolsplugin"
    state_path="$(state_file_for_plugin "$plugin_id")"
    previous_fingerprint=""
    package_synced=0
    if [[ -f "$state_path" ]]; then
        previous_fingerprint="$(<"$state_path")"
    fi

    if [[ "$fingerprint" != "$previous_fingerprint" ]] || ! package_is_complete "$package_path" "$bundle_relative_path"; then
        rm -rf "$package_path"
        mkdir -p "$package_path/$(dirname "$bundle_relative_path")"
        "$PYTHON3" "$MANIFEST_COPY_SCRIPT" copy \
            --source "$manifest" \
            --destination "$package_path/plugin.json" \
            --configuration Debug \
            --app-version-config "$APP_VERSION_CONFIG"
        ditto "$bundle_path" "$package_path/$bundle_relative_path"
        printf '%s\n' "$fingerprint" > "$state_path"
        synced_count=$((synced_count + 1))
        package_synced=1
    else
        skipped_count=$((skipped_count + 1))
    fi

    if [[ "$SKIP_INSTALL" != "1" ]]; then
        install_path="$INSTALL_DIR/$plugin_id.mactoolsplugin"
        if [[ "$package_synced" == "1" || ! -d "$install_path" ]]; then
            copy_package_to_installed_store "$package_path" "$plugin_id"
            installed_count=$((installed_count + 1))
        fi
    fi

    packages+=("$package_path")
done <<< "$plugin_records"

plugin_filter_count=0
for _plugin_filter in "${PLUGIN_FILTERS[@]-}"; do
    plugin_filter_count=$((plugin_filter_count + 1))
done

if [[ ${#packages[@]} -eq 0 ]]; then
    if [[ "$plugin_filter_count" -gt 0 ]]; then
        echo "No plugin matched requested filters in $SOURCE_DIR: ${PLUGIN_FILTERS[*]-}" >&2
    else
        echo "No plugins found in $SOURCE_DIR." >&2
    fi
    exit 1
fi

catalog_args=()
for package in "${packages[@]}"; do
    catalog_args+=(--package "$package")
done

if [[ "$synced_count" -gt 0 || ! -f "$CATALOG_PATH" ]]; then
    echo "Generating local plugin catalog..."
    "$REPO_ROOT/scripts/plugins/generate-plugin-catalog.sh" \
        --mode debug \
        --output "$CATALOG_PATH" \
        "${catalog_args[@]}"
fi

echo "Synced $synced_count changed debug plugin package(s); skipped $skipped_count unchanged."
echo "Catalog: $CATALOG_PATH"
if [[ "$SKIP_INSTALL" != "1" ]]; then
    echo "Installed $installed_count debug plugin package(s)."
    echo "Installed store: $INSTALL_DIR"
fi
