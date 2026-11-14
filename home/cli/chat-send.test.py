#!/usr/bin/env python3
"""Behavioral protocol fixtures only. Never opens a browser or sends a message."""

import copy
from contextlib import contextmanager
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

BASE = Path(__file__).resolve().parent / "chat-send"
SCRIPT = BASE / "scripts/chat_send.py"
SPEC = importlib.util.spec_from_file_location("chat_send", SCRIPT)
SENDER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SENDER)
TEXT = "Fixture secret hello"
CODE = "pwd\nprintf '%s\\n' hello"
SIGNATURE = "- sent by Fulcrum"
BODY = {
    "blocks": [{"type": "text", "text": TEXT + "\n\n\n"}, {"type": "code", "text": CODE}, {"type": "text", "text": "\n\n\n\u200b" + SIGNATURE + "\n"}],
    "text": TEXT + "\n\n\n" + CODE + "\n\n\n\u200b" + SIGNATURE,
    "forbidden": False, "signature_list": False, "signature_plain": True, "mentions": []
}
MENTION = {"email": "other@example.com", "query": "Other", "user_id": "person-1", "member_id": "user/human/person-1"}
CHIP = {"email": "other@example.com", "user_id": "person-1", "member_id": "user/human/person-1", "display": "@Example Person", "mention_type": "0", "selected": True}


def mentioned_body(published=False):
    body = copy.deepcopy(BODY)
    chip = {**CHIP, "mention_type": "3" if published else "0"}
    body["blocks"][0]["text"] = (" " if published else "\u200b ") + body["blocks"][0]["text"]
    body["blocks"].insert(0, {"type": "mention", **chip})
    if not published:
        body["blocks"].insert(0, {"type": "text", "text": "\u200b"})
    body["text"] = "@Example Person " + body["text"]
    body["mentions"] = [chip]
    return body


def fake_browser():
    path = Path(os.environ["CHAT_SEND_FIXTURE"])
    state = json.loads(path.read_text())
    args = sys.argv[2:]
    command = args[0]
    action = json.load(sys.stdin) if command == "action" else None
    state.setdefault("calls", []).append({"command": command, "task": args[1] if len(args) > 1 else None, "action": action})

    def save():
        path.write_text(json.dumps(state))

    def output(value):
        save()
        print(json.dumps(value))

    if state.get("malformed"):
        save()
        print("malformed Fixture secret hello")
        return 0
    if state.get("oversized"):
        save()
        print("x" * 140000)
        return 0
    if state.get("command_failure"):
        save()
        print("Fixture secret hello", file=sys.stderr)
        return 2
    if command == "start":
        state["task"] = {"task": "11111111-1111-1111-1111-111111111111", "profile": "accounts", "label": args[args.index("--label") + 1], "state": "active", "pages": {"main": "target-1"}}
        output(state["task"])
    elif command == "info":
        task = copy.deepcopy(state["task"])
        if state.get("foreign_task"):
            task["pages"] = {"main": "foreign-page"}
        output(task)
    elif command in ("resume", "keep", "finish"):
        state["task"]["state"] = {"resume": "active", "keep": "kept", "finish": "finished"}[command]
        output(state["task"])
    elif command == "action":
        kind = action["type"]
        if kind == "wait":
            output({"state": "visible"})
        elif kind == "viewport":
            state["viewport"] = [action["width"], action["height"]]
            output({})
        elif kind == "fill":
            state["fills"] = state.get("fills", 0) + 1
            state["rendered"] = action["text"]
            state["composer"] = copy.deepcopy(BODY) if action["text"] else {"blocks": [], "text": "", "forbidden": False, "signature_list": False, "mentions": []}
            if action["text"]:
                # Chat treats any language tag after the opening fence as code.
                fence_content = action["text"].split("```", 2)[1]
                code = fence_content[1:] if fence_content.startswith("\n") else fence_content
                state["composer"]["blocks"][1]["text"] = code[:-1] if code.endswith("\n") else code
            state["pending_probes"] = state.get("settle_after", 0) if action["text"] else 0
            output({})
        elif kind == "click":
            target = action["target"]
            if target["role"] == "textbox":
                output({})
                return 0
            if target["role"] == "option":
                state["composer"] = mentioned_body()
                state["mention_selected"] = True
                output({})
                return 0
            # The real command must durably mark the operation before dispatching.
            receipt = json.loads(Path(os.environ["CHAT_SEND_RECEIPT"]).read_text())
            if not receipt.get("send_attempted"):
                return 8
            state["clicks"] = state.get("clicks", 0) + 1
            state["composer"] = {"blocks": [], "text": "", "forbidden": False, "signature_list": False, "mentions": []}
            state["published"] = not state.get("no_publication", False)
            save()
            if state.get("kill_parent"):
                os.kill(os.getppid(), signal.SIGKILL)
                return 0
            if state.get("crash_after_click"):
                return 9
            output({})
        elif kind == "key":
            if action["key"] not in ("Control+Home", "Space", "ArrowLeft"):
                state["mention_keys"] = state.get("mention_keys", "") + action["key"]
            output({})
        elif kind == "evaluate":
            if state.get("published") and state.get("malformed_after_click"):
                save()
                print("bad output with private history")
                return 0
            dom = json.loads((BASE / "tests/dom.json").read_text())
            editor = copy.deepcopy(state.get("composer", dom["editors"][0]))
            if state.get("pending_probes", 0):
                state["pending_probes"] -= 1
                editor = {"blocks": [{"type": "text", "text": state["rendered"]}], "text": state["rendered"], "forbidden": False, "signature_list": False, "mentions": []}
            if state.get("bad_code") and editor.get("blocks"):
                editor["blocks"][1]["text"] += " "
            if state.get("signature_bullet") and editor.get("blocks"):
                editor["signature_list"] = True
            if state.get("foreign_draft"):
                editor = {"text": "Foreign draft", "blocks": [{"type": "text", "text": "Foreign draft"}], "forbidden": False, "mentions": []}
            dom["editors"] = [{"name": "History is on", **editor}]
            if state.get("mention_keys") and not state.get("mention_selected"):
                option = {"email": "other@example.com", "id": "other@example.com", "chip_type": "2", "name": "Example Person other@example.com"}
                dom["options"] = [option, copy.deepcopy(option)] if state.get("ambiguous_mention") else [option]
                if state.get("mention_dialog"):
                    dom["dialogs"] = 1
                if state.get("wrong_mention_email"):
                    dom["options"][0]["email"] = "someone-else@example.com"
            if state.get("ambiguous_editor"):
                dom["editors"].append(copy.deepcopy(dom["editors"][0]))
            for flag, key, value in (("wrong_account", "accounts", ["Google Account: Wrong (wrong@example.com)"]), ("wrong_url", "url", "https://chat.google.com/app/chat/WRONG"), ("wrong_title", "title", "Wrong - Chat"), ("ambiguous_send", "send_count", 2), ("unsupported", "publication_supported", False)):
                if state.get(flag):
                    dom[key] = value
            if state.get("clicks") and state.get("postclick_wrong_title"):
                dom["title"] = "Wrong after click"
            if state.get("published"):
                dom["message_ids"].append("new-own")
                dom["messages"].append({"id": "new-own", "sender_id": "sender-2" if state.get("wrong_sender") else "sender-1", "server": not state.get("pending_publication", False), "body_count": 1, "body": mentioned_body(published=True) if state.get("mention_selected") else copy.deepcopy(BODY)})
            if state.get("duplicate_publication") and state.get("published"):
                dom["messages"].append({**dom["messages"][-1], "id": "second-new-own"})
            output({"value": dom})
        elif kind == "screenshot":
            screenshot = path.with_suffix(".png")
            screenshot.write_bytes(b"\x89PNG\r\n\x1a\nfixture")
            os.chmod(screenshot, 0o600)
            output({"path": str(screenshot)})
        else:
            return 4
    else:
        return 5
    return 0


class SenderTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.state = self.root / "state"
        self.fixture = self.root / "browser.json"
        self.fixture.write_text("{}")
        self.payload = self.root / "payload.json"
        self.payload.write_text(json.dumps({"version": 1, "blocks": [{"type": "text", "text": TEXT}, {"type": "code", "text": CODE}]}))
        self.routes = self.root / "routes.json"
        self.routes.write_text(json.dumps({"version": 1, "routes": {"example": {"url": "https://chat.google.com/app/chat/EXAMPLE", "title": "Example Person - Chat", "account": "sender@example.com", "account_label": "Google Account: Example Sender (sender@example.com)"}}}))
        self.routes.chmod(0o600)
        binary = self.root / "browser-task"
        binary.write_text(self.wrapper())
        binary.chmod(0o700)
        self.env = {**os.environ, "PATH": str(self.root) + os.pathsep + os.environ["PATH"], "CHAT_SEND_FIXTURE": str(self.fixture), "CHAT_SEND_RECEIPT": str(self.state / "one/receipt.json"), "PYTHONDONTWRITEBYTECODE": "1"}

    def wrapper(self):
        import shlex
        return "#!/bin/sh\nexec " + shlex.quote(sys.executable) + " " + shlex.quote(str(Path(__file__).resolve())) + ' --fake-browser "$@"\n'

    def change(self, **changes):
        state = self.browser()
        state.update(changes)
        self.fixture.write_text(json.dumps(state))

    def browser(self):
        return json.loads(self.fixture.read_text())

    def call(self, *args, send=False, operation="one", status=None):
        command = [sys.executable, str(SCRIPT)]
        if status:
            command += [status, "--operation", operation]
        else:
            command += ["--route", "example", "--message", str(self.payload), "--routes-file", str(self.routes)]
            if operation is not None:
                command += ["--operation", operation]
            if send:
                command += ["--send"]
        result = subprocess.run(command + ["--state-dir", str(self.state)] + list(args), env=self.env, text=True, capture_output=True, timeout=20)
        self.assertLess(len(result.stdout), 2048)
        self.assertNotIn(TEXT, result.stdout + result.stderr)
        self.assertEqual(result.stderr, "")
        value = json.loads(result.stdout)
        self.assertEqual(result.returncode, SENDER.EXIT[value["outcome"]])
        return value

    def receipt(self):
        return json.loads((self.state / "one/receipt.json").read_text())

    def group_route(self):
        routes = json.loads(self.routes.read_text())
        routes["routes"]["example"]["kind"] = "group"
        self.routes.write_text(json.dumps(routes))

    def test_preview_settles_captures_before_keep_and_never_sends(self):
        self.change(settle_after=2)
        result = self.call()
        self.assertEqual(result["outcome"], "preview")
        browser = self.browser()
        self.assertEqual(browser.get("clicks", 0), 0)
        self.assertEqual(browser["fills"], 1)
        self.assertIn("```\n" + CODE + "\n```", browser["rendered"])
        self.assertTrue(browser["rendered"].endswith("\u200b" + SIGNATURE))
        self.assertEqual(browser["task"]["state"], "kept")
        calls = browser["calls"]
        shot = next(i for i, c in enumerate(calls) if (c.get("action") or {}).get("type") == "screenshot")
        keep = next(i for i, c in enumerate(calls) if c["command"] == "keep")
        self.assertLess(shot, keep)
        self.assertTrue(Path(self.receipt()["screenshot"]).exists())

    def test_startup_viewport_precedes_wait_and_composition(self):
        self.call()
        browser = self.browser()
        self.assertEqual(browser["viewport"], [1440, 1000])
        actions = [(c.get("action") or {}).get("type") for c in browser["calls"]]
        self.assertLess(actions.index("viewport"), actions.index("wait"))
        self.assertLess(actions.index("wait"), actions.index("fill"))

    def test_language_hint_preserves_code_without_serializing_a_language_line(self):
        payload = json.loads(self.payload.read_text())
        payload["blocks"][1]["language"] = "text"
        self.payload.write_text(json.dumps(payload))
        self.assertEqual(self.call()["outcome"], "preview")
        self.assertEqual(self.browser()["composer"]["blocks"][1]["text"], CODE)
        self.assertEqual(self.receipt()["request"]["payload"]["blocks"][1]["language"], "text")
        # An actual code first line that resembles a language remains untouched.
        payload["blocks"][1]["text"] = "text\n" + CODE
        self.payload.write_text(json.dumps(payload))
        _, rendered, expected = SENDER.payload_config(self.payload)
        self.assertIn("```\ntext\n" + CODE + "\n```", rendered)
        self.assertEqual(expected[1]["text"], "text\n" + CODE)

    def test_send_once_and_cached_confirmed_receipt(self):
        result = self.call(send=True)
        self.assertEqual(result["outcome"], "sent")
        self.assertEqual(self.browser()["clicks"], 1)
        before = len(self.browser()["calls"])
        self.assertEqual(self.call(send=True)["outcome"], "sent")
        self.assertEqual(self.call(status="status")["outcome"], "sent")
        self.assertEqual(len(self.browser()["calls"]), before)
        self.assertEqual(self.browser()["task"]["state"], "finished")
        self.assertEqual(self.receipt()["publication_id"], "new-own")

    def test_crash_after_dispatch_reconciles_without_click(self):
        self.change(crash_after_click=True)
        self.assertEqual(self.call(send=True)["outcome"], "uncertain")
        self.change(crash_after_click=False)
        self.assertEqual(self.call(send=True)["outcome"], "sent")
        self.assertEqual(self.browser()["clicks"], 1)
        self.assertEqual(list(self.state.glob("route-*.json")), [])
        self.change(published=False)
        self.assertEqual(self.call(operation="after-reconciliation")["outcome"], "preview")

    def test_account_url_aliases_share_composer_reservation(self):
        self.call()
        routes = json.loads(self.routes.read_text())
        routes["routes"]["example"]["url"] = "https://chat.google.com/u/0/app/chat/EXAMPLE"
        self.routes.write_text(json.dumps(routes))
        self.assertEqual(self.call(operation="two")["reason"], "route_owned_by_another_operation")
        self.assertEqual(self.browser()["fills"], 1)

    def test_concurrent_route_lock_refuses_without_browser_actions(self):
        self.call()
        before = len(self.browser()["calls"])
        key = SENDER.route_key(self.receipt()["request"]["route"])
        with SENDER.lock(self.state / ("route-" + key + ".lock")):
            self.assertEqual(self.call(operation="two")["reason"], "operation_or_route_busy")
        self.assertEqual(len(self.browser()["calls"]), before)

    def test_failed_run_cannot_overwrite_successor_send_after_operation_unlock(self):
        # Real state, flock contention, run(), and successor CLI. Only the unlock
        # scheduling hook is controlled; no in-memory receipt simulation.
        root = SENDER.private_dir(self.state)
        route = SENDER.route_config(self.routes, "example")
        payload, rendered, expected = SENDER.payload_config(self.payload)
        prepared = SENDER.Operation(root, "one")
        prepared.bind({"alias": "example", "route": route, "payload": payload, "rendered": rendered, "expected": expected})
        real_lock = SENDER.lock
        held_route = real_lock(root / ("route-" + SENDER.route_key(route) + ".lock"))
        held_route.__enter__()
        released = False
        successor = []

        @contextmanager
        def scheduled_lock(path):
            nonlocal released
            try:
                with real_lock(path):
                    yield
            finally:
                if path == root / "one.lock":
                    held_route.__exit__(None, None, None)
                    released = True
                    successor.append(self.call(send=True))

        args = SENDER.parser().parse_args(["status", "--operation", "one", "--state-dir", str(root)])
        try:
            with mock.patch.object(SENDER, "lock", scheduled_lock):
                failed = SENDER.run(args)
        finally:
            if not released:
                held_route.__exit__(None, None, None)
        self.assertEqual(failed["reason"], "operation_or_route_busy")
        self.assertEqual(successor[0]["outcome"], "sent")
        self.assertTrue(self.receipt().get("send_attempted"), "The stale failed run erased the successor's attempt marker")
        self.assertEqual(self.receipt()["outcome"], "sent")
        self.assertEqual(self.call(send=True)["outcome"], "sent")
        self.assertEqual(self.browser()["clicks"], 1)

    def test_process_killed_after_dispatch_never_resends(self):
        self.change(kill_parent=True)
        command = [sys.executable, str(SCRIPT), "--route", "example", "--message", str(self.payload), "--routes-file", str(self.routes), "--state-dir", str(self.state), "--operation", "one", "--send"]
        result = subprocess.run(command, env=self.env, capture_output=True, timeout=20)
        self.assertEqual(result.returncode, -signal.SIGKILL)
        self.assertTrue(self.receipt()["send_attempted"])
        self.change(kill_parent=False)
        self.assertEqual(self.call(send=True)["outcome"], "sent")
        self.assertEqual(self.browser()["clicks"], 1)

    def test_unconfirmed_send_stops_retries_and_cancel(self):
        self.change(no_publication=True, postclick_wrong_title=True)
        self.assertEqual(self.call(send=True)["outcome"], "uncertain")
        self.assertEqual(self.call(send=True)["outcome"], "uncertain")
        self.assertEqual(self.call(status="cancel")["outcome"], "uncertain")
        self.assertEqual(self.browser()["clicks"], 1)
        self.assertEqual(self.browser()["fills"], 1)

    def test_wrong_route_account_title_ambiguous_composer_or_draft_never_mutates(self):
        for flag in ("wrong_account", "wrong_url", "wrong_title", "ambiguous_editor", "ambiguous_send", "foreign_draft"):
            with self.subTest(flag=flag):
                self.fixture.write_text(json.dumps({flag: True}))
                value = self.call(operation=flag)
                self.assertEqual(value["outcome"], "needs_attention")
                self.assertEqual(self.browser().get("fills", 0), 0)
                self.assertEqual(self.browser().get("clicks", 0), 0)
                # An empty task can be cancelled only after resolving the condition.
                self.change(**{flag: False})
                self.assertEqual(self.call(operation=flag, status="cancel")["reason"], "cancelled")

    def test_changed_payload_same_id_refused_even_after_confirmation(self):
        self.assertEqual(self.call(send=True)["outcome"], "sent")
        receipt = (self.state / "one/receipt.json").read_bytes()
        payload = json.loads(self.payload.read_text())
        payload["blocks"][0]["text"] = "Changed payload"
        self.payload.write_text(json.dumps(payload))
        result = self.call(send=True)
        self.assertEqual(result["outcome"], "needs_attention")
        self.assertEqual(result["reason"], "operation_id_payload_or_route_changed")
        self.assertEqual((self.state / "one/receipt.json").read_bytes(), receipt)
        self.assertEqual(self.browser()["clicks"], 1)

    def test_stable_send_id_required_before_browser(self):
        self.assertEqual(self.call(send=True, operation=None)["reason"], "send_requires_stable_operation_id")
        self.assertEqual(self.browser(), {})

    def test_cancel_preserves_foreign_changes(self):
        self.call()
        self.change(foreign_draft=True)
        self.assertEqual(self.call(status="cancel")["reason"], "draft_changed_cancel_refused")
        self.assertEqual(self.browser()["fills"], 1)
        self.assertNotEqual(self.browser()["task"]["state"], "finished")
        self.change(foreign_draft=False)
        self.assertEqual(self.call(status="cancel")["reason"], "cancelled")
        self.assertEqual(self.browser()["rendered"], "")
        self.assertEqual(self.browser()["task"]["state"], "finished")
        self.assertEqual(self.call(send=True)["reason"], "operation_cancelled_use_a_new_id")
        self.assertEqual(self.call(send=True)["reason"], "operation_cancelled_use_a_new_id")
        self.assertEqual(self.call(status="status")["reason"], "cancelled")
        self.assertEqual(self.browser().get("clicks", 0), 0)

    def test_alias_reservation_blocks_another_operation(self):
        self.call()
        self.assertEqual(self.call(operation="two")["reason"], "route_owned_by_another_operation")
        self.assertEqual(self.browser()["fills"], 1)
        self.assertEqual(self.call(status="cancel")["reason"], "cancelled")
        self.assertEqual(self.call(operation="two")["outcome"], "preview")

    def test_permissions_and_task_ownership(self):
        self.call()
        for path in self.state.rglob("*"):
            self.assertEqual(path.stat().st_mode & 0o777, 0o700 if path.is_dir() else 0o600)
        self.change(foreign_task=True)
        self.assertEqual(self.call(status="cancel")["reason"], "task_ownership_changed")
        self.assertEqual(self.browser()["fills"], 1)

    def test_group_mention_preview_and_confirmed_real_publication(self):
        self.group_route()
        payload = json.loads(self.payload.read_text())
        payload["mention"] = MENTION
        self.payload.write_text(json.dumps(payload))
        self.assertEqual(self.call()["outcome"], "preview")
        self.assertEqual(self.browser()["composer"]["mentions"], [CHIP])
        self.assertEqual(self.browser()["mention_keys"], "@Other")
        self.assertEqual(self.call(send=True)["outcome"], "sent")
        self.assertEqual(self.call(send=True)["outcome"], "sent")
        self.assertEqual(self.browser()["clicks"], 1)

    def test_dm_required_mention_stops_before_browser(self):
        payload = json.loads(self.payload.read_text())
        payload["mention"] = MENTION
        self.payload.write_text(json.dumps(payload))
        self.assertEqual(self.call(send=True)["reason"], "required_dm_mention_unsupported")
        self.assertEqual(self.browser(), {})

    def test_mention_ambiguous_wrong_identity_and_dialog_never_send(self):
        self.group_route()
        payload = json.loads(self.payload.read_text())
        payload["mention"] = MENTION
        self.payload.write_text(json.dumps(payload))
        for flag, reason in (("ambiguous_mention", "mention_option_ambiguous"), ("wrong_mention_email", "mention_option_identity_changed"), ("mention_dialog", "dialog_requires_attention")):
            with self.subTest(flag=flag):
                self.fixture.write_text(json.dumps({flag: True}))
                result = self.call(operation=flag, send=True)
                self.assertEqual(result["reason"], reason)
                self.assertEqual(self.browser().get("clicks", 0), 0)
                # No actual chip was selected; the fixture can be discarded, while
                # the real CLI correctly retains its unresolved reservation.
                for owner in self.state.glob("route-*.json"):
                    owner.unlink()

    def test_real_chip_validator_rejects_plain_name(self):
        payload, _, expected = SENDER.payload_config(self.payload)
        mention = MENTION
        body = copy.deepcopy(BODY)
        self.assertFalse(SENDER.matching(body, expected, mention))
        body = mentioned_body()
        body["mentions"][0]["selected"] = False
        self.assertFalse(SENDER.matching(body, expected, mention))
        body["mentions"][0]["selected"] = True
        self.assertTrue(SENDER.matching(body, expected, mention))
        self.assertFalse(SENDER.matching(body, expected, mention, published=True))
        self.assertTrue(SENDER.matching(mentioned_body(published=True), expected, mention, published=True))
        body["mentions"][0]["user_id"] = "wrong-user"
        self.assertFalse(SENDER.matching(body, expected, mention))

    def test_code_and_signature_semantics_are_exact(self):
        _, _, expected = SENDER.payload_config(self.payload)
        self.assertTrue(SENDER.matching(BODY, expected))
        for change in ("code_space", "list", "backslash", "quote"):
            body = copy.deepcopy(BODY)
            if change == "code_space":
                body["blocks"][1]["text"] += " "
            elif change == "list":
                body["signature_list"] = True
            elif change == "quote":
                body["forbidden"] = True
            else:
                body["blocks"][-1]["text"] = "\\- sent by Fulcrum"
            self.assertFalse(SENDER.matching(body, expected), change)

    def test_actual_probe_rejects_styled_signature_in_composer_and_publication(self):
        payload = {"version": 1, "blocks": [{"type": "text", "text": "hello"}]}
        self.payload.write_text(json.dumps(payload))
        _, _, expected = SENDER.payload_config(self.payload)
        result = subprocess.run(["node", str(BASE / "tests/dom-probe.test.js"), "--signature-bodies"], capture_output=True, text=True, check=True)
        for kind, bodies in json.loads(result.stdout).items():
            for stage, body in bodies.items():
                with self.subTest(kind=kind, stage=stage):
                    self.assertEqual(SENDER.matching(body, expected, published=stage == "publication"), kind in ("plain", "body-bold"))

    def test_signature_consolidation_does_not_change_code(self):
        payload = json.loads(self.payload.read_text())
        payload["blocks"][0]["text"] += "\n\n" + SIGNATURE + "\n" + SIGNATURE
        payload["blocks"][1]["text"] += "\n" + SIGNATURE
        self.payload.write_text(json.dumps(payload))
        _, rendered, expected = SENDER.payload_config(self.payload)
        self.assertEqual(rendered.count(SIGNATURE), 2)  # One literal inside code, one attribution.
        self.assertTrue(expected[1]["text"].endswith(SIGNATURE))

    def test_malformed_oversized_and_failed_browser_outputs_are_bounded(self):
        for flag in ("malformed", "oversized", "command_failure"):
            with self.subTest(flag=flag):
                self.fixture.write_text(json.dumps({flag: True}))
                result = self.call(operation=flag)
                self.assertEqual(result["outcome"], "needs_attention")
                self.assertEqual(self.browser().get("clicks", 0), 0)
                # No task/composer was returned or touched, so release the reservation.
                self.fixture.write_text("{}")
                self.call(status="cancel", operation=flag)

    def test_timeout_output_is_bounded_and_does_not_send(self):
        record = {}
        browser = SENDER.Browser(record, lambda: None)
        with mock.patch.object(SENDER.subprocess, "run", side_effect=subprocess.TimeoutExpired("private command", 40)):
            with self.assertRaises(SENDER.Stop) as raised:
                browser.call("start", "accounts")
        self.assertEqual(raised.exception.reason, "browser_timeout")
        self.assertEqual(record["action_count"], 1)

    def test_pending_foreign_or_preexisting_message_cannot_confirm(self):
        self.call()
        operation = SENDER.Operation(self.state, "one")
        operation.record.update(sender_id="sender-1", baseline_ids=["before-own", "before-other"])
        dom = json.loads((BASE / "tests/dom.json").read_text())
        candidate = {"id": "new-own", "sender_id": "sender-1", "server": True, "body_count": 1, "body": BODY}
        dom["messages"] = [candidate]
        dom["message_ids"].append("new-own")
        self.assertIsNotNone(operation.publication(dom))
        for change in ({"server": False}, {"sender_id": "other"}, {"id": "before-own"}, {"body_count": 2}, {"body": None}):
            dom["messages"] = [{**candidate, **change}]
            self.assertIsNone(operation.publication(dom))
        dom["messages"] = [candidate, {**candidate, "id": "second"}]
        dom["message_ids"].append("second")
        with self.assertRaises(SENDER.Stop):
            operation.publication(dom)

    def test_identical_content_different_operations_is_not_deduplicated(self):
        self.assertEqual(self.call(send=True)["outcome"], "sent")
        self.change(published=False)
        self.env["CHAT_SEND_RECEIPT"] = str(self.state / "two/receipt.json")
        self.assertEqual(self.call(send=True, operation="two")["outcome"], "sent")
        self.assertEqual(self.browser()["clicks"], 2)


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--fake-browser":
        sys.exit(fake_browser())
    unittest.main()
