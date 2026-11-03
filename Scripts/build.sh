#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
swift build --disable-sandbox --cache-path .build/cache -c release
mkdir -p dist
cp .build/release/inputbridge .build/release/inputbridge-ddc dist/
cp LICENSE README.md dist/
cp ThirdParty/AppleSiliconDDC/LICENSE dist/AppleSiliconDDC-LICENSE.txt
mkdir -p dist/Docs dist/ThirdParty
cp Docs/Feasibility.md dist/Docs/
cp ThirdParty/README.md dist/ThirdParty/
print "Built: $PWD/dist/inputbridge"
