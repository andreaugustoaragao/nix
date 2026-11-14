#!/usr/bin/env python3
"""Exercise name confirmation and refusal paths without model requests."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("codex_name", Path(__file__).with_name("codex-name.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class CodexNameTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.home = Path(self.directory.name)
        self.index = self.home / "session_index.jsonl"
        self.sent = []
        self.state = {"address": "t9", "state": "live", "status": {"state": "idle"}}

    def hc(self, *args):
        if args[0] == "get":
            return self.state
        if args[0] == "send":
            self.sent.append(args[-1])
            self.append("fresh", args[-1].removeprefix("/rename "))
        return {}

    def append(self, thread, name):
        with self.index.open("a") as stream:
            stream.write(json.dumps({"id": thread, "thread_name": name}) + "\n")

    def test_confirms_a_new_save_and_returns_resume_identity(self):
        self.append("unrelated", "other-task")
        with patch.object(module, "hc", side_effect=self.hc):
            result = module.name_worker("worker-alias", "t001-review", self.home, 1)
        self.assertEqual(result, {"address": "t9", "named": True, "thread_id": "fresh", "thread_name": "t001-review [t9]"})
        self.assertEqual(self.sent, ["/rename t001-review [t9]"])

    def test_stale_matching_name_does_not_confirm_a_failed_rename(self):
        self.append("old", "t001-review [t9]")
        with patch.object(module, "hc", return_value=self.state) as hc, patch.object(module.time, "monotonic", side_effect=[0, 2]):
            with self.assertRaises(TimeoutError):
                module.name_worker("t9", "t001-review", self.home, 1)
        self.assertEqual([c.args[0] for c in hc.call_args_list], ["get", "send"])

    def test_waits_for_a_complete_index_record(self):
        def partial_save(*args):
            if args[0] == "send":
                self.index.write_bytes(b'{"id":"fresh","thread_name":"t001-review [t9]"')
            elif args[0] == "wait":
                with self.index.open("ab") as stream:
                    stream.write(b'}\n')
            return self.state if args[0] == "get" else {}
        with patch.object(module, "hc", side_effect=partial_save):
            result = module.name_worker("t9", "t001-review", self.home, 1)
        self.assertEqual(result["thread_id"], "fresh")

    def test_refuses_non_idle_or_finished_workers(self):
        for state in ["working", "blocked", "error", None]:
            with self.subTest(status=state):
                self.state["status"] = {"state": state}
                with patch.object(module, "hc", side_effect=self.hc):
                    with self.assertRaises(ValueError):
                        module.name_worker("t9", "task", self.home, 1)
        self.state.update(state="finished", status={"state": "idle"})
        with patch.object(module, "hc", side_effect=self.hc):
            with self.assertRaises(ValueError):
                module.name_worker("t9", "task", self.home, 1)
        self.assertEqual(self.sent, [])

    def test_control_characters_cannot_submit_a_second_command(self):
        for name in ["", " ", "task\nsecond prompt", "task\rprompt", "task\x1b"]:
            with self.subTest(name=repr(name)), patch.object(module, "hc") as hc:
                with self.assertRaises(ValueError):
                    module.name_worker("t9", name, self.home, 1)
                hc.assert_not_called()

    def test_remote_worker_cannot_be_confirmed_from_a_local_index(self):
        self.state["address"] = "remote/t9"
        with patch.object(module, "hc", side_effect=self.hc):
            with self.assertRaises(ValueError):
                module.name_worker("remote/t9", "task", self.home, 1)
        self.assertEqual(self.sent, [])

    def test_stopped_worker_is_preserved_without_retrying_the_send(self):
        states = iter([self.state, {"state": "finished"}])
        def stopped(*args):
            return next(states) if args[0] == "get" else {}
        with patch.object(module, "hc", side_effect=stopped) as hc:
            with self.assertRaises(RuntimeError):
                module.name_worker("t9", "task", self.home, 1)
        self.assertEqual(sum(c.args[0] == "send" for c in hc.call_args_list), 1)
        self.assertFalse(any(c.args[0] in ["kill", "rm"] for c in hc.call_args_list))


if __name__ == "__main__":
    unittest.main()
