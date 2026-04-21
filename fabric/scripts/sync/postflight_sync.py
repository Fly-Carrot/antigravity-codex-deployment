#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
from typing import Any

from memory_expansion import (
    append_record,
    compose_postflight_bundle,
    learning_receipt_record,
    normalize_items,
    utc_now_iso,
)
from path_config import resolve_global_root, resolve_workspace

def bridge_field(cli_value: str | None, env_name: str) -> str:
    value = (cli_value or os.environ.get(env_name) or "").strip()
    return value


def main() -> int:
    parser = argparse.ArgumentParser(description="Write structured postflight synchronization records into Global Agent Fabric.")
    parser.add_argument("--global-root", type=Path, default=None)
    parser.add_argument("--workspace", type=Path, default=None)
    parser.add_argument("--agent", required=True)
    parser.add_argument("--summary", required=True)
    parser.add_argument("--task-id", default="session")
    parser.add_argument("--decision")
    parser.add_argument("--open-loop")
    parser.add_argument("--handoff")
    parser.add_argument("--details")
    parser.add_argument("--artifacts", nargs="*", default=[])
    parser.add_argument("--learned-item", action="append", default=[])
    parser.add_argument("--skipped-item", action="append", default=[])
    parser.add_argument("--mempalace-record", action="append", default=[])
    parser.add_argument("--promoted-learning", action="append", default=[])
    parser.add_argument("--bridge-session-id")
    parser.add_argument("--bridge-mode")
    parser.add_argument("--origin-runtime")
    parser.add_argument("--target-runtime")
    parser.add_argument("--context-entrypoint")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    args.global_root = resolve_global_root(args.global_root)
    args.workspace = resolve_workspace(args.workspace)

    memory_root = args.global_root / "memory"
    sync_root = args.global_root / "sync"
    timestamp = utc_now_iso()
    artifacts = list(args.artifacts)
    details = args.details or ""
    learned_items = normalize_items(list(args.learned_item) + list(args.promoted_learning))
    skipped_items = normalize_items(list(args.skipped_item))
    mempalace_items = normalize_items(list(args.mempalace_record))
    promoted_items = normalize_items(list(args.promoted_learning))
    bridge_metadata = {
        "bridge_session_id": bridge_field(args.bridge_session_id, "AGF_MULTICLI_BRIDGE_SESSION_ID"),
        "bridge_mode": bridge_field(args.bridge_mode, "AGF_MULTICLI_BRIDGE_MODE"),
        "origin_runtime": bridge_field(args.origin_runtime, "AGF_MULTICLI_ORIGIN_RUNTIME"),
        "target_runtime": bridge_field(args.target_runtime, "AGF_MULTICLI_TARGET_RUNTIME"),
        "context_entrypoint": bridge_field(args.context_entrypoint, "AGF_MULTICLI_CONTEXT_ENTRYPOINT"),
    }
    bridge_metadata = {key: value for key, value in bridge_metadata.items() if value}

    bundle_records = compose_postflight_bundle(
        timestamp=timestamp,
        agent=args.agent,
        workspace=args.workspace,
        task_id=args.task_id,
        summary=args.summary,
        decision=args.decision or "",
        open_loop=args.open_loop or "",
        handoff=args.handoff or "",
        details=details,
        artifacts=artifacts,
        learned_items=learned_items,
        skipped_items=skipped_items,
        mempalace_items=mempalace_items,
        promoted_items=promoted_items,
        bridge_metadata=bridge_metadata,
    )
    records: list[tuple[Path, dict[str, Any]]] = [
        (memory_root / "decision-log.ndjson", bundle_records[0]),
        (memory_root / "handoffs.ndjson", bundle_records[1]),
        (memory_root / "open-loops.ndjson", bundle_records[2]),
        (memory_root / "mempalace-records.ndjson", bundle_records[3]),
        (memory_root / "promoted-learnings.ndjson", bundle_records[4]),
    ]
    learning_receipt = learning_receipt_record(
        timestamp=timestamp,
        agent=args.agent,
        workspace=args.workspace,
        task_id=args.task_id,
        summary=args.summary,
        details=details,
        artifacts=artifacts,
        learned_items=learned_items,
        skipped_items=skipped_items,
        generated_records=bundle_records,
        source_kind="postflight_expansion",
        source_refs=artifacts,
        extra=bridge_metadata,
    )
    sync_receipt_record = {
        "timestamp": timestamp,
        "agent": args.agent,
        "workspace": str(args.workspace),
        "task_id": args.task_id,
        "hook": "postflight_sync",
        "phase": "session_end",
        "status": "written",
        "status_marker": "[SYNC_OK]",
        "summary": args.summary,
        **bridge_metadata,
    }

    if args.dry_run:
        print(
            json.dumps(
                {
                    "status": "dry_run",
                    "status_marker": "[SYNC_DRY_RUN]",
                    "records": [{"target": str(path), "record": record} for path, record in records],
                    "learning_receipt": {
                        "target": str(sync_root / "learning_receipts.ndjson"),
                        "record": learning_receipt,
                    },
                    "receipt": {
                        "target": str(sync_root / "receipts.ndjson"),
                        "record": {**sync_receipt_record, "status": "dry_run", "status_marker": "[SYNC_DRY_RUN]"},
                    },
                },
                ensure_ascii=False,
                indent=2,
            )
        )
        return 0

    for path, record in records:
        append_record(path, record)
    append_record(sync_root / "learning_receipts.ndjson", learning_receipt)
    append_record(sync_root / "receipts.ndjson", sync_receipt_record)
    print(
        json.dumps(
            {
                "status": "written",
                "status_marker": "[SYNC_OK]",
                "records_written": len(records),
                "targets": [str(path) for path, _ in records],
                "learning_receipt_target": str(sync_root / "learning_receipts.ndjson"),
                "receipt_target": str(sync_root / "receipts.ndjson"),
                "writes": learning_receipt["writes"],
                "learned_items": learned_items,
                "skipped_items": skipped_items,
            },
            ensure_ascii=False,
            indent=2,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
