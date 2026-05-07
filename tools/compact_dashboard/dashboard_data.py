#!/usr/bin/env python3

from __future__ import annotations

import json
import os
from collections import defaultdict
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

DEFAULT_GLOBAL_ROOT = Path.home() / "AgentSharedFabric" / "global-agent-fabric"
DEFAULT_GEMINI_SETTINGS = Path.home() / ".gemini" / "settings.json"
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
CANONICAL_TOP_LEVELS = [
    "00 Raw Sources",
    "10 Wiki",
    "20 Queries and Reports",
    "90 System",
]
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
class ProjectUpdateLog:
    title: str
    summary: str
    preview: str
    content: str
    updated_at: str
    preferred_language: str
    source_task_count: int
    source_record_count: int
    is_available: bool


@dataclass
class KnowledgeBaseOverview:
    vault_root: str
    is_configured: bool
    is_normalized: bool
    total_projects: int
    active_workspaces: int
    legacy_source_count: int
    wiki_page_count: int
    graph_node_count: int
    graph_edge_count: int
    last_built_at: str
    summary: str


@dataclass
class KnowledgeProjectSummary:
    name: str
    slug: str
    workspace: str
    source: str
    lifecycle_phase: str
    runtime: str
    last_updated: str
    focus: str
    page_count: int
    has_wiki: bool
    wiki_root: str


@dataclass
class LegacySourceEntry:
    name: str
    path: str
    classification: str
    status: str


@dataclass
class KnowledgeGraphNode:
    id: str
    label: str
    kind: str
    path: str
    scope: str
    workspace: str
    status: str


@dataclass
class KnowledgeGraphEdge:
    source: str
    target: str
    kind: str


@dataclass
class KnowledgeGraphMeta:
    graph_path: str
    node_count: int
    edge_count: int
    updated_at: str
    is_available: bool


@dataclass
class ObserveRollup:
    project_name: str
    slug: str
    workspace_count: int
    latest_runtime: str
    latest_sync_status: str
    attention_state: str
    latest_activity: str
    latest_focus: str
    open_loop_count: int
    decision_count: int
    learning_count: int
    workspaces: list[str]


@dataclass
class CapabilityEntry:
    id: str
    label: str
    status: str
    source: str
    path: str
    detail: str


@dataclass
class CapabilityGroup:
    kind: str
    title: str
    configured_count: int
    enabled_count: int
    missing_count: int
    source_path: str
    entries: list[CapabilityEntry]


@dataclass
class SelectedScope:
    kind: str
    label: str
    project_name: str
    workspace: str


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
    project_update_log: ProjectUpdateLog
    knowledge_base_overview: KnowledgeBaseOverview
    knowledge_projects: list[KnowledgeProjectSummary]
    legacy_sources: list[LegacySourceEntry]
    knowledge_graph_meta: KnowledgeGraphMeta
    knowledge_graph_nodes: list[KnowledgeGraphNode]
    knowledge_graph_edges: list[KnowledgeGraphEdge]
    observe_rollups: list[ObserveRollup]
    capability_groups: list[CapabilityGroup]
    selected_scope: SelectedScope
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


def _read_ndjson(path: Path, alerts: list[str] | None = None, label: str | None = None) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    records: list[dict[str, Any]] = []
    malformed = 0
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        if alerts is not None:
            alerts.append(f"{label or path.name}: could not read NDJSON ({exc.__class__.__name__}).")
        return []
    for raw_line in lines:
        line = raw_line.strip()
        if not line:
            continue
        try:
            records.append(json.loads(line))
        except json.JSONDecodeError:
            malformed += 1
    if malformed and alerts is not None:
        alerts.append(f"{label or path.name}: skipped {malformed} malformed NDJSON record(s).")
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


def _read_mcp_registry(path: Path, alerts: list[str] | None = None) -> list[dict[str, Any]]:
    if not path.exists():
        if alerts is not None:
            alerts.append(f"MCP registry missing: {path}")
        return []
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        if alerts is not None:
            alerts.append(f"MCP registry unreadable: {path} ({exc.__class__.__name__}).")
        return []
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
            if server.get("id"):
                servers.append(server)
            elif alerts is not None:
                alerts.append(f"MCP registry ignored an entry without id in {path.name}.")
            continue
        idx += 1
    if not in_servers and alerts is not None:
        alerts.append(f"MCP registry has no top-level servers section: {path}")
    return servers


def _read_project_registry(path: Path, alerts: list[str] | None = None) -> list[dict[str, str]]:
    if not path.exists():
        if alerts is not None:
            alerts.append(f"Project registry missing: {path}")
        return []
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        if alerts is not None:
            alerts.append(f"Project registry unreadable: {path} ({exc.__class__.__name__}).")
        return []
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
            elif alerts is not None:
                alerts.append(f"Project registry ignored an entry without path in {path.name}.")
            continue
        idx += 1
    if not in_projects and alerts is not None:
        alerts.append(f"Project registry has no top-level projects section: {path}")
    return projects


def _read_registry_list(path: Path, top_level_key: str, alerts: list[str] | None = None) -> list[dict[str, Any]]:
    if not path.exists():
        if alerts is not None:
            alerts.append(f"{top_level_key} registry missing: {path}")
        return []
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        if alerts is not None:
            alerts.append(f"{top_level_key} registry unreadable: {path} ({exc.__class__.__name__}).")
        return []

    records: list[dict[str, Any]] = []
    in_section = False
    idx = 0
    while idx < len(lines):
        line = lines[idx]
        if line.strip() == f"{top_level_key}:":
            in_section = True
            idx += 1
            continue
        if not in_section:
            idx += 1
            continue
        if line.startswith("  -"):
            record: dict[str, Any] = {}
            idx += 1
            while idx < len(lines):
                raw = lines[idx]
                if raw.startswith("  -") or (raw and not raw.startswith("    ")):
                    break
                stripped = raw.strip()
                if not stripped:
                    idx += 1
                    continue
                if ":" in stripped and not stripped.endswith(":"):
                    key, raw_value = stripped.split(":", 1)
                    record[key] = _parse_scalar(raw_value)
                idx += 1
            if record:
                records.append(record)
            continue
        idx += 1
    if not in_section and alerts is not None:
        alerts.append(f"{top_level_key} registry has no top-level {top_level_key} section: {path}")
    return records


def _entry_label(item: dict[str, Any]) -> str:
    return str(item.get("name") or item.get("label") or item.get("id") or item.get("path") or "unnamed")


def _entry_status(item: dict[str, Any]) -> str:
    if item.get("enabled") is True:
        return "enabled"
    if item.get("enabled") is False:
        return "disabled"
    return str(item.get("status") or "configured")


def _entry_path(item: dict[str, Any]) -> str:
    return str(item.get("path") or item.get("root") or item.get("source_path") or item.get("command") or "")


def _entry_detail(item: dict[str, Any]) -> str:
    for key in ("description", "notes", "detail", "type", "command"):
        value = str(item.get(key) or "").strip()
        if value:
            return _shorten(value, 120)
    return ""


def _capability_entry(item: dict[str, Any], source: str) -> CapabilityEntry:
    label = _entry_label(item)
    return CapabilityEntry(
        id=str(item.get("id") or label),
        label=label,
        status=_entry_status(item),
        source=source,
        path=_entry_path(item),
        detail=_entry_detail(item),
    )


def _capability_group(
    *,
    kind: str,
    title: str,
    source_path: Path,
    items: list[dict[str, Any]],
    source: str,
) -> CapabilityGroup:
    entries = [_capability_entry(item, source) for item in items]
    return CapabilityGroup(
        kind=kind,
        title=title,
        configured_count=len(entries),
        enabled_count=sum(1 for item in entries if item.status == "enabled"),
        missing_count=0 if source_path.exists() else 1,
        source_path=str(source_path),
        entries=entries,
    )


def _directory_capability_group(
    *,
    kind: str,
    title: str,
    root: Path,
    source: str,
) -> CapabilityGroup:
    entries: list[CapabilityEntry] = []
    if root.exists():
        for child in sorted(root.iterdir(), key=lambda item: item.name.lower()):
            if child.name.startswith("."):
                continue
            if child.is_dir() or child.suffix.lower() in {".md", ".yaml", ".yml", ".json", ".py"}:
                entries.append(
                    CapabilityEntry(
                        id=child.stem if child.is_file() else child.name,
                        label=child.stem if child.is_file() else child.name,
                        status="configured",
                        source=source,
                        path=str(child),
                        detail="Directory" if child.is_dir() else child.suffix.lstrip(".").upper(),
                    )
                )
    return CapabilityGroup(
        kind=kind,
        title=title,
        configured_count=len(entries),
        enabled_count=len(entries),
        missing_count=0 if root.exists() else 1,
        source_path=str(root),
        entries=entries,
    )


def _resolve_capability_groups(
    global_root_path: Path,
    alerts: list[str],
    *,
    mcp_items: list[dict[str, Any]] | None = None,
) -> list[CapabilityGroup]:
    mcp_path = global_root_path / "mcp" / "servers.yaml"
    skills_path = global_root_path / "skills" / "sources.yaml"
    workflows_path = global_root_path / "workflows" / "sources.yaml"
    agents_root = global_root_path / "agents"

    mcp_items = mcp_items if mcp_items is not None else _read_mcp_registry(mcp_path, alerts)
    skill_items = _read_registry_list(skills_path, "sources", alerts)
    workflow_items = _read_registry_list(workflows_path, "sources", alerts)

    return [
        _capability_group(kind="mcp", title="MCP Servers", source_path=mcp_path, items=mcp_items, source="mcp/servers.yaml"),
        _capability_group(kind="skills", title="Skill Registries", source_path=skills_path, items=skill_items, source="skills/sources.yaml"),
        _capability_group(kind="workflows", title="Workflow Registries", source_path=workflows_path, items=workflow_items, source="workflows/sources.yaml"),
        _directory_capability_group(kind="subagents", title="Subagent Slots", root=agents_root, source="agents/"),
    ]


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


def _count_cjk_characters(text: str) -> int:
    total = 0
    for ch in text:
        if "\u4e00" <= ch <= "\u9fff" or "\u3400" <= ch <= "\u4dbf":
            total += 1
    return total


def _detect_preferred_language(
    *,
    user_question_profile: UserQuestionProfileState,
    last_handoff: str,
    project_memory_records: list[ProjectMemoryRecord],
) -> str:
    candidate_text = "\n".join(
        [
            user_question_profile.workspace_profile.content,
            user_question_profile.workspace_profile.summary,
            user_question_profile.workspace_profile.preview,
            user_question_profile.global_profile.content,
            user_question_profile.global_profile.summary,
            user_question_profile.global_profile.preview,
            last_handoff,
            "\n".join(record.summary for record in project_memory_records[:12]),
        ]
    )
    lowered = candidate_text.lower()
    cjk_count = _count_cjk_characters(candidate_text)
    chinese_hints = lowered.count("中文") + lowered.count("chinese") + lowered.count("mandarin")
    english_hints = lowered.count("英文") + lowered.count("english")
    if cjk_count >= 12 or chinese_hints > english_hints:
        return "zh"
    return "en"


def _group_project_memory_by_task(records: list[ProjectMemoryRecord]) -> list[tuple[str, list[ProjectMemoryRecord]]]:
    grouped: list[tuple[str, list[ProjectMemoryRecord]]] = []
    by_task: dict[str, list[ProjectMemoryRecord]] = {}
    ordered_tasks: list[str] = []
    for record in records:
        task_id = record.task_id or "(no task id)"
        if task_id not in by_task:
            ordered_tasks.append(task_id)
            by_task[task_id] = []
        by_task[task_id].append(record)
    for task_id in ordered_tasks:
        grouped.append((task_id, by_task[task_id]))
    return grouped


def _format_update_log_record(record: ProjectMemoryRecord, preferred_language: str) -> list[str]:
    lane_label = PROJECT_MEMORY_LABELS.get(record.lane, record.lane)
    header = f"- [{record.timestamp or 'no time'}] [{lane_label}] {record.summary or '(no summary)'}"
    lines = [header]
    details = str(record.details or "").strip()
    if details:
        detail_lines = [line.strip() for line in details.splitlines() if line.strip()]
        capped_lines = detail_lines[:8]
        if preferred_language == "zh":
            lines.append("  详细：")
        else:
            lines.append("  Details:")
        for line in capped_lines:
            lines.append(f"  - {line}")
        if len(detail_lines) > len(capped_lines):
            lines.append("  - ..." if preferred_language == "en" else "  - ……")
    if record.artifacts:
        artifact_label = "Artifacts" if preferred_language == "en" else "关联文件"
        lines.append(f"  {artifact_label}:")
        for artifact in record.artifacts[:5]:
            lines.append(f"  - {artifact}")
    return lines


def _detail_excerpt(text: str, max_lines: int = 3) -> list[str]:
    lines = [line.strip() for line in str(text or "").splitlines() if line.strip()]
    return lines[:max_lines]


def _collect_validation_notes(records: list[ProjectMemoryRecord], preferred_language: str) -> list[str]:
    notes: list[str] = []
    keywords = ("test", "unittest", "validated", "validation", "build", "py_compile", "snapshot", "compile")
    seen: set[str] = set()
    for record in reversed(records):
        haystacks = [record.summary.lower(), record.details.lower()]
        if not any(any(keyword in haystack for keyword in keywords) for haystack in haystacks):
            continue
        candidate = record.summary or ""
        if candidate and candidate not in seen:
            notes.append(candidate)
            seen.add(candidate)
        for excerpt in _detail_excerpt(record.details, max_lines=2):
            if any(keyword in excerpt.lower() for keyword in keywords) and excerpt not in seen:
                notes.append(excerpt)
                seen.add(excerpt)
        if len(notes) >= 6:
            break
    return notes


def _task_section_lines(task_id: str, records: list[ProjectMemoryRecord], preferred_language: str) -> list[str]:
    records_sorted = sorted(records, key=lambda item: _parse_timestamp(item.timestamp))
    latest = records_sorted[-1]
    started = records_sorted[0].timestamp or "unknown"
    ended = latest.timestamp or "unknown"
    by_lane: dict[str, list[ProjectMemoryRecord]] = {}
    for record in records_sorted:
        by_lane.setdefault(record.lane, []).append(record)

    if preferred_language == "zh":
        lines = [
            f"### {task_id}",
            f"- 时间范围：`{started}` -> `{ended}`",
            f"- 记录条数：`{len(records_sorted)}`",
        ]
        latest_receipt = by_lane.get("receipts", [])
        if latest_receipt:
            lines.append(f"- 本轮摘要：{latest_receipt[-1].summary}")
        latest_handoff = by_lane.get("handoffs", [])
        if latest_handoff:
            lines.append(f"- 交接状态：{latest_handoff[-1].summary}")
        decisions = by_lane.get("decision_log", [])[-2:]
        if decisions:
            lines.append("- 关键决策：")
            for record in decisions:
                lines.append(f"  - {record.summary}")
        learns = by_lane.get("promoted_learnings", [])[-2:]
        if learns:
            lines.append("- 学习沉淀：")
            for record in learns:
                lines.append(f"  - {record.summary}")
        loops = by_lane.get("open_loops", [])[-2:]
        if loops:
            lines.append("- 未决项：")
            for record in loops:
                lines.append(f"  - {record.summary}")
        detail_records = [record for record in records_sorted if record.details.strip()][-2:]
        if detail_records:
            lines.append("- 细节摘录：")
            for record in detail_records:
                lane_label = PROJECT_MEMORY_LABELS.get(record.lane, record.lane)
                lines.append(f"  - [{lane_label}] {record.summary}")
                for excerpt in _detail_excerpt(record.details, max_lines=2):
                    lines.append(f"    - {excerpt}")
    else:
        lines = [
            f"### {task_id}",
            f"- Time range: `{started}` -> `{ended}`",
            f"- Record count: `{len(records_sorted)}`",
        ]
        latest_receipt = by_lane.get("receipts", [])
        if latest_receipt:
            lines.append(f"- Round summary: {latest_receipt[-1].summary}")
        latest_handoff = by_lane.get("handoffs", [])
        if latest_handoff:
            lines.append(f"- Handoff state: {latest_handoff[-1].summary}")
        decisions = by_lane.get("decision_log", [])[-2:]
        if decisions:
            lines.append("- Key decisions:")
            for record in decisions:
                lines.append(f"  - {record.summary}")
        learns = by_lane.get("promoted_learnings", [])[-2:]
        if learns:
            lines.append("- Durable learnings:")
            for record in learns:
                lines.append(f"  - {record.summary}")
        loops = by_lane.get("open_loops", [])[-2:]
        if loops:
            lines.append("- Open items:")
            for record in loops:
                lines.append(f"  - {record.summary}")
        detail_records = [record for record in records_sorted if record.details.strip()][-2:]
        if detail_records:
            lines.append("- Detail excerpts:")
            for record in detail_records:
                lane_label = PROJECT_MEMORY_LABELS.get(record.lane, record.lane)
                lines.append(f"  - [{lane_label}] {record.summary}")
                for excerpt in _detail_excerpt(record.details, max_lines=2):
                    lines.append(f"    - {excerpt}")
    lines.append("")
    return lines


def _project_update_log(
    *,
    project_name: str,
    task_id: str,
    last_handoff: str,
    project_memory_counts: dict[str, int],
    project_memory_records: list[ProjectMemoryRecord],
    project_memory_last_updated: str,
    user_question_profile: UserQuestionProfileState,
    include_content: bool,
) -> ProjectUpdateLog:
    if not project_memory_records:
        return ProjectUpdateLog(
            title="Project Update Log",
            summary="No project memory is available yet.",
            preview="",
            content="",
            updated_at="",
            preferred_language="en",
            source_task_count=0,
            source_record_count=0,
            is_available=False,
        )

    preferred_language = _detect_preferred_language(
        user_question_profile=user_question_profile,
        last_handoff=last_handoff,
        project_memory_records=project_memory_records,
    )
    chronological_records = sorted(project_memory_records, key=lambda item: _parse_timestamp(item.timestamp))
    grouped_tasks = _group_project_memory_by_task(chronological_records)
    recent_grouped_tasks = grouped_tasks[-8:]
    distinct_task_count = len({record.task_id or "(no task id)" for record in project_memory_records})
    nonzero_counts = [
        f"{PROJECT_MEMORY_LABELS.get(lane, lane)} {count}"
        for lane, count in project_memory_counts.items()
        if count > 0
    ]
    top_summaries = [record.summary for record in chronological_records[-5:] if record.summary][-3:]
    latest_open_loops = [record.summary for record in reversed(chronological_records) if record.lane == "open_loops" and record.summary][:4]
    latest_learnings = [record.summary for record in reversed(chronological_records) if record.lane == "promoted_learnings" and record.summary][:4]
    latest_decisions = [record.summary for record in reversed(chronological_records) if record.lane == "decision_log" and record.summary][:4]
    validation_notes = _collect_validation_notes(chronological_records, preferred_language)

    if preferred_language == "zh":
        title = "项目更新日志"
        summary = f"已根据 {distinct_task_count} 个任务与 {len(project_memory_records)} 条项目记忆自动整理，按时间连续展开。"
        preview = "；".join(top_summaries) if top_summaries else "暂无可展示的近期更新。"
        lines = [
            f"# {title}",
            "",
            f"- 项目：`{project_name}`",
            f"- 当前任务：`{task_id}`" if task_id and task_id != "-" else "- 当前任务：暂无",
            f"- 最近更新时间：`{project_memory_last_updated}`" if project_memory_last_updated else "- 最近更新时间：暂无",
            f"- 生成语言：`中文`",
            f"- 来源任务数：`{distinct_task_count}`",
            f"- 来源记录数：`{len(project_memory_records)}`",
            "",
            "## 总览",
            f"- 自动依据现有 Project Memory 整理，而不是额外维护第二套手写日志。",
            f"- 板块覆盖：{', '.join(nonzero_counts)}" if nonzero_counts else "- 板块覆盖：暂无",
            f"- 本报告覆盖最近 `{len(recent_grouped_tasks)}` 个任务分段，同时维持跨轮次连续性。",
            "",
            "## 当前焦点",
            f"- {last_handoff or '暂无 handoff 摘要。'}",
            "",
            "## 近期决策",
        ]
        if latest_decisions:
            lines.extend([f"- {item}" for item in latest_decisions])
        else:
            lines.append("- 暂无显式决策摘要。")
        lines.extend(
            [
                "",
                "## 近期学习",
            ]
        )
        if latest_learnings:
            lines.extend([f"- {item}" for item in latest_learnings])
        else:
            lines.append("- 暂无稳定学习条目。")
        lines.extend(
            [
                "",
                "## 待处理与风险",
            ]
        )
        if latest_open_loops:
            lines.extend([f"- {item}" for item in latest_open_loops])
        else:
            lines.append("- 当前没有明确记录的 open loops。")
        lines.extend(
            [
                "",
                "## 验证与证据",
            ]
        )
        if validation_notes:
            lines.extend([f"- {item}" for item in validation_notes])
        else:
            lines.append("- 当前项目记忆中没有提取到明确的验证记录。")
        lines.extend(
            [
                "",
                "## 近期轮次变更",
            ]
        )
        for grouped_task_id, records in reversed(recent_grouped_tasks):
            lines.extend(_task_section_lines(grouped_task_id, records, preferred_language))
        lines.extend(
            [
                "## 建议下一步",
            ]
        )
        if latest_open_loops:
            lines.extend([f"- 优先处理：{item}" for item in latest_open_loops[:3]])
        elif latest_handoff := last_handoff:
            lines.append(f"- 延续当前交接重点：{latest_handoff}")
        else:
            lines.append("- 暂无明确下一步建议。")
    else:
        title = "Project Update Log"
        summary = f"Auto-compiled from {distinct_task_count} tasks and {len(project_memory_records)} project-memory records using a structured round-by-round report format."
        preview = " ".join(top_summaries) if top_summaries else "No recent project-memory summaries are available yet."
        lines = [
            f"# {title}",
            "",
            f"- Project: `{project_name}`",
            f"- Current task: `{task_id}`" if task_id and task_id != "-" else "- Current task: none",
            f"- Last updated: `{project_memory_last_updated}`" if project_memory_last_updated else "- Last updated: n/a",
            f"- Generated language: `English`",
            f"- Source tasks: `{distinct_task_count}`",
            f"- Source records: `{len(project_memory_records)}`",
            "",
            "## Overview",
            "- This report is compiled from existing Project Memory rather than maintained as a second manual changelog.",
            f"- Lane coverage: {', '.join(nonzero_counts)}" if nonzero_counts else "- Lane coverage: none",
            f"- This report covers the latest `{len(recent_grouped_tasks)}` task segments while preserving cross-round continuity.",
            "",
            "## Current Focus",
            f"- {last_handoff or 'No handoff summary is available yet.'}",
            "",
            "## Recent Decisions",
        ]
        if latest_decisions:
            lines.extend([f"- {item}" for item in latest_decisions])
        else:
            lines.append("- No explicit decision summaries are available yet.")
        lines.extend(
            [
                "",
                "## Recent Learnings",
            ]
        )
        if latest_learnings:
            lines.extend([f"- {item}" for item in latest_learnings])
        else:
            lines.append("- No stable learnings are recorded yet.")
        lines.extend(
            [
                "",
                "## Open Loops and Risks",
            ]
        )
        if latest_open_loops:
            lines.extend([f"- {item}" for item in latest_open_loops])
        else:
            lines.append("- There are no explicitly recorded open loops right now.")
        lines.extend(
            [
                "",
                "## Validation and Evidence",
            ]
        )
        if validation_notes:
            lines.extend([f"- {item}" for item in validation_notes])
        else:
            lines.append("- No explicit validation evidence was extracted from the current project memory.")
        lines.extend(
            [
                "",
                "## Recent Rounds",
            ]
        )
        for grouped_task_id, records in reversed(recent_grouped_tasks):
            lines.extend(_task_section_lines(grouped_task_id, records, preferred_language))
        lines.extend(
            [
                "## Recommended Next Steps",
            ]
        )
        if latest_open_loops:
            lines.extend([f"- Prioritize: {item}" for item in latest_open_loops[:3]])
        elif last_handoff:
            lines.append(f"- Continue the current handoff focus: {last_handoff}")
        else:
            lines.append("- No concrete next-step recommendation is available yet.")

    return ProjectUpdateLog(
        title=title,
        summary=_shorten(summary, 120),
        preview=_shorten(preview, 280),
        content="\n".join(lines).strip() if include_content else "",
        updated_at=project_memory_last_updated,
        preferred_language=preferred_language,
        source_task_count=distinct_task_count,
        source_record_count=len(project_memory_records),
        is_available=True,
    )


def _read_json(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {}
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return {}


def _project_slug(value: str) -> str:
    slug = "".join(ch.lower() if ch.isalnum() else "-" for ch in value.strip())
    while "--" in slug:
        slug = slug.replace("--", "-")
    return slug.strip("-") or "workspace"


def _project_identity_key(value: str) -> str:
    return "".join(ch.lower() for ch in value.strip() if ch.isalnum())


def _resolve_selected_scope(workspace_path: str, registry_projects: list[dict[str, str]]) -> SelectedScope:
    if not workspace_path:
        return SelectedScope(kind="all_vault", label="All Vault", project_name="", workspace="")
    registry_by_path = {
        _normalize_path(project.get("path")): project for project in registry_projects if _normalize_path(project.get("path"))
    }
    project = registry_by_path.get(workspace_path)
    project_name = (project or {}).get("name") or Path(workspace_path).name
    return SelectedScope(
        kind="workspace",
        label=f"{project_name} · Workspace",
        project_name=project_name,
        workspace=workspace_path,
    )


def _memory_counts_by_workspace(global_root_path: Path) -> dict[str, dict[str, int]]:
    counts: dict[str, dict[str, int]] = defaultdict(lambda: defaultdict(int))
    for lane, file_name in [
        ("decision_log", "decision-log.ndjson"),
        ("open_loops", "open-loops.ndjson"),
        ("promoted_learnings", "promoted-learnings.ndjson"),
    ]:
        for record in _read_ndjson(global_root_path / "memory" / file_name):
            workspace_path = _normalize_path(record.get("workspace"))
            if not workspace_path:
                continue
            counts[workspace_path][lane] += 1
    return counts


def _fallback_knowledge_projects(
    *,
    vault_root_path: Path,
    registry_projects: list[dict[str, str]],
    available_workspaces: list[WorkspaceOption],
) -> list[KnowledgeProjectSummary]:
    registry_by_path = {
        _normalize_path(project.get("path")): project for project in registry_projects if _normalize_path(project.get("path"))
    }
    projects: list[KnowledgeProjectSummary] = []
    seen: set[str] = set()
    for option in available_workspaces:
        workspace_path = option.path
        if not workspace_path or workspace_path in seen:
            continue
        seen.add(workspace_path)
        project = registry_by_path.get(workspace_path)
        fallback_label = (project or {}).get("name") or option.label or Path(workspace_path).name
        slug = _project_slug(fallback_label or "workspace")
        project_name = _project_display_name(str(fallback_label or ""), workspace_path, slug)
        wiki_root = vault_root_path / "10 Wiki" / "Projects" / slug
        page_count = len(list(wiki_root.glob("*.md"))) if wiki_root.exists() else 0
        projects.append(
            KnowledgeProjectSummary(
                name=project_name,
                slug=slug,
                workspace=workspace_path,
                source=option.source,
                lifecycle_phase="IDLE",
                runtime="",
                last_updated=option.last_seen,
                focus="",
                page_count=page_count,
                has_wiki=wiki_root.exists(),
                wiki_root=str(wiki_root),
            )
        )
    return sorted(projects, key=lambda item: item.name.lower())


def _project_display_name(name: str, workspace: str, slug: str) -> str:
    normalized_name = str(name or "").strip()
    if normalized_name:
        return normalized_name
    workspace_path = _normalize_path(workspace)
    if workspace_path:
        workspace_name = Path(workspace_path).name.strip()
        if workspace_name:
            return workspace_name
    slug_name = str(slug or "").strip().replace("-", " ")
    if slug_name:
        return slug_name.title()
    return "Workspace"


def _looks_like_placeholder_workspace(raw_workspace: str, slug: str, name: str) -> bool:
    raw_value = str(raw_workspace or "").strip()
    if not raw_value:
        return True
    if Path(raw_value).is_absolute():
        return False
    raw_key = _project_identity_key(raw_value)
    if not raw_key:
        return True
    return raw_key in {
        _project_identity_key(slug),
        _project_identity_key(name),
        _project_identity_key(name.replace("_", " ")),
    }


def _canonicalize_manifest_project(
    *,
    item: dict[str, Any],
    vault_root_path: Path,
    fallback_by_slug: dict[str, KnowledgeProjectSummary],
) -> KnowledgeProjectSummary:
    raw_slug = str(item.get("slug") or "")
    raw_name = str(item.get("name") or item.get("project_name") or "")
    raw_workspace = str(item.get("workspace") or "")
    fallback = fallback_by_slug.get(raw_slug)

    canonical_workspace = _normalize_path(raw_workspace)
    if fallback and _looks_like_placeholder_workspace(raw_workspace, raw_slug, raw_name):
        canonical_workspace = fallback.workspace

    display_name = _project_display_name(raw_name, canonical_workspace, raw_slug)
    if fallback:
        raw_name_key = _project_identity_key(raw_name)
        fallback_name_key = _project_identity_key(fallback.name)
        slug_key = _project_identity_key(raw_slug)
        if not raw_name_key or raw_name_key == slug_key:
            display_name = fallback.name
        elif fallback_name_key and raw_name_key == fallback_name_key:
            display_name = fallback.name

    effective_workspace = canonical_workspace or (fallback.workspace if fallback else "")
    effective_slug = raw_slug or (fallback.slug if fallback else _project_slug(display_name))
    wiki_root = vault_root_path / "10 Wiki" / "Projects" / effective_slug

    return KnowledgeProjectSummary(
        name=display_name,
        slug=effective_slug,
        workspace=effective_workspace,
        source=str(item.get("source") or (fallback.source if fallback else "registry")),
        lifecycle_phase=str(item.get("lifecycle_phase") or "IDLE"),
        runtime=_runtime_display_name(item.get("runtime") or ""),
        last_updated=str(item.get("last_updated") or ""),
        focus=_shorten(str(item.get("focus") or ""), 96),
        page_count=int(item.get("page_count") or 0),
        has_wiki=bool(item.get("page_count")),
        wiki_root=str(wiki_root),
    )


def _merge_knowledge_projects(
    primary_projects: list[KnowledgeProjectSummary],
    fallback_projects: list[KnowledgeProjectSummary],
) -> list[KnowledgeProjectSummary]:
    merged: list[KnowledgeProjectSummary] = []
    seen: set[str] = set()

    def merge_key(project: KnowledgeProjectSummary) -> str:
        workspace = _normalize_path(project.workspace)
        if workspace:
            return f"workspace:{workspace}"
        if project.slug:
            return f"slug:{project.slug}"
        return f"name:{project.name.strip().lower()}"

    for project in [*primary_projects, *fallback_projects]:
        key = merge_key(project)
        if key in seen:
            continue
        seen.add(key)
        merged.append(project)
    return merged


def _resolve_knowledge_bundle(
    *,
    global_root_path: Path,
    vault_root: str | Path | None,
    registry_projects: list[dict[str, str]],
    available_workspaces: list[WorkspaceOption],
    workspace_path: str,
    project_memory_counts: dict[str, int],
    attention_state: str,
    lifecycle_phase: str,
    runtime: str,
    project_memory_last_updated: str,
    last_handoff: str,
) -> tuple[
    KnowledgeBaseOverview,
    list[KnowledgeProjectSummary],
    list[LegacySourceEntry],
    KnowledgeGraphMeta,
    list[KnowledgeGraphNode],
    list[KnowledgeGraphEdge],
    list[ObserveRollup],
    SelectedScope,
]:
    selected_scope = _resolve_selected_scope(workspace_path, registry_projects)
    if not vault_root:
        return (
            KnowledgeBaseOverview(
                vault_root="",
                is_configured=False,
                is_normalized=False,
                total_projects=0,
                active_workspaces=0,
                legacy_source_count=0,
                wiki_page_count=0,
                graph_node_count=0,
                graph_edge_count=0,
                last_built_at="",
                summary="No Obsidian vault is configured yet.",
            ),
            [],
            [],
            KnowledgeGraphMeta(graph_path="", node_count=0, edge_count=0, updated_at="", is_available=False),
            [],
            [],
            [],
            selected_scope,
        )

    vault_root_path = Path(vault_root).expanduser()
    if not vault_root_path.exists():
        return (
            KnowledgeBaseOverview(
                vault_root=str(vault_root_path),
                is_configured=True,
                is_normalized=False,
                total_projects=0,
                active_workspaces=0,
                legacy_source_count=0,
                wiki_page_count=0,
                graph_node_count=0,
                graph_edge_count=0,
                last_built_at="",
                summary="Configured Obsidian vault root does not exist.",
            ),
            [],
            [],
            KnowledgeGraphMeta(graph_path="", node_count=0, edge_count=0, updated_at="", is_available=False),
            [],
            [],
            [],
            selected_scope,
        )

    manifest_path = vault_root_path / "90 System" / "knowledge-base-manifest.json"
    graph_path = vault_root_path / "90 System" / "graph.json"
    manifest = _read_json(manifest_path)
    graph_payload = _read_json(graph_path)

    legacy_sources = [
        LegacySourceEntry(
            name=str(item.get("name") or ""),
            path=str(item.get("path") or ""),
            classification=str(item.get("classification") or ""),
            status=str(item.get("status") or ""),
        )
        for item in manifest.get("legacy_sources", [])
    ]

    fallback_projects = _fallback_knowledge_projects(
        vault_root_path=vault_root_path,
        registry_projects=registry_projects,
        available_workspaces=available_workspaces,
    )
    fallback_by_slug = {project.slug: project for project in fallback_projects if project.slug}

    if manifest.get("projects"):
        manifest_projects = [
            _canonicalize_manifest_project(
                item=item,
                vault_root_path=vault_root_path,
                fallback_by_slug=fallback_by_slug,
            )
            for item in manifest.get("projects", [])
        ]
        knowledge_projects = _merge_knowledge_projects(manifest_projects, fallback_projects)
    else:
        knowledge_projects = fallback_projects

    if workspace_path and workspace_path not in {item.workspace for item in knowledge_projects}:
        project_name = _project_display_name(selected_scope.project_name, workspace_path, _project_slug(selected_scope.project_name or Path(workspace_path).name))
        slug = _project_slug(project_name)
        wiki_root = vault_root_path / "10 Wiki" / "Projects" / slug
        knowledge_projects.insert(
            0,
            KnowledgeProjectSummary(
                name=project_name,
                slug=slug,
                workspace=workspace_path,
                source="manual",
                lifecycle_phase=lifecycle_phase,
                runtime=runtime,
                last_updated=project_memory_last_updated,
                focus=last_handoff,
                page_count=len(list(wiki_root.glob("*.md"))) if wiki_root.exists() else 0,
                has_wiki=wiki_root.exists(),
                wiki_root=str(wiki_root),
            ),
        )

    graph_nodes = [
        KnowledgeGraphNode(
            id=str(item.get("id") or ""),
            label=str(item.get("label") or ""),
            kind=str(item.get("kind") or ""),
            path=str(item.get("path") or ""),
            scope=str(item.get("scope") or ""),
            workspace=_normalize_path(item.get("workspace")),
            status=str(item.get("status") or ""),
        )
        for item in graph_payload.get("nodes", [])
    ]
    graph_edges = [
        KnowledgeGraphEdge(
            source=str(item.get("source") or ""),
            target=str(item.get("target") or ""),
            kind=str(item.get("kind") or ""),
        )
        for item in graph_payload.get("edges", [])
    ]
    graph_updated_at = ""
    if graph_path.exists():
        graph_updated_at = datetime.fromtimestamp(graph_path.stat().st_mtime, tz=timezone.utc).astimezone().strftime("%Y-%m-%d %H:%M")
    graph_meta = KnowledgeGraphMeta(
        graph_path=str(graph_path),
        node_count=int(graph_payload.get("node_count") or len(graph_nodes)),
        edge_count=int(graph_payload.get("edge_count") or len(graph_edges)),
        updated_at=graph_updated_at,
        is_available=graph_path.exists() and bool(graph_nodes),
    )

    summary_counts = manifest.get("summary", {})
    total_projects = len(knowledge_projects)
    active_workspaces = len([item for item in knowledge_projects if item.source == "active"])
    wiki_page_count = int(summary_counts.get("wiki_page_count") or sum(item.page_count for item in knowledge_projects))
    graph_node_count = int(summary_counts.get("graph_node_count") or len(graph_nodes))
    graph_edge_count = int(summary_counts.get("graph_edge_count") or len(graph_edges))
    last_built_at = str(manifest.get("generated_at") or "")
    is_normalized = all((vault_root_path / name).exists() for name in CANONICAL_TOP_LEVELS)

    lane_counts_by_workspace = _memory_counts_by_workspace(global_root_path)
    observe_rollups: list[ObserveRollup] = []
    for project in knowledge_projects:
        lane_counts = lane_counts_by_workspace.get(project.workspace, {})
        latest_sync_status = "OK" if project.lifecycle_phase == "SYNCED" else "--"
        observe_rollups.append(
            ObserveRollup(
                project_name=project.name,
                slug=project.slug,
                workspace_count=1,
                latest_runtime=project.runtime,
                latest_sync_status=latest_sync_status,
                attention_state=attention_state if project.workspace == workspace_path else ("healthy" if latest_sync_status == "OK" else "idle"),
                latest_activity=project.last_updated,
                latest_focus=project.focus,
                open_loop_count=int(lane_counts.get("open_loops", 0)),
                decision_count=int(lane_counts.get("decision_log", 0)),
                learning_count=int(lane_counts.get("promoted_learnings", 0)),
                workspaces=[project.workspace] if project.workspace else [],
            )
        )

    overview = KnowledgeBaseOverview(
        vault_root=str(vault_root_path),
        is_configured=True,
        is_normalized=is_normalized,
        total_projects=total_projects,
        active_workspaces=active_workspaces,
        legacy_source_count=len(legacy_sources),
        wiki_page_count=wiki_page_count,
        graph_node_count=graph_node_count,
        graph_edge_count=graph_edge_count,
        last_built_at=last_built_at,
        summary=_shorten(
            f"Vault-wide knowledge base with {total_projects} projects, {wiki_page_count} wiki pages, {len(legacy_sources)} legacy sources, and a {graph_node_count}-node graph.",
            140,
        ),
    )
    return (
        overview,
        knowledge_projects,
        legacy_sources,
        graph_meta,
        graph_nodes,
        graph_edges,
        sorted(observe_rollups, key=lambda item: (item.latest_activity, item.project_name), reverse=True),
        selected_scope,
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
    vault_root: str | Path | None = None,
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
    include_update_log_content = normalized_snapshot_mode == "full"
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

    alerts: list[str] = []
    receipts = _read_ndjson(receipts_path, alerts, "receipts")
    handoffs = _read_ndjson(handoffs_path, alerts, "handoffs")
    phase_events = _read_ndjson(phase_log_path, alerts, "task phases")
    learning_receipts = _read_ndjson(learning_receipts_path, alerts, "learning receipts")
    registry_projects = _read_project_registry(project_registry_path, alerts)
    workspace_path = _resolve_workspace_path(workspace, receipts, handoffs, learning_receipts)

    workspace_receipts = [item for item in receipts if _normalize_path(item.get("workspace")) == workspace_path]
    workspace_handoffs = [item for item in handoffs if _normalize_path(item.get("workspace")) == workspace_path]
    workspace_learning = [item for item in learning_receipts if _normalize_path(item.get("workspace")) == workspace_path]

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
    project_update_log = _project_update_log(
        project_name=Path(workspace_path).name if workspace_path else "(no workspace)",
        task_id=task_id,
        last_handoff=last_handoff,
        project_memory_counts=project_memory_counts,
        project_memory_records=project_memory_records,
        project_memory_last_updated=project_memory_last_updated,
        user_question_profile=user_question_profile,
        include_content=include_update_log_content,
    )

    settings_payload = {}
    if gemini_settings_path.exists():
        try:
            settings_payload = json.loads(gemini_settings_path.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError) as exc:
            alerts.append(f"Gemini settings unreadable: {gemini_settings_path} ({exc.__class__.__name__}).")
    active_mcp_count = len((settings_payload.get("mcpServers") or {}).keys())

    registry_servers = _read_mcp_registry(registry_path, alerts)
    enabled_registry_count = sum(1 for item in registry_servers if item.get("enabled") is True)
    disabled_registry_count = sum(1 for item in registry_servers if item.get("enabled") is False)
    capability_groups = _resolve_capability_groups(global_root_path, alerts, mcp_items=registry_servers)
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
    (
        knowledge_base_overview,
        knowledge_projects,
        legacy_sources,
        knowledge_graph_meta,
        knowledge_graph_nodes,
        knowledge_graph_edges,
        observe_rollups,
        selected_scope,
    ) = _resolve_knowledge_bundle(
        global_root_path=global_root_path,
        vault_root=vault_root,
        registry_projects=registry_projects,
        available_workspaces=available_workspaces,
        workspace_path=workspace_path,
        project_memory_counts=project_memory_counts,
        attention_state=attention_state,
        lifecycle_phase=lifecycle_phase,
        runtime=runtime,
        project_memory_last_updated=project_memory_last_updated,
        last_handoff=last_handoff,
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
        project_update_log=project_update_log,
        knowledge_base_overview=knowledge_base_overview,
        knowledge_projects=knowledge_projects,
        legacy_sources=legacy_sources,
        knowledge_graph_meta=knowledge_graph_meta,
        knowledge_graph_nodes=knowledge_graph_nodes,
        knowledge_graph_edges=knowledge_graph_edges,
        observe_rollups=observe_rollups,
        capability_groups=capability_groups,
        selected_scope=selected_scope,
        includes_project_memory_details=include_project_memory_details,
        includes_question_profile_content=include_question_profile_content,
        project_memory_counts=project_memory_counts,
        project_memory_records=project_memory_records,
        project_memory_last_updated=project_memory_last_updated,
        sync_audit_source=sync_audit_source,
        current_task_health=current_task_health,
        attention_state=attention_state,
    )
