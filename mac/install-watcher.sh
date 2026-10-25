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
if [[ "${1:-}" == "--uninstall" ]]; then
    launchctl bootout "$watcher_domain" "$watcher_plist" 2>/dev/null || true
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
            watcher_sessions+=("--session" "$2"); shift 2 ;;
        *) echo 'Usage: bash mac/install-watcher.sh --session local_ID [--session local_ID ...] | --uninstall' >&2; exit 2 ;;
    esac
done
[[ ${#watcher_sessions[@]} -gt 0 ]] || { echo 'Specify the existing Code session IDs with --session; use ClaudeResume list to inspect them.' >&2; exit 2; }
watcher_built_app="$(bash "$mac_source_dir/build-native.sh")"
mkdir -p "$HOME/Applications" "$(dirname "$watcher_plist")" "$watcher_data" "$watcher_logs"
launchctl bootout "$watcher_domain" "$watcher_plist" 2>/dev/null || true
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
launchctl bootstrap "$watcher_domain" "$watcher_plist"
printf 'Installed for %s sessions. Logs: %s/watcher.log\n' "$((${#watcher_sessions[@]} / 2))" "$watcher_logs"
printf 'If Accessibility is false, run: open "%s" --args request-permission\n' "$watcher_app"
