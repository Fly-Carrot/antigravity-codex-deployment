import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from dashboard_data import build_state


class DashboardDataTests(unittest.TestCase):
    def _write(self, path: Path, content: str) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")

    def _write_registry(self, root: Path, projects: list[tuple[str, str]]) -> None:
        lines = ["version: 1", "projects:"]
        for name, path in projects:
            lines.extend(
                [
                    "  -",
                    f'    id: "{name.lower().replace(" ", "-")}"',
                    f'    name: "{name}"',
                    f'    path: "{path}"',
                    "    overlay_rules: []",
                    f'    overlay_root: "{path}/.agents"',
                ]
            )
        self._write(root / "projects" / "registry.yaml", "\n".join(lines) + "\n")

    def _base_fixture(self, root: Path, workspace: Path) -> Path:
        self._write(
            root / "mcp" / "servers.yaml",
            "\n".join(
                [
                    "version: 1",
                    "servers:",
                    "  -",
                    '    id: "context7"',
                    "    enabled: true",
                    '    command: "/bin/true"',
                    "    args: []",
                    "    env_refs: []",
                    "  -",
                    '    id: "qgis"',
                    "    enabled: false",
                    '    command: "/bin/false"',
                    "    args: []",
                    "    env_refs: []",
                ]
            )
            + "\n",
        )
        settings_path = root / "settings.json"
        settings_path.write_text(
            json.dumps({"mcpServers": {"context7": {}, "notebooklm": {}}}, indent=2),
            encoding="utf-8",
        )
        self._write_registry(root, [(workspace.name, str(workspace))])
        return settings_path

    def test_build_state_uses_exact_phase_and_exact_sync_audit(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            workspace = root / "MCP_Hub"
            workspace.mkdir()
            settings_path = self._base_fixture(root, workspace)
            self._write(
                root / "sync" / "receipts.ndjson",
                "\n".join(
                    [
                        json.dumps(
                            {
                                "agent": "codex",
                                "status_marker": "[BOOT_OK]",
                                "task_id": "task-live",
                                "timestamp": "2026-04-20T06:00:00Z",
                                "workspace": str(workspace),
                            }
                        ),
                        json.dumps(
                            {
                                "agent": "codex",
                                "status_marker": "[SYNC_OK]",
                                "task_id": "task-live",
                                "timestamp": "2026-04-20T06:08:00Z",
                                "summary": "dashboard sync complete",
                                "workspace": str(workspace),
                            }
                        ),
                    ]
                )
                + "\n",
            )
            self._write(
                root / "memory" / "handoffs.ndjson",
                json.dumps(
                    {
                        "task_id": "task-live",
                        "summary": "workspace handoff summary",
                        "timestamp": "2026-04-20T06:08:00Z",
                        "workspace": str(workspace),
                    }
                )
                + "\n",
            )
            self._write(
                root / "memory" / "decision-log.ndjson",
                json.dumps(
                    {
                        "task_id": "task-live",
                        "summary": "Persist workspace bootstrap decision",
                        "details": "Use workspace-first VSCode tasks instead of a separate launcher.",
                        "timestamp": "2026-04-20T06:08:00Z",
                        "workspace": str(workspace),
                        "artifacts": [str(workspace / ".vscode" / "tasks.json")],
                    }
                )
                + "\n",
            )
            self._write(
                root / "memory" / "promoted-learnings.ndjson",
                json.dumps(
                    {
                        "task_id": "task-live",
                        "summary": "Snapshots should carry sync record drill-down payloads.",
                        "details": "This supports clickable sync delta UI.",
                        "timestamp": "2026-04-20T06:08:00Z",
                        "workspace": str(workspace),
                        "route": "stable_technical_route",
                        "mechanism": "cc-skill-continuous-learning",
                    }
                )
                + "\n",
            )
            self._write(
                root / "sync" / "task_phases.ndjson",
                json.dumps(
                    {
                        "agent": "codex",
                        "task_id": "task-live",
                        "timestamp": "2026-04-20T06:07:00Z",
                        "workspace": str(workspace),
                        "phase_key": "report",
                        "phase_label": "回奏",
                        "note": "reporting dashboard work",
                    }
                )
                + "\n",
            )
            self._write(
                root / "sync" / "learning_receipts.ndjson",
                json.dumps(
                    {
                        "agent": "codex",
                        "task_id": "task-live",
                        "timestamp": "2026-04-20T06:08:00Z",
                        "workspace": str(workspace),
                        "writes": {
                            "receipts": 1,
                            "handoffs": 1,
                            "decision_log": 1,
                            "open_loops": 0,
                            "mempalace_records": 1,
                            "promoted_learnings": 1,
                        },
                        "learned_items": ["Phase logging works", "Dashboard now shows sync delta"],
                        "skipped_items": ["No open loop to record"],
                        "source_summary": "dashboard sync complete",
                    }
                )
                + "\n",
            )

            state = build_state(workspace=workspace, global_root=root, gemini_settings=settings_path)

            self.assertEqual(state.project_name, "MCP_Hub")
            self.assertEqual(state.workspace_mode, "pinned")
            self.assertEqual(state.runtime, "codex")
            self.assertEqual(state.lifecycle_phase, "SYNCED")
            self.assertEqual(state.task_id, "task-live")
            self.assertEqual(state.boot_status, "OK")
            self.assertEqual(state.sync_status, "OK")
            self.assertEqual(state.six_stage_current, "")
            self.assertEqual(state.six_stage_completed, ["route", "plan", "review", "dispatch", "execute", "report"])
            self.assertEqual(state.phase_source, "exact")
            self.assertEqual(state.sync_audit_source, "exact")
            self.assertEqual(state.attention_state, "healthy")
            self.assertEqual(state.last_sync_delta.learned_items[0], "Phase logging works")
            self.assertEqual(state.last_sync_delta.writes_count_by_target["promoted_learnings"], 1)
            self.assertEqual({item.target for item in state.last_sync_delta.records}, {"receipts", "handoffs", "decision_log", "promoted_learnings"})
            self.assertEqual(state.last_sync_delta.records[0].title, "Learning Receipt")
            self.assertEqual(state.project_memory_counts["receipts"], 1)
            self.assertGreaterEqual(len(state.project_memory_records), 4)
            self.assertTrue(state.current_task_health.has_learning_receipt)
            self.assertEqual(state.active_mcp_count, 2)
            self.assertEqual(state.enabled_registry_count, 1)
            self.assertEqual(state.disabled_registry_count, 1)
            self.assertEqual(state.available_workspaces[0].source, "active")

    def test_build_state_exposes_bridge_metadata_for_current_task(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            workspace = root / "MCP_Hub"
            workspace.mkdir()
            settings_path = self._base_fixture(root, workspace)
            self._write(
                root / "sync" / "receipts.ndjson",
                "\n".join(
                    [
                        json.dumps(
                            {
                                "agent": "codex",
                                "status_marker": "[BOOT_OK]",
                                "task_id": "task-bridge",
                                "timestamp": "2026-04-20T06:00:00Z",
                                "workspace": str(workspace),
                            }
                        ),
                        json.dumps(
                            {
                                "agent": "codex",
                                "task_id": "task-bridge",
                                "timestamp": "2026-04-20T06:01:00Z",
                                "workspace": str(workspace),
                                "hook": "multicli_bridge",
                                "bridge_session_id": "bridge-codex-to-gemini-demo",
                                "bridge_mode": "handoff",
                                "origin_runtime": "codex",
                                "target_runtime": "gemini",
                                "context_entrypoint": "AGENTS.md",
                            }
                        ),
                    ]
                )
                + "\n",
            )
            self._write(
                root / "memory" / "handoffs.ndjson",
                json.dumps(
                    {
                        "task_id": "task-bridge",
                        "summary": "Codex handed this task to Gemini",
                        "timestamp": "2026-04-20T06:03:00Z",
                        "workspace": str(workspace),
                        "bridge_session_id": "bridge-codex-to-gemini-demo",
                        "bridge_mode": "handoff",
                        "origin_runtime": "codex",
                        "target_runtime": "gemini",
                    }
                )
                + "\n",
            )

            state = build_state(workspace=workspace, global_root=root, gemini_settings=settings_path)

            self.assertTrue(state.is_bridged)
            self.assertEqual(state.bridge_session_id, "bridge-codex-to-gemini-demo")
            self.assertEqual(state.bridge_mode, "handoff")
            self.assertEqual(state.origin_runtime, "codex")
            self.assertEqual(state.target_runtime, "gemini")
            bridge_handoff = next(item for item in state.project_memory_records if item.task_id == "task-bridge")
            self.assertTrue(bridge_handoff.is_bridged)
            self.assertEqual(bridge_handoff.bridge_session_id, "bridge-codex-to-gemini-demo")
            self.assertEqual(bridge_handoff.origin_runtime, "codex")
            self.assertEqual(bridge_handoff.target_runtime, "gemini")

    def test_build_state_includes_user_question_profile_views(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            workspace = root / "Project4"
            workspace.mkdir()
            settings_path = self._base_fixture(root, workspace)
            self._write(
                root / "sync" / "receipts.ndjson",
                json.dumps(
                    {
                        "agent": "codex",
                        "status_marker": "[SYNC_OK]",
                        "task_id": "task-profile",
                        "timestamp": "2026-04-22T01:00:00Z",
                        "workspace": str(workspace),
                    }
                )
                + "\n",
            )
            self._write(
                root / "memory" / "user-question-profiles.ndjson",
                "\n".join(
                    [
                        json.dumps(
                            {
                                "agent": "codex",
                                "task_id": "task-a",
                                "timestamp": "2026-04-21T08:00:00Z",
                                "workspace": str(workspace),
                            }
                        ),
                        json.dumps(
                            {
                                "agent": "codex",
                                "task_id": "task-b",
                                "timestamp": "2026-04-21T09:00:00Z",
                                "workspace": str(root / "Elsewhere"),
                            }
                        ),
                    ]
                )
                + "\n",
            )
            self._write(
                root / "memory" / "user-question-profile.md",
                "\n".join(
                    [
                        "# Global User Question Profile",
                        "",
                        "Compiled from `2` distilled user-question snapshots across `2` workspace(s).",
                        "Last updated: `2026-04-22T01:00:00Z`",
                        "",
                        "## Questioning DNA",
                        "",
                        "- Starts from: risks (2), scope (1)",
                    ]
                )
                + "\n",
            )
            self._write(
                workspace / ".agents" / "sync" / "user-question-profile.md",
                "\n".join(
                    [
                        "# Workspace User Question Profile",
                        "",
                        "Compiled from `1` distilled user-question snapshots across `1` workspace(s).",
                        "Last updated: `2026-04-22T01:00:00Z`",
                        "",
                        "## Focus Points",
                        "",
                        "- Shared memory correctness (1)",
                    ]
                )
                + "\n",
            )

            state = build_state(workspace=workspace, global_root=root, gemini_settings=settings_path)

            self.assertEqual(state.user_question_profile.snapshot_count, 2)
            self.assertEqual(state.user_question_profile.workspace_snapshot_count, 1)
            self.assertEqual(state.user_question_profile.global_profile.summary, "Compiled from `2` distilled user-question snapshots across `2` workspace(s).")
            self.assertEqual(state.user_question_profile.global_profile.updated_at, "2026-04-22T01:00:00Z")
            self.assertIn("Starts from: risks", state.user_question_profile.global_profile.preview)
            self.assertEqual(state.user_question_profile.workspace_profile.summary, "Compiled from `1` distilled user-question snapshots across `1` workspace(s).")
            self.assertIn("Shared memory correctness", state.user_question_profile.workspace_profile.preview)

    def test_project_memory_prefers_rich_bundle_over_legacy_duplicate(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            workspace = root / "Project4"
            workspace.mkdir()
            settings_path = self._base_fixture(root, workspace)
            self._write(
                root / "sync" / "receipts.ndjson",
                json.dumps(
                    {
                        "agent": "codex",
                        "status_marker": "[BOOT_OK]",
                        "task_id": "task-memory",
                        "timestamp": "2026-04-21T06:00:00Z",
                        "workspace": str(workspace),
                    }
                )
                + "\n",
            )
            self._write(
                root / "memory" / "handoffs.ndjson",
                "\n".join(
                    [
                        json.dumps(
                            {
                                "task_id": "task-memory",
                                "summary": "legacy import handoff",
                                "timestamp": "2026-04-21T06:01:00Z",
                                "workspace": str(workspace),
                                "type": "handoff_import",
                            }
                        ),
                        json.dumps(
                            {
                                "task_id": "task-memory",
                                "summary": "rich bundle handoff",
                                "details": "Expanded handoff details.",
                                "timestamp": "2026-04-21T06:02:00Z",
                                "workspace": str(workspace),
                                "type": "historical_handoff_bundle",
                                "bundle_version": 2,
                            }
                        ),
                    ]
                )
                + "\n",
            )
            self._write(
                root / "sync" / "learning_receipts.ndjson",
                "\n".join(
                    [
                        json.dumps(
                            {
                                "task_id": "task-memory",
                                "summary": "legacy receipt",
                                "timestamp": "2026-04-21T06:01:00Z",
                                "workspace": str(workspace),
                            }
                        ),
                        json.dumps(
                            {
                                "task_id": "task-memory",
                                "summary": "rich receipt",
                                "timestamp": "2026-04-21T06:02:00Z",
                                "workspace": str(workspace),
                                "type": "historical_backfill_receipt",
                                "bundle_version": 2,
                            }
                        ),
                    ]
                )
                + "\n",
            )

            state = build_state(workspace=workspace, global_root=root, gemini_settings=settings_path)

            handoffs = [item for item in state.project_memory_records if item.lane == "handoffs"]
            receipts = [item for item in state.project_memory_records if item.lane == "receipts"]
            self.assertEqual(len(handoffs), 1)
            self.assertEqual(handoffs[0].type, "historical_handoff_bundle")
            self.assertEqual(len(receipts), 1)
            self.assertEqual(receipts[0].type, "historical_backfill_receipt")
            self.assertEqual(state.project_memory_counts["handoffs"], 1)
            self.assertEqual(state.project_memory_counts["receipts"], 1)

    def test_build_state_falls_back_to_waiting_sync_delta_for_active_task(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            workspace = root / "MCP_Hub"
            workspace.mkdir()
            settings_path = self._base_fixture(root, workspace)
            self._write(
                root / "sync" / "receipts.ndjson",
                json.dumps(
                    {
                        "agent": "codex",
                        "status_marker": "[BOOT_OK]",
                        "task_id": "task-live",
                        "timestamp": "2026-04-20T06:00:00Z",
                        "workspace": str(workspace),
                    }
                )
                + "\n",
            )

            state = build_state(workspace=workspace, global_root=root, gemini_settings=settings_path)

            self.assertEqual(state.six_stage_current, "execute")
            self.assertEqual(state.workspace_mode, "pinned")
            self.assertEqual(state.phase_source, "heuristic")
            self.assertEqual(state.sync_audit_source, "none")
            self.assertEqual(state.attention_state, "active_pending_sync")
            self.assertEqual(state.last_sync_delta.source_summary, "Waiting for postflight sync.")
            self.assertIn("phase source = heuristic", state.alerts)

    def test_build_state_prefers_latest_task_and_infers_missing_learning_receipt(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            workspace = root / "MCP_Hub"
            workspace.mkdir()
            settings_path = self._base_fixture(root, workspace)
            self._write(
                root / "sync" / "receipts.ndjson",
                "\n".join(
                    [
                        json.dumps(
                            {
                                "agent": "codex",
                                "status_marker": "[BOOT_OK]",
                                "task_id": "task-stale",
                                "timestamp": "2026-04-20T05:00:00Z",
                                "workspace": str(workspace),
                            }
                        ),
                        json.dumps(
                            {
                                "agent": "codex",
                                "status_marker": "[BOOT_OK]",
                                "task_id": "task-fresh",
                                "timestamp": "2026-04-20T06:00:00Z",
                                "workspace": str(workspace),
                            }
                        ),
                        json.dumps(
                            {
                                "agent": "codex",
                                "status_marker": "[SYNC_OK]",
                                "task_id": "task-fresh",
                                "timestamp": "2026-04-20T06:10:00Z",
                                "summary": "fresh task synced",
                                "workspace": str(workspace),
                            }
                        ),
                    ]
                )
                + "\n",
            )
            self._write(
                root / "memory" / "handoffs.ndjson",
                json.dumps(
                    {
                        "task_id": "task-fresh",
                        "summary": "fresh workspace handoff",
                        "timestamp": "2026-04-20T06:11:00Z",
                        "workspace": str(workspace),
                    }
                )
                + "\n",
            )

            state = build_state(workspace=workspace, global_root=root, gemini_settings=settings_path)

            self.assertEqual(state.task_id, "task-fresh")
            self.assertEqual(state.sync_status, "OK")
            self.assertEqual(state.six_stage_current, "")
            self.assertEqual(state.sync_audit_source, "inferred")
            self.assertEqual(state.attention_state, "missing_learning_receipt")
            self.assertEqual(state.last_sync_delta.writes_count_by_target["handoffs"], 1)
            self.assertIn("latest sync is missing an explicit learning receipt", state.alerts)

    def test_build_state_marks_synced_without_learning_when_receipt_is_empty(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            workspace = root / "MCP_Hub"
            workspace.mkdir()
            settings_path = self._base_fixture(root, workspace)
            self._write(
                root / "sync" / "receipts.ndjson",
                "\n".join(
                    [
                        json.dumps(
                            {
                                "agent": "codex",
                                "status_marker": "[BOOT_OK]",
                                "task_id": "task-empty",
                                "timestamp": "2026-04-20T06:00:00Z",
                                "workspace": str(workspace),
                            }
                        ),
                        json.dumps(
                            {
                                "agent": "codex",
                                "status_marker": "[SYNC_OK]",
                                "task_id": "task-empty",
                                "timestamp": "2026-04-20T06:02:00Z",
                                "summary": "empty learning sync",
                                "workspace": str(workspace),
                            }
                        ),
                    ]
                )
                + "\n",
            )
            self._write(
                root / "sync" / "learning_receipts.ndjson",
                json.dumps(
                    {
                        "agent": "codex",
                        "task_id": "task-empty",
                        "timestamp": "2026-04-20T06:02:00Z",
                        "workspace": str(workspace),
                        "writes": {"receipts": 1, "handoffs": 1},
                        "learned_items": [],
                        "skipped_items": ["No durable knowledge this turn"],
                        "source_summary": "empty learning sync",
                    }
                )
                + "\n",
            )

            state = build_state(workspace=workspace, global_root=root, gemini_settings=settings_path)

            self.assertEqual(state.attention_state, "synced_without_learning")
            self.assertEqual(state.sync_audit_source, "exact")
            self.assertEqual(state.last_sync_delta.learned_items, [])
            self.assertIn("latest sync recorded no learned items", state.alerts)

    def test_build_state_auto_selects_latest_active_workspace(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            workspace_a = root / "MCP_Hub"
            workspace_b = root / "antigravity-codex-deployment"
            workspace_a.mkdir()
            workspace_b.mkdir()
            settings_path = self._base_fixture(root, workspace_a)
            self._write(
                root / "sync" / "receipts.ndjson",
                "\n".join(
                    [
                        json.dumps(
                            {
                                "agent": "codex",
                                "status_marker": "[SYNC_OK]",
                                "task_id": "task-a",
                                "timestamp": "2026-04-20T06:00:00Z",
                                "summary": "older workspace synced",
                                "workspace": str(workspace_a),
                            }
                        ),
                        json.dumps(
                            {
                                "agent": "gemini",
                                "status_marker": "[BOOT_OK]",
                                "task_id": "task-b",
                                "timestamp": "2026-04-20T06:10:00Z",
                                "workspace": str(workspace_b),
                            }
                        ),
                    ]
                )
                + "\n",
            )

            state = build_state(workspace=None, global_root=root, gemini_settings=settings_path)

            self.assertEqual(Path(state.workspace), workspace_b.resolve())
            self.assertEqual(state.workspace_mode, "auto")
            self.assertEqual(state.project_name, "antigravity-codex-deployment")
            self.assertEqual(state.runtime, "gemini")
            self.assertEqual(state.task_id, "task-b")
            self.assertIn("workspace source = auto", state.alerts)

    def test_build_state_merges_active_and_registered_workspaces(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            workspace_active = root / "MCP_Hub"
            workspace_registered = root / "Project5"
            workspace_active.mkdir()
            workspace_registered.mkdir()
            settings_path = self._base_fixture(root, workspace_active)
            self._write_registry(root, [("MCP_Hub", str(workspace_active)), ("Project5", str(workspace_registered))])
            self._write(
                root / "sync" / "receipts.ndjson",
                json.dumps(
                    {
                        "agent": "codex",
                        "status_marker": "[SYNC_OK]",
                        "task_id": "task-active",
                        "timestamp": "2026-04-20T06:10:00Z",
                        "summary": "active workspace synced",
                        "workspace": str(workspace_active),
                    }
                )
                + "\n",
            )

            state = build_state(workspace=None, global_root=root, gemini_settings=settings_path)

            self.assertEqual(state.workspace_mode, "auto")
            self.assertEqual([item.label for item in state.available_workspaces], ["MCP_Hub", "Project5"])
            self.assertEqual([item.source for item in state.available_workspaces], ["active", "registered"])
            self.assertEqual(state.available_workspaces[0].last_seen, "2026-04-20T06:10:00Z")

    def test_build_state_auto_ignores_missing_latest_workspace(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            workspace_live = root / "MCP_Hub"
            workspace_missing = root / "Shixi"
            workspace_live.mkdir()
            settings_path = self._base_fixture(root, workspace_live)
            self._write(
                root / "sync" / "receipts.ndjson",
                "\n".join(
                    [
                        json.dumps(
                            {
                                "agent": "codex",
                                "status_marker": "[SYNC_OK]",
                                "task_id": "task-live",
                                "timestamp": "2026-04-20T06:00:00Z",
                                "summary": "live workspace synced",
                                "workspace": str(workspace_live),
                            }
                        ),
                        json.dumps(
                            {
                                "agent": "codex",
                                "status_marker": "[SYNC_OK]",
                                "task_id": "task-missing",
                                "timestamp": "2026-04-20T06:10:00Z",
                                "summary": "missing workspace synced",
                                "workspace": str(workspace_missing),
                            }
                        ),
                    ]
                )
                + "\n",
            )

            state = build_state(workspace=None, global_root=root, gemini_settings=settings_path)

            self.assertEqual(Path(state.workspace), workspace_live.resolve())
            self.assertEqual(state.project_name, "MCP_Hub")
            self.assertEqual([item.label for item in state.available_workspaces], ["MCP_Hub"])

    def test_build_state_filters_missing_workspace_candidates_but_keeps_manual_pin(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            workspace_live = root / "MCP_Hub"
            workspace_missing = root / "Shixi"
            registered_missing = root / "Project5"
            workspace_live.mkdir()
            settings_path = self._base_fixture(root, workspace_live)
            self._write_registry(root, [("MCP_Hub", str(workspace_live)), ("Project5", str(registered_missing))])
            self._write(
                root / "sync" / "receipts.ndjson",
                "\n".join(
                    [
                        json.dumps(
                            {
                                "agent": "codex",
                                "status_marker": "[SYNC_OK]",
                                "task_id": "task-live",
                                "timestamp": "2026-04-20T06:00:00Z",
                                "summary": "live workspace synced",
                                "workspace": str(workspace_live),
                            }
                        ),
                        json.dumps(
                            {
                                "agent": "codex",
                                "status_marker": "[SYNC_OK]",
                                "task_id": "task-missing",
                                "timestamp": "2026-04-20T06:10:00Z",
                                "summary": "missing workspace synced",
                                "workspace": str(workspace_missing),
                            }
                        ),
                    ]
                )
                + "\n",
            )

            state = build_state(workspace=workspace_missing, global_root=root, gemini_settings=settings_path)

            self.assertEqual([item.label for item in state.available_workspaces], ["Shixi", "MCP_Hub"])
            self.assertEqual([item.source for item in state.available_workspaces], ["manual", "active"])

    def test_build_state_supports_manual_pinned_workspace(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            workspace = root / "manual-workspace"
            workspace.mkdir()
            settings_path = self._base_fixture(root, root / "MCP_Hub")
            (root / "MCP_Hub").mkdir(exist_ok=True)

            state = build_state(workspace=workspace, global_root=root, gemini_settings=settings_path)

            self.assertEqual(state.workspace_mode, "pinned")
            self.assertEqual(Path(state.workspace), workspace.resolve())
            self.assertEqual(state.lifecycle_phase, "IDLE")
            self.assertEqual(state.available_workspaces[0].source, "manual")
            self.assertEqual(state.available_workspaces[0].label, "manual-workspace")


if __name__ == "__main__":
    unittest.main()
