#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage:
  publish-plugin-release.sh --repo owner/repo --tag plugins-2026.05.17 --asset Demo.mactoolsplugin.zip [--asset More.mactoolsplugin.zip]

Requires GitHub CLI authenticated with release upload permissions.
Use --allow-empty for catalog-only plugin releases with no package assets.
USAGE
}

REPO=""
TAG=""
TITLE=""
NOTES_FILE=""
PRERELEASE=0
ALLOW_EMPTY=0
ASSETS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo)
            REPO="${2:-}"
            shift 2
            ;;
        --tag)
            TAG="${2:-}"
            shift 2
            ;;
        --title)
            TITLE="${2:-}"
            shift 2
            ;;
        --notes-file)
            NOTES_FILE="${2:-}"
            shift 2
            ;;
        --prerelease)
            PRERELEASE=1
            shift
            ;;
        --allow-empty)
            ALLOW_EMPTY=1
            shift
            ;;
        --asset)
            ASSETS+=("${2:-}")
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

if [[ -z "$REPO" || -z "$TAG" ]]; then
    usage >&2
    exit 1
fi

if [[ ${#ASSETS[@]} -eq 0 && "$ALLOW_EMPTY" != "1" ]]; then
    echo "At least one --asset is required unless --allow-empty is set." >&2
    usage >&2
    exit 1
fi

command -v gh >/dev/null || { echo "GitHub CLI 'gh' is required." >&2; exit 1; }

for asset in "${ASSETS[@]}"; do
    [[ -f "$asset" ]] || { echo "Release asset not found: $asset" >&2; exit 1; }
done

TITLE="${TITLE:-$TAG}"

release_args=(--repo "$REPO" --title "$TITLE" --latest=false)
if [[ -n "$NOTES_FILE" ]]; then
    [[ -f "$NOTES_FILE" ]] || { echo "Release notes file not found: $NOTES_FILE" >&2; exit 1; }
    release_args+=(--notes-file "$NOTES_FILE")
else
    release_args+=(--notes "")
fi
if [[ "$PRERELEASE" == "1" ]]; then
    release_args+=(--prerelease)
fi

if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    if [[ ${#ASSETS[@]} -gt 0 ]]; then
        gh release upload "$TAG" "${ASSETS[@]}" --repo "$REPO" --clobber
    fi
    gh release edit "$TAG" "${release_args[@]}"
else
    if [[ ${#ASSETS[@]} -gt 0 ]]; then
        gh release create "$TAG" "${ASSETS[@]}" "${release_args[@]}"
    else
        gh release create "$TAG" "${release_args[@]}"
    fi
fi
