# Boot Sequence

## Goal

This sequence defines the minimum synchronization steps every runtime must execute before and after meaningful work.

## Pre-Run

1. Determine current workspace.
2. Run `preflight_check.py`.
3. Run `sync_all.py` with `--agent` and `--task-id` so a `session_start` receipt is written to `sync/receipts.ndjson`.
4. Read the workspace overlay only after the global root has been validated and loaded.
5. After a successful start receipt, explicitly report `[BOOT_OK]` in chat.

## During Work

1. Follow the shared rule stack from `global-agent-fabric`.
2. Route stable technical-route memory to `cc-skill-continuous-learning`.
3. Route episodic / detailed process memory to `mempalace`.
4. At major task boundaries, prefer an explicit `postflight_sync.py` write-back rather than waiting until the very end.

## Post-Run

1. Prepare a compact structured summary of:
   - decisions
   - open loops
   - handoff state
2. Run `postflight_sync.py`.
3. Confirm that a `session_end` receipt was written to `sync/receipts.ndjson`.
4. After a successful end receipt, explicitly report `[SYNC_OK]` in chat.
5. If write-back fails, report that synchronization is incomplete.

## Non-Negotiable Rule

No runtime should start substantial work from stale local assumptions when the shared global root is available.
