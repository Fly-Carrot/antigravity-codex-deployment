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
AUTO_WORKSPACE_SENTINELS = {"", "auto", "latest"}
PHASE_ORDER = ["route", "plan", "review", "dispatch", "execute", "report"]
PHASE_LABELS = {
    "route": "Route",
    "plan": "Plan",
    "review": "Review",
    "dispatch": "Dispatch",
    "execute": "Execute",
    "report": "Report",
}
WRITE_TARGET_ORDER = [
    "receipts",
    "handoffs",
    "decision_log",
    "open_loops",
    "mempalace_records",
    "promoted_learnings",
]
PROJECT_MEMORY_LANES = [
    "receipts",
    "handoffs",
    "decision_log",
    "open_loops",
    "mempalace_records",
    "promoted_learnings",
]
PROJECT_MEMORY_LABELS = {
    "receipts": "Receipt",
    "handoffs": "Handoff",
    "decision_log": "Decision",
    "open_loops": "Loop",
    "mempalace_records": "Mem",
    "promoted_learnings": "Learn",
}
USER_QUESTION_PROFILE_LOG = "memory/user-question-profiles.ndjson"
GLOBAL_USER_QUESTION_PROFILE = "memory/user-question-profile.md"
WORKSPACE_USER_QUESTION_PROFILE = ".agents/sync/user-question-profile.md"


@dataclass
class SyncRecordEntry:
    target: str
    title: str
    timestamp: str
    summary: str
    details: str
    artifacts: list[str]
    source_path: str
    route: str
    mechanism: str


@dataclass
class ProjectMemoryRecord:
    lane: str
    title: str
    timestamp: str
    summary: str
    details: str
    artifacts: list[str]
    workspace: str
    task_id: str
    agent: str
    type: str
    source_path: str
    route: str
    mechanism: str
    bridge_session_id: str
    bridge_mode: str
    origin_runtime: str
    target_runtime: str
    is_bridged: bool


@dataclass
class SyncDelta:
    writes_count_by_target: dict[str, int]
    learned_items: list[str]
    skipped_items: list[str]
    source_summary: str
    records: list[SyncRecordEntry]


@dataclass
class TaskHealth:
    is_booted: bool
    has_exact_phase: bool
    has_postflight_sync: bool
    has_learning_receipt: bool


@dataclass
class WorkspaceOption:
    path: str
    label: str
    source: str
    last_seen: str


@dataclass
class QuestionProfileDocument:
    title: str
    summary: str
    preview: str
    content: str
    path: str
    updated_at: str
    is_available: bool
    is_placeholder: bool


@dataclass
class UserQuestionProfileState:
    snapshot_count: int
    workspace_snapshot_count: int
    global_profile: QuestionProfileDocument
    workspace_profile: QuestionProfileDocument


@dataclass
class DashboardState:
    workspace: str
    workspace_mode: str
    snapshot_mode: str
    project_name: str
    runtime: str
    bridge_session_id: str
    bridge_mode: str
    origin_runtime: str
    target_runtime: str
    is_bridged: bool
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
    available_workspaces: list[WorkspaceOption]
    alerts: list[str]
    last_sync_delta: SyncDelta
    user_question_profile: UserQuestionProfileState
    includes_project_memory_details: bool
    includes_question_profile_content: bool
    project_memory_counts: dict[str, int]
    project_memory_records: list[ProjectMemoryRecord]
    project_memory_last_updated: str
    sync_audit_source: str
    current_task_health: TaskHealth
    attention_state: str

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


def _workspace_exists(path: str | Path | None) -> bool:
    normalized = _normalize_path(path)
    if not normalized:
        return False
    try:
        return Path(normalized).exists()
    except OSError:
        return False


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


def _is_auto_workspace(value: str | Path | None) -> bool:
    if value is None:
        return True
    return str(value).strip().lower() in AUTO_WORKSPACE_SENTINELS


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


def _read_project_registry(path: Path) -> list[dict[str, str]]:
    if not path.exists():
        return []
    lines = path.read_text(encoding="utf-8").splitlines()
    projects: list[dict[str, str]] = []
    in_projects = False
    idx = 0
    while idx < len(lines):
        line = lines[idx]
        if line.strip() == "projects:":
            in_projects = True
            idx += 1
            continue
        if not in_projects:
            idx += 1
            continue
        if line.startswith("  -"):
            project: dict[str, str] = {}
            idx += 1
            while idx < len(lines):
                raw = lines[idx]
                if raw.startswith("  -") or (raw and not raw.startswith("    ")):
                    break
                stripped = raw.strip()
                if not stripped or stripped.endswith(":"):
                    idx += 1
                    continue
                if ":" in stripped:
                    key, raw_value = stripped.split(":", 1)
                    if key in {"id", "name", "path"}:
                        project[key] = str(_parse_scalar(raw_value))
                idx += 1
            if project.get("path"):
                projects.append(project)
            continue
        idx += 1
    return projects


def _shorten(text: str, width: int = 80) -> str:
    clean = " ".join(text.split())
    if len(clean) <= width:
        return clean
    if width <= 1:
        return clean[:width]
    return clean[: width - 1] + "..."


def _read_text(path: Path) -> str:
    if not path.exists():
        return ""
    return path.read_text(encoding="utf-8")


def _runtime_display_name(value: Any) -> str:
    text = str(value or "").strip()
    if not text:
        return ""

    normalized = "".join(char for char in text.lower() if char.isalnum())
    aliases = {
        "codex": "Codex",
        "codexcli": "Codex",
        "gemini": "Gemini CLI",
        "geminicli": "Gemini CLI",
        "antigravity": "Gemini CLI",
        "techlead": "Gemini CLI",
    }
    if normalized in aliases:
        return aliases[normalized]
    return text


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
                "agent": _runtime_display_name(latest.get("agent") or "?"),
                "time": _parse_timestamp(latest.get("timestamp")).astimezone().strftime("%m-%d %H:%M"),
                "boot": "OK" if boot_ok else "--",
                "sync": "OK" if sync_ok else "..",
                "summary": _shorten(str(summary), 52),
                "sort_key": latest.get("timestamp") or "",
            }
        )
    recent.sort(key=lambda item: _parse_timestamp(item["sort_key"]), reverse=True)
    return recent[:5]


def _workspace_label(path: str, registry_by_path: dict[str, dict[str, str]]) -> str:
    entry = registry_by_path.get(path)
    if entry and entry.get("name"):
        return entry["name"]
    return Path(path).name if path else "(no workspace)"


def _meaningful_profile_lines(content: str) -> list[str]:
    lines: list[str] = []
    for raw_line in content.splitlines():
        line = raw_line.strip()
        if not line:
            continue
        if line.startswith("<!--") or line.startswith("# "):
            continue
        lines.append(line)
    return lines


def _profile_updated_at(path: Path, content: str) -> str:
    for raw_line in content.splitlines():
        line = raw_line.strip()
        if line.startswith("Last updated:"):
            return line.removeprefix("Last updated:").strip().strip("`")
    if not path.exists():
        return ""
    return datetime.fromtimestamp(path.stat().st_mtime, tz=timezone.utc).astimezone().strftime("%Y-%m-%d %H:%M")


def _question_profile_document(
    path: Path | None,
    *,
    title: str,
    missing_summary: str,
    include_content: bool,
) -> QuestionProfileDocument:
    if path is None:
        return QuestionProfileDocument(
            title=title,
            summary=missing_summary,
            preview="",
            content="",
            path="",
            updated_at="",
            is_available=False,
            is_placeholder=True,
        )

    content = _read_text(path)
    lines = _meaningful_profile_lines(content)
    summary = lines[0] if lines else missing_summary
    preview_lines = lines[1:6] if len(lines) > 1 else []
    preview = _shorten(" ".join(preview_lines), 280) if preview_lines else ""
    lowered = " ".join(lines[:3]).lower()
    is_placeholder = "no distilled user question profile" in lowered or "no compiled user questioning profile" in lowered
    return QuestionProfileDocument(
        title=title,
        summary=summary,
        preview=preview,
        content=content.strip() if include_content else "",
        path=str(path),
        updated_at=_profile_updated_at(path, content),
        is_available=path.exists(),
        is_placeholder=is_placeholder,
    )


def _resolve_user_question_profile(
    *,
    global_root: Path,
    workspace_path: str,
    include_content: bool,
) -> UserQuestionProfileState:
    records = _read_ndjson(global_root / USER_QUESTION_PROFILE_LOG)
    workspace_records = [
        record for record in records if _normalize_path(record.get("workspace")) == workspace_path
    ]
    workspace_profile_path = Path(workspace_path) / WORKSPACE_USER_QUESTION_PROFILE if workspace_path else None
    return UserQuestionProfileState(
        snapshot_count=len(records),
        workspace_snapshot_count=len(workspace_records),
        global_profile=_question_profile_document(
            global_root / GLOBAL_USER_QUESTION_PROFILE,
            title="Global Profile",
            missing_summary="No compiled global question profile yet.",
            include_content=include_content,
        ),
        workspace_profile=_question_profile_document(
            workspace_profile_path,
            title="Workspace Overlay",
            missing_summary="No workspace question overlay is available yet.",
            include_content=include_content,
        ),
    )


def _build_workspace_activity_map(records: list[dict[str, Any]]) -> dict[str, str]:
    activity: dict[str, str] = {}
    for record in records:
        workspace_path = _normalize_path(record.get("workspace"))
        timestamp = str(record.get("timestamp") or "")
        if not workspace_path or not timestamp:
            continue
        if workspace_path not in activity or _parse_timestamp(timestamp) > _parse_timestamp(activity[workspace_path]):
            activity[workspace_path] = timestamp
    return activity


def _build_available_workspaces(
    current_workspace: str,
    workspace_mode: str,
    receipts: list[dict[str, Any]],
    handoffs: list[dict[str, Any]],
    learning_receipts: list[dict[str, Any]],
    registry_projects: list[dict[str, str]],
) -> list[WorkspaceOption]:
    registry_by_path_all = {
        _normalize_path(project.get("path")): project for project in registry_projects if _normalize_path(project.get("path"))
    }
    registry_by_path = {
        path: project for path, project in registry_by_path_all.items() if _workspace_exists(path)
    }
    activity_by_path = {
        path: timestamp
        for path, timestamp in _build_workspace_activity_map(receipts + handoffs + learning_receipts).items()
        if _workspace_exists(path)
    }
    active_paths = sorted(activity_by_path.keys(), key=lambda path: _parse_timestamp(activity_by_path[path]), reverse=True)
    registered_paths = sorted(
        [path for path in registry_by_path.keys() if path not in active_paths],
        key=lambda path: (_workspace_label(path, registry_by_path).lower(), path.lower()),
    )

    options: list[WorkspaceOption] = []
    seen: set[str] = set()

    for path in active_paths:
        options.append(
            WorkspaceOption(
                path=path,
                label=_workspace_label(path, registry_by_path),
                source="active",
                last_seen=activity_by_path.get(path, ""),
            )
        )
        seen.add(path)

    for path in registered_paths:
        options.append(
            WorkspaceOption(
                path=path,
                label=_workspace_label(path, registry_by_path),
                source="registered",
                last_seen=activity_by_path.get(path, ""),
            )
        )
        seen.add(path)

    if workspace_mode == "pinned" and current_workspace and current_workspace not in seen:
        options.insert(
            0,
            WorkspaceOption(
                path=current_workspace,
                label=_workspace_label(current_workspace, registry_by_path_all),
                source="manual",
                last_seen=activity_by_path.get(current_workspace, ""),
            ),
        )

    return options


def _resolve_workspace_path(
    workspace: str | Path | None,
    receipts: list[dict[str, Any]],
    handoffs: list[dict[str, Any]],
    learning_receipts: list[dict[str, Any]],
) -> str:
    if not _is_auto_workspace(workspace):
        return _normalize_path(workspace)

    latest_record: dict[str, Any] | None = None
    for record in receipts + handoffs + learning_receipts:
        workspace_value = _normalize_path(record.get("workspace"))
        if not workspace_value or not _workspace_exists(workspace_value):
            continue
        if latest_record is None or _parse_timestamp(record.get("timestamp")) > _parse_timestamp(latest_record.get("timestamp")):
            latest_record = record

    if latest_record is None:
        return ""
    return _normalize_path(latest_record.get("workspace"))


def _select_current_task(workspace_receipts: list[dict[str, Any]]) -> tuple[str, list[dict[str, Any]]]:
    if not workspace_receipts:
        return "-", []
    by_task: dict[str, list[dict[str, Any]]] = {}
    for record in workspace_receipts:
        by_task.setdefault(str(record.get("task_id") or "unknown-task"), []).append(record)

    return max(by_task.items(), key=lambda item: max(_parse_timestamp(record.get("timestamp")) for record in item[1]))


def _resolve_phase_state(current_records: list[dict[str, Any]], phase_events: list[dict[str, Any]], alerts: list[str]) -> tuple[str, list[str], str, str]:
    sync_ok = any(item.get("status_marker") == "[SYNC_OK]" for item in current_records)
    boot_ok = any(item.get("status_marker") == "[BOOT_OK]" for item in current_records)

    if phase_events:
        latest = sorted(
            enumerate(phase_events),
            key=lambda item: (_parse_timestamp(item[1].get("timestamp")), item[0]),
        )[-1][1]
        current = str(latest.get("phase_key") or "")
        if sync_ok and current == "report":
            note = str(latest.get("note") or latest.get("phase_label") or "")
            if not note:
                note = "Task fully synced; waiting for next route."
            else:
                note = f"{note} Waiting for next route."
            return "", PHASE_ORDER[:], note, "exact"
        current_index = PHASE_ORDER.index(current) if current in PHASE_ORDER else -1
        completed = PHASE_ORDER[:current_index] if current_index >= 0 else []
        note = str(latest.get("note") or latest.get("phase_label") or "")
        return current, completed, note, "exact"

    if current_records:
        if sync_ok:
            alerts.append("phase source = heuristic")
            return "", PHASE_ORDER[:], "Derived from [SYNC_OK] receipt; waiting for next task.", "heuristic"
        if boot_ok:
            alerts.append("phase source = heuristic")
            return "execute", PHASE_ORDER[:4], "Derived from [BOOT_OK] receipt.", "heuristic"

    return "", [], "", "none"


def _latest_record(records: list[dict[str, Any]]) -> dict[str, Any]:
    if not records:
        return {}
    return max(records, key=lambda item: _parse_timestamp(item.get("timestamp")))


def _empty_writes() -> dict[str, int]:
    return {key: 0 for key in WRITE_TARGET_ORDER}


def _resolve_bridge_metadata(records: list[dict[str, Any]]) -> dict[str, Any]:
    ordered = sorted(records, key=lambda item: _parse_timestamp(item.get("timestamp")), reverse=True)
    fields = {
        "bridge_session_id": "",
        "bridge_mode": "",
        "origin_runtime": "",
        "target_runtime": "",
    }
    for record in ordered:
        for key in list(fields.keys()):
            if fields[key]:
                continue
            value = str(record.get(key) or "").strip()
            if value:
                fields[key] = value
    fields["origin_runtime"] = _runtime_display_name(fields["origin_runtime"])
    fields["target_runtime"] = _runtime_display_name(fields["target_runtime"])
    fields["is_bridged"] = any(bool(value) for value in fields.values())
    return fields


def _matching_task_records(
    records: list[dict[str, Any]],
    workspace_path: str,
    task_id: str,
    *,
    timestamp: str | None = None,
    status_marker: str | None = None,
) -> list[dict[str, Any]]:
    matched: list[dict[str, Any]] = []
    for record in records:
        if _normalize_path(record.get("workspace")) != workspace_path:
            continue
        if str(record.get("task_id") or "") != task_id:
            continue
        if timestamp and str(record.get("timestamp") or "") != timestamp:
            continue
        if status_marker and str(record.get("status_marker") or "") != status_marker:
            continue
        matched.append(record)
    return sorted(matched, key=lambda item: _parse_timestamp(item.get("timestamp")), reverse=True)


def _format_learning_receipt_details(record: dict[str, Any]) -> str:
    detail_parts: list[str] = []
    writes = record.get("writes") or {}
    if writes:
        write_summary = ", ".join(
            f"{key}={int(value)}"
            for key, value in writes.items()
            if int(value) > 0
        )
        if write_summary:
            detail_parts.append(f"Writes: {write_summary}")
    learned = [str(item) for item in record.get("learned_items") or [] if str(item).strip()]
    if learned:
        detail_parts.append("Learned:\n" + "\n".join(f"- {item}" for item in learned))
    skipped = [str(item) for item in record.get("skipped_items") or [] if str(item).strip()]
    if skipped:
        detail_parts.append("Skipped:\n" + "\n".join(f"- {item}" for item in skipped))
    if str(record.get("details") or "").strip():
        detail_parts.append(str(record.get("details") or "").strip())
    return "\n\n".join(detail_parts)


def _record_entry(
    *,
    target: str,
    title: str,
    source_path: Path,
    record: dict[str, Any],
    summary: str | None = None,
    details: str | None = None,
) -> SyncRecordEntry:
    return SyncRecordEntry(
        target=target,
        title=title,
        timestamp=str(record.get("timestamp") or ""),
        summary=str(summary if summary is not None else record.get("summary") or ""),
        details=str(details if details is not None else record.get("details") or ""),
        artifacts=[str(item) for item in record.get("artifacts") or [] if str(item).strip()],
        source_path=str(source_path),
        route=str(record.get("route") or ""),
        mechanism=str(record.get("mechanism") or ""),
    )


def _project_memory_entry(
    *,
    lane: str,
    title: str,
    source_path: Path,
    record: dict[str, Any],
    bridge_metadata: dict[str, Any],
    include_details: bool,
) -> ProjectMemoryRecord:
    return ProjectMemoryRecord(
        lane=lane,
        title=title,
        timestamp=str(record.get("timestamp") or ""),
        summary=str(record.get("summary") or record.get("source_summary") or ""),
        details=str(record.get("details") or "") if include_details else "",
        artifacts=[str(item) for item in record.get("artifacts") or [] if str(item).strip()],
        workspace=str(record.get("workspace") or ""),
        task_id=str(record.get("task_id") or ""),
        agent=_runtime_display_name(record.get("agent") or ""),
        type=str(record.get("type") or ""),
        source_path=str(source_path),
        route=str(record.get("route") or ""),
        mechanism=str(record.get("mechanism") or ""),
        bridge_session_id=str(bridge_metadata["bridge_session_id"]),
        bridge_mode=str(bridge_metadata["bridge_mode"]),
        origin_runtime=str(bridge_metadata["origin_runtime"]),
        target_runtime=str(bridge_metadata["target_runtime"]),
        is_bridged=bool(bridge_metadata["is_bridged"]),
    )


def _is_rich_project_memory_record(record: dict[str, Any]) -> bool:
    record_type = str(record.get("type") or "")
    if record_type.endswith("_bundle") or record_type.endswith("_receipt"):
        return True
    return str(record.get("bundle_version") or "") == "2" and not record_type.endswith("_import")


def _filter_project_memory_records(
    records_by_lane: dict[str, list[dict[str, Any]]],
) -> dict[str, list[dict[str, Any]]]:
    rich_keys: set[tuple[str, str]] = set()
    for lane, lane_records in records_by_lane.items():
        for record in lane_records:
            task_id = str(record.get("task_id") or "").strip()
            if task_id and _is_rich_project_memory_record(record):
                rich_keys.add((lane, task_id))

    filtered: dict[str, list[dict[str, Any]]] = {}
    for lane, lane_records in records_by_lane.items():
        filtered_lane: list[dict[str, Any]] = []
        for record in lane_records:
            task_id = str(record.get("task_id") or "").strip()
            if task_id and (lane, task_id) in rich_keys and not _is_rich_project_memory_record(record):
                continue
            filtered_lane.append(record)
        filtered[lane] = filtered_lane
    return filtered


def _resolve_project_memory(
    *,
    workspace_path: str,
    receipts_path: Path,
    handoffs_path: Path,
    decision_log_path: Path,
    open_loops_path: Path,
    mempalace_path: Path,
    promoted_learnings_path: Path,
    learning_receipts_path: Path,
    include_details: bool,
    max_records: int,
) -> tuple[dict[str, int], list[ProjectMemoryRecord], str]:
    sources = {
        "receipts": (learning_receipts_path, "Receipt"),
        "handoffs": (handoffs_path, "Handoff"),
        "decision_log": (decision_log_path, "Decision"),
        "open_loops": (open_loops_path, "Open Loop"),
        "mempalace_records": (mempalace_path, "MemPalace"),
        "promoted_learnings": (promoted_learnings_path, "Promoted Learning"),
    }
    raw_records_by_lane: dict[str, list[dict[str, Any]]] = {lane: [] for lane in PROJECT_MEMORY_LANES}
    task_records: dict[str, list[dict[str, Any]]] = {}

    def remember_task_record(record: dict[str, Any]) -> None:
        task_id = str(record.get("task_id") or "").strip()
        if not task_id:
            return
        task_records.setdefault(task_id, []).append(record)

    for record in _read_ndjson(receipts_path):
        if _normalize_path(record.get("workspace")) != workspace_path:
            continue
        remember_task_record(record)

    for lane, (path, _default_title) in sources.items():
        for record in _read_ndjson(path):
            if _normalize_path(record.get("workspace")) != workspace_path:
                continue
            raw_records_by_lane[lane].append(record)
            remember_task_record(record)

    records_by_lane = _filter_project_memory_records(raw_records_by_lane)
    counts = {lane: 0 for lane in PROJECT_MEMORY_LANES}
    records: list[ProjectMemoryRecord] = []
    for lane, (path, default_title) in sources.items():
        for record in records_by_lane[lane]:
            counts[lane] += 1
            task_id = str(record.get("task_id") or "").strip()
            bridge_metadata = _resolve_bridge_metadata(task_records.get(task_id, [record]))
            records.append(
                _project_memory_entry(
                    lane=lane,
                    title=str(record.get("title") or default_title),
                    source_path=path,
                    record=record,
                    bridge_metadata=bridge_metadata,
                    include_details=include_details,
                )
            )
    records.sort(key=lambda item: _parse_timestamp(item.timestamp), reverse=True)
    last_updated = records[0].timestamp if records else ""
    return counts, records[:max_records], last_updated


def _resolve_sync_records(
    *,
    workspace_path: str,
    task_id: str,
    current_records: list[dict[str, Any]],
    workspace_handoffs: list[dict[str, Any]],
    workspace_learning: list[dict[str, Any]],
    handoffs_path: Path,
    receipts_path: Path,
    learning_receipts_path: Path,
    decision_log_path: Path,
    open_loops_path: Path,
    mempalace_path: Path,
    promoted_learnings_path: Path,
) -> list[SyncRecordEntry]:
    if not task_id or task_id == "-":
        return []

    receipt_records = _read_ndjson(receipts_path)
    decision_records = _read_ndjson(decision_log_path)
    open_loop_records = _read_ndjson(open_loops_path)
    mempalace_records = _read_ndjson(mempalace_path)
    promoted_records = _read_ndjson(promoted_learnings_path)

    latest_learning = _latest_record([item for item in workspace_learning if str(item.get("task_id") or "") == task_id])
    if latest_learning:
        sync_timestamp = str(latest_learning.get("timestamp") or "")
        entries = [
            _record_entry(
                target="receipts",
                title="Learning Receipt",
                source_path=learning_receipts_path,
                record=latest_learning,
                summary=str(latest_learning.get("source_summary") or "Structured sync audit receipt."),
                details=_format_learning_receipt_details(latest_learning),
            )
        ]
        for receipt in _matching_task_records(
            receipt_records,
            workspace_path,
            task_id,
            timestamp=sync_timestamp,
            status_marker="[SYNC_OK]",
        ):
            entries.append(
                _record_entry(
                    target="receipts",
                    title="Session Receipt",
                    source_path=receipts_path,
                    record=receipt,
                )
            )
        for record in _matching_task_records(decision_records, workspace_path, task_id, timestamp=sync_timestamp):
            entries.append(_record_entry(target="decision_log", title="Decision", source_path=decision_log_path, record=record))
        for record in _matching_task_records(workspace_handoffs, workspace_path, task_id, timestamp=sync_timestamp):
            entries.append(_record_entry(target="handoffs", title="Handoff", source_path=handoffs_path, record=record))
        for record in _matching_task_records(open_loop_records, workspace_path, task_id, timestamp=sync_timestamp):
            entries.append(_record_entry(target="open_loops", title="Open Loop", source_path=open_loops_path, record=record))
        for record in _matching_task_records(mempalace_records, workspace_path, task_id, timestamp=sync_timestamp):
            entries.append(_record_entry(target="mempalace_records", title="MemPalace", source_path=mempalace_path, record=record))
        for record in _matching_task_records(promoted_records, workspace_path, task_id, timestamp=sync_timestamp):
            entries.append(_record_entry(target="promoted_learnings", title="Promoted Learning", source_path=promoted_learnings_path, record=record))
        return entries

    latest_sync_receipt = _latest_record(
        [
            item
            for item in current_records
            if str(item.get("status_marker") or "") == "[SYNC_OK]"
        ]
    )
    if not latest_sync_receipt:
        return []

    entries = [
        _record_entry(
            target="receipts",
            title="Session Receipt",
            source_path=receipts_path,
            record=latest_sync_receipt,
        )
    ]
    latest_handoff = _latest_record([item for item in workspace_handoffs if str(item.get("task_id") or "") == task_id])
    if latest_handoff:
            entries.append(
                _record_entry(
                    target="handoffs",
                    title="Handoff",
                    source_path=handoffs_path,
                    record=latest_handoff,
                )
            )
    return entries


def _resolve_sync_delta(
    task_id: str,
    current_records: list[dict[str, Any]],
    workspace_handoffs: list[dict[str, Any]],
    learning_receipts: list[dict[str, Any]],
    sync_records: list[SyncRecordEntry],
    alerts: list[str],
) -> tuple[SyncDelta, str, str]:
    task_learning = [item for item in learning_receipts if str(item.get("task_id") or "") == task_id]
    if task_learning:
        latest = _latest_record(task_learning)
        writes = _empty_writes()
        for key, value in (latest.get("writes") or {}).items():
            if key in writes:
                writes[key] = int(value)
        learned_items = [str(item) for item in latest.get("learned_items") or [] if str(item).strip()]
        skipped_items = [str(item) for item in latest.get("skipped_items") or [] if str(item).strip()]
        if not learned_items:
            alerts.append("latest sync recorded no learned items")
            attention_state = "synced_without_learning"
        else:
            attention_state = "healthy"
        return (
            SyncDelta(
                writes_count_by_target=writes,
                learned_items=learned_items[:3],
                skipped_items=skipped_items[:2],
                source_summary=_shorten(str(latest.get("source_summary") or ""), 96),
                records=sync_records,
            ),
            "exact",
            attention_state,
        )

    sync_ok = any(item.get("status_marker") == "[SYNC_OK]" for item in current_records)
    if sync_ok:
        handoff = _latest_record([item for item in workspace_handoffs if str(item.get("task_id") or "") == task_id])
        inferred = _empty_writes()
        inferred["receipts"] = 1
        inferred["handoffs"] = 1 if handoff else 0
        alerts.append("sync audit source = inferred")
        alerts.append("latest sync is missing an explicit learning receipt")
        source_summary = str(_latest_record(current_records).get("summary") or handoff.get("summary") or "")
        return (
            SyncDelta(
                writes_count_by_target=inferred,
                learned_items=[],
                skipped_items=[],
                source_summary=_shorten(source_summary, 96),
                records=sync_records,
            ),
            "inferred",
            "missing_learning_receipt",
        )

    boot_ok = any(item.get("status_marker") == "[BOOT_OK]" for item in current_records)
    if boot_ok:
        return (
            SyncDelta(
                writes_count_by_target=_empty_writes(),
                learned_items=[],
                skipped_items=[],
                source_summary="Waiting for postflight sync.",
                records=sync_records,
            ),
            "none",
            "active_pending_sync",
        )

    return (
        SyncDelta(
            writes_count_by_target=_empty_writes(),
            learned_items=[],
            skipped_items=[],
            source_summary="No sync manifest yet.",
            records=sync_records,
        ),
        "none",
        "idle",
    )


def build_state(
    workspace: str | Path | None = None,
    global_root: str | Path | None = None,
    gemini_settings: str | Path | None = None,
    snapshot_mode: str = "full",
) -> DashboardState:
    global_root_path = resolve_global_root(global_root)
    gemini_settings_path = resolve_gemini_settings(gemini_settings)
    workspace_mode = "auto" if _is_auto_workspace(workspace) else "pinned"
    normalized_snapshot_mode = snapshot_mode.strip().lower() or "full"
    if normalized_snapshot_mode not in {"full", "summary"}:
        raise ValueError(f"unsupported snapshot mode: {snapshot_mode}")
    include_project_memory_details = normalized_snapshot_mode == "full"
    include_question_profile_content = normalized_snapshot_mode == "full"
    project_memory_limit = 120 if normalized_snapshot_mode == "full" else 24

    receipts_path = global_root_path / "sync" / "receipts.ndjson"
    handoffs_path = global_root_path / "memory" / "handoffs.ndjson"
    decision_log_path = global_root_path / "memory" / "decision-log.ndjson"
    open_loops_path = global_root_path / "memory" / "open-loops.ndjson"
    mempalace_path = global_root_path / "memory" / "mempalace-records.ndjson"
    promoted_learnings_path = global_root_path / "memory" / "promoted-learnings.ndjson"
    phase_log_path = global_root_path / "sync" / "task_phases.ndjson"
    learning_receipts_path = global_root_path / "sync" / "learning_receipts.ndjson"
    registry_path = global_root_path / "mcp" / "servers.yaml"
    project_registry_path = global_root_path / "projects" / "registry.yaml"

    receipts = _read_ndjson(receipts_path)
    handoffs = _read_ndjson(handoffs_path)
    phase_events = _read_ndjson(phase_log_path)
    learning_receipts = _read_ndjson(learning_receipts_path)
    registry_projects = _read_project_registry(project_registry_path)
    workspace_path = _resolve_workspace_path(workspace, receipts, handoffs, learning_receipts)

    workspace_receipts = [item for item in receipts if _normalize_path(item.get("workspace")) == workspace_path]
    workspace_handoffs = [item for item in handoffs if _normalize_path(item.get("workspace")) == workspace_path]
    workspace_learning = [item for item in learning_receipts if _normalize_path(item.get("workspace")) == workspace_path]

    alerts: list[str] = []
    if _is_auto_workspace(workspace):
        if workspace_path:
            alerts.append("workspace source = auto")
        else:
            alerts.append("workspace source = auto (no active workspace yet)")
    if not workspace_receipts:
        alerts.append("No receipts found for this workspace yet.")

    task_id, current_records = _select_current_task(workspace_receipts)
    current_records = sorted(current_records, key=lambda item: _parse_timestamp(item.get("timestamp")))
    latest_record = current_records[-1] if current_records else {}

    runtime = _runtime_display_name(latest_record.get("agent") or "-")
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

    task_handoffs = [item for item in workspace_handoffs if str(item.get("task_id") or "") == task_id]
    latest_handoff = _latest_record(task_handoffs or workspace_handoffs)
    last_handoff = str(latest_handoff.get("summary") or "No workspace handoff yet.")
    task_learning_records = [item for item in workspace_learning if str(item.get("task_id") or "") == task_id]
    bridge_metadata = _resolve_bridge_metadata(current_records + task_handoffs + task_learning_records)
    sync_records = _resolve_sync_records(
        workspace_path=workspace_path,
        task_id=task_id,
        current_records=current_records,
        workspace_handoffs=workspace_handoffs,
        workspace_learning=workspace_learning,
        handoffs_path=handoffs_path,
        receipts_path=receipts_path,
        learning_receipts_path=learning_receipts_path,
        decision_log_path=decision_log_path,
        open_loops_path=open_loops_path,
        mempalace_path=mempalace_path,
        promoted_learnings_path=promoted_learnings_path,
    )
    project_memory_counts, project_memory_records, project_memory_last_updated = _resolve_project_memory(
        workspace_path=workspace_path,
        receipts_path=receipts_path,
        handoffs_path=handoffs_path,
        decision_log_path=decision_log_path,
        open_loops_path=open_loops_path,
        mempalace_path=mempalace_path,
        promoted_learnings_path=promoted_learnings_path,
        learning_receipts_path=learning_receipts_path,
        include_details=include_project_memory_details,
        max_records=project_memory_limit,
    )
    user_question_profile = _resolve_user_question_profile(
        global_root=global_root_path,
        workspace_path=workspace_path,
        include_content=include_question_profile_content,
    )

    settings_payload = {}
    if gemini_settings_path.exists():
        settings_payload = json.loads(gemini_settings_path.read_text(encoding="utf-8"))
    active_mcp_count = len((settings_payload.get("mcpServers") or {}).keys())

    registry_servers = _read_mcp_registry(registry_path)
    enabled_registry_count = sum(1 for item in registry_servers if item.get("enabled") is True)
    disabled_registry_count = sum(1 for item in registry_servers if item.get("enabled") is False)
    available_workspaces = _build_available_workspaces(
        current_workspace=workspace_path,
        workspace_mode=workspace_mode,
        receipts=receipts,
        handoffs=handoffs,
        learning_receipts=learning_receipts,
        registry_projects=registry_projects,
    )

    last_sync_delta, sync_audit_source, attention_state = _resolve_sync_delta(
        task_id=task_id,
        current_records=current_records,
        workspace_handoffs=workspace_handoffs,
        learning_receipts=workspace_learning,
        sync_records=sync_records,
        alerts=alerts,
    )
    current_task_health = TaskHealth(
        is_booted=boot_status == "OK",
        has_exact_phase=phase_source == "exact",
        has_postflight_sync=sync_status == "OK",
        has_learning_receipt=sync_audit_source == "exact",
    )

    return DashboardState(
        workspace=workspace_path,
        workspace_mode=workspace_mode,
        snapshot_mode=normalized_snapshot_mode,
        project_name=Path(workspace_path).name if workspace_path else "(no workspace)",
        runtime=runtime,
        bridge_session_id=str(bridge_metadata["bridge_session_id"]),
        bridge_mode=str(bridge_metadata["bridge_mode"]),
        origin_runtime=str(bridge_metadata["origin_runtime"]),
        target_runtime=str(bridge_metadata["target_runtime"]),
        is_bridged=bool(bridge_metadata["is_bridged"]),
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
        available_workspaces=available_workspaces,
        alerts=alerts,
        last_sync_delta=last_sync_delta,
        user_question_profile=user_question_profile,
        includes_project_memory_details=include_project_memory_details,
        includes_question_profile_content=include_question_profile_content,
        project_memory_counts=project_memory_counts,
        project_memory_records=project_memory_records,
        project_memory_last_updated=project_memory_last_updated,
        sync_audit_source=sync_audit_source,
        current_task_health=current_task_health,
        attention_state=attention_state,
    )
