#!/usr/bin/env python3

from __future__ import annotations

import argparse
import hashlib
import json
import re
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path
import sys
from typing import Any

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from dashboard_data import (  # noqa: E402
    PROJECT_MEMORY_LABELS,
    ProjectMemoryRecord,
    _normalize_path,
    _parse_timestamp,
    _read_ndjson,
    _read_project_registry,
    build_state,
    resolve_global_root,
)

DEFAULT_VAULT_ROOT = Path.home() / "Library" / "Mobile Documents" / "iCloud~md~obsidian" / "Documents" / "Obsidian Memory"
DEFAULT_RAW_CHAT_DIR = "00 Raw Sources/Agent Chats"
CANONICAL_TOP_LEVELS = [
    "00 Raw Sources",
    "10 Wiki",
    "20 Queries and Reports",
    "90 System",
]
PROJECT_PAGE_TITLES = [
    "Overview",
    "Current Status",
    "Architecture",
    "Decisions",
    "Open Questions",
    "Sources",
]
SEMANTIC_TOKEN_PATTERN = re.compile(r"[A-Za-z][A-Za-z0-9_-]{2,}")
WIKI_LINK_PATTERN = re.compile(r"\[\[([^\]|#]+)(?:#[^\]|]+)?(?:\|[^\]]+)?\]\]")
SEMANTIC_STOPWORDS = {
    "about",
    "after",
    "again",
    "also",
    "been",
    "build",
    "cache",
    "current",
    "data",
    "edge",
    "from",
    "into",
    "just",
    "more",
    "node",
    "only",
    "page",
    "project",
    "scope",
    "should",
    "source",
    "status",
    "that",
    "their",
    "there",
    "these",
    "this",
    "through",
    "update",
    "wiki",
    "with",
    "your",
}


def _now_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def _write(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content.rstrip() + "\n", encoding="utf-8")


def _slugify(value: str) -> str:
    cleaned = re.sub(r"[^a-z0-9]+", "-", value.strip().lower())
    return cleaned.strip("-") or "workspace"


def _stable_slug(name: str, workspace: str, used: set[str]) -> str:
    base = _slugify(name or Path(workspace).name)
    if base not in used:
        used.add(base)
        return base
    digest = hashlib.sha1(workspace.encode("utf-8")).hexdigest()[:6]
    slug = f"{base}-{digest}"
    used.add(slug)
    return slug


def _safe_read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        try:
            return path.read_text(encoding="utf-8", errors="ignore")
        except OSError:
            return ""
    except OSError:
        return ""


def _read_json_file(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {}
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return {}
    return payload if isinstance(payload, dict) else {}


def _extract_keywords(text: str, *, limit: int = 8) -> list[str]:
    counts: dict[str, int] = defaultdict(int)
    for token in SEMANTIC_TOKEN_PATTERN.findall(text):
        lowered = token.lower()
        if len(lowered) < 3 or lowered in SEMANTIC_STOPWORDS:
            continue
        counts[lowered] += 1
    ranked = sorted(counts.items(), key=lambda item: (-item[1], item[0]))
    return [token for token, _ in ranked[:limit]]


def _normalize_semantic_label(value: Any) -> str:
    if not isinstance(value, str):
        return ""
    compact = re.sub(r"\s+", " ", value).strip()
    return compact[:72]


def _normalize_hint_slug(value: str, slug_lookup: dict[str, str]) -> str:
    direct = slug_lookup.get(value.lower())
    if direct:
        return direct
    return _slugify(value)


def _semantic_cache_index(vault_root: Path, slug_lookup: dict[str, str]) -> dict[str, dict[str, list[str]]]:
    semantic_index: dict[str, dict[str, list[str]]] = defaultdict(lambda: {"keywords": [], "entities": []})
    source_hint_map: dict[str, list[str]] = {}

    normalized_sources = _read_json_file(vault_root / "90 System" / "normalized-sources-manifest.json")
    for item in normalized_sources.get("items", []):
        source_id = str(item.get("source_id") or "")
        if not source_id:
            continue
        hints = [
            _normalize_hint_slug(str(hint), slug_lookup)
            for hint in item.get("wiki_elements", {}).get("project_hints", [])
            if str(hint).strip()
        ]
        if hints:
            source_hint_map[source_id] = sorted(set(hints))

    semantic_root = vault_root / "90 System" / "semantic-cache"
    cache_payloads: list[tuple[str, Any]] = []
    for file_name in ("source-keywords.json", "source-entities.json"):
        path = semantic_root / file_name
        if not path.exists():
            continue
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError):
            continue
        cache_payloads.append((file_name, payload))

    metadata_path = vault_root / "90 System" / "semantic_metadata.json"
    if metadata_path.exists():
        try:
            payload = json.loads(metadata_path.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError):
            payload = {}
        if isinstance(payload, dict):
            cache_payloads.append(("semantic_metadata.json", payload))

    def add_value(slug: str, field: str, raw_value: Any) -> None:
        label = _normalize_semantic_label(raw_value)
        if label:
            semantic_index[slug][field].append(label)

    def walk(value: Any, *, inferred_slug: str | None = None, source_id: str | None = None, field: str) -> None:
        local_slug = inferred_slug
        local_source_id = source_id
        if isinstance(value, dict):
            if not local_source_id:
                maybe_source = str(value.get("source_id") or value.get("source") or "").strip()
                if maybe_source:
                    local_source_id = maybe_source
            if not local_slug:
                project_hint = str(value.get("project") or value.get("project_hint") or value.get("workspace") or "").strip()
                if project_hint:
                    local_slug = _normalize_hint_slug(project_hint, slug_lookup)
            if local_source_id and not local_slug:
                hints = source_hint_map.get(local_source_id, [])
                if hints:
                    local_slug = hints[0]
            for key in ("keyword", "term", "label", "name", "entity"):
                if key in value and local_slug:
                    add_value(local_slug, field, value.get(key))
            for child in value.values():
                walk(child, inferred_slug=local_slug, source_id=local_source_id, field=field)
            return
        if isinstance(value, list):
            for child in value:
                walk(child, inferred_slug=local_slug, source_id=local_source_id, field=field)
            return
        if local_slug and isinstance(value, str):
            add_value(local_slug, field, value)

    for file_name, payload in cache_payloads:
        field = "entities" if "entities" in file_name else "keywords"
        walk(payload, field=field)

    deduped: dict[str, dict[str, list[str]]] = {}
    for slug, values in semantic_index.items():
        deduped[slug] = {
            "keywords": sorted(set(values["keywords"]))[:40],
            "entities": sorted(set(values["entities"]))[:40],
        }
    return deduped


def _frontmatter(*, title: str, tags: list[str], workspace: str, generated_at: str) -> list[str]:
    return [
        "---",
        f'title: "{title.replace(chr(34), chr(39))}"',
        "generated_by: shared-fabric-dashboard",
        f'workspace: "{workspace.replace(chr(34), chr(39))}"',
        f'generated_at: "{generated_at}"',
        f"tags: [{', '.join(tags)}]",
        "---",
        "",
    ]


def _group_by_lane(records: list[ProjectMemoryRecord]) -> dict[str, list[ProjectMemoryRecord]]:
    grouped: dict[str, list[ProjectMemoryRecord]] = defaultdict(list)
    for record in records:
        grouped[record.lane].append(record)
    return grouped


def _record_bullets(records: list[ProjectMemoryRecord], *, include_details: bool, limit: int = 12) -> list[str]:
    lines: list[str] = []
    for record in list(records)[-limit:]:
        stamp = record.timestamp or "n/a"
        lines.append(f"- `{stamp}` {record.summary}")
        if include_details and record.details.strip():
            excerpt = " ".join(line.strip() for line in record.details.strip().splitlines()[:3] if line.strip())
            if excerpt:
                lines.append(f"  - {excerpt}")
    return lines or ["- None recorded yet."]


def _artifact_lines(records: list[ProjectMemoryRecord]) -> list[str]:
    seen: set[str] = set()
    lines: list[str] = []
    for record in records:
        for artifact in record.artifacts:
            cleaned = artifact.strip()
            if not cleaned or cleaned in seen:
                continue
            seen.add(cleaned)
            lines.append(f"- `{cleaned}`")
    return lines or ["- No explicit artifacts were attached to current project memory."]


def _wiki_link(relative_path: str, label: str) -> str:
    return f"[[{relative_path}|{label}]]"


def _project_wiki_link(slug: str, file_name: str, label: str) -> str:
    return _wiki_link(f"10 Wiki/Projects/{slug}/{file_name}", label)


def _project_overview_page(*, state, slug: str, generated_at: str) -> str:
    zh = state.project_update_log.preferred_language == "zh"
    lines = _frontmatter(
        title=f"{state.project_name} Overview",
        tags=["shared-fabric", "wiki", "project-overview"],
        workspace=state.workspace,
        generated_at=generated_at,
    )
    status_link = _project_wiki_link(slug, "Current Status.md", "Current Status")
    architecture_link = _project_wiki_link(slug, "Architecture.md", "Architecture")
    decisions_link = _project_wiki_link(slug, "Decisions.md", "Decisions")
    loops_link = _project_wiki_link(slug, "Open Questions.md", "Open Questions")
    sources_link = _project_wiki_link(slug, "Sources.md", "Sources")
    if zh:
        lines.extend(
            [
                f"# {state.project_name} 概览",
                "",
                f"- 工作区：`{state.workspace}`",
                f"- Runtime：`{state.runtime}`",
                f"- 当前任务：`{state.task_id or '暂无'}`",
                f"- 生命周期：`{state.lifecycle_phase}`",
                f"- 当前焦点：{state.last_handoff}",
                "",
                "## 核心页面",
                f"- {status_link}",
                f"- {architecture_link}",
                f"- {decisions_link}",
                f"- {loops_link}",
                f"- {sources_link}",
                "",
                "## 当前摘要",
                f"- {state.project_update_log.summary}",
            ]
        )
    else:
        lines.extend(
            [
                f"# {state.project_name} Overview",
                "",
                f"- Workspace: `{state.workspace}`",
                f"- Runtime: `{state.runtime}`",
                f"- Current task: `{state.task_id or 'n/a'}`",
                f"- Lifecycle: `{state.lifecycle_phase}`",
                f"- Current focus: {state.last_handoff}",
                "",
                "## Core Pages",
                f"- {status_link}",
                f"- {architecture_link}",
                f"- {decisions_link}",
                f"- {loops_link}",
                f"- {sources_link}",
                "",
                "## Summary",
                f"- {state.project_update_log.summary}",
            ]
        )
    return "\n".join(lines)


def _current_status_page(*, state, generated_at: str) -> str:
    title = "Current Status" if state.project_update_log.preferred_language != "zh" else "当前状态"
    lines = _frontmatter(
        title=f"{state.project_name} {title}",
        tags=["shared-fabric", "wiki", "project-status"],
        workspace=state.workspace,
        generated_at=generated_at,
    )
    lines.append(state.project_update_log.content or state.project_update_log.summary or "No status report is available yet.")
    return "\n".join(lines)


def _architecture_page(*, state, generated_at: str) -> str:
    by_lane = _group_by_lane(state.project_memory_records)
    zh = state.project_update_log.preferred_language == "zh"
    lines = _frontmatter(
        title=f"{state.project_name} Architecture",
        tags=["shared-fabric", "wiki", "project-architecture"],
        workspace=state.workspace,
        generated_at=generated_at,
    )
    if zh:
        lines.extend(
            [
                f"# {state.project_name} 架构与运行脉络",
                "",
                "## 当前焦点",
                f"- {state.last_handoff}",
                "",
                "## 关键决策",
                *_record_bullets(by_lane.get("decision_log", []), include_details=False, limit=8),
                "",
                "## 过程记忆与实现脉络",
                *_record_bullets(by_lane.get("mempalace_records", []), include_details=True, limit=8),
                "",
                "## 近期学习",
                *_record_bullets(by_lane.get("promoted_learnings", []), include_details=True, limit=6),
                "",
                "## 未决问题",
                *_record_bullets(by_lane.get("open_loops", []), include_details=False, limit=8),
                "",
                "## 证据与来源",
                *_artifact_lines(state.project_memory_records),
            ]
        )
    else:
        lines.extend(
            [
                f"# {state.project_name} Architecture and Operating Narrative",
                "",
                "## Current Focus",
                f"- {state.last_handoff}",
                "",
                "## Key Decisions",
                *_record_bullets(by_lane.get("decision_log", []), include_details=False, limit=8),
                "",
                "## Process Memory and Implementation Trail",
                *_record_bullets(by_lane.get("mempalace_records", []), include_details=True, limit=8),
                "",
                "## Recent Learnings",
                *_record_bullets(by_lane.get("promoted_learnings", []), include_details=True, limit=6),
                "",
                "## Open Questions",
                *_record_bullets(by_lane.get("open_loops", []), include_details=False, limit=8),
                "",
                "## Evidence and Sources",
                *_artifact_lines(state.project_memory_records),
            ]
        )
    return "\n".join(lines)


def _lane_page(*, state, lane: str, title: str, generated_at: str) -> str:
    records = _group_by_lane(state.project_memory_records).get(lane, [])
    zh = state.project_update_log.preferred_language == "zh"
    lines = _frontmatter(
        title=f"{state.project_name} {title}",
        tags=["shared-fabric", "wiki", lane],
        workspace=state.workspace,
        generated_at=generated_at,
    )
    heading = {
        ("decision_log", True): "决策",
        ("open_loops", True): "待处理与开放问题",
        ("sources", True): "来源与证据",
    }.get((lane, zh), title)
    lines.extend([f"# {state.project_name} {heading}", ""])
    if lane == "sources":
        lines.extend(_artifact_lines(state.project_memory_records))
    else:
        lines.extend(_record_bullets(records, include_details=True, limit=24))
    return "\n".join(lines)


def _schema_page(*, workspace: str, generated_at: str, raw_chat_dir: str) -> str:
    lines = _frontmatter(
        title="Obsidian Wiki Schema",
        tags=["shared-fabric", "wiki", "schema"],
        workspace=workspace,
        generated_at=generated_at,
    )
    lines.extend(
        [
            "# Obsidian Wiki Schema",
            "",
            "## Purpose",
            "- Keep raw sources immutable.",
            "- Maintain project and concept pages as the durable synthesis layer.",
            "- Regenerate navigation, manifests, reports, and graph data deterministically from Shared Fabric state.",
            "",
            "## Canonical Layout",
            "- `00 Raw Sources/Agent Chats/`",
            "- `00 Raw Sources/External Imports/`",
            "- `00 Raw Sources/Shared Fabric Snapshots/`",
            "- `10 Wiki/Projects/<project>/`",
            "- `20 Queries and Reports/`",
            "- `90 System/`",
            "",
            "## Current Raw Chat Feed",
            f"- Configured raw chat export directory: `{raw_chat_dir}`",
            "",
            "## Maintenance Rules",
            "- Shared Fabric remains the canonical system of record for decisions, handoffs, loops, learnings, receipts, and distilled user-question profiles.",
            "- Obsidian wiki pages are generated views that should be overwritten or refreshed deterministically, not manually forked into parallel truths.",
            "- `knowledge-base-manifest.json` inventories vault status without auto-migrating legacy structures.",
            "- `graph.json` is the app-readable navigation graph for vault-wide focus and project highlighting.",
            "- `migration-report.md` should guide normalization work without silently rewriting user folders.",
        ]
    )
    return "\n".join(lines)


def _discover_workspaces(global_root: Path) -> list[dict[str, str]]:
    receipts = _read_ndjson(global_root / "sync" / "receipts.ndjson")
    handoffs = _read_ndjson(global_root / "memory" / "handoffs.ndjson")
    learning = _read_ndjson(global_root / "sync" / "learning_receipts.ndjson")
    registry_projects = _read_project_registry(global_root / "projects" / "registry.yaml")
    registry_by_path = {
        _normalize_path(project.get("path")): project
        for project in registry_projects
        if _normalize_path(project.get("path"))
    }

    activity_by_path: dict[str, str] = {}
    for record in receipts + handoffs + learning:
        workspace_path = _normalize_path(record.get("workspace"))
        timestamp = str(record.get("timestamp") or "")
        if not workspace_path or not timestamp or not Path(workspace_path).exists():
            continue
        if workspace_path not in activity_by_path or _parse_timestamp(timestamp) > _parse_timestamp(activity_by_path[workspace_path]):
            activity_by_path[workspace_path] = timestamp

    candidates: list[dict[str, str]] = []
    seen: set[str] = set()
    for path, project in registry_by_path.items():
        if path in seen or not Path(path).exists():
            continue
        candidates.append(
            {
                "workspace": path,
                "name": project.get("name") or Path(path).name,
                "project_id": project.get("id") or _slugify(project.get("name") or Path(path).name),
                "source": "registry",
                "last_seen": activity_by_path.get(path, ""),
            }
        )
        seen.add(path)
    for path, timestamp in sorted(activity_by_path.items(), key=lambda item: _parse_timestamp(item[1]), reverse=True):
        if path in seen:
            continue
        candidates.append(
            {
                "workspace": path,
                "name": Path(path).name,
                "project_id": _slugify(Path(path).name),
                "source": "active",
                "last_seen": timestamp,
            }
        )
        seen.add(path)
    return candidates


def _build_project_state_payload(
    *,
    workspace: str,
    source: str,
    name: str,
    slug: str,
    global_root: Path,
    vault_root: Path,
    gemini_settings: str | Path | None,
) -> dict[str, Any]:
    state = build_state(
        workspace=workspace,
        global_root=global_root,
        gemini_settings=gemini_settings,
        snapshot_mode="full",
        vault_root=vault_root,
    )
    project_root = vault_root / "10 Wiki" / "Projects" / slug
    pages = [
        {"title": title, "path": str(project_root / f"{title}.md")}
        for title in PROJECT_PAGE_TITLES
    ]
    return {
        "state": state,
        "workspace": state.workspace,
        "name": name or state.project_name,
        "slug": slug,
        "source": source,
        "pages": pages,
        "page_count": len(pages),
    }


def _write_project_pages(project_root: Path, payload: dict[str, Any], generated_at: str) -> list[str]:
    state = payload["state"]
    slug = payload["slug"]
    page_payloads = {
        project_root / "Overview.md": _project_overview_page(state=state, slug=slug, generated_at=generated_at),
        project_root / "Current Status.md": _current_status_page(state=state, generated_at=generated_at),
        project_root / "Architecture.md": _architecture_page(state=state, generated_at=generated_at),
        project_root / "Decisions.md": _lane_page(state=state, lane="decision_log", title="Decisions", generated_at=generated_at),
        project_root / "Open Questions.md": _lane_page(state=state, lane="open_loops", title="Open Questions", generated_at=generated_at),
        project_root / "Sources.md": _lane_page(state=state, lane="sources", title="Sources", generated_at=generated_at),
    }
    written: list[str] = []
    for path, content in page_payloads.items():
        _write(path, content)
        written.append(str(path))
    return written


def _canonical_directories(vault_root: Path) -> list[Path]:
    return [
        vault_root / "00 Raw Sources" / "Agent Chats",
        vault_root / "00 Raw Sources" / "External Imports" / "NotebookLM",
        vault_root / "00 Raw Sources" / "External Imports" / "Notion",
        vault_root / "00 Raw Sources" / "External Imports" / "Web Clipper",
        vault_root / "00 Raw Sources" / "Shared Fabric Snapshots" / "Update Logs",
        vault_root / "00 Raw Sources" / "Shared Fabric Snapshots" / "Handoffs",
        vault_root / "00 Raw Sources" / "Shared Fabric Snapshots" / "Memory Receipts",
        vault_root / "10 Wiki" / "Projects",
        vault_root / "20 Queries and Reports",
        vault_root / "90 System",
    ]


def _load_normalized_sources_manifest(vault_root: Path) -> dict[str, Any]:
    manifest_path = vault_root / "90 System" / "normalized-sources-manifest.json"
    if not manifest_path.exists():
        return {"source_families": [], "items": [], "summary": {"family_count": 0, "item_count": 0}}
    try:
        payload = json.loads(manifest_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return {"source_families": [], "items": [], "summary": {"family_count": 0, "item_count": 0}}
    payload.setdefault("source_families", [])
    payload.setdefault("items", [])
    payload.setdefault("summary", {"family_count": len(payload["source_families"]), "item_count": len(payload["items"])})
    return payload


def _write_source_library_pages(vault_root: Path, normalized_sources: dict[str, Any], generated_at: str) -> list[str]:
    source_root = vault_root / "10 Wiki" / "Sources"
    source_root.mkdir(parents=True, exist_ok=True)
    written: list[str] = []

    families = normalized_sources.get("source_families", [])
    overview_lines = [
        "---",
        'title: "Source Library Overview"',
        "generated_by: shared-fabric-dashboard",
        f'generated_at: "{generated_at}"',
        "tags: [shared-fabric, wiki, sources]",
        "---",
        "",
        "# Source Library Overview",
        "",
        "## Families",
    ]
    if not families:
        overview_lines.append("- No normalized source families are available yet. Run Process Sources first.")
    else:
        for family in families:
            label = str(family.get("label") or family.get("family") or "Source Family")
            overview_lines.append(f"- [[10 Wiki/Sources/{label}.md|{label}]] · `{int(family.get('item_count') or 0)}` items")
    overview_lines.extend(["", "## Processing Summary", f"- Last build: `{generated_at}`"])
    overview_path = source_root / "Overview.md"
    _write(overview_path, "\n".join(overview_lines))
    written.append(str(overview_path))

    items_by_family: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for item in normalized_sources.get("items", []):
        family_key = str(item.get("family") or "")
        if family_key:
            items_by_family[family_key].append(item)

    for family in families:
        family_key = str(family.get("family") or "")
        label = str(family.get("label") or family_key or "Source Family")
        items = items_by_family.get(family_key, [])
        lines = [
            "---",
            f'title: "{label.replace(chr(34), chr(39))}"',
            "generated_by: shared-fabric-dashboard",
            f'generated_at: "{generated_at}"',
            "tags: [shared-fabric, wiki, sources]",
            "---",
            "",
            f"# {label}",
            "",
            f"- Raw root: `{family.get('target_root', '')}`",
            f"- Source roots: `{len(family.get('source_roots', []))}`",
            f"- Items: `{int(family.get('item_count') or 0)}`",
            "",
            "## Entries",
        ]
        if not items:
            lines.append("- No normalized entries yet.")
        else:
            for item in items[:200]:
                lines.append(f"- **{item.get('title', 'Untitled')}**")
                summary = str(item.get("summary") or "").strip()
                if summary:
                    lines.append(f"  - {summary}")
                lines.append(f"  - Raw: `{item.get('raw_content_path', '')}`")
                project_hints = item.get("wiki_elements", {}).get("project_hints", [])
                if project_hints:
                    lines.append(f"  - Project hints: {', '.join(project_hints)}")
        page_path = source_root / f"{label}.md"
        _write(page_path, "\n".join(lines))
        written.append(str(page_path))

    return written


def _classify_legacy_top_level(path: Path) -> str:
    name = path.name.lower()
    if "notion" in name:
        return "external-notion"
    if "notebook" in name:
        return "external-notebooklm"
    if "agent" in name and "chat" in name:
        return "legacy-agent-history"
    return "legacy-top-level"


def _inventory_legacy_sources(vault_root: Path) -> list[dict[str, str]]:
    entries: list[dict[str, str]] = []
    for path in sorted(vault_root.iterdir(), key=lambda item: item.name.lower()):
        if path.name in CANONICAL_TOP_LEVELS:
            continue
        entries.append(
            {
                "name": path.name,
                "path": str(path),
                "classification": _classify_legacy_top_level(path),
                "status": "legacy",
            }
        )
    return entries


def _migration_report(
    *,
    workspace: str,
    generated_at: str,
    project_payloads: list[dict[str, Any]],
    legacy_sources: list[dict[str, str]],
) -> str:
    lines = _frontmatter(
        title="Vault Migration Report",
        tags=["shared-fabric", "wiki", "migration-report"],
        workspace=workspace,
        generated_at=generated_at,
    )
    lines.extend(
        [
            "# Vault Migration Report",
            "",
            "## Policy",
            "- This normalization run is conservative.",
            "- Canonical directories were created or refreshed.",
            "- Existing legacy folders were inventoried, not moved.",
            "",
            "## Known Projects",
        ]
    )
    if not project_payloads:
        lines.append("- No known projects were discovered.")
    else:
        for payload in project_payloads:
            lines.append(
                f"- `{payload['name']}` · source={payload['source']} · workspace=`{payload['workspace']}` · pages={payload['page_count']}"
            )
    lines.extend(["", "## Legacy Sources"])
    if not legacy_sources:
        lines.append("- No non-canonical top-level legacy folders were found.")
    else:
        for source in legacy_sources:
            lines.append(
                f"- `{source['name']}` · {source['classification']} · `{source['path']}`"
            )
    lines.extend(
        [
            "",
            "## Recommended Next Actions",
            "- Keep raw imports in `00 Raw Sources/`.",
            "- Use `Build All Project Wikis` after major sync waves.",
            "- Migrate legacy top-level folders manually once their target canonical destinations are confirmed.",
        ]
    )
    return "\n".join(lines)


def _build_graph_payload(
    *,
    vault_root: Path,
    generated_at: str,
    project_payloads: list[dict[str, Any]],
    legacy_sources: list[dict[str, str]],
    normalized_sources: dict[str, Any],
) -> dict[str, Any]:
    nodes: list[dict[str, Any]] = [
        {
            "id": "vault:root",
            "label": vault_root.name,
            "kind": "vault",
            "path": str(vault_root),
        }
    ]
    edges: list[dict[str, Any]] = []
    slug_lookup = {payload["name"].lower(): payload["slug"] for payload in project_payloads if payload.get("name")}
    semantic_cache = _semantic_cache_index(vault_root, slug_lookup)
    keyword_nodes: dict[str, dict[str, Any]] = {}
    entity_nodes: dict[str, dict[str, Any]] = {}
    for payload in project_payloads:
        state = payload["state"]
        project_node_id = f"project:{payload['slug']}"
        nodes.append(
            {
                "id": project_node_id,
                "label": payload["name"],
                "kind": "project",
                "path": payload["workspace"],
                "scope": payload["slug"],
                "workspace": payload["workspace"],
                "status": state.lifecycle_phase,
            }
        )
        edges.append({"source": "vault:root", "target": project_node_id, "kind": "contains"})
        for page in payload["pages"]:
            page_name = Path(page["path"]).stem
            page_slug = _slugify(page_name)
            if page_slug == "workspace":
                page_slug = f"page-{hashlib.sha1(page_name.encode('utf-8')).hexdigest()[:8]}"
            page_id = f"page:{payload['slug']}:{page_slug}"
            nodes.append(
                {
                    "id": page_id,
                    "label": page_name,
                    "kind": "page",
                    "path": page["path"],
                    "scope": payload["slug"],
                    "workspace": payload["workspace"],
                }
            )
            edges.append({"source": project_node_id, "target": page_id, "kind": "page"})
            page_text = _safe_read_text(Path(page["path"]))
            extracted = _extract_keywords(f"{page_name}\n{page_text}", limit=9)
            for keyword in extracted:
                keyword_id = f"keyword:{payload['slug']}:{_slugify(keyword)}"
                if keyword_id not in keyword_nodes:
                    keyword_nodes[keyword_id] = {
                        "id": keyword_id,
                        "label": keyword,
                        "kind": "keyword",
                        "path": "",
                        "scope": payload["slug"],
                        "workspace": payload["workspace"],
                        "status": "",
                    }
                edges.append({"source": page_id, "target": keyword_id, "kind": "semantic"})
            linked_pages = {
                _slugify(match)
                for match in WIKI_LINK_PATTERN.findall(page_text)
                if match.strip()
            }
            for linked in list(linked_pages)[:8]:
                if linked == _slugify(page_name):
                    continue
                candidate_id = f"page:{payload['slug']}:{linked}"
                edges.append({"source": page_id, "target": candidate_id, "kind": "references"})
        source_page = f"page:{payload['slug']}:sources"
        workspace_node = f"workspace:{payload['slug']}"
        nodes.append(
            {
                "id": workspace_node,
                "label": Path(payload["workspace"]).name,
                "kind": "workspace",
                "path": payload["workspace"],
                "scope": payload["slug"],
                "workspace": payload["workspace"],
            }
        )
        edges.append({"source": project_node_id, "target": workspace_node, "kind": "workspace"})
        edges.append({"source": source_page, "target": workspace_node, "kind": "documents"})
        cache_payload = semantic_cache.get(payload["slug"], {})
        for keyword in cache_payload.get("keywords", [])[:28]:
            keyword_id = f"keyword:{payload['slug']}:{_slugify(keyword)}"
            if keyword_id not in keyword_nodes:
                keyword_nodes[keyword_id] = {
                    "id": keyword_id,
                    "label": keyword,
                    "kind": "keyword",
                    "path": "",
                    "scope": payload["slug"],
                    "workspace": payload["workspace"],
                    "status": "",
                }
            edges.append({"source": project_node_id, "target": keyword_id, "kind": "semantic-cache"})
        for entity in cache_payload.get("entities", [])[:28]:
            entity_id = f"entity:{payload['slug']}:{_slugify(entity)}"
            if entity_id not in entity_nodes:
                entity_nodes[entity_id] = {
                    "id": entity_id,
                    "label": entity,
                    "kind": "entity",
                    "path": "",
                    "scope": payload["slug"],
                    "workspace": payload["workspace"],
                    "status": "",
                }
            edges.append({"source": project_node_id, "target": entity_id, "kind": "entity"})
    for source in legacy_sources:
        node_id = f"legacy:{_slugify(source['name'])}"
        nodes.append(
            {
                "id": node_id,
                "label": source["name"],
                "kind": "legacy",
                "path": source["path"],
            }
        )
        edges.append({"source": "vault:root", "target": node_id, "kind": "legacy"})
    if normalized_sources.get("source_families"):
        source_root_id = "source-library:root"
        nodes.append(
            {
                "id": source_root_id,
                "label": "Sources",
                "kind": "source-library",
                "path": str(vault_root / "10 Wiki" / "Sources"),
            }
        )
        edges.append({"source": "vault:root", "target": source_root_id, "kind": "source-library"})
        for family in normalized_sources["source_families"]:
            family_id = f"source-family:{family['family']}"
            nodes.append(
                {
                    "id": family_id,
                    "label": family["label"],
                    "kind": "source-family",
                    "path": str(vault_root / "10 Wiki" / "Sources" / f"{family['label']}.md"),
                    "item_count": family.get("item_count", 0),
                }
            )
            edges.append({"source": source_root_id, "target": family_id, "kind": "source-family"})
            for item in family.get("items", [])[:80]:
                item_id = f"source-item:{item['source_id']}"
                nodes.append(
                    {
                        "id": item_id,
                        "label": item["title"],
                        "kind": "source-item",
                        "path": item["raw_content_path"],
                        "family": family["family"],
                    }
                )
                edges.append({"source": family_id, "target": item_id, "kind": "source-item"})
                for project_hint in item.get("wiki_elements", {}).get("project_hints", []):
                    project_id = f"project:{_slugify(project_hint)}"
                    edges.append({"source": item_id, "target": project_id, "kind": "mentions"})
    nodes.extend(keyword_nodes.values())
    nodes.extend(entity_nodes.values())
    deduped_edges: list[dict[str, Any]] = []
    seen_edges: set[tuple[str, str, str]] = set()
    node_ids = {item["id"] for item in nodes}
    for edge in edges:
        source = str(edge.get("source") or "")
        target = str(edge.get("target") or "")
        kind = str(edge.get("kind") or "")
        if not source or not target or source not in node_ids or target not in node_ids:
            continue
        key = (source, target, kind)
        if key in seen_edges:
            continue
        seen_edges.add(key)
        deduped_edges.append({"source": source, "target": target, "kind": kind})
    return {
        "generated_at": generated_at,
        "vault_root": str(vault_root),
        "nodes": nodes,
        "edges": deduped_edges,
        "node_count": len(nodes),
        "edge_count": len(deduped_edges),
    }


def _manifest_payload(
    *,
    generated_at: str,
    vault_root: Path,
    raw_chat_dir: str,
    project_payloads: list[dict[str, Any]],
    legacy_sources: list[dict[str, str]],
    graph_payload: dict[str, Any],
    normalized_sources: dict[str, Any],
) -> dict[str, Any]:
    wiki_page_count = sum(payload["page_count"] for payload in project_payloads)
    active_workspace_count = sum(1 for payload in project_payloads if payload["source"] == "active")
    registered_project_count = sum(1 for payload in project_payloads if payload["source"] == "registry")
    return {
        "generated_at": generated_at,
        "vault_root": str(vault_root),
        "raw_chat_dir": raw_chat_dir,
        "canonical_top_levels": CANONICAL_TOP_LEVELS,
        "projects": [
            {
                "name": payload["name"],
                "slug": payload["slug"],
                "workspace": payload["workspace"],
                "source": payload["source"],
                "page_count": payload["page_count"],
                "pages": payload["pages"],
                "lifecycle_phase": payload["state"].lifecycle_phase,
                "runtime": payload["state"].runtime,
                "focus": payload["state"].last_handoff,
                "task_id": payload["state"].task_id,
                "last_updated": payload["state"].project_memory_last_updated,
            }
            for payload in project_payloads
        ],
        "legacy_sources": legacy_sources,
        "summary": {
            "project_count": len(project_payloads),
            "registered_project_count": registered_project_count,
            "active_workspace_count": active_workspace_count,
            "legacy_source_count": len(legacy_sources),
            "normalized_source_family_count": normalized_sources.get("summary", {}).get("family_count", 0),
            "normalized_source_item_count": normalized_sources.get("summary", {}).get("item_count", 0),
            "wiki_page_count": wiki_page_count,
            "graph_node_count": graph_payload["node_count"],
            "graph_edge_count": graph_payload["edge_count"],
        },
        "normalized_sources": {
            "family_count": normalized_sources.get("summary", {}).get("family_count", 0),
            "item_count": normalized_sources.get("summary", {}).get("item_count", 0),
            "families": [
                {
                    "family": family.get("family", ""),
                    "label": family.get("label", ""),
                    "item_count": family.get("item_count", 0),
                    "target_root": family.get("target_root", ""),
                }
                for family in normalized_sources.get("source_families", [])
            ],
        },
    }


def _index_page(*, workspace: str, generated_at: str, project_payloads: list[dict[str, Any]], normalized_sources: dict[str, Any]) -> str:
    lines = _frontmatter(
        title="Shared Fabric Wiki Index",
        tags=["shared-fabric", "wiki", "index"],
        workspace=workspace,
        generated_at=generated_at,
    )
    lines.extend(
        [
            "# Shared Fabric Wiki Index",
            "",
            "## System",
            "- [[90 System/obsidian-wiki-schema.md|Schema]]",
            "- [[90 System/log.md|Log]]",
            "- [[90 System/migration-report.md|Migration Report]]",
            "",
            "## Source Library",
            "- [[10 Wiki/Sources/Overview.md|Sources Overview]]",
        ]
    )
    for family in normalized_sources.get("source_families", []):
        lines.append(f"- [[10 Wiki/Sources/{family['label']}.md|{family['label']}]]")
    lines.extend(
        [
            "",
            "## Projects",
        ]
    )
    if not project_payloads:
        lines.append("- No project wiki directories have been generated yet.")
    else:
        for payload in project_payloads:
            slug = payload["slug"]
            overview_label = f"{payload['name']} Overview"
            lines.append(f"- {_project_wiki_link(slug, 'Overview.md', overview_label)}")
            lines.append(f"  - {_project_wiki_link(slug, 'Current Status.md', 'Current Status')}")
            lines.append(f"  - {_project_wiki_link(slug, 'Architecture.md', 'Architecture')}")
    return "\n".join(lines)


def _log_page(*, workspace: str, generated_at: str, mode: str, project_payloads: list[dict[str, Any]], legacy_sources: list[dict[str, str]]) -> str:
    lines = _frontmatter(
        title="Shared Fabric Wiki Log",
        tags=["shared-fabric", "wiki", "log"],
        workspace=workspace,
        generated_at=generated_at,
    )
    lines.extend(
        [
            "# Shared Fabric Wiki Log",
            "",
            f"## [{generated_at}] {mode}",
            "",
            f"- Project pages refreshed: `{len(project_payloads)}`",
            f"- Legacy top-level entries inventoried: `{len(legacy_sources)}`",
            "",
            "### Project Rounds",
        ]
    )
    if not project_payloads:
        lines.append("- No project states were compiled.")
    else:
        for payload in project_payloads:
            state = payload["state"]
            lines.append(
                f"- `{payload['name']}` · `{state.runtime or 'n/a'}` · `{state.lifecycle_phase}` · `{state.task_id or 'n/a'}`"
            )
    return "\n".join(lines)


def _ensure_raw_source_readme(*, vault_root: Path, workspace: str, generated_at: str, raw_chat_dir: str) -> str:
    raw_sources_readme = vault_root / "00 Raw Sources" / "Agent Chats" / "README.md"
    _write(
        raw_sources_readme,
        "\n".join(
            _frontmatter(
                title="Agent Chats Raw Sources",
                tags=["shared-fabric", "wiki", "raw-sources"],
                workspace=workspace,
                generated_at=generated_at,
            )
            + [
                "# Agent Chats Raw Sources",
                "",
                "- This directory is the canonical raw-source target for exported Codex and Gemini chat transcripts.",
                f"- Current configured export path in the app may still point to: `{raw_chat_dir}`",
                "- Transcript files are inputs to synthesis, not the final wiki layer.",
            ]
        ),
    )
    return str(raw_sources_readme)


def export_obsidian_wiki(
    *,
    workspace: str | Path | None,
    global_root: str | Path | None,
    vault_root: str | Path,
    gemini_settings: str | Path | None = None,
    raw_chat_dir: str = DEFAULT_RAW_CHAT_DIR,
    mode: str = "build-workspace",
) -> dict[str, object]:
    normalized_mode = mode.strip().lower()
    if normalized_mode == "build":
        normalized_mode = "build-workspace"
    elif normalized_mode == "both":
        normalized_mode = "build-workspace"
    elif normalized_mode not in {"normalize", "build-workspace", "build-all"}:
        raise ValueError(f"unsupported mode: {mode}")

    global_root_path = resolve_global_root(global_root)
    vault_root_path = Path(vault_root).expanduser()
    if not vault_root_path.exists():
        raise FileNotFoundError(f"vault root does not exist: {vault_root_path}")

    generated_at = _now_iso()
    created_directories: list[str] = []
    written_files: list[str] = []

    def ensure_dir(path: Path) -> None:
        path.mkdir(parents=True, exist_ok=True)
        created_directories.append(str(path))

    for directory in _canonical_directories(vault_root_path):
        ensure_dir(directory)

    current_workspace = _normalize_path(workspace)
    known_workspaces = _discover_workspaces(global_root_path)
    if current_workspace and current_workspace not in [entry["workspace"] for entry in known_workspaces]:
        known_workspaces.insert(
            0,
            {
                "workspace": current_workspace,
                "name": Path(current_workspace).name,
                "project_id": _slugify(Path(current_workspace).name),
                "source": "manual",
                "last_seen": "",
            },
        )

    used_slugs: set[str] = set()
    if normalized_mode == "build-all":
        target_workspaces = known_workspaces
    elif normalized_mode == "build-workspace":
        if not current_workspace:
            raise ValueError("workspace is required for build-workspace mode")
        target_workspaces = [
            {
                "workspace": current_workspace,
                "name": Path(current_workspace).name,
                "project_id": _slugify(Path(current_workspace).name),
                "source": "manual",
                "last_seen": "",
            }
        ]
    else:
        target_workspaces = []

    project_payloads: list[dict[str, Any]] = []
    for candidate in target_workspaces:
        workspace_path = candidate["workspace"]
        if not workspace_path:
            continue
        slug = _stable_slug(candidate["name"], workspace_path, used_slugs)
        payload = _build_project_state_payload(
            workspace=workspace_path,
            source=candidate["source"],
            name=candidate["name"],
            slug=slug,
            global_root=global_root_path,
            vault_root=vault_root_path,
            gemini_settings=gemini_settings,
        )
        project_payloads.append(payload)

    project_payloads.sort(key=lambda item: item["name"].lower())

    legacy_sources = _inventory_legacy_sources(vault_root_path)
    normalized_sources = _load_normalized_sources_manifest(vault_root_path)
    workspace_for_system = current_workspace or (project_payloads[0]["workspace"] if project_payloads else "")
    written_files.extend(_write_source_library_pages(vault_root_path, normalized_sources, generated_at))

    schema_path = vault_root_path / "90 System" / "obsidian-wiki-schema.md"
    _write(schema_path, _schema_page(workspace=workspace_for_system, generated_at=generated_at, raw_chat_dir=raw_chat_dir))
    written_files.append(str(schema_path))
    written_files.append(_ensure_raw_source_readme(vault_root=vault_root_path, workspace=workspace_for_system, generated_at=generated_at, raw_chat_dir=raw_chat_dir))

    if normalized_mode in {"build-workspace", "build-all"}:
        for payload in project_payloads:
            project_root = vault_root_path / "10 Wiki" / "Projects" / payload["slug"]
            ensure_dir(project_root)
            written_files.extend(_write_project_pages(project_root, payload, generated_at))

    graph_payload = _build_graph_payload(
        vault_root=vault_root_path,
        generated_at=generated_at,
        project_payloads=project_payloads,
        legacy_sources=legacy_sources,
        normalized_sources=normalized_sources,
    )
    manifest_payload = _manifest_payload(
        generated_at=generated_at,
        vault_root=vault_root_path,
        raw_chat_dir=raw_chat_dir,
        project_payloads=project_payloads,
        legacy_sources=legacy_sources,
        graph_payload=graph_payload,
        normalized_sources=normalized_sources,
    )

    index_path = vault_root_path / "90 System" / "index.md"
    _write(
        index_path,
        _index_page(
            workspace=workspace_for_system,
            generated_at=generated_at,
            project_payloads=project_payloads,
            normalized_sources=normalized_sources,
        ),
    )
    written_files.append(str(index_path))

    log_path = vault_root_path / "90 System" / "log.md"
    _write(log_path, _log_page(workspace=workspace_for_system, generated_at=generated_at, mode=normalized_mode, project_payloads=project_payloads, legacy_sources=legacy_sources))
    written_files.append(str(log_path))

    migration_path = vault_root_path / "90 System" / "migration-report.md"
    _write(
        migration_path,
        _migration_report(
            workspace=workspace_for_system,
            generated_at=generated_at,
            project_payloads=project_payloads,
            legacy_sources=legacy_sources,
        ),
    )
    written_files.append(str(migration_path))

    manifest_path = vault_root_path / "90 System" / "knowledge-base-manifest.json"
    manifest_path.write_text(json.dumps(manifest_payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    written_files.append(str(manifest_path))

    graph_path = vault_root_path / "90 System" / "graph.json"
    graph_path.write_text(json.dumps(graph_payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    written_files.append(str(graph_path))

    return {
        "workspace": workspace_for_system,
        "project_name": Path(workspace_for_system).name if workspace_for_system else "",
        "mode": normalized_mode,
        "vault_root": str(vault_root_path),
        "raw_chat_dir": raw_chat_dir,
        "projects_built": len(project_payloads),
        "legacy_source_count": len(legacy_sources),
        "graph_node_count": graph_payload["node_count"],
        "graph_edge_count": graph_payload["edge_count"],
        "directories_created": sorted(set(created_directories)),
        "files_written": written_files,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description="Normalize an Obsidian vault and build vault-wide Shared Fabric wiki artifacts.")
    parser.add_argument("--workspace", default=None)
    parser.add_argument("--global-root", default=None)
    parser.add_argument("--vault-root", default=str(DEFAULT_VAULT_ROOT))
    parser.add_argument("--gemini-settings", default=None)
    parser.add_argument("--raw-chat-dir", default=DEFAULT_RAW_CHAT_DIR)
    parser.add_argument("--mode", choices=["normalize", "build-workspace", "build-all", "build", "both"], default="build-workspace")
    args = parser.parse_args()

    result = export_obsidian_wiki(
        workspace=args.workspace,
        global_root=args.global_root,
        vault_root=args.vault_root,
        gemini_settings=args.gemini_settings,
        raw_chat_dir=args.raw_chat_dir,
        mode=args.mode,
    )
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
