#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="${1:-$SCRIPT_DIR/.env.local}"
PATHS_OUTPUT="${2:-$SCRIPT_DIR/paths.yaml}"
STATE_ARCHIVE="${3:-}"
PYTHON_BIN="${PYTHON_BIN:-$(command -v python3 || true)}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Missing env file: $ENV_FILE" >&2
  echo "Copy $SCRIPT_DIR/env.template to $SCRIPT_DIR/.env.local and fill in the machine paths." >&2
  exit 1
fi

if [[ -z "$PYTHON_BIN" ]]; then
  echo "python3 not found in PATH" >&2
  exit 1
fi

set -a
. "$ENV_FILE"
set +a

if [[ -z "${AGF_GLOBAL_ROOT:-}" ]]; then
  echo "AGF_GLOBAL_ROOT is required in $ENV_FILE" >&2
  exit 1
fi

BOOTSTRAP_ROOT="${AGF_FRAMEWORK_SOURCE_ROOT:-$AGF_GLOBAL_ROOT}"
BOOTSTRAP_SCRIPT="$BOOTSTRAP_ROOT/scripts/sync/bootstrap_global_agent_fabric.py"

if [[ ! -f "$BOOTSTRAP_SCRIPT" ]]; then
  echo "Missing bootstrap script: $BOOTSTRAP_SCRIPT" >&2
  exit 1
fi

mkdir -p "$AGF_GLOBAL_ROOT"

"$PYTHON_BIN" "$SCRIPT_DIR/write_paths_config.py" \
  --env-file "$ENV_FILE" \
  --output "$PATHS_OUTPUT"

"$PYTHON_BIN" "$BOOTSTRAP_SCRIPT" \
  --global-root "$AGF_GLOBAL_ROOT" \
  --awesome-skills-root "$AGF_AWESOME_SKILLS_ROOT" \
  --gemini-rule "$AGF_GEMINI_RULE" \
  --mcp-config "$AGF_ANTIGRAVITY_MCP_CONFIG"

mkdir -p \
  "$AGF_GLOBAL_ROOT/docs" \
  "$AGF_GLOBAL_ROOT/memory" \
  "$AGF_GLOBAL_ROOT/mcp" \
  "$AGF_GLOBAL_ROOT/scripts/sync" \
  "$AGF_GLOBAL_ROOT/skills" \
  "$AGF_GLOBAL_ROOT/sync"

cp "$BOOTSTRAP_ROOT/sync/boot-sequence.md" "$AGF_GLOBAL_ROOT/sync/boot-sequence.md"
cp "$BOOTSTRAP_ROOT/memory/architecture.md" "$AGF_GLOBAL_ROOT/memory/architecture.md"
cp "$BOOTSTRAP_ROOT/memory/routes.yaml" "$AGF_GLOBAL_ROOT/memory/routes.yaml"
cp "$BOOTSTRAP_ROOT/memory/schema.yaml" "$AGF_GLOBAL_ROOT/memory/schema.yaml"
cp "$BOOTSTRAP_ROOT/memory/ki-registry.yaml" "$AGF_GLOBAL_ROOT/memory/ki-registry.yaml"
cp "$BOOTSTRAP_ROOT/memory/mempalace-taxonomy.yaml" "$AGF_GLOBAL_ROOT/memory/mempalace-taxonomy.yaml"
cp "$BOOTSTRAP_ROOT/mcp/secrets.example.yaml" "$AGF_GLOBAL_ROOT/mcp/secrets.example.yaml"
cp "$BOOTSTRAP_ROOT"/scripts/sync/*.py "$AGF_GLOBAL_ROOT/scripts/sync/"
if [[ -f "$BOOTSTRAP_ROOT/skills/registry.yaml" ]]; then
  cp "$BOOTSTRAP_ROOT/skills/registry.yaml" "$AGF_GLOBAL_ROOT/skills/registry.yaml"
fi

"$PYTHON_BIN" "$SCRIPT_DIR/render_framework_config.py" \
  --env-file "$ENV_FILE" \
  --output-root "$AGF_GLOBAL_ROOT"

if [[ -n "$STATE_ARCHIVE" ]]; then
  "$SCRIPT_DIR/restore_state.sh" "$ENV_FILE" "$STATE_ARCHIVE"
fi

PYTHON_BIN="$PYTHON_BIN" "$SCRIPT_DIR/doctor.sh" "$ENV_FILE"

echo "install: ok"
echo "paths: $PATHS_OUTPUT"
echo "global_root: $AGF_GLOBAL_ROOT"
