#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

from path_config import resolve_global_root, resolve_workspace


def load_ndjson(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


def latest_records(records: list[dict[str, Any]], limit: int) -> list[dict[str, Any]]:
    return sorted(records, key=lambda row: row.get("timestamp", ""), reverse=True)[:limit]


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8").strip()


def bullets(items: list[str]) -> list[str]:
    return items or ["- _None_"]


def render_record(record: dict[str, Any]) -> str:
    return f"- `{record.get('timestamp', 'unknown-time')}` `{record.get('task_id', 'unknown-task')}` {record.get('summary', '(no summary)')}"


def main() -> int:
    parser = argparse.ArgumentParser(description="Export a Codex-friendly session brief from Global Agent Fabric + project overlay.")
    parser.add_argument("--global-root", type=Path, default=None)
    parser.add_argument("--workspace", type=Path, default=None)
    parser.add_argument("--output", type=Path, default=None)
    parser.add_argument("--limit", type=int, default=8)
    args = parser.parse_args()

    args.global_root = resolve_global_root(args.global_root)
    args.workspace = resolve_workspace(args.workspace)

    output = args.output or (args.workspace / ".agents" / "sync" / "codex-context.md")
    overlay_root = args.workspace / ".agents"
    global_memory = args.global_root / "memory"
    global_workflows = args.global_root / "workflows" / "imported"
    local_rules = sorted((overlay_root / "rules").glob("*.md")) if (overlay_root / "rules").exists() else []
    local_files = []
    for rel in ("sync/registry.yaml", "memory/profile.md"):
        path = overlay_root / rel
        if path.exists():
            local_files.append(str(path))

    decisions = latest_records(load_ndjson(global_memory / "decision-log.ndjson"), args.limit)
    open_loops = latest_records(load_ndjson(global_memory / "open-loops.ndjson"), args.limit)
    handoffs = latest_records(load_ndjson(global_memory / "handoffs.ndjson"), args.limit)
    workflows = sorted(global_workflows.glob("*.md")) if global_workflows.exists() else []

    lines = [
        "# Codex Session Context",
        "",
        f"Workspace: `{args.workspace}`",
        f"Global Root: `{args.global_root}`",
        "",
        "## Global Bootstrap Order",
        "",
        f"- `{args.global_root / 'README.md'}`",
        f"- `{args.global_root / 'rules' / 'global' / 'gemini-global.md'}`",
        f"- `{args.global_root / 'projects' / 'registry.yaml'}`",
        f"- `{args.global_root / 'mcp' / 'servers.yaml'}`",
        f"- `{args.global_root / 'skills' / 'sources.yaml'}`",
        f"- `{args.global_root / 'workflows' / 'sources.yaml'}`",
        f"- `{args.global_root / 'memory' / 'routes.yaml'}`",
        f"- `{args.global_root / 'memory' / 'schema.yaml'}`",
        "",
        "## Local Overlay Rules",
        "",
    ]
    lines.extend(bullets([f"- {path}" for path in map(str, local_rules)]))
    lines.extend(["", "## Local Overlay Extras", ""])
    lines.extend(bullets([f"- {item}" for item in local_files]))
    lines.extend(["", "## Global Memory Profile", ""])
    profile = args.global_root / "memory" / "profile.md"
    lines.append(read_text(profile) if profile.exists() else "_Missing_")
    lines.extend(["", "## Global Workflow Snapshots", ""])
    lines.extend(bullets([f"- {path}" for path in map(str, workflows[: args.limit])]))
    lines.extend(["", "## Recent Decisions", ""])
    lines.extend(bullets([render_record(r) for r in decisions]))
    lines.extend(["", "## Open Loops", ""])
    lines.extend(bullets([render_record(r) for r in open_loops]))
    lines.extend(["", "## Recent Handoffs", ""])
    lines.extend(bullets([render_record(r) for r in handoffs]))

    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")
    print(str(output))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
