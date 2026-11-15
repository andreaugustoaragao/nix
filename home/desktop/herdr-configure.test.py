import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

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


if __name__ == "__main__":
    unittest.main()
