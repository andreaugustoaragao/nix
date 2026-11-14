"""Check profile migration without risking an open browser's settings."""

import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("theme", Path(__file__).with_name("browser-system-theme.py"))
theme = importlib.util.module_from_spec(spec)
spec.loader.exec_module(theme)


class ThemeTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.policy = {
            "directory": "chromium",
            "preferences": {"extensions": {"theme": {"id": "", "system_theme": 1}},
                            "browser": {"theme": {"color_scheme2": 0}},
                            "brave": {"darker_mode": False, "dark_mode_migrated": True}},
        }
        self.arguments = ["--user-data-dir=" + str(self.root)]

    def write(self, name, value):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value))
        return path

    def test_existing_profiles_keep_unrelated_settings_and_follow_gtk(self):
        self.write("Local State", {"profile": {"last_used": "Personal"}, "brave": {"dark_mode": 2, "other": True}})
        personal = self.write("Personal/Preferences", {"extensions": {"theme": {"id": "old-theme"}}, "session": {"restore_on_startup": 1}})
        work = self.write("Work/Preferences", {"profile": {"name": "Work"}})
        theme.prepare(self.policy, self.arguments)
        self.assertEqual(json.loads(personal.read_text())["extensions"]["theme"], {"id": "", "system_theme": 1})
        self.assertEqual(json.loads(personal.read_text())["session"], {"restore_on_startup": 1})
        self.assertEqual(json.loads(personal.read_text())["brave"], {"darker_mode": False, "dark_mode_migrated": True})
        self.assertEqual(json.loads(work.read_text())["profile"], {"name": "Work"})
        self.assertEqual(json.loads((self.root / "Local State").read_text())["brave"], {"dark_mode": 2, "other": True})
        self.assertFalse((self.root / "Default").exists())
        modified = personal.stat().st_mtime_ns
        theme.prepare(self.policy, self.arguments)
        self.assertEqual(personal.stat().st_mtime_ns, modified)

    def test_active_or_stale_singleton_leaves_every_file_untouched(self):
        path = self.write("Default/Preferences", {"extensions": {"theme": {"id": "existing"}}})
        original = path.read_bytes()
        (self.root / "SingletonLock").symlink_to("host-12345")
        theme.prepare(self.policy, self.arguments + ["--profile-directory=New"])
        self.assertEqual(path.read_bytes(), original)
        self.assertFalse((self.root / "New").exists())
        self.assertFalse((self.root / "Local State").exists())

    def test_new_explicit_profile_and_custom_data_directory(self):
        theme.prepare(self.policy, ["--user-data-dir", str(self.root), "--profile-directory", "New"])
        path = self.root / "New/Preferences"
        self.assertEqual(json.loads(path.read_text())["browser"]["theme"]["color_scheme2"], 0)
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_xdg_default_directory(self):
        with patch.dict(os.environ, {"XDG_CONFIG_HOME": str(self.root), "CHROME_CONFIG_HOME": "", "CHROME_USER_DATA_DIR": ""}):
            theme.prepare(self.policy, [])
        self.assertTrue((self.root / "chromium/Default/Preferences").exists())

    def test_profile_cannot_escape_user_data_directory(self):
        with self.assertRaises(ValueError):
            theme.prepare(self.policy, self.arguments + ["--profile-directory=../outside"])


if __name__ == "__main__":
    unittest.main()
