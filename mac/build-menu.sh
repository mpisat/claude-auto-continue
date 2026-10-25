#!/usr/bin/env bash
set -euo pipefail
mac_source_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
swift build --package-path "$mac_source_dir/native" -c release --product ClaudeMenu >&2
menu_binary_dir="$(swift build --package-path "$mac_source_dir/native" -c release --show-bin-path)"
menu_app="$mac_source_dir/native/.build/Claude Auto Continue Menu.app"
mkdir -p "$menu_app/Contents/MacOS" "$menu_app/Contents/Resources/mac"
cp "$menu_binary_dir/ClaudeMenu" "$menu_app/Contents/MacOS/ClaudeMenu"
cp "$mac_source_dir/../Makefile" "$mac_source_dir/../CONTROL.md" "$menu_app/Contents/Resources/"
cp "$mac_source_dir/README.md" "$mac_source_dir/VALIDATION.md" "$menu_app/Contents/Resources/mac/"
python3 - "$menu_app/Contents/Info.plist" <<'PY'
import plistlib,sys
with open(sys.argv[1], 'wb') as file:
    plistlib.dump({'CFBundleIdentifier':'io.github.claude-ac.macos-menu',
                  'CFBundleExecutable':'ClaudeMenu','CFBundleName':'Claude Auto Continue Menu',
                  'CFBundlePackageType':'APPL','CFBundleVersion':'1','CFBundleShortVersionString':'0.1.0',
                  'LSMinimumSystemVersion':'13.0','LSUIElement':True,
                  'LSMultipleInstancesProhibited':True},file)
PY
codesign --force --sign - --identifier io.github.claude-ac.macos-menu "$menu_app" >&2
printf '%s\n' "$menu_app"
