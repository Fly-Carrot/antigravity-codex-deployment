#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
APP_ROOT="$SCRIPT_DIR/Shared Fabric Dashboard.app"
CONTENTS_DIR="$APP_ROOT/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
APP_BIN="$MACOS_DIR/SharedFabricDashboard"
MODULE_CACHE_DIR="/tmp/shared_fabric_dashboard_app/module-cache"
SWIFT_SRC="$SCRIPT_DIR/FloatingDashboard.swift"
PLIST_TEMPLATE="$SCRIPT_DIR/DashboardInfo.plist"
ASSETS_DIR="$SCRIPT_DIR/assets"
STATIC_ICON_SVG="$ASSETS_DIR/shared-fabric-app-icon.svg"
ICONSET_DIR="$MODULE_CACHE_DIR/SharedFabricDashboard.iconset"
ICON_FILE="$RESOURCES_DIR/SharedFabricDashboard.icns"
ICON_PNG="$RESOURCES_DIR/SharedFabricDashboard.png"
ICON_TIFF_DIR="$MODULE_CACHE_DIR/icon-tiff"
ICON_TIFF_FILE="$ICON_TIFF_DIR/SharedFabricDashboard.tiff"
MASTER_ICON_PNG="$MODULE_CACHE_DIR/SharedFabricDashboard-master.png"

mkdir -p "$MODULE_CACHE_DIR" "$MACOS_DIR" "$RESOURCES_DIR" "$ICON_TIFF_DIR"
cp "$PLIST_TEMPLATE" "$CONTENTS_DIR/Info.plist"
swiftc -module-cache-path "$MODULE_CACHE_DIR" "$SWIFT_SRC" -o "$APP_BIN"
chmod +x "$APP_BIN"

rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"

if [[ ! -f "$STATIC_ICON_SVG" ]]; then
  echo "Missing static icon source: $STATIC_ICON_SVG" >&2
  exit 1
fi

if sips -s format png "$STATIC_ICON_SVG" --out "$MASTER_ICON_PNG" >/dev/null; then
  for pair in \
    "16:icon_16x16.png" \
    "32:icon_16x16@2x.png" \
    "32:icon_32x32.png" \
    "64:icon_32x32@2x.png" \
    "128:icon_128x128.png" \
    "256:icon_128x128@2x.png" \
    "256:icon_256x256.png" \
    "512:icon_256x256@2x.png" \
    "512:icon_512x512.png" \
    "1024:icon_512x512@2x.png"
  do
    size="${pair%%:*}"
    name="${pair#*:}"
    sips -z "$size" "$size" "$MASTER_ICON_PNG" --out "$ICONSET_DIR/$name" >/dev/null
  done

  cp "$ICONSET_DIR/icon_512x512@2x.png" "$ICON_PNG"
  rm -f "$ICON_FILE"
  if ! iconutil -c icns "$ICONSET_DIR" -o "$ICON_FILE"; then
    echo "warning: iconutil could not build SharedFabricDashboard.icns; trying TIFF fallback" >&2
    find "$ICON_TIFF_DIR" -type f -delete
    for png in "$ICONSET_DIR"/*.png; do
      base="$(basename "$png" .png)"
      sips -s format tiff "$png" --out "$ICON_TIFF_DIR/$base.tiff" >/dev/null
    done
    tiffutil -cat "$ICON_TIFF_DIR"/*.tiff -out "$ICON_TIFF_FILE" >/dev/null
    if ! tiff2icns "$ICON_TIFF_FILE" "$ICON_FILE"; then
      echo "warning: tiff2icns fallback also failed; runtime PNG icon fallback will be used" >&2
    fi
  fi
else
  echo "warning: could not rasterize $STATIC_ICON_SVG with sips; keeping any existing bundle icon assets" >&2
fi

if [[ -d "$ASSETS_DIR" ]]; then
  rsync -a "$ASSETS_DIR/" "$RESOURCES_DIR/"
fi

# Finder tends to hold onto stale icon previews if the app bundle mtime does not move.
touch "$APP_ROOT" "$CONTENTS_DIR" "$MACOS_DIR" "$RESOURCES_DIR" "$CONTENTS_DIR/Info.plist"
