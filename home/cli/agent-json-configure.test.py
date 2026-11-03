"""Exercise the same two CLI invocations used by Home Manager activation."""

import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("agent-json-configure.py")
OLD = "/nix/store/old-pi-rs/share/pi-rs/agent-hooks/rewrite.sh"
NEW = "/nix/store/new-pi-rs/share/pi-rs/agent-hooks/rewrite.sh"
ORCA = {"command": "/home/user/.local/share/orca/hook", "timeout": 30}


def settings(kind, command):
    if kind == "claude":
        return {
            "model": "opus[1m]",
            "env": {"ENABLE_LSP_TOOL": "1"},
            "statusLine": {"type": "command", "command": command + "-statusline"},
            "hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [
                {"type": "command", "command": command},
            ]}]},
        }
    return {"version": 1, "hooks": {"preToolUse": [
        {"matcher": "Bash", "command": command},
        {"command": "agent-hub cursor-hook"},
        {"command": "bash herdr-agent-state.sh session"},
    ]}}


class ActivationTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.target = self.root / "home/config.json"
        self.desired = self.root / "desired.json"
        self.state = self.root / "state/managed.json"
        self.legacy = self.root / "old-generation/config.json"

    def write(self, path, value):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value))

    def invoke(self, kind, prepare=False, success=True):
        command = [sys.executable, str(SCRIPT), "--kind", kind,
                   "--target", str(self.target), "--desired", str(self.desired),
                   "--state", str(self.state), "--legacy", str(self.legacy)]
        if prepare:
            command.append("--prepare")
        process = subprocess.run(command, capture_output=True, text=True)
        if success:
            self.assertEqual(process.returncode, 0, process.stderr)
        else:
            self.assertNotEqual(process.returncode, 0)
        return process

    def activate(self, kind):
        self.invoke(kind, prepare=True)
        # linkGeneration deletes only links; the prepare step must detach it.
        self.assertFalse(self.target.is_symlink())
        self.invoke(kind)
        return json.loads(self.target.read_text())

    def commands(self, value, kind):
        if kind == "claude":
            return [handler["command"] for entries in value["hooks"].values()
                    for entry in entries for handler in entry["hooks"]]
        return [entry["command"] for entries in value["hooks"].values() for entry in entries]

    def add_external(self, value, kind):
        value["userPreference"] = {"theme": "dark"}
        if kind == "claude":
            value["env"]["USER_SETTING"] = "keep"
            # Editors may append to the same matcher group as a managed hook.
            value["hooks"]["PreToolUse"][0]["hooks"].append({"type": "command", **ORCA})
        else:
            value["hooks"]["preToolUse"].append(copy.deepcopy(ORCA))

    def test_old_symlink_detaches_without_touching_store_then_reconciles(self):
        for kind in ("claude", "cursor"):
            with self.subTest(kind=kind):
                self.target.unlink(missing_ok=True)
                self.state.unlink(missing_ok=True)
                old = settings(kind, OLD)
                self.write(self.legacy, old)
                self.legacy.chmod(0o444)
                self.target.parent.mkdir(parents=True, exist_ok=True)
                self.target.symlink_to(self.legacy)
                self.write(self.desired, settings(kind, NEW))
                before = self.legacy.read_bytes()
                self.invoke(kind, prepare=True)
                self.assertFalse(self.target.is_symlink())
                self.assertEqual(json.loads(self.target.read_text()), old)
                self.assertEqual(self.target.stat().st_mode & 0o777, 0o600)
                current = self.activate(kind)
                self.assertNotIn(OLD, self.commands(current, kind))
                self.assertEqual(self.commands(current, kind).count(NEW), 1)
                self.assertEqual(self.legacy.read_bytes(), before)
                # Orca uses realpath before writing; this must stay in HOME.
                realpath = Path(os.path.realpath(self.target))
                self.assertEqual(realpath, self.target)
                self.add_external(current, kind)
                self.write(realpath, current)
                for _ in range(2):
                    current = self.activate(kind)
                    self.assertEqual(self.commands(current, kind).count(ORCA["command"]), 1)
                    self.assertEqual(self.commands(current, kind).count(NEW), 1)
                    self.assertEqual(current["userPreference"], {"theme": "dark"})
                if kind == "claude":
                    self.assertEqual(current["env"]["USER_SETTING"], "keep")
                    self.assertEqual(current["statusLine"]["command"], NEW + "-statusline")
                self.legacy.chmod(0o600)

    def test_changed_and_removed_managed_entries_preserve_external_values(self):
        for kind in ("claude", "cursor"):
            with self.subTest(kind=kind):
                self.state.unlink(missing_ok=True)
                original = settings(kind, OLD)
                self.add_external(original, kind)
                self.write(self.target, original)
                self.write(self.desired, settings(kind, OLD))
                self.activate(kind)
                self.write(self.desired, settings(kind, NEW))
                changed = self.activate(kind)
                self.assertNotIn(OLD, self.commands(changed, kind))
                self.assertEqual(self.commands(changed, kind).count(NEW), 1)
                self.assertEqual(self.commands(changed, kind).count(ORCA["command"]), 1)
                self.write(self.desired, {})
                removed = self.activate(kind)
                self.assertEqual(self.commands(removed, kind), [ORCA["command"]])
                self.assertEqual(removed["userPreference"], {"theme": "dark"})
                if kind == "claude":
                    self.assertEqual(removed["env"], {"USER_SETTING": "keep"})
                    self.assertNotIn("statusLine", removed)

    def test_malformed_config_or_manifest_is_not_overwritten(self):
        for kind in ("claude", "cursor"):
            for invalid in ('{"hooks":', '[]', '{"hooks": {"bad": 42}}'):
                for symlink in (False, True):
                    with self.subTest(kind=kind, invalid=invalid, symlink=symlink):
                        self.target.unlink(missing_ok=True)
                        self.state.unlink(missing_ok=True)
                        self.write(self.desired, settings(kind, NEW))
                        self.write(self.target, {})
                        if symlink:
                            self.target.unlink()
                            self.write(self.legacy, {})
                            self.target.symlink_to(self.legacy)
                        self.target.write_text(invalid)
                        for prepare in (True, False):
                            self.invoke(kind, prepare=prepare, success=False)
                            self.assertEqual(self.target.read_text(), invalid)
                            self.assertEqual(self.target.is_symlink(), symlink)
                            self.assertFalse(self.state.exists())
            self.target.unlink(missing_ok=True)
            self.write(self.target, settings(kind, OLD))
            self.write(self.state, {})
            before = self.target.read_bytes()
            self.invoke(kind, success=False)
            self.assertEqual(self.target.read_bytes(), before)
            self.assertEqual(self.state.read_text(), "{}")

    def test_interrupted_update_retires_both_journaled_command_sets(self):
        for kind in ("claude", "cursor"):
            for applied in (OLD, NEW):
                with self.subTest(kind=kind, applied=applied):
                    current = settings(kind, applied)
                    self.add_external(current, kind)
                    self.write(self.target, current)
                    self.write(self.state, {"managed": [settings(kind, OLD), settings(kind, NEW)]})
                    third = NEW.replace("new-pi-rs", "third-pi-rs")
                    self.write(self.desired, settings(kind, third))
                    result = self.activate(kind)
                    commands = self.commands(result, kind)
                    self.assertNotIn(OLD, commands)
                    self.assertNotIn(NEW, commands)
                    self.assertEqual(commands.count(third), 1)
                    self.assertEqual(commands.count(ORCA["command"]), 1)
                    self.assertEqual(self.activate(kind), result)

    def test_interruption_after_linking_keeps_legacy_ownership(self):
        for kind in ("claude", "cursor"):
            with self.subTest(kind=kind):
                self.target.unlink(missing_ok=True)
                self.state.unlink(missing_ok=True)
                self.write(self.legacy, settings(kind, OLD))
                self.target.parent.mkdir(parents=True, exist_ok=True)
                self.target.symlink_to(self.legacy)
                self.write(self.desired, settings(kind, NEW))
                self.invoke(kind, prepare=True)
                # The next activation's old generation no longer owns this
                # home.file. Its earlier command identities must survive.
                self.legacy.unlink()
                result = self.activate(kind)
                self.assertNotIn(OLD, self.commands(result, kind))
                self.assertEqual(self.commands(result, kind).count(NEW), 1)


if __name__ == "__main__":
    unittest.main()
