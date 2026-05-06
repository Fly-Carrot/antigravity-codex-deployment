#!/bin/zsh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
DEMO_ROOT="${1:-/tmp/fabric-release-demo}"
WORKSPACE_SLUG="${2:-signal-garden}"
APP_BIN="$REPO_ROOT/tools/compact_dashboard_desktop/Fabric.app/Contents/MacOS/Fabric"
SNAPSHOT_SCRIPT="$REPO_ROOT/tools/compact_dashboard/export_snapshot.py"
SETTINGS_PATH="$DEMO_ROOT/gemini-settings.json"
GLOBAL_ROOT="$DEMO_ROOT/global-root"
VAULT_ROOT="$DEMO_ROOT/vault"
WORKSPACE_PATH="$DEMO_ROOT/workspaces/$WORKSPACE_SLUG"

if [[ ! -x "$APP_BIN" ]]; then
  "$REPO_ROOT/tools/compact_dashboard_desktop/build_dashboard_app.sh"
fi

if [[ ! -d "$DEMO_ROOT" ]]; then
  "$REPO_ROOT/scripts/prepare_fabric_demo_release_env.py" --output-root "$DEMO_ROOT" >/dev/null
fi

env \
  SHARED_FABRIC_DASHBOARD_VAULT_ROOT="$VAULT_ROOT" \
  SHARED_FABRIC_DASHBOARD_SNAPSHOT_SCRIPT="$SNAPSHOT_SCRIPT" \
  "$APP_BIN" \
  --workspace "$WORKSPACE_PATH" \
  --global-root "$GLOBAL_ROOT" \
  --gemini-settings "$SETTINGS_PATH"
