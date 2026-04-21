import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).resolve().parents[1] / "install" / "bootstrap_vscode_workspace.py"
spec = importlib.util.spec_from_file_location("bootstrap_vscode_workspace", MODULE_PATH)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
sys.modules[spec.name] = module
spec.loader.exec_module(module)


class BootstrapVSCodeWorkspaceTests(unittest.TestCase):
    def _write(self, path: Path, content: str) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")

    def _make_registry(self, root: Path, workspace: Path) -> None:
        content = (
            "version: 1\n"
            "projects:\n"
            "  -\n"
            '    id: "workspace"\n'
            '    name: "Workspace"\n'
            f'    path: "{workspace}"\n'
            "    overlay_rules: []\n"
            f'    overlay_root: "{workspace / ".agents"}"\n'
        )
        self._write(root / "projects" / "registry.yaml", content)

    def _make_servers_and_secrets(self, root: Path) -> None:
        servers = (
            "version: 1\n"
            "servers:\n"
            "  -\n"
            '    id: "context7"\n'
            "    enabled: true\n"
            '    command: "/bin/echo"\n'
            "    args: []\n"
            "    env_refs:\n"
            '      - "PATH"\n'
            '    owner: "global"\n'
            '    scope: "docs"\n'
            '    source: "/tmp/servers.yaml"\n'
        )
        secrets = "version: 1\nenv:\n"
        self._write(root / "mcp" / "servers.yaml", servers)
        self._write(root / "mcp" / "secrets.yaml", secrets)

    def test_render_tasks_supports_boot_sync_postflight(self) -> None:
        tasks = module.render_tasks(Path("/tmp/global-agent-fabric"), ["codex", "gemini"])
        labels = [task["label"] for task in tasks["tasks"]]
        input_ids = [item["id"] for item in tasks["inputs"]]

        self.assertIn("Shared Fabric: Boot Current Workspace", labels)
        self.assertIn("Shared Fabric: Rebuild Workspace Entry", labels)
        self.assertIn("sharedFabricAgent", input_ids)

    def test_bootstrap_workspace_writes_agents_and_tasks(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir) / "global-agent-fabric"
            workspace = Path(tmpdir) / "workspace"
            workspace.mkdir()
            self._make_registry(root, workspace)
            self._make_servers_and_secrets(root)
            settings_path = Path(tmpdir) / ".gemini" / "settings.json"

            summary = module.bootstrap_workspace(
                workspace=workspace,
                global_root=root,
                runtimes=["codex", "gemini"],
                gemini_settings=settings_path,
                secrets_file=root / "mcp" / "secrets.yaml",
            )

            self.assertTrue((workspace / "AGENTS.md").exists())
            self.assertTrue((workspace / ".vscode" / "tasks.json").exists())
            self.assertEqual(summary["runtimes"], ["codex", "gemini"])
            settings = json.loads(settings_path.read_text(encoding="utf-8"))
            self.assertEqual(settings["context"]["fileName"], ["AGENTS.md", "GEMINI.md"])

    def test_bootstrap_workspace_codex_only_skips_gemini_settings(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir) / "global-agent-fabric"
            workspace = Path(tmpdir) / "workspace"
            workspace.mkdir()
            self._write(root / "projects" / "registry.yaml", "version: 1\nprojects:\n")

            summary = module.bootstrap_workspace(
                workspace=workspace,
                global_root=root,
                runtimes=["codex"],
                gemini_settings=None,
                secrets_file=None,
            )

            self.assertTrue((workspace / "AGENTS.md").exists())
            self.assertEqual(summary["gemini_settings"], "")
            tasks = json.loads((workspace / ".vscode" / "tasks.json").read_text(encoding="utf-8"))
            input_ids = [item["id"] for item in tasks["inputs"]]
            self.assertNotIn("sharedFabricAgent", input_ids)


if __name__ == "__main__":
    unittest.main()
