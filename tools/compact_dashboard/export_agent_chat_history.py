#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any

DEFAULT_CODEX_ROOT = Path.home() / ".codex"
DEFAULT_GEMINI_ROOT = Path.home() / ".gemini"
DEFAULT_VAULT_ROOT = Path.home() / "Library" / "Mobile Documents" / "iCloud~md~obsidian" / "Documents" / "Obsidian Memory"
DEFAULT_OUTPUT_DIR = "Agent Chat History"


@dataclass
class ExportedSession:
    runtime: str
    runtime_label: str
    session_id: str
    title: str
    started_at: str
    updated_at: str
    workspace: str
    source_path: Path
    output_path: Path


def _normalize_path(value: str | Path | None) -> str:
    if not value:
        return ""
    try:
        return str(Path(value).expanduser().resolve())
    except OSError:
        return str(Path(value).expanduser())


def _safe_name(value: str, fallback: str) -> str:
    cleaned = re.sub(r"[^\w\-. ]+", "_", value.strip(), flags=re.UNICODE)
    cleaned = re.sub(r"\s+", " ", cleaned).strip(" ._")
    return cleaned or fallback


def _read_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def _read_jsonl(path: Path) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line:
            continue
        try:
            payload = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(payload, dict):
            records.append(payload)
    return records


def _load_codex_thread_names(codex_root: Path) -> dict[str, str]:
    index_path = codex_root / "session_index.jsonl"
    names: dict[str, str] = {}
    if not index_path.exists():
        return names
    for item in _read_jsonl(index_path):
        session_id = str(item.get("id") or "").strip()
        thread_name = str(item.get("thread_name") or "").strip()
        if session_id and thread_name:
            names[session_id] = thread_name
    return names


def _codex_session_markdown(
    source_path: Path,
    *,
    workspace: str,
    thread_name: str,
) -> tuple[str, str, str, str]:
    records = _read_jsonl(source_path)
    if not records:
        raise ValueError(f"empty Codex transcript: {source_path}")

    meta = next((item for item in records if item.get("type") == "session_meta"), {})
    payload = meta.get("payload") if isinstance(meta.get("payload"), dict) else {}
    session_id = str(payload.get("id") or source_path.stem)
    started_at = str(payload.get("timestamp") or meta.get("timestamp") or "")
    updated_at = str(records[-1].get("timestamp") or started_at)
    title = thread_name or str(payload.get("cwd") or source_path.stem)

    lines = [
        "---",
        f'title: "{title.replace(chr(34), chr(39))}"',
        'runtime: "Codex"',
        f'session_id: "{session_id}"',
        f'workspace: "{workspace.replace(chr(34), chr(39))}"',
        f'source_path: "{str(source_path).replace(chr(34), chr(39))}"',
        f'started_at: "{started_at}"',
        f'updated_at: "{updated_at}"',
        "---",
        "",
        f"# {title}",
        "",
        f"- Runtime: `Codex`",
        f"- Session ID: `{session_id}`",
        f"- Workspace: `{workspace}`",
        f"- Source: `{source_path}`",
        "",
        "## Transcript",
        "",
    ]

    last_reasoning_timestamp = ""
    last_reasoning_items: list[str] = []

    def flush_reasoning() -> None:
        nonlocal last_reasoning_items, last_reasoning_timestamp
        if not last_reasoning_items:
            return
        lines.extend([f"### Codex Thinking · {last_reasoning_timestamp}", ""])
        lines.extend([f"- {item}" for item in last_reasoning_items])
        lines.append("")
        last_reasoning_items = []
        last_reasoning_timestamp = ""

    for record in records:
        timestamp = str(record.get("timestamp") or "")
        kind = str(record.get("type") or "")
        payload = record.get("payload") if isinstance(record.get("payload"), dict) else {}
        payload_type = str(payload.get("type") or "")

        if kind == "event_msg" and payload_type == "user_message":
            flush_reasoning()
            message = str(payload.get("message") or "").rstrip()
            if message:
                lines.extend([f"### User · {timestamp}", "", message, ""])
            continue

        if kind == "event_msg" and payload_type == "agent_message":
            flush_reasoning()
            message = str(payload.get("message") or "").rstrip()
            if message:
                lines.extend([f"### Codex · {timestamp}", "", message, ""])
            continue

        if kind == "response_item" and payload_type == "reasoning":
            summary_items = payload.get("summary") or []
            summaries = [
                str(item.get("text") or "").strip()
                for item in summary_items
                if isinstance(item, dict) and str(item.get("text") or "").strip()
            ]
            if summaries:
                if timestamp == last_reasoning_timestamp:
                    for item in summaries:
                        if item not in last_reasoning_items:
                            last_reasoning_items.append(item)
                else:
                    flush_reasoning()
                    last_reasoning_timestamp = timestamp
                    last_reasoning_items = summaries.copy()

    flush_reasoning()
    return session_id, title, started_at, updated_at, "\n".join(lines).rstrip() + "\n"


def _gemini_message_text(content: Any) -> str:
    if isinstance(content, str):
        return content.strip()
    if isinstance(content, list):
        parts: list[str] = []
        for item in content:
            if isinstance(item, dict):
                text = str(item.get("text") or "").strip()
                if text:
                    parts.append(text)
        return "\n\n".join(parts).strip()
    return ""


def _gemini_session_markdown(source_path: Path, *, workspace: str) -> tuple[str, str, str, str, str]:
    if source_path.suffix == ".jsonl":
        raw = source_path.read_text(encoding="utf-8")
        text_lines = [line.strip() for line in raw.splitlines() if line.strip()]
        session_id = source_path.stem
        title = source_path.stem
        return (
            session_id,
            title,
            "",
            "",
            "\n".join(
                [
                    "---",
                    f'title: "{title}"',
                    'runtime: "Gemini CLI"',
                    f'session_id: "{session_id}"',
                    f'workspace: "{workspace.replace(chr(34), chr(39))}"',
                    f'source_path: "{str(source_path).replace(chr(34), chr(39))}"',
                    "---",
                    "",
                    f"# {title}",
                    "",
                    "## Transcript",
                    "",
                    *text_lines,
                    "",
                ]
            ),
        )

    payload = _read_json(source_path)
    session_id = str(payload.get("sessionId") or source_path.stem)
    started_at = str(payload.get("startTime") or "")
    updated_at = str(payload.get("lastUpdated") or started_at)
    title = session_id
    messages = payload.get("messages") if isinstance(payload.get("messages"), list) else []

    lines = [
        "---",
        f'title: "{title}"',
        'runtime: "Gemini CLI"',
        f'session_id: "{session_id}"',
        f'workspace: "{workspace.replace(chr(34), chr(39))}"',
        f'source_path: "{str(source_path).replace(chr(34), chr(39))}"',
        f'started_at: "{started_at}"',
        f'updated_at: "{updated_at}"',
        "---",
        "",
        f"# {title}",
        "",
        f"- Runtime: `Gemini CLI`",
        f"- Session ID: `{session_id}`",
        f"- Workspace: `{workspace}`",
        f"- Source: `{source_path}`",
        "",
        "## Transcript",
        "",
    ]

    for message in messages:
        if not isinstance(message, dict):
            continue
        role = str(message.get("type") or "message")
        timestamp = str(message.get("timestamp") or "")
        heading = {
            "user": "User",
            "gemini": "Gemini CLI",
            "info": "Info",
        }.get(role, role.capitalize())
        text = _gemini_message_text(message.get("content"))
        if text:
            lines.extend([f"### {heading} · {timestamp}", "", text, ""])
        thoughts = message.get("thoughts") if isinstance(message.get("thoughts"), list) else []
        if thoughts:
            lines.extend([f"### Gemini Thinking · {timestamp}", ""])
            for thought in thoughts:
                if not isinstance(thought, dict):
                    continue
                subject = str(thought.get("subject") or "Thought").strip()
                description = str(thought.get("description") or "").strip()
                if description:
                    lines.append(f"- **{subject}:** {description}")
            lines.append("")

    return session_id, title, started_at, updated_at, "\n".join(lines).rstrip() + "\n"


def _codex_sessions_for_workspace(workspace: str, codex_root: Path, out_root: Path) -> list[ExportedSession]:
    thread_names = _load_codex_thread_names(codex_root)
    workspace_name = _safe_name(Path(workspace).name, "workspace")
    sessions: list[ExportedSession] = []
    session_candidates = sorted((codex_root / "sessions").glob("**/*.jsonl")) + sorted((codex_root / "archived_sessions").glob("*.jsonl"))
    seen_ids: set[str] = set()

    for source_path in session_candidates:
        records = _read_jsonl(source_path)
        if not records:
            continue
        meta = next((item for item in records if item.get("type") == "session_meta"), {})
        payload = meta.get("payload") if isinstance(meta.get("payload"), dict) else {}
        cwd = _normalize_path(payload.get("cwd"))
        if cwd != workspace:
            continue
        session_id = str(payload.get("id") or source_path.stem)
        if session_id in seen_ids:
            continue
        seen_ids.add(session_id)
        title = thread_names.get(session_id, "")
        _, rendered_title, started_at, updated_at, markdown = _codex_session_markdown(
            source_path,
            workspace=workspace,
            thread_name=title,
        )
        file_name = f"{session_id}.md"
        output_path = out_root / workspace_name / "Codex" / file_name
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(markdown, encoding="utf-8")
        sessions.append(
            ExportedSession(
                runtime="codex",
                runtime_label="Codex",
                session_id=session_id,
                title=rendered_title,
                started_at=started_at,
                updated_at=updated_at,
                workspace=workspace,
                source_path=source_path,
                output_path=output_path,
            )
        )
    return sessions


def _gemini_tmp_roots_for_workspace(workspace: str, gemini_root: Path) -> list[Path]:
    tmp_root = gemini_root / "tmp"
    if not tmp_root.exists():
        return []
    matches: list[Path] = []
    for project_root_marker in tmp_root.glob("*/.project_root"):
        try:
            project_root = _normalize_path(project_root_marker.read_text(encoding="utf-8").strip())
        except OSError:
            continue
        if project_root == workspace:
            matches.append(project_root_marker.parent)
    return matches


def _gemini_sessions_for_workspace(workspace: str, gemini_root: Path, out_root: Path) -> list[ExportedSession]:
    workspace_name = _safe_name(Path(workspace).name, "workspace")
    sessions: list[ExportedSession] = []
    for project_root in _gemini_tmp_roots_for_workspace(workspace, gemini_root):
        for source_path in sorted((project_root / "chats").glob("session-*.*")):
            try:
                session_id, title, started_at, updated_at, markdown = _gemini_session_markdown(
                    source_path,
                    workspace=workspace,
                )
            except (ValueError, json.JSONDecodeError):
                continue
            file_name = f"{session_id}.md"
            output_path = out_root / workspace_name / "Gemini CLI" / file_name
            output_path.parent.mkdir(parents=True, exist_ok=True)
            output_path.write_text(markdown, encoding="utf-8")
            sessions.append(
                ExportedSession(
                    runtime="gemini",
                    runtime_label="Gemini CLI",
                    session_id=session_id,
                    title=title,
                    started_at=started_at,
                    updated_at=updated_at,
                    workspace=workspace,
                    source_path=source_path,
                    output_path=output_path,
                )
            )
    return sessions


def _write_workspace_index(workspace: str, out_root: Path, sessions: list[ExportedSession]) -> Path:
    workspace_name = _safe_name(Path(workspace).name, "workspace")
    workspace_root = out_root / workspace_name
    workspace_root.mkdir(parents=True, exist_ok=True)
    lines = [
        f"# {Path(workspace).name} Agent Chat History",
        "",
        f"- Workspace: `{workspace}`",
        f"- Exported sessions: `{len(sessions)}`",
        "",
    ]
    grouped: dict[str, list[ExportedSession]] = {}
    for session in sessions:
        grouped.setdefault(session.runtime_label, []).append(session)
    for runtime in sorted(grouped.keys()):
        lines.extend([f"## {runtime}", ""])
        for session in sorted(grouped[runtime], key=lambda item: item.updated_at or item.started_at, reverse=True):
            relative_path = session.output_path.relative_to(workspace_root)
            label = session.title or session.session_id
            stamp = session.updated_at or session.started_at or ""
            lines.append(f"- [{label}]({relative_path.as_posix()}) · `{session.session_id}` · {stamp}")
        lines.append("")
    index_path = workspace_root / "index.md"
    index_path.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")
    return index_path


def export_chat_history(
    *,
    workspace: str | Path,
    vault_root: str | Path,
    output_dir: str,
    runtime: str,
    codex_root: str | Path,
    gemini_root: str | Path,
) -> dict[str, Any]:
    normalized_workspace = _normalize_path(workspace)
    if not normalized_workspace:
        raise ValueError("workspace is required")
    vault_root_path = Path(vault_root).expanduser()
    if not vault_root_path.exists():
        raise FileNotFoundError(f"vault root does not exist: {vault_root_path}")
    out_root = vault_root_path / output_dir
    out_root.mkdir(parents=True, exist_ok=True)

    sessions: list[ExportedSession] = []
    if runtime in {"both", "codex"}:
        sessions.extend(_codex_sessions_for_workspace(normalized_workspace, Path(codex_root).expanduser(), out_root))
    if runtime in {"both", "gemini"}:
        sessions.extend(_gemini_sessions_for_workspace(normalized_workspace, Path(gemini_root).expanduser(), out_root))

    index_path = _write_workspace_index(normalized_workspace, out_root, sessions)
    return {
        "workspace": normalized_workspace,
        "vault_root": str(vault_root_path),
        "output_root": str(out_root),
        "index_path": str(index_path),
        "runtime": runtime,
        "session_count": len(sessions),
        "sessions": [
            {
                "runtime": session.runtime_label,
                "session_id": session.session_id,
                "title": session.title,
                "started_at": session.started_at,
                "updated_at": session.updated_at,
                "source_path": str(session.source_path),
                "output_path": str(session.output_path),
            }
            for session in sorted(sessions, key=lambda item: (item.updated_at or item.started_at, item.runtime_label, item.session_id), reverse=True)
        ],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Export Codex and Gemini CLI chat transcripts into an Obsidian vault.")
    parser.add_argument("--workspace", required=True)
    parser.add_argument("--vault-root", default=str(DEFAULT_VAULT_ROOT))
    parser.add_argument("--output-dir", default=DEFAULT_OUTPUT_DIR)
    parser.add_argument("--runtime", choices=["both", "codex", "gemini"], default="both")
    parser.add_argument("--codex-root", default=str(DEFAULT_CODEX_ROOT))
    parser.add_argument("--gemini-root", default=str(DEFAULT_GEMINI_ROOT))
    args = parser.parse_args()

    payload = export_chat_history(
        workspace=args.workspace,
        vault_root=args.vault_root,
        output_dir=args.output_dir,
        runtime=args.runtime,
        codex_root=args.codex_root,
        gemini_root=args.gemini_root,
    )
    print(json.dumps(payload, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
