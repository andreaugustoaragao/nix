"""Observable Work publication contract; all portfolios are isolated temporary fixtures."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/work.py"
sys.path.insert(0, str(SCRIPT.parent))
import work


def cp(key, depends=None, title=None):
    return {"id": key, "title": title or key, "depends": depends or [], "acceptance": f"Evidence for {key}"}


class WorkContract(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.env = patch.dict(os.environ, {"HC_TERMINAL_ID": "t1", "HC_TERMINAL_SOCKET": "/fixture/core", "XDG_STATE_HOME": str(self.base / "state")})
        self.env.start()
        self.addCleanup(self.env.stop)
        self.portfolio = self.base / "portfolio"
        self.portfolio.mkdir()
        (self.portfolio / "portfolio.md").write_text("Fixture narrative must survive\n")
        (self.portfolio / "tasks").mkdir()
        (self.portfolio / "tasks/T000.md").write_text("Legacy task without a plan\n")
        work.register(self.portfolio, "fixture-space", fixture=True)
        self.number = 0
        self.put("task", outcome="Fixture result", next_action="Implement")

    def put(self, kind, **extra):
        self.number += 1
        event = {"id": f"event-{self.number}", "task": "T001", "kind": kind, **extra}
        return work.publish(self.portfolio, event, at="2026-01-01T10:00:00Z")

    def task(self):
        return work.rebuild(self.portfolio)["tasks"][0]

    def plan(self):
        self.put("plan", checkpoints=[cp("build"), cp("check", ["build"])])

    def verify(self, key):
        self.put("verify", checkpoint=key, summary=f"Checked {key}", evidence=["/fixture/results.txt: command and exit 0"])

    def test_baseline_revision_and_dependency_verification(self):
        self.plan()
        original = self.task()["baseline"]
        self.verify("build")
        self.verify("check")
        self.put("revise", reason="Changed the build criterion", checkpoints=[cp("build", title="New build"), cp("check", ["build"]), cp("ship", ["check"])])
        task = self.task()
        self.assertEqual(original, task["baseline"])
        self.assertEqual([None, None, None], [p["verification"] for p in task["current"]])
        self.assertEqual(0, task["history"][-1]["verified"])
        self.assertEqual(3, task["history"][-1]["scope"])
        self.assertEqual(["build", "check"], task["revisions"][-1]["changed"])
        with self.assertRaises(work.RecordError):
            self.verify("check")

    def test_idempotence_and_crash_between_event_and_snapshot(self):
        self.plan()
        event = {"id": "stable", "task": "T001", "kind": "verify", "checkpoint": "build", "summary": "Real artifact", "evidence": ["/fixture/build.log"]}
        work.publish(self.portfolio, event, at="2026-01-01T10:00:01Z")
        saved = work.events(self.portfolio)
        (self.portfolio / "work/snapshot.json").write_text("invalid after simulated crash")
        self.assertEqual("duplicate", work.publish(self.portfolio, event)["status"])
        self.assertEqual(saved, work.events(self.portfolio))
        self.assertEqual(1, self.task()["history"][-1]["verified"])
        with self.assertRaises(work.RecordError):
            work.publish(self.portfolio, {**event, "summary": "different"})
        with self.assertRaises(work.RecordError):
            self.verify("build")

    def test_activity_never_changes_progress_or_check_in(self):
        self.plan()
        before = self.task()
        self.put("worker", terminal="t2", status="working", summary="Compiler is busy")
        after = self.task()
        self.assertEqual(before["check_in"], after["check_in"])
        self.assertIsNone(after["last_verified"])
        with self.assertRaises(work.RecordError):
            self.put("check-in", step="build", summary="Long compile", next_action="Read log", quiet_seconds=900)
        self.put("check-in", step="build", summary="Long compile", next_action="Read log", quiet_seconds=900, quiet_reason="A declared quiet compile")
        self.assertEqual("2026-01-01T10:15:00Z", self.task()["check_in"]["due"])

    def test_ownership_and_bootstrap(self):
        with self.assertRaises(work.RecordError):
            work.require_plan(self.portfolio, "T001")
        self.plan()
        self.put("lifecycle", state="active", next_action="Build")
        work.require_plan(self.portfolio, "T001")
        with patch.dict(os.environ, {"HC_TERMINAL_ID": "t2"}):
            with self.assertRaises(work.RecordError):
                self.put("worker", terminal="t2", status="working", summary="I am a worker")
            with self.assertRaises(work.RecordError):
                work.require_plan(self.portfolio, "T001")

    def test_blockers_and_done_require_evidence(self):
        self.plan()
        self.put("block", issue="decision", message="Choose storage", needs_user=True, checkpoint="build")
        with self.assertRaises(work.RecordError):
            self.verify("build")
        self.put("resolve", issue="decision", summary="User chose local")
        self.verify("build")
        with self.assertRaises(work.RecordError):
            self.put("lifecycle", state="done", next_action="Hand off")
        self.verify("check")
        self.put("lifecycle", state="done", next_action="Hand off")
        self.assertEqual("done", self.task()["state"])

    def test_partial_files_and_invalid_records_do_not_invent_progress(self):
        self.plan()
        event_dir = self.portfolio / "work/events"
        (event_dir / ".pending-interrupted").write_text('{"seq":')
        self.assertIsNone(self.task()["last_verified"])
        (event_dir / "000000000003.json").write_text('{"seq":')
        with self.assertRaises(work.RecordError):
            work.rebuild(self.portfolio)
        self.assertIsNone(json.loads((self.portfolio / "work/snapshot.json").read_text())["tasks"][0]["last_verified"])

    def test_cli_rejects_invalid_input_and_preserves_legacy(self):
        event = self.base / "invalid.json"
        event.write_text(json.dumps({"id": "bad", "kind": "verify", "task": "T001", "checkpoint": "build", "summary": "trust me", "evidence": []}))
        result = subprocess.run([sys.executable, str(SCRIPT), "--portfolio", str(self.portfolio), "publish", "--event", str(event)], capture_output=True, text=True)
        self.assertEqual(2, result.returncode)
        self.assertIn("evidence", result.stderr)
        self.assertEqual(["T000"], work.rebuild(self.portfolio)["legacy"])
        self.assertEqual("Fixture narrative must survive\n", (self.portfolio / "portfolio.md").read_text())

    def test_concurrent_space_registration_preserves_both_coordinators(self):
        children = []
        for i in (2, 3):
            portfolio = self.base / f"portfolio-{i}"
            portfolio.mkdir()
            (portfolio / "portfolio.md").write_text("Concurrent isolated fixture\n")
            env = dict(os.environ, HC_TERMINAL_ID=f"t{i}")
            children.append(subprocess.Popen(
                [sys.executable, "-c", "import sys; from pathlib import Path; import work; work.register(Path(sys.argv[1]), sys.argv[2], fixture=True)", str(portfolio), f"space-{i}"],
                cwd=SCRIPT.parent, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True))
        for child in children:
            _, error = child.communicate(timeout=10)
            self.assertEqual(0, child.returncode, error)
        for i in (2, 3):
            source = work.read_json(work.discovery_path(f"space-{i}"))
            registration = work.read_json(Path(source["portfolio"]) / "work/registration.json")
            self.assertEqual(f"t{i}", registration["coordinator"])

    def test_fixture_cli_help_and_invalid_paths_never_write(self):
        fixture_script = SCRIPT.with_name("work-fixtures.py")
        before = set(self.base.iterdir())
        for arguments, expected in ((["--help"], 0), (["--unknown"], 2), (["relative-output"], 2), ([str(self.base / "--help")], 2)):
            result = subprocess.run([sys.executable, str(fixture_script), *arguments], cwd=self.base, capture_output=True, text=True)
            self.assertEqual(expected, result.returncode, result.stderr)
            self.assertEqual(before, set(self.base.iterdir()))

    def test_completed_task_requires_explicit_reactivation_before_revision(self):
        self.plan()
        self.verify("build")
        self.verify("check")
        self.put("lifecycle", state="done", next_action="Hand off")
        before = work.events(self.portfolio)
        revised = [cp("build", title="New build"), cp("check", ["build"])]
        with self.assertRaisesRegex(work.RecordError, "reactivate"):
            self.put("revise", reason="New acceptance", checkpoints=revised)
        self.assertEqual(before, work.events(self.portfolio))
        self.assertEqual("done", self.task()["state"])
        self.put("lifecycle", state="active", next_action="Recheck changed criteria")
        self.put("revise", reason="New acceptance", checkpoints=revised)
        self.assertEqual("active", self.task()["state"])
        self.assertIsNone(self.task()["current"][0]["verification"])

    def test_history_preserves_removed_checkpoint_criteria_and_evidence(self):
        self.plan()
        self.verify("build")
        accepted = self.task()["current"][0]
        self.put("revise", reason="Remove build checkpoint", checkpoints=[cp("replacement")])
        task = self.task()
        historical = next(h for h in task["history"] if h["kind"] == "verify")
        self.assertEqual(accepted, historical["checkpoint"])
        self.assertEqual("Evidence for build", historical["checkpoint"]["acceptance"])
        self.assertEqual(["/fixture/results.txt: command and exit 0"], historical["checkpoint"]["verification"]["evidence"])
        self.assertEqual(["replacement"], [p["id"] for p in task["current"]])
        self.assertEqual(["build", "check"], [p["id"] for p in task["baseline"]["checkpoints"]])

    def project_extra(self, extra):
        records = work.events(self.portfolio)
        for i, event in enumerate(extra, start=len(records) + 1):
            records.append({"seq": i, "at": "2026-01-01T10:00:00Z", "event": work.validate_event(event)})
        registration = work.read_json(self.portfolio / "work/registration.json")
        return work.project(self.portfolio, registration, records)

    def test_projection_keeps_all_unresolved_issues_and_counts_omitted_resolutions(self):
        extra = []
        for i in range(257):
            extra += [{"id": f"block-{i}", "kind": "block", "task": "T001", "issue": f"closed-{i}", "message": "Resolved decision", "needs_user": True},
                      {"id": f"resolve-{i}", "kind": "resolve", "task": "T001", "issue": f"closed-{i}", "summary": "Resolved"}]
        extra += [{"id": f"open-{i}", "kind": "block", "task": "T001", "issue": f"open-{i}", "message": "Pending decision", "needs_user": True} for i in range(257)]
        snapshot = self.project_extra(extra)
        task = snapshot["tasks"][0]
        self.assertEqual(321, len(task["issues"]))
        self.assertEqual(193, task["issues_omitted"])
        self.assertEqual(257, sum(not i["resolved"] for i in task["issues"]))
        self.assertLessEqual(len(work.encode(snapshot).encode()), work.SNAPSHOT_LIMIT)
        with patch.object(work, "SNAPSHOT_LIMIT", 1024):
            with self.assertRaisesRegex(work.RecordError, "unresolved issues exceed"):
                self.project_extra(extra)

    def test_worker_roster_survives_report_history_truncation(self):
        extra = [{"id": "worker-first", "kind": "worker", "task": "T001", "terminal": "t2", "status": "working", "summary": "Still present"}]
        extra += [{"id": f"worker-other-{i}", "kind": "worker", "task": "T001", "terminal": "t3", "status": "working", "summary": str(i)} for i in range(64)]
        task = self.project_extra(extra)["tasks"][0]
        self.assertEqual({"t3"}, {a["terminal"] for a in task["activity"]})
        self.assertEqual(1, task["activity_omitted"])
        self.assertEqual({"t2", "t3"}, {a["terminal"] for a in task["workers"]})
        self.assertEqual("worker-first", task["workers"][0]["event"])


if __name__ == "__main__":
    unittest.main()
