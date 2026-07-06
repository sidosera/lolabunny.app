#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION_FILE="$ROOT_DIR/.version"

default_version="v0.0.0"
if [[ -f "$VERSION_FILE" ]]; then
  detected_version="$(tr -d '[:space:]' < "$VERSION_FILE" || true)"
  if [[ -n "$detected_version" ]]; then
    default_version="$detected_version"
  fi
fi

VERSION="${1:-${VERSION:-$default_version}}"
ARCH_INPUT="${2:-${ARCH:-$(uname -m)}}"

case "$ARCH_INPUT" in
  arm64|aarch64)
    ARCH="arm64"
    SWIFT_TRIPLE="arm64-apple-macos12.0"
    ;;
  x86_64|amd64)
    ARCH="x86_64"
    SWIFT_TRIPLE="x86_64-apple-macos12.0"
    ;;
  *)
    echo "Unsupported arch: $ARCH_INPUT (expected arm64 or x86_64)" >&2
    exit 1
    ;;
esac

BINARY_PATH="${BINARY_PATH:-$ROOT_DIR/build/swiftpm/app-server/$SWIFT_TRIPLE/release/lolabunny}"
if [[ ! -f "$BINARY_PATH" ]]; then
  cat >&2 <<EOF
Missing backend binary at:
  $BINARY_PATH

Build it first, for example:
  swift build --package-path "$ROOT_DIR/app-server" --scratch-path "$ROOT_DIR/build/swiftpm/app-server" --configuration release --product lolabunny --triple $SWIFT_TRIPLE
EOF
  exit 1
fi

MOCK_ROOT="${MOCK_ROOT:-$ROOT_DIR/.local-updates}"
RELEASES_DIR="$MOCK_ROOT/releases"
DOWNLOAD_DIR="$RELEASES_DIR/download/$VERSION"
ARCHIVE_NAME="lolabunny-${VERSION}-darwin-${ARCH}.tar.gz"

mkdir -p "$DOWNLOAD_DIR"

tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

cp "$BINARY_PATH" "$tmp_dir/lolabunny"
chmod 755 "$tmp_dir/lolabunny"
(cd "$tmp_dir" && shasum -a 256 lolabunny > lolabunny.sha256)
printf '%s\n' "$VERSION" > "$tmp_dir/.version"
archive_files=(lolabunny lolabunny.sha256 .version)
if [[ -d "$ROOT_DIR/lola-core" ]]; then
  cp -R "$ROOT_DIR/lola-core" "$tmp_dir/"
  archive_files+=(lola-core)
fi
tar czf "$DOWNLOAD_DIR/$ARCHIVE_NAME" -C "$tmp_dir" "${archive_files[@]}"

printf '/releases/tag/%s\n' "$VERSION" > "$RELEASES_DIR/latest"

cat <<EOF
Local release mock prepared.

Latest pointer:
  $RELEASES_DIR/latest

Archive:
  $DOWNLOAD_DIR/$ARCHIVE_NAME

Configure app for local mock:
  LolabunnyUpdateArchiveBaseURL = $RELEASES_DIR
  LolabunnyUpdateArchiveVersion = latest
EOF
