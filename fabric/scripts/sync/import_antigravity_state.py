#!/usr/bin/env python3

from __future__ import annotations

import argparse
import hashlib
import json
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from memory_expansion import (
    append_ndjson_if_new,
    compose_workflow_bundle,
    learning_receipt_record,
    normalize_items,
    parse_imported_workflow_snapshot,
    utc_now_iso,
)
from path_config import resolve_global_root, resolve_path, resolve_workspace

SENSITIVE_ARG_TOKENS = {"--api-key", "--apikey", "--token", "--auth-token"}
MCP_SCOPE_HINTS = {
    "notebooklm": "research",
    "zotero": "literature",
    "context7": "docs",
    "markitdown": "document-conversion",
    "chrome-devtools": "browser-automation",
    "mempalace": "memory",
    "qgis": "gis",
}


def load_json(path: Path) -> Any:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8").strip()


def ensure_parent(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)


def parse_iso8601(value: str | None) -> datetime | None:
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def yaml_quote(value: str) -> str:
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def yaml_scalar(value: Any) -> str:
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return str(value)
    return yaml_quote(str(value))


def dump_yaml(data: Any, indent: int = 0) -> list[str]:
    space = " " * indent
    if isinstance(data, dict):
        if not data:
            return [f"{space}{{}}"]
        lines: list[str] = []
        for key, value in data.items():
            if isinstance(value, dict) and value:
                lines.append(f"{space}{key}:")
                lines.extend(dump_yaml(value, indent + 2))
            elif isinstance(value, list) and value:
                lines.append(f"{space}{key}:")
                lines.extend(dump_yaml(value, indent + 2))
            elif isinstance(value, list):
                lines.append(f"{space}{key}: []")
            elif isinstance(value, dict):
                lines.append(f"{space}{key}: {{}}")
            else:
                lines.append(f"{space}{key}: {yaml_scalar(value)}")
        return lines
    if isinstance(data, list):
        if not data:
            return [f"{space}[]"]
        lines = []
        for item in data:
            if isinstance(item, (dict, list)):
                lines.append(f"{space}-")
                lines.extend(dump_yaml(item, indent + 2))
            else:
                lines.append(f"{space}- {yaml_scalar(item)}")
        return lines
    return [f"{space}{yaml_scalar(data)}"]


@dataclass
class ImportState:
    path: Path
    imported_brain_signatures: set[str]
    imported_history_signatures: set[str]
    imported_receipt_signatures: set[str]

    @classmethod
    def load(cls, path: Path) -> "ImportState":
        raw = load_json(path) if path.exists() else {}
        return cls(
            path=path,
            imported_brain_signatures=set(raw.get("imported_brain_signatures", [])),
            imported_history_signatures=set(raw.get("imported_history_signatures", [])),
            imported_receipt_signatures=set(raw.get("imported_receipt_signatures", [])),
        )

    def save(self) -> None:
        ensure_parent(self.path)
        payload = {
            "version": 2,
            "updated_at": utc_now_iso(),
            "imported_brain_signatures": sorted(self.imported_brain_signatures),
            "imported_history_signatures": sorted(self.imported_history_signatures),
            "imported_receipt_signatures": sorted(self.imported_receipt_signatures),
        }
        self.path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def mask_sensitive_args(server_id: str, args: list[str]) -> list[str]:
    masked: list[str] = []
    skip_next = False
    for arg in args:
        if skip_next:
            skip_next = False
            continue
        if arg in SENSITIVE_ARG_TOKENS:
            masked.extend([arg, f"${{{server_id.upper().replace('-', '_')}_SECRET}}"])
            skip_next = True
        else:
            masked.append(arg)
    return masked


def import_mcp_config(mcp_config_path: Path, output_path: Path) -> int:
    if not mcp_config_path.exists():
        return 0
    payload = load_json(mcp_config_path)
    servers = []
    for server_id, config in sorted((payload.get("mcpServers") or {}).items()):
        servers.append(
            {
                "id": server_id,
                "enabled": not bool(config.get("disabled", False)),
                "command": config.get("command"),
                "args": mask_sensitive_args(server_id, list(config.get("args") or [])),
                "env_refs": sorted((config.get("env") or {}).keys()),
                "owner": "global",
                "scope": MCP_SCOPE_HINTS.get(server_id, "general"),
                "source": str(mcp_config_path),
            }
        )
    ensure_parent(output_path)
    output_path.write_text("\n".join(dump_yaml({"version": 1, "servers": servers})) + "\n", encoding="utf-8")
    return len(servers)


def infer_task_summary(content: str, fallback: str) -> str:
    for line in content.splitlines():
        line = line.strip().lstrip("#").strip()
        if line:
            return line
    return fallback


def load_artifact(task_dir: Path, stem: str) -> dict[str, Any] | None:
    content_path = task_dir / f"{stem}.md"
    meta_path = task_dir / f"{stem}.md.metadata.json"
    if not content_path.exists() and not meta_path.exists():
        return None
    return {
        "content": read_text(content_path) if content_path.exists() else "",
        "metadata": load_json(meta_path) if meta_path.exists() else {},
    }


def write_workflow_snapshot(task_dir: Path, output_root: Path) -> Path | None:
    task_id = task_dir.name
    task_artifact = load_artifact(task_dir, "task")
    plan_artifact = load_artifact(task_dir, "implementation_plan")
    walkthrough_artifact = load_artifact(task_dir, "walkthrough")
    if not any([task_artifact, plan_artifact, walkthrough_artifact]):
        return None
    lines = [
        "---",
        f'task_id: "{task_id}"',
        'source: "antigravity"',
        'status: "imported"',
        "---",
        "",
        f"# Antigravity Task {task_id}",
        "",
    ]
    for title, artifact in (("Task", task_artifact), ("Implementation Plan", plan_artifact), ("Walkthrough", walkthrough_artifact)):
        if not artifact:
            continue
        lines.append(f"## {title}")
        meta = artifact["metadata"]
        if meta:
            lines.append("")
            for key in ("artifactType", "updatedAt", "version", "summary"):
                if key in meta:
                    lines.append(f"- {key}: {meta[key]}")
        lines.append("")
        lines.append(artifact["content"] or "_No content captured_")
        lines.append("")
    out = output_root / f"antigravity-{task_id}.md"
    ensure_parent(out)
    out.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")
    return out


def sorted_brain_dirs(brain_root: Path) -> list[Path]:
    candidates = [path for path in brain_root.iterdir() if path.is_dir()]

    def sort_key(path: Path) -> float:
        meta = path / "walkthrough.md.metadata.json"
        if meta.exists():
            parsed = parse_iso8601(load_json(meta).get("updatedAt"))
            if parsed:
                return parsed.timestamp()
        return path.stat().st_mtime

    return sorted(candidates, key=sort_key, reverse=True)


def import_brain(brain_root: Path, workflows_root: Path, memory_root: Path, sync_root: Path, state: ImportState, workspace: Path, limit: int) -> tuple[int, int]:
    workflow_count = 0
    memory_count = 0
    for task_dir in sorted_brain_dirs(brain_root)[:limit]:
        snapshot = write_workflow_snapshot(task_dir, workflows_root)
        if snapshot is None:
            continue
        workflow_count += 1
        sections = parse_imported_workflow_snapshot(snapshot)
        task_artifact = load_artifact(task_dir, "task")
        plan_artifact = load_artifact(task_dir, "implementation_plan")
        walkthrough_artifact = load_artifact(task_dir, "walkthrough")
        updated_at = None
        for artifact in (walkthrough_artifact, plan_artifact, task_artifact):
            if artifact and artifact.get("metadata", {}).get("updatedAt"):
                updated_at = artifact["metadata"]["updatedAt"]
                break
        timestamp = updated_at or utc_now_iso()
        bundle = compose_workflow_bundle(
            timestamp=timestamp,
            agent="antigravity",
            workspace=workspace,
            task_id=task_dir.name,
            workflow_snapshot=snapshot,
            task_summary=sections.task_summary or infer_task_summary((task_artifact or {}).get("content", ""), task_dir.name),
            plan_summary=sections.plan_summary,
            walkthrough_summary=sections.walkthrough_summary,
            task_section=sections.task,
            plan_section=sections.implementation_plan,
            walkthrough_section=sections.walkthrough,
            source_kind="workflow_import",
            record_type_prefix="workflow_import",
        )
        for lane_record in bundle:
            target = memory_root / {
                "decision_log": "decision-log.ndjson",
                "handoffs": "handoffs.ndjson",
                "open_loops": "open-loops.ndjson",
                "mempalace_records": "mempalace-records.ndjson",
                "promoted_learnings": "promoted-learnings.ndjson",
            }[lane_record["lane"]]
            if append_ndjson_if_new(target, lane_record, state.imported_brain_signatures):
                memory_count += 1
        receipt = learning_receipt_record(
            timestamp=timestamp,
            agent="antigravity",
            workspace=workspace,
            task_id=task_dir.name,
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
            artifacts=[str(snapshot)],
            learned_items=[sections.plan_summary, sections.walkthrough_summary],
            skipped_items=[],
            generated_records=bundle,
            source_kind="workflow_import",
            source_refs=[str(snapshot)],
            status_marker="[MEMORY_BUNDLE]",
            sync_status="generated",
            extra={"type": "workflow_import_receipt"},
        )
        append_ndjson_if_new(sync_root / "learning_receipts.ndjson", receipt, state.imported_receipt_signatures)
    return workflow_count, memory_count


def import_history(history_root: Path, decision_log_path: Path, state: ImportState, workspace: Path, limit: int) -> int:
    imported = 0
    if not history_root.exists():
        return imported
    entries_files = sorted(history_root.glob("*/entries.json"), reverse=True)
    for entries_file in entries_files[:limit]:
        payload = load_json(entries_file)
        resource = payload.get("resource", "")
        if not resource.endswith("mcp_config.json"):
            continue
        for entry in payload.get("entries", []):
            snapshot_path = entries_file.parent / entry["id"]
            if not snapshot_path.exists():
                continue
            snapshot = load_json(snapshot_path)
            record = {
                "timestamp": datetime.fromtimestamp(entry["timestamp"] / 1000, tz=UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
                "agent": "antigravity",
                "workspace": str(workspace),
                "task_id": f"history-{entries_file.parent.name}",
                "summary": f"Imported MCP snapshot from Antigravity history ({entry['id']})",
                "details": json.dumps(
                    {
                        "resource": resource,
                        "servers": sorted((snapshot.get("mcpServers") or {}).keys()),
                        "snapshot_file": str(snapshot_path),
                    },
                    ensure_ascii=False,
                    indent=2,
                ),
                "artifacts": [str(snapshot_path)],
                "lane": "decision_log",
                "title": "Decision",
                "type": "mcp_snapshot_import",
                "bundle_version": 2,
                "source_kind": "history_import",
                "source_refs": [str(snapshot_path)],
            }
            if append_ndjson_if_new(decision_log_path, record, state.imported_history_signatures):
                imported += 1
    return imported


def main() -> int:
    parser = argparse.ArgumentParser(description="Import Antigravity state into Global Agent Fabric with rich memory bundles.")
    parser.add_argument("--global-root", type=Path, default=None)
    parser.add_argument("--workspace", type=Path, default=None)
    parser.add_argument("--mcp-config", type=Path, default=None)
    parser.add_argument("--brain-root", type=Path, default=None)
    parser.add_argument("--history-root", type=Path, default=None)
    parser.add_argument("--brain-limit", type=int, default=12)
    parser.add_argument("--history-limit", type=int, default=20)
    args = parser.parse_args()

    args.global_root = resolve_global_root(args.global_root)
    args.workspace = resolve_workspace(args.workspace)
    args.mcp_config = resolve_path(args.mcp_config, ["AGF_ANTIGRAVITY_MCP_CONFIG"], default=Path("/Users/david_chen/.gemini/antigravity/mcp_config.json"))
    args.brain_root = resolve_path(args.brain_root, ["AGF_ANTIGRAVITY_BRAIN_ROOT"], default=Path("/Users/david_chen/.gemini/antigravity/brain"))
    args.history_root = resolve_path(args.history_root, ["AGF_ANTIGRAVITY_HISTORY_ROOT"], default=Path("/Users/david_chen/.gemini/history"))

    state = ImportState.load(args.global_root / "sync" / "import-state.json")
    memory_root = args.global_root / "memory"
    sync_root = args.global_root / "sync"
    workflows_root = args.global_root / "workflows" / "imported"

    mcp_servers_written = import_mcp_config(args.mcp_config, args.global_root / "mcp" / "servers.yaml") if args.mcp_config else 0
    workflow_count, memory_count = import_brain(args.brain_root, workflows_root, memory_root, sync_root, state, args.workspace, args.brain_limit) if args.brain_root and args.brain_root.exists() else (0, 0)
    history_count = import_history(args.history_root, memory_root / "decision-log.ndjson", state, args.workspace, args.history_limit) if args.history_root and args.history_root.exists() else 0
    state.save()

    print(
        json.dumps(
            {
                "global_root": str(args.global_root),
                "mcp_servers_written": mcp_servers_written,
                "workflow_snapshots_written": workflow_count,
                "brain_memory_records_appended": memory_count,
                "history_records_appended": history_count,
                "state_file": str(state.path),
            },
            ensure_ascii=False,
            indent=2,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
