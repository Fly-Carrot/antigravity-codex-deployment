import json
import tempfile
import unittest
from pathlib import Path

from tools.compact_dashboard.export_agent_chat_history import export_chat_history


class ExportAgentChatHistoryTests(unittest.TestCase):
    def test_exports_codex_and_gemini_sessions_into_obsidian_workspace_folder(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            workspace = root / "workspace"
            workspace.mkdir()
            vault_root = root / "vault"
            vault_root.mkdir()
            codex_root = root / ".codex"
            gemini_root = root / ".gemini"
            (codex_root / "archived_sessions").mkdir(parents=True)
            (gemini_root / "tmp" / "workspace" / "chats").mkdir(parents=True)

            session_id = "codex-session-1"
            (codex_root / "session_index.jsonl").write_text(
                json.dumps({"id": session_id, "thread_name": "Codex Transcript"}) + "\n",
                encoding="utf-8",
            )
            codex_lines = [
                {
                    "timestamp": "2026-04-27T01:00:00Z",
                    "type": "session_meta",
                    "payload": {
                        "id": session_id,
                        "timestamp": "2026-04-27T01:00:00Z",
                        "cwd": str(workspace),
                    },
                },
                {
                    "timestamp": "2026-04-27T01:00:01Z",
                    "type": "event_msg",
                    "payload": {
                        "type": "user_message",
                        "message": "Please inspect the workspace.",
                    },
                },
                {
                    "timestamp": "2026-04-27T01:00:02Z",
                    "type": "event_msg",
                    "payload": {
                        "type": "agent_message",
                        "message": "Inspecting now.",
                    },
                },
                {
                    "timestamp": "2026-04-27T01:00:03Z",
                    "type": "response_item",
                    "payload": {
                        "type": "function_call",
                        "name": "exec_command",
                        "arguments": "{\"cmd\":\"pwd\"}",
                    },
                },
                {
                    "timestamp": "2026-04-27T01:00:04Z",
                    "type": "response_item",
                    "payload": {
                        "type": "function_call_output",
                        "output": "/tmp/workspace",
                    },
                },
            ]
            (codex_root / "archived_sessions" / "rollout-codex-session-1.jsonl").write_text(
                "\n".join(json.dumps(item, ensure_ascii=False) for item in codex_lines) + "\n",
                encoding="utf-8",
            )

            gemini_project = gemini_root / "tmp" / "workspace"
            (gemini_project / ".project_root").write_text(str(workspace), encoding="utf-8")
            gemini_payload = {
                "sessionId": "gemini-session-1",
                "startTime": "2026-04-27T02:00:00Z",
                "lastUpdated": "2026-04-27T02:05:00Z",
                "messages": [
                    {
                        "timestamp": "2026-04-27T02:00:10Z",
                        "type": "user",
                        "content": [{"text": "Summarize the current project."}],
                    },
                    {
                        "timestamp": "2026-04-27T02:01:00Z",
                        "type": "gemini",
                        "content": "Here is the current project summary.",
                        "toolCalls": [
                            {
                                "name": "run_shell_command",
                                "args": {"command": "pwd"},
                                "result": [{"functionResponse": {"response": {"output": "/tmp/workspace"}}}],
                            }
                        ],
                    },
                ],
            }
            (gemini_project / "chats" / "session-2026-04-27T02-00-gemini-session-1.json").write_text(
                json.dumps(gemini_payload, ensure_ascii=False, indent=2),
                encoding="utf-8",
            )

            payload = export_chat_history(
                workspace=workspace,
                vault_root=vault_root,
                output_dir="Agent Chat History",
                runtime="both",
                codex_root=codex_root,
                gemini_root=gemini_root,
            )

            self.assertEqual(payload["session_count"], 2)
            self.assertTrue((vault_root / "Agent Chat History" / "workspace" / "Codex" / f"{session_id}.md").exists())
            self.assertTrue((vault_root / "Agent Chat History" / "workspace" / "Gemini CLI" / "gemini-session-1.md").exists())
            index_text = (vault_root / "Agent Chat History" / "workspace" / "index.md").read_text(encoding="utf-8")
            self.assertIn("Codex Transcript", index_text)
            self.assertIn("gemini-session-1", index_text)
            codex_text = (vault_root / "Agent Chat History" / "workspace" / "Codex" / f"{session_id}.md").read_text(encoding="utf-8")
            self.assertIn("Please inspect the workspace.", codex_text)
            self.assertNotIn("Tool Call · exec_command", codex_text)
            self.assertNotIn('{"cmd":"pwd"}', codex_text)
            gemini_text = (vault_root / "Agent Chat History" / "workspace" / "Gemini CLI" / "gemini-session-1.md").read_text(encoding="utf-8")
            self.assertIn("Summarize the current project.", gemini_text)
            self.assertNotIn("Tool Result", gemini_text)
            self.assertNotIn('"command": "pwd"', gemini_text)

    def test_reexport_overwrites_same_session_file(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            workspace = root / "workspace"
            workspace.mkdir()
            vault_root = root / "vault"
            vault_root.mkdir()
            codex_root = root / ".codex"
            gemini_root = root / ".gemini"
            (codex_root / "archived_sessions").mkdir(parents=True)
            (gemini_root / "tmp").mkdir(parents=True)

            session_id = "codex-session-2"
            (codex_root / "session_index.jsonl").write_text(
                json.dumps({"id": session_id, "thread_name": "Codex Transcript"}) + "\n",
                encoding="utf-8",
            )
            transcript_path = codex_root / "archived_sessions" / "rollout-codex-session-2.jsonl"

            def write_transcript(agent_text: str) -> None:
                transcript_path.write_text(
                    "\n".join(
                        [
                            json.dumps(
                                {
                                    "timestamp": "2026-04-27T03:00:00Z",
                                    "type": "session_meta",
                                    "payload": {
                                        "id": session_id,
                                        "timestamp": "2026-04-27T03:00:00Z",
                                        "cwd": str(workspace),
                                    },
                                }
                            ),
                            json.dumps(
                                {
                                    "timestamp": "2026-04-27T03:00:01Z",
                                    "type": "event_msg",
                                    "payload": {
                                        "type": "agent_message",
                                        "message": agent_text,
                                    },
                                }
                            ),
                        ]
                    )
                    + "\n",
                    encoding="utf-8",
                )

            write_transcript("First export")
            export_chat_history(
                workspace=workspace,
                vault_root=vault_root,
                output_dir="Agent Chat History",
                runtime="codex",
                codex_root=codex_root,
                gemini_root=gemini_root,
            )
            output_path = vault_root / "Agent Chat History" / "workspace" / "Codex" / f"{session_id}.md"
            self.assertIn("First export", output_path.read_text(encoding="utf-8"))

            write_transcript("Updated export")
            export_chat_history(
                workspace=workspace,
                vault_root=vault_root,
                output_dir="Agent Chat History",
                runtime="codex",
                codex_root=codex_root,
                gemini_root=gemini_root,
            )
            self.assertIn("Updated export", output_path.read_text(encoding="utf-8"))
            self.assertNotIn("First export", output_path.read_text(encoding="utf-8"))

    def test_exports_live_codex_session_from_sessions_tree(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            workspace = root / "workspace"
            workspace.mkdir()
            vault_root = root / "vault"
            vault_root.mkdir()
            codex_root = root / ".codex"
            gemini_root = root / ".gemini"
            live_dir = codex_root / "sessions" / "2026" / "04" / "27"
            live_dir.mkdir(parents=True)
            (gemini_root / "tmp").mkdir(parents=True)

            session_id = "live-codex-session"
            (codex_root / "session_index.jsonl").write_text(
                json.dumps({"id": session_id, "thread_name": "Live Codex Transcript"}) + "\n",
                encoding="utf-8",
            )
            (live_dir / "rollout-live-codex-session.jsonl").write_text(
                "\n".join(
                    [
                        json.dumps(
                            {
                                "timestamp": "2026-04-27T04:00:00Z",
                                "type": "session_meta",
                                "payload": {
                                    "id": session_id,
                                    "timestamp": "2026-04-27T04:00:00Z",
                                    "cwd": str(workspace),
                                },
                            }
                        ),
                        json.dumps(
                            {
                                "timestamp": "2026-04-27T04:00:01Z",
                                "type": "event_msg",
                                "payload": {
                                    "type": "agent_message",
                                    "message": "Live session export works.",
                                },
                            }
                        ),
                    ]
                )
                + "\n",
                encoding="utf-8",
            )

            payload = export_chat_history(
                workspace=workspace,
                vault_root=vault_root,
                output_dir="Agent Chat History",
                runtime="codex",
                codex_root=codex_root,
                gemini_root=gemini_root,
            )

            self.assertEqual(payload["session_count"], 1)
            output_path = vault_root / "Agent Chat History" / "workspace" / "Codex" / f"{session_id}.md"
            self.assertTrue(output_path.exists())
            self.assertIn("Live session export works.", output_path.read_text(encoding="utf-8"))

    def test_keeps_reasoning_but_omits_heavy_tool_payloads(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            workspace = root / "workspace"
            workspace.mkdir()
            vault_root = root / "vault"
            vault_root.mkdir()
            codex_root = root / ".codex"
            gemini_root = root / ".gemini"
            live_dir = codex_root / "sessions" / "2026" / "04" / "27"
            live_dir.mkdir(parents=True)
            (gemini_root / "tmp").mkdir(parents=True)

            session_id = "reasoning-codex-session"
            (codex_root / "session_index.jsonl").write_text(
                json.dumps({"id": session_id, "thread_name": "Reasoning Session"}) + "\n",
                encoding="utf-8",
            )
            (live_dir / "rollout-reasoning-codex-session.jsonl").write_text(
                "\n".join(
                    [
                        json.dumps(
                            {
                                "timestamp": "2026-04-27T05:00:00Z",
                                "type": "session_meta",
                                "payload": {
                                    "id": session_id,
                                    "timestamp": "2026-04-27T05:00:00Z",
                                    "cwd": str(workspace),
                                },
                            }
                        ),
                        json.dumps(
                            {
                                "timestamp": "2026-04-27T05:00:01Z",
                                "type": "response_item",
                                "payload": {
                                    "type": "reasoning",
                                    "summary": [{"text": "Comparing options before answering."}],
                                },
                            }
                        ),
                        json.dumps(
                            {
                                "timestamp": "2026-04-27T05:00:02Z",
                                "type": "response_item",
                                "payload": {
                                    "type": "function_call",
                                    "name": "exec_command",
                                    "arguments": "{\"cmd\":\"very large payload\"}",
                                },
                            }
                        ),
                        json.dumps(
                            {
                                "timestamp": "2026-04-27T05:00:03Z",
                                "type": "event_msg",
                                "payload": {
                                    "type": "agent_message",
                                    "message": "Here is the concise answer.",
                                },
                            }
                        ),
                    ]
                )
                + "\n",
                encoding="utf-8",
            )

            export_chat_history(
                workspace=workspace,
                vault_root=vault_root,
                output_dir="Agent Chat History",
                runtime="codex",
                codex_root=codex_root,
                gemini_root=gemini_root,
            )
            output_text = (vault_root / "Agent Chat History" / "workspace" / "Codex" / f"{session_id}.md").read_text(encoding="utf-8")
            self.assertIn("Codex Thinking", output_text)
            self.assertIn("Comparing options before answering.", output_text)
            self.assertIn("Here is the concise answer.", output_text)
            self.assertNotIn("very large payload", output_text)


if __name__ == "__main__":
    unittest.main()
