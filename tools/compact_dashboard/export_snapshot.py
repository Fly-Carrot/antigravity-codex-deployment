#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
from pathlib import Path

from dashboard_data import build_state


def main() -> int:
    parser = argparse.ArgumentParser(description="Export a single JSON snapshot for the compact dashboard surfaces.")
    parser.add_argument("--workspace", type=Path, default=Path("/Users/david_chen/Desktop/MCP_Hub"))
    parser.add_argument("--global-root", type=str, default=None)
    parser.add_argument("--gemini-settings", type=str, default=None)
    parser.add_argument("--output", type=Path, default=None)
    args = parser.parse_args()

    snapshot = build_state(
        workspace=args.workspace.expanduser().resolve(),
        global_root=args.global_root,
        gemini_settings=args.gemini_settings,
    ).to_snapshot()
    payload = json.dumps(snapshot, ensure_ascii=False, indent=2)

    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(payload + "\n", encoding="utf-8")
    else:
        print(payload)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
