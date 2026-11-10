"""Regression checks for the declarative appearance migration."""

import base64
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import tomlkit

sys.path.insert(0, str(Path(__file__).parent))
from configure import merge_file, retire_trial
import sync


class AppearanceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def test_json_preserves_unowned_fields_and_removes_mode_override(self):
        path = self.root / "settings.json"
        path.write_text('{// app settings\n"plugins":["orca"],"appearance":"dark","theme":{"other":true},}')
        entry = {"format": "json", "set": {"theme": {"dark": "gruvbox-dark", "light": "gruvbox-light"}}, "remove": ["appearance"]}
        merge_file(path, entry)
        expected = {"plugins": ["orca"], "theme": {"other": True, "dark": "gruvbox-dark", "light": "gruvbox-light"}}
        self.assertEqual(json.loads(path.read_text()), expected)
        initial = path.stat().st_mtime_ns
        merge_file(path, entry)
        self.assertEqual(path.stat().st_mtime_ns, initial)

    def test_toml_nested_merge_preserves_unrelated_settings(self):
        path = self.root / "settings.toml"
        path.write_text('# keep this comment\n[theme]\nmode="dark"\n[bar]\nsize=32\n')
        entry = {"format": "toml", "set": {"theme": {"builtin": "Gruvbox"}, "wallpaper": {"monitors": {"Virtual-2": {"path": "portrait.jpg"}}}}}
        merge_file(path, entry)
        value = tomlkit.parse(path.read_text())
        self.assertEqual(value["theme"], {"mode": "dark", "builtin": "Gruvbox"})
        self.assertEqual(value["bar"]["size"], 32)
        self.assertIn("keep this comment", path.read_text())
        first = path.read_text()
        merge_file(path, entry)
        self.assertEqual(path.read_text(), first)

    def test_ini_preserves_unrelated_fields_and_key_case(self):
        path = self.root / "qt6ct.conf"
        path.write_text("[Appearance]\nstyle=Breeze\n[Interface]\nwheel_scroll_lines=7\n")
        merge_file(path, {"format": "ini", "set": {"Appearance": {"style": "Fusion", "custom_palette": "true"}, "Colors:Window": {"BackgroundNormal": "40,40,40"}}})
        self.assertIn("wheel_scroll_lines=7", path.read_text())
        self.assertIn("BackgroundNormal=40,40,40", path.read_text())
        self.assertNotIn("Breeze", path.read_text())

    def test_merging_symlink_does_not_modify_target(self):
        source, path = self.root / "store", self.root / "app.json"
        source.write_text('{"zoom":1.1}')
        path.symlink_to(source)
        merge_file(path, {"format": "json", "set": {"theme": "gruvbox"}})
        self.assertEqual(source.read_text(), '{"zoom":1.1}')
        self.assertFalse(path.is_symlink())

    def trial(self, edited=False):
        config, state = self.root / "config", self.root / "state"
        path = config / "ghostty/config"
        path.parent.mkdir(parents=True)
        path.write_text("user edit" if edited else "trial")
        snapshot = state / "gruvbox-trial/snapshot.json"
        snapshot.parent.mkdir(parents=True)
        snapshot.write_text(json.dumps({"files": {"ghostty/config": {
            "original": {"link": "/nix/store/original"},
            "applied": {"data": base64.b64encode(b"trial").decode(), "mode": 384},
        }}}))
        return config, state, path, snapshot

    def test_trial_retirement_restores_symlink_and_is_idempotent(self):
        config, state, path, snapshot = self.trial()
        retire_trial(config, state)
        self.assertTrue(path.is_symlink())
        self.assertEqual(os.readlink(path), "/nix/store/original")
        self.assertFalse(snapshot.exists())
        self.assertTrue(snapshot.with_name("snapshot.migrated.json").exists())
        retire_trial(config, state)

    def test_trial_retirement_refuses_external_changes(self):
        config, state, path, snapshot = self.trial(edited=True)
        with self.assertRaisesRegex(ValueError, "edited outside"):
            retire_trial(config, state)
        self.assertEqual(path.read_text(), "user edit")
        self.assertTrue(snapshot.exists())

    def test_trial_absent_original_is_supported(self):
        config, state, path, snapshot = self.trial()
        value = json.loads(snapshot.read_text())
        value["files"]["ghostty/config"]["original"] = None
        snapshot.write_text(json.dumps(value))
        retire_trial(config, state)
        self.assertFalse(path.exists())

    def settings(self):
        config, state = self.root / "config", self.root / "state"
        settings = {"config": str(config), "state": str(state), "noctalia": "noctalia", "gsettings": "gsettings"}
        base = self.root / "base.json"
        base.write_text(json.dumps({"@CONFIG@/qt6ct/qt6ct.conf": {"format": "ini", "set": {"Appearance": {"style": "Fusion"}}}}))
        settings["baseManifest"] = str(base)
        settings["paletteFiles"], settings["modeManifests"], settings["wallpaperModes"] = {}, {}, {}
        for mode in ("dark", "light"):
            settings["paletteFiles"][mode] = {}
            for kind in ("gtk2", "gtk3", "gtk4", "qt"):
                source = self.root / f"{mode}-{kind}"
                source.write_text(mode)
                settings["paletteFiles"][mode][kind] = str(source)
            manifest = self.root / f"{mode}.json"
            manifest.write_text(json.dumps({"@CONFIG@/kdeglobals": {"format": "ini", "set": {"General": {"ColorScheme": "Gruvbox" + mode}}}}))
            settings["modeManifests"][mode] = str(manifest)
            settings["wallpaperModes"][mode] = {"default": "center-" + mode, "monitors": {"Virtual-2": "portrait-" + mode}}
        path = self.root / "policy.json"
        path.write_text(json.dumps(settings))
        return path, config, state

    def test_offline_startup_and_mode_changes_use_same_artifacts(self):
        policy, config, state = self.settings()
        def offline(argv, **kwargs):
            return subprocess.CompletedProcess(argv, 1, "", "offline")
        with patch.dict(os.environ, {}, clear=True), patch.object(sync.subprocess, "run", side_effect=offline):
            for action in ("prepare", "light", "dark", "light", "prepare"):
                with patch.object(sys, "argv", ["sync.py", str(policy), action]):
                    sync.main()
                # prepare follows persisted shell mode; manual script modes do not select shell mode.
                expected = "dark" if action == "prepare" else action
                self.assertEqual((config / "gtk-3.0/gruvbox.css").read_text(), expected)
                self.assertEqual((config / "qt6ct/colors/gruvbox.conf").read_text(), expected)
                value = tomlkit.parse((state / "noctalia/settings.toml").read_text())
                self.assertEqual(value["theme"]["builtin"], "Gruvbox")
                self.assertEqual(value["wallpaper"]["monitors"]["Virtual-2"]["path"], "portrait-" + expected)

    def test_sync_parses_native_config_get_raw_toml(self):
        policy, config, state = self.settings()
        commands = []
        def online(argv, **kwargs):
            commands.append(argv)
            output = '"light"\n' if argv[2] == "config-get" else "ok\n"
            return subprocess.CompletedProcess(argv, 0, output, "")
        with patch.dict(os.environ, {}, clear=True), patch.object(sync.subprocess, "run", side_effect=online), patch.object(sys, "argv", ["sync.py", str(policy), "sync"]):
            sync.main()
        self.assertEqual((state / "gruvbox-mode").read_text(), "light\n")
        self.assertIn(["noctalia", "msg", "wallpaper-set", "Virtual-2", "portrait-light"], commands)

    def test_prepare_restores_saved_light_mode_without_shell_ipc(self):
        policy, config, state = self.settings()
        saved = state / "noctalia/settings.toml"
        saved.parent.mkdir(parents=True)
        saved.write_text('[theme]\nmode="light"\n[bar]\nsize=32\n')
        with patch.dict(os.environ, {}, clear=True), patch.object(sync.subprocess, "run", side_effect=AssertionError("startup must not require shell IPC")), patch.object(sys, "argv", ["sync.py", str(policy), "prepare"]):
            sync.main()
        value = tomlkit.parse(saved.read_text())
        self.assertEqual(value["theme"]["mode"], "light")
        self.assertEqual(value["theme"]["builtin"], "Gruvbox")
        self.assertEqual(value["bar"]["size"], 32)
        self.assertEqual(value["wallpaper"]["default"]["path"], "center-light")
        self.assertEqual(value["wallpaper"]["monitors"]["Virtual-2"]["path"], "portrait-light")
        self.assertEqual((config / "gtk-3.0/gruvbox.css").read_text(), "light")
        self.assertEqual((config / "qt6ct/colors/gruvbox.conf").read_text(), "light")

    @unittest.skipUnless(os.environ.get("TEST_GSETTINGS"), "real gsettings is supplied by the Nix check")
    def test_all_actions_find_pinned_schemas_without_desktop_environment(self):
        policy, config, state = self.settings()
        settings = json.loads(policy.read_text())
        settings["gsettings"] = os.environ["TEST_GSETTINGS"]
        settings["gsettingsSchemaDir"] = os.environ["TEST_GSETTINGS_SCHEMA_DIR"]
        policy.write_text(json.dumps(settings))
        real_run = subprocess.run
        writes = []

        def run(argv, **kwargs):
            if argv[0] == settings["gsettings"]:
                result = real_run(argv, **kwargs)
                writes.append(argv[3])
                return result
            # Only shell IPC is simulated; gsettings and schema loading are real.
            output = '"dark"\n' if argv[2] == "config-get" else "ok\n"
            return subprocess.CompletedProcess(argv, 0, output, "")

        environment = {
            "HOME": str(self.root),
            "DBUS_SESSION_BUS_ADDRESS": "unix:path=/unused-with-memory-backend",
            "GSETTINGS_BACKEND": "memory",
            "XDG_DATA_DIRS": str(self.root / "empty-data"),
            "GSETTINGS_SCHEMA_DIR": str(self.root / "wrong-inherited-schema-directory"),
        }
        with patch.dict(os.environ, environment, clear=True), patch.object(sync.subprocess, "run", side_effect=run):
            for action in ("activate", "prepare", "dark", "light", "sync"):
                with self.subTest(action=action), patch.object(sys, "argv", ["sync.py", str(policy), action]):
                    sync.main()
        self.assertEqual(writes, ["gtk-theme", "icon-theme", "color-scheme"] * 5)


if __name__ == "__main__":
    unittest.main()
