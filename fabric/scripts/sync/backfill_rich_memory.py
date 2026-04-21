#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
from pathlib import Path

from memory_expansion import (
    LANE_ORDER,
    append_ndjson_if_new,
    compose_history_bundle,
    compose_workflow_bundle,
    group_task_records,
    learning_receipt_record,
    load_signatures,
    parse_imported_workflow_snapshot,
    read_ndjson,
    utc_now_iso,
)
from path_config import resolve_global_root

LANE_FILE_BY_KEY = {
    "handoffs": "handoffs.ndjson",
    "decision_log": "decision-log.ndjson",
    "open_loops": "open-loops.ndjson",
    "mempalace_records": "mempalace-records.ndjson",
    "promoted_learnings": "promoted-learnings.ndjson",
}


def existing_bundle_present(records: list[dict[str, object]]) -> bool:
    return any(str(record.get("bundle_version") or "") == "2" for record in records)


def main() -> int:
    parser = argparse.ArgumentParser(description="Backfill rich memory bundles from existing imported workflows and sparse lane logs.")
    parser.add_argument("--global-root", type=Path, default=None)
    parser.add_argument("--workspace", type=str, default=None)
    args = parser.parse_args()

    global_root = resolve_global_root(args.global_root)
    memory_root = global_root / "memory"
    sync_root = global_root / "sync"
    workflows_root = global_root / "workflows" / "imported"

    lane_records = {lane: read_ndjson(memory_root / filename) for lane, filename in LANE_FILE_BY_KEY.items()}
    learning_receipts = read_ndjson(sync_root / "learning_receipts.ndjson")

    lane_signatures = {lane: load_signatures(memory_root / filename) for lane, filename in LANE_FILE_BY_KEY.items()}
    receipt_signatures = load_signatures(sync_root / "learning_receipts.ndjson")

    bundled_tasks: set[tuple[str, str]] = set()
    generated = 0
    receipt_count = 0

    workflow_paths = sorted(workflows_root.glob("antigravity-*.md"))
    for workflow_path in workflow_paths:
        sections = parse_imported_workflow_snapshot(workflow_path)
        task_id = workflow_path.stem.removeprefix("antigravity-")
        workspace = None
        for lane in LANE_ORDER:
            for record in lane_records[lane]:
                if str(record.get("task_id") or "") == task_id:
                    workspace = str(record.get("workspace") or "")
                    break
            if workspace:
                break
        if not workspace:
            continue
        if args.workspace and workspace != args.workspace:
            continue
        task_lane_records = {
            lane: [record for record in lane_records[lane] if str(record.get("task_id") or "") == task_id and str(record.get("workspace") or "") == workspace]
            for lane in LANE_ORDER
        }
        if any(existing_bundle_present(records) for records in task_lane_records.values()):
            bundled_tasks.add((workspace, task_id))
            continue
        timestamp_candidates = [
            str(record.get("timestamp") or "")
            for records in task_lane_records.values()
            for record in records
            if str(record.get("timestamp") or "")
        ]
        receipt_match = next(
            (
                record
                for record in learning_receipts
                if str(record.get("task_id") or "") == task_id and str(record.get("workspace") or "") == workspace
            ),
            None,
        )
        if receipt_match and str(receipt_match.get("timestamp") or ""):
            timestamp = str(receipt_match.get("timestamp") or "")
        else:
            timestamp = max(timestamp_candidates) if timestamp_candidates else utc_now_iso()
        bundle = compose_workflow_bundle(
            timestamp=timestamp,
            agent="antigravity",
            workspace=Path(workspace),
            task_id=task_id,
            workflow_snapshot=workflow_path,
            task_summary=sections.task_summary,
            plan_summary=sections.plan_summary,
            walkthrough_summary=sections.walkthrough_summary,
            task_section=sections.task,
            plan_section=sections.implementation_plan,
            walkthrough_section=sections.walkthrough,
            source_kind="historical_backfill",
            record_type_prefix="historical_backfill",
            extra={"backfilled": True},
        )
        for record in bundle:
            target = memory_root / LANE_FILE_BY_KEY[record["lane"]]
            if append_ndjson_if_new(target, record, lane_signatures[record["lane"]]):
                generated += 1
        receipt = learning_receipt_record(
            timestamp=bundle[0]["timestamp"],
            agent="antigravity",
            workspace=Path(workspace),
            task_id=task_id,
            summary=sections.walkthrough_summary or sections.task_summary,
            details="\n\n".join(
                part
                for part in [
                    sections.task and f"## Task\n{sections.task}",
                    sections.implementation_plan and f"## Implementation Plan\n{sections.implementation_plan}",
                    sections.walkthrough and f"## Walkthrough\n{sections.walkthrough}",
                ]
                if part
            ),
            artifacts=[str(workflow_path)],
            learned_items=[sections.plan_summary, sections.walkthrough_summary],
            skipped_items=[],
            generated_records=bundle,
            source_kind="historical_backfill",
            source_refs=[str(workflow_path)],
            status_marker="[MEMORY_BUNDLE]",
            sync_status="generated",
            extra={"type": "historical_backfill_receipt", "backfilled": True},
        )
        if append_ndjson_if_new(sync_root / "learning_receipts.ndjson", receipt, receipt_signatures):
            receipt_count += 1
        bundled_tasks.add((workspace, task_id))

    grouped_lane_records = {
        lane: group_task_records(records)
        for lane, records in lane_records.items()
    }
    grouped_receipts = group_task_records(learning_receipts)
    all_tasks = {
        key
        for grouped in grouped_lane_records.values()
        for key in grouped.keys()
    } | set(grouped_receipts.keys())

    for workspace, task_id in sorted(all_tasks):
        if args.workspace and workspace != args.workspace:
            continue
        if (workspace, task_id) in bundled_tasks:
            continue
        task_lane_records = {
            lane: grouped_lane_records[lane].get((workspace, task_id), [])
            for lane in LANE_ORDER
        }
        if any(existing_bundle_present(records) for records in task_lane_records.values()):
            continue
        receipt_match = None
        for receipt in grouped_receipts.get((workspace, task_id), []):
            if str(receipt.get("bundle_version") or "") == "2":
                receipt_match = receipt
                break
            if receipt_match is None:
                receipt_match = receipt
        source_summary = ""
        if receipt_match:
            source_summary = str(receipt_match.get("source_summary") or "")
        if not source_summary:
            for lane in ("handoffs", "decision_log", "open_loops"):
                summaries = [str(record.get("summary") or "") for record in task_lane_records[lane] if str(record.get("summary") or "")]
                if summaries:
                    source_summary = summaries[0]
                    break
        if not source_summary:
            source_summary = f"Backfilled rich memory for {task_id}"
        timestamps = [
            str(record.get("timestamp") or "")
            for records in task_lane_records.values()
            for record in records
            if str(record.get("timestamp") or "")
        ]
        if receipt_match and str(receipt_match.get("timestamp") or ""):
            timestamps.append(str(receipt_match.get("timestamp") or ""))
        timestamp = max(timestamps) if timestamps else "2026-01-01T00:00:00Z"
        agent = "codex"
        for lane in LANE_ORDER:
            if task_lane_records[lane]:
                agent = str(task_lane_records[lane][0].get("agent") or agent)
                break
        bundle = compose_history_bundle(
            timestamp=timestamp,
            agent=agent,
            workspace=Path(workspace),
            task_id=task_id,
            source_summary=source_summary,
            learning_receipt=receipt_match,
            lane_records=task_lane_records,
            source_kind="historical_backfill",
            extra={"backfilled": True},
        )
        for record in bundle:
            target = memory_root / LANE_FILE_BY_KEY[record["lane"]]
            if append_ndjson_if_new(target, record, lane_signatures[record["lane"]]):
                generated += 1
        receipt = learning_receipt_record(
            timestamp=timestamp,
            agent=agent,
            workspace=Path(workspace),
            task_id=task_id,
            summary=source_summary,
            details=str((receipt_match or {}).get("details") or ""),
            artifacts=[str(artifact) for artifact in (receipt_match or {}).get("artifacts") or [] if str(artifact).strip()],
            learned_items=[str(item) for item in (receipt_match or {}).get("learned_items") or [] if str(item).strip()],
            skipped_items=[str(item) for item in (receipt_match or {}).get("skipped_items") or [] if str(item).strip()],
            generated_records=bundle,
            source_kind="historical_backfill",
            source_refs=[str(artifact) for artifact in (receipt_match or {}).get("artifacts") or [] if str(artifact).strip()],
            status_marker="[MEMORY_BUNDLE]",
            sync_status="generated",
            extra={"type": "historical_backfill_receipt", "backfilled": True},
        )
        if append_ndjson_if_new(sync_root / "learning_receipts.ndjson", receipt, receipt_signatures):
            receipt_count += 1

    print(
        json.dumps(
            {
                "status": "written",
                "generated_memory_records": generated,
                "generated_receipts": receipt_count,
                "workspace_filter": args.workspace or "",
                "global_root": str(global_root),
            },
            ensure_ascii=False,
            indent=2,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
