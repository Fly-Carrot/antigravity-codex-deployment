#!/bin/zsh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
VERSION="4.0.0"
APP_PATH="$REPO_ROOT/tools/compact_dashboard_desktop/Fabric.app"
DIST_DIR="$REPO_ROOT/dist"
ARCHIVE_NAME="Fabric-v${VERSION}-macOS.zip"
CHECKSUM_NAME="${ARCHIVE_NAME}.sha256.txt"

mkdir -p "$DIST_DIR"
"$REPO_ROOT/tools/compact_dashboard_desktop/build_dashboard_app.sh"
rm -f "$DIST_DIR/$ARCHIVE_NAME" "$DIST_DIR/$CHECKSUM_NAME"

xattr -cr "$APP_PATH" 2>/dev/null || true
codesign --verify --deep --strict "$APP_PATH"

(
  cd "$REPO_ROOT/tools/compact_dashboard_desktop"
  COPYFILE_DISABLE=1 /usr/bin/zip -qryX "$DIST_DIR/$ARCHIVE_NAME" "Fabric.app"
)
(
  cd "$REPO_ROOT"
  shasum -a 256 "dist/$ARCHIVE_NAME" > "dist/$CHECKSUM_NAME"
)

echo "$DIST_DIR/$ARCHIVE_NAME"
echo "$DIST_DIR/$CHECKSUM_NAME"
