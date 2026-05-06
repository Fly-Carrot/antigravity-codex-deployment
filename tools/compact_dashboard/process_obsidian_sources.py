#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import re
import shutil
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from export_obsidian_wiki import DEFAULT_RAW_CHAT_DIR, DEFAULT_VAULT_ROOT
from dashboard_data import _normalize_path, _parse_timestamp, _read_ndjson, resolve_global_root


SOURCE_FAMILIES = {
    "agent_chats": {
        "label": "Agent Chats",
        "target": Path("00 Raw Sources") / "Agent Chats",
        "legacy_names": ["Agent Chat History"],
    },
    "gemini": {
        "label": "Gemini",
        "target": Path("00 Raw Sources") / "External Imports" / "Gemini",
        "legacy_names": ["Gemini", "Gemini CLI"],
    },
    "chatgpt": {
        "label": "ChatGPT",
        "target": Path("00 Raw Sources") / "External Imports" / "ChatGPT",
        "legacy_names": ["ChatGPT", "OpenAI", "ChatGPT Exports"],
    },
    "notebooklm": {
        "label": "NotebookLM",
        "target": Path("00 Raw Sources") / "External Imports" / "NotebookLM",
        "legacy_names": ["NotebookLM"],
    },
    "notion": {
        "label": "Notion",
        "target": Path("00 Raw Sources") / "External Imports" / "Notion",
        "legacy_names": ["Notion"],
    },
    "shared_fabric": {
        "label": "Shared Fabric",
        "target": Path("00 Raw Sources") / "Shared Fabric Snapshots",
        "legacy_names": [],
    },
}


@dataclass
class SourceItem:
    family: str
    title: str
    source_id: str
    source_timestamp: str
    raw_content_path: str
    provenance_path: str
    summary: str
    wiki_elements: dict[str, Any]


def _now_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def _write(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content.rstrip() + "\n", encoding="utf-8")


def _copy_tree_contents(source: Path, target: Path) -> None:
    target.mkdir(parents=True, exist_ok=True)
    if not source.exists():
        return
    for child in source.iterdir():
        destination = target / child.name
        if child.is_dir():
            shutil.copytree(child, destination, dirs_exist_ok=True)
        else:
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(child, destination)


def _copy_file(source: Path, target: Path) -> None:
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, target)


def _looks_like_separator(value: str) -> bool:
    compact = value.strip()
    if not compact:
        return True
    if compact.startswith("```"):
        return True
    separator_chars = set("-_=|:.`~*#")
    if set(compact) <= separator_chars:
        return True
    if compact.count("|") >= 2 and set(compact.replace("|", "").replace(":", "").replace("-", "").replace(" ", "")) == set():
        return True
    return False


def _frontmatter_title(text: str) -> str:
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        return ""
    for line in lines[1:40]:
        stripped = line.strip()
        if stripped == "---":
            break
        if stripped.lower().startswith("title:"):
            value = stripped.split(":", 1)[1].strip().strip("\"'")
            return value[:120]
    return ""


def _guess_title(path: Path, text: str) -> str:
    fm_title = _frontmatter_title(text)
    if fm_title and not _looks_like_separator(fm_title):
        return fm_title
    for line in text.splitlines():
        stripped = line.strip()
        if _looks_like_separator(stripped):
            continue
        if re.match(r"^[A-Za-z0-9_-]+\s*:\s*", stripped):
            continue
        if stripped.startswith("#"):
            return stripped.lstrip("#").strip() or path.stem
        if stripped:
            return stripped[:120]
    return path.stem


def _guess_summary(text: str) -> str:
    for block in text.split("\n\n"):
        normalized = " ".join(line.strip() for line in block.splitlines() if line.strip())
        if normalized:
            return normalized[:220]
    return ""


def _read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        try:
            return path.read_text(encoding="utf-8", errors="ignore")
        except OSError:
            return ""
    except OSError:
        return ""


def _text_source_files(root: Path) -> list[Path]:
    if not root.exists():
        return []
    supported = {".md", ".markdown", ".txt", ".json", ".jsonl", ".csv", ".tsv"}
    return sorted(
        [
            path
            for path in root.rglob("*")
            if path.is_file() and path.suffix.lower() in supported
        ],
        key=lambda item: str(item).lower(),
    )


def _guess_project_hints(path: Path, text: str, known_projects: list[str]) -> list[str]:
    haystack = f"{path.as_posix()} {text[:500]}".lower()
    matches = [project for project in known_projects if project and project.lower() in haystack]
    return sorted(set(matches))[:6]


def _discover_known_projects(global_root: Path) -> list[str]:
    receipts = _read_ndjson(global_root / "sync" / "receipts.ndjson")
    workspaces = {
        Path(_normalize_path(entry.get("workspace"))).name
        for entry in receipts
        if _normalize_path(entry.get("workspace"))
    }
    return sorted(item for item in workspaces if item)


def _build_source_items(family: str, target_root: Path, known_projects: list[str]) -> list[SourceItem]:
    items: list[SourceItem] = []
    for path in _text_source_files(target_root):
        text = _read_text(path)
        stat = path.stat()
        relative = path.relative_to(target_root)
        items.append(
            SourceItem(
                family=family,
                title=_guess_title(path, text),
                source_id=f"{family}:{relative.as_posix()}",
                source_timestamp=datetime.fromtimestamp(stat.st_mtime, tz=timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
                raw_content_path=str(path),
                provenance_path=str(path),
                summary=_guess_summary(text),
                wiki_elements={
                    "project_hints": _guess_project_hints(path, text, known_projects),
                    "has_markdown": path.suffix.lower() in {".md", ".markdown"},
                },
            )
        )
    return items


def _sync_family_sources(vault_root: Path, family: str, raw_chat_dir: str, global_root: Path) -> tuple[list[str], Path]:
    config = SOURCE_FAMILIES[family]
    target_root = vault_root / config["target"]
    target_root.mkdir(parents=True, exist_ok=True)
    source_paths: list[str] = []

    if family == "agent_chats":
        candidate = vault_root / raw_chat_dir
        if candidate.exists():
            source_paths.append(str(candidate))
            if candidate.resolve() != target_root.resolve():
                _copy_tree_contents(candidate, target_root)
        for legacy_name in config["legacy_names"]:
            legacy = vault_root / legacy_name
            if legacy.exists():
                source_paths.append(str(legacy))
                _copy_tree_contents(legacy, target_root)
        return sorted(set(source_paths)), target_root

    if family == "shared_fabric":
        files_to_copy = [
            global_root / "memory" / "decision-log.ndjson",
            global_root / "memory" / "handoffs.ndjson",
            global_root / "memory" / "open-loops.ndjson",
            global_root / "memory" / "mempalace-records.ndjson",
            global_root / "memory" / "promoted-learnings.ndjson",
            global_root / "memory" / "user-question-profile.md",
            global_root / "sync" / "learning_receipts.ndjson",
            global_root / "sync" / "receipts.ndjson",
            global_root / "sync" / "task_phases.ndjson",
        ]
        for source in files_to_copy:
            if source.exists():
                source_paths.append(str(source))
                _copy_file(source, target_root / source.name)
        imported_root = global_root / "workflows" / "imported"
        if imported_root.exists():
            source_paths.append(str(imported_root))
            _copy_tree_contents(imported_root, target_root / "workflows-imported")
        return sorted(set(source_paths)), target_root

    for legacy_name in config["legacy_names"]:
        legacy = vault_root / legacy_name
        if legacy.exists():
            source_paths.append(str(legacy))
            _copy_tree_contents(legacy, target_root)
    if target_root.exists():
        source_paths.append(str(target_root))
    return sorted(set(source_paths)), target_root


def process_sources(
    *,
    workspace: str | Path | None,
    global_root: str | Path | None,
    vault_root: str | Path,
    raw_chat_dir: str = DEFAULT_RAW_CHAT_DIR,
    gemini_settings: str | Path | None = None,
) -> dict[str, Any]:
    global_root_path = resolve_global_root(global_root)
    vault_root_path = Path(vault_root).expanduser()
    workspace_path = _normalize_path(workspace)
    if not vault_root_path.exists():
        raise FileNotFoundError(f"vault root does not exist: {vault_root_path}")

    generated_at = _now_iso()
    known_projects = _discover_known_projects(global_root_path)

    families_payload: list[dict[str, Any]] = []
    all_items: list[dict[str, Any]] = []
    copied_roots: list[str] = []

    for family, config in SOURCE_FAMILIES.items():
        source_roots, target_root = _sync_family_sources(vault_root_path, family, raw_chat_dir, global_root_path)
        items = _build_source_items(family, target_root, known_projects)
        family_payload = {
            "family": family,
            "label": config["label"],
            "target_root": str(target_root),
            "source_roots": source_roots,
            "item_count": len(items),
            "items": [
                {
                    "family": item.family,
                    "title": item.title,
                    "source_id": item.source_id,
                    "source_timestamp": item.source_timestamp,
                    "raw_content_path": item.raw_content_path,
                    "provenance_path": item.provenance_path,
                    "summary": item.summary,
                    "wiki_elements": item.wiki_elements,
                }
                for item in items
            ],
        }
        families_payload.append(family_payload)
        all_items.extend(family_payload["items"])
        copied_roots.extend(source_roots)

    normalized_manifest = {
        "generated_at": generated_at,
        "vault_root": str(vault_root_path),
        "workspace": workspace_path,
        "summary": {
            "family_count": len(families_payload),
            "item_count": len(all_items),
        },
        "source_families": families_payload,
        "items": all_items,
    }

    manifest_path = vault_root_path / "90 System" / "normalized-sources-manifest.json"
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    manifest_path.write_text(json.dumps(normalized_manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    report_lines = [
        "# Source Processing Report",
        "",
        f"- Generated at: `{generated_at}`",
        f"- Families: `{len(families_payload)}`",
        f"- Items: `{len(all_items)}`",
        "",
        "## Families",
    ]
    for family in families_payload:
        report_lines.append(f"- **{family['label']}** · `{family['item_count']}` items · target `{family['target_root']}`")
        for source_root in family["source_roots"]:
            report_lines.append(f"  - source: `{source_root}`")
    report_path = vault_root_path / "90 System" / "source-processing-report.md"
    _write(report_path, "\n".join(report_lines))

    return {
        "generated_at": generated_at,
        "workspace": workspace_path,
        "vault_root": str(vault_root_path),
        "normalized_manifest": str(manifest_path),
        "report_path": str(report_path),
        "families_processed": len(families_payload),
        "items_processed": len(all_items),
        "source_roots": sorted(set(copied_roots)),
        "next_step": "Run export_obsidian_wiki.py --mode build-all to compile source manifests into wiki/system outputs.",
    }


def main() -> None:
    parser = argparse.ArgumentParser(description="Normalize all supported external sources into canonical raw-source structure.")
    parser.add_argument("--workspace", default=None)
    parser.add_argument("--global-root", default=None)
    parser.add_argument("--vault-root", default=str(DEFAULT_VAULT_ROOT))
    parser.add_argument("--raw-chat-dir", default=DEFAULT_RAW_CHAT_DIR)
    parser.add_argument("--gemini-settings", default=None)
    args = parser.parse_args()

    result = process_sources(
        workspace=args.workspace,
        global_root=args.global_root,
        vault_root=args.vault_root,
        raw_chat_dir=args.raw_chat_dir,
        gemini_settings=args.gemini_settings,
    )
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
