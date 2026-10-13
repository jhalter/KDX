#!/bin/bash
set -euo pipefail
if [[ $# -ne 1 || ! -f "$1" ]]; then
    echo 'Usage: scripts/build-apps.sh /path/to/KDX_1.6_OSX_intel.7z' >&2
    exit 1
fi
original_archive="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
swift build -c release --disable-sandbox --build-system native -debug-info-format none --cache-path "$PWD/.build/cache" --manifest-cache local
bin_path=$(swift build -c release --disable-sandbox --build-system native -debug-info-format none --cache-path "$PWD/.build/cache" --manifest-cache local --show-bin-path)
assets="$PWD/.build/original-assets"
"$bin_path/KDXAppearanceTool" export-all "$original_archive" "$assets"
appearance_catalog="$assets/OriginalAppearances.json"
server_appearance_catalog="$assets/OriginalServerAppearances.json"
for product in KDXClient KDXServer; do
    case "$product" in KDXClient) title="KDX Client";; KDXServer) title="KDX Server";; esac
    bundle="dist/$title.app"
    mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources/Notices"
    # Replace the inode so rebuilding does not modify pages mapped by a running app.
    cp "$bin_path/$product" "$bundle/Contents/MacOS/.$product.new"
    mv -f "$bundle/Contents/MacOS/.$product.new" "$bundle/Contents/MacOS/$product"
    cp "$assets/challenge-table.bin" "$bundle/Contents/Resources/challenge-table.bin"
    cp Notices/*.txt "$bundle/Contents/Resources/Notices/"
    if [[ "$product" == KDXServer ]]; then
        cp Resources/ServerIcon/ServerIcon.icns "$bundle/Contents/Resources/AppIcon.icns"
    else
        cp Resources/AppIcon/AppIcon.icns "$bundle/Contents/Resources/AppIcon.icns"
    fi
    icon_plist='<key>CFBundleIconFile</key><string>AppIcon.icns</string>'
    if [[ "$product" == KDXServer ]]; then
        cp "$server_appearance_catalog" "$bundle/Contents/Resources/OriginalAppearances.json"
    else
        cp "$appearance_catalog" "$bundle/Contents/Resources/OriginalAppearances.json"
    fi
    "$bin_path/KDXAppearanceTool" verify "$bundle/Contents/Resources/OriginalAppearances.json"
    cat > "$bundle/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>$product</string>
<key>CFBundleIdentifier</key><string>org.macos-kdx.$product</string>
<key>CFBundleName</key><string>$title</string>
<key>CFBundleDisplayName</key><string>$title</string>
$icon_plist
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSLocalNetworkUsageDescription</key><string>Connect to KDX servers and accept KDX client connections on your network.</string>
</dict></plist>
PLIST
    plutil -lint "$bundle/Contents/Info.plist"
    codesign --force --sign - "$bundle"
    codesign --verify --strict "$bundle"
done
