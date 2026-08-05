#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
REPO_ROOT="${SCRIPT_DIR:h:h}"
FIXTURE_TOOL="$SCRIPT_DIR/MacToolsE2EFixture.swift"
KEY_SENDER_TOOL="$SCRIPT_DIR/MacToolsE2EKeySender.swift"
HARNESS_PATH="$SCRIPT_DIR/mactools-e2e.sh"
APP_PATH="${MACTOOLS_E2E_APP_PATH:-$HOME/Applications/MacTools Dev.app}"
PLUGIN_INSTALL_DIR="${MACTOOLS_E2E_PLUGIN_DIR:-$HOME/Library/Application Support/MacTools Dev/Plugins/Installed}"
ARTIFACT_ROOT="${MACTOOLS_E2E_ARTIFACT_ROOT:-$REPO_ROOT/build/E2EArtifacts}"
BUILT_APP_PATH="$REPO_ROOT/build/DerivedData/Build/Products/Debug/${APP_PATH:t}"
PYTHON3="${PYTHON3:-/usr/bin/python3}"

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
    print -r -- "  resume <session-dir>                  Revalidate and reopen a prepared session"
    print -r -- "  rebuild <session-dir> [--dry-run]     Rebuild and replace the stable signed app"
    print -r -- "  audit <session-dir>                   Save and validate fixture state"
    print -r -- "  checkpoint <session-dir> <name> <pass|fail|pending> [detail]"
    print -r -- "  shortcut <session-dir> <open-settings|action-grid> [--dry-run]"
    print -r -- "  record <session-dir> [seconds] [--dry-run]"
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

matching_pids() {
    local executable
    executable="$(app_executable)"
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
    local passed="$9"

    mkdir -p "${output_path:h}"
    "$PYTHON3" - "$output_path" "$APP_PATH" "$bundle_id" "$team_id" "$expected_team_id" \
        "$authority" "$plugin_count" "$process_count" "$event_posting_access" "$passed" <<'PY'
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
    passed,
) = sys.argv[1:]
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
    "eventPostingAccess": event_posting_access == "true",
    "recorder": "/usr/sbin/screencapture",
    "transcoder": "/opt/homebrew/bin/ffmpeg",
    "permissionState": "pending-user-grant",
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
    local event_posting_access=false
    if key_sender_tool check >/dev/null 2>&1; then
        event_posting_access=true
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
    [[ -x /usr/sbin/screencapture ]] || failures+=("screencapture is unavailable")
    [[ -x /opt/homebrew/bin/ffmpeg ]] || failures+=("ffmpeg is unavailable")

    local passed=true
    (( ${#failures[@]} == 0 )) || passed=false
    write_preflight_json \
        "$output_path" "$bundle_id" "$team_id" "$expected_team" "$authority" \
        "$plugin_count" "$process_count" "$event_posting_access" "$passed"

    print -r -- "App: $APP_PATH"
    print -r -- "Bundle: $bundle_id"
    print -r -- "Team: $team_id"
    print -r -- "Authority: $authority"
    print -r -- "Installed plugins: $plugin_count"
    print -r -- "Running instances: $process_count"
    print -r -- "Synthetic shortcut access: $event_posting_access"
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
    "$PYTHON3" - "$output" <<'PY'
import json
import sys

names = [
    "marketplace-visible",
    "actions-shortcuts-visible",
    "workflow-visible",
    "workflow-run-succeeded",
    "run-link-executed",
    "action-grid-visible",
    "launchpad-visible",
    "calculator-automation-triggered",
    "shortcut-control-command-3",
    "shortcut-control-command-4",
    "relaunch-persistence",
    "rebuild-permission-persistence",
]
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump({name: {"status": "pending", "detail": ""} for name in names}, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
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
    "$PYTHON3" - "$session_dir/ui-checkpoints.json" "$name" "$checkpoint_status" "$detail" <<'PY'
import json
import sys
from datetime import datetime, timezone

path, name, status, detail = sys.argv[1:]
with open(path, encoding="utf-8") as handle:
    payload = json.load(handle)
payload[name] = {
    "status": status,
    "detail": detail,
    "timestamp": datetime.now(timezone.utc).isoformat(),
}

with open(path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
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

record_session() {
    local session_dir="$1"
    local duration="${2:-90}"
    local mode="${3:-}"
    [[ "$duration" == <-> ]] && (( duration >= 1 && duration <= 600 )) || {
        print -u2 -r -- "error: recording duration must be between 1 and 600 seconds"
        return 1
    }
    [[ -f "$session_dir/session.plist" ]] || {
        print -u2 -r -- "error: invalid E2E session directory $session_dir"
        return 1
    }
    local mov="$session_dir/screencast.mov"
    local mp4="$session_dir/screencast.mp4"
    print -r -- "/usr/sbin/screencapture -v -V$duration -D1 -C -k -x '$mov'"
    if [[ "$mode" == --dry-run ]]; then
        return 0
    fi

    /usr/sbin/screencapture -v "-V$duration" -D1 -C -k -x "$mov"
    /opt/homebrew/bin/ffmpeg -hide_banner -loglevel error -y -i "$mov" \
        -an -c:v libx264 -crf 20 -preset medium -pix_fmt yuv420p \
        -movflags +faststart "$mp4"
    shasum -a 256 "$mov" "$mp4" >"$session_dir/screencast.sha256"
}

collect_session() {
    local session_dir="$1"
    audit_session "$session_dir" >/dev/null
    codesign -dv --verbose=4 "$APP_PATH" >"$session_dir/signature.txt" 2>&1
    codesign -d -r- "$APP_PATH" >"$session_dir/designated-requirement.txt" 2>&1
    pgrep -fal 'MacTools Dev' >"$session_dir/processes.txt" || true
    /usr/bin/log show --last 5m --style compact --predicate 'process == "MacTools Dev"' \
        2>/dev/null | tail -2000 >"$session_dir/app.log" || true

    "$PYTHON3" - "$session_dir" <<'PY'
import hashlib
import json
import os
import sys
from datetime import datetime, timezone

session = sys.argv[1]
def load(name):
    with open(os.path.join(session, name), encoding="utf-8") as handle:
        return json.load(handle)

fixture = load("fixture.audit.json")
preflight = load("preflight.json")
checkpoints = load("ui-checkpoints.json")
recordings = {}
for name in ("screencast.mov", "screencast.mp4"):
    path = os.path.join(session, name)
    if os.path.isfile(path):
        digest = hashlib.sha256()
        with open(path, "rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
        recordings[name] = {"bytes": os.path.getsize(path), "sha256": digest.hexdigest()}

statuses = [item["status"] for item in checkpoints.values()]
payload = {
    "generatedAt": datetime.now(timezone.utc).isoformat(),
    "preflight": preflight,
    "fixture": fixture,
    "uiCheckpoints": checkpoints,
    "recordings": recordings,
    "passed": preflight.get("passed", False)
        and fixture.get("valid", False)
        and bool(statuses)
        and all(status == "pass" for status in statuses),
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
    record)
        [[ $# -ge 2 ]] || { usage; exit 1; }
        record_session "$2" "${3:-90}" "${4:-}"
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
