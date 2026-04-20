#!/usr/bin/env python3

from __future__ import annotations

import argparse
from pathlib import Path

from render_framework_config import load_env_file, require


def yaml_quote(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def render_paths(values: dict[str, str]) -> str:
    user_home = require(values, "AGF_USER_HOME")
    desktop_root = require(values, "AGF_DESKTOP_ROOT")
    global_root = require(values, "AGF_GLOBAL_ROOT")
    awesome_skills_root = require(values, "AGF_AWESOME_SKILLS_ROOT")
    gemini_root = require(values, "AGF_GEMINI_ROOT")
    gemini_settings = require(values, "AGF_GEMINI_SETTINGS")
    gemini_rule = require(values, "AGF_GEMINI_RULE")
    antigravity_mcp_config = require(values, "AGF_ANTIGRAVITY_MCP_CONFIG")
    antigravity_brain_root = require(values, "AGF_ANTIGRAVITY_BRAIN_ROOT")
    antigravity_history_root = require(values, "AGF_ANTIGRAVITY_HISTORY_ROOT")
    codex_root = require(values, "AGF_CODEX_ROOT")
    project_mcp_hub = require(values, "AGF_PROJECT_MCP_HUB")
    project_3_5 = require(values, "AGF_PROJECT_3_5")
    project_4 = require(values, "AGF_PROJECT_4")
    project_5 = require(values, "AGF_PROJECT_5")
    project_5_5 = require(values, "AGF_PROJECT_5_5")
    project_design = require(values, "AGF_PROJECT_DESIGN")

    lines = [
        "version: 1",
        "",
        "paths:",
        f"  user_home: {yaml_quote(user_home)}",
        f"  desktop_root: {yaml_quote(desktop_root)}",
        "",
        f"  global_root: {yaml_quote(global_root)}",
        f"  awesome_skills_root: {yaml_quote(awesome_skills_root)}",
        "",
        f"  gemini_root: {yaml_quote(gemini_root)}",
        f"  gemini_settings: {yaml_quote(gemini_settings)}",
        f"  gemini_rule: {yaml_quote(gemini_rule)}",
        f"  antigravity_mcp_config: {yaml_quote(antigravity_mcp_config)}",
        f"  antigravity_brain_root: {yaml_quote(antigravity_brain_root)}",
        f"  antigravity_history_root: {yaml_quote(antigravity_history_root)}",
        "",
        f"  codex_root: {yaml_quote(codex_root)}",
        "",
        "  project_roots:",
        f"    mcp_hub: {yaml_quote(project_mcp_hub)}",
        f"    project3_5: {yaml_quote(project_3_5)}",
        f"    project4: {yaml_quote(project_4)}",
        f"    project5: {yaml_quote(project_5)}",
        f"    project5_5: {yaml_quote(project_5_5)}",
        f"    project_design: {yaml_quote(project_design)}",
        "",
        "derived:",
        f"  receipts_log: {yaml_quote(global_root + '/sync/receipts.ndjson')}",
        f"  import_state_file: {yaml_quote(global_root + '/sync/import-state.json')}",
        f"  shared_memory_root: {yaml_quote(global_root + '/memory')}",
        f"  workflow_import_root: {yaml_quote(global_root + '/workflows/imported')}",
        "",
    ]
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description="Render a concrete install/paths.yaml from an env file.")
    parser.add_argument("--env-file", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    values = load_env_file(args.env_file)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(render_paths(values), encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
