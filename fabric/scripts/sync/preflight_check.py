#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from path_config import resolve_global_root, resolve_workspace


def utc_now_iso() -> str:
    return datetime.now(UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def ensure_parent(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)


def append_record(path: Path, record: dict[str, Any]) -> None:
    ensure_parent(path)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(record, ensure_ascii=False, sort_keys=True) + "\n")


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate Global Agent Fabric before a runtime starts work.")
    parser.add_argument("--global-root", type=Path, default=None)
    parser.add_argument("--workspace", type=Path, default=None)
    parser.add_argument("--agent")
    parser.add_argument("--task-id", default="session")
    parser.add_argument("--emit-receipt", action="store_true")
    args = parser.parse_args()

    args.global_root = resolve_global_root(args.global_root)
    args.workspace = resolve_workspace(args.workspace)

    required_global = [
        args.global_root / "README.md",
        args.global_root / "rules" / "global" / "gemini-global.md",
        args.global_root / "projects" / "registry.yaml",
        args.global_root / "mcp" / "servers.yaml",
        args.global_root / "skills" / "sources.yaml",
        args.global_root / "workflows" / "sources.yaml",
        args.global_root / "memory" / "routes.yaml",
        args.global_root / "memory" / "schema.yaml",
        args.global_root / "sync" / "runtime-map.yaml",
        args.global_root / "sync" / "hook-policy.yaml",
    ]
    missing_global = [str(path) for path in required_global if not path.exists()]

    project_registry = args.global_root / "projects" / "registry.yaml"
    overlay_exists = (args.workspace / ".agents").exists()

    status = "ok" if not missing_global else "error"
    summary = {
        "status": status,
        "status_marker": "[BOOT_OK]" if status == "ok" else "[BOOT_FAIL]",
        "global_root": str(args.global_root),
        "workspace": str(args.workspace),
        "agent": args.agent,
        "task_id": args.task_id,
        "workspace_overlay_exists": overlay_exists,
        "missing_global_files": missing_global,
        "project_registry": str(project_registry),
    }

    if args.emit_receipt:
        if not args.agent:
            parser.error("--emit-receipt requires --agent")
        append_record(
            args.global_root / "sync" / "receipts.ndjson",
            {
                "timestamp": utc_now_iso(),
                "agent": args.agent,
                "workspace": str(args.workspace),
                "task_id": args.task_id,
                "hook": "preflight_check",
                "phase": "session_start",
                "status": status,
                "status_marker": summary["status_marker"],
            },
        )

    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return 0 if status == "ok" else 1


if __name__ == "__main__":
    raise SystemExit(main())
