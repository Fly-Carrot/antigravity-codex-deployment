# Compact Dashboard

This dashboard now has two surfaces for the shared fabric runtime:

- a compact terminal monitor
- a macOS floating panel fed by the same JSON snapshot

## Data Sources

Both surfaces read the same shared state:

- `sync/receipts.ndjson`
- `memory/handoffs.ndjson`
- `sync/task_phases.ndjson`
- Gemini `settings.json`
- shared `mcp/servers.yaml`

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

## Terminal Dashboard

Launch it with:

```bash
python3 /path/to/workspace/tools/compact_dashboard/run_dashboard.py \
  --workspace /path/to/workspace
```

Keys:

- `q` quit
- `r` refresh now

## Snapshot Export

To inspect the exact JSON payload shared by both surfaces:

```bash
python3 /path/to/workspace/tools/compact_dashboard/export_snapshot.py \
  --workspace /path/to/workspace
```

## macOS Floating Panel

You now have two launch paths:

1. Script launcher

```bash
/path/to/workspace/tools/compact_dashboard_desktop/launch_floating_dashboard.sh \
  --workspace /path/to/workspace
```

2. Built app bundle

- `tools/compact_dashboard_desktop/MCP Hub Dashboard.app`

Build it first:

```bash
/path/to/workspace/tools/compact_dashboard_desktop/build_dashboard_app.sh
```

After that, you can open the generated `.app` directly from Finder and it will launch the same floating panel for the workspace that contains the dashboard tool.

If you later change the Swift panel source and want to refresh the bundled app binary, run:

```bash
/path/to/workspace/tools/compact_dashboard_desktop/build_dashboard_app.sh
```

The panel is intentionally small and read-only:

- title + runtime
- BOOT / SYNC / lifecycle
- six-stage horizontal bar
- current task
- MCP counts
- latest handoff
- up to 3 recent tasks
- `Refresh` and `Open Logs`

`MCP_Hub` is the first pilot workspace, but all commands retain `--workspace`, so the same setup can later point at `Project4` without changing the architecture.
