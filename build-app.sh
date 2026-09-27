#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
export CLANG_MODULE_CACHE_PATH="${PWD}/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="${PWD}/.build/module-cache"
swift build -c release --disable-sandbox
app="${PWD}/dist/SpaceLabeler.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/SpaceLabeler "$app/Contents/MacOS/SpaceLabeler"
cp Info.plist "$app/Contents/Info.plist"
cp assets/top-bar-logo.png "$app/Contents/Resources/top-bar-logo.png"
cp assets/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
xattr -cr "$app"
codesign --force --sign - "$app"
echo "Built $app"
