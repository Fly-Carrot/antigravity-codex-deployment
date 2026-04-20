#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from path_config import resolve_global_root, resolve_workspace

PHASE_LABELS = {
    "route": "路由",
    "plan": "规划",
    "review": "自审",
    "dispatch": "分发",
    "execute": "执行",
    "report": "回奏",
}


def utc_now_iso() -> str:
    return datetime.now(UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def ensure_parent(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)


def append_record(path: Path, record: dict[str, Any]) -> None:
    ensure_parent(path)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(record, ensure_ascii=False, sort_keys=True) + "\n")


def main() -> int:
    parser = argparse.ArgumentParser(description="Append an exact six-stage task phase event to Global Agent Fabric.")
    parser.add_argument("--global-root", type=Path, default=None)
    parser.add_argument("--workspace", type=Path, default=None)
    parser.add_argument("--agent", required=True)
    parser.add_argument("--task-id", default="session")
    parser.add_argument("--phase", required=True, choices=sorted(PHASE_LABELS.keys()))
    parser.add_argument("--note", default="")
    args = parser.parse_args()

    args.global_root = resolve_global_root(args.global_root)
    args.workspace = resolve_workspace(args.workspace)

    record = {
        "timestamp": utc_now_iso(),
        "workspace": str(args.workspace),
        "agent": args.agent,
        "task_id": args.task_id,
        "phase_key": args.phase,
        "phase_label": PHASE_LABELS[args.phase],
        "note": args.note,
    }
    target = args.global_root / "sync" / "task_phases.ndjson"
    append_record(target, record)
    print(
        json.dumps(
            {
                "status": "written",
                "target": str(target),
                "phase_key": record["phase_key"],
                "phase_label": record["phase_label"],
                "task_id": record["task_id"],
            },
            ensure_ascii=False,
            indent=2,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
