# Shared Fabric Dashboard

<p align="center">
  <img src="docs/assets/shared-fabric-logo.svg" alt="Shared Fabric Dashboard logo" width="132" />
</p>

<h3 align="center">Personal AI Memory Console for Codex and Gemini</h3>

<p align="center">
  Shared Fabric Dashboard gives CLI agents a durable memory system, exact task visibility, and a clean desktop observer.
  <br/>
  It works well with <strong>one runtime</strong>, and gets even better when Codex and Gemini share the same fabric.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/release-v3.1.1-2A76F5?style=flat-square" alt="Release v3.1.1" />
  <img src="https://img.shields.io/badge/platform-macOS-111827?style=flat-square" alt="macOS" />
  <img src="https://img.shields.io/badge/runtime-Codex-0F172A?style=flat-square" alt="Codex" />
  <img src="https://img.shields.io/badge/runtime-Gemini%20CLI-334155?style=flat-square" alt="Gemini CLI" />
  <img src="https://img.shields.io/badge/memory-Decision%20%7C%20Handoff%20%7C%20Mem%20%7C%20Loop%20%7C%20Learn%20%7C%20Receipt-0F766E?style=flat-square" alt="Memory lanes" />
  <img src="https://img.shields.io/badge/export-Obsidian%20Chat%20History-7C3AED?style=flat-square" alt="Obsidian chat history export" />
</p>

<p align="center">
  <a href="https://github.com/Fly-Carrot/shared-fabric-codex-gemini/releases/tag/v3.1.1">Download v3.1.1</a>
  ·
  <a href="docs/releases/v3.1.1.md">Release Notes</a>
  ·
  <a href="tools/compact_dashboard_desktop/">Desktop App Source</a>
</p>

![Shared Fabric Dashboard desktop app](docs/assets/dashboard-app-window.png)

## Why This Exists

Most agent setups still lose context between sessions, hide what actually synced, and make memory quality hard to inspect.

Shared Fabric Dashboard solves that with one canonical shared fabric root:

- use `Codex` alone and get durable project memory, question-profile distillation, and phase visibility
- use `Gemini CLI` alone and get the same boot, sync, memory, and dashboard surfaces
- use both together and let them read and write into the same structured memory system

This repository is the portable deployment snapshot for that workflow. Your live memory does **not** live here. It lives in the `global-agent-fabric` root you choose during setup.

## What You Actually Get

- **Shared memory lanes**: `Decision`, `Handoff`, `Mem`, `Loop`, `Learn`, and `Receipt`
- **Question Profile**: a distilled global user profile plus workspace overlay
- **Six-stage task tracking**: `route -> plan -> review -> dispatch -> execute -> report`
- **Desktop observer**: session health, phase, sync delta, project memory, recent activity, and setup assistant
- **Obsidian export**: manual export of readable Codex and Gemini chat history into your vault

## Feature Tour

### 1. Session Health

![Session card](docs/assets/dashboard-session-card.png)

See the active runtime, task id, workspace path, boot status, sync status, and audit health in one place.

### 2. Exact Phase Tracking

![Phase card](docs/assets/dashboard-phase-card.png)

Track real six-stage progress from canonical phase logs instead of guessing from chat output.

### 3. Latest Sync Audit

![Sync Delta card](docs/assets/dashboard-sync-delta-card.png)

Inspect what the latest postflight actually wrote, lane by lane, without opening raw ndjson files.

### 4. User Question Profile

![Question Profile card](docs/assets/dashboard-question-profile-card.png)

Carry forward how the user tends to ask, what they care about, and how they prefer answers to be framed.

### 5. Cumulative Project Memory

![Project Memory card](docs/assets/dashboard-project-memory-card.png)

Browse the growing project memory timeline rather than just the newest sync receipt.

### 6. Setup Assistant

![Setup Assistant](docs/assets/dashboard-setup-assistant.png)

Stand up a clean shared fabric root and enable a workspace without leaving the app.

## Setup

### 1. Create the shared storage root

From the desktop app, open the setup assistant.

Or use the CLI:

```bash
python3 install/bootstrap_shared_fabric.py
```

For non-interactive setup:

```bash
python3 install/bootstrap_shared_fabric.py \
  --non-interactive \
  --global-root /path/to/global-agent-fabric \
  --desktop-root /path/to/Desktop
```

This creates the shared directory skeleton, renders local config, installs the portable snapshot, and runs the doctor chain.

### 2. Enable a workspace

```bash
python3 install/bootstrap_vscode_workspace.py \
  --workspace /path/to/workspace \
  --global-root /path/to/global-agent-fabric \
  --runtimes both
```

This generates:

- project-root `AGENTS.md`
- `.vscode/tasks.json`
- Gemini compatibility settings for `AGENTS.md` and `GEMINI.md`
- `.agents/sync/user-question-profile.md`

The generated VSCode task surface includes:

- `Shared Fabric: Boot Current Workspace`
- `Shared Fabric: Sync Current Workspace`
- `Shared Fabric: Postflight Sync`
- `Shared Fabric: Open Global Root`
- `Shared Fabric: Rebuild Workspace Entry`

## Recommended Startup Snippet

Use a workspace-adjusted version of this in your runtime instructions:

```text
Use /path/to/global-agent-fabric as the canonical shared fabric.
Before substantial work, run the shared boot sequence for this workspace and report [BOOT_OK].
Load global shared context first, then runtime-specific context, then the current project overlay.
For complex tasks, emit exact six-stage phase events via log_task_phase.py so the dashboard can track progress.
Write back through postflight_sync.py and report [SYNC_OK].
Treat this workspace as project-scoped, not global.

Do not write directly to memory/*.ndjson or sync/*.ndjson; use canonical sync scripts only.
Prefer canonical rich-memory bundle generation over ad-hoc summary-only records.
Route stable reusable learnings to promoted learning, and route detailed process memory / trial-and-error to MemPalace.

Maintain a distilled user-question profile through canonical postflight sync.
For each substantial task, distill the user's recurring focus points, question patterns, response preferences, reasoning preferences, recurring themes, and frictions/anxieties into a structured user-question-profile payload.
Do not persist raw user prompts by default.
Treat the user-question profile as global-first, and let the current workspace contribute only a project-specific overlay.

Use available MCP tools and local skills when they materially improve accuracy, but keep shared-fabric synchronization on canonical scripts rather than ad-hoc file writes.
If the active postflight_sync.py does not support user-question-profile distillation, do not claim full sync; say explicitly that user-question-profile write-back is still missing.
A task is not fully synced unless postflight includes a user-question-profile distillation payload for substantial work.
```

## Shared Memory Model

| Board | Purpose |
| --- | --- |
| `Decision` | Chosen approaches, architecture calls, and user-approved directions |
| `Handoff` | Current state, completed work, and exact next actions |
| `Mem` | Trial-and-error, reasoning paths, and nuanced rationale |
| `Loop` | Blockers, unresolved risks, and remaining work |
| `Learn` | Stable reusable lessons and promoted learnings |
| `Receipt` | Sync audit records, counts, provenance, and cross-links |

`Question Profile` is additive. It is not a seventh lane. It is a compiled distilled layer generated from substantial-task postflight snapshots.

## Repository Layout

```text
shared-fabric-repo/
  docs/
    assets/
    releases/
  fabric/
    scripts/
      sync/
  install/
  tests/
  tools/
    compact_dashboard/
    compact_dashboard_desktop/
```

## Notes

- The app bundle is still named `Shared Fabric Dashboard`.
- The canonical shared state lives in your chosen `global-agent-fabric` root, not in this repository.
- VSCode integration is intentionally workspace-first rather than extension-first.
- Historical bridge metadata is still readable for compatibility, but it is treated as provenance rather than a primary control surface.
