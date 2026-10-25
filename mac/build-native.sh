#!/usr/bin/env bash
set -euo pipefail
mac_source_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
swift build --package-path "$mac_source_dir/native" -c release >&2
mac_binary_dir="$(swift build --package-path "$mac_source_dir/native" -c release --show-bin-path)"
mac_app="$mac_source_dir/native/.build/Claude Auto Continue.app"
mkdir -p "$mac_app/Contents/MacOS"
cp "$mac_binary_dir/ClaudeResume" "$mac_app/Contents/MacOS/ClaudeResume"
python3 - "$mac_app/Contents/Info.plist" <<'PY'
import plistlib,sys
with open(sys.argv[1], 'wb') as file:
    plistlib.dump({'CFBundleIdentifier':'io.github.claude-ac.macos-watcher',
                  'CFBundleExecutable':'ClaudeResume','CFBundleName':'Claude Auto Continue',
                  'CFBundlePackageType':'APPL','CFBundleVersion':'1','CFBundleShortVersionString':'0.1.0',
                  'LSMinimumSystemVersion':'13.0','LSUIElement':True}, file)
PY
codesign --force --sign - --identifier io.github.claude-ac.macos-watcher "$mac_app" >&2
printf '%s\n' "$mac_app"
