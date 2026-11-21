#!/usr/bin/env python3
"""Worker controller boundaries. No real model or browser is contacted."""
import json
import os
import re
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent / "chat-send/scripts"))
import chat_task as M


class WorkerTests(unittest.TestCase):
    def setUp(self):
        old_mask = os.umask(0o077)
        self.addCleanup(os.umask, old_mask)
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.routes = self.root / "routes.json"
        self.route = {"url": "https://chat.google.com/app/chat/EXAMPLE", "title": "Example - Chat", "account": "owner@example.com", "account_label": "Google Account: Owner (owner@example.com)"}
        M.atomic(self.routes, {"version": 1, "routes": {"example": self.route}})
        self.brief = self.root / "brief.txt"
        self.brief.write_text("Say that the check is complete. Do not invent details.")
        self.sender = self.root / "chat-send"
        self.sender.write_text("fixture")
        self.args = M.parser().parse_args(["--route", "example", "--brief", str(self.brief), "--operation", "fixed", "--routes-file", str(self.routes), "--state-dir", str(self.root / "state")])
        self.directory = self.args.state_dir / ".workers/fixed"
        self.calls = []
        self.flags = {}

    def command(self, argv, **kwargs):
        self.calls.append(argv)
        if argv[:2] == ["hc", "run"]:
            if self.flags.get("launch_unknown"):
                raise M.Stop("worker_command_failed")
            ready = {"provider": M.PROVIDER, "model": M.MODEL, "thinking": "low", "tools": ["deliver_message"], "system_prompt": M.SYSTEM + "\n\n<cwd>\n" + str(self.directory) + "\n</cwd>"}
            if self.flags.get("extra_context"):
                ready["system_prompt"] += "\n\n<project_context>unwanted repository context</project_context>"
            if self.flags.get("extra_tool"):
                ready["tools"].append("bash")
            M.atomic(self.directory / "ready.json", ready)
            if self.flags.get("change_route"):
                M.atomic(self.routes, {"version": 1, "routes": {"example": {**self.route, "url": "https://chat.google.com/app/chat/OTHER"}}})
            return {"address": "t-fixture"}
        if argv[:2] == ["hc", "send"]:
            self.assertTrue(argv[-1].startswith("Prepare the message from this self-contained brief:\n\n"))
            job = M.read_json(self.directory / "job.json", private=True)
            snap = M.read_json(Path(job["routes_file"]), private=True)
            self.assertEqual(snap["routes"]["example"], self.route)
            self.assertEqual(job["sender"], str(self.sender))
            payload = {"version": 1, "blocks": [{"type": "text", "text": "The check is complete."}]}
            M.atomic(self.directory / "payload.json", payload)
            receipt = {"operation_id": "fixed", "outcome": "sent" if self.args.send else "preview", "reason": "fixture", "send_attempted": self.args.send,
                       "request": {"route": self.route, "payload": payload}}
            if self.flags.get("swap_payload"):
                receipt["request"]["payload"] = {"version": 1, "blocks": [{"type": "text", "text": "Other content"}]}
            self.receipt(receipt)
            M.atomic(self.directory / "done.json", {"requests": 1})
            event = {"event": "wire_usage", "data": {"request": 1, "id": "response-1", "usage": {"input_tokens": 300, "output_tokens": 30, "cost": 0.0004}}}
            (self.directory / "telemetry.jsonl").write_text(json.dumps(event) + "\n" + json.dumps(event) + "\n")
            return {"started": True}
        raise AssertionError(argv)

    def receipt(self, value):
        M.private_dir(self.args.state_dir / "fixed")
        M.atomic(self.args.state_dir / "fixed/receipt.json", value)

    def run_job(self):
        with mock.patch.dict(os.environ, {"CHAT_SEND_BIN": str(self.sender)}), mock.patch.object(M.shutil, "which", return_value="/bin/true"), mock.patch.object(M, "command", side_effect=self.command), mock.patch.object(M.subprocess, "run", return_value=SimpleNamespace(returncode=0)):
            return M.execute(self.args)

    def test_default_is_preview_in_fresh_terra_session_with_only_delivery(self):
        result = self.run_job()
        self.assertEqual(result["outcome"], "preview")
        self.assertFalse(result["send_attempted"])
        launch = self.calls[0]
        for option, value in [("--model", "gpt-6.1-terra"), ("--thinking", "low"), ("--provider", "litellm"), ("--tools", "deliver_message")]:
            self.assertEqual(launch[launch.index(option) + 1], value)
        for flag in ["--no-builtin-tools", "--no-mcp", "--no-context-files", "--no-skills", "--no-extensions", "--no-prompt-templates"]:
            self.assertIn(flag, launch)
        self.assertNotIn("--print", launch)
        self.assertEqual(result["accounting"]["gateway_cost"], 0.0004)
        self.assertEqual(len(result["accounting"]["responses"]), 1)
        for p in self.args.state_dir.rglob("*"):
            self.assertEqual(p.stat().st_mode & 0o777, 0o700 if p.is_dir() else 0o600)

    def test_send_permission_requires_explicit_flag(self):
        self.args.send = True
        self.assertEqual(self.run_job()["outcome"], "sent")
        self.assertTrue(M.read_json(self.directory / "job.json", private=True)["send_authorized"])

    def test_route_is_snapshotted_before_launch(self):
        self.flags["change_route"] = True
        self.assertEqual(self.run_job()["outcome"], "preview")
        self.assertNotEqual(M.read_json(self.routes)["routes"]["example"], self.route)

    def test_repeat_only_checks_original_native_operation(self):
        self.run_job()
        count = len(self.calls)
        with mock.patch.object(M, "native_result", return_value={"outcome": "preview"}) as status:
            self.assertEqual(self.run_job()["outcome"], "preview")
            status.assert_called_once()
        self.assertEqual(len(self.calls), count)

    def test_changed_brief_same_id_never_relaunches(self):
        self.run_job()
        self.brief.write_text("Changed brief")
        count = len(self.calls)
        with self.assertRaisesRegex(M.Stop, "worker_operation_request_changed"):
            self.run_job()
        self.assertEqual(len(self.calls), count)

    def test_unknown_launch_is_never_repeated(self):
        self.flags["launch_unknown"] = True
        with self.assertRaises(M.Stop):
            self.run_job()
        count = len(self.calls)
        self.flags.clear()
        self.assertEqual(self.run_job()["reason"], "worker_has_no_sender_receipt_inspect_original_job")
        self.assertEqual(len(self.calls), count)

    def test_wrong_startup_scope_stops_before_prompt(self):
        self.flags["extra_tool"] = True
        with self.assertRaisesRegex(M.Stop, "worker_startup_scope_mismatch"):
            self.run_job()
        self.assertFalse(any(c[:2] == ["hc", "send"] for c in self.calls))

    def test_extra_system_context_stops_before_prompt(self):
        self.flags["extra_context"] = True
        with self.assertRaisesRegex(M.Stop, "worker_startup_scope_mismatch"):
            self.run_job()
        self.assertFalse(any(c[:2] == ["hc", "send"] for c in self.calls))

    def test_receipt_content_swap_is_uncertain(self):
        self.flags["swap_payload"] = True
        with self.assertRaises(M.Stop) as caught:
            self.run_job()
        self.assertEqual(caught.exception.outcome, "uncertain")

    def test_existing_native_operation_cannot_start_new_worker(self):
        M.private_dir(self.args.state_dir)
        self.receipt({"operation_id": "fixed"})
        with self.assertRaisesRegex(M.Stop, "operation_exists_use_chat_send_status"):
            self.run_job()
        self.assertFalse(self.calls)

    def test_bad_or_oversized_brief_and_dm_mention_stop_before_launch(self):
        for text in ["", "bad\x1btext", "x" * 16385]:
            self.brief.write_text(text)
            with self.assertRaises(M.Stop): self.run_job()
        self.brief.write_text("A brief")
        self.args.mention_email, self.args.mention_query = "person@example.com", "Person"
        with self.assertRaisesRegex(M.Stop, "required_dm_mention_unsupported"):
            self.run_job()
        self.assertFalse(self.calls)

    def test_portfolio_requires_existing_task_and_uses_separate_worker_tab(self):
        self.args.portfolio = self.root
        with mock.patch.object(M.shutil, "which", return_value="/bin/true"):
            with self.assertRaisesRegex(M.Stop, "portfolio_requires_existing_task_id"):
                M.launch(self.args, self.directory)
            self.args.task_id = "T099"
            launch = M.launch(self.args, self.directory)
        self.assertEqual(launch[0], "chief-of-staff-spawn")
        self.assertEqual(launch[launch.index("--tab-name") + 1], "Chat messages")

    def test_clarification_can_never_claim_publication_without_native_receipt(self):
        M.private_dir(self.directory)
        M.atomic(self.directory / "done.json", {"requests":1,"result":{"operation_id":"fixed","outcome":"sent","reason":"brief_needs_clarification","detail":"Which date?"}})
        result=M.result_for(self.args.state_dir,"fixed",self.directory)
        self.assertEqual(result["outcome"],"needs_attention")
        self.assertFalse(result["send_attempted"])
        self.assertEqual(result["detail"],"Which date?")
        self.args.mode, self.args.route, self.args.brief = "status", None, None
        self.assertEqual(M.execute(self.args)["detail"], "Which date?")

    def test_missing_cost_stays_unknown(self):
        self.run_job()
        path = self.directory / "telemetry.jsonl"
        event = json.loads(path.read_text().splitlines()[0]);del event["data"]["usage"]["cost"]
        path.write_text(json.dumps(event) + "\n{interrupted")
        value = M.accounting(self.directory)
        self.assertIsNone(value["gateway_cost"])
        self.assertEqual(value["cost_source"], "unknown")

    def test_terminal_name_obeys_actual_herdr_limit_and_keeps_uniqueness(self):
        with mock.patch.object(M.shutil, "which", return_value="/bin/true"):
            self.args.operation = "A" * 80
            first = M.launch(self.args, self.directory)
            self.args.operation = "A" * 79 + "B"
            second = M.launch(self.args, self.directory)
        names = [argv[argv.index("--name") + 1] for argv in [first, second]]
        self.assertNotEqual(*names)
        for name in names:
            self.assertIsNotNone(re.fullmatch(r"[a-z0-9][a-z0-9._-]{0,31}", name))

    def test_worker_command_resolves_pi_task_and_requires_it(self):
        with mock.patch.object(M.shutil, "which", side_effect={"pi-task": "/run/current-system/sw/bin/pi-task", "hc": "/run/current-system/sw/bin/hc"}.get):
            launch = M.worker_command(self.directory)
        self.assertEqual(launch[2], "/run/current-system/sw/bin/pi-task")
        for option, value in [("--model", "gpt-6.1-terra"), ("--thinking", "low"), ("--provider", "litellm"), ("--tools", "deliver_message")]:
            self.assertEqual(launch[launch.index(option) + 1], value)
        for flag in ["--no-builtin-tools", "--no-mcp", "--no-context-files", "--no-skills", "--no-extensions", "--no-prompt-templates", "--no-themes", "--offline", "--approve"]:
            self.assertIn(flag, launch)

        with mock.patch.object(M.shutil, "which", side_effect={"pi": "/run/current-system/sw/bin/pi", "hc": "/run/current-system/sw/bin/hc"}.get):
            with self.assertRaisesRegex(M.Stop, "pi_task_unavailable"):
                M.worker_command(self.directory)

        with mock.patch.object(M.shutil, "which", side_effect={"pi-task": "/run/current-system/sw/bin/pi-task"}.get):
            with self.assertRaisesRegex(M.Stop, "herdr_unavailable"):
                M.worker_command(self.directory)

    def test_real_command_failure_retains_private_diagnostics(self):
        path = self.root / "error.json"
        with self.assertRaisesRegex(M.Stop, "worker_command_failed"):
            M.command([sys.executable, "-c", "import sys;sys.stderr.write('private fixture failure');sys.exit(2)"], diagnostics=path)
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(M.read_json(path)["stderr"], "private fixture failure")


if __name__ == "__main__":
    unittest.main()
