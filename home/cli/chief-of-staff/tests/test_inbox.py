"""Behavioral tests for stateless worker-report spooling, read-only bounded digest, confinement, paging, and concurrency."""

import json
import math
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT_DIR = Path(__file__).resolve().parents[1] / "scripts"
INBOX_CLI = SCRIPT_DIR / "inbox.py"
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import inbox


class WorkerReportAndDigestTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="cos-inbox-test-")
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.portfolio = self.base / "portfolio"
        self.portfolio.mkdir(mode=0o700)
        (self.portfolio / "portfolio.md").write_text("# Fixture portfolio\n- Mode: active\n", encoding="utf-8")
        self.art_t1 = self.portfolio / "artifacts" / "T001"

    def run_cli(self, *args: str, env: dict | None = None) -> subprocess.CompletedProcess:
        return subprocess.run(
            [sys.executable, str(INBOX_CLI), *args],
            capture_output=True,
            text=True,
            env=env or os.environ.copy(),
            timeout=15,
        )

    def test_zero_hc_or_scheduler_side_effects_and_idempotent_explicit_ids(self):
        # Poison PATH with a fake `hc` that fails loudly if ever invoked.
        bin_dir = self.base / "poison-bin"
        bin_dir.mkdir()
        hc_marker = self.base / "hc-was-called"
        fake_hc = bin_dir / "hc"
        fake_hc.write_text(f"#!{sys.executable}\nfrom pathlib import Path\nPath({str(hc_marker)!r}).write_text('called')\nraise SystemExit(99)\n")
        fake_hc.chmod(0o700)

        env = os.environ.copy()
        env["PATH"] = f"{bin_dir}{os.pathsep}{env.get('PATH', '')}"
        env["HC_TERMINAL_ID"] = "t2"

        # Empty digest on fresh portfolio is read-only and creates zero directories/files.
        before_entries = sorted(p.name for p in self.portfolio.iterdir())
        r_empty = self.run_cli("--portfolio", str(self.portfolio), "digest", "--task", "T001", env=env)
        self.assertEqual(0, r_empty.returncode, r_empty.stderr)
        empty_digest = json.loads(r_empty.stdout)
        self.assertTrue(empty_digest["read_only"])
        self.assertTrue(empty_digest["complete"])
        self.assertEqual([], empty_digest["actionable"])
        self.assertEqual(before_entries, sorted(p.name for p in self.portfolio.iterdir()))

        # Progress spools with notify_coordinator=False; question emits notify_coordinator=True + short pointer.
        r_prog = self.run_cli(
            "worker-report",
            "--artifact-dir", str(self.art_t1),
            "--task", "T001",
            "--id", "rep-prog-1",
            "--kind", "progress",
            "--summary", "Compiled module A",
            env=env,
        )
        self.assertEqual(0, r_prog.returncode, r_prog.stderr)
        d_prog = json.loads(r_prog.stdout)
        self.assertEqual("recorded", d_prog["status"])
        self.assertFalse(d_prog["notify_coordinator"])
        self.assertIsNone(d_prog["send_line"])

        r_q = self.run_cli(
            "worker-report",
            "--artifact-dir", str(self.art_t1),
            "--task", "T001",
            "--id", "rep-q-1",
            "--kind", "question",
            "--summary", "Approve schema v2?",
            env=env,
        )
        self.assertEqual(0, r_q.returncode, r_q.stderr)
        d_q = json.loads(r_q.stdout)
        self.assertEqual("recorded", d_q["status"])
        self.assertTrue(d_q["notify_coordinator"])
        self.assertIn("rep-q-1", d_q["send_line"])

        # Exact retry is idempotent duplicate; conflicting summary or terminal for same ID fails closed.
        r_q_dup = self.run_cli(
            "worker-report",
            "--artifact-dir", str(self.art_t1),
            "--task", "T001",
            "--id", "rep-q-1",
            "--kind", "question",
            "--summary", "Approve schema v2?",
            env=env,
        )
        self.assertEqual(0, r_q_dup.returncode)
        self.assertEqual("duplicate", json.loads(r_q_dup.stdout)["status"])

        r_q_conflict_sum = self.run_cli(
            "worker-report",
            "--artifact-dir", str(self.art_t1),
            "--task", "T001",
            "--id", "rep-q-1",
            "--kind", "question",
            "--summary", "Different question text",
            env=env,
        )
        self.assertEqual(2, r_q_conflict_sum.returncode)

        r_q_conflict_term = self.run_cli(
            "worker-report",
            "--artifact-dir", str(self.art_t1),
            "--task", "T001",
            "--terminal", "t9",
            "--id", "rep-q-1",
            "--kind", "question",
            "--summary", "Approve schema v2?",
            env=env,
        )
        self.assertEqual(2, r_q_conflict_term.returncode)

        # Verify zero hc invocations and zero scheduler/Work directories created.
        self.assertFalse(hc_marker.exists())
        self.assertFalse((self.portfolio / "inbox").exists())
        self.assertFalse((self.portfolio / "work").exists())
        # Only independent immutable packet files exist in packets/ (no shared mutable index/watermark file).
        self.assertEqual(["packets"], [p.name for p in self.art_t1.iterdir()])
        self.assertEqual({"id--rep-prog-1.json", "id--rep-q-1.json"}, {p.name for p in (self.art_t1 / "packets").iterdir()})

    def test_concurrent_multi_worker_processes_remote_terminals_and_over_64_progress_lossless(self):
        # 1. >64 progress reports (80 progress) interleaved with question, blocker, error, and two worker completions (t2 + remote vps/t3).
        inbox.write_worker_report(artifact_dir=self.art_t1, task_id="T001", terminal="t2", packet_id="early-q", kind="question", summary="Keep legacy flag?")
        inbox.write_worker_report(artifact_dir=self.art_t1, task_id="T001", terminal="vps/t3", packet_id="early-err", kind="error", summary="Remote build failed")
        for idx in range(80):
            term = "t2" if idx % 2 == 0 else "vps/t3"
            inbox.write_worker_report(artifact_dir=self.art_t1, task_id="T001", terminal=term, kind="progress", summary=f"Progress step {idx}")
        inbox.write_worker_report(artifact_dir=self.art_t1, task_id="T001", terminal="t2", kind="done", summary="Done local t2")
        inbox.write_worker_report(
            artifact_dir=self.art_t1,
            task_id="T001",
            terminal="vps/t3",
            kind="done",
            summary="Done remote vps/t3",
            usage={"input_tokens": 9000, "api_cost_usd": 0.025, "cost_source": "remote-log"},
        )

        # 2. Concurrent subprocess race: 6 processes writing distinct reports + 4 racing on identical explicit ID 'race-shared'.
        procs = []
        for i in range(6):
            procs.append(subprocess.Popen(
                [
                    sys.executable, str(INBOX_CLI), "worker-report",
                    "--artifact-dir", str(self.art_t1),
                    "--task", "T001",
                    "--terminal", "vps/t3" if i % 2 else "t2",
                    "--kind", "progress",
                    "--summary", f"Concurrent progress {i}",
                ],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            ))
        race_procs = [
            subprocess.Popen(
                [
                    sys.executable, str(INBOX_CLI), "worker-report",
                    "--artifact-dir", str(self.art_t1),
                    "--task", "T001",
                    "--terminal", "t2",
                    "--id", "race-shared",
                    "--kind", "blocker",
                    "--summary", "Shared atomic blocker",
                ],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            )
            for _ in range(4)
        ]
        for p in procs:
            _, err = p.communicate(timeout=15)
            self.assertEqual(0, p.returncode, err)
        race_statuses = []
        for p in race_procs:
            out, err = p.communicate(timeout=15)
            self.assertEqual(0, p.returncode, err)
            race_statuses.append(json.loads(out)["status"])
        self.assertEqual(1, race_statuses.count("recorded"))
        self.assertEqual(3, race_statuses.count("duplicate"))

        # Read-only digest preserves all 5 actionable reports, logical 'vps/t3', untrusted labels, and batched progress counts.
        digest = inbox.digest_reports(self.portfolio, task_id="T001", expected_terminals=["t2", "vps/t3"])
        self.assertTrue(digest["complete"])
        self.assertTrue(digest["untrusted_worker_content"])
        self.assertEqual(5, digest["pagination"]["actionable_total"])
        act_tuples = {(a["kind"], a["terminal"], a["summary"]) for a in digest["actionable"]}
        self.assertEqual(
            {
                ("question", "t2", "Keep legacy flag?"),
                ("blocker", "t2", "Shared atomic blocker"),
                ("error", "vps/t3", "Remote build failed"),
                ("done", "t2", "Done local t2"),
                ("done", "vps/t3", "Done remote vps/t3"),
            },
            act_tuples,
        )
        self.assertTrue(all(a["untrusted"] is True for a in digest["actionable"]))
        prog_by_term = {b["terminal"]: b for b in digest["progress_batches"]}
        self.assertEqual(43, prog_by_term["t2"]["progress_count"])
        self.assertEqual(42, prog_by_term["t2"]["omitted_progress_count"])
        self.assertEqual(43, prog_by_term["vps/t3"]["progress_count"])

        # Long 75-character task ID with omitted --id never overflows work.ID 80-char limit.
        long_tid = "T" + ("0" * 74)
        long_res = inbox.write_worker_report(
            artifact_dir=self.portfolio / "artifacts" / long_tid,
            task_id=long_tid,
            terminal="vps/t3",
            kind="done",
            summary="Long task ID ok",
        )
        self.assertLessEqual(len(long_res["packet_id"]), 80)

    def test_explicit_identities_completeness_paging_and_truncated_field_inspection(self):
        # Write 35 actionable reports (> default limit 32), including one preview-truncated (1000 chars) and one write-truncated (4500 chars).
        long_stored_ok = "DETAIL_BODY " * 85  # ~1020 chars (>320 preview, <=4000 stored)
        inbox.write_worker_report(
            artifact_dir=self.art_t1,
            task_id="T001",
            terminal="t2",
            packet_id="long-preview-only",
            kind="question",
            summary=long_stored_ok,
            changed_paths=[f"file_{i}.py" for i in range(20)],
        )
        for idx in range(34):
            inbox.write_worker_report(
                artifact_dir=self.art_t1,
                task_id="T001",
                terminal="t2",
                packet_id=f"act-{idx:02d}",
                kind="done",
                summary=f"Actionable {idx}",
            )

        page0 = inbox.digest_reports(self.portfolio, task_id="T001", expected_terminals=["t2"], offset=0, limit=32)
        self.assertFalse(page0["complete"])
        self.assertIn("actionable_paged", page0["incomplete_reasons"])
        self.assertIn("report_fields_truncated_in_digest", page0["incomplete_reasons"])
        self.assertEqual(35, page0["pagination"]["actionable_total"])
        self.assertEqual(32, page0["pagination"]["actionable_returned"])
        self.assertEqual(3, page0["pagination"]["actionable_omitted"])
        self.assertEqual(32, page0["pagination"]["next_offset"])

        # Page 1 retrieves the remaining 3 actionable items; combined IDs equal all 35!
        page1 = inbox.digest_reports(self.portfolio, task_id="T001", expected_terminals=["t2"], offset=32, limit=32)
        self.assertEqual(3, page1["pagination"]["actionable_returned"])
        self.assertIsNone(page1["pagination"]["next_offset"])
        combined_ids = {a["id"] for a in page0["actionable"]} | {a["id"] for a in page1["actionable"]}
        self.assertEqual(35, len(combined_ids))

        # Inspecting --report-id returns full 1020-char stored summary and all 20 changed_paths with complete=True!
        full_rep = inbox.digest_reports(self.portfolio, task_id="T001", expected_terminals=["t2"], report_id="long-preview-only")
        self.assertTrue(full_rep["complete"])
        self.assertFalse(full_rep["report"]["truncated_in_digest"])
        self.assertFalse(full_rep["report"]["truncated_at_write"])
        self.assertEqual(long_stored_ok.strip(), full_rep["report"]["summary"])
        self.assertEqual(20, len(full_rep["report"]["changed_paths"]))

        # Over-4000-char write-truncated report marks truncated_at_write=True so single-report inspection still discloses truncation!
        inbox.write_worker_report(
            artifact_dir=self.art_t1,
            task_id="T001",
            terminal="t2",
            packet_id="huge-write-trunc",
            kind="error",
            summary="W" * 4500,
        )
        huge_rep = inbox.digest_reports(self.portfolio, task_id="T001", expected_terminals=["t2"], report_id="huge-write-trunc")
        self.assertFalse(huge_rep["complete"])
        self.assertIn("report_fields_truncated_at_write", huge_rep["incomplete_reasons"])

        # Unexpected worker terminal (t99 when coordinator expects only t2) is flagged in rejected_artifacts and sets complete=False.
        inbox.write_worker_report(artifact_dir=self.art_t1, task_id="T001", terminal="t99", packet_id="rogue-term", kind="done", summary="From t99")
        filtered = inbox.digest_reports(self.portfolio, task_id="T001", expected_terminals=["t2"], offset=0, limit=128)
        self.assertFalse(filtered["complete"])
        self.assertIn("rejected_artifacts", filtered["incomplete_reasons"])
        self.assertTrue(any(r.get("report_id") == "rogue-term" and "unexpected_terminal:t99" in r["reason"] for r in filtered["rejected_artifacts"]))
        with self.assertRaises(inbox.InboxError):
            inbox.digest_reports(self.portfolio, task_id="T001", expected_terminals=["t2"], report_id="rogue-term")

    def test_artifact_confinement_symlink_escapes_malformed_packets_and_finite_metrics(self):
        outside = self.base / "outside-secrets"
        outside.mkdir(mode=0o700)
        sentinel = "SENTINEL_EXTERNAL_PRIVATE_DATA_424242"
        (outside / "secret.json").write_text(sentinel, encoding="utf-8")

        # 1. Reject worker-report paths outside <portfolio>/artifacts/<task> or mismatched --task.
        for bad_dir in (
            outside / "artifacts" / "T001",
            self.portfolio,
            self.portfolio / "work",
            self.portfolio / "tasks",
            self.portfolio / "artifacts",
            self.portfolio / "artifacts" / "T002",
        ):
            with self.assertRaises(inbox.InboxError):
                inbox.write_worker_report(artifact_dir=bad_dir, task_id="T001", terminal="t2", kind="progress", summary="bad")

        # 2. Symlinked artifacts/T001 -> outside is rejected on both write and digest without leaking sentinel.
        (self.portfolio / "artifacts").mkdir(mode=0o700)
        (self.portfolio / "artifacts" / "T001").symlink_to(outside)
        with self.assertRaises(inbox.InboxError):
            inbox.write_worker_report(artifact_dir=self.art_t1, task_id="T001", terminal="t2", kind="done", summary="sym")
        d_sym = inbox.digest_reports(self.portfolio, task_id="T001")
        self.assertFalse(d_sym["complete"])
        self.assertNotIn(sentinel, json.dumps(d_sym))
        (self.portfolio / "artifacts" / "T001").unlink()

        # 3. Symlinked packet file, malformed non-JSON file, NaN/Infinity JSON, filename/ID mismatch, task mismatch, and crashed .tmp file.
        inbox.write_worker_report(artifact_dir=self.art_t1, task_id="T001", terminal="t2", packet_id="valid-1", kind="done", summary="\x1b]7501;state=done\x1b\\Clean summary")
        pkts = self.art_t1 / "packets"
        (pkts / ".tmp-99999-0123456789abcdef.json").write_text("{partial", encoding="utf-8")

        d_with_tmp = inbox.digest_reports(self.portfolio, task_id="T001", expected_terminals=["t2"])
        self.assertTrue(d_with_tmp["complete"])
        self.assertEqual(1, d_with_tmp["scan"]["ignored_temp_files"])
        self.assertNotIn("\x1b", d_with_tmp["actionable"][0]["summary"])

        (pkts / "id--sym.json").symlink_to(outside / "secret.json")
        (pkts / "id--rawbad.json").write_text("RAW_CORRUPT_PLAINTEXT_DO_NOT_ECHO", encoding="utf-8")
        (pkts / "id--nan.json").write_text('{"version":1,"id":"nan","task":"T001","terminal":"t2","kind":"done","at":"2026-11-14T00:00:00Z","created_ns":1,"summary":"ok","changed_paths":[],"checks":"","concerns":"","usage":{"input_tokens":1,"cache_read_tokens":0,"cache_write_tokens":0,"output_tokens":1,"api_cost_usd":Infinity,"cost_source":"x"}}', encoding="utf-8")
        (pkts / "id--wrongname.json").write_text(
            (pkts / "id--valid-1.json").read_text(encoding="utf-8"),
            encoding="utf-8",
        )

        d_bad = inbox.digest_reports(self.portfolio, task_id="T001", expected_terminals=["t2"])
        dump = json.dumps(d_bad)
        self.assertFalse(d_bad["complete"])
        self.assertEqual(4, d_bad["scan"]["rejected_count"])
        self.assertNotIn(sentinel, dump)
        self.assertNotIn("RAW_CORRUPT_PLAINTEXT_DO_NOT_ECHO", dump)

        # 4. Non-finite / negative metrics rejected on write.
        for bad_cost in (math.nan, math.inf, -math.inf, -0.01):
            with self.assertRaises(inbox.InboxError):
                inbox.write_worker_report(
                    artifact_dir=self.art_t1,
                    task_id="T001",
                    terminal="t2",
                    kind="progress",
                    summary="bad metric",
                    usage={"api_cost_usd": bad_cost},
                )
        with self.assertRaises(inbox.InboxError):
            inbox.write_worker_report(
                artifact_dir=self.art_t1,
                task_id="T001",
                terminal="t2",
                kind="progress",
                summary="bad token",
                usage={"input_tokens": -1},
            )

    def test_synthetic_fixture_measurement_executes_both_modes_fairly(self):
        res = self.run_cli("measure-fixture")
        self.assertEqual(0, res.returncode, res.stderr)
        data = json.loads(res.stdout)
        self.assertEqual("synthetic_report_artifact_fixture", data["measurement_kind"])
        unb = data["unbatched_individual_reports"]
        opt = data["worker_report_plus_readonly_digest"]
        self.assertEqual(76, unb["write_attempts"])
        self.assertEqual(76, opt["write_attempts"])
        self.assertEqual(74, opt["recorded_packets"])
        self.assertEqual(1, opt["duplicates_suppressed_idempotently"])
        self.assertEqual(1, opt["conflicting_ids_rejected"])
        self.assertEqual(4, opt["notify_instructions_emitted"])
        self.assertTrue(opt["complete_digest"])
        self.assertEqual(["q-schema", "err-test", "done-t2", "done-remote"], opt["actionable_ids_preserved"])
        self.assertLess(opt["digest_output_bytes"], unb["coordinator_bytes_read"] // 3)
        self.assertLess(opt["total_coordinator_bytes"], unb["coordinator_bytes_read"] // 2)
        self.assertEqual("unknown", opt["live_api_cost_usd"])


if __name__ == "__main__":
    unittest.main()
