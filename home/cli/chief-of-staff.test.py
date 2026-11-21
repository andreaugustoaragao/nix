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
from unittest.mock import patch

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
    with patch.object(sys, "path", [str(path.parent), *sys.path]):
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
            CANONICAL / "references/work-records.md",
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

    def test_read_only_review_report_delivery_stays_with_coordinator(self):
        role = (LEGACY / "reviewer.md").read_text()
        self.assertIn("complete verdict as your final response", role)
        self.assertIn("coordinator captures", role)
        self.assertNotIn("hc send", role)
        self.assertNotIn("scoped approval mechanism", role)
        contract = (CANONICAL / "references/herdr-workflow.md").read_text()
        self.assertIn("Read-only reviewers return the complete", contract)
        self.assertIn("Do not assign them messaging commands", contract)
        self.assertIn("After their completion event", contract)

    def test_discovery_handles_string_and_legacy_subagents(self):
        init_mod = load_script("init.py")
        for children in (
            ["t-other", "t-child"],
            [{"terminal": "t-other"}, {"terminal": "t-child"}],
            ["t-other", {"terminal": "t-child"}],
        ):
            with self.subTest(children=children):
                worker = {"id": "workers", "terminals": [{"terminal": "t-parent", "sub_agents": children}]}
                chief = {"id": "chief", "terminals": [{"terminal": "t-chief"}]}
                space = {"id": "space", "tabs": [worker, chief]}
                app = {"spaces": [space]}
                self.assertEqual(init_mod.find_space_and_tab(app, "t-child"), (space, worker))
                self.assertEqual(init_mod.find_space_and_tab(app, "t-chief"), (space, chief))
                self.assertEqual(init_mod.find_space_and_tab(app, "missing"), (None, None))

    def test_conflicts_detect_string_and_legacy_child_addresses(self):
        init_mod = load_script("init.py")
        for child in ("t-child", {"terminal": "t-child"}):
            with self.subTest(child=child):
                chief = {"id": "mine", "name": "chief-of-staff", "terminals": [{"terminal": "t-me"}]}
                worker = {"id": "other", "name": "Workers", "terminals": [
                    {"terminal": "t-parent", "sub_agents": [child]},
                ]}
                space = {"id": "space", "tabs": [chief, worker]}
                live = [{"address": "t-child", "state": "live", "labels": {"herdr.role": "chief-of-staff"}}]
                conflict = init_mod.check_conflict(space, chief, "t-me", live)
                self.assertEqual(conflict["reason"], "existing_chief_of_staff_terminal")
                self.assertEqual(conflict["terminal"], "t-child")
                live[0]["address"] = "outside-space"
                self.assertIsNone(init_mod.check_conflict(space, chief, "t-me", live))
                worker["name"] = "chief-of-staff"
                conflict = init_mod.check_conflict(space, chief, "t-me", [])
                self.assertEqual(conflict["reason"], "existing_chief_of_staff_tab")
                self.assertIn("t-child", conflict["terminals"])

    def run_headless_init(self, directory, *, conflicting=False, labels=True):
        module = load_script("init.py")
        coordinator = {
            "address": "t17", "state": "live", "cwd": "/home/fixture/folio",
            "labels": {
                "herdr.space": "sp638431b9e0553b425028dafce37ca4bc",
                "herdr.tab": "tbe7583d07ec91ebb95bd8d9061301c6e7",
                "herdr.role": "chief-of-staff", "herdr.name": "folio-chief",
                "where": "folio / chief-of-staff",
            } if labels else {},
            "status": {"app": "codex", "state": "working"},
        }
        worker = {
            "address": "t18", "state": "live", "cwd": "/home/fixture/folio",
            "labels": {"herdr.space": coordinator["labels"].get("herdr.space"),
                       "herdr.tab": "tb-worker", "where": "folio / Review",
                       "herdr.role": "chief-of-staff" if conflicting else "review"},
            "status": {"app": "codex", "state": "working"},
        }
        calls = []
        def query(command, **kwargs):
            calls.append(command)
            if command[0] == "herdr-app":
                raise FileNotFoundError(2, "No such file or directory", "herdr-app")
            if command[1] == "get":
                return {"t17": coordinator, "t18": worker}[command[2]]
            if command[1] == "ls":
                # Actual hc ls output omits labels and returns scalar status.
                return {"terminals": [{"address": t["address"], "state": "live",
                                       "status": "working"} for t in [coordinator, worker]]}
            if command[1] == "templates":
                return {"templates": []}
            raise AssertionError(command)
        output = io.StringIO()
        with patch.dict(os.environ, {"HC_TERMINAL_ID": "t17", "HC_TERMINAL_SOCKET": "/tmp/headless-core.sock",
                                     "XDG_STATE_HOME": str(directory)}), \
             patch.object(sys, "argv", ["chief-of-staff-init"]), \
             patch.object(module, "run_json", side_effect=query), \
             patch.object(module, "run_cmd") as writes, redirect_stdout(output):
            result = module.main()
        return result, json.loads(output.getvalue()), writes, calls

    def test_headless_init_registers_native_space_without_changing_layout(self):
        with tempfile.TemporaryDirectory() as temporary:
            result, response, writes, calls = self.run_headless_init(Path(temporary))
            self.assertEqual(result, 0)
            self.assertEqual(response["status"], "ok")
            self.assertFalse(response["desktop"])
            self.assertEqual(response["space"]["id"], "sp638431b9e0553b425028dafce37ca4bc")
            self.assertEqual(response["other_live_terminals"][0]["address"], "t18")
            registration = json.loads((Path(response["portfolio_dir"]) / "work/registration.json").read_text())
            self.assertEqual(registration["coordinator"], "t17")
            self.assertEqual(registration["space"], response["space"]["id"])
            writes.assert_not_called()
            self.assertIn(["hc", "get", "t18"], calls)

    def test_headless_init_rejects_conflict_and_missing_space_labels(self):
        for options, expected in [({"conflicting": True}, "conflict"), ({"labels": False}, "error")]:
            with self.subTest(options=options), tempfile.TemporaryDirectory() as temporary:
                result, response, writes, _ = self.run_headless_init(Path(temporary), **options)
                self.assertNotEqual(result, 0)
                self.assertEqual(response["status"], expected)
                self.assertEqual(list(Path(temporary).rglob("registration.json")), [])
                writes.assert_not_called()

    def run_headless_spawn(self, directory, *, tab=None, name=None, labels=True, full=False, desktop_error=None, pending=False, unnamed=False, harness="shell", command=None):
        module = load_script("spawn.py")
        portfolio = directory / "portfolio"
        portfolio.mkdir()
        (portfolio / "portfolio.md").write_text("# Existing coordinator\n")
        chief = {"address": "t17", "state": "live", "cwd": "/project",
                 "labels": {"herdr.space": "sp-native", "herdr.tab": "tb-chief",
                            "herdr.role": "chief-of-staff", "where": "project / chief-of-staff"} if labels else {}}
        workers = [{"address": f"t{n}", "state": "live", "labels": {
            "herdr.space": "sp-native", "herdr.tab": "tb-worker", "where": "project / Worker"}}
            for n in range(20, 24 if full else 21)]
        if unnamed:
            for worker in workers:
                worker["labels"].pop("where")
        if pending:
            workers = [{"address": "t29", "state": "live", "labels": {"herdr.space": "sp-native"}}]
        records = {record["address"]: record for record in [chief, *workers]}
        calls = []
        def query(command, **kwargs):
            calls.append(command)
            if command[0] == "herdr-app":
                if desktop_error:
                    raise desktop_error
                raise FileNotFoundError(2, "missing", "herdr-app")
            if command[1] == "get":
                return records[command[2]]
            if command[1] == "ls":
                return {"terminals": [{"address": address, "state": "live"} for address in records]}
            if command[1] == "run":
                return {"address": "t30"}
            raise AssertionError(command)
        argv = ["chief-of-staff-spawn", "--portfolio", str(portfolio), "--task-id", "T001",
                "--goal", "Verify native child", "--role", "check", "--name", "t001-check",
                "--cwd", "/project", "--harness", harness]
        if tab:
            argv.extend(["--tab-id", tab])
        if name:
            argv.extend(["--tab-name", name])
        argv.extend(["--", *(command or ["printf", "supplied argument"])])
        output = io.StringIO()
        with patch.dict(os.environ, {"HC_TERMINAL_ID": "t17", "HC_TERMINAL_SOCKET": "/tmp/core.sock"}), \
             patch.object(sys, "argv", argv), patch.object(module, "run_json", side_effect=query), \
             patch.object(module, "run_cmd") as writes, redirect_stdout(output):
            result = module.main()
        writes.assert_not_called()
        return result, json.loads(output.getvalue()), calls, portfolio

    def test_full_and_minimal_pi_commands_share_engine_identity(self):
        for command in ("pi", "pi-task", "/nix/store/fixture/bin/pi-task"):
            with self.subTest(command=command), tempfile.TemporaryDirectory() as temporary:
                result, response, calls, portfolio = self.run_headless_spawn(
                    Path(temporary), harness="auto", command=[command, "--offline"])
                self.assertEqual(result, 0)
                self.assertEqual(response["harness"], "pi")
                self.assertEqual(next(call for call in calls if call[:2] == ["hc", "run"])[-3:],
                                 ["--", command, "--offline"])
                self.assertIn("pi", (portfolio / "tasks/T001.md").read_text())

    def test_headless_spawn_reuses_validated_native_worker_tab(self):
        for selector in ({"tab": "tb-worker"}, {"name": "Worker"}, {}):
            with self.subTest(selector=selector), tempfile.TemporaryDirectory() as temporary:
                result, response, calls, portfolio = self.run_headless_spawn(Path(temporary), **selector)
                self.assertEqual(result, 0)
                self.assertFalse(response["desktop"])
                self.assertEqual(response["tab"]["id"], "tb-worker")
                self.assertEqual(response["tab"]["name"], "Worker")
                self.assertFalse(response["tab"]["pending"])
                launch = next(call for call in calls if call[:2] == ["hc", "run"])
                self.assertIn("herdr.space=sp-native", launch)
                self.assertIn("herdr.tab=tb-worker", launch)
                self.assertNotIn("herdr.tab=tb-chief", launch)
                self.assertEqual(launch[-3:], ["--", "printf", "supplied argument"])
                self.assertIn("`t30`", (portfolio / "tasks/T001.md").read_text())

    def test_headless_spawn_defers_new_tab_placement_without_inventing_a_tab(self):
        for options in ({"name": "New topic"}, {"full": True}):
            with self.subTest(options=options), tempfile.TemporaryDirectory() as temporary:
                result, response, calls, portfolio = self.run_headless_spawn(Path(temporary), **options)
                self.assertEqual(result, 0)
                self.assertIsNone(response["tab"]["id"])
                self.assertIsNone(response["tab"]["name"])
                self.assertTrue(response["tab"]["pending"])
                launch = next(call for call in calls if call[:2] == ["hc", "run"])
                self.assertFalse(any(item.startswith("herdr.tab=") for item in launch))
                self.assertEqual(sum(call[0] == "herdr-app" for call in calls), 1)
                self.assertIn("placement pending", (portfolio / "tasks/T001.md").read_text())

    def test_headless_spawn_does_not_reuse_a_child_awaiting_controller_placement(self):
        with tempfile.TemporaryDirectory() as temporary:
            result, response, calls, _ = self.run_headless_spawn(Path(temporary), pending=True)
            self.assertEqual(result, 0)
            self.assertIsNone(response["tab"]["id"])
            self.assertIsNone(response["tab"]["name"])
            self.assertTrue(response["tab"]["pending"])
            launch = next(call for call in calls if call[:2] == ["hc", "run"])
            self.assertFalse(any(item.startswith("herdr.tab=") for item in launch))

    def test_headless_spawn_records_confirmed_tab_id_when_name_is_unknown(self):
        with tempfile.TemporaryDirectory() as temporary:
            result, response, _, portfolio = self.run_headless_spawn(Path(temporary), unnamed=True)
            self.assertEqual(result, 0)
            self.assertEqual(response["tab"]["id"], "tb-worker")
            self.assertIsNone(response["tab"]["name"])
            self.assertFalse(response["tab"]["pending"])
            record = (portfolio / "tasks/T001.md").read_text()
            self.assertIn("tab `tb-worker`", record)
            self.assertNotIn("placement pending", record)

    def test_headless_spawn_rejects_chief_missing_and_full_explicit_tabs(self):
        for options in ({"tab": "tb-chief"}, {"tab": "other/tb-worker"},
                        {"tab": "tb-missing"}, {"tab": "tb-worker", "full": True}, {"labels": False}):
            with self.subTest(options=options), tempfile.TemporaryDirectory() as temporary:
                result, response, calls, portfolio = self.run_headless_spawn(Path(temporary), **options)
                self.assertNotEqual(result, 0)
                self.assertEqual(response["error"], "tab_resolution_failed")
                self.assertFalse(any(call[:2] == ["hc", "run"] for call in calls))
                self.assertFalse(list((portfolio / "tasks").glob("*.md")))

    def test_spawn_does_not_treat_desktop_transport_errors_as_headless(self):
        import subprocess
        with tempfile.TemporaryDirectory() as temporary:
            result, response, calls, _ = self.run_headless_spawn(
                Path(temporary), desktop_error=subprocess.CalledProcessError(1, "herdr-app"))
            self.assertNotEqual(result, 0)
            self.assertEqual(response["error"], "tab_resolution_failed")
            self.assertEqual(calls, [["herdr-app", "ls"]])

    def test_init_and_spawn_helpers_end_to_end(self):
        init_mod = load_script("init.py")
        spawn_mod = load_script("spawn.py")
        work_mod = load_script("work.py")

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
                    task_id = f"T00{idx}"
                    for kind, fields in (
                        ("task", {"outcome": f"Goal {idx}", "next_action": "Implement"}),
                        ("plan", {"checkpoints": [{"id": "implement", "title": "Implement goal",
                                                  "depends": [], "acceptance": "Goal verified"}]}),
                        ("lifecycle", {"state": "active", "next_action": "Implement"}),
                    ):
                        work_mod.publish(portfolio_dir, {
                            "id": f"{task_id}-{kind}", "kind": kind, "task": task_id, **fields,
                        })
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


def load_tests(loader, tests, pattern):
    suite = unittest.TestSuite()
    suite.addTests(tests)
    suite.addTests(loader.discover(str(CANONICAL / "tests"), pattern="test_*.py"))
    return suite


if __name__ == "__main__":
    unittest.main()
