#!/bin/zsh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$REPO_ROOT"

python3 -m unittest discover tests
python3 -m unittest discover tools/compact_dashboard/tests

SWIFTC_BIN="$(xcrun -find swiftc)"
SDKROOT_PATH="$(xcrun --sdk macosx --show-sdk-path)"
VERIFY_MODULE_CACHE="$REPO_ROOT/.build/verify-module-cache"
mkdir -p "$VERIFY_MODULE_CACHE"
"$SWIFTC_BIN" \
  -sdk "$SDKROOT_PATH" \
  -module-cache-path "$VERIFY_MODULE_CACHE" \
  -typecheck \
  tools/compact_dashboard_desktop/FloatingDashboard.swift

./tools/compact_dashboard_desktop/build_dashboard_app.sh

echo "VERIFY_OK"
