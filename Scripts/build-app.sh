#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
./Scripts/build.sh
app_path="$PWD/dist/InputBridge.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
# APFS is normally case-insensitive: InputBridge and inputbridge collide.
if [[ -f "$app_path/Contents/MacOS/InputBridge" ]]; then rm "$app_path/Contents/MacOS/InputBridge"; fi
cp .build/release/InputBridgeApp "$app_path/Contents/MacOS/InputBridgeMenu"
cp .build/release/inputbridge .build/release/inputbridge-ddc "$app_path/Contents/MacOS/"
cp LICENSE "$app_path/Contents/Resources/LICENSE.txt"
cp ThirdParty/AppleSiliconDDC/LICENSE "$app_path/Contents/Resources/AppleSiliconDDC-LICENSE.txt"
cp README.md "$app_path/Contents/Resources/README.md"
mkdir -p "$app_path/Contents/Resources/Docs" "$app_path/Contents/Resources/ThirdParty"
cp Docs/*.md "$app_path/Contents/Resources/Docs/"
cp ThirdParty/README.md "$app_path/Contents/Resources/ThirdParty/"
xcrun swift Scripts/make-icon.swift .build/AppIcon.iconset
iconutil --convert icns .build/AppIcon.iconset --output "$app_path/Contents/Resources/AppIcon.icns"
python3 Scripts/seed-calibration.py Diagnostics "$app_path/Contents/Resources/InitialCalibration.json"
python3 - "$app_path" <<'PY'
import plistlib, sys
from pathlib import Path
app = Path(sys.argv[1])
info = {'CFBundleExecutable':'InputBridgeMenu', 'CFBundleIdentifier':'dev.adachi.InputBridge',
        'CFBundleName':'InputBridge', 'CFBundleDisplayName':'InputBridge', 'CFBundlePackageType':'APPL',
        'CFBundleShortVersionString':'1.0.2', 'CFBundleVersion':'3', 'CFBundleIconFile':'AppIcon',
        'CFBundleDevelopmentRegion':'ja', 'LSMinimumSystemVersion':'13.0', 'LSUIElement':False,
        'NSHighResolutionCapable':True, 'NSSupportsAutomaticTermination':False,
        'NSSupportsSuddenTermination':False, 'LSApplicationCategoryType':'public.app-category.utilities',
        'NSHumanReadableCopyright':'MIT License · AppleSiliconDDC by @waydabber'}
with (app/'Contents/Info.plist').open('wb') as handle:
    plistlib.dump(info,handle)
PY
codesign --force --sign - --options runtime --timestamp=none --identifier dev.adachi.InputBridge.cli "$app_path/Contents/MacOS/inputbridge"
codesign --force --sign - --options runtime --timestamp=none --identifier dev.adachi.InputBridge.ddc "$app_path/Contents/MacOS/inputbridge-ddc"
codesign --force --sign - --options runtime --timestamp=none "$app_path"
codesign --verify --deep --strict "$app_path"
print "Built: $app_path"
