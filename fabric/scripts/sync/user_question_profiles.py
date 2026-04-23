#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import re
from collections import Counter, OrderedDict
from pathlib import Path
from typing import Any

from path_config import resolve_global_root, resolve_workspace

MANAGED_MARKER = "<!-- managed-by: global-agent-fabric user_question_profiles.py -->"
SKILL_MARKER = "<!-- generated-by: global-agent-fabric user_question_profiles.py -->"
PROFILE_FILENAME = "user-question-profiles.ndjson"
WORKSPACE_PROFILE_RELATIVE_PATH = ".agents/sync/user-question-profile.md"
GLOBAL_PROFILE_RELATIVE_PATH = "memory/user-question-profile.md"
GLOBAL_SKILL_RELATIVE_PATH = "skills/generated/user-questioning-profile/SKILL.md"
REQUIRED_PROFILE_FIELDS = [
    "focus_points",
    "question_patterns",
    "response_preferences",
    "reasoning_preferences",
    "recurring_themes",
    "frictions_or_anxieties",
]

STARTING_LENS_KEYWORDS = {
    "principles": ["principle", "first principle", "fundamental", "essence", "root cause", "本质", "原理"],
    "risks": ["risk", "failure mode", "failure", "tradeoff", "uncertainty", "fallback", "风险", "失败"],
    "implementation": ["implementation", "code", "build", "ship", "integrate", "落地", "实现"],
    "scope": ["scope", "boundary", "boundaries", "interface", "contract", "constraint", "冗余", "边界", "范围"],
}
EARLY_AMBIGUITY_KEYWORDS = [
    "ambiguity early",
    "prune ambiguity",
    "clarify first",
    "lock scope",
    "before implementation",
    "先澄清",
    "先锁定",
    "先对齐",
]
ITERATIVE_AMBIGUITY_KEYWORDS = [
    "iterate",
    "explore",
    "prototype",
    "brainstorm",
    "keep options open",
    "逐步",
    "探索",
    "迭代",
]
BOUNDARY_PROBING_KEYWORDS = {
    "failure_modes": ["failure mode", "failure", "break", "fallback", "edge case", "崩", "故障"],
    "architecture": ["architecture", "system design", "abstraction", "结构", "架构"],
    "scope": ["scope", "boundary", "contract", "ownership", "边界", "范围"],
    "compatibility": ["compat", "backward", "migration", "legacy", "兼容", "迁移"],
}


def normalize_items(values: list[str]) -> list[str]:
    ordered = OrderedDict[str, None]()
    for value in values:
        item = str(value).strip()
        if item:
            ordered[item] = None
    return list(ordered.keys())


def shorten(text: str, width: int = 180) -> str:
    clean = " ".join(str(text).split())
    if len(clean) <= width:
        return clean
    return clean[: width - 3].rstrip() + "..."


def ensure_parent(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)


def append_record(path: Path, record: dict[str, Any]) -> None:
    ensure_parent(path)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(record, ensure_ascii=False, sort_keys=True) + "\n")


def load_ndjson(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    records: list[dict[str, Any]] = []
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line:
            continue
        try:
            records.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return records


def parse_profile_json_arg(value: str | None) -> dict[str, Any] | None:
    if not value:
        return None
    text = value.strip()
    if not text:
        return None
    candidate = Path(text[1:] if text.startswith("@") else text).expanduser()
    if candidate.exists():
        text = candidate.read_text(encoding="utf-8")
    payload = json.loads(text)
    if not isinstance(payload, dict):
        raise SystemExit("User question profile payload must decode to a JSON object.")
    return payload


def _string_list(payload: dict[str, Any], key: str, required: bool = True) -> list[str]:
    value = payload.get(key)
    if value is None:
        if required:
            raise SystemExit(f"User question profile payload is missing required field: {key}")
        return []
    if isinstance(value, str):
        return normalize_items([value])
    if isinstance(value, list):
        return normalize_items([str(item) for item in value])
    raise SystemExit(f"User question profile field must be a string or list of strings: {key}")


def infer_questioning_dna(items: list[str]) -> dict[str, Any]:
    joined = " \n ".join(item.lower() for item in items if item.strip())
    starting_lenses = [
        category
        for category, keywords in STARTING_LENS_KEYWORDS.items()
        if any(keyword in joined for keyword in keywords)
    ]
    ambiguity_style = "unspecified"
    if any(keyword in joined for keyword in EARLY_AMBIGUITY_KEYWORDS):
        ambiguity_style = "prefers pruning ambiguity early"
    elif any(keyword in joined for keyword in ITERATIVE_AMBIGUITY_KEYWORDS):
        ambiguity_style = "comfortable with iterative ambiguity reduction"
    boundary_probes = [
        category
        for category, keywords in BOUNDARY_PROBING_KEYWORDS.items()
        if any(keyword in joined for keyword in keywords)
    ]
    return {
        "starting_lenses": starting_lenses,
        "ambiguity_style": ambiguity_style,
        "boundary_probes": boundary_probes,
    }


def build_user_question_profile_record(
    *,
    timestamp: str,
    agent: str,
    workspace: Path,
    task_id: str,
    task_summary: str,
    artifacts: list[str],
    payload: dict[str, Any],
) -> dict[str, Any]:
    normalized = {field: _string_list(payload, field) for field in REQUIRED_PROFILE_FIELDS}
    optional_summary = shorten(str(payload.get("summary") or "").strip(), 220)
    details_override = str(payload.get("details") or "").strip()
    all_items = [
        item
        for field in REQUIRED_PROFILE_FIELDS
        for item in normalized[field]
    ]
    dna = infer_questioning_dna(all_items)
    summary = optional_summary or (
        normalized["focus_points"][0]
        if normalized["focus_points"]
        else shorten(f"Questioning profile snapshot for {task_summary}", 220)
    )
    details = details_override or render_profile_details(
        summary=task_summary,
        profile_fields=normalized,
        questioning_dna=dna,
    )
    return {
        "timestamp": timestamp,
        "agent": agent,
        "workspace": str(workspace),
        "task_id": task_id,
        "summary": summary,
        "details": details,
        "artifacts": normalize_items(artifacts),
        "type": "user_question_profile_snapshot",
        "bundle_version": 1,
        "source_kind": "postflight_distillation",
        **normalized,
        "questioning_dna": dna,
    }


def render_profile_details(
    *,
    summary: str,
    profile_fields: dict[str, list[str]],
    questioning_dna: dict[str, Any],
) -> str:
    blocks = [
        "## Task Summary\n" + shorten(summary, 320),
    ]
    title_map = {
        "focus_points": "Focus Points",
        "question_patterns": "Question Patterns",
        "response_preferences": "Response Preferences",
        "reasoning_preferences": "Reasoning Preferences",
        "recurring_themes": "Recurring Themes",
        "frictions_or_anxieties": "Frictions or Anxieties",
    }
    for key in REQUIRED_PROFILE_FIELDS:
        values = profile_fields[key]
        if values:
            blocks.append("## " + title_map[key] + "\n" + "\n".join(f"- {item}" for item in values))
    dna_lines = []
    if questioning_dna.get("starting_lenses"):
        dna_lines.append("- Starts from: " + ", ".join(questioning_dna["starting_lenses"]))
    if questioning_dna.get("ambiguity_style") and questioning_dna["ambiguity_style"] != "unspecified":
        dna_lines.append("- Ambiguity handling: " + questioning_dna["ambiguity_style"])
    if questioning_dna.get("boundary_probes"):
        dna_lines.append("- Common probes: " + ", ".join(questioning_dna["boundary_probes"]))
    if dna_lines:
        blocks.append("## Questioning DNA\n" + "\n".join(dna_lines))
    return "\n\n".join(blocks).strip()


def workspace_profile_placeholder() -> str:
    return "\n".join(
        [
            MANAGED_MARKER,
            "# User Question Profile",
            "",
            "_No compiled user questioning profile is available for this workspace yet._",
            "",
            "This file is generated from distilled per-task user question snapshots.",
            "",
        ]
    )


def ensure_workspace_profile_stub(workspace: Path) -> Path:
    path = workspace / WORKSPACE_PROFILE_RELATIVE_PATH
    if path.exists():
        existing = path.read_text(encoding="utf-8")
        if MANAGED_MARKER not in existing:
            return path
    ensure_parent(path)
    if not path.exists():
        path.write_text(workspace_profile_placeholder(), encoding="utf-8")
    return path


def _canonicalize(text: str) -> str:
    return re.sub(r"\s+", " ", text.strip().lower())


def _rank_field(records: list[dict[str, Any]], key: str, limit: int = 6) -> list[tuple[str, int]]:
    counts: Counter[str] = Counter()
    labels: dict[str, str] = {}
    for record in records:
        for raw in record.get(key) or []:
            item = str(raw).strip()
            if not item:
                continue
            canonical = _canonicalize(item)
            counts[canonical] += 1
            labels.setdefault(canonical, item)
    return [(labels[key], count) for key, count in counts.most_common(limit)]


def _rank_dna(records: list[dict[str, Any]], key: str) -> list[tuple[str, int]]:
    counts: Counter[str] = Counter()
    for record in records:
        dna = record.get("questioning_dna") or {}
        values = dna.get(key)
        if isinstance(values, str):
            values = [values]
        for value in values or []:
            item = str(value).strip()
            if item and item != "unspecified":
                counts[item] += 1
    return counts.most_common()


def _ambiguity_tension(records: list[dict[str, Any]]) -> list[str]:
    labels = []
    for value, _count in _rank_dna(records, "starting_lenses"):
        labels.append(f"Switches between starting lenses such as {value} and other recurrent frames depending on the task.")
    ambiguity_styles = Counter()
    for record in records:
        dna = record.get("questioning_dna") or {}
        style = str(dna.get("ambiguity_style") or "").strip()
        if style and style != "unspecified":
            ambiguity_styles[style] += 1
    if len(ambiguity_styles) > 1:
        labels.append(
            "Shows variation in ambiguity handling across tasks: "
            + ", ".join(style for style, _count in ambiguity_styles.most_common())
            + "."
        )
    return normalize_items(labels)


def render_compiled_profile(
    *,
    title: str,
    records: list[dict[str, Any]],
    scope_label: str,
    compact: bool,
) -> str:
    if not records:
        return "\n".join(
            [
                MANAGED_MARKER,
                f"# {title}",
                "",
                f"_No distilled user question profile is available for {scope_label} yet._",
                "",
            ]
        )

    latest_timestamp = max(str(record.get("timestamp") or "") for record in records)
    workspaces = sorted({str(record.get("workspace") or "") for record in records if str(record.get("workspace") or "").strip()})
    focus_points = _rank_field(records, "focus_points")
    question_patterns = _rank_field(records, "question_patterns")
    response_preferences = _rank_field(records, "response_preferences")
    reasoning_preferences = _rank_field(records, "reasoning_preferences")
    recurring_themes = _rank_field(records, "recurring_themes")
    frictions = _rank_field(records, "frictions_or_anxieties")
    starting_lenses = _rank_dna(records, "starting_lenses")
    boundary_probes = _rank_dna(records, "boundary_probes")
    tensions = _ambiguity_tension(records)

    lines = [
        MANAGED_MARKER,
        f"# {title}",
        "",
        f"Compiled from `{len(records)}` distilled user-question snapshots across `{len(workspaces)}` workspace(s).",
        f"Last updated: `{latest_timestamp}`",
        "",
        "## Questioning DNA",
        "",
    ]
    has_dna_entry = False
    if starting_lenses:
        lines.append("- Starts from: " + ", ".join(f"{item} ({count})" for item, count in starting_lenses[:4]))
        has_dna_entry = True
    if boundary_probes:
        lines.append("- Common probes: " + ", ".join(f"{item} ({count})" for item, count in boundary_probes[:4]))
        has_dna_entry = True
    ambiguity_styles = sorted(
        {
            str((record.get("questioning_dna") or {}).get("ambiguity_style") or "").strip()
            for record in records
            if str((record.get("questioning_dna") or {}).get("ambiguity_style") or "").strip()
            and str((record.get("questioning_dna") or {}).get("ambiguity_style") or "").strip() != "unspecified"
        }
    )
    if ambiguity_styles:
        lines.append("- Ambiguity handling: " + "; ".join(ambiguity_styles))
        has_dna_entry = True
    if not has_dna_entry:
        lines.append("- No strong questioning DNA signal has been inferred yet.")

    def add_ranked_section(label: str, ranked: list[tuple[str, int]], max_items: int) -> None:
        lines.extend(["", f"## {label}", ""])
        if ranked:
            lines.extend([f"- {item} ({count})" for item, count in ranked[:max_items]])
        else:
            lines.append("- _None yet_")

    add_ranked_section("Core Focus Points", focus_points, 5)
    add_ranked_section("Question Patterns", question_patterns, 6 if not compact else 4)
    add_ranked_section("Response Preferences", response_preferences, 5 if not compact else 4)
    add_ranked_section("Reasoning Preferences", reasoning_preferences, 5 if not compact else 4)
    add_ranked_section("Recurring Themes", recurring_themes, 5 if not compact else 4)
    add_ranked_section("Frictions or Anxieties", frictions, 4)

    if tensions:
        lines.extend(["", "## Tensions and Variations", ""])
        lines.extend([f"- {item}" for item in tensions[:3]])

    if not compact:
        lines.extend(
            [
                "",
                "## Evidence Base",
                "",
                "- This profile is distilled-only; raw prompts are not retained as canonical memory by default.",
                "- Patterns strengthen when they recur across tasks or projects.",
            ]
        )

    lines.append("")
    return "\n".join(lines)


def render_profile_skill(global_profile_markdown: str) -> str:
    profile_body = global_profile_markdown.split("\n", 1)[1] if "\n" in global_profile_markdown else global_profile_markdown
    return "\n".join(
        [
            "---",
            "name: user-questioning-profile",
            "description: |",
            "  Auto-generated profile of the primary user's questioning habits and framing preferences.",
            "  Use when adapting explanation style, prioritizing likely concerns, or anticipating follow-up angles.",
            "---",
            "",
            SKILL_MARKER,
            "# User Questioning Profile",
            "",
            "## How To Use",
            "",
            "- Use this profile to frame answers around the user's recurring concerns and preferred reasoning style.",
            "- Prefer anticipating likely follow-up questions instead of waiting for them.",
            "- Treat tensions as real: preserve both sides instead of flattening them into a single style.",
            "- Do not pretend to know raw prompts that were never persisted; this is a distilled profile only.",
            "",
            profile_body.strip(),
            "",
        ]
    )


def compile_user_question_profiles(global_root: Path, workspace: Path | None = None) -> dict[str, str]:
    global_root = resolve_global_root(global_root)
    workspace = resolve_workspace(workspace) if workspace is not None else None
    records = load_ndjson(global_root / "memory" / PROFILE_FILENAME)

    global_profile = render_compiled_profile(
        title="User Question Profile",
        records=records,
        scope_label="the shared fabric",
        compact=False,
    )
    global_profile_path = global_root / GLOBAL_PROFILE_RELATIVE_PATH
    ensure_parent(global_profile_path)
    global_profile_path.write_text(global_profile, encoding="utf-8")

    global_skill_path = global_root / GLOBAL_SKILL_RELATIVE_PATH
    ensure_parent(global_skill_path)
    global_skill_path.write_text(render_profile_skill(global_profile), encoding="utf-8")

    outputs = {
        "global_profile": str(global_profile_path),
        "global_skill": str(global_skill_path),
    }

    if workspace is not None:
        workspace_records = [
            record for record in records if str(record.get("workspace") or "") == str(workspace)
        ]
        workspace_profile = render_compiled_profile(
            title="Workspace User Question Profile",
            records=workspace_records,
            scope_label=str(workspace),
            compact=True,
        )
        workspace_profile_path = workspace / WORKSPACE_PROFILE_RELATIVE_PATH
        ensure_parent(workspace_profile_path)
        workspace_profile_path.write_text(workspace_profile, encoding="utf-8")
        outputs["workspace_profile"] = str(workspace_profile_path)

    return outputs


def main() -> int:
    parser = argparse.ArgumentParser(description="Compile distilled user question profile snapshots into global and workspace-facing artifacts.")
    parser.add_argument("--global-root", type=Path, default=None)
    parser.add_argument("--workspace", type=Path, default=None)
    args = parser.parse_args()

    outputs = compile_user_question_profiles(args.global_root, args.workspace)
    print(json.dumps(outputs, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
