#!/usr/bin/env bash
set -euo pipefail
umask 077
mac_source_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
watcher_label="io.github.claude-ac.macos-watcher"
watcher_app="$HOME/Applications/Claude Auto Continue.app"
watcher_plist="$HOME/Library/LaunchAgents/$watcher_label.plist"
watcher_data="$HOME/Library/Application Support/Claude Auto Continue"
watcher_logs="$HOME/Library/Logs/Claude Auto Continue"
watcher_domain="gui/$(id -u)"
watcher_service="$watcher_domain/$watcher_label"
# Only launchctl's missing-service result proves absence. Permission and
# transport errors must not permit replacing a still-loaded executable.
watcher_loaded() {
    local info status
    if info="$(launchctl print "$watcher_service" 2>&1)"; then return 0
    else status=$?; fi
    [[ "$status" -eq 113 ]] && return 1
    printf '%s\n' "$info" >&2
    exit "$status"
}
unload_watcher() {
    if watcher_loaded; then
        launchctl bootout "$watcher_service"
        for _ in {1..25}; do
            if ! watcher_loaded; then return 0; fi
            sleep 0.2
        done
        if watcher_loaded; then echo 'Watcher is still unloading after five seconds.' >&2; exit 1; fi
    fi
}
if [[ "${1:-}" == "--uninstall" ]]; then
    unload_watcher
    bash "$mac_source_dir/install-menu.sh" --uninstall
    rm -f "$watcher_plist"
    rm -rf "$watcher_app"
    # Keep the attempt ledger on uninstall: reinstall must not replay an
    # uncertain click. Logs also remain for diagnosis, and contain no prompts.
    printf 'Watcher unloaded and app removed. State and logs retained in:\n%s\n%s\n' "$watcher_data" "$watcher_logs"
    exit 0
fi
watcher_sessions=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --session)
            [[ $# -ge 2 ]] || { echo 'Missing session ID' >&2; exit 2; }
            duplicate=false
            for ((i=1; i<${#watcher_sessions[@]}; i+=2)); do
                if [[ "${watcher_sessions[i]}" == "$2" ]]; then duplicate=true; break; fi
            done
            if [[ "$duplicate" == false ]]; then watcher_sessions+=("--session" "$2"); fi
            shift 2 ;;
        *) echo 'Usage: bash mac/install-watcher.sh --session local_ID [--session local_ID ...] | --uninstall' >&2; exit 2 ;;
    esac
done
[[ ${#watcher_sessions[@]} -gt 0 ]] || { echo 'Specify the existing Code session IDs with --session; use ClaudeResume list to inspect them.' >&2; exit 2; }
watcher_built_app="$(bash "$mac_source_dir/build-native.sh")"
mkdir -p "$HOME/Applications" "$(dirname "$watcher_plist")" "$watcher_data" "$watcher_logs"
unload_watcher
# Replace only this helper's installed bundle; never Claude Desktop itself.
if [[ -e "$watcher_app" ]]; then rm -rf "$watcher_app"; fi
ditto "$watcher_built_app" "$watcher_app"
python3 - "$watcher_plist" "$watcher_app/Contents/MacOS/ClaudeResume" "$watcher_logs" "${watcher_sessions[@]}" <<'PY'
import plistlib,sys
path,binary,logs,*sessions=sys.argv[1:]
with open(path,'wb') as file:
    plistlib.dump({'Label':'io.github.claude-ac.macos-watcher',
        'ProgramArguments':[binary,'watch',*sessions], 'RunAtLoad':True,
        'KeepAlive':{'SuccessfulExit':False},'ThrottleInterval':30,
        'ProcessType':'Background','StandardOutPath':logs+'/watcher.log',
        'StandardErrorPath':logs+'/watcher-error.log','Umask':63},file)
PY
plutil -lint "$watcher_plist"
"$watcher_app/Contents/MacOS/ClaudeResume" doctor
launchctl enable "$watcher_service"
launchctl bootstrap "$watcher_domain" "$watcher_plist"
printf 'Installed for %s sessions. Logs: %s/watcher.log\n' "$((${#watcher_sessions[@]} / 2))" "$watcher_logs"
printf 'If Accessibility is false, run: open "%s" --args request-permission\n' "$watcher_app"

bash "$mac_source_dir/install-menu.sh"
