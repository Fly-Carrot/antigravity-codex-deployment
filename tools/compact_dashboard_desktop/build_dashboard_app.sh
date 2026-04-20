#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
APP_ROOT="$SCRIPT_DIR/MCP Hub Dashboard.app"
CONTENTS_DIR="$APP_ROOT/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
APP_BIN="$MACOS_DIR/MCPHubDashboard"
MODULE_CACHE_DIR="/tmp/mcp_hub_dashboard_app/module-cache"
SWIFT_SRC="$SCRIPT_DIR/FloatingDashboard.swift"
PLIST_TEMPLATE="$SCRIPT_DIR/DashboardInfo.plist"

mkdir -p "$MODULE_CACHE_DIR" "$MACOS_DIR"
cp "$PLIST_TEMPLATE" "$CONTENTS_DIR/Info.plist"
swiftc -module-cache-path "$MODULE_CACHE_DIR" "$SWIFT_SRC" -o "$APP_BIN"
chmod +x "$APP_BIN"
