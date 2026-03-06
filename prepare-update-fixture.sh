#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION_FILE="$ROOT_DIR/.version"
SERVER_MANIFEST="$ROOT_DIR/app-server/Cargo.toml"

if [[ ! -f "$VERSION_FILE" || ! -f "$SERVER_MANIFEST" ]]; then
    echo "Run this script from the lolabunny.app repo root." >&2
    exit 1
fi

OLD_VERSION="${1:-${OLD_VERSION:-v1.0.1-beta+10}}"
NEW_VERSION="${2:-${NEW_VERSION:-v1.1-beta+1}}"
SERVER_ROOT="${SERVER_ROOT:-$HOME/.local/share/.lolabunny}"
ARCH_TOKEN="${ARCH_TOKEN:-$(uname -m)}"
CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$HOME/.cache/lolabunny-update-fixture-target}"
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

INSTALLED_BINARY="$SERVER_ROOT/servers/$OLD_VERSION/$ARCH_TOKEN/lolabunny"
LATEST_BINARY="$SERVER_ROOT/servers/.latest/$NEW_VERSION/$ARCH_TOKEN/lolabunny"

if [[ "$CLEAR_EXISTING" == "1" ]]; then
    rm -rf "$(dirname "$INSTALLED_BINARY")" "$(dirname "$LATEST_BINARY")"
fi

build_and_install() {
    local version="$1"
    local destination="$2"

    printf '%s\n' "$version" > "$VERSION_FILE"
    CARGO_TARGET_DIR="$CARGO_TARGET_DIR" cargo build --release --manifest-path "$SERVER_MANIFEST" >/dev/null
    mkdir -p "$(dirname "$destination")"
    install -m 755 "$CARGO_TARGET_DIR/release/lolabunny" "$destination"
}

echo "Preparing update fixture: installed=$OLD_VERSION latest=$NEW_VERSION arch=$ARCH_TOKEN"
build_and_install "$OLD_VERSION" "$INSTALLED_BINARY"
build_and_install "$NEW_VERSION" "$LATEST_BINARY"

echo
echo "Fixture ready."
echo "Installed binary: $INSTALLED_BINARY"
echo "Latest binary:    $LATEST_BINARY"
echo
echo "To re-run with custom versions:"
echo "  bash \"$ROOT_DIR/prepare-update-fixture.sh\" v1.0.0 v1.1.0"
