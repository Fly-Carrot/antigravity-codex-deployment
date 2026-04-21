import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).resolve().parents[1] / 'fabric' / 'scripts' / 'sync' / 'bootstrap_gemini_workspace.py'
SCRIPT_DIR = MODULE_PATH.parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

spec = importlib.util.spec_from_file_location('bootstrap_gemini_workspace', MODULE_PATH)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)


class BootstrapGeminiWorkspaceTests(unittest.TestCase):
    def make_registry(self, root: Path, workspace: Path, overlays: list[Path]) -> None:
        overlay_lines = ''.join(f'      - {json.dumps(str(path))}\n' for path in overlays)
        content = (
            'version: 1\n'
            'projects:\n'
            '  -\n'
            '    id: "test-project"\n'
            '    name: "Test Project"\n'
            f'    path: {json.dumps(str(workspace))}\n'
            '    overlay_rules:\n'
            f'{overlay_lines}'
            f'    overlay_root: {json.dumps(str(workspace / ".agents"))}\n'
        )
        (root / 'projects').mkdir(parents=True, exist_ok=True)
        (root / 'projects' / 'registry.yaml').write_text(content, encoding='utf-8')

    def make_servers(self, root: Path) -> None:
        content = (
            'version: 1\n'
            'servers:\n'
            '  -\n'
            '    id: "context7"\n'
            '    enabled: true\n'
            '    command: "/opt/homebrew/bin/npx"\n'
            '    args:\n'
            '      - "-y"\n'
            '      - "@upstash/context7-mcp"\n'
            '      - "--api-key"\n'
            '      - "${CONTEXT7_API_KEY}"\n'
            '    env_refs:\n'
            '      - "PATH"\n'
            '      - "CONTEXT7_API_KEY"\n'
            '    owner: "global"\n'
            '    scope: "docs"\n'
            '    source: "/tmp/fabric/mcp/servers.yaml"\n'
            '  -\n'
            '    id: "qgis"\n'
            '    enabled: false\n'
            '    command: "/bin/false"\n'
            '    args: []\n'
            '    env_refs: []\n'
            '    owner: "global"\n'
            '    scope: "gis"\n'
            '    source: "/tmp/fabric/mcp/servers.yaml"\n'
            '  -\n'
            '    id: "zotero"\n'
            '    enabled: true\n'
            '    command: "/bin/zotero"\n'
            '    args: []\n'
            '    env_refs:\n'
            '      - "ZOTERO_API_KEY"\n'
            '      - "ZOTERO_LIBRARY_ID"\n'
            '    owner: "global"\n'
            '    scope: "literature"\n'
            '    source: "/tmp/fabric/mcp/servers.yaml"\n'
        )
        (root / 'mcp').mkdir(parents=True, exist_ok=True)
        (root / 'mcp' / 'servers.yaml').write_text(content, encoding='utf-8')

    def make_secrets(self, root: Path) -> None:
        content = (
            'version: 1\n'
            'env:\n'
            '  CONTEXT7_API_KEY: "ctx7-test"\n'
            '  ZOTERO_API_KEY: "zotero-key"\n'
            '  ZOTERO_LIBRARY_ID: "12345"\n'
        )
        (root / 'mcp').mkdir(parents=True, exist_ok=True)
        (root / 'mcp' / 'secrets.yaml').write_text(content, encoding='utf-8')

    def test_merge_settings_keeps_existing_fields(self) -> None:
        settings = {
            'security': {'auth': {'selectedType': 'oauth-personal'}},
            'context': {'fileName': ['GEMINI.md']},
        }
        module.merge_context_filenames(settings)
        self.assertEqual(settings['security']['auth']['selectedType'], 'oauth-personal')
        self.assertEqual(settings['context']['fileName'], ['GEMINI.md', 'AGENTS.md'])
        module.merge_context_filenames(settings)
        self.assertEqual(settings['context']['fileName'], ['GEMINI.md', 'AGENTS.md'])

    def test_build_gemini_mcp_servers_skips_disabled_and_resolves_env(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            self.make_servers(root)
            self.make_secrets(root)
            servers = module.parse_servers_yaml(root / 'mcp' / 'servers.yaml')
            secrets = module.parse_env_yaml(root / 'mcp' / 'secrets.yaml')
            rendered = module.build_gemini_mcp_servers(servers, secrets, root / 'mcp' / 'secrets.yaml')
            self.assertIn('context7', rendered)
            self.assertIn('zotero', rendered)
            self.assertNotIn('qgis', rendered)
            self.assertEqual(rendered['context7']['args'][3], 'ctx7-test')
            self.assertEqual(rendered['zotero']['env']['ZOTERO_LIBRARY_ID'], '12345')

    def test_render_workspace_agents_for_project_overlay(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            workspace = Path(tmpdir) / 'Project4'
            overlay = workspace / '.agents' / 'rules' / 'ecology.md'
            overlay.parent.mkdir(parents=True, exist_ok=True)
            overlay.write_text('# ecology\n', encoding='utf-8')
            project = {
                'id': 'project4',
                'overlay_rules': [str(overlay)],
            }
            content = module.render_workspace_agents(project, workspace)
            self.assertIn('@./.agents/rules/ecology.md', content)
            self.assertIn('codex-context.md', content)

    def test_write_workspace_agents_refuses_unmanaged_file(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / 'AGENTS.md'
            path.write_text('# manual\n', encoding='utf-8')
            with self.assertRaises(SystemExit):
                module.write_workspace_agents(path, 'new content')

    def test_bootstrap_workspace_allows_unregistered_workspace(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            workspace = root / 'Scratch'
            workspace.mkdir()
            (root / 'projects').mkdir(parents=True, exist_ok=True)
            (root / 'projects' / 'registry.yaml').write_text('version: 1\nprojects:\n', encoding='utf-8')
            self.make_servers(root)
            self.make_secrets(root)
            settings_path = root / 'settings.json'

            summary = module.bootstrap_workspace(
                workspace=workspace,
                global_root=root,
                gemini_settings=settings_path,
                secrets_file=root / 'mcp' / 'secrets.yaml',
            )

            self.assertFalse(summary['registered'])
            self.assertTrue((workspace / 'AGENTS.md').exists())
            settings = json.loads(settings_path.read_text(encoding='utf-8'))
            self.assertEqual(settings['context']['fileName'], ['AGENTS.md', 'GEMINI.md'])


if __name__ == '__main__':
    unittest.main()
