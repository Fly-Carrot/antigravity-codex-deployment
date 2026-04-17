#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="${1:-$SCRIPT_DIR/.env.local}"
OUTPUT_ARCHIVE="${2:-$PROJECT_ROOT/state-export.tar.gz}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Missing env file: $ENV_FILE" >&2
  exit 1
fi

set -a
. "$ENV_FILE"
set +a

MANIFEST_FILE="$PROJECT_ROOT/manifests/state-include.txt"
EXCLUDE_FILE="$PROJECT_ROOT/manifests/exclude.txt"

if [[ ! -f "$MANIFEST_FILE" ]]; then
  echo "Missing state manifest: $MANIFEST_FILE" >&2
  exit 1
fi

TMP_DIR="$(mktemp -d /tmp/agf-state-export.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

PAYLOAD_ROOT="$TMP_DIR/payload"
mkdir -p "$PAYLOAD_ROOT/global-agent-fabric" "$PAYLOAD_ROOT/overlays" "$TMP_DIR/metadata"

is_excluded() {
  local candidate="$1"
  while IFS= read -r exclude_path || [[ -n "$exclude_path" ]]; do
    [[ -z "$exclude_path" || "$exclude_path" == \#* ]] && continue
    if [[ "$candidate" == "$exclude_path" || "$candidate" == "$exclude_path"* ]]; then
      return 0
    fi
  done < "$EXCLUDE_FILE"
  return 1
}

project_overlay_key() {
  local candidate="$1"
  case "$candidate" in
    "$AGF_PROJECT_MCP_HUB"/*) echo "mcp_hub" ;;
    "$AGF_PROJECT_3_5"/*) echo "project3_5" ;;
    "$AGF_PROJECT_4"/*) echo "project4" ;;
    "$AGF_PROJECT_5"/*) echo "project5" ;;
    "$AGF_PROJECT_5_5"/*) echo "project5_5" ;;
    "$AGF_PROJECT_DESIGN"/*) echo "project_design" ;;
    *) return 1 ;;
  esac
}

bundle_relative_path() {
  local source_path="$1"
  if [[ "$source_path" == "$AGF_GLOBAL_ROOT/"* ]]; then
    echo "global-agent-fabric/${source_path#$AGF_GLOBAL_ROOT/}"
    return 0
  fi

  local key=""
  if key="$(project_overlay_key "$source_path")"; then
    local project_root_var=""
    case "$key" in
      mcp_hub) project_root_var="$AGF_PROJECT_MCP_HUB" ;;
      project3_5) project_root_var="$AGF_PROJECT_3_5" ;;
      project4) project_root_var="$AGF_PROJECT_4" ;;
      project5) project_root_var="$AGF_PROJECT_5" ;;
      project5_5) project_root_var="$AGF_PROJECT_5_5" ;;
      project_design) project_root_var="$AGF_PROJECT_DESIGN" ;;
    esac
    echo "overlays/$key/${source_path#$project_root_var/}"
    return 0
  fi

  return 1
}

copy_entry() {
  local source_path="$1"
  local rel_path=""
  if ! rel_path="$(bundle_relative_path "$source_path")"; then
    echo "Skipping unmapped state entry: $source_path" >&2
    return 0
  fi

  local target_path="$PAYLOAD_ROOT/$rel_path"
  mkdir -p "$(dirname "$target_path")"

  if [[ -d "$source_path" ]]; then
    mkdir -p "$target_path"
    rsync -a "$source_path"/ "$target_path"/
  else
    cp "$source_path" "$target_path"
  fi
}

while IFS= read -r source_path || [[ -n "$source_path" ]]; do
  [[ -z "$source_path" || "$source_path" == \#* ]] && continue
  if is_excluded "$source_path"; then
    echo "Excluded from export: $source_path"
    continue
  fi
  if [[ ! -e "$source_path" ]]; then
    echo "Missing export source, skipping: $source_path"
    continue
  fi
  copy_entry "$source_path"
done < "$MANIFEST_FILE"

cat > "$TMP_DIR/metadata/export-info.txt" <<EOF
created_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
source_global_root=$AGF_GLOBAL_ROOT
source_project_mcp_hub=$AGF_PROJECT_MCP_HUB
source_project_3_5=$AGF_PROJECT_3_5
source_project_4=$AGF_PROJECT_4
source_project_5=$AGF_PROJECT_5
source_project_5_5=$AGF_PROJECT_5_5
source_project_design=$AGF_PROJECT_DESIGN
EOF

mkdir -p "$(dirname "$OUTPUT_ARCHIVE")"
tar -czf "$OUTPUT_ARCHIVE" -C "$TMP_DIR" payload metadata

echo "export: ok"
echo "archive: $OUTPUT_ARCHIVE"
