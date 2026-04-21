#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

SYNC_SCRIPT_DIR = Path(__file__).resolve().parents[1] / "fabric" / "scripts" / "sync"
if str(SYNC_SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SYNC_SCRIPT_DIR))

import bootstrap_gemini_workspace as gemini_bootstrap


RUNTIME_CHOICES = {"codex", "gemini", "both"}


def normalize_runtimes(value: str) -> list[str]:
    lowered = value.strip().lower()
    if lowered not in RUNTIME_CHOICES:
        raise SystemExit(f"Unsupported runtime selection: {value}")
    if lowered == "both":
        return ["codex", "gemini"]
    return [lowered]


def task_shell_header(agent_expression: str) -> str:
    return "\n".join(
        [
            'set -euo pipefail',
            'GLOBAL_ROOT="$1"',
            'WORKSPACE="${workspaceFolder}"',
            f'AGENT="{agent_expression}"',
            'TASK_ID="${input:sharedFabricTaskId}"',
            'if [[ -z "$TASK_ID" ]]; then',
            '  TASK_ID="shared-fabric-${AGENT}-$(date +%Y%m%d-%H%M%S)"',
            'fi',
        ]
    )


def render_tasks(global_root: Path, runtimes: list[str]) -> dict[str, object]:
    global_root_str = str(global_root)
    installer_script = str(Path(__file__).resolve())
    agent_expression = "${input:sharedFabricAgent}" if len(runtimes) > 1 else runtimes[0]

    boot_script = "\n".join(
        [
            task_shell_header(agent_expression),
            'python3 "$GLOBAL_ROOT/scripts/sync/preflight_check.py" \\',
            '  --global-root "$GLOBAL_ROOT" \\',
            '  --workspace "$WORKSPACE" \\',
            '  --agent "$AGENT" \\',
            '  --task-id "$TASK_ID" \\',
            '  --emit-receipt',
            'python3 "$GLOBAL_ROOT/scripts/sync/sync_all.py" \\',
            '  --global-root "$GLOBAL_ROOT" \\',
            '  --workspace "$WORKSPACE" \\',
            '  --agent "$AGENT" \\',
            '  --task-id "$TASK_ID" \\',
            '  --skip-preflight \\',
            '  --skip-receipt',
        ]
    )
    sync_script = "\n".join(
        [
            task_shell_header(agent_expression),
            'python3 "$GLOBAL_ROOT/scripts/sync/sync_all.py" \\',
            '  --global-root "$GLOBAL_ROOT" \\',
            '  --workspace "$WORKSPACE" \\',
            '  --agent "$AGENT" \\',
            '  --task-id "$TASK_ID" \\',
            '  --skip-preflight \\',
            '  --skip-receipt',
        ]
    )
    postflight_script = "\n".join(
        [
            task_shell_header(agent_expression),
            'SUMMARY="${input:sharedFabricSummary}"',
            'DECISION="${input:sharedFabricDecision}"',
            'OPEN_LOOP="${input:sharedFabricOpenLoop}"',
            'HANDOFF="${input:sharedFabricHandoff}"',
            'ARGS=(--global-root "$GLOBAL_ROOT" --workspace "$WORKSPACE" --agent "$AGENT" --task-id "$TASK_ID" --summary "$SUMMARY")',
            'if [[ -n "$DECISION" ]]; then ARGS+=(--decision "$DECISION"); fi',
            'if [[ -n "$OPEN_LOOP" ]]; then ARGS+=(--open-loop "$OPEN_LOOP"); fi',
            'if [[ -n "$HANDOFF" ]]; then ARGS+=(--handoff "$HANDOFF"); fi',
            'python3 "$GLOBAL_ROOT/scripts/sync/postflight_sync.py" "${ARGS[@]}"',
        ]
    )
    rebuild_script = "\n".join(
        [
            'set -euo pipefail',
            'GLOBAL_ROOT="$1"',
            f'python3 "{installer_script}" --workspace "${{workspaceFolder}}" --global-root "$GLOBAL_ROOT" --runtimes {"both" if len(runtimes) > 1 else runtimes[0]}',
        ]
    )

    tasks = {
        "version": "2.0.0",
        "tasks": [
            {
                "label": "Shared Fabric: Boot Current Workspace",
                "type": "shell",
                "command": "/bin/zsh",
                "args": ["-lc", boot_script, "--", global_root_str],
                "problemMatcher": [],
            },
            {
                "label": "Shared Fabric: Sync Current Workspace",
                "type": "shell",
                "command": "/bin/zsh",
                "args": ["-lc", sync_script, "--", global_root_str],
                "problemMatcher": [],
            },
            {
                "label": "Shared Fabric: Postflight Sync",
                "type": "shell",
                "command": "/bin/zsh",
                "args": ["-lc", postflight_script, "--", global_root_str],
                "problemMatcher": [],
            },
            {
                "label": "Shared Fabric: Open Global Root",
                "type": "shell",
                "command": "/usr/bin/open",
                "args": [global_root_str],
                "problemMatcher": [],
            },
            {
                "label": "Shared Fabric: Rebuild Workspace Entry",
                "type": "shell",
                "command": "/bin/zsh",
                "args": ["-lc", rebuild_script, "--", global_root_str],
                "problemMatcher": [],
            },
        ],
        "inputs": [
            {
                "id": "sharedFabricTaskId",
                "type": "promptString",
                "description": "Optional task id override for shared fabric commands",
                "default": "",
            },
            {
                "id": "sharedFabricSummary",
                "type": "promptString",
                "description": "Summary for postflight sync",
                "default": "Shared Fabric postflight sync",
            },
            {
                "id": "sharedFabricDecision",
                "type": "promptString",
                "description": "Optional decision note for postflight sync",
                "default": "",
            },
            {
                "id": "sharedFabricOpenLoop",
                "type": "promptString",
                "description": "Optional open loop for postflight sync",
                "default": "",
            },
            {
                "id": "sharedFabricHandoff",
                "type": "promptString",
                "description": "Optional handoff note for postflight sync",
                "default": "",
            },
        ],
    }
    if len(runtimes) > 1:
        tasks["inputs"].insert(
            0,
            {
                "id": "sharedFabricAgent",
                "type": "pickString",
                "description": "Select the runtime identity for this shared fabric action",
                "options": runtimes,
            },
        )
    return tasks


def write_tasks_file(workspace: Path, tasks: dict[str, object]) -> Path:
    target = workspace / ".vscode" / "tasks.json"
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(tasks, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    return target


def bootstrap_workspace(
    *,
    workspace: Path,
    global_root: Path,
    runtimes: list[str],
    gemini_settings: Path | None,
    secrets_file: Path | None,
) -> dict[str, object]:
    workspace = workspace.expanduser().resolve()
    global_root = global_root.expanduser().resolve()
    workspace.mkdir(parents=True, exist_ok=True)

    if "gemini" in runtimes:
        gemini_summary = gemini_bootstrap.bootstrap_workspace(
            workspace=workspace,
            global_root=global_root,
            gemini_settings=gemini_settings or gemini_bootstrap.DEFAULT_GEMINI_SETTINGS,
            secrets_file=secrets_file or (global_root / "mcp" / "secrets.yaml"),
        )
    else:
        registry = gemini_bootstrap.parse_project_registry(global_root / "projects" / "registry.yaml")
        project = gemini_bootstrap.resolve_workspace_project(registry, workspace)
        agents_path = workspace / "AGENTS.md"
        gemini_bootstrap.write_workspace_agents(
            agents_path,
            gemini_bootstrap.render_workspace_agents(project, workspace),
        )
        gemini_summary = {
            "workspace": str(workspace),
            "project_id": project["id"],
            "registered": bool(project.get("registered", False)),
            "gemini_settings": "",
            "agents_file": str(agents_path),
            "mcp_servers": [],
        }

    tasks_path = write_tasks_file(workspace, render_tasks(global_root, runtimes))
    return {
        "workspace": str(workspace),
        "global_root": str(global_root),
        "runtimes": runtimes,
        "agents_file": gemini_summary["agents_file"],
        "registered": gemini_summary["registered"],
        "gemini_settings": gemini_summary["gemini_settings"],
        "vscode_tasks": str(tasks_path),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Bootstrap a workspace-first VSCode shared-fabric entry.")
    parser.add_argument("--workspace", type=Path, required=True)
    parser.add_argument("--global-root", type=Path, required=True)
    parser.add_argument("--runtimes", default="both")
    parser.add_argument("--gemini-settings", type=Path, default=None)
    parser.add_argument("--secrets-file", type=Path, default=None)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    runtimes = normalize_runtimes(args.runtimes)
    if args.dry_run:
        payload = {
            "status": "dry_run",
            "workspace": str(args.workspace.expanduser().resolve()),
            "global_root": str(args.global_root.expanduser().resolve()),
            "runtimes": runtimes,
            "tasks": render_tasks(args.global_root.expanduser().resolve(), runtimes),
        }
        print(json.dumps(payload, ensure_ascii=False, indent=2))
        return 0

    summary = bootstrap_workspace(
        workspace=args.workspace,
        global_root=args.global_root,
        runtimes=runtimes,
        gemini_settings=args.gemini_settings,
        secrets_file=args.secrets_file,
    )
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
