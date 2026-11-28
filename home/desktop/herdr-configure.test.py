import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

WORK_INTAKE = os.environ.get(
    "WORK_INTAKE_BIN",
    shutil.which("work-intake") or shutil.which("herdr-intake-dashboard"),
)


def intake_view_argv():
    if not WORK_INTAKE:
        return None
    if Path(WORK_INTAKE).name == "herdr-intake-dashboard":
        return [WORK_INTAKE, "view"]
    return [WORK_INTAKE, "herdr-view", "view"]

spec = importlib.util.spec_from_file_location("configure", Path(__file__).with_name("herdr-configure.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class LayoutAdoption(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / "layouts").mkdir()
        (self.root / "layouts/main-flat.json").write_text("{}")

    def test_existing_app_state_survives_offline_adoption(self):
        state = {"layout": "main", "workspace.panels": ["user-panel"], "frame.welcomed": "finished"}
        (self.root / "shared.json").write_text(json.dumps(state))
        with patch.object(module.subprocess, "run", return_value=subprocess.CompletedProcess([], 1)):
            module.configure(self.root, "main-flat", "herdr-app")
        self.assertEqual(json.loads((self.root / "shared.json").read_text()), dict(state, layout="main-flat"))

    def test_fresh_install_gets_declared_layout(self):
        with patch.object(module.subprocess, "run", return_value=subprocess.CompletedProcess([], 1)):
            module.configure(self.root, "main-flat", "herdr-app")
        self.assertEqual(json.loads((self.root / "shared.json").read_text()), {"layout": "main-flat"})

    def test_configuration_can_precede_app_installation(self):
        with patch.object(module.subprocess, "run", side_effect=FileNotFoundError):
            module.configure(self.root, "main-flat", "herdr-app")
        self.assertEqual(json.loads((self.root / "shared.json").read_text()), {"layout": "main-flat"})

    def test_live_app_owns_its_state_file(self):
        state = self.root / "shared.json"
        state.write_text('{"layout":"main","keep":true}')
        with patch.object(module.subprocess, "run", side_effect=[
            subprocess.CompletedProcess([], 0, '{"layout":"main"}'),
            subprocess.CompletedProcess([], 0),
        ]) as run:
            module.configure(self.root, "main-flat", "herdr-app")
        self.assertEqual(run.call_args_list[1].args[0], ["herdr-app", "do", "layout.switch", "--name", "main-flat"])
        self.assertEqual(state.read_text(), '{"layout":"main","keep":true}')
        self.assertEqual(run.call_args_list[0].kwargs["env"]["HERDR_APP_HOME"], str(self.root))

    def test_failed_live_switch_is_visible(self):
        with patch.object(module.subprocess, "run", side_effect=[
            subprocess.CompletedProcess([], 0, '{"layout":"main"}'),
            subprocess.CalledProcessError(1, "herdr-app"),
        ]):
            with self.assertRaises(subprocess.CalledProcessError):
                module.configure(self.root, "main-flat", "herdr-app")
        self.assertFalse((self.root / "shared.json").exists())

    def test_invalid_state_is_preserved(self):
        state = self.root / "shared.json"
        state.write_text("broken")
        with self.assertRaises(ValueError):
            module.configure(self.root, "main-flat", "herdr-app")
        self.assertEqual(state.read_text(), "broken")

    def test_missing_layout_is_rejected(self):
        with self.assertRaises(ValueError):
            module.configure(self.root, "absent", "herdr-app")
        self.assertFalse((self.root / "shared.json").exists())

    def test_programs_merge_preserves_custom_launchers_shells_and_interpreters(self):
        target = self.root / "programs.json"
        target.write_text(
            json.dumps(
                {
                    "shells": ["xonsh"],
                    "interpreters": ["pipx"],
                    "programs": {
                        "my-agent": {"name": "My Agent", "run": ["my-agent"]},
                    },
                }
            )
        )
        declared = Path(__file__).parent / "herdr/programs.json"
        with patch.object(module.subprocess, "run", return_value=subprocess.CompletedProcess([], 1)):
            module.configure(self.root, "main-flat", "herdr-app", declared)
        merged = json.loads(target.read_text())
        self.assertEqual(merged["shells"], ["xonsh"])
        self.assertEqual(merged["interpreters"], ["pipx"])
        self.assertEqual(merged["programs"]["my-agent"], {"name": "My Agent", "run": ["my-agent"]})
        self.assertEqual(merged["programs"]["omp"]["run"], ["omp"])
        self.assertEqual(merged["programs"]["omp"]["name"], "OMP")

    def test_programs_merge_creates_file_when_absent(self):
        declared = Path(__file__).parent / "herdr/programs.json"
        module.reconcile_programs(self.root, declared)
        merged = json.loads((self.root / "programs.json").read_text())
        self.assertEqual(merged["programs"]["omp"]["run"], ["omp"])

    def test_invalid_programs_file_is_preserved(self):
        target = self.root / "programs.json"
        target.write_text("broken")
        declared = Path(__file__).parent / "herdr/programs.json"
        with self.assertRaises(ValueError):
            module.reconcile_programs(self.root, declared)
        self.assertEqual(target.read_text(), "broken")


class PackagedDependencies(unittest.TestCase):
    def test_custom_layout_mods_are_in_the_nix_source(self):
        source = Path(__file__).parent / "herdr"
        shipped_mods = {"changes", "workspace-status", "work-intake"}

        def mods(node):
            if isinstance(node, dict):
                if isinstance(node.get("mod"), str):
                    yield node["mod"]
                for value in node.values():
                    yield from mods(value)
            elif isinstance(node, list):
                for value in node:
                    yield from mods(value)

        for layout in (source / "layouts").glob("*.json"):
            for mod in mods(json.loads(layout.read_text())):
                if mod not in shipped_mods:
                    self.assertTrue((source / "mods" / mod / "main.js").is_file(), f"{layout.name}: {mod}")

    def test_intake_viewer_works_without_a_notes_checkout(self):
        if not WORK_INTAKE:
            self.skipTest("work-intake binary not on PATH")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "not-cloned-yet"
            state = Path(directory) / "empty-state"
            result = subprocess.run(
                intake_view_argv(),
                env={
                    **os.environ,
                    "HERDR_INTAKE_NOTES_ROOT": str(root),
                    "HERDR_INTAKE_STATE_DIR": str(state),
                    "WORK_INTAKE_STATE_DIR": str(state),
                },
                capture_output=True,
                text=True,
                check=True,
            )
            self.assertIsNone(json.loads(result.stdout)["report"])
            self.assertEqual(json.loads(result.stdout)["items"], [])
            self.assertFalse(root.exists())

    def test_intake_viewer_reads_external_state_dir_without_in_vault_system(self):
        if not WORK_INTAKE:
            self.skipTest("work-intake binary not on PATH")
        with tempfile.TemporaryDirectory() as directory:
            vault = Path(directory) / "notes"
            state = Path(directory) / "state"
            brief = vault / "weekly/2026_11_23/briefings/2026-11-27-work-intake.md"
            brief.parent.mkdir(parents=True, exist_ok=True)
            brief.write_text("# Work intake\n\nCalendar: clear\n")
            run_id = "11111111-2222-4333-8444-555555555555"
            run_dir = state / "runs" / run_id
            run_dir.mkdir(parents=True, exist_ok=True)
            (run_dir / "manifest.json").write_text(json.dumps({
                "run_id": run_id,
                "status": "complete",
                "briefed_at": "2026-11-27T12:00:00Z",
                "briefing_path": "weekly/2026_11_23/briefings/2026-11-27-work-intake.md",
                "source_coverage_complete": True,
            }))
            (state / "herdr/receipts").mkdir(parents=True, exist_ok=True)
            receipt = {
                "schema_version": 1,
                "run_id": run_id,
                "generated_at": "2026-11-27T12:00:00Z",
                "horizon_end": "2026-11-27T14:00:00Z",
                "display_time": "Fri 05:00 MST",
                "coverage": "complete",
                "briefing_path": "weekly/2026_11_23/briefings/2026-11-27-work-intake.md",
                "briefing_markdown": "# Work intake\n\nCalendar: clear\n",
                "source_manifest": f"_system/intake/work-intake/{run_id}/manifest.json",
                "summary": "External state test",
                "notify": False,
                "attention": "routine",
                "action_count": 0,
            }
            (state / "herdr/receipts" / f"{run_id}.json").write_text(json.dumps(receipt))
            result = subprocess.run(
                intake_view_argv(),
                env=dict(os.environ, HERDR_INTAKE_NOTES_ROOT=str(vault), HERDR_INTAKE_STATE_DIR=str(state)),
                capture_output=True,
                text=True,
                check=True,
            )
            payload = json.loads(result.stdout)
            self.assertEqual(payload["latest"], run_id)
            self.assertEqual(len(payload["history"]), 1)
            self.assertFalse((vault / "_system").exists())


if __name__ == "__main__":
    unittest.main()
