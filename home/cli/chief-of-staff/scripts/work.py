#!/usr/bin/env python3
"""Coordinator-owned Work records. Immutable events are authoritative; snapshots are views."""

import argparse
from contextlib import contextmanager
from copy import deepcopy
from datetime import datetime, timedelta, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import tempfile

VERSION = 1
SNAPSHOT_LIMIT = 768 * 1024
ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:-]{0,79}\Z")
TERMINAL = re.compile(r"(?:[A-Za-z0-9._-]+/)?t[0-9a-z]+\Z")
KINDS = {
    "task": ({"outcome", "next_action"}, set()),
    "plan": ({"checkpoints"}, set()),
    "revise": ({"checkpoints", "reason"}, set()),
    "check-in": ({"step", "next_action", "summary"}, {"quiet_seconds", "quiet_reason"}),
    "verify": ({"checkpoint", "summary", "evidence"}, set()),
    "block": ({"issue", "message", "needs_user"}, {"checkpoint"}),
    "resolve": ({"issue", "summary"}, set()),
    "worker": ({"terminal", "status", "summary"}, set()),
    "lifecycle": ({"state", "next_action"}, set()),
}


class RecordError(ValueError):
    pass


def utc_now():
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def text(value, name, limit=1000):
    if not isinstance(value, str) or not value.strip() or len(value) > limit or any(ord(c) < 32 for c in value):
        raise RecordError(f"{name}: expected nonempty single-line text, at most {limit} characters")
    return value


def identifier(value, name="id"):
    if not isinstance(value, str) or not ID.fullmatch(value):
        raise RecordError(f"{name}: use 1–80 letters, digits, dot, underscore, colon or hyphen")
    return value


def fields(value, required, optional=frozenset()):
    if not isinstance(value, dict) or required - value.keys() or value.keys() - required - optional:
        raise RecordError(f"Expected fields {sorted(required)}; optional {sorted(optional)}")


def checkpoints(value):
    if not isinstance(value, list) or not 1 <= len(value) <= 32:
        raise RecordError("checkpoints: supply 1–32 checkpoints")
    result = []
    for cp in value:
        fields(cp, {"id", "title", "depends", "acceptance"})
        identifier(cp["id"], "checkpoint id")
        text(cp["title"], "title", 200)
        text(cp["acceptance"], "acceptance")
        if not isinstance(cp["depends"], list) or len(cp["depends"]) > 32:
            raise RecordError("depends must be a list of checkpoint IDs")
        for dep in cp["depends"]:
            identifier(dep, "dependency")
        if len(set(cp["depends"])) != len(cp["depends"]):
            raise RecordError("duplicate dependency")
        result.append(deepcopy(cp))
    by_id = {cp["id"]: cp for cp in result}
    if len(by_id) != len(result):
        raise RecordError("duplicate checkpoint ID")
    visiting, visited = set(), set()

    def visit(cp_id):
        if cp_id in visiting or cp_id not in by_id:
            raise RecordError("checkpoint dependencies must exist and be acyclic")
        if cp_id in visited:
            return
        visiting.add(cp_id)
        for dep in by_id[cp_id]["depends"]:
            visit(dep)
        visiting.remove(cp_id)
        visited.add(cp_id)

    for cp_id in by_id:
        visit(cp_id)
    return result


def validate_event(event):
    if not isinstance(event, dict) or event.get("kind") not in KINDS:
        raise RecordError("Unknown event kind")
    required, optional = KINDS[event["kind"]]
    fields(event, {"id", "kind", "task"} | required, optional)
    for key in ("id", "task"):
        identifier(event[key], key)
    kind = event["kind"]
    for key in ("outcome", "next_action", "summary", "reason", "message", "step", "quiet_reason"):
        if key in event:
            text(event[key], key)
    for key in ("checkpoint", "issue"):
        if key in event:
            identifier(event[key], key)
    if kind in ("plan", "revise"):
        checkpoints(event["checkpoints"])
    if kind == "check-in":
        quiet = event.get("quiet_seconds", 300)
        if type(quiet) is not int or not 60 <= quiet <= 86400:
            raise RecordError("quiet_seconds must be an integer from 60 to 86400")
        if quiet > 300 and not event.get("quiet_reason"):
            raise RecordError("A quiet window longer than five minutes requires quiet_reason")
    if kind == "verify":
        evidence = event["evidence"]
        if not isinstance(evidence, list) or not 1 <= len(evidence) <= 8:
            raise RecordError("verify requires 1–8 concrete evidence references")
        for ref in evidence:
            text(ref, "evidence")
    if kind == "block" and type(event["needs_user"]) is not bool:
        raise RecordError("needs_user must be boolean")
    if kind == "worker":
        if not isinstance(event["terminal"], str) or not TERMINAL.fullmatch(event["terminal"]):
            raise RecordError("terminal must be a literal Herdr terminal address")
        if event["status"] not in ("working", "idle", "blocked", "done", "unavailable"):
            raise RecordError("invalid worker status")
    if kind == "lifecycle" and event["state"] not in ("queued", "active", "paused", "cancelled", "done"):
        raise RecordError("invalid task state")
    return deepcopy(event)


def encode(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":")) + "\n"


def atomic_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, temporary = tempfile.mkstemp(prefix=".pending-", dir=path.parent)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w") as stream:
            stream.write(encode(value))
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


@contextmanager
def lock(directory):
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (directory / ".lock").open("a") as stream:
        fcntl.flock(stream, fcntl.LOCK_EX)
        yield


def root():
    return Path(os.environ.get("XDG_STATE_HOME") or Path.home() / ".local/state") / "chief-of-staff"


def discovery_path(space):
    return root() / "work-spaces" / hashlib.sha256(space.encode()).hexdigest() / "source.json"


def read_json(path):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError) as exc:
        raise RecordError(f"Invalid or unavailable record {path}: {exc}") from exc


def identity():
    terminal, core = os.environ.get("HC_TERMINAL_ID"), os.environ.get("HC_TERMINAL_SOCKET")
    if not terminal or not core:
        raise RecordError("HC_TERMINAL_ID and HC_TERMINAL_SOCKET are required for writes")
    return terminal, core


def assert_owner(registration):
    terminal, core = identity()
    if (terminal, core) != (registration["coordinator"], registration["core"]):
        raise RecordError("Only the registered coordinator terminal on its owning core may write Work records")


def register(portfolio, space, *, allow_transfer=False, fixture=False):
    portfolio = portfolio.resolve()
    terminal, core = identity()
    text(space, "space", 200)
    if not (portfolio / "portfolio.md").is_file():
        raise RecordError("Register an existing portfolio directory")
    work = portfolio / "work"
    discovery = discovery_path(space)
    # Different spaces never share writable discovery files. Same-space registration
    # serializes separately from each portfolio's sole event writer.
    with lock(discovery.parent), lock(work):
        if discovery.exists():
            existing = read_json(discovery)
            if existing["portfolio"] != str(portfolio) and not allow_transfer:
                raise RecordError("Another portfolio is registered for this space; explicitly resume with --portfolio")
        reg_path = work / "registration.json"
        if reg_path.exists():
            old = read_json(reg_path)
            if (old["coordinator"], old["core"]) != (terminal, core) and not allow_transfer:
                raise RecordError("Ownership changed: explicitly resume with chief-of-staff-init --portfolio")
        registration = {"version": VERSION, "portfolio": str(portfolio), "space": space,
                        "coordinator": terminal, "core": core, "fixture": fixture, "registered_at": utc_now()}
        atomic_json(reg_path, registration)
        snapshot = rebuild(portfolio, registration)
        atomic_json(work / "snapshot.json", snapshot)
        atomic_json(discovery, {"version": VERSION, "space": space, "portfolio": str(portfolio)})
    return snapshot


def apply_event(tasks, event, at, seq):
    kind, task_id = event["kind"], event["task"]
    if kind == "task":
        if task_id in tasks:
            raise RecordError("Task ID already exists; never reuse task IDs")
        tasks[task_id] = {"id": task_id, "outcome": event["outcome"], "state": "queued",
                          "next_action": event["next_action"], "step": "No check-in yet", "baseline": None,
                          "current": [], "revisions": [], "history": [], "activity": [], "workers": {}, "issues": [],
                          "check_in": None, "last_verified": None, "created_at": at, "updated_at": at}
    if task_id not in tasks:
        raise RecordError("Publish a task event before its plan or updates")
    task = tasks[task_id]
    by_id = {cp["id"]: cp for cp in task["current"]}
    if kind in ("plan", "revise"):
        if task["state"] == "done":
            raise RecordError("Explicitly reactivate completed work before revising its plan")
        if (kind == "plan") != (task["baseline"] is None):
            raise RecordError("Publish the original plan once; use revise for subsequent scope changes")
        proposed = checkpoints(event["checkpoints"])
        added, removed, changed = [], [], []
        current = []
        for cp in proposed:
            old = by_id.get(cp["id"])
            same = old is not None and all(old[key] == cp[key] for key in cp)
            if not old:
                added.append(cp["id"])
            elif not same:
                changed.append(cp["id"])
            current.append({**cp, "version": old["version"] if same else (old["version"] + 1 if old else 1),
                            "verification": old["verification"] if same else None})
        removed = [key for key in by_id if key not in {cp["id"] for cp in proposed}]
        if kind == "revise" and not (added or removed or changed):
            raise RecordError("Revision must change planned scope")
        # Changed prerequisites invalidate dependent verification transitively.
        invalid = set(added + removed + changed)
        for _ in current:
            for cp in current:
                if any(dep in invalid for dep in cp["depends"]):
                    if cp["id"] not in invalid:
                        cp["version"] += 1
                        changed.append(cp["id"])
                    invalid.add(cp["id"])
                    cp["verification"] = None
        task["current"] = current
        if kind == "plan":
            task["baseline"] = {"at": at, "event": event["id"], "checkpoints": deepcopy(proposed)}
            task["check_in"] = {"at": at, "due": (datetime.fromisoformat(at.replace("Z", "+00:00")) + timedelta(seconds=300)).isoformat().replace("+00:00", "Z"), "summary": "Plan published", "quiet_reason": None}
        task["revisions"].append({"event": event["id"], "at": at, "reason": event.get("reason", "Original baseline"),
                                   "added": added, "removed": removed, "changed": changed,
                                   "checkpoints": deepcopy(proposed)})
    elif kind == "check-in":
        if task["state"] in ("done", "cancelled"):
            raise RecordError("Reactivate the task before a new check-in")
        task["step"], task["next_action"] = event["step"], event["next_action"]
        task["check_in"] = {"at": at, "due": (datetime.fromisoformat(at.replace("Z", "+00:00")) + timedelta(seconds=event.get("quiet_seconds", 300))).isoformat().replace("+00:00", "Z"), "summary": event["summary"], "quiet_reason": event.get("quiet_reason")}
    elif kind == "verify":
        cp = by_id.get(event["checkpoint"])
        if not cp or cp["verification"] or any(not by_id[dep]["verification"] for dep in cp["depends"]):
            raise RecordError("Verify an unverified current checkpoint only after its dependencies")
        if any(not issue["resolved"] and issue.get("checkpoint") in (None, cp["id"]) for issue in task["issues"]):
            raise RecordError("Resolve the checkpoint's blockers before verification")
        if task["state"] in ("done", "cancelled"):
            raise RecordError("Reactivate the task before verification")
        cp["verification"] = {"event": event["id"], "at": at, "summary": event["summary"], "evidence": event["evidence"]}
        task["last_verified"] = {**cp["verification"], "checkpoint": cp["id"]}
    elif kind == "block":
        if any(issue["id"] == event["issue"] for issue in task["issues"]):
            raise RecordError("Issue IDs are permanent; use a new ID for a new decision")
        if "checkpoint" in event and event["checkpoint"] not in by_id:
            raise RecordError("Unknown checkpoint for blocker")
        task["issues"].append({"id": event["issue"], "at": at, "message": event["message"],
                               "needs_user": event["needs_user"], "checkpoint": event.get("checkpoint"), "resolved": None})
    elif kind == "resolve":
        issue = next((issue for issue in task["issues"] if issue["id"] == event["issue"]), None)
        if not issue or issue["resolved"]:
            raise RecordError("Resolve an existing unresolved issue")
        issue["resolved"] = {"at": at, "summary": event["summary"]}
    elif kind == "worker":
        report = {"event": event["id"], "at": at, "terminal": event["terminal"], "status": event["status"], "summary": event["summary"]}
        task["activity"].append(report)
        task["workers"][event["terminal"]] = report
    elif kind == "lifecycle":
        if event["state"] == "done" and (not task["baseline"] or any(not cp["verification"] for cp in task["current"]) or any(not issue["resolved"] for issue in task["issues"])):
            raise RecordError("Done requires a baseline, all current checkpoints verified and all issues resolved")
        task["state"], task["next_action"] = event["state"], event["next_action"]
    task["updated_at"] = at
    if kind in ("plan", "revise", "verify", "lifecycle"):
        task["history"].append({"event": event["id"], "seq": seq, "at": at, "kind": kind,
                                "scope": len(task["current"]), "verified": sum(cp["verification"] is not None for cp in task["current"]),
                                "summary": event.get("summary") or event.get("reason") or kind,
                                "checkpoint": deepcopy(by_id[event["checkpoint"]]) if kind == "verify" else None})


def events(portfolio):
    result, seen = [], set()
    for path in sorted((portfolio / "work/events").glob("*.json")):
        record = read_json(path)
        fields(record, {"seq", "at", "event"})
        if type(record["seq"]) is not int or record["seq"] != len(result) + 1 or path.name != f'{record["seq"]:012d}.json':
            raise RecordError("Event sequence is incomplete or out of order; reconcile the history")
        datetime.fromisoformat(record["at"].replace("Z", "+00:00"))
        event = validate_event(record["event"])
        if event["id"] in seen:
            raise RecordError("Duplicate event ID in durable history")
        seen.add(event["id"])
        result.append(record)
    return result


def project(portfolio, registration, records):
    tasks = {}
    for record in records:
        apply_event(tasks, record["event"], record["at"], record["seq"])
    # Legacy Markdown is visible without fabricating its plan or completion.
    legacy = [path.stem for path in sorted((portfolio / "tasks").glob("*.md")) if path.stem not in tasks]
    visible = []
    for task in sorted(tasks.values(), key=lambda task: (task["state"] in ("done", "cancelled"), task["id"])):
        item = deepcopy(task)
        item["workers"] = list(item["workers"].values())
        resolved = [issue["id"] for issue in item["issues"] if issue["resolved"]][-64:]
        retained = set(resolved)
        item["issues"] = [issue for issue in item["issues"] if not issue["resolved"] or issue["id"] in retained]
        item["issues_omitted"] = len(task["issues"]) - len(item["issues"])
        for key, limit in (("history", 96), ("activity", 64), ("revisions", 32)):
            item[key + "_omitted"] = max(0, len(item[key]) - limit)
            item[key] = item[key][-limit:]
        visible.append(item)
    snapshot = {"version": VERSION, "registration": registration, "seq": len(records),
                "published_at": records[-1]["at"] if records else registration["registered_at"],
                "tasks": visible, "legacy": legacy[:128], "legacy_omitted": max(0, len(legacy) - 128), "tasks_omitted": 0}
    while len(encode(snapshot).encode()) > SNAPSHOT_LIMIT:
        # Trim only history, never unresolved issues or the latest worker roster.
        candidates = [(len(task[key]) - minimum, task, key) for task in visible
                      for key, minimum in (("history", 1), ("activity", 0), ("revisions", 1))
                      if len(task[key]) > minimum]
        if candidates:
            available, task, key = max(candidates, key=lambda candidate: candidate[0])
            removed = max(1, available // 2)
            del task[key][:removed]
            task[key + "_omitted"] += removed
            continue
        resolved_task = next((task for task in visible if any(issue["resolved"] for issue in task["issues"])), None)
        if resolved_task is not None:
            old_count = len(resolved_task["issues"])
            resolved_task["issues"] = [issue for issue in resolved_task["issues"] if not issue["resolved"]]
            resolved_task["issues_omitted"] += old_count - len(resolved_task["issues"])
            continue
        archived = next((task for task in reversed(visible) if task["state"] in ("done", "cancelled") and not any(not issue["resolved"] for issue in task["issues"])), None)
        if archived is None:
            raise RecordError("Active work and unresolved issues exceed snapshot capacity; archive completed tasks or reduce record text before publishing")
        visible.remove(archived)
        snapshot["tasks_omitted"] += 1
    return snapshot


def rebuild(portfolio, registration=None):
    return project(portfolio, registration or read_json(portfolio / "work/registration.json"), events(portfolio))


def publish(portfolio, event, *, at=None):
    event = validate_event(event)
    work = portfolio / "work"
    with lock(work):
        registration = read_json(work / "registration.json")
        assert_owner(registration)
        records = events(portfolio)
        old = next((record for record in records if record["event"]["id"] == event["id"]), None)
        if old and old["event"] != event:
            raise RecordError("Event ID already has different content; inspect history before retrying")
        if not old:
            timestamp = at or utc_now()
            if records and timestamp < records[-1]["at"]:
                raise RecordError("Clock moved backwards; reconcile time before publishing")
            records.append({"seq": len(records) + 1, "at": timestamp, "event": event})
        snapshot = project(portfolio, registration, records)  # Validate before durable publication.
        if not old:
            atomic_json(work / "events" / f'{len(records):012d}.json', records[-1])
        # A retry also repairs a snapshot left behind by a crash after event publication.
        atomic_json(work / "snapshot.json", snapshot)
        return {"status": "duplicate" if old else "published", "seq": old["seq"] if old else len(records), "snapshot": str(work / "snapshot.json")}


def require_plan(portfolio, task_id):
    registration = read_json(portfolio / "work/registration.json")
    assert_owner(registration)
    task = next((task for task in rebuild(portfolio)["tasks"] if task["id"] == task_id), None)
    if not task or not task["baseline"] or task["state"] != "active":
        raise RecordError("Publish a task baseline and activate it before implementation dispatch (see references/work-records.md)")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--portfolio", type=Path)
    sub = parser.add_subparsers(dest="command", required=True)
    pub = sub.add_parser("publish", help="Validate and publish one event; reuse its ID on retry")
    pub.add_argument("--event", type=Path, required=True)
    sub.add_parser("snapshot", help="Read/replay without writing")
    sub.add_parser("repair", help="Coordinator-only snapshot rebuild after interruption")
    locate = sub.add_parser("locate", help="Read-only discovery for the native Work panel")
    locate.add_argument("--space", required=True)
    args = parser.parse_args()
    os.umask(0o077)
    try:
        if args.command == "locate":
            source = read_json(discovery_path(args.space))
            if source["space"] != args.space:
                raise RecordError("Work discovery belongs to a different space")
            portfolio = source["portfolio"]
            result = {"snapshot": str(Path(portfolio) / "work/snapshot.json")}
        else:
            if args.portfolio is None:
                raise RecordError("--portfolio is required")
            portfolio = args.portfolio.resolve()
            if portfolio.is_file():
                portfolio = portfolio.parent
            if args.command == "publish":
                result = publish(portfolio, read_json(args.event))
            elif args.command == "snapshot":
                result = rebuild(portfolio)
            else:
                with lock(portfolio / "work"):
                    registration = read_json(portfolio / "work/registration.json")
                    assert_owner(registration)
                    result = rebuild(portfolio, registration)
                    atomic_json(portfolio / "work/snapshot.json", result)
        print(encode(result), end="")
        return 0
    except (RecordError, OSError, ValueError, KeyError, TypeError) as exc:
        print(encode({"status": "error", "message": str(exc)}), file=sys.stderr, end="")
        return 2


if __name__ == "__main__":
    sys.exit(main())
