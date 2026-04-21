#!/usr/bin/env python3

from __future__ import annotations

import argparse
from pathlib import Path


PROJECTS = [
    ("mcp-hub", "MCP_Hub", "AGF_PROJECT_MCP_HUB", None),
    ("project3.5", "Project3.5", "AGF_PROJECT_3_5", "ecology"),
    ("project4", "Project4", "AGF_PROJECT_4", "ecology"),
    ("project5", "Project5", "AGF_PROJECT_5", "ecology"),
    ("project5.5", "Project 5.5", "AGF_PROJECT_5_5", "ecology"),
    ("project-design", "Project Design", "AGF_PROJECT_DESIGN", "design"),
]


def strip_quotes(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in {'"', "'"}:
        return value[1:-1]
    return value


def load_env_file(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    if not path.exists():
        return values
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = strip_quotes(value)
    return values


def require(values: dict[str, str], key: str) -> str:
    value = values.get(key, "").strip()
    if not value:
        raise SystemExit(f"Missing required config value: {key}")
    return value


def yaml_quote(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def overlay_rules(path: str, rule_name: str | None) -> list[str]:
    if not rule_name:
        return []
    return [f"{path}/.agents/rules/{rule_name}.md"]


def render_projects_registry(values: dict[str, str]) -> str:
    lines = ["version: 1", "projects:"]
    for project_id, name, env_key, rule_name in PROJECTS:
        project_path = require(values, env_key)
        lines.extend(
            [
                "  -",
                f'    id: {yaml_quote(project_id)}',
                f'    name: {yaml_quote(name)}',
                f'    path: {yaml_quote(project_path)}',
            ]
        )
        rules = overlay_rules(project_path, rule_name)
        if rules:
            lines.append("    overlay_rules:")
            lines.extend([f"      - {yaml_quote(rule)}" for rule in rules])
        else:
            lines.append("    overlay_rules: []")
        lines.append(f'    overlay_root: {yaml_quote(project_path + "/.agents")}')
    return "\n".join(lines) + "\n"


def render_hook_policy(values: dict[str, str]) -> str:
    global_root = require(values, "AGF_GLOBAL_ROOT")
    return "\n".join(
        [
            "version: 1",
            'policy_name: "global-agent-fabric-hook-policy"',
            'goal: "Ensure Antigravity and Codex bootstrap from the same shared state and write back through the same shared protocols."',
            "shared_scripts:",
            f'  preflight_check: {yaml_quote(global_root + "/scripts/sync/preflight_check.py")}',
            f'  sync_all: {yaml_quote(global_root + "/scripts/sync/sync_all.py")}',
            f'  postflight_sync: {yaml_quote(global_root + "/scripts/sync/postflight_sync.py")}',
            f'shared_receipt_log: {yaml_quote(global_root + "/sync/receipts.ndjson")}',
            "hook_points:",
            "  session_start:",
            "    required:",
            '      - "Run preflight_check.py"',
            '      - "Run sync_all.py before substantial work"',
            '      - "Emit a session_start receipt with status_marker [BOOT_OK] on success"',
            "    purpose:",
            '      - "Validate global root integrity"',
            '      - "Identify current project overlay"',
            '      - "Load latest shared memory, MCP, workflow, and rule state"',
            "  task_boundary:",
            "    recommended:",
            '      - "Call postflight_sync.py when a major task phase completes"',
            "    purpose:",
            '      - "Persist decision/open-loop/handoff deltas at meaningful boundaries"',
            "  session_end:",
            "    required:",
            '      - "Call postflight_sync.py with a structured summary"',
            '      - "Emit a session_end receipt with status_marker [SYNC_OK] on success"',
            "    purpose:",
            '      - "Guarantee the next runtime sees continuation state"',
            "runtimes:",
            "  antigravity:",
            '    integration_mode: "runtime-native hooks or workflow wrappers"',
            "    minimum_contract:",
            '      - "session_start -> preflight_check + sync_all"',
            '      - "session_end -> postflight_sync"',
            '      - "Echo [BOOT_OK] / [SYNC_OK] in chat when the corresponding receipt is written"',
            "  codex:",
            '    integration_mode: "session wrapper or manual standardized pre/post commands"',
            "    minimum_contract:",
            '      - "session_start -> preflight_check + sync_all"',
            '      - "session_end -> postflight_sync"',
            '      - "Echo [BOOT_OK] / [SYNC_OK] in chat when the corresponding receipt is written"',
            "failure_policy:",
            "  preflight:",
            '    severity: "blocking"',
            '    rule: "If global root, project registry, or memory schema is unreadable, stop and repair before substantive work."',
            "  postflight:",
            '    severity: "warning"',
            '    rule: "If write-back fails, surface the failure explicitly and do not pretend synchronization completed."',
            "",
        ]
    )


def render_memory_routes(values: dict[str, str]) -> str:
    global_root = require(values, "AGF_GLOBAL_ROOT")
    awesome_skills_root = require(values, "AGF_AWESOME_SKILLS_ROOT")
    return "\n".join(
        [
            "version: 1",
            "routes:",
            "  stable_technical_route:",
            '    type: "skill"',
            '    handler: "cc-skill-continuous-learning"',
            f"    source_path: {yaml_quote(awesome_skills_root + '/skills/cc-skill-continuous-learning')}",
            "    capture_examples:",
            '      - "successful environment recipe"',
            '      - "reusable architecture decision"',
            '      - "stable implementation pattern"',
            '      - "cross-session engineering instinct"',
            "    bridge_outputs:",
            f"      - {yaml_quote(global_root + '/memory/ki-registry.yaml')}",
            f"      - {yaml_quote(global_root + '/memory/decision-log.ndjson')}",
            "  episodic_detail:",
            '    type: "mcp"',
            '    handler: "mempalace"',
            f"    source_path: {yaml_quote(global_root + '/mcp/servers.yaml#mempalace')}",
            "    capture_examples:",
            '      - "debugging trace"',
            '      - "reasoning chain"',
            '      - "parameter exploration"',
            '      - "failed branch with future retrieval value"',
            "    bridge_outputs:",
            f"      - {yaml_quote(global_root + '/memory/mempalace-taxonomy.yaml')}",
            f"      - {yaml_quote(global_root + '/memory/handoffs.ndjson')}",
            f"      - {yaml_quote(global_root + '/memory/open-loops.ndjson')}",
            "",
        ]
    )


def render_runtime_map(values: dict[str, str]) -> str:
    global_root = require(values, "AGF_GLOBAL_ROOT")
    awesome_skills_root = require(values, "AGF_AWESOME_SKILLS_ROOT")
    gemini_rule = require(values, "AGF_GEMINI_RULE")
    gemini_settings = require(values, "AGF_GEMINI_SETTINGS")
    antigravity_mcp_config = require(values, "AGF_ANTIGRAVITY_MCP_CONFIG")
    bootstrap_order = [
        f"{global_root}/README.md",
        f"{global_root}/rules/global/gemini-global.md",
        f"{global_root}/projects/registry.yaml",
        f"{global_root}/mcp/servers.yaml",
        f"{global_root}/skills/sources.yaml",
        f"{global_root}/workflows/sources.yaml",
        f"{global_root}/memory/routes.yaml",
        f"{global_root}/memory/schema.yaml",
        f"{global_root}/sync/hook-policy.yaml",
        f"{global_root}/sync/boot-sequence.md",
    ]
    lines = [
        "version: 1",
        f"global_root: {yaml_quote(global_root)}",
        f"shared_receipt_log: {yaml_quote(global_root + '/sync/receipts.ndjson')}",
        "runtimes:",
        "  antigravity:",
        f"    global_rule_source: {yaml_quote(gemini_rule)}",
        f"    mcp_source: {yaml_quote(antigravity_mcp_config)}",
        f"    skills_root: {yaml_quote(awesome_skills_root + '/skills')}",
        "    bootstrap_order:",
    ]
    lines.extend([f"      - {yaml_quote(item)}" for item in bootstrap_order])
    lines.extend(
        [
            "    write_routes:",
            f"      shared_logs_root: {yaml_quote(global_root + '/memory')}",
            "      stable_technical_route:",
            '        mechanism: "cc-skill-continuous-learning"',
            f"        bridge: {yaml_quote(global_root + '/memory/ki-registry.yaml')}",
            "      episodic_detail:",
            '        mechanism: "mempalace"',
            f"        bridge: {yaml_quote(global_root + '/memory/mempalace-taxonomy.yaml')}",
            "    hook_contract:",
            "      session_start:",
            f"        - {yaml_quote(global_root + '/scripts/sync/preflight_check.py')}",
            f"        - {yaml_quote(global_root + '/scripts/sync/sync_all.py')}",
            "      session_end:",
            f"        - {yaml_quote(global_root + '/scripts/sync/postflight_sync.py')}",
            "      required_chat_markers:",
            '        - "[BOOT_OK]"',
            '        - "[SYNC_OK]"',
            '    bridge_context_entrypoint: "AGENTS.md"',
            "  gemini:",
            f"    global_rule_source: {yaml_quote(gemini_rule)}",
            f"    settings_source: {yaml_quote(gemini_settings)}",
            f"    skills_root: {yaml_quote(awesome_skills_root + '/skills')}",
            "    preferred_bootstrap_order:",
        ]
    )
    lines.extend([f"      - {yaml_quote(item)}" for item in bootstrap_order])
    lines.extend(
        [
            "    write_routes:",
            f"      shared_logs_root: {yaml_quote(global_root + '/memory')}",
            "      stable_technical_route:",
            '        mechanism: "cc-skill-continuous-learning"',
            f"        bridge: {yaml_quote(global_root + '/memory/ki-registry.yaml')}",
            "      episodic_detail:",
            '        mechanism: "mempalace"',
            f"        bridge: {yaml_quote(global_root + '/memory/mempalace-taxonomy.yaml')}",
            "    hook_contract:",
            "      session_start:",
            f"        - {yaml_quote(global_root + '/scripts/sync/preflight_check.py')}",
            f"        - {yaml_quote(global_root + '/scripts/sync/sync_all.py')}",
            "      session_end:",
            f"        - {yaml_quote(global_root + '/scripts/sync/postflight_sync.py')}",
            "      required_chat_markers:",
            '        - "[BOOT_OK]"',
            '        - "[SYNC_OK]"',
            '    bridge_context_entrypoint: "AGENTS.md"',
            "  codex:",
            "    preferred_bootstrap_order:",
        ]
    )
    lines.extend([f"      - {yaml_quote(item)}" for item in bootstrap_order])
    lines.extend(
        [
            "    write_routes:",
            f"      shared_logs_root: {yaml_quote(global_root + '/memory')}",
            "      stable_technical_route:",
            '        mechanism: "cc-skill-continuous-learning"',
            f"        bridge: {yaml_quote(global_root + '/memory/ki-registry.yaml')}",
            "      episodic_detail:",
            '        mechanism: "mempalace"',
            f"        bridge: {yaml_quote(global_root + '/memory/mempalace-taxonomy.yaml')}",
            "    hook_contract:",
            "      session_start:",
            f"        - {yaml_quote(global_root + '/scripts/sync/preflight_check.py')}",
            f"        - {yaml_quote(global_root + '/scripts/sync/sync_all.py')}",
            "      session_end:",
            f"        - {yaml_quote(global_root + '/scripts/sync/postflight_sync.py')}",
            "      required_chat_markers:",
            '        - "[BOOT_OK]"',
            '        - "[SYNC_OK]"',
            '    bridge_context_entrypoint: "AGENTS.md"',
            "project_overlay_policy:",
            '  mode: "read_existing_overlay_only"',
            f"  project_registry: {yaml_quote(global_root + '/projects/registry.yaml')}",
            "",
        ]
    )
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description="Render machine-specific YAML config files for Global Agent Fabric.")
    parser.add_argument("--env-file", type=Path, required=True)
    parser.add_argument("--output-root", type=Path, required=True)
    args = parser.parse_args()

    values = load_env_file(args.env_file)
    output_root = args.output_root
    (output_root / "projects").mkdir(parents=True, exist_ok=True)
    (output_root / "sync").mkdir(parents=True, exist_ok=True)

    (output_root / "projects" / "registry.yaml").write_text(
        render_projects_registry(values), encoding="utf-8"
    )
    (output_root / "sync" / "hook-policy.yaml").write_text(
        render_hook_policy(values), encoding="utf-8"
    )
    (output_root / "sync" / "runtime-map.yaml").write_text(
        render_runtime_map(values), encoding="utf-8"
    )
    (output_root / "memory" / "routes.yaml").write_text(
        render_memory_routes(values), encoding="utf-8"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
