#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
BUILD_DIR="/tmp/mcp_hub_dashboard_desktop"
MODULE_CACHE_DIR="$BUILD_DIR/module-cache"
BIN="$BUILD_DIR/floating_dashboard"
SWIFT_SRC="$SCRIPT_DIR/FloatingDashboard.swift"
SNAPSHOT_SCRIPT="$SCRIPT_DIR/../compact_dashboard/export_snapshot.py"

mkdir -p "$BUILD_DIR" "$MODULE_CACHE_DIR"

swiftc -module-cache-path "$MODULE_CACHE_DIR" "$SWIFT_SRC" -o "$BIN"

if [ "$#" -eq 0 ]; then
  set -- --workspace "$WORKSPACE_ROOT"
fi

exec "$BIN" --snapshot-script "$SNAPSHOT_SCRIPT" "$@"
