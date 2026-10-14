#!/bin/bash
# Build both universal apps, sign, notarize, staple, and package for GitHub.
set -euo pipefail
if [[ $# -ne 2 || "$1" == --help ]]; then
    echo "Usage: $0 VERSION /path/to/KDX_1.6_OSX_intel.7z"
    echo 'Environment: BUILD_NUMBER (default 1), SIGN_IDENTITY, NOTARY_PROFILE'
    exit 1
fi
cd "$(dirname "$0")/.."
version="$1"
[[ "$version" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?((a|b|rc)[0-9]+)?$ ]] || { echo 'Invalid version' >&2; exit 1; }
identity="${SIGN_IDENTITY:-Developer ID Application: Jeff Halter (DUYJJ3L797)}"
profile="${NOTARY_PROFILE:-phosphor-notary}"
output="$PWD/dist/v$version"
if [[ -e "$output" ]]; then
    echo "Refusing to overwrite existing candidate: $output" >&2
    exit 1
fi
VERSION="$version" UNIVERSAL=1 scripts/build-apps.sh "$2"
mkdir -p "$output"
for product in KDXClient KDXServer; do
    case "$product" in KDXClient) title='KDX Client';; KDXServer) title='KDX Server';; esac
    app="$output/$title.app"
    ditto "dist/$title.app" "$app"
    archs="$(lipo -archs "$app/Contents/MacOS/$product")"
    [[ "$archs" == 'x86_64 arm64' || "$archs" == 'arm64 x86_64' ]]
    [[ "$(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")" == "$version" ]]
    codesign --force --options runtime --timestamp --sign "$identity" "$app"
    details="$(codesign -dvvv "$app" 2>&1)"
    [[ "$details" == *'Authority=Developer ID Application:'* && "$details" == *'runtime'* ]]
    codesign --verify --deep --strict --verbose=2 "$app"
    zip="$output/$product-v$version.zip"
    ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"
    # Retain the submission ID and result for recovery and independent checks.
    xcrun notarytool submit "$zip" --keychain-profile "$profile" --wait --output-format json > "$output/$product-notary.json"
    cat "$output/$product-notary.json"
    [[ "$(plutil -extract status raw "$output/$product-notary.json")" == Accepted ]]
    xcrun stapler staple "$app"
    xcrun stapler validate "$app"
    spctl --assess --type execute --verbose=2 "$app"
    # The downloadable archive must contain the stapled app.
    rm "$zip"
    ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"
done
(cd "$output" && shasum -a 256 KDXClient-*.zip KDXServer-*.zip > SHA256SUMS.txt)
echo "Verified release artifacts: $output"
