#!/usr/bin/env python3

from __future__ import annotations

import os
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
INFERRED_GLOBAL_ROOT = SCRIPT_DIR.parent.parent


def _strip_quotes(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in {'"', "'"}:
        return value[1:-1]
    return value


def _load_env_file(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    if not path.exists():
        return values
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = _strip_quotes(value)
    return values


def _merged_env() -> dict[str, str]:
    merged = dict(os.environ)
    env_file = merged.get("AGF_ENV_FILE")
    if env_file:
        merged = {**_load_env_file(Path(env_file).expanduser()), **merged}
    return merged


def resolve_path(cli_value: Path | None, env_names: list[str], default: Path | None = None) -> Path | None:
    if cli_value is not None:
        return cli_value
    env = _merged_env()
    for name in env_names:
        value = env.get(name)
        if value:
            return Path(value).expanduser()
    return default


def resolve_global_root(cli_value: Path | None) -> Path:
    return resolve_path(cli_value, ["AGF_GLOBAL_ROOT"], default=INFERRED_GLOBAL_ROOT) or INFERRED_GLOBAL_ROOT


def resolve_workspace(cli_value: Path | None) -> Path:
    return resolve_path(
        cli_value,
        ["AGF_DEFAULT_WORKSPACE", "AGF_PROJECT_4", "AGF_PROJECT_MCP_HUB"],
        default=Path.cwd(),
    ) or Path.cwd()
