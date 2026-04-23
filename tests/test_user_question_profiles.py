import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SYNC_DIR = Path(__file__).resolve().parents[1] / "fabric" / "scripts" / "sync"
MODULE_PATH = SYNC_DIR / "user_question_profiles.py"
EXPORT_SCRIPT = SYNC_DIR / "export_codex_context.py"
if str(SYNC_DIR) not in sys.path:
    sys.path.insert(0, str(SYNC_DIR))

spec = importlib.util.spec_from_file_location("user_question_profiles", MODULE_PATH)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
sys.modules[spec.name] = module
spec.loader.exec_module(module)


class UserQuestionProfilesTests(unittest.TestCase):
    def _append_snapshot(
        self,
        root: Path,
        workspace: Path,
        task_id: str,
        *,
        focus_points: list[str],
        question_patterns: list[str],
        response_preferences: list[str],
        reasoning_preferences: list[str],
        recurring_themes: list[str],
        frictions_or_anxieties: list[str],
    ) -> None:
        record = module.build_user_question_profile_record(
            timestamp="2026-04-22T00:00:00Z",
            agent="codex",
            workspace=workspace,
            task_id=task_id,
            task_summary=f"Task {task_id}",
            artifacts=[],
            payload={
                "focus_points": focus_points,
                "question_patterns": question_patterns,
                "response_preferences": response_preferences,
                "reasoning_preferences": reasoning_preferences,
                "recurring_themes": recurring_themes,
                "frictions_or_anxieties": frictions_or_anxieties,
            },
        )
        module.append_record(root / "memory" / module.PROFILE_FILENAME, record)

    def test_compile_profiles_generates_global_workspace_and_skill_outputs(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            workspace = root / "workspace-a"
            other_workspace = root / "workspace-b"
            workspace.mkdir()
            other_workspace.mkdir()

            self._append_snapshot(
                root,
                workspace,
                "task-a1",
                focus_points=["Architecture boundaries"],
                question_patterns=["Starts from first principles before implementation"],
                response_preferences=["Wants concise but structurally clear answers"],
                reasoning_preferences=["Prefers ambiguity pruned before implementation"],
                recurring_themes=["Shared memory correctness"],
                frictions_or_anxieties=["Worries about hidden regressions"],
            )
            self._append_snapshot(
                root,
                workspace,
                "task-a2",
                focus_points=["Architecture boundaries"],
                question_patterns=["Presses on failure modes and fallback behavior"],
                response_preferences=["Wants concise but structurally clear answers"],
                reasoning_preferences=["Sometimes wants implementation-level detail immediately"],
                recurring_themes=["Shared memory correctness"],
                frictions_or_anxieties=["Worries about hidden regressions"],
            )
            self._append_snapshot(
                root,
                other_workspace,
                "task-b1",
                focus_points=["Release polish"],
                question_patterns=["Asks for public-facing clarity"],
                response_preferences=["Wants product-level summaries"],
                reasoning_preferences=["Prefers ambiguity pruned before implementation"],
                recurring_themes=["Presentation quality"],
                frictions_or_anxieties=["Dislikes rough edges in public output"],
            )

            outputs = module.compile_user_question_profiles(root, workspace)

            global_profile = Path(outputs["global_profile"]).read_text(encoding="utf-8")
            self.assertIn("Compiled from `3` distilled user-question snapshots", global_profile)
            self.assertIn("Architecture boundaries (2)", global_profile)
            self.assertIn("Tensions and Variations", global_profile)
            self.assertIn("Switches between starting lenses", global_profile)

            workspace_profile = Path(outputs["workspace_profile"]).read_text(encoding="utf-8")
            self.assertIn("Workspace User Question Profile", workspace_profile)
            self.assertIn("Shared memory correctness (2)", workspace_profile)
            self.assertNotIn("Presentation quality", workspace_profile)

            skill = Path(outputs["global_skill"]).read_text(encoding="utf-8")
            self.assertIn("name: user-questioning-profile", skill)
            self.assertIn("Do not pretend to know raw prompts", skill)

    def test_export_codex_context_includes_global_and_workspace_user_profiles(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            workspace = root / "workspace"
            workspace.mkdir()

            module.ensure_workspace_profile_stub(workspace)
            self._append_snapshot(
                root,
                workspace,
                "task-a1",
                focus_points=["Architecture boundaries"],
                question_patterns=["Starts from first principles before implementation"],
                response_preferences=["Wants concise but structurally clear answers"],
                reasoning_preferences=["Prefers ambiguity pruned before implementation"],
                recurring_themes=["Shared memory correctness"],
                frictions_or_anxieties=["Worries about hidden regressions"],
            )
            module.compile_user_question_profiles(root, workspace)

            result = subprocess.run(
                [
                    sys.executable,
                    str(EXPORT_SCRIPT),
                    "--global-root",
                    str(root),
                    "--workspace",
                    str(workspace),
                ],
                check=True,
                capture_output=True,
                text=True,
            )
            output_path = Path(result.stdout.strip())
            rendered = output_path.read_text(encoding="utf-8")
            self.assertIn("## Global User Question Profile", rendered)
            self.assertIn("## Workspace User Question Profile", rendered)
            self.assertIn("Architecture boundaries", rendered)


if __name__ == "__main__":
    unittest.main()
