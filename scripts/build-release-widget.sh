#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Lolabunny"
APP_EXECUTABLE="widget"
MIN_MACOS="13.0"
APP_PACKAGE_DIR="$ROOT_DIR"
BUILD_DIR="$ROOT_DIR/.build/lolabunny-release"
SWIFT_SCRATCH_PATH="$ROOT_DIR/.build/swiftpm/widget-arm64"
BUNDLE_DIR="$BUILD_DIR/bundle"
DMG_STAGING_DIR="$BUILD_DIR/dmg-staging"
APP_BUNDLE="$BUNDLE_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
INFO_PLIST="$ROOT_DIR/Bundle/Info.plist"
ENTITLEMENTS="$ROOT_DIR/Bundle/Lolabunny.entitlements"
ICON_SOURCE="$ROOT_DIR/bunny.png"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
VERSION="$(tr -d '[:space:]' < "$ROOT_DIR/.version")"
DMG_PATH="$BUILD_DIR/$APP_NAME-$VERSION-arm64.dmg"
SWIFT_TRIPLE="arm64-apple-macos$MIN_MACOS"

require_file() {
    local path="$1"
    local label="$2"

    if [[ ! -f "$path" ]]; then
        echo "$label not found: $path" >&2
        exit 1
    fi
}

require_file "$INFO_PLIST" "Info.plist"
require_file "$ENTITLEMENTS" "Entitlements file"
require_file "$ICON_SOURCE" "Icon source"

rm -rf "$BUNDLE_DIR" "$DMG_STAGING_DIR" "$DMG_PATH"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

swift build \
    --disable-sandbox \
    --package-path "$APP_PACKAGE_DIR" \
    --scratch-path "$SWIFT_SCRATCH_PATH" \
    --configuration release \
    --product "$APP_EXECUTABLE" \
    --triple "$SWIFT_TRIPLE"

bin_dir="$(swift build \
    --disable-sandbox \
    --package-path "$APP_PACKAGE_DIR" \
    --scratch-path "$SWIFT_SCRATCH_PATH" \
    --configuration release \
    --product "$APP_EXECUTABLE" \
    --triple "$SWIFT_TRIPLE" \
    --show-bin-path)"

swift_bin="$bin_dir/$APP_EXECUTABLE"
require_file "$swift_bin" "Swift binary"

install -m 755 "$swift_bin" "$MACOS_DIR/$APP_EXECUTABLE"
strip "$MACOS_DIR/$APP_EXECUTABLE"
cp "$INFO_PLIST" "$CONTENTS_DIR/Info.plist"
printf 'APPL????' > "$CONTENTS_DIR/PkgInfo"

if [[ -f "$ROOT_DIR/.version" ]]; then
    cp "$ROOT_DIR/.version" "$RESOURCES_DIR/.version"
else
    printf 'dev' > "$RESOURCES_DIR/.version"
fi

sips -z 18 18 "$ICON_SOURCE" --out "$RESOURCES_DIR/bunny.png" >/dev/null
sips -z 36 36 "$ICON_SOURCE" --out "$RESOURCES_DIR/bunny@2x.png" >/dev/null

iconset_dir="$RESOURCES_DIR/AppIcon.iconset"
mkdir -p "$iconset_dir"
icon_specs=(
    "16:icon_16x16.png"
    "32:icon_16x16@2x.png"
    "32:icon_32x32.png"
    "64:icon_32x32@2x.png"
    "128:icon_128x128.png"
    "256:icon_128x128@2x.png"
    "256:icon_256x256.png"
    "512:icon_256x256@2x.png"
    "512:icon_512x512.png"
    "1024:icon_512x512@2x.png"
)

for icon_spec in "${icon_specs[@]}"; do
    icon_size="${icon_spec%%:*}"
    icon_name="${icon_spec#*:}"
    sips -z "$icon_size" "$icon_size" "$ICON_SOURCE" --out "$iconset_dir/$icon_name" >/dev/null
done

iconutil --convert icns "$iconset_dir" --output "$RESOURCES_DIR/AppIcon.icns"
rm -rf "$iconset_dir"

echo "Signing with identity: $CODESIGN_IDENTITY"
codesign --force --deep \
    --sign "$CODESIGN_IDENTITY" \
    --entitlements "$ENTITLEMENTS" \
    "$APP_BUNDLE"

mkdir -p "$DMG_STAGING_DIR"
cp -R "$APP_BUNDLE" "$DMG_STAGING_DIR/$APP_NAME.app"
ln -s /Applications "$DMG_STAGING_DIR/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_STAGING_DIR" -ov -format UDZO "$DMG_PATH"
rm -rf "$DMG_STAGING_DIR"

echo "Bundle ready: $APP_BUNDLE"
echo "DMG ready: $DMG_PATH"
