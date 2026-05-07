#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
APP_ROOT="$SCRIPT_DIR/Fabric.app"
CONTENTS_DIR="$APP_ROOT/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
APP_BIN="$MACOS_DIR/Fabric"
MODULE_CACHE_DIR="/tmp/fabric_app/module-cache"
SWIFT_SRC="$SCRIPT_DIR/FloatingDashboard.swift"
PLIST_TEMPLATE="$SCRIPT_DIR/DashboardInfo.plist"
ASSETS_DIR="$SCRIPT_DIR/assets"
COMPACT_DASHBOARD_SRC="$(cd "$SCRIPT_DIR/../compact_dashboard" && pwd -P)"
COMPACT_DASHBOARD_BUNDLE_DIR="$RESOURCES_DIR/compact_dashboard"
INSTALL_SRC="$(cd "$SCRIPT_DIR/../../install" && pwd -P)"
INSTALL_BUNDLE_DIR="$RESOURCES_DIR/install"
FABRIC_SRC="$(cd "$SCRIPT_DIR/../../fabric" && pwd -P)"
FABRIC_BUNDLE_DIR="$RESOURCES_DIR/fabric"
STATIC_ICON_SVG="$ASSETS_DIR/fabric-app-icon.svg"
ICON_GENERATOR_SRC="$SCRIPT_DIR/generate_app_icon.swift"
ICON_GENERATOR_BIN="$MODULE_CACHE_DIR/generate_app_icon"
ICONSET_DIR="$MODULE_CACHE_DIR/Fabric.iconset"
ICON_FILE="$RESOURCES_DIR/Fabric.icns"
ICON_PNG="$RESOURCES_DIR/Fabric.png"

rm -rf "$APP_ROOT"
mkdir -p "$MODULE_CACHE_DIR" "$MACOS_DIR" "$RESOURCES_DIR"
cp "$PLIST_TEMPLATE" "$CONTENTS_DIR/Info.plist"
swiftc -module-cache-path "$MODULE_CACHE_DIR" "$SWIFT_SRC" -o "$APP_BIN"
chmod +x "$APP_BIN"

rm -rf "$ICONSET_DIR"
swiftc -module-cache-path "$MODULE_CACHE_DIR" "$ICON_GENERATOR_SRC" -o "$ICON_GENERATOR_BIN"
"$ICON_GENERATOR_BIN" "$MODULE_CACHE_DIR" >/dev/null

if [[ ! -f "$STATIC_ICON_SVG" ]]; then
  echo "Missing static icon source: $STATIC_ICON_SVG" >&2
  exit 1
fi

cp "$ICONSET_DIR/icon_512x512@2x.png" "$ICON_PNG"
rm -f "$ICON_FILE"
if ! iconutil -c icns "$ICONSET_DIR" -o "$ICON_FILE"; then
  echo "error: iconutil could not build Fabric.icns from generated iconset" >&2
  exit 1
fi

if [[ -d "$ASSETS_DIR" ]]; then
  rsync -a "$ASSETS_DIR/" "$RESOURCES_DIR/"
fi

if [[ -d "$COMPACT_DASHBOARD_SRC" ]]; then
  rm -rf "$COMPACT_DASHBOARD_BUNDLE_DIR"
  mkdir -p "$COMPACT_DASHBOARD_BUNDLE_DIR"
  rsync -a \
    --exclude "__pycache__/" \
    --exclude "tests/" \
    "$COMPACT_DASHBOARD_SRC/" \
    "$COMPACT_DASHBOARD_BUNDLE_DIR/"
fi

if [[ -d "$INSTALL_SRC" ]]; then
  rm -rf "$INSTALL_BUNDLE_DIR"
  mkdir -p "$INSTALL_BUNDLE_DIR"
  rsync -a \
    --exclude "__pycache__/" \
    --exclude ".env.local" \
    --exclude "paths.yaml" \
    "$INSTALL_SRC/" \
    "$INSTALL_BUNDLE_DIR/"
fi

if [[ -d "$FABRIC_SRC" ]]; then
  rm -rf "$FABRIC_BUNDLE_DIR"
  mkdir -p "$FABRIC_BUNDLE_DIR"
  rsync -a \
    --exclude "__pycache__/" \
    --exclude "*.ndjson" \
    "$FABRIC_SRC/" \
    "$FABRIC_BUNDLE_DIR/"
fi

# Finder tends to hold onto stale icon previews if the app bundle mtime does not move.
touch "$APP_ROOT" "$CONTENTS_DIR" "$MACOS_DIR" "$RESOURCES_DIR" "$CONTENTS_DIR/Info.plist"

# Build outputs on macOS can inherit provenance/quarantine attributes from copied
# resources. Clear them and seal the final app bundle with an ad-hoc signature so
# Gatekeeper does not see a half-signed bundle as damaged.
xattr -cr "$APP_ROOT" 2>/dev/null || true
codesign --force --deep --sign - "$APP_ROOT" >/dev/null
codesign --verify --deep --strict "$APP_ROOT"
