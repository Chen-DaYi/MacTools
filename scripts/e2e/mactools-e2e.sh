#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
REPO_ROOT="${SCRIPT_DIR:h:h}"
FIXTURE_TOOL="$SCRIPT_DIR/MacToolsE2EFixture.swift"
KEY_SENDER_TOOL="$SCRIPT_DIR/MacToolsE2EKeySender.swift"
CAPTURE_RECT_TOOL="$SCRIPT_DIR/MacToolsE2ECaptureRect.swift"
PRIVACY_HELPER_SOURCE="$SCRIPT_DIR/MacToolsE2EPrivacyHelper.swift"
PRIVACY_RECORDER_SOURCE="$SCRIPT_DIR/MacToolsE2ERecorder.swift"
SCENARIO_MANIFEST="$SCRIPT_DIR/scenarios.json"
HARNESS_PATH="$SCRIPT_DIR/mactools-e2e.sh"
APP_PATH="${MACTOOLS_E2E_APP_PATH:-$HOME/Applications/MacTools Dev.app}"
PLUGIN_INSTALL_DIR="${MACTOOLS_E2E_PLUGIN_DIR:-$HOME/Library/Application Support/MacTools Dev/Plugins/Installed}"
ARTIFACT_ROOT="${MACTOOLS_E2E_ARTIFACT_ROOT:-$REPO_ROOT/build/E2EArtifacts}"
BUILT_APP_PATH="$REPO_ROOT/build/DerivedData/Build/Products/Debug/${APP_PATH:t}"
PYTHON3="${PYTHON3:-/usr/bin/python3}"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

if [[ -n "${DEVELOPER_DIR:-}" ]]; then
    E2E_DEVELOPER_DIR="$DEVELOPER_DIR"
elif [[ -d /Applications/Xcode-beta.app/Contents/Developer ]]; then
    E2E_DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
else
    E2E_DEVELOPER_DIR="$(xcode-select -p)"
fi

usage() {
    print -r -- "Usage: $0 <command> [arguments]"
    print -r -- ""
    print -r -- "Commands:"
    print -r -- "  preflight [output.json]               Verify stable app, signing, plugins, and tools"
    print -r -- "  prepare                               Back up preferences, seed safe fixtures, and launch"
    print -r -- "  upgrade <session-dir>                 Reset checkpoints and install the latest fixture"
    print -r -- "  reseed <session-dir>                  Reset fixture state without replacing its backup"
    print -r -- "  resume <session-dir>                  Revalidate and reopen a prepared session"
    print -r -- "  rebuild <session-dir> [--dry-run]     Rebuild and replace the stable signed app"
    print -r -- "  audit <session-dir>                   Save and validate fixture state"
    print -r -- "  checkpoint <session-dir> <name> <pass|fail|pending> [detail]"
    print -r -- "  shortcut <session-dir> <open-settings|action-grid|dashboard|safe-workflow> [--dry-run]"
    print -r -- "  pointer-click <session-dir> <reference-width> <reference-height> <x> <y> [--dry-run]"
    print -r -- "  input-select-all <session-dir> [--dry-run]"
    print -r -- "  input-text <session-dir> <text> [--dry-run]"
    print -r -- "  privacy-helper <session-dir> <primary|secondary> [--dry-run]"
    print -r -- "  record <session-dir> [seconds] [--dry-run]"
    print -r -- "  record-pack <session-dir> <pack-id> [seconds] [--dry-run]"
    print -r -- "  wait-recording-ready <session-dir> [label] [seconds]"
    print -r -- "  start-recording <session-dir> [label]"
    print -r -- "  stop-recording <session-dir> [label]"
    print -r -- "  verify-code <session-dir> [--dry-run]   Run migration and injected-trackpad suites"
    print -r -- "  scenarios [pack-id]                   Print all scenario packs or one pack"
    print -r -- "  collect <session-dir>                 Build report.json and diagnostic artifacts"
    print -r -- "  restore <session-dir>                 Restore preferences and relaunch the app"
    print -r -- "  self-test                             Validate the fixture tool in an isolated domain"
}

require_app() {
    if [[ ! -d "$APP_PATH" ]]; then
        print -u2 -r -- "error: stable app not found at $APP_PATH"
        return 1
    fi
}

plist_value() {
    /usr/libexec/PlistBuddy -c "Print :$2" "$1"
}

app_bundle_identifier() {
    plist_value "$APP_PATH/Contents/Info.plist" CFBundleIdentifier
}

app_executable() {
    local executable_name
    executable_name="$(plist_value "$APP_PATH/Contents/Info.plist" CFBundleExecutable)"
    print -r -- "$APP_PATH/Contents/MacOS/$executable_name"
}

extension_bundle_identifier() {
    local extension_plist="$APP_PATH/Contents/PlugIns/RightClickFinderSync.appex/Contents/Info.plist"
    [[ -f "$extension_plist" ]] || return 0
    plist_value "$extension_plist" CFBundleIdentifier
}

fixture_tool() {
    env DEVELOPER_DIR="$E2E_DEVELOPER_DIR" xcrun swift "$FIXTURE_TOOL" "$@"
}

key_sender_tool() {
    env DEVELOPER_DIR="$E2E_DEVELOPER_DIR" xcrun swift "$KEY_SENDER_TOOL" "$@"
}

capture_rect_tool() {
    env DEVELOPER_DIR="$E2E_DEVELOPER_DIR" xcrun swift "$CAPTURE_RECT_TOOL" "$@"
}

privacy_recorder_binary() {
    local session_dir="$1"
    print -r -- "$session_dir/privacy-recorder/MacToolsE2ERecorder"
}

build_privacy_recorder() {
    local session_dir="$1"
    [[ -f "$PRIVACY_RECORDER_SOURCE" ]] || {
        print -u2 -r -- "error: application-filtered recorder source is unavailable"
        return 1
    }
    local binary
    binary="$(privacy_recorder_binary "$session_dir")"
    mkdir -p "${binary:h}"
    env DEVELOPER_DIR="$E2E_DEVELOPER_DIR" xcrun swiftc \
        -parse-as-library -suppress-warnings \
        -framework AppKit -framework AVFoundation -framework ScreenCaptureKit \
        "$PRIVACY_RECORDER_SOURCE" -o "$binary"
    /usr/bin/codesign --force --sign - "$binary"
}

ensure_privacy_recorder() {
    local session_dir="$1"
    local binary
    binary="$(privacy_recorder_binary "$session_dir")"
    if [[ ! -x "$binary" || "$PRIVACY_RECORDER_SOURCE" -nt "$binary" ]]; then
        build_privacy_recorder "$session_dir"
    fi
}

privacy_recorder_tool() {
    local session_dir="$1"
    shift
    "$(privacy_recorder_binary "$session_dir")" "$@"
}

input_driver_binary() {
    local session_dir="$1"
    print -r -- "$session_dir/input-driver/MacToolsE2EInputDriver"
}

build_input_driver() {
    local session_dir="$1"
    local binary
    binary="$(input_driver_binary "$session_dir")"
    mkdir -p "${binary:h}"
    env DEVELOPER_DIR="$E2E_DEVELOPER_DIR" xcrun swiftc \
        -framework ApplicationServices -framework CoreGraphics \
        "$KEY_SENDER_TOOL" -o "$binary"
    /usr/bin/codesign --force --sign - "$binary"
}

ensure_input_driver() {
    local session_dir="$1"
    local binary
    binary="$(input_driver_binary "$session_dir")"
    if [[ ! -x "$binary" || "$KEY_SENDER_TOOL" -nt "$binary" ]]; then
        build_input_driver "$session_dir"
    fi
}

input_driver_tool() {
    local session_dir="$1"
    shift
    "$(input_driver_binary "$session_dir")" "$@"
}

privacy_helper_app_path() {
    local session_dir="$1"
    local variant="$2"
    print -r -- "$session_dir/privacy-helpers/MacTools E2E ${variant:u} Helper.app"
}

build_privacy_helpers() {
    local session_dir="$1"
    [[ -f "$PRIVACY_HELPER_SOURCE" ]] || {
        print -u2 -r -- "error: privacy-safe helper source is unavailable"
        return 1
    }
    local helper_root="$session_dir/privacy-helpers"
    local executable="$helper_root/MacToolsE2EPrivacyHelper"
    mkdir -p "$helper_root"
    env DEVELOPER_DIR="$E2E_DEVELOPER_DIR" xcrun swiftc \
        -parse-as-library -framework AppKit "$PRIVACY_HELPER_SOURCE" -o "$executable"

    local variant app bundle_id title accent
    for variant in primary secondary backdrop; do
        app="$(privacy_helper_app_path "$session_dir" "$variant")"
        if [[ "$variant" == primary ]]; then
            bundle_id="com.jennymedia.mactools.e2e-helper.primary"
            title="MacTools E2E Primary Helper"
            accent="orange"
        elif [[ "$variant" == secondary ]]; then
            bundle_id="com.jennymedia.mactools.e2e-helper.secondary"
            title="MacTools E2E Secondary Helper"
            accent="blue"
        else
            bundle_id="com.jennymedia.mactools.e2e-helper.backdrop"
            title="MacTools E2E Privacy Backdrop"
            accent="blue"
        fi
        mkdir -p "$app/Contents/MacOS"
        /usr/bin/ditto "$executable" "$app/Contents/MacOS/MacToolsE2EPrivacyHelper"
        "$PYTHON3" - "$app/Contents/Info.plist" "$bundle_id" "$title" "$accent" <<'PY'
import plistlib
import sys

path, bundle_id, title, accent = sys.argv[1:]
payload = {
    "CFBundleDevelopmentRegion": "en",
    "CFBundleDisplayName": title,
    "CFBundleExecutable": "MacToolsE2EPrivacyHelper",
    "CFBundleIdentifier": bundle_id,
    "CFBundleInfoDictionaryVersion": "6.0",
    "CFBundleName": title,
    "CFBundlePackageType": "APPL",
    "CFBundleShortVersionString": "1.0",
    "CFBundleVersion": "1",
    "LSMinimumSystemVersion": "14.0",
    "MacToolsE2EAccent": accent,
    "MacToolsE2ETitle": title,
    "NSHighResolutionCapable": True,
}
with open(path, "wb") as handle:
    plistlib.dump(payload, handle)
PY
        /usr/bin/codesign --force --sign - "$app"
        "$LSREGISTER" -f "$app"
    done
}

ensure_privacy_helpers() {
    local session_dir="$1"
    local primary secondary backdrop
    primary="$(privacy_helper_app_path "$session_dir" primary)"
    secondary="$(privacy_helper_app_path "$session_dir" secondary)"
    backdrop="$(privacy_helper_app_path "$session_dir" backdrop)"
    if [[ ! -d "$primary" || ! -d "$secondary" || ! -d "$backdrop" ]]; then
        build_privacy_helpers "$session_dir"
        return
    fi
    "$LSREGISTER" -f "$primary"
    "$LSREGISTER" -f "$secondary"
    "$LSREGISTER" -f "$backdrop"
}

recording_visibility_state_path() {
    local session_dir="$1"
    print -r -- "$session_dir/privacy-recorder/hidden-application-pids.txt"
}

restore_recording_visibility() {
    local session_dir="$1"
    local state_path executable
    state_path="$(recording_visibility_state_path "$session_dir")"
    executable="$(privacy_helper_app_path "$session_dir" backdrop)/Contents/MacOS/MacToolsE2EPrivacyHelper"
    if [[ -s "$state_path" && -x "$executable" ]]; then
        "$executable" --restore-visibility "$state_path"
    fi
    rm -f -- "$state_path"
}

stop_privacy_helpers() {
    local session_dir="$1"
    local variant app executable output
    local cleanup_failed=false
    for variant in primary secondary backdrop; do
        app="$(privacy_helper_app_path "$session_dir" "$variant")"
        executable="$app/Contents/MacOS/MacToolsE2EPrivacyHelper"
        output="$(/bin/ps -axo pid=,command= | awk -v executable="$executable" '
            {
                pid = $1
                sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "", $0)
                if ($0 == executable || index($0, executable " ") == 1) print pid
            }
        ')"
        if [[ -n "$output" ]]; then
            local -a helper_pids
            helper_pids=("${(@f)output}")
            /bin/kill -TERM -- "${helper_pids[@]}"
            local attempt=0
            for attempt in {1..50}; do
                local still_running=false
                local helper_pid=""
                for helper_pid in "${helper_pids[@]}"; do
                    if /bin/kill -0 "$helper_pid" >/dev/null 2>&1; then
                        still_running=true
                        break
                    fi
                done
                [[ "$still_running" == false ]] && break
                sleep 0.1
            done
            for helper_pid in "${helper_pids[@]}"; do
                if /bin/kill -0 "$helper_pid" >/dev/null 2>&1; then
                    cleanup_failed=true
                    /bin/kill -KILL "$helper_pid" >/dev/null 2>&1 || true
                fi
            done
        fi
    done
    sleep 0.25
    [[ "$cleanup_failed" == false ]] \
        || print -u2 -r -- "warning: privacy helper required forced termination"
    restore_recording_visibility "$session_dir"
    return 0
}

matching_pids() {
    local executable
    executable="$(app_executable)"
    pgrep -f -x "$executable" || true
}

matching_built_pids() {
    [[ -d "$BUILT_APP_PATH" ]] || return 0
    local executable_name executable
    executable_name="$(plist_value "$BUILT_APP_PATH/Contents/Info.plist" CFBundleExecutable)"
    executable="$BUILT_APP_PATH/Contents/MacOS/$executable_name"
    pgrep -f -x "$executable" || true
}

stop_app() {
    local output
    output="$(matching_pids)"
    [[ -n "$output" ]] || return 0

    local -a pids
    pids=("${(@f)output}")
    /bin/kill -TERM -- "${pids[@]}"

    local attempt
    for attempt in {1..50}; do
        [[ -z "$(matching_pids)" ]] && return 0
        sleep 0.1
    done
    print -u2 -r -- "error: MacTools Dev did not terminate gracefully"
    return 1
}

stop_built_app() {
    local output
    output="$(matching_built_pids)"
    [[ -n "$output" ]] || return 0

    local -a pids
    pids=("${(@f)output}")
    /bin/kill -TERM -- "${pids[@]}"

    local attempt
    for attempt in {1..50}; do
        [[ -z "$(matching_built_pids)" ]] && return 0
        sleep 0.1
    done
    print -u2 -r -- "error: Derived Data MacTools test host did not terminate gracefully"
    return 1
}

restore_stable_launch_services_registration() {
    [[ -x "$LSREGISTER" ]] || {
        print -u2 -r -- "error: lsregister is unavailable at $LSREGISTER"
        return 1
    }
    if [[ -d "$BUILT_APP_PATH" ]]; then
        "$LSREGISTER" -u "$BUILT_APP_PATH" >/dev/null 2>&1 || true
    fi
    "$LSREGISTER" -f "$APP_PATH" >/dev/null
}

restore_stable_app_after_code_verification() {
    stop_built_app || true
    restore_stable_launch_services_registration || true
    if [[ -z "$(matching_pids)" ]]; then
        /usr/bin/open -a "$APP_PATH" "mactools-dev://app/settings/plugins/marketplace"
    fi
}

expected_team_identifier() {
    if [[ -n "${MACTOOLS_E2E_TEAM_ID:-}" ]]; then
        print -r -- "$MACTOOLS_E2E_TEAM_ID"
        return
    fi
    local config="$REPO_ROOT/LocalConfig.xcconfig"
    [[ -f "$config" ]] || return 0
    awk -F= '/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=/{value=$2; gsub(/[[:space:]]/, "", value); print value; exit}' "$config"
}

write_preflight_json() {
    local output_path="$1"
    local bundle_id="$2"
    local team_id="$3"
    local expected_team_id="$4"
    local authority="$5"
    local plugin_count="$6"
    local process_count="$7"
    local event_posting_access="$8"
    local conflicting_process_count="$9"
    local trackpad_listener_lease_owned="${10}"
    local passed="${11}"

    mkdir -p "${output_path:h}"
    "$PYTHON3" - "$output_path" "$APP_PATH" "$bundle_id" "$team_id" "$expected_team_id" \
        "$authority" "$plugin_count" "$process_count" "$event_posting_access" \
        "$conflicting_process_count" "$trackpad_listener_lease_owned" "$passed" <<'PY'
import json
import sys
from datetime import datetime, timezone

(
    output_path,
    app_path,
    bundle_id,
    team_id,
    expected_team_id,
    authority,
    plugin_count,
    process_count,
    event_posting_access,
    conflicting_process_count,
    trackpad_listener_lease_owned,
    passed,
) = sys.argv[1:]
listener_owned = trackpad_listener_lease_owned == "true"
payload = {
    "timestamp": datetime.now(timezone.utc).isoformat(),
    "passed": passed == "true",
    "appPath": app_path,
    "bundleIdentifier": bundle_id,
    "teamIdentifier": team_id,
    "expectedTeamIdentifier": expected_team_id or None,
    "authority": authority,
    "installedPluginCount": int(plugin_count),
    "matchingProcessCount": int(process_count),
    "derivedDataProcessCount": int(conflicting_process_count),
    "eventPostingAccess": event_posting_access == "true",
    "recorder": "scripts/e2e/MacToolsE2ERecorder.swift",
    "recorderPrivacyFilter": "application-allowlist",
    "recorderEnvironmentPreparation": "hide-and-restore-unrelated-regular-apps",
    "transcoder": "/opt/homebrew/bin/ffmpeg",
    "permissionState": "granted" if listener_owned else "unverified",
    "permissionEvidence": {
        "trackpadListenerLeaseOwnedByStableApp": listener_owned,
        "meaning": (
            "The active Trackpad Gestures listener starts only after MacTools observes both "
            "Accessibility and Input Monitoring permission."
            if listener_owned
            else "No active Trackpad Gestures listener was observed; this does not prove denial."
        ),
    },
}
with open(output_path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
}

preflight() {
    require_app
    local output_path="${1:-$ARTIFACT_ROOT/preflight-latest.json}"
    local bundle_id
    bundle_id="$(app_bundle_identifier)"

    local signature_output
    signature_output="$(codesign -dv --verbose=4 "$APP_PATH" 2>&1)"
    local team_id authority expected_team
    team_id="$(print -r -- "$signature_output" | awk -F= '/^TeamIdentifier=/{print $2; exit}')"
    authority="$(print -r -- "$signature_output" | awk -F= '/^Authority=Apple Development:/{print $2; exit}')"
    expected_team="$(expected_team_identifier)"

    local plugin_count=0
    if [[ -d "$PLUGIN_INSTALL_DIR" ]]; then
        plugin_count="$(find "$PLUGIN_INSTALL_DIR" -maxdepth 1 -type d -name '*.mactoolsplugin' | wc -l | tr -d ' ')"
    fi
    local process_count=0
    local process_output
    process_output="$(matching_pids)"
    if [[ -n "$process_output" ]]; then
        process_count="$(print -r -- "$process_output" | wc -l | tr -d ' ')"
    fi
    local conflicting_process_count=0
    local conflicting_process_output
    conflicting_process_output="$(matching_built_pids)"
    if [[ -n "$conflicting_process_output" ]]; then
        conflicting_process_count="$(print -r -- "$conflicting_process_output" | wc -l | tr -d ' ')"
    fi
    local event_posting_access=false
    if key_sender_tool check >/dev/null 2>&1; then
        event_posting_access=true
    fi
    local trackpad_listener_lease_owned=false
    local listener_lock="${TMPDIR:-/tmp}"
    listener_lock="${listener_lock%/}/$bundle_id.trackpad-gestures.listener.lock"
    if [[ -f "$listener_lock" && -n "$process_output" ]]; then
        local listener_owners
        listener_owners="$(/usr/sbin/lsof -t -- "$listener_lock" 2>/dev/null || true)"
        local stable_pid
        for stable_pid in "${(@f)process_output}"; do
            if print -r -- "$listener_owners" | grep -q -x "$stable_pid"; then
                trackpad_listener_lease_owned=true
                break
            fi
        done
    fi

    local -a failures
    failures=()
    codesign --verify --deep --strict "$APP_PATH" 2>/dev/null || failures+=("strict code-signature verification failed")
    [[ -n "$team_id" ]] || failures+=("Apple Development team identifier is missing")
    [[ -n "$authority" ]] || failures+=("Apple Development signing authority is missing")
    if [[ -n "$expected_team" && "$team_id" != "$expected_team" ]]; then
        failures+=("team identifier $team_id does not match expected $expected_team")
    fi
    [[ "$APP_PATH" != *"/build/"* ]] || failures+=("app path is not stable")
    (( plugin_count > 0 )) || failures+=("no installed Debug plugin packages were found")
    (( process_count <= 1 )) || failures+=("more than one stable-path app instance is running")
    (( conflicting_process_count == 0 )) \
        || failures+=("a Derived Data MacTools test host is still running")
    [[ -f "$CAPTURE_RECT_TOOL" ]] || failures+=("private capture rectangle helper is unavailable")
    [[ -f "$PRIVACY_RECORDER_SOURCE" ]] || failures+=("application-filtered recorder is unavailable")
    [[ -x /opt/homebrew/bin/ffmpeg ]] || failures+=("ffmpeg is unavailable")

    local passed=true
    (( ${#failures[@]} == 0 )) || passed=false
    write_preflight_json \
        "$output_path" "$bundle_id" "$team_id" "$expected_team" "$authority" \
        "$plugin_count" "$process_count" "$event_posting_access" \
        "$conflicting_process_count" "$trackpad_listener_lease_owned" "$passed"

    print -r -- "App: $APP_PATH"
    print -r -- "Bundle: $bundle_id"
    print -r -- "Team: $team_id"
    print -r -- "Authority: $authority"
    print -r -- "Installed plugins: $plugin_count"
    print -r -- "Running instances: $process_count"
    print -r -- "Derived Data test hosts: $conflicting_process_count"
    print -r -- "Synthetic shortcut access: $event_posting_access"
    print -r -- "Trackpad listener permission evidence: $trackpad_listener_lease_owned"
    print -r -- "Report: $output_path"

    if [[ "$passed" != true ]]; then
        local failure
        for failure in "${failures[@]}"; do
            print -u2 -r -- "error: $failure"
        done
        return 1
    fi
}

domain_exists() {
    defaults read "$1" >/dev/null 2>&1
}

save_domain() {
    local domain="$1"
    local output="$2"
    if domain_exists "$domain"; then
        defaults export "$domain" "$output" >/dev/null
        return 0
    fi
    return 1
}

restore_domain() {
    local domain="$1"
    local existed="$2"
    local backup="$3"
    if [[ "$existed" == true ]]; then
        [[ -f "$backup" ]] || {
            print -u2 -r -- "error: missing preferences backup $backup"
            return 1
        }
        defaults import "$domain" "$backup" >/dev/null
    else
        defaults delete "$domain" >/dev/null 2>&1 || true
    fi
}

write_session_metadata() {
    local metadata="$1"
    local bundle_id="$2"
    local extension_id="$3"
    local had_preferences="$4"
    local had_extension_preferences="$5"

    plutil -create xml1 "$metadata"
    plutil -insert appPath -string "$APP_PATH" "$metadata"
    plutil -insert bundleIdentifier -string "$bundle_id" "$metadata"
    plutil -insert extensionBundleIdentifier -string "$extension_id" "$metadata"
    plutil -insert hadPreferences -bool "$had_preferences" "$metadata"
    plutil -insert hadExtensionPreferences -bool "$had_extension_preferences" "$metadata"
    plutil -insert preparedAt -date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$metadata"
}

write_pending_checkpoints() {
    local output="$1"
    "$PYTHON3" - "$output" "$SCENARIO_MANIFEST" <<'PY'
import json
import sys

with open(sys.argv[2], encoding="utf-8") as handle:
    manifest = json.load(handle)
names = [
    name
    for pack in manifest["packs"]
    for name in pack["checkpoints"]
]
if len(names) != len(set(names)):
    raise SystemExit("scenario manifest contains duplicate checkpoint names")
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump({name: {"status": "pending", "detail": ""} for name in names}, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
}

print_scenarios() {
    local pack_id="${1:-}"
    "$PYTHON3" - "$SCENARIO_MANIFEST" "$pack_id" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    manifest = json.load(handle)
pack_id = sys.argv[2]
if not pack_id:
    print(json.dumps(manifest, indent=2, sort_keys=True))
    raise SystemExit(0)
for pack in manifest["packs"]:
    if pack["id"] == pack_id:
        print(json.dumps(pack, indent=2, sort_keys=True))
        raise SystemExit(0)
raise SystemExit(f"unknown scenario pack: {pack_id}")
PY
}

recording_start_route() {
    local pack_id="$1"
    "$PYTHON3" - "$SCENARIO_MANIFEST" "$pack_id" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    manifest = json.load(handle)
for pack in manifest["packs"]:
    if pack["id"] == sys.argv[2]:
        print(pack.get("recordingStartRoute", "settings/features/automation"))
        raise SystemExit(0)
raise SystemExit(f"unknown scenario pack: {sys.argv[2]}")
PY
}

recording_marker_path() {
    local session_dir="${1:A}"
    local label="${2:-}"
    local marker="$3"
    local base_name="screencast"
    [[ -z "$label" ]] || base_name="screencast.$label"
    print -r -- "$session_dir/privacy-recorder/$base_name.$marker"
}

wait_recording_ready() {
    local session_dir="$1"
    local label="${2:-}"
    local timeout="${3:-15}"
    [[ "$timeout" == <-> ]] && (( timeout >= 1 && timeout <= 60 )) || {
        print -u2 -r -- "error: ready timeout must be between 1 and 60 seconds"
        return 1
    }
    local ready_marker
    ready_marker="$(recording_marker_path "$session_dir" "$label" ready)"
    local attempt
    for (( attempt = 1; attempt <= timeout * 10; attempt++ )); do
        if [[ -f "$ready_marker" ]]; then
            print -r -- "recording-ready=$ready_marker"
            return 0
        fi
        sleep 0.1
    done
    print -u2 -r -- "error: recorder did not become ready within $timeout seconds"
    return 1
}

start_recording() {
    local session_dir="$1"
    local label="${2:-}"
    local start_marker
    start_marker="$(recording_marker_path "$session_dir" "$label" start)"
    mkdir -p "${start_marker:h}"
    /usr/bin/touch "$start_marker"
    print -r -- "recording-start-requested=$start_marker"
}

stop_recording() {
    local session_dir="$1"
    local label="${2:-}"
    local stop_marker
    stop_marker="$(recording_marker_path "$session_dir" "$label" stop)"
    mkdir -p "${stop_marker:h}"
    /usr/bin/touch "$stop_marker"
    print -r -- "recording-stop-requested=$stop_marker"
}

resume_session() {
    local session_dir="$1"
    [[ -f "$session_dir/session.plist" ]] || {
        print -u2 -r -- "error: invalid E2E session directory $session_dir"
        return 1
    }
    local prepared_app_path
    prepared_app_path="$(session_value "$session_dir" appPath)"
    [[ "$prepared_app_path" == "$APP_PATH" ]] || {
        print -u2 -r -- "error: session app path $prepared_app_path does not match $APP_PATH"
        return 1
    }

    ensure_privacy_helpers "$session_dir"
    preflight "$session_dir/preflight.json"
    audit_session "$session_dir" >/dev/null
    /usr/bin/open -a "$APP_PATH" "mactools-dev://app/settings/plugins/marketplace"

    "$PYTHON3" - "$session_dir/ui-checkpoints.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    checkpoints = json.load(handle)
pending = sorted(name for name, item in checkpoints.items() if item["status"] != "pass")
print("Pending checkpoints: " + (", ".join(pending) if pending else "none"))
PY
    print -r -- "Recording command: $HARNESS_PATH record '$session_dir' 90"
    print -r -- "Restore command: $HARNESS_PATH restore '$session_dir'"
}

rebuild_session() {
    local session_dir="$1"
    local mode="${2:-}"
    [[ -f "$session_dir/session.plist" ]] || {
        print -u2 -r -- "error: invalid E2E session directory $session_dir"
        return 1
    }
    local prepared_app_path expected_bundle_id
    prepared_app_path="$(session_value "$session_dir" appPath)"
    expected_bundle_id="$(session_value "$session_dir" bundleIdentifier)"
    [[ "$prepared_app_path" == "$APP_PATH" ]] || {
        print -u2 -r -- "error: session app path $prepared_app_path does not match $APP_PATH"
        return 1
    }

    print -r -- "env DEVELOPER_DIR='$E2E_DEVELOPER_DIR' make -C '$REPO_ROOT' sync-debug-plugins"
    print -r -- "Replace '$APP_PATH' from '$BUILT_APP_PATH'"
    if [[ "$mode" == --dry-run ]]; then
        return
    fi

    env DEVELOPER_DIR="$E2E_DEVELOPER_DIR" make -C "$REPO_ROOT" sync-debug-plugins
    [[ -d "$BUILT_APP_PATH" ]] || {
        print -u2 -r -- "error: rebuilt app not found at $BUILT_APP_PATH"
        return 1
    }

    mkdir -p "$ARTIFACT_ROOT"
    local install_stage staged_app
    install_stage="$(mktemp -d "$ARTIFACT_ROOT/install-staging.XXXXXX")"
    staged_app="$install_stage/${APP_PATH:t}"
    /usr/bin/ditto --rsrc --extattr --acl "$BUILT_APP_PATH" "$staged_app"
    codesign --verify --deep --strict "$staged_app"

    local staged_bundle_id staged_signature staged_team expected_team
    staged_bundle_id="$(plist_value "$staged_app/Contents/Info.plist" CFBundleIdentifier)"
    staged_signature="$(codesign -dv --verbose=4 "$staged_app" 2>&1)"
    staged_team="$(print -r -- "$staged_signature" | awk -F= '/^TeamIdentifier=/{print $2; exit}')"
    expected_team="$(expected_team_identifier)"
    [[ "$staged_bundle_id" == "$expected_bundle_id" ]] || {
        print -u2 -r -- "error: rebuilt bundle identifier $staged_bundle_id does not match $expected_bundle_id"
        return 1
    }
    [[ -n "$staged_team" && ( -z "$expected_team" || "$staged_team" == "$expected_team" ) ]] || {
        print -u2 -r -- "error: rebuilt Team ID $staged_team does not match $expected_team"
        return 1
    }

    stop_app
    codesign -d -r- "$APP_PATH" >"$session_dir/designated-requirement.before-rebuild.txt" 2>&1
    local stamp backup_app
    stamp="$(date -u +%Y%m%d-%H%M%S)"
    backup_app="$session_dir/app-before-rebuild-$stamp.app"
    /bin/mv "$APP_PATH" "$backup_app"
    if /bin/mv "$staged_app" "$APP_PATH"; then
        /bin/rmdir "$install_stage"
    else
        /bin/mv "$backup_app" "$APP_PATH"
        return 1
    fi

    codesign -d -r- "$APP_PATH" >"$session_dir/designated-requirement.after-rebuild.txt" 2>&1
    cmp -s \
        "$session_dir/designated-requirement.before-rebuild.txt" \
        "$session_dir/designated-requirement.after-rebuild.txt" || {
        print -u2 -r -- "error: designated requirement changed across the stable rebuild"
        /bin/mv "$APP_PATH" "$session_dir/app-rejected-rebuild-$stamp.app"
        /bin/mv "$backup_app" "$APP_PATH"
        return 1
    }
    preflight "$session_dir/preflight.json"
    /usr/bin/open -a "$APP_PATH" "mactools-dev://app/settings/plugins/marketplace"
    print -r -- "Rebuilt stable app with an unchanged designated requirement."
    print -r -- "Recoverable previous app: $backup_app"
}

prepare() {
    require_app
    local stamp session_dir
    stamp="$(date -u +%Y%m%d-%H%M%S)"
    session_dir="$ARTIFACT_ROOT/session-$stamp-$$"
    mkdir -p "$session_dir"

    preflight "$session_dir/preflight.json"
    stop_app

    local bundle_id extension_id
    bundle_id="$(app_bundle_identifier)"
    extension_id="$(extension_bundle_identifier)"
    local had_preferences=false
    local had_extension_preferences=false
    if save_domain "$bundle_id" "$session_dir/preferences.before.plist"; then
        had_preferences=true
    fi
    if [[ -n "$extension_id" ]] && save_domain "$extension_id" "$session_dir/extension-preferences.before.plist"; then
        had_extension_preferences=true
    fi
    write_session_metadata \
        "$session_dir/session.plist" "$bundle_id" "$extension_id" \
        "$had_preferences" "$had_extension_preferences"
    write_pending_checkpoints "$session_dir/ui-checkpoints.json"
    build_privacy_helpers "$session_dir"
    build_privacy_recorder "$session_dir"

    if ! fixture_tool seed --bundle-id "$bundle_id" --allow-real-domain >"$session_dir/fixture.seed.json"; then
        restore_domain "$bundle_id" "$had_preferences" "$session_dir/preferences.before.plist"
        if [[ -n "$extension_id" ]]; then
            restore_domain \
                "$extension_id" "$had_extension_preferences" \
                "$session_dir/extension-preferences.before.plist"
        fi
        return 1
    fi

    /usr/bin/open -a "$APP_PATH" "mactools-dev://app/settings/plugins/marketplace"
    local attempt
    for attempt in {1..100}; do
        [[ -n "$(matching_pids)" ]] && break
        sleep 0.1
    done
    local process_output process_count
    process_output="$(matching_pids)"
    process_count=0
    if [[ -n "$process_output" ]]; then
        process_count="$(print -r -- "$process_output" | wc -l | tr -d ' ')"
    fi
    if (( process_count != 1 )); then
        print -u2 -r -- "error: expected one stable-path process after launch, found $process_count"
        print -u2 -r -- "Restore with: $HARNESS_PATH restore '$session_dir'"
        return 1
    fi

    print -r -- "Prepared E2E session: $session_dir"
    print -r -- "Restore command: $HARNESS_PATH restore '$session_dir'"
    print -r -- "$session_dir"
}

reseed_session() {
    local session_dir="$1"
    [[ -f "$session_dir/session.plist" ]] || {
        print -u2 -r -- "error: invalid E2E session directory $session_dir"
        return 1
    }
    local prepared_app_path bundle_id
    prepared_app_path="$(session_value "$session_dir" appPath)"
    bundle_id="$(session_value "$session_dir" bundleIdentifier)"
    [[ "$prepared_app_path" == "$APP_PATH" ]] || {
        print -u2 -r -- "error: session app path $prepared_app_path does not match $APP_PATH"
        return 1
    }

    stop_app
    stop_privacy_helpers "$session_dir"
    ensure_privacy_helpers "$session_dir"
    local stamp evidence_path
    stamp="$(date -u +%Y%m%d-%H%M%S)"
    evidence_path="$session_dir/fixture.reseed-$stamp.json"
    fixture_tool seed --bundle-id "$bundle_id" --allow-real-domain >"$evidence_path"
    /usr/bin/open -a "$APP_PATH" "mactools-dev://app/settings/plugins/marketplace"

    local attempt
    for attempt in {1..100}; do
        [[ -n "$(matching_pids)" ]] && break
        sleep 0.1
    done
    local process_count
    process_count="$(matching_pids | wc -l | tr -d ' ')"
    [[ "$process_count" == 1 ]] || {
        print -u2 -r -- "error: expected one stable-path process after reseed, found $process_count"
        return 1
    }
    print -r -- "Reseeded E2E fixture: $evidence_path"
}

upgrade_session() {
    local session_dir="$1"
    [[ -f "$session_dir/session.plist" ]] || {
        print -u2 -r -- "error: invalid E2E session directory $session_dir"
        return 1
    }
    write_pending_checkpoints "$session_dir/ui-checkpoints.json"
    reseed_session "$session_dir"
    print -r -- "Reset required checkpoints from $SCENARIO_MANIFEST"
}

session_value() {
    plist_value "$1/session.plist" "$2"
}

audit_session() {
    local session_dir="$1"
    [[ -f "$session_dir/session.plist" ]] || {
        print -u2 -r -- "error: invalid E2E session directory $session_dir"
        return 1
    }
    local bundle_id
    bundle_id="$(session_value "$session_dir" bundleIdentifier)"
    fixture_tool audit --bundle-id "$bundle_id" | tee "$session_dir/fixture.audit.json"
}

checkpoint() {
    local session_dir="$1"
    local name="$2"
    local checkpoint_status="$3"
    local detail="${4:-}"
    [[ "$checkpoint_status" == pass || "$checkpoint_status" == fail || "$checkpoint_status" == pending ]] || {
        print -u2 -r -- "error: checkpoint status must be pass, fail, or pending"
        return 1
    }
    "$PYTHON3" - \
        "$session_dir/ui-checkpoints.json" \
        "$session_dir/report.json" \
        "$SCENARIO_MANIFEST" \
        "$name" "$checkpoint_status" "$detail" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone

path, report_path, manifest_path, name, status, detail = sys.argv[1:]
with open(path, encoding="utf-8") as handle:
    payload = json.load(handle)
with open(manifest_path, encoding="utf-8") as handle:
    manifest = json.load(handle)
known_names = {
    checkpoint
    for pack in manifest["packs"]
    for checkpoint in pack["checkpoints"]
}
if name not in known_names:
    raise SystemExit(f"unknown checkpoint: {name}")
payload[name] = {
    "status": status,
    "detail": detail,
    "timestamp": datetime.now(timezone.utc).isoformat(),
}

with open(path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
    handle.write("\n")

if os.path.isfile(report_path):
    with open(report_path, encoding="utf-8") as handle:
        report = json.load(handle)
    scenario_coverage = {}
    for pack in manifest["packs"]:
        pack_statuses = {
            checkpoint: payload.get(checkpoint, {"status": "not-required"})["status"]
            for checkpoint in pack["checkpoints"]
        }
        scenario_coverage[pack["id"]] = {
            "title": pack["title"],
            "phase": pack["phase"],
            "required": pack["required"],
            "checkpoints": pack_statuses,
            "passed": bool(pack_statuses)
                and all(value == "pass" for value in pack_statuses.values()),
        }
    required_names = [
        checkpoint
        for pack in manifest["packs"]
        if pack["required"]
        for checkpoint in pack["checkpoints"]
    ]
    required_statuses = [
        payload.get(checkpoint, {"status": "pending"})["status"]
        for checkpoint in required_names
    ]
    report["generatedAt"] = datetime.now(timezone.utc).isoformat()
    report["uiCheckpoints"] = payload
    report["scenarioCoverage"] = scenario_coverage
    report["passed"] = (
        report.get("preflight", {}).get("passed", False)
        and report.get("fixture", {}).get("valid", False)
        and set(required_names).issubset(payload)
        and bool(required_statuses)
        and all(value == "pass" for value in required_statuses)
    )
    with open(report_path, "w", encoding="utf-8") as handle:
        json.dump(report, handle, indent=2, sort_keys=True)
        handle.write("\n")
PY
}

send_shortcut() {
    local session_dir="$1"
    local shortcut_name="$2"
    local mode="${3:-}"
    [[ -f "$session_dir/session.plist" ]] || {
        print -u2 -r -- "error: invalid E2E session directory $session_dir"
        return 1
    }
    key_sender_tool describe "$shortcut_name" >/dev/null
    if [[ "$mode" == --dry-run ]]; then
        key_sender_tool describe "$shortcut_name"
        return
    fi
    key_sender_tool check >/dev/null || {
        print -u2 -r -- "error: synthetic shortcut access is not granted; no key was sent"
        return 1
    }
    [[ "$(matching_pids | wc -l | tr -d ' ')" == 1 ]] || {
        print -u2 -r -- "error: expected exactly one stable MacTools process"
        return 1
    }
    /usr/bin/open -a Finder
    sleep 0.5
    key_sender_tool send "$shortcut_name"
}

send_pointer_click() {
    local session_dir="$1"
    local reference_width="$2"
    local reference_height="$3"
    local local_x="$4"
    local local_y="$5"
    local mode="${6:-}"
    [[ -f "$session_dir/session.plist" ]] || {
        print -u2 -r -- "error: invalid E2E session directory $session_dir"
        return 1
    }
    for value in "$reference_width" "$reference_height" "$local_x" "$local_y"; do
        [[ "$value" == <-> ]] || {
            print -u2 -r -- "error: pointer coordinates and reference dimensions must be non-negative integers"
            return 1
        }
    done
    (( reference_width > 0 && reference_height > 0 )) || {
        print -u2 -r -- "error: pointer reference dimensions must be positive"
        return 1
    }
    (( local_x <= reference_width && local_y <= reference_height )) || {
        print -u2 -r -- "error: pointer coordinate is outside the reference window"
        return 1
    }
    if [[ "$mode" == --dry-run ]]; then
        print -r -- "Pointer click at ($local_x,$local_y) in ${reference_width}x${reference_height} focused MacTools window"
        return 0
    fi
    ensure_input_driver "$session_dir"
    local process_output process_id
    process_output="$(matching_pids)"
    [[ "$(print -r -- "$process_output" | wc -l | tr -d ' ')" == 1 ]] || {
        print -u2 -r -- "error: expected exactly one stable MacTools process before pointer input"
        return 1
    }
    process_id="${process_output%%$'\n'*}"
    input_driver_tool "$session_dir" click-relative \
        "$process_id" "$reference_width" "$reference_height" "$local_x" "$local_y"
}

send_input_select_all() {
    local session_dir="$1"
    local mode="${2:-}"
    [[ -f "$session_dir/session.plist" ]] || {
        print -u2 -r -- "error: invalid E2E session directory $session_dir"
        return 1
    }
    if [[ "$mode" == --dry-run ]]; then
        print -r -- "Select all in the focused MacTools control"
        return 0
    fi
    ensure_input_driver "$session_dir"
    input_driver_tool "$session_dir" select-all
}

send_input_text() {
    local session_dir="$1"
    local input_text="$2"
    local mode="${3:-}"
    [[ -f "$session_dir/session.plist" ]] || {
        print -u2 -r -- "error: invalid E2E session directory $session_dir"
        return 1
    }
    if [[ "$mode" == --dry-run ]]; then
        print -r -- "Type ${#input_text} characters into the focused MacTools control"
        return 0
    fi
    ensure_input_driver "$session_dir"
    input_driver_tool "$session_dir" type-text "$input_text"
}

launch_privacy_helper_session() {
    local session_dir="$1"
    local variant="$2"
    local mode="${3:-}"
    [[ -f "$session_dir/session.plist" ]] || {
        print -u2 -r -- "error: invalid E2E session directory $session_dir"
        return 1
    }
    session_dir="${session_dir:A}"
    [[ "$variant" == primary || "$variant" == secondary ]] || {
        print -u2 -r -- "error: privacy helper variant must be primary or secondary"
        return 1
    }
    local app
    app="$(privacy_helper_app_path "$session_dir" "$variant")"
    if [[ "$mode" == --dry-run ]]; then
        print -r -- "/usr/bin/open -a '$app'"
        return
    fi
    ensure_privacy_helpers "$session_dir"
    /usr/bin/open -a "$app"
}

record_session() {
    local session_dir="$1"
    local duration="${2:-90}"
    local mode="${3:-}"
    local label="${4:-}"
    local start_route="${5:-settings/features/automation}"
    [[ "$duration" == <-> ]] && (( duration >= 1 && duration <= 600 )) || {
        print -u2 -r -- "error: recording duration must be between 1 and 600 seconds"
        return 1
    }
    [[ -f "$session_dir/session.plist" ]] || {
        print -u2 -r -- "error: invalid E2E session directory $session_dir"
        return 1
    }
    session_dir="${session_dir:A}"
    if [[ -n "$label" && "$label" == *[^a-z0-9-]* ]]; then
        print -u2 -r -- "error: recording label must contain only lowercase letters, digits, and hyphens"
        return 1
    fi
    local base_name="screencast"
    [[ -z "$label" ]] || base_name="screencast.$label"
    local mov="$session_dir/$base_name.mov"
    local mp4="$session_dir/$base_name.mp4"
    local temporary_mov="$session_dir/.$base_name.$$.mov"
    local temporary_mp4="$session_dir/.$base_name.$$.mp4"
    if [[ "$mode" == --dry-run ]]; then
        print -r -- "Hide unrelated apps reversibly, start the privacy backdrop, reactivate MacTools, then record"
        print -r -- "Story start route: mactools-dev://app/$start_route"
        print -r -- "ScreenCaptureKit allowlist: MacTools + session privacy helper"
        print -r -- "MacToolsE2ERecorder '$mov' '$duration' '<visible-MacTools-window>' '<ready-file>' '<first-action-file>' '<assertion-stop-file>' '<allowed-bundle-ids>'"
        return 0
    fi

    stop_privacy_helpers "$session_dir"
    build_privacy_helpers "$session_dir"
    ensure_privacy_recorder "$session_dir"
    ensure_input_driver "$session_dir"
    stop_app
    sleep 0.5
    local visibility_state
    visibility_state="$(recording_visibility_state_path "$session_dir")"
    rm -f -- "$visibility_state"
    /usr/bin/open -a "$APP_PATH"
    sleep 1
    key_sender_tool check >/dev/null || {
        print -u2 -r -- "error: synthetic shortcut access is required to establish the private Settings recording surface"
        return 1
    }
    key_sender_tool send open-settings >/dev/null
    sleep 1
    /usr/bin/open -a "$APP_PATH" "mactools-dev://app/$start_route"
    sleep 0.75
    /usr/bin/open -a "$(privacy_helper_app_path "$session_dir" backdrop)" \
        --args --recording-privacy --visibility-state "$visibility_state"
    trap 'stop_privacy_helpers "$session_dir"' EXIT INT TERM
    sleep 0.75
    /usr/bin/open -gj -a "$(privacy_helper_app_path "$session_dir" primary)"
    /usr/bin/open -gj -a "$(privacy_helper_app_path "$session_dir" secondary)"
    sleep 0.5
    /usr/bin/open -a "$APP_PATH" "mactools-dev://app/$start_route"
    sleep 0.75

    local process_output process_id capture_rect
    process_output="$(matching_pids)"
    [[ "$(print -r -- "$process_output" | wc -l | tr -d ' ')" == 1 ]] || {
        stop_privacy_helpers "$session_dir"
        print -u2 -r -- "error: expected exactly one stable MacTools process before recording"
        return 1
    }
    process_id="${process_output%%$'\n'*}"
    capture_rect=""
    local capture_attempt
    for capture_attempt in {1..50}; do
        capture_rect="$(capture_rect_tool "$process_id" 2>/dev/null || true)"
        [[ "$capture_rect" == <->,<->,<->,<-> ]] && break
        sleep 0.2
    done
    [[ "$capture_rect" == <->,<->,<->,<-> ]] || {
        stop_privacy_helpers "$session_dir"
        print -u2 -r -- "error: no visible standard MacTools window is available for private recording"
        return 1
    }

    local app_bundle_id primary_helper_bundle_id secondary_helper_bundle_id backdrop_bundle_id
    app_bundle_id="$(app_bundle_identifier)"
    primary_helper_bundle_id="$(plist_value "$(privacy_helper_app_path "$session_dir" primary)/Contents/Info.plist" CFBundleIdentifier)"
    secondary_helper_bundle_id="$(plist_value "$(privacy_helper_app_path "$session_dir" secondary)/Contents/Info.plist" CFBundleIdentifier)"
    backdrop_bundle_id="$(plist_value "$(privacy_helper_app_path "$session_dir" backdrop)/Contents/Info.plist" CFBundleIdentifier)"
    local ready_marker start_marker stop_marker
    ready_marker="$(recording_marker_path "$session_dir" "$label" ready)"
    start_marker="$(recording_marker_path "$session_dir" "$label" start)"
    stop_marker="$(recording_marker_path "$session_dir" "$label" stop)"
    print -r -- "ScreenCaptureKit application allowlist: $app_bundle_id, $primary_helper_bundle_id, $secondary_helper_bundle_id, $backdrop_bundle_id"
    print -r -- "Recording readiness marker: $ready_marker"
    print -r -- "First action marker: $start_marker"
    print -r -- "Assertion stop marker: $stop_marker"
    rm -f -- "$temporary_mov" "$temporary_mp4" "$ready_marker" "$start_marker" "$stop_marker"
    if ! privacy_recorder_tool "$session_dir" \
        "$temporary_mov" "$duration" "$capture_rect" "$ready_marker" "$start_marker" "$stop_marker" \
        "$app_bundle_id" "$primary_helper_bundle_id" "$secondary_helper_bundle_id" "$backdrop_bundle_id"; then
        stop_privacy_helpers "$session_dir"
        rm -f -- "$temporary_mov" "$temporary_mp4" "$ready_marker" "$start_marker" "$stop_marker"
        return 1
    fi
    rm -f -- "$ready_marker" "$start_marker" "$stop_marker"
    stop_privacy_helpers "$session_dir"
    trap - EXIT INT TERM
    if ! /opt/homebrew/bin/ffmpeg -hide_banner -loglevel error -y -i "$temporary_mov" \
        -an -c:v libx264 -crf 20 -preset medium -pix_fmt yuv420p \
        -movflags +faststart "$temporary_mp4"; then
        rm -f -- "$temporary_mov" "$temporary_mp4"
        return 1
    fi
    mv -f -- "$temporary_mov" "$mov"
    mv -f -- "$temporary_mp4" "$mp4"
    shasum -a 256 "$mov" "$mp4" >"$session_dir/$base_name.sha256"
}

record_pack_session() {
    local session_dir="$1"
    local pack_id="$2"
    local duration="${3:-90}"
    local mode="${4:-}"
    print_scenarios "$pack_id" >/dev/null
    local start_route
    start_route="$(recording_start_route "$pack_id")"
    record_session "$session_dir" "$duration" "$mode" "$pack_id" "$start_route"
    if [[ "$mode" != --dry-run ]]; then
        checkpoint "$session_dir" screencast-captured pass \
            "Recorded scenario pack $pack_id"
    fi
}

verify_code_session() {
    local session_dir="$1"
    local mode="${2:-}"
    [[ -f "$session_dir/session.plist" ]] || {
        print -u2 -r -- "error: invalid E2E session directory $session_dir"
        return 1
    }

    local -a common_args
    common_args=(
        -project "$REPO_ROOT/MacTools.xcodeproj"
        -scheme MacTools
        -configuration Debug
        -derivedDataPath "$REPO_ROOT/build/DerivedData"
        test
        -quiet
    )
    print -r -- "Run PluginCatalogManagerTests with xcodebuild"
    print -r -- "Run action-registry core coverage and native action-provider suites with xcodebuild"
    print -r -- "Run the six injected Trackpad Gestures test classes with xcodebuild"
    if [[ "$mode" == --dry-run ]]; then
        return 0
    fi
    require_app

    local result=0
    stop_app
    trap 'restore_stable_app_after_code_verification' EXIT
    stop_built_app
    restore_stable_launch_services_registration
    if env DEVELOPER_DIR="$E2E_DEVELOPER_DIR" xcodebuild "${common_args[@]}" \
        -only-testing:MacToolsTests/PluginCatalogManagerTests \
        2>&1 | tee "$session_dir/code-verification.migration.log"; then
        checkpoint "$session_dir" plugin-migration-isolated-tests pass \
            "PluginCatalogManagerTests passed"
    else
        checkpoint "$session_dir" plugin-migration-isolated-tests fail \
            "See code-verification.migration.log"
        result=1
    fi
    stop_built_app
    restore_stable_launch_services_registration

    if env DEVELOPER_DIR="$E2E_DEVELOPER_DIR" xcodebuild "${common_args[@]}" \
        -only-testing:MacToolsTests/ActionRegistryTests \
        -only-testing:MacToolsTests/ActionExecutorTests \
        -only-testing:MacToolsTests/ActionRunLinkServiceTests \
        -only-testing:MacToolsTests/AutomationControllerTests \
        -only-testing:MacToolsTests/PluginHostActionRegistryTests \
        -only-testing:MacToolsTests/ActionGridPluginTests \
        -only-testing:MacToolsTests/ActivityBarPluginTests \
        -only-testing:MacToolsTests/AppearancePluginTests \
        -only-testing:MacToolsTests/AppHotkeyPluginTests \
        -only-testing:MacToolsTests/AppVolumePluginTests \
        -only-testing:MacToolsTests/AutoHideDockPluginTests \
        -only-testing:MacToolsTests/AutoHideMenuBarPluginTests \
        -only-testing:MacToolsTests/AutoInputPluginPanelTests \
        -only-testing:MacToolsTests/BatteryChargeLimitPluginTests \
        -only-testing:MacToolsTests/ClipboardClearPluginTests \
        -only-testing:MacToolsTests/DiskCleanPluginTests \
        -only-testing:MacToolsTests/DisplayBrightnessPluginTests \
        -only-testing:MacToolsTests/DisplayResolutionPluginTests \
        -only-testing:MacToolsTests/DisplaySleepPluginTests \
        -only-testing:MacToolsTests/DisplayTrueColorPluginTests \
        -only-testing:MacToolsTests/EjectDiskPluginTests \
        -only-testing:MacToolsTests/EmptyTrashPluginTests \
        -only-testing:MacToolsTests/FanControlPluginTests \
        -only-testing:MacToolsTests/FixDamagedAppPluginTests \
        -only-testing:MacToolsTests/HideNotchPluginTests \
        -only-testing:MacToolsTests/HomebrewPluginTests \
        -only-testing:MacToolsTests/IPOverviewPluginTests \
        -only-testing:MacToolsTests/KeepAwakePreferenceTests \
        -only-testing:MacToolsTests/LaunchControlCanonicalActionTests \
        -only-testing:MacToolsTests/LaunchpadPluginActionTests \
        -only-testing:MacToolsTests/LockScreenPluginTests \
        -only-testing:MacToolsTests/MicrophoneMutePluginTests \
        -only-testing:MacToolsTests/NightShiftPluginTests \
        -only-testing:MacToolsTests/PhysicalCleanModePluginTests \
        -only-testing:MacToolsTests/QuitAppsPluginTests \
        -only-testing:MacToolsTests/SavedScriptsPluginTests \
        -only-testing:MacToolsTests/SidecarPluginTests \
        -only-testing:MacToolsTests/StageManagerPluginTests \
        -only-testing:MacToolsTests/SystemMutePluginTests \
        -only-testing:MacToolsTests/TranslatorPluginTests \
        -only-testing:MacToolsTests/WindowSwitcherPluginTests \
        -only-testing:MacToolsTests/XcodeCleanPluginTests \
        2>&1 | tee "$session_dir/code-verification.action-registry.log"; then
        checkpoint "$session_dir" action-registry-health pass \
            "Core registry coverage and native action-provider suites passed"
    else
        checkpoint "$session_dir" action-registry-health fail \
            "See code-verification.action-registry.log"
        result=1
    fi
    stop_built_app
    restore_stable_launch_services_registration

    if env DEVELOPER_DIR="$E2E_DEVELOPER_DIR" xcodebuild "${common_args[@]}" \
        -only-testing:MacToolsTests/TrackpadTypingSuppressionGateTests \
        -only-testing:MacToolsTests/TrackpadMiddleClickArbiterTests \
        -only-testing:MacToolsTests/TrackpadMiddleClickCoordinatorTests \
        -only-testing:MacToolsTests/TrackpadGestureStoreTests \
        -only-testing:MacToolsTests/TrackpadGesturesPluginTests \
        -only-testing:MacToolsTests/TrackpadGestureRecognizerTests \
        2>&1 | tee "$session_dir/code-verification.trackpad.log"; then
        checkpoint "$session_dir" trackpad-automated-tests pass \
            "Injected Trackpad Gestures suites passed"
    else
        checkpoint "$session_dir" trackpad-automated-tests fail \
            "See code-verification.trackpad.log"
        result=1
    fi
    stop_built_app
    restore_stable_launch_services_registration
    /usr/bin/open -a "$APP_PATH" "mactools-dev://app/settings/plugins/marketplace"
    trap - EXIT
    return "$result"
}

collect_session() {
    local session_dir="$1"
    preflight "$session_dir/preflight.json" >/dev/null || true
    audit_session "$session_dir" >/dev/null
    codesign -dv --verbose=4 "$APP_PATH" >"$session_dir/signature.txt" 2>&1
    codesign -d -r- "$APP_PATH" >"$session_dir/designated-requirement.txt" 2>&1
    pgrep -fal 'MacTools Dev' >"$session_dir/processes.txt" || true
    /usr/bin/log show --last 5m --style compact --predicate 'process == "MacTools Dev"' \
        2>/dev/null | tail -2000 >"$session_dir/app.log" || true

    "$PYTHON3" - "$session_dir" "$SCENARIO_MANIFEST" <<'PY'
import hashlib
import json
import glob
import os
import sys
from datetime import datetime, timezone

session = sys.argv[1]
with open(sys.argv[2], encoding="utf-8") as handle:
    scenario_manifest = json.load(handle)
def load(name):
    with open(os.path.join(session, name), encoding="utf-8") as handle:
        return json.load(handle)

fixture = load("fixture.audit.json")
preflight = load("preflight.json")
checkpoints = load("ui-checkpoints.json")
recordings = {}
for path in sorted(glob.glob(os.path.join(session, "screencast*.mov")) + glob.glob(os.path.join(session, "screencast*.mp4"))):
    name = os.path.basename(path)
    if os.path.isfile(path):
        digest = hashlib.sha256()
        with open(path, "rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
        recordings[name] = {"bytes": os.path.getsize(path), "sha256": digest.hexdigest()}

def hashed_artifacts(pattern):
    artifacts = {}
    for path in sorted(glob.glob(os.path.join(session, pattern))):
        if not os.path.isfile(path):
            continue
        digest = hashlib.sha256()
        with open(path, "rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
        artifacts[os.path.basename(path)] = {
            "bytes": os.path.getsize(path),
            "sha256": digest.hexdigest(),
        }
    return artifacts

screenshots = hashed_artifacts("screenshot*.png")
code_verification_logs = hashed_artifacts("code-verification.*.log")

required_packs = [pack for pack in scenario_manifest["packs"] if pack["required"]]
required_checkpoint_names = [
    name for pack in required_packs for name in pack["checkpoints"]
]
required_statuses = [
    checkpoints.get(name, {"status": "pending"})["status"]
    for name in required_checkpoint_names
]
scenario_coverage = {}
for pack in scenario_manifest["packs"]:
    pack_statuses = {
        name: checkpoints.get(name, {"status": "not-required"})["status"]
        for name in pack["checkpoints"]
    }
    scenario_coverage[pack["id"]] = {
        "title": pack["title"],
        "phase": pack["phase"],
        "required": pack["required"],
        "checkpoints": pack_statuses,
        "passed": bool(pack_statuses)
            and all(status == "pass" for status in pack_statuses.values()),
    }
payload = {
    "generatedAt": datetime.now(timezone.utc).isoformat(),
    "preflight": preflight,
    "fixture": fixture,
    "uiCheckpoints": checkpoints,
    "scenarioManifestVersion": scenario_manifest["formatVersion"],
    "scenarioCoverage": scenario_coverage,
    "recordings": recordings,
    "screenshots": screenshots,
    "codeVerificationLogs": code_verification_logs,
    "passed": preflight.get("passed", False)
        and fixture.get("valid", False)
        and set(required_checkpoint_names).issubset(checkpoints)
        and bool(required_statuses)
        and all(status == "pass" for status in required_statuses),
}
with open(os.path.join(session, "report.json"), "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
    print -r -- "Collected report: $session_dir/report.json"
}

restore_session() {
    local session_dir="$1"
    [[ -f "$session_dir/session.plist" ]] || {
        print -u2 -r -- "error: invalid E2E session directory $session_dir"
        return 1
    }
    stop_app
    stop_privacy_helpers "$session_dir"

    local bundle_id extension_id had_preferences had_extension_preferences
    bundle_id="$(session_value "$session_dir" bundleIdentifier)"
    extension_id="$(session_value "$session_dir" extensionBundleIdentifier)"
    had_preferences="$(session_value "$session_dir" hadPreferences)"
    had_extension_preferences="$(session_value "$session_dir" hadExtensionPreferences)"
    [[ "$had_preferences" == true ]] || had_preferences=false
    [[ "$had_extension_preferences" == true ]] || had_extension_preferences=false

    restore_domain "$bundle_id" "$had_preferences" "$session_dir/preferences.before.plist"
    if [[ -n "$extension_id" ]]; then
        restore_domain \
            "$extension_id" "$had_extension_preferences" \
            "$session_dir/extension-preferences.before.plist"
    fi
    touch "$session_dir/restored.ok"
    /usr/bin/open -a "$APP_PATH" "mactools-dev://app/settings/plugins/marketplace"
    print -r -- "Restored preferences from $session_dir"
}

self_test() {
    local domain="com.jennymedia.mactools.e2e-test.$$.${RANDOM}"
    trap 'fixture_tool clear-test-domain --bundle-id "$domain" >/dev/null 2>&1 || true' EXIT
    fixture_tool seed --bundle-id "$domain" >/dev/null
    fixture_tool audit --bundle-id "$domain"
    fixture_tool clear-test-domain --bundle-id "$domain"
    trap - EXIT
}

command="${1:-}"
case "$command" in
    preflight)
        preflight "${2:-}"
        ;;
    prepare)
        prepare
        ;;
    upgrade)
        [[ $# -ge 2 ]] || { usage; exit 1; }
        upgrade_session "$2"
        ;;
    reseed)
        [[ $# -ge 2 ]] || { usage; exit 1; }
        reseed_session "$2"
        ;;
    resume)
        [[ $# -ge 2 ]] || { usage; exit 1; }
        resume_session "$2"
        ;;
    rebuild)
        [[ $# -ge 2 ]] || { usage; exit 1; }
        rebuild_session "$2" "${3:-}"
        ;;
    audit)
        [[ $# -ge 2 ]] || { usage; exit 1; }
        audit_session "$2"
        ;;
    checkpoint)
        [[ $# -ge 4 ]] || { usage; exit 1; }
        checkpoint "$2" "$3" "$4" "${5:-}"
        ;;
    shortcut)
        [[ $# -ge 3 ]] || { usage; exit 1; }
        send_shortcut "$2" "$3" "${4:-}"
        ;;
    pointer-click)
        [[ $# -ge 6 ]] || { usage; exit 1; }
        send_pointer_click "$2" "$3" "$4" "$5" "$6" "${7:-}"
        ;;
    input-select-all)
        [[ $# -ge 2 ]] || { usage; exit 1; }
        send_input_select_all "$2" "${3:-}"
        ;;
    input-text)
        [[ $# -ge 3 ]] || { usage; exit 1; }
        send_input_text "$2" "$3" "${4:-}"
        ;;
    privacy-helper)
        [[ $# -ge 3 ]] || { usage; exit 1; }
        launch_privacy_helper_session "$2" "$3" "${4:-}"
        ;;
    record)
        [[ $# -ge 2 ]] || { usage; exit 1; }
        record_session "$2" "${3:-90}" "${4:-}"
        ;;
    record-pack)
        [[ $# -ge 3 ]] || { usage; exit 1; }
        record_pack_session "$2" "$3" "${4:-90}" "${5:-}"
        ;;
    wait-recording-ready)
        [[ $# -ge 2 ]] || { usage; exit 1; }
        wait_recording_ready "$2" "${3:-}" "${4:-15}"
        ;;
    start-recording)
        [[ $# -ge 2 ]] || { usage; exit 1; }
        start_recording "$2" "${3:-}"
        ;;
    stop-recording)
        [[ $# -ge 2 ]] || { usage; exit 1; }
        stop_recording "$2" "${3:-}"
        ;;
    verify-code)
        [[ $# -ge 2 ]] || { usage; exit 1; }
        verify_code_session "$2" "${3:-}"
        ;;
    scenarios)
        print_scenarios "${2:-}"
        ;;
    collect)
        [[ $# -ge 2 ]] || { usage; exit 1; }
        collect_session "$2"
        ;;
    restore)
        [[ $# -ge 2 ]] || { usage; exit 1; }
        restore_session "$2"
        ;;
    self-test)
        self_test
        ;;
    *)
        usage
        exit 1
        ;;
esac
