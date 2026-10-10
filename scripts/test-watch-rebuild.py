#!/usr/bin/env python3
"""Check that automatic rebuilds cannot activate and report build failures."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class WatchBuildTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        self.log = root / "commands.jsonl"
        self.bin = root / "bin"
        self.bin.mkdir()
        self.script = root / "scripts" / "watch-rebuild.sh"
        self.script.parent.mkdir()
        shutil.copy2(Path(__file__).with_name("watch-rebuild.sh"), self.script)
        self.env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}",
                        WATCH_TEST_LOG=str(self.log), WATCH_TEST_UID="1000",
                        WATCH_TEST_PLATFORM="Linux", WATCH_TEST_EXIT="0")
        for name in ("id", "hostname", "uname", "nix", "watchexec", "sudo",
                     "nixos-rebuild", "darwin-rebuild"):
            stub = self.bin / name
            stub.write_text("#!/usr/bin/env python3\n" + '''import json, os, sys
from pathlib import Path
name = Path(sys.argv[0]).name
if name in ("id", "hostname", "uname"):
    print({"id": os.environ["WATCH_TEST_UID"], "hostname": "test-host",
           "uname": os.environ["WATCH_TEST_PLATFORM"]}[name])
else:
    with open(os.environ["WATCH_TEST_LOG"], "a") as out:
        out.write(json.dumps([name, *sys.argv[1:]]) + "\\n")
    if name == "nix":
        sys.exit(int(os.environ["WATCH_TEST_EXIT"]))
    if name in ("sudo", "nixos-rebuild", "darwin-rebuild"):
        sys.exit(99)
''')
            stub.chmod(0o755)

    def run_script(self, *args):
        return subprocess.run(["bash", str(self.script), *args], env=self.env,
                              capture_output=True, text=True)

    def commands(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] \
            if self.log.exists() else []

    def test_platform_builds_without_activation(self):
        for platform, attr in (("Linux", "nixosConfigurations.test-host.config.system.build.toplevel"),
                               ("Darwin", "darwinConfigurations.test-host.system")):
            with self.subTest(platform=platform):
                self.log.unlink(missing_ok=True)
                self.env["WATCH_TEST_PLATFORM"] = platform
                result = self.run_script("--__build")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.commands(), [["nix", "build", f".#{attr}",
                                  "--no-link", "--print-out-paths", "--option", "warn-dirty", "false"]])
                self.assertIn("Activate when ready:", result.stdout)

    def test_failure_is_reported_and_preserves_exit_status(self):
        self.env["WATCH_TEST_EXIT"] = "42"
        result = self.run_script("--__build")
        self.assertEqual(result.returncode, 42)
        self.assertIn("build FAILED (exit 42)", result.stdout)
        self.assertNotIn("Activate when ready:", result.stdout)

    def test_legacy_arbitrary_command_is_rejected(self):
        result = self.run_script("--__exec", "sudo", "nixos-rebuild", "switch")
        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.commands(), [])

    def test_additional_build_arguments_are_rejected(self):
        result = self.run_script("--__build", "sudo")
        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.commands(), [])

    def test_root_execution_is_rejected(self):
        self.env["WATCH_TEST_UID"] = "0"
        result = self.run_script("--__build")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(self.commands(), [])

    def test_watcher_uses_fixed_build_callback(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        commands = self.commands()
        self.assertEqual(len(commands), 1)
        command = commands[0]
        self.assertEqual(command[0], "watchexec")
        self.assertEqual(command[command.index("--") + 1:], [str(self.script), "--__build"])
        self.assertIn("--on-busy-update=queue", command)


if __name__ == "__main__":
    unittest.main()
