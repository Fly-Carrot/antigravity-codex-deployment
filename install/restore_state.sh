#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="${1:-$SCRIPT_DIR/.env.local}"
STATE_ARCHIVE="${2:-}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Missing env file: $ENV_FILE" >&2
  exit 1
fi

if [[ -z "$STATE_ARCHIVE" || ! -f "$STATE_ARCHIVE" ]]; then
  echo "Missing state archive: $STATE_ARCHIVE" >&2
  exit 1
fi

set -a
. "$ENV_FILE"
set +a

TMP_DIR="$(mktemp -d /tmp/agf-state-restore.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

tar -xzf "$STATE_ARCHIVE" -C "$TMP_DIR"

PAYLOAD_ROOT="$TMP_DIR/payload"
if [[ ! -d "$PAYLOAD_ROOT" ]]; then
  echo "Invalid state archive: missing payload directory" >&2
  exit 1
fi

restore_tree() {
  local source_dir="$1"
  local target_dir="$2"
  if [[ -d "$source_dir" ]]; then
    mkdir -p "$target_dir"
    rsync -a "$source_dir"/ "$target_dir"/
  fi
}

restore_tree "$PAYLOAD_ROOT/global-agent-fabric/memory" "$AGF_GLOBAL_ROOT/memory"
restore_tree "$PAYLOAD_ROOT/global-agent-fabric/workflows/imported" "$AGF_GLOBAL_ROOT/workflows/imported"

restore_tree "$PAYLOAD_ROOT/overlays/mcp_hub/.agents" "$AGF_PROJECT_MCP_HUB/.agents"
restore_tree "$PAYLOAD_ROOT/overlays/project3_5/.agents" "$AGF_PROJECT_3_5/.agents"
restore_tree "$PAYLOAD_ROOT/overlays/project4/.agents" "$AGF_PROJECT_4/.agents"
restore_tree "$PAYLOAD_ROOT/overlays/project5/.agents" "$AGF_PROJECT_5/.agents"
restore_tree "$PAYLOAD_ROOT/overlays/project5_5/.agents" "$AGF_PROJECT_5_5/.agents"
restore_tree "$PAYLOAD_ROOT/overlays/project_design/.agents" "$AGF_PROJECT_DESIGN/.agents"

echo "restore: ok"
echo "archive: $STATE_ARCHIVE"
