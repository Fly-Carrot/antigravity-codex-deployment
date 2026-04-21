#!/usr/bin/env python3

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

from path_config import resolve_global_root, resolve_workspace

SCRIPT_DIR = Path(__file__).resolve().parent


def run(step: list[str]) -> None:
    subprocess.run(step, check=True)


def main() -> int:
    parser = argparse.ArgumentParser(description="Run the full Global Agent Fabric sync cycle.")
    parser.add_argument("--global-root", type=Path, default=None)
    parser.add_argument("--workspace", type=Path, default=None)
    parser.add_argument("--agent", default="unknown")
    parser.add_argument("--task-id", default="session")
    parser.add_argument("--skip-preflight", action="store_true")
    parser.add_argument("--skip-receipt", action="store_true")
    parser.add_argument("--skip-import", action="store_true")
    parser.add_argument("--skip-export", action="store_true")
    parser.add_argument("--brain-limit", type=int, default=12)
    parser.add_argument("--history-limit", type=int, default=20)
    args = parser.parse_args()

    args.global_root = resolve_global_root(args.global_root)
    args.workspace = resolve_workspace(args.workspace)

    python = sys.executable
    if not args.skip_preflight:
        run(
            [
                python,
                str(SCRIPT_DIR / "preflight_check.py"),
                "--global-root",
                str(args.global_root),
                "--workspace",
                str(args.workspace),
                "--agent",
                args.agent,
                "--task-id",
                args.task_id,
            ]
            + ([] if args.skip_receipt else ["--emit-receipt"])
        )
    if not args.skip_import:
        run(
            [
                python,
                str(SCRIPT_DIR / "import_antigravity_state.py"),
                "--global-root",
                str(args.global_root),
                "--workspace",
                str(args.workspace),
                "--brain-limit",
                str(args.brain_limit),
                "--history-limit",
                str(args.history_limit),
            ]
        )
    if not args.skip_export:
        run(
            [
                python,
                str(SCRIPT_DIR / "export_codex_context.py"),
                "--global-root",
                str(args.global_root),
                "--workspace",
                str(args.workspace),
            ]
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
