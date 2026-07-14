#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION_FILE="$ROOT_DIR/.version"
PACKAGE_MANIFEST="$ROOT_DIR/Package.swift"

if [[ ! -f "$VERSION_FILE" || ! -f "$PACKAGE_MANIFEST" ]]; then
    echo "Run this script from the lolabunny.app repo root." >&2
    exit 1
fi

OLD_VERSION="${1:-${OLD_VERSION:-v1.0.1-beta+10}}"
NEW_VERSION="${2:-${NEW_VERSION:-v1.1-beta+1}}"
DATA_ROOT="${DATA_ROOT:-$HOME/.local/share/.lolabunny}"
SWIFT_SCRATCH_PATH="${SWIFT_SCRATCH_PATH:-$HOME/.cache/lolabunny-update-fixture-swiftpm}"
CLEAR_EXISTING="${CLEAR_EXISTING:-1}"
STOP_RUNNING="${STOP_RUNNING:-1}"

if [[ "$OLD_VERSION" == "$NEW_VERSION" ]]; then
    echo "OLD_VERSION and NEW_VERSION must be different." >&2
    exit 1
fi

ORIGINAL_VERSION_FILE="$(mktemp)"
cp "$VERSION_FILE" "$ORIGINAL_VERSION_FILE"
restore_version_file() {
    cp "$ORIGINAL_VERSION_FILE" "$VERSION_FILE"
    rm -f "$ORIGINAL_VERSION_FILE"
}
trap restore_version_file EXIT

RUNTIME_DIR="$(python3 - <<'PY'
import os
import tempfile
print(os.path.join(tempfile.gettempdir(), ".lolabunny"))
PY
)"

if [[ "$STOP_RUNNING" == "1" && -f "$RUNTIME_DIR/pid" ]]; then
    PID="$(tr -d '[:space:]' < "$RUNTIME_DIR/pid" || true)"
    if [[ -n "$PID" ]] && kill -0 "$PID" 2>/dev/null; then
        kill "$PID" 2>/dev/null || true
        sleep 0.3
    fi
fi

rm -f "$RUNTIME_DIR/pid" "$RUNTIME_DIR/server-args.sig"

INSTALLED_BINARY="$DATA_ROOT/servers/$OLD_VERSION/server"
LATEST_BINARY="$DATA_ROOT/servers/$NEW_VERSION.locked/server"

if [[ "$CLEAR_EXISTING" == "1" ]]; then
    rm -rf "$(dirname "$INSTALLED_BINARY")" "$(dirname "$LATEST_BINARY")"
fi

build_and_install() {
    local version="$1"
    local destination="$2"

    printf '%s\n' "$version" > "$VERSION_FILE"
    swift build \
        --disable-sandbox \
        --package-path "$ROOT_DIR" \
        --scratch-path "$SWIFT_SCRATCH_PATH" \
        --configuration release \
        --product server

    bin_dir="$(swift build \
        --disable-sandbox \
        --package-path "$ROOT_DIR" \
        --scratch-path "$SWIFT_SCRATCH_PATH" \
        --configuration release \
        --product server \
        --show-bin-path)"
    mkdir -p "$(dirname "$destination")"
    install -m 755 "$bin_dir/server" "$destination"
}

echo "Preparing update fixture: installed=$OLD_VERSION latest=$NEW_VERSION"
build_and_install "$OLD_VERSION" "$INSTALLED_BINARY"
build_and_install "$NEW_VERSION" "$LATEST_BINARY"

echo
echo "Fixture ready."
echo "Installed binary: $INSTALLED_BINARY"
echo "Latest binary:    $LATEST_BINARY"
echo
echo "To re-run with custom versions:"
echo "  bash \"$ROOT_DIR/prepare-update-fixture.sh\" v1.0.0 v1.1.0"
