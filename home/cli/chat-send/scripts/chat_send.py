#!/usr/bin/env python3
"""Private, task-owned Google Chat sender. No Google APIs or model calls."""

import argparse
from contextlib import contextmanager
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
import time
import uuid

SIGNATURE = "- sent by Fulcrum"
MARKER = "\u200b"
EXIT = {"preview": 0, "sent": 0, "needs_attention": 2, "uncertain": 3, "failed": 1}
EDITOR = {"role": "textbox", "name": "History is on", "exact": True}
SEND = {"role": "button", "name": "Send message", "exact": True}
PROBE = Path(__file__).with_name("dom_probe.js").read_text()
TOKEN = re.compile(r"[a-zA-Z0-9][a-zA-Z0-9_-]{0,79}\Z")
URL = re.compile(r"https://chat\.google\.com/(?:u/[0-9]+/)?app/(?:chat|space)/[a-zA-Z0-9_-]+\Z")


class Stop(Exception):
    def __init__(self, reason, outcome="needs_attention"):
        super().__init__(reason)
        self.reason, self.outcome = reason, outcome


def encode(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()


def digest(value):
    return hashlib.sha256(encode(value)).hexdigest()


def route_key(route):
    # Account-selection URL prefixes can still refer to the same shared composer.
    return digest(re.sub(r"^https://chat\.google\.com/(?:u/[0-9]+/)?", "", route["url"]))


def private_dir(path):
    path = Path(path)
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
        raise Stop("unsafe_state_directory", "failed")
    os.chmod(path, 0o700)
    return path


def atomic(path, value):
    data = encode(value)
    fd, tmp = tempfile.mkstemp(prefix=".write-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as out:
            out.write(data)
            out.flush()
            os.fsync(out.fileno())
        os.replace(tmp, path)
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def read_json(path, private=False):
    try:
        info = Path(path).lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_size > 131072:
            raise Stop("invalid_input_file")
        if private and (info.st_uid != os.getuid() or info.st_mode & 0o077):
            raise Stop("input_file_must_be_private")
        with open(path, "rb") as stream:
            return json.loads(stream.read(131073))
    except (OSError, ValueError, RecursionError) as error:
        raise Stop("unreadable_or_invalid_json") from error


@contextmanager
def lock(path):
    fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        os.fchmod(fd, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise Stop("operation_or_route_busy") from error
        yield
    finally:
        os.close(fd)


def route_config(path, alias):
    if not TOKEN.fullmatch(alias):
        raise Stop("invalid_route_alias")
    config = read_json(path, private=True)
    if not isinstance(config, dict) or config.get("version") != 1 or not isinstance(config.get("routes"), dict):
        raise Stop("invalid_routes")
    route = config["routes"].get(alias)
    required = {"url", "title", "account", "account_label"}
    if not isinstance(route, dict) or not required <= set(route) or set(route) - required - {"kind"}:
        raise Stop("route_missing_or_invalid")
    if not all(isinstance(v, str) and 0 < len(v) < 2048 for v in route.values()):
        raise Stop("invalid_route_values")
    if not URL.fullmatch(route["url"]) or not re.fullmatch(r"[^\s()@]+@[^\s()@]+", route["account"]):
        raise Stop("noncanonical_route_or_account")
    if not route["account_label"].startswith("Google Account:") or not route["account_label"].endswith("(" + route["account"] + ")"):
        raise Stop("invalid_account_label")
    if route.get("kind", "dm") not in ("dm", "group"):
        raise Stop("invalid_route_kind")
    return route


def payload_config(path):
    payload = read_json(path)
    if not isinstance(payload, dict) or set(payload) - {"version", "blocks", "operation_id", "mention"} or payload.get("version") != 1:
        raise Stop("invalid_payload")
    blocks = payload.get("blocks")
    if not isinstance(blocks, list) or not 1 <= len(blocks) <= 60:
        raise Stop("invalid_blocks")
    rendered, expected = [], []
    for block in blocks:
        if not isinstance(block, dict) or block.get("type") not in ("text", "code"):
            raise Stop("invalid_block")
        kind = block["type"]
        allowed = {"type", "text", "language"} if kind == "code" else {"type", "text"}
        value = block.get("text")
        if set(block) - allowed or not isinstance(value, str) or not value or "\r" in value or "\x00" in value or MARKER in value:
            raise Stop("invalid_block_text")
        if kind == "code":
            language = block.get("language", "")
            if not isinstance(language, str) or not re.fullmatch(r"[a-zA-Z0-9_+.-]{0,24}", language) or "```" in value:
                raise Stop("invalid_code_fence")
            # Chat renders fence language tags as literal first lines of code.
            rendered.append("```\n" + value + "\n```")
        else:
            # Only standalone plain signatures are consolidated; code is untouched.
            value = "\n".join(line for line in value.split("\n") if line != SIGNATURE).strip("\n")
            if not value:
                continue
            if SIGNATURE in value or "```" in value:
                raise Stop("signature_or_code_must_be_a_separate_block")
            rendered.append(value)
        expected.append({"type": kind, "text": value})
    if not expected:
        raise Stop("empty_message")
    rendered.append(MARKER + SIGNATURE)
    expected.append({"type": "text", "text": SIGNATURE})
    text = "\n\n".join(rendered)
    if len(text.encode()) > 30000:
        raise Stop("message_too_large")
    mention = payload.get("mention")
    if mention is not None:
        if not isinstance(mention, dict) or set(mention) - {"email", "query", "user_id", "member_id"} or not {"email", "query"} <= set(mention):
            raise Stop("invalid_mention")
        if not all(isinstance(v, str) and 0 < len(v) < 200 for v in mention.values()):
            raise Stop("invalid_mention")
        if not re.fullmatch(r"[^\s()@]+@[^\s()@]+", mention["email"]) or not re.fullmatch(r"[a-zA-Z0-9]{2,24}", mention["query"]):
            raise Stop("invalid_mention_identity_or_query")
    return payload, text, normalize_blocks(expected)


def normalize_blocks(blocks):
    result = []
    for block in blocks:
        kind, value = block["type"], block["text"]
        if kind == "text":
            # Native code articles add layout-only blank lines. Code is never normalized.
            value = "\n".join(SIGNATURE if line == MARKER + SIGNATURE else line for line in value.split("\n"))
            value = re.sub(r"\n{3,}", "\n\n", value).strip("\n")
            if not value:
                continue
        if result and kind == "text" and result[-1]["type"] == "text":
            result[-1]["text"] += "\n\n" + value
        else:
            result.append({"type": kind, "text": value})
    return result


def matching(body, expected, mention=None, published=False):
    if not isinstance(body, dict) or body.get("forbidden") or body.get("signature_list") or body.get("signature_plain") is not True:
        return False
    blocks = body.get("blocks")
    if not isinstance(blocks, list) or not all(isinstance(b, dict) for b in blocks):
        return False
    chips = body.get("mentions", [])
    if mention is None:
        if chips:
            return False
    else:
        if len(chips) != 1 or not isinstance(chips[0], dict):
            return False
        chip = chips[0]
        if chip.get("selected") is not True or chip.get("email") != mention["email"] or not chip.get("user_id") or not chip.get("member_id"):
            return False
        if chip.get("mention_type") != ("3" if published else "0"):
            return False
        if any(chip.get(key) != mention[key] for key in ("user_id", "member_id") if key in mention):
            return False
        # A real leading chip is represented separately by the DOM reader. Strip only
        # its verified invisible markers and the single space inserted by our recipe.
        blocks = [dict(b) for b in blocks]
        while blocks and blocks[0].get("type") == "text" and not blocks[0].get("text", "").strip("\n" + MARKER):
            blocks.pop(0)
        if not blocks or blocks.pop(0).get("type") != "mention":
            return False
        if blocks and blocks[0].get("type") == "text":
            value = blocks[0].get("text", "")
            value = value.lstrip(MARKER)
            if not value.startswith(" "):
                return False
            blocks[0]["text"] = value[1:].lstrip(MARKER)
    if not all(isinstance(b, dict) and b.get("type") in ("text", "code") and isinstance(b.get("text"), str) for b in blocks):
        return False
    if normalize_blocks(blocks) != expected:
        return False
    return True


def empty(body):
    return not body.get("text", "").strip("\n") and not body.get("mentions") and not body.get("forbidden") and all(b.get("type") == "text" and not b.get("text", "").strip("\n") for b in body.get("blocks", []))


class Browser:
    def __init__(self, record, persist):
        self.record, self.persist = record, persist

    def call(self, *args, action=None):
        label = action["type"] if action else args[0]
        start = time.monotonic()
        try:
            # Browser output stays private; never include its diagnostic/history in stdout.
            with tempfile.TemporaryFile() as out, tempfile.TemporaryFile() as err:
                result = subprocess.run(["browser-task", *args], input=encode(action) if action else None, stdout=out, stderr=err, timeout=40, check=False)
                if result.returncode:
                    raise Stop("browser_command_failed")
                if out.tell() > 131072:
                    raise Stop("browser_output_oversized")
                out.seek(0)
                value = json.load(out)
                if not isinstance(value, dict):
                    raise Stop("browser_output_invalid")
                return value
        except subprocess.TimeoutExpired as error:
            raise Stop("browser_timeout") from error
        except (OSError, ValueError, RecursionError) as error:
            raise Stop("browser_unavailable_or_invalid_output") from error
        finally:
            timings = self.record.setdefault("actions", [])
            timings.append({"action": label, "ms": round((time.monotonic() - start) * 1000)})
            self.record["actions"] = timings[-200:]
            self.record["action_count"] = self.record.get("action_count", 0) + 1
            self.record["action_ms"] = self.record.get("action_ms", 0) + timings[-1]["ms"]
            self.persist()

    def action(self, kind, **values):
        return self.call("action", self.record["task"], "--page", "main", "--timeout", "30", action={"type": kind, **values})

    def ownership(self, resume=False):
        info = self.call("info", self.record["task"])
        if (info.get("task") != self.record["task"] or info.get("profile") != "accounts" or info.get("label") != self.record["label"] or info.get("pages") != self.record["pages"]):
            raise Stop("task_ownership_changed")
        state = info.get("state")
        if state == "kept" and resume:
            self.call("resume", self.record["task"])
        elif state != "active":
            raise Stop("task_not_active")

    def probe(self):
        value = self.action("evaluate", expression=PROBE).get("value")
        if not isinstance(value, dict) or value.get("version") != 1 or value.get("truncated"):
            raise Stop("unsupported_or_truncated_dom")
        return value


class Operation:
    def __init__(self, root, operation_id):
        self.root = root
        self.directory = private_dir(root / operation_id)
        self.path = self.directory / "receipt.json"
        self.record = read_json(self.path, private=True) if self.path.exists() else {"operation_id": operation_id}
        self.browser = Browser(self.record, self.save)
        self.owner_path = self.root / ("route-" + route_key(self.record["request"]["route"]) + ".json") if "request" in self.record else None

    def save(self):
        atomic(self.path, self.record)

    def bind(self, request):
        fingerprint = digest(request)
        if "fingerprint" in self.record and self.record["fingerprint"] != fingerprint:
            raise Stop("operation_id_payload_or_route_changed")
        if "request" not in self.record:
            self.record.update(request=request, fingerprint=fingerprint, outcome="preview", reason="prepared")
            self.save()

    def reserve(self):
        route = self.record["request"]["route"]
        # All aliases and accounts for the same URL share one composer reservation.
        key = route_key(route)
        self.owner_path = self.root / ("route-" + key + ".json")
        if self.owner_path.exists():
            owner = read_json(self.owner_path, private=True)
            if owner.get("operation_id") != self.record["operation_id"]:
                raise Stop("route_owned_by_another_operation")
        else:
            atomic(self.owner_path, {"operation_id": self.record["operation_id"]})

    def release(self):
        if self.owner_path and self.owner_path.exists() and read_json(self.owner_path, private=True).get("operation_id") == self.record["operation_id"]:
            self.owner_path.unlink()

    def checked(self):
        dom = self.browser.probe()
        route = self.record["request"]["route"]
        if dom.get("url") != route["url"] or dom.get("title") != route["title"]:
            raise Stop("route_or_title_changed")
        if dom.get("accounts") != [route["account_label"]]:
            raise Stop("account_changed_or_ambiguous")
        editors = dom.get("editors")
        if not isinstance(editors, list) or len(editors) != 1 or editors[0].get("name") != EDITOR["name"]:
            raise Stop("composer_missing_or_ambiguous")
        if dom.get("send_count") != 1:
            raise Stop("send_control_missing_or_ambiguous")
        if dom.get("dialogs", 0):
            raise Stop("dialog_requires_attention")
        return dom

    def expected(self, body, published=False):
        request = self.record["request"]
        return matching(body, request["expected"], request["payload"].get("mention"), published=published)

    def settle(self, publication=False, body_only=False):
        deadline = time.monotonic() + 12
        while True:
            dom = self.checked()
            if publication:
                found = self.publication(dom)
                if found:
                    return dom, found
            else:
                ready = matching(dom["editors"][0], self.record["request"]["expected"]) if body_only else self.expected(dom["editors"][0])
                if ready:
                    return dom
            if time.monotonic() >= deadline:
                raise Stop("publication_not_confirmed" if publication else "markdown_did_not_settle", "uncertain" if publication else "needs_attention")
            time.sleep(0.2)

    def mention(self):
        mention = self.record["request"]["payload"]["mention"]
        if self.record.get("mention_attempted"):
            raise Stop("mention_composition_interrupted")
        self.record["mention_attempted"] = True
        self.save()
        self.browser.action("click", target=EDITOR)
        for key in ["Control+Home", "Space", "ArrowLeft", "@", *mention["query"]]:
            self.browser.action("key", key=key)
        deadline = time.monotonic() + 6
        while True:
            dom = self.checked()
            options = [o for o in dom.get("options", []) if mention["email"] in o.get("name", "")]
            if len(options) > 1:
                raise Stop("mention_option_ambiguous")
            if options:
                option = options[0]
                if option.get("email") != mention["email"] or option.get("id") != mention["email"] or option.get("chip_type") != "2":
                    raise Stop("mention_option_identity_changed")
                break
            if time.monotonic() >= deadline:
                raise Stop("real_mention_option_unavailable")
            time.sleep(0.2)
        self.browser.action("click", target={"role": "option", "name": mention["email"], "exact": False})
        self.settle()
        self.record["mention_inserted"] = True
        self.save()

    def publication(self, dom):
        baseline = self.record.get("baseline_ids", [])
        own = self.record.get("sender_id")
        ids = dom.get("message_ids", [])
        if not baseline or baseline[-1] not in ids or not empty(dom["editors"][0]):
            return None
        tail = ids.index(baseline[-1])
        matches = [m for m in dom.get("messages", []) if m.get("id") in ids[tail + 1:] and m["id"] not in baseline and m.get("sender_id") == own and m.get("server") is True and m.get("body_count") == 1 and self.expected(m.get("body"), published=True)]
        if len(matches) > 1:
            raise Stop("multiple_new_matching_messages", "uncertain")
        return matches[0] if len(matches) == 1 else None

    def screenshot(self):
        result = self.browser.action("screenshot", full_page=False)
        source = Path(result.get("path", ""))
        info = source.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_size > 16 * 1024 * 1024:
            raise Stop("invalid_screenshot", "failed")
        # Copy into operation storage; browser retention must not expire our receipt.
        destination = self.directory / "screenshot.png"
        fd, tmp = tempfile.mkstemp(prefix=".screenshot-", dir=self.directory)
        try:
            with os.fdopen(fd, "wb") as out, source.open("rb") as inp:
                out.write(inp.read(16 * 1024 * 1024 + 1))
                out.flush()
                os.fsync(out.fileno())
            os.replace(tmp, destination)
        finally:
            if os.path.exists(tmp):
                os.unlink(tmp)
        self.record["screenshot"] = str(destination)
        self.save()

    def finish(self):
        self.browser.ownership()
        self.browser.call("finish", self.record["task"])
        self.record["task_finished"] = True
        self.save()

    def confirm(self, message):
        self.record.update(outcome="sent", reason="publication_confirmed", publication_id=message["id"], confirmed_at=time.time())
        self.save()  # Confirmed delivery survives screenshot/finish failures.
        self.release()
        self.screenshot()
        self.finish()

    def start(self):
        self.record["label"] = "chat-send:" + self.record["operation_id"]
        self.save()
        task = self.browser.call("start", "accounts", "--label", self.record["label"], "--url", self.record["request"]["route"]["url"])
        if not isinstance(task.get("task"), str) or not isinstance(task.get("pages"), dict):
            raise Stop("invalid_task_start_response")
        self.record.update(task=task["task"], pages=task["pages"])
        self.save()
        self.browser.ownership()
        self.browser.action("viewport", width=1440, height=1000)
        self.browser.action("wait", target=EDITOR, state="visible")

    def sender(self, dom):
        account = self.record["request"]["route"]["account"]
        ids = {i["message_id"] for i in dom.get("identities", []) if i.get("email") == account}
        senders = {m["sender_id"] for m in dom.get("messages", []) if m.get("id") in ids and m.get("sender_id")}
        if len(senders) != 1 or not dom.get("publication_supported"):
            raise Stop("publication_identity_not_supported")
        return senders.pop()

    def execute(self, mode, send=False):
        if self.record.get("outcome") == "sent":
            self.release()
            return
        if self.record.get("cancelled"):
            if mode != "status":
                raise Stop("operation_cancelled_use_a_new_id")
            return
        if self.record.get("send_attempted"):
            if not self.record.get("task"):
                raise Stop("attempted_task_missing", "uncertain")
            self.browser.ownership(resume=True)
            _, message = self.settle(publication=True)
            self.confirm(message)
            return
        if mode == "status":
            return
        if mode != "cancel" and self.record["request"]["payload"].get("mention") and self.record["request"]["route"].get("kind", "dm") != "group":
            raise Stop("required_dm_mention_unsupported")
        self.reserve()
        if mode == "cancel" and not self.record.get("task"):
            self.record.update(outcome="preview", reason="cancelled", cancelled=True)
            self.save()
            self.release()
            return
        if not self.record.get("task"):
            self.start()
        else:
            self.browser.ownership(resume=True)
        dom = self.checked()
        editor = dom["editors"][0]
        if mode == "cancel":
            if not empty(editor):
                def owned(body):
                    return self.expected(body) or (not self.record.get("mention_attempted") and matching(body, self.record["request"]["expected"]))

                if not self.record.get("draft_written") or not owned(editor):
                    raise Stop("draft_changed_cancel_refused")
                # Fresh guard immediately before clearing the exact owned draft.
                if not owned(self.checked()["editors"][0]):
                    raise Stop("draft_changed_cancel_refused")
                self.browser.action("fill", target=EDITOR, text="")
                if not empty(self.checked()["editors"][0]):
                    raise Stop("cancel_clear_not_confirmed")
            self.finish()
            self.record.update(outcome="preview", reason="cancelled", cancelled=True)
            self.save()
            self.release()
            return
        if self.record.get("draft_written"):
            if not self.expected(editor):
                if self.record["request"]["payload"].get("mention") and not self.record.get("mention_attempted") and matching(editor, self.record["request"]["expected"]):
                    self.mention()
                else:
                    raise Stop("owned_draft_changed")
        elif not empty(editor):
            raise Stop("foreign_draft")
        else:
            # Persist ownership intent first; an interrupted fill cannot overwrite on retry.
            self.record["draft_written"] = True
            self.save()
            self.browser.action("fill", target=EDITOR, text=self.record["request"]["rendered"])
            dom = self.settle(body_only=True)
            if self.record["request"]["payload"].get("mention"):
                self.mention()
        if not send:
            self.screenshot()
            self.browser.call("keep", self.record["task"])
            self.record.update(outcome="preview", reason="ready_for_review")
            self.save()
            return
        dom = self.checked()
        if not self.expected(dom["editors"][0]) or not dom.get("send_enabled"):
            raise Stop("draft_changed_or_send_disabled")
        sender = self.sender(dom)
        baseline = dom.get("message_ids")
        if not isinstance(baseline, list) or not all(isinstance(i, str) and i for i in baseline) or len(baseline) != len(set(baseline)):
            raise Stop("publication_ids_ambiguous")
        self.record.update(send_attempted=True, attempted_at=time.time(), baseline_ids=baseline, sender_id=sender, outcome="uncertain", reason="send_attempt_recorded")
        self.save()  # Never move this write after the click or reset it on failure.
        self.browser.action("click", target=SEND)
        _, message = self.settle(publication=True)
        self.confirm(message)


def parser():
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("mode", nargs="?", choices=("status", "cancel"), default=None)
    result.add_argument("--route")
    result.add_argument("--message", type=Path)
    result.add_argument("--send", action="store_true")
    result.add_argument("--operation")
    result.add_argument("--routes-file", type=Path, default=Path(os.environ.get("XDG_CONFIG_HOME", str(Path.home() / ".config"))) / "chat-send/routes.json")
    result.add_argument("--state-dir", type=Path, default=Path(os.environ.get("XDG_STATE_HOME", str(Path.home() / ".local/state"))) / "chat-send")
    return result


def run(args):
    try:
        if args.mode:
            if not args.operation or args.route or args.message or args.send:
                raise Stop("status_cancel_require_only_operation")
            operation_id, request = args.operation, None
        else:
            if not args.route or not args.message:
                raise Stop("route_and_message_required")
            route = route_config(args.routes_file, args.route)
            payload, rendered, expected = payload_config(args.message)
            embedded = payload.get("operation_id")
            if embedded is not None and (not isinstance(embedded, str) or not TOKEN.fullmatch(embedded)):
                raise Stop("invalid_operation_id")
            if embedded and args.operation and embedded != args.operation:
                raise Stop("operation_id_disagrees")
            operation_id = args.operation or embedded
            if args.send and not operation_id:
                raise Stop("send_requires_stable_operation_id")
            operation_id = operation_id or uuid.uuid4().hex
            payload.pop("operation_id", None)
            request = {"alias": args.route, "route": route, "payload": payload, "rendered": rendered, "expected": expected}
        if not isinstance(operation_id, str) or not TOKEN.fullmatch(operation_id):
            raise Stop("invalid_operation_id")
        os.umask(0o077)
        root = private_dir(args.state_dir)
        with lock(root / (operation_id + ".lock")):
            op = None
            try:
                if request is None and not (root / operation_id / "receipt.json").exists():
                    raise Stop("operation_not_found")
                op = Operation(root, operation_id)
                if request:
                    op.bind(request)
                key = route_key(op.record["request"]["route"])
                with lock(root / ("route-" + key + ".lock")):
                    op.execute(args.mode or "prepare", send=args.send)
                return summary(op)
            except (Stop, OSError, KeyError, TypeError, ValueError, RecursionError) as error:
                reason = error.reason if isinstance(error, Stop) else "internal_or_storage_error"
                outcome = error.outcome if isinstance(error, Stop) else "failed"
                if op is not None:
                    if reason == "operation_id_payload_or_route_changed":
                        outcome = "needs_attention"
                    elif op.record.get("outcome") == "sent":
                        # Receipt cleanup failure cannot erase actual publication evidence.
                        outcome, reason = "sent", "publication_confirmed_cleanup_incomplete"
                    elif op.record.get("send_attempted"):
                        outcome = "uncertain"
                    # Receipt updates, including failures, stay under the operation lock.
                    if reason not in ("operation_id_payload_or_route_changed", "operation_cancelled_use_a_new_id"):
                        op.record.update(outcome=outcome, reason=reason)
                        try:
                            op.save()
                        except OSError:
                            pass
                    result = summary(op)
                    result.update(outcome=outcome, reason=reason)
                    return result
                return {"outcome": outcome, "reason": reason, "operation_id": operation_id}
    except (Stop, OSError, KeyError, TypeError, ValueError, RecursionError) as error:
        # No receipt may be read or saved outside its operation lock.
        reason = error.reason if isinstance(error, Stop) else "internal_or_storage_error"
        outcome = error.outcome if isinstance(error, Stop) else "failed"
        return {"outcome": outcome, "reason": reason, "operation_id": args.operation}


def summary(op):
    record = op.record
    return {"outcome": record.get("outcome", "failed"), "reason": record.get("reason", "unknown"), "operation_id": record["operation_id"], "receipt": str(op.path), "task": record.get("task"), "action_count": record.get("action_count", 0), "action_ms": record.get("action_ms", 0), "send_attempted": bool(record.get("send_attempted"))}


def main():
    result = run(parser().parse_args())
    print(json.dumps(result, separators=(",", ":")))
    return EXIT[result["outcome"]]


if __name__ == "__main__":
    sys.exit(main())
