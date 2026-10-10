#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
swift build -c release --disable-sandbox --build-system native -debug-info-format none --cache-path "$PWD/.build/cache" --manifest-cache local
bin_path=$(swift build -c release --disable-sandbox --build-system native -debug-info-format none --cache-path "$PWD/.build/cache" --manifest-cache local --show-bin-path)
for product in KDXClient KDXServer; do
    if [[ "$product" == KDXClient ]]; then title='KDX Client'; else title='KDX Server'; fi
    bundle="dist/$title.app"
    mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources/Notices"
    cp "$bin_path/$product" "$bundle/Contents/MacOS/$product"
    cp Notices/*.txt "$bundle/Contents/Resources/Notices/"
    cat > "$bundle/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>$product</string>
<key>CFBundleIdentifier</key><string>org.macos-kdx.$product</string>
<key>CFBundleName</key><string>$title</string>
<key>CFBundleDisplayName</key><string>$title</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSLocalNetworkUsageDescription</key><string>Connect to KDX servers and accept KDX client connections on your network.</string>
</dict></plist>
PLIST
    plutil -lint "$bundle/Contents/Info.plist"
    codesign --force --sign - "$bundle"
    codesign --verify --strict "$bundle"
done
