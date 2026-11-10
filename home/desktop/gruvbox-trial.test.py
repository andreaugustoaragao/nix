#!/usr/bin/env python3
import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location("trial", Path(__file__).with_name("gruvbox-trial.py"))
trial = importlib.util.module_from_spec(spec)
spec.loader.exec_module(trial)


class TrialTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        self.config, self.state, self.images = root / "config", root / "state", root / "images"
        self.state.mkdir()
        self.images.mkdir()
        ghostty = self.config / "ghostty/config"
        ghostty.parent.mkdir(parents=True)
        original = ghostty.parent / "managed-config"
        original.write_text("font-size = 11\ntheme = Catppuccin Mocha\n")
        original.chmod(0o444)
        ghostty.symlink_to("managed-config")
        gtk = self.config / "gtk-3.0/gtk.css"
        gtk.parent.mkdir()
        gtk.write_text("@import 'colors.css';\n/* existing customization */\n")
        gtk.chmod(0o640)
        self.original_files = {name: trial.file_state(self.config / name)
                               for name in ("ghostty/config", "gtk-3.0/gtk.css", "gtk-4.0/gtk.css")}
        for mode in ("dark", "light"):
            for slot in ("center", "portrait"):
                (self.images / f"{slot}-{mode}.jpg").touch()
        self.shell = {"theme.source": "builtin", "theme.builtin": "Catppuccin",
                      "theme.mode": "dark", "theme.shell_mode": "follow",
                      "wallpaper.automation.enabled": True}
        self.wallpapers = {output: f"/original/{output}.jpg" for output in trial.OUTPUTS}
        self.original_shell = self.shell.copy()
        self.original_walls = self.wallpapers.copy()
        self.client = trial.Trial(self.config, self.state, self.images)
        self.addCleanup(patch.stopall)
        patch.object(trial, "ipc", self.ipc).start()
        patch.object(self.client, "reload_ghostty").start()
        patch.object(trial.subprocess, "run", return_value=subprocess.CompletedProcess(
            [], 0, stdout=json.dumps({output: {"logical": {"x": 1}} for output in trial.OUTPUTS}))).start()

    def ipc(self, action, *args):
        if action == "config-get":
            return json.dumps(self.shell[args[0]])
        if action == "config-set":
            self.shell[args[0]] = json.loads(args[1])
        if action == "wallpaper-get":
            return self.wallpapers[args[0]]
        if action == "wallpaper-set":
            self.wallpapers[args[0]] = args[1]
        return "ok"

    def test_dark_light_repeat_restore_preserves_original_files_and_art(self):
        for mode in ("dark", "dark", "light"):
            self.client.apply(mode)
            self.assertEqual(self.shell["theme.builtin"], "Gruvbox")
            self.assertEqual(self.shell["theme.mode"], mode)
            self.assertTrue(self.wallpapers["Virtual-1"].endswith(f"center-{mode}.jpg"))
            self.assertEqual(self.wallpapers["Virtual-2"], self.wallpapers["Virtual-3"])
        self.client.restore()
        self.client.restore()
        self.assertEqual(self.shell, self.original_shell)
        self.assertEqual(self.wallpapers, self.original_walls)
        self.assertEqual({name: trial.file_state(self.config / name) for name in self.original_files},
                         self.original_files)
        self.assertEqual((self.config / "ghostty/managed-config").stat().st_mode & 0o777, 0o444)

    def test_restore_refuses_external_file_edit(self):
        self.client.apply("dark")
        path = self.config / "gtk-3.0/gtk.css"
        path.write_text("user edit")
        with self.assertRaisesRegex(RuntimeError, "gtk-3.0/gtk.css"):
            self.client.restore()
        self.assertEqual(path.read_text(), "user edit")
        self.assertTrue(self.client.snapshot.exists())

    def test_restore_refuses_external_shell_edit(self):
        self.client.apply("dark")
        self.shell["theme.builtin"] = "Nord"
        with self.assertRaisesRegex(RuntimeError, "theme.builtin"):
            self.client.restore()
        self.assertEqual(self.shell["theme.builtin"], "Nord")

    def test_interrupted_mode_change_can_restore(self):
        self.client.apply("dark")
        dark_shell, dark_walls = copy.deepcopy(self.shell), self.wallpapers.copy()
        dark_files = {name: (self.config / name).read_bytes() for name in self.original_files}
        self.client.apply("light")
        self.shell.update(dark_shell)
        self.wallpapers.update(dark_walls)
        for name, data in dark_files.items():
            trial.atomic_write(self.config / name, data)
        self.client.restore()
        self.assertEqual(self.shell, self.original_shell)

    def test_missing_monitor_changes_nothing(self):
        with patch.object(trial.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, stdout="{}")):
            with self.assertRaisesRegex(RuntimeError, "three active"):
                self.client.apply("dark")
        self.assertFalse(self.client.snapshot.exists())


if __name__ == "__main__":
    unittest.main()
