#!/usr/bin/env python3
"""Structural skill regressions; not a test of autonomous agent scheduling."""

from pathlib import Path
from contextlib import redirect_stdout
import importlib.util
import io
import json
import os
import re
import stat
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent
CANONICAL = ROOT / "chief-of-staff"
LEGACY = ROOT / "herdr-coordinate"
STATES = {
    "queued", "active", "reviewing", "integrating", "blocked", "paused",
    "done", "cancelled",
}


def load_script(name: str):
    path = CANONICAL / "scripts" / name
    spec = importlib.util.spec_from_file_location(name.removesuffix(".py"), path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class ChiefOfStaffSkillTests(unittest.TestCase):
    def test_portable_skill_frontmatter(self):
        for directory in (CANONICAL, LEGACY):
            with self.subTest(skill=directory.name):
                content = (directory / "SKILL.md").read_text()
                self.assertTrue(content.startswith("---\n"))
                frontmatter = content.split("---\n", 2)[1]
                fields = dict(line.split(": ", 1) for line in frontmatter.splitlines())
                self.assertEqual(fields["name"], directory.name)
                self.assertRegex(fields["name"], r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
                self.assertLessEqual(len(fields["name"]), 64)
                self.assertTrue(fields["description"].strip())
                self.assertLessEqual(len(fields["description"]), 1024)

    def test_bundled_references_resolve(self):
        links = []
        for path in CANONICAL.rglob("*.md"):
            for link in re.findall(r"\[[^\]]+\]\(([^)]+)\)", path.read_text()):
                target = (path.parent / link).resolve()
                self.assertTrue(target.is_relative_to(CANONICAL.resolve()))
                self.assertTrue(target.is_file(), f"Missing reference: {path}: {link}")
                links.append(target)
        self.assertEqual(set(links), {
            CANONICAL / "references/herdr-workflow.md",
            CANONICAL / "references/routing.md",
            CANONICAL / "references/routing-evidence.md",
            CANONICAL / "templates/portfolio.md",
            CANONICAL / "templates/task.md",
        })

    def test_alias_has_no_second_execution_contract(self):
        alias = (LEGACY / "SKILL.md").read_text()
        self.assertIn("~/.agents/skills/chief-of-staff/SKILL.md", alias)
        self.assertIn("Reuse the current conversation's portfolio", alias)
        self.assertNotIn("hc run", alias)
        self.assertNotIn("../chief-of-staff", alias)  # Separate Nix store roots.
        metadata = (LEGACY / "agents/openai.yaml").read_text()
        self.assertIn("$chief-of-staff", metadata)
        self.assertIn("allow_implicit_invocation: false", metadata)

    def test_states_and_record_templates(self):
        skill = (CANONICAL / "SKILL.md").read_text()
        declared = set(re.findall(r"^\| `([a-z]+)` \|", skill, re.MULTILINE))
        self.assertEqual(declared, STATES)
        portfolio = (CANONICAL / "templates/portfolio.md").read_text()
        task = (CANONICAL / "templates/task.md").read_text()
        for field in ("Coordinator terminal", "Owning core", "Dependencies",
                      "Live worker inventory", "Handoff / recovery"):
            self.assertIn(field, portfolio)
        for field in ("State: queued", "Previous stage", "Original user request",
                      "Acceptance checks", "Baseline and isolation",
                      "Assignments and launch intents", "Integration and verification"):
            self.assertIn(field, task)

    def test_harness_selection_and_safety_contract_survive(self):
        contract = (CANONICAL / "references/herdr-workflow.md").read_text()
        for harness in ("Cursor", "OpenCode", "Codex"):
            self.assertIn(harness, contract)
        self.assertIn("different harness", contract)
        self.assertIn("session resume ID", contract)
        for safeguard in ("never silently", "Workers must\nnot delegate",
                          "first_message.sent", "Never force-send into a permission",
                          "without committing, stashing or", "Never stop/restart core"):
            self.assertIn(safeguard, contract)
        self.assertNotIn("The mode ends\nwith the task", contract)

    def test_client_neutral_roles_and_canonical_codex_metadata(self):
        for filename in ("implementer.md", "reviewer.md"):
            role = (LEGACY / filename).read_text()
            self.assertIn("chief-of-staff-coordinated", role)
            self.assertNotIn("Codex-coordinated", role)
        metadata = (CANONICAL / "agents/openai.yaml").read_text()
        self.assertIn('display_name: "Chief of staff"', metadata)
        self.assertIn("$chief-of-staff", metadata)
        self.assertIn("allow_implicit_invocation: false", metadata)

    def test_init_and_spawn_helpers_end_to_end(self):
        init_mod = load_script("init.py")
        spawn_mod = load_script("spawn.py")

        space = {
            "id": "sp1",
            "name": "nix",
            "folder": "/tmp/nix",
            "tabs": [
                {"id": "tb1", "name": "1", "terminals": [{"terminal": "t1", "pane": "p1"}]},
                {"id": "tb2", "name": "Worker", "terminals": [{"terminal": "t2", "pane": "p2"}]},
            ],
        }
        self.assertIsNone(init_mod.check_conflict(space, space["tabs"][0], "t1", [{"address": "t1", "state": "live", "labels": {}}]))
        self.assertIsNotNone(
            init_mod.check_conflict(
                space,
                space["tabs"][0],
                "t1",
                [{"address": "t2", "state": "live", "labels": {"herdr.role": "chief-of-staff"}}],
            )
        )
        self.assertIsNone(spawn_mod.choose_worker_tab(space, "tb1", None, "NewTopic"))
        picked = spawn_mod.choose_worker_tab(space, "tb1", None, "Worker")
        self.assertEqual(picked["id"], "tb2")

        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            bin_dir = tmp_path / "bin"
            bin_dir.mkdir()
            calls_log = tmp_path / "calls.jsonl"

            def write_exec(name: str, body: str):
                p = bin_dir / name
                p.write_text(f"#!{sys.executable}\n" + body)
                p.chmod(p.stat().st_mode | stat.S_IEXEC)

            write_exec(
                "herdr-app",
                f"""
import json, sys
with open({str(calls_log)!r}, "a") as f:
    f.write(json.dumps(["herdr-app", *sys.argv[1:]]) + "\\n")
if sys.argv[1] == "ls":
    print(json.dumps({{
        "spaces": [{{
            "id": "sp1", "name": "nix", "folder": "/tmp/nix",
            "tabs": [
                {{"id": "tb1", "name": "1", "terminals": [{{"terminal": "t1", "pane": "p1", "app": "codex", "status": "idle"}}]}},
                {{"id": "tb2", "name": "Worker", "terminals": [{{"terminal": "t2", "pane": "p2", "app": "pi", "status": "working"}}]}},
            ],
        }}]
    }}))
else:
    print(json.dumps({{"ok": True}}))
""",
            )
            write_exec(
                "hc",
                f"""
import json, sys
with open({str(calls_log)!r}, "a") as f:
    f.write(json.dumps(["hc", *sys.argv[1:]]) + "\\n")
cmd = sys.argv[1]
if cmd == "ls":
    print(json.dumps({{"terminals": [
        {{"address": "t1", "state": "live", "cwd": "/tmp/nix", "labels": {{}}}},
        {{"address": "t2", "state": "live", "cwd": "/tmp/nix", "labels": {{"herdr.space": "sp1"}}}},
    ]}}))
elif cmd == "get":
    print(json.dumps({{"address": sys.argv[2], "state": "live", "cwd": "/tmp/nix"}}))
elif cmd == "templates":
    print(json.dumps({{"templates": [{{"name": "dev-review", "command": "codex"}}]}}))
elif cmd == "run":
    print(json.dumps({{"address": "t9"}}))
else:
    print(json.dumps({{"ok": True}}))
""",
            )
            write_exec(
                "herdr-codex-name",
                f"""
import json, sys
with open({str(calls_log)!r}, "a") as f:
    f.write(json.dumps(["herdr-codex-name", *sys.argv[1:]]) + "\\n")
print(json.dumps({{"address": sys.argv[1], "named": True, "thread_id": "thr_123", "thread_name": sys.argv[2] + " [" + sys.argv[1] + "]"}}))
""",
            )

            old_env = os.environ.copy()
            old_argv = sys.argv[:]
            try:
                os.environ["PATH"] = f"{bin_dir}:{old_env.get('PATH', '')}"
                os.environ["XDG_STATE_HOME"] = str(tmp_path / "state")
                os.environ["HC_TERMINAL_ID"] = "t1"
                os.environ["HC_TERMINAL_SOCKET"] = "/tmp/hc.sock"
                os.environ["CODEX_THREAD_ID"] = "thread-abc"

                # First init creates portfolio, labels terminal, renames tab.
                sys.argv = ["chief-of-staff-init"]
                buf = io.StringIO()
                with redirect_stdout(buf):
                    rc = init_mod.main()
                self.assertEqual(rc, 0)
                first = json.loads(buf.getvalue())
                self.assertEqual(first["status"], "ok")
                self.assertFalse(first["reused"])
                portfolio_dir = Path(first["portfolio_dir"])
                self.assertTrue((portfolio_dir / "portfolio.md").is_file())
                self.assertEqual(stat.S_IMODE(portfolio_dir.stat().st_mode), 0o700)

                # Second init reuses active portfolio.
                buf = io.StringIO()
                with redirect_stdout(buf):
                    rc = init_mod.main()
                self.assertEqual(rc, 0)
                second = json.loads(buf.getvalue())
                self.assertTrue(second["reused"])
                self.assertEqual(second["portfolio_dir"], first["portfolio_dir"])

                # Spawn two tasks into worker tab tb2.
                for idx in (1, 2):
                    sys.argv = [
                        "chief-of-staff-spawn",
                        "--portfolio", str(portfolio_dir),
                        "--goal", f"Goal {idx}",
                        "--role", "impl",
                        "--name", f"t00{idx}-impl",
                        "--cwd", "/tmp/nix",
                        "--tab-name", "Worker",
                        "--", "codex",
                    ]
                    buf = io.StringIO()
                    with redirect_stdout(buf):
                        rc = spawn_mod.main()
                    self.assertEqual(rc, 0)
                    res = json.loads(buf.getvalue())
                    self.assertEqual(res["task_id"], f"T00{idx}")
                    self.assertEqual(res["codex"]["thread_id"], "thr_123")

                portfolio_md = (portfolio_dir / "portfolio.md").read_text()
                self.assertIn("| T001 |", portfolio_md)
                self.assertIn("| T002 |", portfolio_md)
                self.assertNotIn("\n\n| T002 |", portfolio_md)
                self.assertIn("T001", (portfolio_dir / "tasks/T001.md").read_text())
            finally:
                sys.argv = old_argv
                os.environ.clear()
                os.environ.update(old_env)


if __name__ == "__main__":
    unittest.main()
