#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
export CLANG_MODULE_CACHE_PATH="${PWD}/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="${PWD}/.build/module-cache"
swift build -c release --disable-sandbox
app="${PWD}/dist/SpaceLabeler.app"
mkdir -p "$app/Contents/MacOS"
cp .build/release/SpaceLabeler "$app/Contents/MacOS/SpaceLabeler"
cp Info.plist "$app/Contents/Info.plist"
codesign --force --sign - "$app"
echo "Built $app"
