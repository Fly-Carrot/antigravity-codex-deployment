#!/usr/bin/env python3

from __future__ import annotations

import hashlib
import json
import re
from collections import OrderedDict
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

LANE_SPECS: dict[str, dict[str, str]] = {
    "handoffs": {
        "title": "Handoff",
        "filename": "handoffs.ndjson",
        "type": "rich_handoff_bundle",
    },
    "decision_log": {
        "title": "Decision",
        "filename": "decision-log.ndjson",
        "type": "rich_decision_bundle",
    },
    "open_loops": {
        "title": "Open Loop",
        "filename": "open-loops.ndjson",
        "type": "rich_open_loop_bundle",
    },
    "mempalace_records": {
        "title": "MemPalace",
        "filename": "mempalace-records.ndjson",
        "type": "rich_mempalace_bundle",
        "route": "episodic_detail",
        "mechanism": "mempalace",
    },
    "promoted_learnings": {
        "title": "Promoted Learning",
        "filename": "promoted-learnings.ndjson",
        "type": "rich_promoted_learning_bundle",
        "route": "stable_technical_route",
        "mechanism": "cc-skill-continuous-learning",
    },
}

LANE_ORDER = [
    "decision_log",
    "handoffs",
    "open_loops",
    "mempalace_records",
    "promoted_learnings",
]


@dataclass
class WorkflowSections:
    task: str
    implementation_plan: str
    walkthrough: str
    task_summary: str
    plan_summary: str
    walkthrough_summary: str


def utc_now_iso() -> str:
    return datetime.now(UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def ensure_parent(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)


def append_record(path: Path, record: dict[str, Any]) -> None:
    ensure_parent(path)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(record, ensure_ascii=False, sort_keys=True) + "\n")


def read_ndjson(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    records: list[dict[str, Any]] = []
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line:
            continue
        try:
            records.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return records


def append_ndjson_if_new(path: Path, record: dict[str, Any], known_signatures: set[str]) -> bool:
    canonical = json.dumps(record, ensure_ascii=False, sort_keys=True)
    signature = hashlib.sha256(canonical.encode("utf-8")).hexdigest()
    if signature in known_signatures:
        return False
    append_record(path, record)
    known_signatures.add(signature)
    return True


def load_signatures(path: Path) -> set[str]:
    signatures: set[str] = set()
    if not path.exists():
        return signatures
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line:
            continue
        signatures.add(hashlib.sha256(line.encode("utf-8")).hexdigest())
    return signatures


def normalize_items(values: list[str]) -> list[str]:
    ordered = OrderedDict[str, None]()
    for value in values:
        item = value.strip()
        if item:
            ordered[item] = None
    return list(ordered.keys())


def shorten(text: str, width: int = 180) -> str:
    clean = " ".join(text.split())
    if len(clean) <= width:
        return clean
    return clean[: width - 3].rstrip() + "..."


def summarize_text(text: str, fallback: str, width: int = 180) -> str:
    for raw_line in text.splitlines():
        line = raw_line.strip().lstrip("#").strip()
        if line:
            return shorten(line, width)
    return shorten(fallback, width)


def unresolved_markdown_items(text: str) -> list[str]:
    return [match.group(1).strip() for match in re.finditer(r"^- \[ \]\s+(.*)$", text, flags=re.MULTILINE)]


def _section_block(title: str, content: str) -> str:
    body = content.strip()
    if not body:
        return ""
    return f"## {title}\n{body}"


def _bullet_block(title: str, items: list[str]) -> str:
    normalized = normalize_items(items)
    if not normalized:
        return ""
    bullets = "\n".join(f"- {item}" for item in normalized)
    return f"## {title}\n{bullets}"


def _join_blocks(*blocks: str) -> str:
    return "\n\n".join(block for block in blocks if block.strip()).strip()


def _lane_record(
    *,
    lane: str,
    timestamp: str,
    agent: str,
    workspace: Path,
    task_id: str,
    summary: str,
    details: str,
    artifacts: list[str],
    source_kind: str,
    source_refs: list[str] | None = None,
    record_type: str | None = None,
    extra: dict[str, Any] | None = None,
) -> dict[str, Any]:
    spec = LANE_SPECS[lane]
    record: dict[str, Any] = {
        "timestamp": timestamp,
        "agent": agent,
        "workspace": str(workspace),
        "task_id": task_id,
        "lane": lane,
        "title": spec["title"],
        "summary": shorten(summary, 220),
        "details": details.strip(),
        "artifacts": normalize_items(artifacts),
        "type": record_type or spec["type"],
        "bundle_version": 2,
        "source_kind": source_kind,
        "source_refs": normalize_items(source_refs or []),
    }
    if "route" in spec:
        record["route"] = spec["route"]
    if "mechanism" in spec:
        record["mechanism"] = spec["mechanism"]
    if extra:
        record.update(extra)
    return record


def learning_receipt_record(
    *,
    timestamp: str,
    agent: str,
    workspace: Path,
    task_id: str,
    summary: str,
    details: str,
    artifacts: list[str],
    learned_items: list[str],
    skipped_items: list[str],
    generated_records: list[dict[str, Any]],
    source_kind: str,
    source_refs: list[str] | None = None,
    status_marker: str = "[SYNC_OK]",
    sync_status: str = "written",
    extra: dict[str, Any] | None = None,
) -> dict[str, Any]:
    writes = {
        "receipts": 1,
        "handoffs": 1,
        "decision_log": 1,
        "open_loops": 1,
        "mempalace_records": 1,
        "promoted_learnings": 1,
    }
    record: dict[str, Any] = {
        "timestamp": timestamp,
        "agent": agent,
        "workspace": str(workspace),
        "task_id": task_id,
        "sync_status": sync_status,
        "status_marker": status_marker,
        "writes": writes,
        "learned_items": normalize_items(learned_items),
        "skipped_items": normalize_items(skipped_items),
        "source_summary": shorten(summary, 220),
        "details": details.strip(),
        "artifacts": normalize_items(artifacts),
        "generated_records": [
            {
                "lane": item["lane"],
                "title": item["title"],
                "summary": item["summary"],
                "type": item["type"],
            }
            for item in generated_records
        ],
        "bundle_version": 2,
        "source_kind": source_kind,
        "source_refs": normalize_items(source_refs or []),
    }
    if extra:
        record.update(extra)
    return record


def parse_imported_workflow_snapshot(path: Path) -> WorkflowSections:
    text = path.read_text(encoding="utf-8")
    sections: dict[str, list[str]] = {}
    current: str | None = None
    for raw_line in text.splitlines():
        line = raw_line.rstrip()
        if line.startswith("## "):
            current = line[3:].strip().lower().replace(" ", "_")
            sections.setdefault(current, [])
            continue
        if current is not None:
            sections[current].append(line)
    task_text = "\n".join(sections.get("task", [])).strip()
    plan_text = "\n".join(sections.get("implementation_plan", [])).strip()
    walkthrough_text = "\n".join(sections.get("walkthrough", [])).strip()
    return WorkflowSections(
        task=task_text,
        implementation_plan=plan_text,
        walkthrough=walkthrough_text,
        task_summary=summarize_text(task_text, path.stem),
        plan_summary=summarize_text(plan_text, "Imported implementation plan"),
        walkthrough_summary=summarize_text(walkthrough_text, "Imported walkthrough"),
    )


def compose_postflight_bundle(
    *,
    timestamp: str,
    agent: str,
    workspace: Path,
    task_id: str,
    summary: str,
    decision: str,
    open_loop: str,
    handoff: str,
    details: str,
    artifacts: list[str],
    learned_items: list[str],
    skipped_items: list[str],
    mempalace_items: list[str],
    promoted_items: list[str],
    bridge_metadata: dict[str, Any] | None = None,
) -> list[dict[str, Any]]:
    bridge_metadata = bridge_metadata or {}
    source_refs = artifacts
    decision_summary = decision or summary
    handoff_summary = handoff or summary
    open_loop_summary = open_loop or (skipped_items[0] if skipped_items else f"Continue from {shorten(summary, 90)}")
    mem_summary = mempalace_items[0] if mempalace_items else (details or summary)
    learn_summary = promoted_items[0] if promoted_items else (learned_items[0] if learned_items else summary)

    decision_details = _join_blocks(
        _section_block("Task Summary", summary),
        _section_block("Chosen Direction", decision or summary),
        _section_block("Supporting Details", details),
        _bullet_block("Durable Learnings", learned_items),
    )
    handoff_details = _join_blocks(
        _section_block("Current State", handoff or summary),
        _section_block("Decision Context", decision or summary),
        _section_block("Follow-up", open_loop or "No explicit open loop recorded."),
        _section_block("Supporting Details", details),
    )
    open_loop_details = _join_blocks(
        _section_block("Primary Open Loop", open_loop or "No explicit blocker was recorded; continue from the latest task summary."),
        _bullet_block("Skipped Items", skipped_items),
        _section_block("Current Task Summary", summary),
        _section_block("Supporting Details", details),
    )
    mem_details = _join_blocks(
        _bullet_block("Reasoning Trace", mempalace_items),
        _section_block("Context", details or summary),
        _section_block("Decision Context", decision or summary),
        _section_block("Remaining Uncertainty", open_loop or "No explicit unresolved branch recorded."),
    )
    learn_details = _join_blocks(
        _bullet_block("Reusable Learnings", promoted_items or learned_items),
        _section_block("Task Summary", summary),
        _section_block("Supporting Context", details),
    )

    return [
        _lane_record(
            lane="decision_log",
            timestamp=timestamp,
            agent=agent,
            workspace=workspace,
            task_id=task_id,
            summary=decision_summary,
            details=decision_details,
            artifacts=artifacts,
            source_kind="postflight_expansion",
            source_refs=source_refs,
            extra=bridge_metadata,
        ),
        _lane_record(
            lane="handoffs",
            timestamp=timestamp,
            agent=agent,
            workspace=workspace,
            task_id=task_id,
            summary=handoff_summary,
            details=handoff_details,
            artifacts=artifacts,
            source_kind="postflight_expansion",
            source_refs=source_refs,
            extra=bridge_metadata,
        ),
        _lane_record(
            lane="open_loops",
            timestamp=timestamp,
            agent=agent,
            workspace=workspace,
            task_id=task_id,
            summary=open_loop_summary,
            details=open_loop_details,
            artifacts=artifacts,
            source_kind="postflight_expansion",
            source_refs=source_refs,
            extra=bridge_metadata,
        ),
        _lane_record(
            lane="mempalace_records",
            timestamp=timestamp,
            agent=agent,
            workspace=workspace,
            task_id=task_id,
            summary=mem_summary,
            details=mem_details,
            artifacts=artifacts,
            source_kind="postflight_expansion",
            source_refs=source_refs,
            extra=bridge_metadata,
        ),
        _lane_record(
            lane="promoted_learnings",
            timestamp=timestamp,
            agent=agent,
            workspace=workspace,
            task_id=task_id,
            summary=learn_summary,
            details=learn_details,
            artifacts=artifacts,
            source_kind="postflight_expansion",
            source_refs=source_refs,
            extra=bridge_metadata,
        ),
    ]


def compose_workflow_bundle(
    *,
    timestamp: str,
    agent: str,
    workspace: Path,
    task_id: str,
    workflow_snapshot: Path,
    task_summary: str,
    plan_summary: str,
    walkthrough_summary: str,
    task_section: str,
    plan_section: str,
    walkthrough_section: str,
    source_kind: str,
    record_type_prefix: str = "workflow",
    extra: dict[str, Any] | None = None,
) -> list[dict[str, Any]]:
    extra = extra or {}
    unresolved = unresolved_markdown_items(task_section)
    artifacts = [str(workflow_snapshot)]
    source_refs = [str(workflow_snapshot)]

    return [
        _lane_record(
            lane="decision_log",
            timestamp=timestamp,
            agent=agent,
            workspace=workspace,
            task_id=task_id,
            summary=plan_summary or task_summary,
            details=_join_blocks(
                _section_block("Implementation Plan", plan_section),
                _section_block("Task Context", task_section),
                _section_block("Execution Walkthrough", walkthrough_section),
            ),
            artifacts=artifacts,
            source_kind=source_kind,
            source_refs=source_refs,
            record_type=f"{record_type_prefix}_decision_bundle",
            extra=extra,
        ),
        _lane_record(
            lane="handoffs",
            timestamp=timestamp,
            agent=agent,
            workspace=workspace,
            task_id=task_id,
            summary=walkthrough_summary or task_summary,
            details=_join_blocks(
                _section_block("Task Tracker", task_section),
                _bullet_block("Outstanding Items", unresolved),
                _section_block("Implementation Plan", plan_section),
                _section_block("Walkthrough", walkthrough_section),
            ),
            artifacts=artifacts,
            source_kind=source_kind,
            source_refs=source_refs,
            record_type=f"{record_type_prefix}_handoff_bundle",
            extra=extra,
        ),
        _lane_record(
            lane="open_loops",
            timestamp=timestamp,
            agent=agent,
            workspace=workspace,
            task_id=task_id,
            summary=unresolved[0] if unresolved else f"Continue imported task {task_id}",
            details=_join_blocks(
                _bullet_block("Outstanding Checklist Items", unresolved),
                _section_block("Task Tracker", task_section),
                _section_block("Implementation Plan", plan_section),
            ),
            artifacts=artifacts,
            source_kind=source_kind,
            source_refs=source_refs,
            record_type=f"{record_type_prefix}_open_loop_bundle",
            extra=extra,
        ),
        _lane_record(
            lane="mempalace_records",
            timestamp=timestamp,
            agent=agent,
            workspace=workspace,
            task_id=task_id,
            summary=walkthrough_summary or plan_summary,
            details=_join_blocks(
                _section_block("Reasoning and Plan", plan_section),
                _section_block("Execution Narrative", walkthrough_section),
                _section_block("Task Tracker", task_section),
            ),
            artifacts=artifacts,
            source_kind=source_kind,
            source_refs=source_refs,
            record_type=f"{record_type_prefix}_mempalace_bundle",
            extra=extra,
        ),
        _lane_record(
            lane="promoted_learnings",
            timestamp=timestamp,
            agent=agent,
            workspace=workspace,
            task_id=task_id,
            summary=plan_summary or walkthrough_summary,
            details=_join_blocks(
                _section_block("Reusable Patterns from the Plan", plan_section),
                _section_block("Reusable Signals from the Walkthrough", walkthrough_section),
            ),
            artifacts=artifacts,
            source_kind=source_kind,
            source_refs=source_refs,
            record_type=f"{record_type_prefix}_learning_bundle",
            extra=extra,
        ),
    ]


def group_task_records(records: list[dict[str, Any]]) -> dict[tuple[str, str], list[dict[str, Any]]]:
    grouped: dict[tuple[str, str], list[dict[str, Any]]] = {}
    for record in records:
        workspace = str(record.get("workspace") or "")
        task_id = str(record.get("task_id") or "")
        if not workspace or not task_id:
            continue
        grouped.setdefault((workspace, task_id), []).append(record)
    return grouped


def compose_history_bundle(
    *,
    timestamp: str,
    agent: str,
    workspace: Path,
    task_id: str,
    source_summary: str,
    learning_receipt: dict[str, Any] | None,
    lane_records: dict[str, list[dict[str, Any]]],
    source_kind: str,
    extra: dict[str, Any] | None = None,
) -> list[dict[str, Any]]:
    extra = extra or {}

    def lane_summaries(lane: str) -> list[str]:
        return [str(item.get("summary") or "").strip() for item in lane_records.get(lane, []) if str(item.get("summary") or "").strip()]

    def lane_details(lane: str) -> list[str]:
        return [str(item.get("details") or "").strip() for item in lane_records.get(lane, []) if str(item.get("details") or "").strip()]

    artifacts = normalize_items(
        [
            artifact
            for records in lane_records.values()
            for record in records
            for artifact in record.get("artifacts") or []
            if str(artifact).strip()
        ]
        + [str(artifact) for artifact in (learning_receipt or {}).get("artifacts") or [] if str(artifact).strip()]
    )
    source_refs = artifacts
    learned_items = [str(item) for item in (learning_receipt or {}).get("learned_items") or [] if str(item).strip()]
    skipped_items = [str(item) for item in (learning_receipt or {}).get("skipped_items") or [] if str(item).strip()]

    decision_summary = lane_summaries("decision_log")[0] if lane_summaries("decision_log") else source_summary
    handoff_summary = lane_summaries("handoffs")[0] if lane_summaries("handoffs") else source_summary
    open_loop_summary = lane_summaries("open_loops")[0] if lane_summaries("open_loops") else f"Review continuation state for {task_id}"
    mem_summary = lane_summaries("mempalace_records")[0] if lane_summaries("mempalace_records") else source_summary
    learn_summary = lane_summaries("promoted_learnings")[0] if lane_summaries("promoted_learnings") else (learned_items[0] if learned_items else source_summary)

    return [
        _lane_record(
            lane="decision_log",
            timestamp=timestamp,
            agent=agent,
            workspace=workspace,
            task_id=task_id,
            summary=decision_summary,
            details=_join_blocks(
                _section_block("Existing Decision Summaries", "\n".join(f"- {item}" for item in lane_summaries("decision_log"))),
                _section_block("Existing Decision Details", "\n\n".join(lane_details("decision_log"))),
                _section_block("Source Summary", source_summary),
            ),
            artifacts=artifacts,
            source_kind=source_kind,
            source_refs=source_refs,
            record_type="historical_decision_bundle",
            extra=extra,
        ),
        _lane_record(
            lane="handoffs",
            timestamp=timestamp,
            agent=agent,
            workspace=workspace,
            task_id=task_id,
            summary=handoff_summary,
            details=_join_blocks(
                _section_block("Existing Handoff Summaries", "\n".join(f"- {item}" for item in lane_summaries("handoffs"))),
                _section_block("Existing Handoff Details", "\n\n".join(lane_details("handoffs"))),
                _section_block("Source Summary", source_summary),
            ),
            artifacts=artifacts,
            source_kind=source_kind,
            source_refs=source_refs,
            record_type="historical_handoff_bundle",
            extra=extra,
        ),
        _lane_record(
            lane="open_loops",
            timestamp=timestamp,
            agent=agent,
            workspace=workspace,
            task_id=task_id,
            summary=open_loop_summary,
            details=_join_blocks(
                _section_block("Existing Open Loop Summaries", "\n".join(f"- {item}" for item in lane_summaries("open_loops"))),
                _bullet_block("Skipped Items", skipped_items),
                _section_block("Existing Open Loop Details", "\n\n".join(lane_details("open_loops"))),
                _section_block("Source Summary", source_summary),
            ),
            artifacts=artifacts,
            source_kind=source_kind,
            source_refs=source_refs,
            record_type="historical_open_loop_bundle",
            extra=extra,
        ),
        _lane_record(
            lane="mempalace_records",
            timestamp=timestamp,
            agent=agent,
            workspace=workspace,
            task_id=task_id,
            summary=mem_summary,
            details=_join_blocks(
                _section_block("Existing MemPalace Summaries", "\n".join(f"- {item}" for item in lane_summaries("mempalace_records"))),
                _section_block("Existing Decision and Handoff Context", "\n".join(f"- {item}" for item in lane_summaries("decision_log") + lane_summaries("handoffs"))),
                _section_block("Detailed Context", "\n\n".join(lane_details("decision_log") + lane_details("handoffs") + lane_details("open_loops"))),
            ),
            artifacts=artifacts,
            source_kind=source_kind,
            source_refs=source_refs,
            record_type="historical_mempalace_bundle",
            extra=extra,
        ),
        _lane_record(
            lane="promoted_learnings",
            timestamp=timestamp,
            agent=agent,
            workspace=workspace,
            task_id=task_id,
            summary=learn_summary,
            details=_join_blocks(
                _bullet_block("Learned Items", learned_items),
                _section_block("Existing Promoted Learning Summaries", "\n".join(f"- {item}" for item in lane_summaries("promoted_learnings"))),
                _section_block("Source Summary", source_summary),
                _section_block("Source Details", str((learning_receipt or {}).get("details") or "")),
            ),
            artifacts=artifacts,
            source_kind=source_kind,
            source_refs=source_refs,
            record_type="historical_learning_bundle",
            extra=extra,
        ),
    ]

