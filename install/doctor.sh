#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="${1:-$SCRIPT_DIR/.env.local}"
PYTHON_BIN="${PYTHON_BIN:-$(command -v python3 || true)}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Missing env file: $ENV_FILE" >&2
  exit 1
fi

if [[ -z "$PYTHON_BIN" ]]; then
  echo "python3 not found in PATH" >&2
  exit 1
fi

set -a
. "$ENV_FILE"
set +a

required_vars=(
  AGF_GLOBAL_ROOT
  AGF_AWESOME_SKILLS_ROOT
  AGF_GEMINI_RULE
  AGF_ANTIGRAVITY_MCP_CONFIG
  AGF_PROJECT_MCP_HUB
)

for var_name in "${required_vars[@]}"; do
  if [[ -z "${(P)var_name:-}" ]]; then
    echo "Missing required env var: $var_name" >&2
    exit 1
  fi
done

required_files=(
  "$AGF_GLOBAL_ROOT/README.md"
  "$AGF_GLOBAL_ROOT/sync/boot-sequence.md"
  "$AGF_GLOBAL_ROOT/sync/runtime-map.yaml"
  "$AGF_GLOBAL_ROOT/sync/hook-policy.yaml"
  "$AGF_GLOBAL_ROOT/projects/registry.yaml"
  "$AGF_GLOBAL_ROOT/scripts/sync/preflight_check.py"
  "$AGF_GLOBAL_ROOT/scripts/sync/sync_all.py"
  "$AGF_GLOBAL_ROOT/scripts/sync/postflight_sync.py"
)

for path in "${required_files[@]}"; do
  if [[ ! -e "$path" ]]; then
    echo "Missing required framework file: $path" >&2
    exit 1
  fi
done

"$PYTHON_BIN" "$AGF_GLOBAL_ROOT/scripts/sync/preflight_check.py" \
  --global-root "$AGF_GLOBAL_ROOT" \
  --workspace "$AGF_PROJECT_MCP_HUB" \
  --agent codex \
  --task-id doctor-check

"$PYTHON_BIN" "$AGF_GLOBAL_ROOT/scripts/sync/sync_all.py" \
  --global-root "$AGF_GLOBAL_ROOT" \
  --workspace "$AGF_PROJECT_MCP_HUB" \
  --agent codex \
  --task-id doctor-sync-check \
  --skip-import \
  --skip-export \
  --skip-receipt

echo "doctor: ok"
