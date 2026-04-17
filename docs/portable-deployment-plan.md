# Antigravity + Codex Portable Deployment Plan

## Goal

Build a portable, repeatable deployment flow that preserves the current shared
Antigravity + Codex framework, while separating reusable framework assets from
private state and machine-local configuration.

## Design Principles

1. Keep the framework in GitHub as the canonical code and protocol layer.
2. Keep mutable state exportable and restorable, but not mixed into framework code.
3. Keep secrets and machine-local paths out of Git.
4. Replace hard-coded absolute paths with install-time templates.
5. Preserve work continuity rather than mirroring every private runtime file.

## Packaging Model

### 1. Framework Layer

Store in a GitHub repository, ideally private by default.

Includes:

- `global-agent-fabric/README.md`
- `global-agent-fabric/docs/`
- `global-agent-fabric/rules/`
- `global-agent-fabric/mcp/servers.yaml`
- `global-agent-fabric/mcp/secrets.example.yaml`
- `global-agent-fabric/memory/schema.yaml`
- `global-agent-fabric/memory/routes.yaml`
- `global-agent-fabric/memory/architecture.md`
- `global-agent-fabric/memory/ki-registry.yaml`
- `global-agent-fabric/memory/mempalace-taxonomy.yaml`
- `global-agent-fabric/projects/registry.yaml.template`
- `global-agent-fabric/sync/boot-sequence.md`
- `global-agent-fabric/sync/hook-policy.yaml.template`
- `global-agent-fabric/sync/runtime-map.yaml.template`
- `global-agent-fabric/scripts/sync/`
- `install/`
- `manifests/`

### 2. State Layer

Store separately from the framework repo, either in a private state repo or an
encrypted archive.

Includes:

- `global-agent-fabric/memory/decision-log.ndjson`
- `global-agent-fabric/memory/open-loops.ndjson`
- `global-agent-fabric/memory/handoffs.ndjson`
- `global-agent-fabric/workflows/imported/`
- project overlays such as `PROJECT/.agents/`
- selected profiles or project facts that represent retained working memory

### 3. Machine Layer

Never commit to GitHub. Reconstruct or inject on each machine.

Includes:

- `~/.gemini/GEMINI.md`
- `~/.gemini/antigravity/mcp_config.json`
- `~/.codex/...` private runtime state
- `~/Library/Application Support/Antigravity/...`
- API keys, cookies, tokens, OAuth state
- virtual environments and caches

## Current Migration Findings

### A. Already Suitable for Framework Git Storage

- Shared protocol documents are structured and versionable.
- Sync scripts already define the runtime lifecycle.
- MCP server definitions already sanitize secrets at the registry layer.
- The current layout already separates docs, rules, sync scripts, and memory schemas.

### B. Must Be Parameterized Before Migration

Current files still embed machine-specific absolute paths such as
`/Users/david_chen/...`.

Most important path-bound files:

- `global-agent-fabric/sync/runtime-map.yaml`
- `global-agent-fabric/sync/hook-policy.yaml`
- `global-agent-fabric/projects/registry.yaml`
- `global-agent-fabric/scripts/sync/bootstrap_global_agent_fabric.py`
- `global-agent-fabric/scripts/sync/import_antigravity_state.py`
- `global-agent-fabric/scripts/sync/export_codex_context.py`
- `global-agent-fabric/scripts/sync/postflight_sync.py`
- `global-agent-fabric/scripts/sync/sync_all.py`

### C. Must Not Be Treated as Framework

- `global-agent-fabric/sync/receipts.ndjson`
- `global-agent-fabric/sync/import-state.json`
- `global-agent-fabric/workflows/imported/`
- mutable `memory/*.ndjson` logs
- `global-agent-fabric_venv/`

## Recommended Repository Layout

```text
antigravity-codex-fabric/
  fabric/
    docs/
    mcp/
    memory/
    projects/
    rules/
    scripts/
    sync/
    workflows/
  install/
    install_everything.sh
    restore_state.sh
    export_state.sh
    doctor.sh
    env.template
    paths.template.yaml
  manifests/
    framework-include.txt
    state-include.txt
    exclude.txt
  README.md
```

## Script Roadmap

### Phase 1: Parameterization

Add a generated config file such as `install/paths.yaml` that defines:

- `global_root`
- `workspace_root`
- `awesome_skills_root`
- `gemini_root`
- `codex_root`
- `antigravity_history_root`

All current sync scripts should resolve their defaults from this generated file
instead of embedding the current username and desktop layout.

### Phase 2: Export and Restore

Implement:

- `install/export_state.sh`
- `install/restore_state.sh`

Export should bundle only files listed in `manifests/state-include.txt`, minus
anything from `manifests/exclude.txt`.

Restore should:

1. unpack the state bundle
2. restore `memory/` and `workflows/imported/`
3. restore project `.agents/` overlays
4. regenerate machine-local path templates
5. run a health check

### Phase 3: One-Command Install

Implement `install/install_everything.sh` to:

1. clone or update the framework repo
2. install Python dependencies
3. create a venv if needed
4. materialize `paths.yaml` from the current machine
5. prompt for or load secrets
6. optionally restore a state bundle
7. run `doctor.sh`

## v1 Success Criteria

The first portable release should be considered successful if a fresh Mac can:

1. clone the framework repo
2. run one install command
3. restore a selected state bundle
4. pass a health check
5. successfully run `preflight_check.py`, `sync_all.py`, and `postflight_sync.py`

## Recommended Next Steps

1. Convert the current hard-coded path files into templates.
2. Create the three manifest files and use them as the source of truth.
3. Implement `export_state.sh`.
4. Implement `install_everything.sh`.
5. Implement `doctor.sh`.
6. Initialize a private GitHub repo for the framework layer.
