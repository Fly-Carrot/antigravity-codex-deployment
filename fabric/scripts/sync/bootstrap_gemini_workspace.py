#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import os
import re
from pathlib import Path
from typing import Any

from path_config import resolve_global_root, resolve_path

MANAGED_MARKER = "<!-- managed-by: global-agent-fabric bootstrap_gemini_workspace.py -->"
SETTINGS_MANAGED_BY = "global-agent-fabric"
DEFAULT_GEMINI_SETTINGS = Path.home() / ".gemini" / "settings.json"


def parse_scalar(text: str) -> Any:
    text = text.strip()
    if not text:
        return ""
    if text in {"[]", "{}"}:
        return [] if text == "[]" else {}
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return text


def parse_project_registry(path: Path) -> list[dict[str, Any]]:
    lines = path.read_text(encoding="utf-8").splitlines()
    projects: list[dict[str, Any]] = []
    in_projects = False
    i = 0
    while i < len(lines):
        line = lines[i]
        stripped = line.strip()
        if stripped == "projects:":
            in_projects = True
            i += 1
            continue
        if not in_projects:
            i += 1
            continue
        if line.startswith("  -"):
            project: dict[str, Any] = {}
            i += 1
            while i < len(lines):
                raw = lines[i]
                if raw.startswith("  -") or (raw and not raw.startswith("    ")):
                    break
                if not raw.strip():
                    i += 1
                    continue
                if raw.startswith("    overlay_rules:"):
                    i += 1
                    rules: list[str] = []
                    while i < len(lines) and lines[i].startswith("      - "):
                        rules.append(str(parse_scalar(lines[i].strip()[2:].strip())))
                        i += 1
                    project["overlay_rules"] = rules
                    continue
                match = re.match(r"^\s{4}([^:]+):\s*(.*)$", raw)
                if match:
                    key, value = match.groups()
                    project[key] = parse_scalar(value)
                i += 1
            project.setdefault("overlay_rules", [])
            projects.append(project)
            continue
        i += 1
    return projects


def parse_servers_yaml(path: Path) -> list[dict[str, Any]]:
    lines = path.read_text(encoding="utf-8").splitlines()
    servers: list[dict[str, Any]] = []
    in_servers = False
    i = 0
    while i < len(lines):
        line = lines[i]
        stripped = line.strip()
        if stripped == "servers:":
            in_servers = True
            i += 1
            continue
        if not in_servers:
            i += 1
            continue
        if line.startswith("  -"):
            server: dict[str, Any] = {}
            i += 1
            while i < len(lines):
                raw = lines[i]
                if raw.startswith("  -") or (raw and not raw.startswith("    ")):
                    break
                if not raw.strip():
                    i += 1
                    continue
                if raw.startswith("    args:") or raw.startswith("    env_refs:"):
                    key = raw.strip()[:-1]
                    i += 1
                    values: list[Any] = []
                    while i < len(lines) and lines[i].startswith("      - "):
                        values.append(parse_scalar(lines[i].strip()[2:].strip()))
                        i += 1
                    server[key] = values
                    continue
                match = re.match(r"^\s{4}([^:]+):\s*(.*)$", raw)
                if match:
                    key, value = match.groups()
                    server[key] = parse_scalar(value)
                i += 1
            server.setdefault("args", [])
            server.setdefault("env_refs", [])
            servers.append(server)
            continue
        i += 1
    return servers


def parse_env_yaml(path: Path) -> dict[str, str]:
    if not path.exists():
        return {}
    lines = path.read_text(encoding="utf-8").splitlines()
    env: dict[str, str] = {}
    in_env = False
    for raw in lines:
        if raw.strip() == "env:":
            in_env = True
            continue
        if not in_env:
            continue
        if raw and not raw.startswith("  "):
            break
        stripped = raw.strip()
        if not stripped:
            continue
        match = re.match(r"^([^:]+):\s*(.*)$", stripped)
        if match:
            key, value = match.groups()
            env[key] = str(parse_scalar(value))
    return env


def read_settings(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {}
    return json.loads(path.read_text(encoding="utf-8"))


def write_settings(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def merge_context_filenames(settings: dict[str, Any]) -> None:
    context = settings.setdefault("context", {})
    existing = context.get("fileName", [])
    if isinstance(existing, str):
        ordered = [existing]
    elif isinstance(existing, list):
        ordered = [str(item) for item in existing]
    else:
        ordered = []
    for name in ["AGENTS.md", "GEMINI.md"]:
        if name not in ordered:
            ordered.append(name)
    context["fileName"] = ordered


def resolve_env_value(name: str, secret_env: dict[str, str], secrets_file: Path) -> str:
    if name == "PATH":
        return os.environ.get("PATH", "")
    if name in secret_env and secret_env[name]:
        return secret_env[name]
    value = os.environ.get(name)
    if value:
        return value
    raise SystemExit(
        f"Missing required MCP environment value: {name}. "
        f"Set it in {secrets_file} or export it in the shell."
    )


def substitute_arg_placeholders(args: list[Any], resolved_env: dict[str, str]) -> list[str]:
    rendered: list[str] = []
    placeholder_pattern = re.compile(r"^\$\{([A-Z0-9_]+)\}$")
    for arg in args:
        text = str(arg)
        match = placeholder_pattern.match(text)
        if match:
            key = match.group(1)
            if key not in resolved_env:
                raise SystemExit(f"Missing value for MCP arg placeholder: {key}")
            rendered.append(resolved_env[key])
        else:
            rendered.append(text)
    return rendered


def build_gemini_mcp_servers(
    servers: list[dict[str, Any]], secret_env: dict[str, str], secrets_file: Path
) -> dict[str, Any]:
    rendered: dict[str, Any] = {}
    for server in servers:
        if not server.get("enabled", False):
            continue
        env_refs = [str(item) for item in server.get("env_refs", [])]
        resolved_env = {name: resolve_env_value(name, secret_env, secrets_file) for name in env_refs}
        payload: dict[str, Any] = {"command": str(server["command"])}
        args = [str(item) for item in server.get("args", [])]
        if args:
            payload["args"] = substitute_arg_placeholders(args, resolved_env)
        if resolved_env:
            payload["env"] = resolved_env
        rendered[str(server["id"])] = payload
    return rendered


def relative_import(from_root: Path, target: Path) -> str:
    rel = target.relative_to(from_root).as_posix()
    return f"@./{rel}"


def slugify_workspace_name(name: str) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")
    return slug or "workspace"


def resolve_workspace_project(registry: list[dict[str, Any]], workspace: Path) -> dict[str, Any]:
    project = next(
        (item for item in registry if Path(str(item["path"])).expanduser().resolve() == workspace),
        None,
    )
    if project is None:
        return {
            "id": slugify_workspace_name(workspace.name),
            "name": workspace.name,
            "path": str(workspace),
            "overlay_rules": [],
            "overlay_root": str(workspace / ".agents"),
            "registered": False,
        }
    resolved = dict(project)
    resolved.setdefault("name", workspace.name)
    resolved.setdefault("path", str(workspace))
    resolved.setdefault("overlay_rules", [])
    resolved.setdefault("overlay_root", str(workspace / ".agents"))
    resolved["registered"] = True
    return resolved


def render_workspace_agents(project: dict[str, Any], workspace: Path) -> str:
    lines = [
        MANAGED_MARKER,
        "# Workspace Context Entry",
        "",
        "This file is the project-scoped context bridge for Gemini CLI and Codex.",
        "",
        "## Scope",
        "",
        "- Global shared instructions continue to load from `~/.gemini/GEMINI.md`.",
        "- This file adds only workspace-specific context.",
        "- Shared fabric remains the canonical source for project registry, memory routing, MCP definitions, skills, and workflow registries.",
        "",
        "## Workspace Imports",
        "",
    ]
    overlay_rules = [Path(item) for item in project.get("overlay_rules", [])]
    if overlay_rules:
        for overlay in overlay_rules:
            if not overlay.exists():
                raise SystemExit(f"Overlay rule missing from registry: {overlay}")
            lines.append(relative_import(workspace, overlay))
    else:
        lines.append("_No additional project overlay rules are registered for this workspace._")
    lines.extend(
        [
            "",
            "## Optional Deep Context",
            "",
            "- `./.agents/sync/codex-context.md` remains available as deep generated session context.",
            "- It is intentionally not auto-imported by this thin workspace bridge.",
            "",
        ]
    )
    return "\n".join(lines)


def write_workspace_agents(path: Path, content: str) -> None:
    if path.exists():
        existing = path.read_text(encoding="utf-8")
        if MANAGED_MARKER not in existing:
            raise SystemExit(
                f"Refusing to overwrite unmanaged AGENTS.md at {path}. "
                "Please migrate it manually or add the managed marker."
            )
    path.write_text(content, encoding="utf-8")


def bootstrap_workspace(
    *,
    workspace: Path,
    global_root: Path,
    gemini_settings: Path,
    secrets_file: Path,
) -> dict[str, Any]:
    registry = parse_project_registry(global_root / "projects" / "registry.yaml")
    project = resolve_workspace_project(registry, workspace)

    settings = read_settings(gemini_settings)
    merge_context_filenames(settings)

    secret_env = parse_env_yaml(secrets_file)
    servers = parse_servers_yaml(global_root / "mcp" / "servers.yaml")
    rendered_mcp = build_gemini_mcp_servers(servers, secret_env, secrets_file)
    settings["mcpServers"] = rendered_mcp
    settings.setdefault("globalAgentFabric", {})["managedBy"] = SETTINGS_MANAGED_BY
    settings["globalAgentFabric"]["workspaceBootstrap"] = {
        "workspace": str(workspace),
        "projectId": str(project["id"]),
        "globalRoot": str(global_root),
        "registered": bool(project.get("registered", False)),
    }

    write_settings(gemini_settings, settings)

    agents_path = workspace / "AGENTS.md"
    write_workspace_agents(agents_path, render_workspace_agents(project, workspace))

    return {
        "workspace": str(workspace),
        "project_id": project["id"],
        "registered": bool(project.get("registered", False)),
        "gemini_settings": str(gemini_settings),
        "agents_file": str(agents_path),
        "mcp_servers": sorted(rendered_mcp.keys()),
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Bootstrap Gemini CLI workspace context and MCP settings from shared fabric."
    )
    parser.add_argument("--workspace", type=Path, required=True)
    parser.add_argument("--global-root", type=Path, default=None)
    parser.add_argument("--gemini-settings", type=Path, default=None)
    parser.add_argument("--secrets-file", type=Path, default=None)
    args = parser.parse_args()

    workspace = args.workspace.expanduser().resolve()
    global_root = resolve_global_root(args.global_root)
    gemini_settings = (
        resolve_path(args.gemini_settings, ["AGF_GEMINI_SETTINGS"], default=DEFAULT_GEMINI_SETTINGS)
        or DEFAULT_GEMINI_SETTINGS
    )
    secrets_file = args.secrets_file or (global_root / "mcp" / "secrets.yaml")
    summary = bootstrap_workspace(
        workspace=workspace,
        global_root=global_root,
        gemini_settings=gemini_settings,
        secrets_file=secrets_file,
    )
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
