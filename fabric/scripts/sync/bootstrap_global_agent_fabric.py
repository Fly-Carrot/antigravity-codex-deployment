#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

from path_config import resolve_global_root, resolve_path

DEFAULT_GLOBAL_ROOT = Path("/Users/david_chen/Antigravity_Skills/global-agent-fabric")
DEFAULT_AWESOME_SKILLS_ROOT = Path("/Users/david_chen/Antigravity_Skills/awesome-skills")
DEFAULT_GEMINI_RULE = Path("/Users/david_chen/.gemini/GEMINI.md")
DEFAULT_MCP_CONFIG = Path("/Users/david_chen/.gemini/antigravity/mcp_config.json")
DEFAULT_MCP_REGISTRY_SOURCE = Path("/Users/david_chen/Antigravity_Skills/global-agent-fabric/mcp/servers.yaml")

PROJECT_SPECS = [
    ("mcp-hub", "MCP_Hub", "AGF_PROJECT_MCP_HUB", Path("/Users/david_chen/Desktop/MCP_Hub"), None),
    ("project3.5", "Project3.5", "AGF_PROJECT_3_5", Path("/Users/david_chen/Desktop/Project3.5"), "ecology"),
    ("project4", "Project4", "AGF_PROJECT_4", Path("/Users/david_chen/Desktop/Project4"), "ecology"),
    ("project5", "Project5", "AGF_PROJECT_5", Path("/Users/david_chen/Desktop/Project5"), "ecology"),
    ("project5.5", "Project 5.5", "AGF_PROJECT_5_5", Path("/Users/david_chen/Desktop/Project 5.5"), "ecology"),
    ("project-design", "Project Design", "AGF_PROJECT_DESIGN", Path("/Users/david_chen/Desktop/Project Design"), "design"),
]


def build_projects() -> list[dict[str, Any]]:
    projects: list[dict[str, Any]] = []
    for project_id, name, env_name, default_path, rule_name in PROJECT_SPECS:
        project_path = resolve_path(None, [env_name], default=default_path) or default_path
        overlay_rules = [] if not rule_name else [str(project_path / ".agents" / "rules" / f"{rule_name}.md")]
        projects.append(
            {
                "id": project_id,
                "name": name,
                "path": str(project_path),
                "overlay_rules": overlay_rules,
            }
        )
    return projects


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8").strip()


def load_json(path: Path) -> Any:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def ensure_parent(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)


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
            elif isinstance(value, dict):
                lines.append(f"{space}{key}: {{}}")
            elif isinstance(value, list):
                lines.append(f"{space}{key}: []")
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


def write_yaml(path: Path, payload: Any) -> None:
    ensure_parent(path)
    path.write_text("\n".join(dump_yaml(payload)) + "\n", encoding="utf-8")


def sanitize_mcp(payload: dict[str, Any], registry_source: Path) -> dict[str, Any]:
    servers = []
    for server_id, config in sorted((payload.get("mcpServers") or {}).items()):
        env_refs = sorted((config.get("env") or {}).keys())
        args = list(config.get("args") or [])
        sanitized_args: list[str] = []
        skip_next = False
        for arg in args:
            if skip_next:
                skip_next = False
                continue
            if arg == "--api-key":
                api_key_env = f"{server_id.upper().replace('-', '_')}_API_KEY"
                if api_key_env not in env_refs:
                    env_refs.append(api_key_env)
                    env_refs.sort()
                sanitized_args.extend([arg, f"${{{api_key_env}}}"])
                skip_next = True
            elif arg in {"--token", "--auth-token"}:
                token_env = f"{server_id.upper().replace('-', '_')}_TOKEN"
                if token_env not in env_refs:
                    env_refs.append(token_env)
                    env_refs.sort()
                sanitized_args.extend([arg, f"${{{token_env}}}"])
                skip_next = True
            else:
                sanitized_args.append(arg)
        servers.append(
            {
                "id": server_id,
                "enabled": not bool(config.get("disabled", False)),
                "command": config.get("command"),
                "args": sanitized_args,
                "env_refs": env_refs,
                "owner": "global",
                "source": str(registry_source),
            }
        )
    return {"version": 1, "servers": servers}


def build_project_registry(projects: list[dict[str, Any]]) -> dict[str, Any]:
    return {
        "version": 1,
        "projects": [
            {
                "id": project["id"],
                "name": project["name"],
                "path": project["path"],
                "overlay_rules": project["overlay_rules"],
                "overlay_root": f"{project['path']}/.agents",
            }
            for project in projects
        ],
    }


def build_workflow_sources(awesome_skills_root: Path) -> dict[str, Any]:
    workflows_json = awesome_skills_root / "data" / "workflows.json"
    docs_workflows = awesome_skills_root / "docs" / "users" / "workflows.md"
    workflow_count = 0
    if workflows_json.exists():
        workflow_count = len((load_json(workflows_json) or {}).get("workflows", []))
    return {
        "version": 1,
        "sources": [
            {
                "id": "awesome-skills-json",
                "type": "json_catalog",
                "path": str(workflows_json),
                "workflow_count": workflow_count,
            },
            {
                "id": "awesome-skills-docs",
                "type": "markdown_reference",
                "path": str(docs_workflows),
            },
        ],
    }


def build_skills_sources(awesome_skills_root: Path, global_root: Path) -> dict[str, Any]:
    skills_root = awesome_skills_root / "skills"
    skill_count = len(list(skills_root.glob("*/SKILL.md"))) if skills_root.exists() else 0
    return {
        "version": 1,
        "sources": [
            {
                "id": "awesome-skills",
                "type": "skill_repo",
                "path": str(skills_root),
                "skill_count": skill_count,
            },
            {
                "id": "generated-shared-fabric-skills",
                "type": "generated_skill_repo",
                "path": str(global_root / "skills" / "generated"),
                "skill_count": 0,
            }
        ],
    }


def build_runtime_map(global_root: Path) -> dict[str, Any]:
    return {
        "version": 1,
        "global_root": str(global_root),
        "runtimes": {
            "antigravity": {
                "global_rule_source": str(DEFAULT_GEMINI_RULE),
                "mcp_source": str(DEFAULT_MCP_CONFIG),
                "skills_root": str(DEFAULT_AWESOME_SKILLS_ROOT / "skills"),
            },
            "codex": {
                "preferred_bootstrap_order": [
                    str(global_root / "rules" / "global" / "gemini-global.md"),
                    str(global_root / "projects" / "registry.yaml"),
                    str(global_root / "mcp" / "servers.yaml"),
                    str(global_root / "skills" / "sources.yaml"),
                ]
            },
        },
    }


def build_overlay_file(project: dict[str, Any]) -> dict[str, Any]:
    return {
        "project_id": project["id"],
        "project_name": project["name"],
        "project_root": project["path"],
        "overlay_root": f"{project['path']}/.agents",
        "inherits_from": "global-agent-fabric",
        "overlay_rules": project["overlay_rules"],
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Bootstrap a global agent fabric under Antigravity_Skills."
    )
    parser.add_argument("--global-root", type=Path, default=None)
    parser.add_argument("--awesome-skills-root", type=Path, default=None)
    parser.add_argument("--gemini-rule", type=Path, default=None)
    parser.add_argument("--mcp-config", type=Path, default=None)
    args = parser.parse_args()

    args.global_root = resolve_global_root(args.global_root)
    args.awesome_skills_root = resolve_path(args.awesome_skills_root, ["AGF_AWESOME_SKILLS_ROOT"], default=DEFAULT_AWESOME_SKILLS_ROOT) or DEFAULT_AWESOME_SKILLS_ROOT
    args.gemini_rule = resolve_path(args.gemini_rule, ["AGF_GEMINI_RULE"], default=DEFAULT_GEMINI_RULE) or DEFAULT_GEMINI_RULE
    args.mcp_config = resolve_path(args.mcp_config, ["AGF_ANTIGRAVITY_MCP_CONFIG"], default=DEFAULT_MCP_CONFIG) or DEFAULT_MCP_CONFIG

    global_root = args.global_root
    projects = build_projects()
    global_root.mkdir(parents=True, exist_ok=True)

    readme = f"""# Global Agent Fabric

This directory is the shared canonical state for Antigravity and Codex.

- Global rule source: `{args.gemini_rule}`
- Global skills/workflows source: `{args.awesome_skills_root}`
- Global MCP source: `{args.mcp_config}`

Project overlays are registered in `projects/registry.yaml`.
"""
    ensure_parent(global_root / "README.md")
    (global_root / "README.md").write_text(readme, encoding="utf-8")

    gemini_target = global_root / "rules" / "global" / "gemini-global.md"
    ensure_parent(gemini_target)
    gemini_content = "# Global Gemini Rule Mirror\n\n" + read_text(args.gemini_rule) + "\n"
    gemini_target.write_text(gemini_content, encoding="utf-8")

    write_yaml(global_root / "projects" / "registry.yaml", build_project_registry(projects))
    write_yaml(global_root / "workflows" / "sources.yaml", build_workflow_sources(args.awesome_skills_root))
    write_yaml(global_root / "skills" / "sources.yaml", build_skills_sources(args.awesome_skills_root, global_root))
    write_yaml(global_root / "mcp" / "servers.yaml", sanitize_mcp(load_json(args.mcp_config), global_root / "mcp" / "servers.yaml"))
    write_yaml(
        global_root / "mcp" / "secrets.example.yaml",
        {
            "version": 1,
            "env": {
                "ZOTERO_API_KEY": "<set-locally>",
                "ZOTERO_LIBRARY_ID": "<set-locally>",
                "CONTEXT7_API_KEY": "<set-locally>",
            },
        },
    )
    write_yaml(global_root / "sync" / "runtime-map.yaml", build_runtime_map(global_root))

    memory_root = global_root / "memory"
    memory_root.mkdir(parents=True, exist_ok=True)
    (memory_root / "profile.md").write_text(
        "# Global Profile\n\n- Owner: David\n- Purpose: shared global canonical state for Antigravity and Codex\n",
        encoding="utf-8",
    )
    for filename in ("decision-log.ndjson", "open-loops.ndjson", "handoffs.ndjson"):
        ensure_parent(memory_root / filename)
        (memory_root / filename).touch(exist_ok=True)

    overlays_root = global_root / "rules" / "overlays"
    overlays_root.mkdir(parents=True, exist_ok=True)
    for project in projects:
        write_yaml(overlays_root / f"{project['id']}.yaml", build_overlay_file(project))

    summary = {
        "global_root": str(global_root),
        "projects_registered": len(projects),
        "skills_source": str(args.awesome_skills_root / "skills"),
        "workflow_source": str(args.awesome_skills_root / "data" / "workflows.json"),
        "gemini_rule_source": str(args.gemini_rule),
        "mcp_source": str(args.mcp_config),
    }
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
