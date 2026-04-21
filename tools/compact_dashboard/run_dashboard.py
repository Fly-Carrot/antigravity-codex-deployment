#!/usr/bin/env python3

from __future__ import annotations

import argparse
import curses
import time
from pathlib import Path

from dashboard_data import PHASE_LABELS, PHASE_ORDER, WRITE_TARGET_ORDER, build_state


def _fit(text: str, width: int) -> str:
    if width <= 0:
        return ""
    if len(text) <= width:
        return text
    if width == 1:
        return text[:1]
    return text[: width - 1] + "…"


def _render_stage_bar(current: str, completed: list[str]) -> str:
    tokens: list[str] = []
    completed_set = set(completed)
    for phase_key in PHASE_ORDER:
        label = PHASE_LABELS[phase_key]
        if phase_key == current:
            tokens.append(f"▶{label}")
        elif phase_key in completed_set:
            tokens.append(f"●{label}")
        else:
            tokens.append(f"·{label}")
    return " ".join(tokens)


def _render_writes(counts: dict[str, int]) -> str:
    label_map = {
        "receipts": "rcpt",
        "handoffs": "handoff",
        "decision_log": "decision",
        "open_loops": "loop",
        "mempalace_records": "memp",
        "promoted_learnings": "learn",
    }
    return "  ".join(f"{label_map[key]}:{counts.get(key, 0)}" for key in WRITE_TARGET_ORDER)


def _draw(stdscr: curses.window, workspace: str | None, global_root: str | None, gemini_settings: str | None) -> None:
    try:
        curses.curs_set(0)
    except curses.error:
        pass
    stdscr.nodelay(True)
    stdscr.timeout(1500)

    while True:
        state = build_state(workspace=workspace, global_root=global_root, gemini_settings=gemini_settings)
        height, width = stdscr.getmaxyx()
        stdscr.erase()

        title = f"Shared Fabric Control Tower  {state.project_name}"
        stdscr.addstr(0, 0, _fit(title, width - 1), curses.A_BOLD)
        stdscr.addstr(1, 0, _fit(f"runtime {state.runtime}   task {state.task_id}", width - 1))
        stdscr.addstr(
            2,
            0,
            _fit(
                f"boot {state.boot_status}   sync {state.sync_status}   lifecycle {state.lifecycle_phase}   attention {state.attention_state}",
                width - 1,
            ),
        )
        stdscr.addstr(
            3,
            0,
            _fit(
                f"mcp {state.active_mcp_count}   registry {state.enabled_registry_count} on / {state.disabled_registry_count} off   audit {state.sync_audit_source}",
                width - 1,
            ),
        )
        stdscr.addstr(4, 0, _fit(f"stages {_render_stage_bar(state.six_stage_current, state.six_stage_completed)}", width - 1))
        current_label = PHASE_LABELS.get(state.six_stage_current, "-")
        stdscr.addstr(5, 0, _fit(f"current {current_label}   phase source {state.phase_source}", width - 1))
        if state.six_stage_note:
            stdscr.addstr(6, 0, _fit(f"phase note {state.six_stage_note}", width - 1))

        row = 8
        stdscr.addstr(row, 0, _fit("last sync delta", width - 1), curses.A_UNDERLINE)
        row += 1
        stdscr.addstr(row, 0, _fit(_render_writes(state.last_sync_delta.writes_count_by_target), width - 1))
        row += 1
        learned = ", ".join(state.last_sync_delta.learned_items) or "(none)"
        stdscr.addstr(row, 0, _fit(f"learned {learned}", width - 1))
        row += 1
        skipped = ", ".join(state.last_sync_delta.skipped_items) or "(none)"
        stdscr.addstr(row, 0, _fit(f"skipped {skipped}", width - 1))
        row += 1
        stdscr.addstr(row, 0, _fit(f"summary {state.last_sync_delta.source_summary}", width - 1))
        row += 2

        stdscr.addstr(row, 0, _fit(f"handoff {state.last_handoff}", width - 1))
        row += 2
        stdscr.addstr(row, 0, _fit("recent tasks", width - 1), curses.A_UNDERLINE)
        row += 1
        for item in state.recent_tasks[:3]:
            line = f"{item['time']}  {item['agent']:<6}  B:{item['boot']} S:{item['sync']}  {item['task_id']}  {item['summary']}"
            if row >= height - 3:
                break
            stdscr.addstr(row, 0, _fit(line, width - 1))
            row += 1

        if state.alerts and row < height - 2:
            row += 1
            stdscr.addstr(row, 0, _fit("alerts", width - 1), curses.A_UNDERLINE)
            row += 1
            for alert in state.alerts[:2]:
                if row >= height - 2:
                    break
                stdscr.addstr(row, 0, _fit(alert, width - 1))
                row += 1

        footer = "q quit   r refresh"
        stdscr.addstr(height - 1, 0, _fit(footer, width - 1), curses.A_DIM)
        stdscr.refresh()

        key = stdscr.getch()
        if key in (ord("q"), ord("Q")):
            break
        if key in (ord("r"), ord("R")):
            continue
        time.sleep(0.1)


def main() -> int:
    parser = argparse.ArgumentParser(description="Compact shared-fabric runtime dashboard.")
    parser.add_argument("--workspace", type=str, default=None)
    parser.add_argument("--global-root", type=str, default=None)
    parser.add_argument("--gemini-settings", type=str, default=None)
    args = parser.parse_args()

    curses.wrapper(_draw, args.workspace, args.global_root, args.gemini_settings)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
