# Path Migration Checklist

## Goal

Replace machine-specific absolute paths in the current shared framework with a
generated path configuration so the same framework can be restored on another
computer.

## Source of Truth

Use the rendered `install/paths.yaml` as the primary config contract.

Fallback order for scripts:

1. explicit CLI flag
2. rendered `paths.yaml`
3. environment variable
4. script-relative default when safe

## Refactor Targets

### 1. YAML Files That Should Become Templates

- `global-agent-fabric/sync/runtime-map.yaml`
- `global-agent-fabric/sync/hook-policy.yaml`
- `global-agent-fabric/projects/registry.yaml`

Action:

- Move committed versions to `*.template.yaml`
- Render machine-specific files during install
- Stop committing one machine's rendered paths as canonical source

### 2. Python Scripts That Should Read the Rendered Config

- `scripts/sync/preflight_check.py`
- `scripts/sync/sync_all.py`
- `scripts/sync/postflight_sync.py`
- `scripts/sync/export_codex_context.py`
- `scripts/sync/import_antigravity_state.py`
- `scripts/sync/bootstrap_global_agent_fabric.py`

Action:

- Introduce a shared helper module, for example `scripts/sync/path_config.py`
- Centralize reads for:
  - `global_root`
  - `workspace`
  - `gemini_rule`
  - `mcp_config`
  - `brain_root`
  - `history_root`
  - project registry paths

### 3. Dynamic Project Registry Generation

The current `projects/registry.yaml` should be generated from:

- machine-level `desktop_root`
- named project roots from `paths.yaml`
- optional install-time project selection

## Recommended Refactor Order

1. Add `path_config.py` to read `paths.yaml`
2. Refactor `preflight_check.py` and `sync_all.py`
3. Refactor `postflight_sync.py`
4. Refactor `export_codex_context.py`
5. Refactor `import_antigravity_state.py`
6. Add rendered template sources for runtime YAML files
7. Implement `render_framework_config.py` to generate machine-specific YAMLs
8. Update bootstrap/install scripts to generate the rendered files

## Definition of Done

The path migration is complete when:

1. No sync script requires `/Users/david_chen/...` to run
2. The framework can be installed under a different username and directory root
3. `preflight_check.py`, `sync_all.py`, and `postflight_sync.py` work with only:
   - a rendered `paths.yaml`
   - valid local secrets
   - restored or fresh state
