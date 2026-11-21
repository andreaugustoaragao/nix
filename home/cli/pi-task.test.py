#!/usr/bin/env python3
"""Check Pi task launch isolation and explicit paid-model selection."""
import json
import os
from pathlib import Path
import shlex
import shutil
import sys
import subprocess
import tempfile
import unittest


class PiTaskTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.binary = self.root / "raw-pi"
        self.binary.write_text(
            f"#!{sys.executable}\n"
            "import json, os, sys\n"
            "print(json.dumps(sys.argv[1:]))\n"
            "sys.exit(int(os.environ.get('PI_TEST_EXIT', '0')))\n"
        )
        self.binary.chmod(0o700)

    def run_pi(self, *arguments, model="llama-cpp/test-local", exit_code=0):
        source = Path(__file__).with_name("pi-task.sh").read_text()
        wrapper = self.root / "pi-task"
        bash = shutil.which("bash")
        self.assertIsNotNone(bash)
        wrapper.write_text(f"#!{bash}\nset -euo pipefail\n" + source.replace(
            "@pi@", shlex.quote(str(self.binary))
        ).replace("@local-model@", shlex.quote(model)))
        wrapper.chmod(0o700)
        return subprocess.run(
            [str(wrapper), *arguments], text=True, capture_output=True,
            env={**os.environ, "PI_TEST_EXIT": str(exit_code)}, check=False,
        )

    def test_plain_pi_task_is_local_and_has_no_automatic_resources_or_tools(self):
        result = self.run_pi()
        self.assertEqual(result.returncode, 0, result.stderr)
        args = json.loads(result.stdout)
        for flag in ["--no-context-files", "--no-skills", "--no-prompt-templates",
                     "--no-extensions", "--no-mcp", "--no-tools", "--offline"]:
            self.assertIn(flag, args)
        self.assertEqual(args[args.index("--model") + 1], "llama-cpp/test-local")
        self.assertEqual(args[args.index("--thinking") + 1], "low")

    def test_task_arguments_are_preserved_after_defaults(self):
        task = ["--provider", "litellm", "--model", "gpt-6.1-terra", "--tools", "read",
                "--system-prompt", "A bounded brief with spaces", "Summarize this"]
        result = self.run_pi(*task)
        self.assertEqual(json.loads(result.stdout)[-len(task):], task)

    def test_local_failure_is_returned_without_retry_or_cloud_fallback(self):
        result = self.run_pi("A small task", exit_code=23)
        self.assertEqual(result.returncode, 23)
        self.assertEqual(len(result.stdout.splitlines()), 1)
        self.assertNotIn("litellm", result.stdout)

    def test_host_without_a_local_model_requires_explicit_selection(self):
        result = self.run_pi("A small task", model="")
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout, "")
        self.assertIn("--model provider/model", result.stderr)

    def test_explicit_model_works_on_a_host_without_local_models(self):
        result = self.run_pi("--model", "litellm/gpt-6.1-terra", model="")
        self.assertEqual(result.returncode, 0, result.stderr)
        args = json.loads(result.stdout)
        self.assertEqual(args[args.index("--model") + 1], "litellm/gpt-6.1-terra")

    def test_prompt_after_separator_is_not_a_model_selection(self):
        result = self.run_pi("--", "--model", "litellm/gpt-6.1-terra", model="")
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout, "")

    def test_option_values_cannot_opt_into_a_paid_default(self):
        for option in ["--name", "--system-prompt", "--append-system-prompt", "--extension"]:
            with self.subTest(option=option):
                result = self.run_pi(option, "--model", "--print", "A small task", model="")
                self.assertEqual(result.returncode, 2)
                self.assertEqual(result.stdout, "")

    def test_equals_model_syntax_does_not_bypass_explicit_selection(self):
        # Pi1.5.2 accepts a separate --model argument, not --model=value.
        result = self.run_pi("--model=litellm/gpt-6.1-terra", model="")
        self.assertEqual(result.returncode, 2)

    def test_missing_or_empty_model_cannot_use_a_paid_default(self):
        for args in [["--model"], ["--model", ""],
                     ["--model", "litellm/gpt-6.1-terra", "--model", ""]]:
            with self.subTest(args=args):
                result = self.run_pi(*args, model="")
                self.assertEqual(result.returncode, 2)
                self.assertEqual(result.stdout, "")

    def test_maintenance_commands_are_passed_through_unchanged(self):
        for args in [["--help"], ["--version"], ["--list-models", "llama-cpp"],
                     ["auth", "status"], ["mcp", "list"], ["config"]]:
            with self.subTest(args=args):
                result = self.run_pi(*args, model="")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads(result.stdout), args)


if __name__ == "__main__":
    unittest.main()
