#!/usr/bin/env bash
# Clears Lolabunny downloaded servers, widget-server config, and temp runtime (pid / launch-args sig).
# Matches widget paths in Sources/LolabunnyWidgetCore/Config.swift (XDG data home + TMPDIR/.lolabunny).
set -euo pipefail

echo "Stopping lolabunny widget-server process if running..."
pkill -x lolabunny 2>/dev/null || true

DATA_ROOT="${XDG_DATA_HOME:-$HOME/.local/share}/.lolabunny"
echo "Removing: $DATA_ROOT/servers"
rm -rf "$DATA_ROOT/servers"

echo "Removing: $DATA_ROOT/config.toml"
rm -f "$DATA_ROOT/config.toml"

TMP_RUNTIME="${TMPDIR:-/tmp/}.lolabunny"
echo "Removing: $TMP_RUNTIME"
rm -rf "$TMP_RUNTIME"

echo "Done. Quit Lolabunny (if open), then reopen — you may need to download the widget-server again."
