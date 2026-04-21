# Compact Dashboard 2.1

This dashboard now has two synchronized surfaces for the shared fabric runtime:

- a compact terminal monitor for fast inspection
- a macOS floating panel with Apple-style cards, motion, and sync audit visibility

## Data Sources

Both surfaces read the same shared state:

- `sync/receipts.ndjson`
- `sync/task_phases.ndjson`
- `sync/learning_receipts.ndjson`
- `memory/handoffs.ndjson`
- Gemini `settings.json`
- shared `mcp/servers.yaml`

## What Changed In 2.1

The dashboard is no longer only a status monitor.
It now also shows the latest sync delta:

- what was written during postflight
- whether durable learning was actually recorded
- which items were skipped
- whether the latest task is healthy, still in flight, or missing an explicit learning receipt

## Exact vs Heuristic Stages

The six-stage bar can run in two modes:

- `exact`: the current task has explicit phase events in `sync/task_phases.ndjson`
- `heuristic`: no phase events exist yet, so the dashboard falls back to receipts

Fallback rules are:

- `[BOOT_OK]` without `[SYNC_OK]` -> `执行`
- `[SYNC_OK]` -> `回奏`
- no receipts -> empty stage bar

To write an exact phase event:

```bash
python3 /path/to/global-agent-fabric/scripts/sync/log_task_phase.py \
  --workspace /path/to/workspace \
  --agent codex \
  --task-id some-task-id \
  --phase execute \
  --note "building dashboard"
```

## Learning Receipts

`postflight_sync.py` now writes a sync audit record into `sync/learning_receipts.ndjson`.

That record carries:

- per-target write counts
- learned items
- skipped items
- the source summary for the sync

This is the data source behind the `Sync Delta` card in the floating dashboard.

## Terminal Dashboard

Launch it with:

```bash
python3 /path/to/workspace/tools/compact_dashboard/run_dashboard.py \
  --workspace /path/to/workspace
```

If you omit `--workspace`, the dashboard auto-follows the latest active workspace found in the shared fabric.

Keys:

- `q` quit
- `r` refresh now

## Snapshot Export

To inspect the exact JSON payload shared by both surfaces:

```bash
python3 /path/to/workspace/tools/compact_dashboard/export_snapshot.py \
  --workspace /path/to/workspace
```

If `--workspace` is omitted here as well, snapshot export follows the latest active workspace automatically.

## macOS Floating Panel

You now have two launch paths:

1. Script launcher

```bash
/path/to/workspace/tools/compact_dashboard_desktop/launch_floating_dashboard.sh \
  --workspace /path/to/workspace
```

If you launch the floating dashboard with no `--workspace`, it behaves like a global control tower and follows the latest active workspace in the shared fabric.

2. Built app bundle

- `tools/compact_dashboard_desktop/Shared Fabric Dashboard.app`

Build it first:

```bash
/path/to/workspace/tools/compact_dashboard_desktop/build_dashboard_app.sh
```

After that, you can open the generated `.app` directly from Finder and it will launch the same floating panel for the workspace that contains the dashboard tool.

## Desktop App MVP

The desktop surface is now a small but real macOS app shell instead of a single read-only panel.

It includes:

- `Settings...` with persisted preferences via `UserDefaults`
- `Auto` vs `Pinned` workspace mode
- mixed workspace switching sourced from recent shared-fabric activity plus `projects/registry.yaml`
- `New Window` support so different windows can watch different workspaces
- `Refresh`, `Previous Workspace`, `Next Workspace`, `Open Current Workspace`, and `Open Shared Fabric Sync Folder` commands from the menu bar

The snapshot payload now also carries:

- `workspace_mode`
- `available_workspaces`

Each available workspace entry includes:

- `path`
- `label`
- `source` (`active`, `registered`, or `manual`)
- `last_seen`

## Visual Direction

The desktop panel is intentionally designed to feel closer to a small Apple utility window:

- frosted material background
- soft layered cards
- restrained color accents
- SF Symbols iconography
- lightweight motion on refresh and stage changes

The panel stays read-only.
It is meant to make sync and learning visible, not to become a control panel.

`MCP_Hub` was the first pilot workspace, but the dashboard is no longer pinned to it by default. You can let it auto-follow the latest active workspace or pass `--workspace` to pin any project explicitly.
