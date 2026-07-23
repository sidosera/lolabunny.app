#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Lolabunny"
APP_EXECUTABLE="lolabunny-macos-app"
MIN_MACOS="13.0"
APP_PACKAGE_DIR="$ROOT_DIR"
BUILD_DIR="$ROOT_DIR/.build/lolabunny-macos-app-release"
BUNDLE_DIR="$BUILD_DIR/bundle"
DMG_STAGING_DIR="$BUILD_DIR/dmg-staging"
APP_BUNDLE="$BUNDLE_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
INFO_PLIST="$ROOT_DIR/Bundle/MacOSAppInfo.plist"
ENTITLEMENTS="$ROOT_DIR/Bundle/Lolabunny.entitlements"
ICON_SOURCE="$ROOT_DIR/bunny.png"
VERSION="$(tr -d '[:space:]' < "$ROOT_DIR/.version")"
DMG_PATH="$BUILD_DIR/lolabunny-macos-app@$VERSION.dmg"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$ROOT_DIR/.build/clang-module-cache}"

resolve_codesign_identity() {
    if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
        printf '%s\n' "$CODESIGN_IDENTITY"
        return
    fi

    local identity=""
    identity="$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' \
        | head -n 1)"
    if [[ -z "$identity" ]]; then
        identity="$(security find-identity -v -p codesigning 2>/dev/null \
            | sed -n 's/.*"\(Apple Development: .*\)"/\1/p' \
            | head -n 1)"
    fi
    if [[ -z "$identity" ]]; then
        identity="$(security find-identity -v -p codesigning 2>/dev/null \
            | sed -n 's/.*"\(Mac Developer: .*\)"/\1/p' \
            | head -n 1)"
    fi

    printf '%s\n' "${identity:--}"
}

CODESIGN_IDENTITY="$(resolve_codesign_identity)"

require_file() {
    local path="$1"
    local label="$2"

    if [[ ! -f "$path" ]]; then
        echo "$label not found: $path" >&2
        exit 1
    fi
}

triple_for_arch() {
    local arch="$1"

    case "$arch" in
        arm64) echo "arm64-apple-macos$MIN_MACOS" ;;
        x86_64) echo "x86_64-apple-macos$MIN_MACOS" ;;
        *)
            echo "unsupported arch: $arch" >&2
            exit 1
            ;;
    esac
}

scratch_path_for_arch() {
    local arch="$1"

    echo "$ROOT_DIR/.build/swiftpm/lolabunny-macos-app-$arch"
}

build_product() {
    local product="$1"
    local arch="$2"
    local scratch_path
    local swift_triple

    scratch_path="$(scratch_path_for_arch "$arch")"
    swift_triple="$(triple_for_arch "$arch")"

    swift build \
        --disable-sandbox \
        --package-path "$APP_PACKAGE_DIR" \
        --scratch-path "$scratch_path" \
        --configuration release \
        --product "$product" \
        --triple "$swift_triple"
}

show_bin_path() {
    local product="$1"
    local arch="$2"
    local scratch_path
    local swift_triple

    scratch_path="$(scratch_path_for_arch "$arch")"
    swift_triple="$(triple_for_arch "$arch")"

    swift build \
        --disable-sandbox \
        --package-path "$APP_PACKAGE_DIR" \
        --scratch-path "$scratch_path" \
        --configuration release \
        --product "$product" \
        --triple "$swift_triple" \
        --show-bin-path
}

create_universal_binary() {
    local product="$1"
    local output="$2"
    local arm64_bin
    local x86_64_bin

    arm64_bin="$(show_bin_path "$product" arm64)/$product"
    x86_64_bin="$(show_bin_path "$product" x86_64)/$product"
    require_file "$arm64_bin" "$product arm64 binary"
    require_file "$x86_64_bin" "$product x86_64 binary"
    lipo -create "$arm64_bin" "$x86_64_bin" -output "$output"
    chmod 755 "$output"
}

require_file "$INFO_PLIST" "Info.plist"
require_file "$ENTITLEMENTS" "Entitlements file"
require_file "$ICON_SOURCE" "Icon source"

rm -rf "$BUNDLE_DIR" "$DMG_STAGING_DIR" "$DMG_PATH"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

for arch in arm64 x86_64; do
    build_product "$APP_EXECUTABLE" "$arch"
done

create_universal_binary "$APP_EXECUTABLE" "$MACOS_DIR/$APP_EXECUTABLE"
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
codesign_args=(
    --force
    --deep
    --sign "$CODESIGN_IDENTITY"
    --entitlements "$ENTITLEMENTS"
)
if [[ "$CODESIGN_IDENTITY" != "-" ]]; then
    codesign_args+=(--options runtime --timestamp)
fi
codesign "${codesign_args[@]}" "$APP_BUNDLE"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

mkdir -p "$DMG_STAGING_DIR"
cp -R "$APP_BUNDLE" "$DMG_STAGING_DIR/$APP_NAME.app"
ln -s /Applications "$DMG_STAGING_DIR/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_STAGING_DIR" -ov -format UDZO "$DMG_PATH"
rm -rf "$DMG_STAGING_DIR"

echo "Bundle ready: $APP_BUNDLE"
echo "DMG ready: $DMG_PATH"
