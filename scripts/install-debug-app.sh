#!/bin/zsh

set -euo pipefail

if [[ $# -ne 2 ]]; then
    print -u2 -r -- "usage: $0 <built-app> <installed-app>"
    exit 2
fi

source_app="${1:A}"
installed_app="${2:A}"
install_parent="${installed_app:h}"
expected_parent="${HOME:A}/Applications"

[[ -d "$source_app" && "${source_app:e}" == app ]] || {
    print -u2 -r -- "error: built app not found at $source_app"
    exit 1
}
[[ "$install_parent" == "$expected_parent" && "${installed_app:e}" == app ]] || {
    print -u2 -r -- "error: debug app target must be an app directly inside $expected_parent"
    exit 1
}

/bin/mkdir -p "$install_parent"
stage_root="$(/usr/bin/mktemp -d "$install_parent/.mactools-debug-install.XXXXXX")"
staged_app="$stage_root/${installed_app:t}"
backup_app="$stage_root/previous.app"
before_requirement="$stage_root/designated-requirement.before.txt"
after_requirement="$stage_root/designated-requirement.after.txt"

cleanup() {
    if [[ -d "$stage_root" ]]; then
        /bin/rm -rf "$stage_root"
    fi
}
trap cleanup EXIT INT TERM

/usr/bin/ditto --rsrc --extattr --acl "$source_app" "$staged_app"
/usr/bin/codesign --verify --deep --strict "$staged_app"

had_previous=false
if [[ -d "$installed_app" ]]; then
    had_previous=true
    /usr/bin/codesign -d -r- "$installed_app" >"$before_requirement" 2>&1
fi

installed_executable="$installed_app/Contents/MacOS/${installed_app:t:r}"
running_pids=()
while read -r pid command; do
    if [[ "$command" == "$installed_executable" || "$command" == "$installed_executable "* ]]; then
        running_pids+=("$pid")
        /bin/kill -TERM "$pid" >/dev/null 2>&1 || true
    fi
done < <(/bin/ps -axo pid=,command=)

for pid in "${running_pids[@]}"; do
    for _ in {1..50}; do
        /bin/kill -0 "$pid" >/dev/null 2>&1 || break
        /bin/sleep 0.1
    done
    if /bin/kill -0 "$pid" >/dev/null 2>&1; then
        print -u2 -r -- "error: existing Debug app process $pid did not terminate"
        exit 1
    fi
done

if [[ "$had_previous" == true ]]; then
    /bin/mv "$installed_app" "$backup_app"
fi

if ! /bin/mv "$staged_app" "$installed_app"; then
    if [[ "$had_previous" == true && -d "$backup_app" ]]; then
        /bin/mv "$backup_app" "$installed_app"
    fi
    exit 1
fi

if [[ "$had_previous" == true ]]; then
    /usr/bin/codesign -d -r- "$installed_app" >"$after_requirement" 2>&1
    if ! /usr/bin/cmp -s "$before_requirement" "$after_requirement"; then
        /bin/mv "$installed_app" "$stage_root/rejected.app"
        /bin/mv "$backup_app" "$installed_app"
        print -u2 -r -- "error: signing identity changed; restored the previous app so macOS permissions remain valid"
        exit 1
    fi
fi

lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "$lsregister" ]]; then
    bundle_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$installed_app/Contents/Info.plist")"
    while IFS= read -r registered_app; do
        [[ -n "$registered_app" && "$registered_app" != "$installed_app" ]] || continue
        "$lsregister" -u "$registered_app" >/dev/null 2>&1 || true
    done < <(
        "$lsregister" -dump | /usr/bin/awk \
            -v target="$bundle_identifier" \
            -v keep="$installed_app" '
                function emit() {
                    if (identifier == target && path != "" && path != keep) print path
                }
                /^-+$/ {
                    emit()
                    path = ""
                    identifier = ""
                    next
                }
                /^[[:space:]]*path:[[:space:]]*/ {
                    value = $0
                    sub(/^[[:space:]]*path:[[:space:]]*/, "", value)
                    sub(/ \(0x[0-9a-fA-F]+\)$/, "", value)
                    path = value
                    next
                }
                /^[[:space:]]*identifier:[[:space:]]*/ {
                    value = $0
                    sub(/^[[:space:]]*identifier:[[:space:]]*/, "", value)
                    identifier = value
                    next
                }
                END { emit() }
            '
    )
    "$lsregister" -u "$source_app" >/dev/null 2>&1 || true
    "$lsregister" -f "$installed_app" >/dev/null 2>&1 || true
fi

print -r -- "Installed verified Debug app: $installed_app"
