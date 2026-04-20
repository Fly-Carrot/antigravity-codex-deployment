#!/usr/bin/env python3

from __future__ import annotations

import json
import os
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

DEFAULT_GLOBAL_ROOT = Path("/Users/david_chen/Antigravity_Skills/global-agent-fabric")
DEFAULT_GEMINI_SETTINGS = Path("/Users/david_chen/.gemini/settings.json")
PHASE_ORDER = ["route", "plan", "review", "dispatch", "execute", "report"]
PHASE_LABELS = {
    "route": "路由",
    "plan": "规划",
    "review": "自审",
    "dispatch": "分发",
    "execute": "执行",
    "report": "回奏",
}


@dataclass
class DashboardState:
    workspace: str
    project_name: str
    runtime: str
    task_id: str
    boot_status: str
    sync_status: str
    lifecycle_phase: str
    six_stage_current: str
    six_stage_completed: list[str]
    six_stage_note: str
    phase_source: str
    last_handoff: str
    active_mcp_count: int
    enabled_registry_count: int
    disabled_registry_count: int
    recent_tasks: list[dict[str, str]]
    alerts: list[str]

    def to_snapshot(self) -> dict[str, Any]:
        return asdict(self)


def resolve_global_root(global_root: str | Path | None = None) -> Path:
    if global_root:
        return Path(global_root).expanduser()
    env_value = os.environ.get("AGF_GLOBAL_ROOT")
    if env_value:
        return Path(env_value).expanduser()
    return DEFAULT_GLOBAL_ROOT


def resolve_gemini_settings(path: str | Path | None = None) -> Path:
    if path:
        return Path(path).expanduser()
    env_value = os.environ.get("AGF_GEMINI_SETTINGS")
    if env_value:
        return Path(env_value).expanduser()
    return DEFAULT_GEMINI_SETTINGS


def _normalize_path(value: str | Path | None) -> str:
    if value in {None, ""}:
        return ""
    try:
        return str(Path(value).expanduser().resolve())
    except OSError:
        return str(Path(value).expanduser())


def _parse_timestamp(value: str | None) -> datetime:
    if not value:
        return datetime.min.replace(tzinfo=timezone.utc)
    normalized = value.replace("Z", "+00:00")
    return datetime.fromisoformat(normalized)


def _read_ndjson(path: Path) -> list[dict[str, Any]]:
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


def _parse_scalar(value: str) -> Any:
    text = value.strip()
    if not text:
        return ""
    if text in {"[]", "{}"}:
        return [] if text == "[]" else {}
    if text == "true":
        return True
    if text == "false":
        return False
    if text == "null":
        return None
    if len(text) >= 2 and text[0] == text[-1] and text[0] in {'"', "'"}:
        return text[1:-1]
    return text


def _read_mcp_registry(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    lines = path.read_text(encoding="utf-8").splitlines()
    servers: list[dict[str, Any]] = []
    in_servers = False
    idx = 0
    while idx < len(lines):
        line = lines[idx]
        if line.strip() == "servers:":
            in_servers = True
            idx += 1
            continue
        if not in_servers:
            idx += 1
            continue
        if line.startswith("  -"):
            server: dict[str, Any] = {}
            idx += 1
            while idx < len(lines):
                raw = lines[idx]
                if raw.startswith("  -") or (raw and not raw.startswith("    ")):
                    break
                stripped = raw.strip()
                if not stripped:
                    idx += 1
                    continue
                if stripped.endswith(":") and stripped[:-1] in {"args", "env_refs"}:
                    key = stripped[:-1]
                    idx += 1
                    values: list[Any] = []
                    while idx < len(lines) and lines[idx].startswith("      - "):
                        values.append(_parse_scalar(lines[idx].strip()[2:].strip()))
                        idx += 1
                    server[key] = values
                    continue
                if ":" in stripped:
                    key, raw_value = stripped.split(":", 1)
                    server[key] = _parse_scalar(raw_value)
                idx += 1
            servers.append(server)
            continue
        idx += 1
    return servers


def _shorten(text: str, width: int = 80) -> str:
    clean = " ".join(text.split())
    if len(clean) <= width:
        return clean
    if width <= 1:
        return clean[:width]
    return clean[: width - 1] + "..."


def _build_recent_tasks(workspace_receipts: list[dict[str, Any]], handoffs: list[dict[str, Any]]) -> list[dict[str, str]]:
    grouped: dict[str, list[dict[str, Any]]] = {}
    for record in workspace_receipts:
        task_id = str(record.get("task_id") or "unknown-task")
        grouped.setdefault(task_id, []).append(record)

    handoff_by_task: dict[str, dict[str, Any]] = {}
    for handoff in handoffs:
        task_id = str(handoff.get("task_id") or "")
        if not task_id:
            continue
        previous = handoff_by_task.get(task_id)
        if previous is None or _parse_timestamp(handoff.get("timestamp")) > _parse_timestamp(previous.get("timestamp")):
            handoff_by_task[task_id] = handoff

    recent: list[dict[str, str]] = []
    for task_id, records in grouped.items():
        ordered = sorted(records, key=lambda item: _parse_timestamp(item.get("timestamp")))
        latest = ordered[-1]
        boot_ok = any(item.get("status_marker") == "[BOOT_OK]" for item in ordered)
        sync_ok = any(item.get("status_marker") == "[SYNC_OK]" for item in ordered)
        handoff = handoff_by_task.get(task_id, {})
        summary = latest.get("summary") or handoff.get("summary") or latest.get("hook") or ""
        recent.append(
            {
                "task_id": task_id,
                "agent": str(latest.get("agent") or "?"),
                "time": _parse_timestamp(latest.get("timestamp")).astimezone().strftime("%m-%d %H:%M"),
                "boot": "OK" if boot_ok else "--",
                "sync": "OK" if sync_ok else "..",
                "summary": _shorten(str(summary), 52),
                "sort_key": latest.get("timestamp") or "",
            }
        )
    recent.sort(key=lambda item: _parse_timestamp(item["sort_key"]), reverse=True)
    return recent[:5]


def _select_current_task(workspace_receipts: list[dict[str, Any]]) -> tuple[str, list[dict[str, Any]]]:
    if not workspace_receipts:
        return "-", []
    by_task: dict[str, list[dict[str, Any]]] = {}
    for record in workspace_receipts:
        by_task.setdefault(str(record.get("task_id") or "unknown-task"), []).append(record)

    return max(by_task.items(), key=lambda item: max(_parse_timestamp(record.get("timestamp")) for record in item[1]))


def _resolve_phase_state(
    current_records: list[dict[str, Any]],
    phase_events: list[dict[str, Any]],
    alerts: list[str],
) -> tuple[str, list[str], str, str]:
    if phase_events:
        latest = sorted(
            enumerate(phase_events),
            key=lambda item: (_parse_timestamp(item[1].get("timestamp")), item[0]),
        )[-1][1]
        current = str(latest.get("phase_key") or "")
        current_index = PHASE_ORDER.index(current) if current in PHASE_ORDER else -1
        completed = PHASE_ORDER[:current_index] if current_index >= 0 else []
        note = str(latest.get("note") or latest.get("phase_label") or "")
        return current, completed, note, "exact"

    if current_records:
        sync_ok = any(item.get("status_marker") == "[SYNC_OK]" for item in current_records)
        boot_ok = any(item.get("status_marker") == "[BOOT_OK]" for item in current_records)
        if sync_ok:
            alerts.append("phase source = heuristic")
            return "report", PHASE_ORDER[:-1], "Derived from [SYNC_OK] receipt.", "heuristic"
        if boot_ok:
            alerts.append("phase source = heuristic")
            return "execute", PHASE_ORDER[:4], "Derived from [BOOT_OK] receipt.", "heuristic"

    return "", [], "", "none"


def build_state(
    workspace: str | Path,
    global_root: str | Path | None = None,
    gemini_settings: str | Path | None = None,
) -> DashboardState:
    workspace_path = _normalize_path(workspace)
    global_root_path = resolve_global_root(global_root)
    gemini_settings_path = resolve_gemini_settings(gemini_settings)

    receipts_path = global_root_path / "sync" / "receipts.ndjson"
    handoffs_path = global_root_path / "memory" / "handoffs.ndjson"
    phase_log_path = global_root_path / "sync" / "task_phases.ndjson"
    registry_path = global_root_path / "mcp" / "servers.yaml"

    receipts = _read_ndjson(receipts_path)
    handoffs = _read_ndjson(handoffs_path)
    phase_events = _read_ndjson(phase_log_path)

    workspace_receipts = [item for item in receipts if _normalize_path(item.get("workspace")) == workspace_path]
    workspace_handoffs = [item for item in handoffs if _normalize_path(item.get("workspace")) == workspace_path]

    alerts: list[str] = []
    if not workspace_receipts:
        alerts.append("No receipts found for this workspace yet.")

    task_id, current_records = _select_current_task(workspace_receipts)
    current_records = sorted(current_records, key=lambda item: _parse_timestamp(item.get("timestamp")))
    latest_record = current_records[-1] if current_records else {}

    runtime = str(latest_record.get("agent") or "-")
    boot_status = "OK" if any(item.get("status_marker") == "[BOOT_OK]" for item in current_records) else "--"
    sync_status = "OK" if any(item.get("status_marker") == "[SYNC_OK]" for item in current_records) else "--"

    if boot_status == "OK" and sync_status != "OK":
        lifecycle_phase = "ACTIVE"
    elif sync_status == "OK":
        lifecycle_phase = "SYNCED"
    elif current_records:
        lifecycle_phase = "SEEN"
    else:
        lifecycle_phase = "IDLE"

    task_phase_events = [
        item
        for item in phase_events
        if _normalize_path(item.get("workspace")) == workspace_path and str(item.get("task_id") or "") == task_id
    ]
    six_stage_current, six_stage_completed, six_stage_note, phase_source = _resolve_phase_state(
        current_records=current_records,
        phase_events=task_phase_events,
        alerts=alerts,
    )

    latest_handoff = {}
    if workspace_handoffs:
        latest_handoff = max(workspace_handoffs, key=lambda item: _parse_timestamp(item.get("timestamp")))
    last_handoff = str(latest_handoff.get("summary") or "No workspace handoff yet.")

    settings_payload = {}
    if gemini_settings_path.exists():
        settings_payload = json.loads(gemini_settings_path.read_text(encoding="utf-8"))
    active_mcp_count = len((settings_payload.get("mcpServers") or {}).keys())

    registry_servers = _read_mcp_registry(registry_path)
    enabled_registry_count = sum(1 for item in registry_servers if item.get("enabled") is True)
    disabled_registry_count = sum(1 for item in registry_servers if item.get("enabled") is False)

    return DashboardState(
        workspace=workspace_path,
        project_name=Path(workspace_path).name,
        runtime=runtime,
        task_id=task_id,
        boot_status=boot_status,
        sync_status=sync_status,
        lifecycle_phase=lifecycle_phase,
        six_stage_current=six_stage_current,
        six_stage_completed=six_stage_completed,
        six_stage_note=_shorten(six_stage_note, 96),
        phase_source=phase_source,
        last_handoff=_shorten(last_handoff, 96),
        active_mcp_count=active_mcp_count,
        enabled_registry_count=enabled_registry_count,
        disabled_registry_count=disabled_registry_count,
        recent_tasks=_build_recent_tasks(workspace_receipts, workspace_handoffs),
        alerts=alerts,
    )
