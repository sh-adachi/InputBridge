#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
app_source="$PWD/dist/InputBridge.app"
app_destination="${1:-/Applications/InputBridge.app}"
if [[ ! -d "$app_source" ]]; then
  print -u2 "先に ./Scripts/build-app.sh を実行してください。"
  exit 1
fi
if pgrep -f "$app_destination/Contents/MacOS/InputBridgeMenu" >/dev/null; then
  print -u2 "InputBridgeを終了してから、もう一度インストールしてください。"
  exit 1
fi
if [[ -f "$app_destination/Contents/Info.plist" ]]; then
  existing_identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_destination/Contents/Info.plist")
  if [[ "$existing_identifier" != "dev.adachi.InputBridge" ]]; then
    print -u2 "同名の別アプリがあるため、インストールを中止しました。"
    exit 1
  fi
fi
mkdir -p "${app_destination:h}"
ditto "$app_source" "$app_destination"
codesign --verify --deep --strict "$app_destination"
open "$app_destination"
print "Installed: $app_destination"
