#!/usr/bin/env bash
set -euo pipefail
umask 077
mac_source_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
menu_label="io.github.claude-ac.macos-menu"
menu_app="$HOME/Applications/Claude Auto Continue Menu.app"
menu_plist="$HOME/Library/LaunchAgents/$menu_label.plist"
menu_domain="gui/$(id -u)"
menu_service="$menu_domain/$menu_label"
menu_logs="$HOME/Library/Logs/Claude Auto Continue"
[[ $# -eq 0 || ( $# -eq 1 && "$1" == --uninstall ) ]] || { echo 'Usage: bash mac/install-menu.sh [--uninstall]' >&2; exit 2; }
if [[ $# -eq 0 ]]; then menu_built_app="$(bash "$mac_source_dir/build-menu.sh")"; fi
# launchctl print returns 113 only when this exact service is absent.
menu_loaded() {
    local info status
    if info="$(launchctl print "$menu_service" 2>&1)"; then return 0
    else status=$?; fi
    [[ "$status" -eq 113 ]] && return 1
    printf '%s\n' "$info" >&2
    exit "$status"
}
if menu_loaded; then
    launchctl bootout "$menu_service"
    for _ in {1..25}; do
        if ! menu_loaded; then break; fi
        sleep 0.2
    done
    if menu_loaded; then echo 'Menu app is still unloading.' >&2; exit 1; fi
fi
if [[ "${1:-}" == --uninstall ]]; then
    rm -f "$menu_plist"
    rm -rf "$menu_app"
    echo 'Menu app removed. Watcher configuration, state and logs retained.'
    exit 0
fi
mkdir -p "$HOME/Applications" "$(dirname "$menu_plist")" "$menu_logs"
if [[ -e "$menu_app" ]]; then rm -rf "$menu_app"; fi
ditto "$menu_built_app" "$menu_app"
python3 - "$menu_plist" "$menu_app/Contents/MacOS/ClaudeMenu" "$menu_logs" <<'PY'
import plistlib,sys
path,binary,logs=sys.argv[1:]
with open(path,'wb') as file:
    plistlib.dump({'Label':'io.github.claude-ac.macos-menu','ProgramArguments':[binary],
        'RunAtLoad':True,'KeepAlive':{'SuccessfulExit':False},'ThrottleInterval':30,
        'StandardOutPath':logs+'/menu.log','StandardErrorPath':logs+'/menu-error.log'},file)
PY
plutil -lint "$menu_plist"
launchctl enable "$menu_service"
launchctl bootstrap "$menu_domain" "$menu_plist"
echo 'Menu app installed. Look for AC with a circular-arrow icon in the macOS menu bar.'
