#!/usr/bin/env python3
"""Generate labeled Work scenarios in a NEW isolated directory; never touch live records."""
from datetime import datetime, timedelta, timezone
import argparse
import json
import os
from pathlib import Path

import work


def generate(destination):
    destination.mkdir(mode=0o700, parents=True, exist_ok=False)
    os.environ.update(XDG_STATE_HOME=str(destination / "private-state"), HC_TERMINAL_ID="tfixture", HC_TERMINAL_SOCKET="/isolated-fixture/core")
    result = {}
    now = datetime.now(timezone.utc).replace(microsecond=0)
    for scenario in ("quiet", "stale", "blocker", "revision", "coordinator-missing", "coordinator-recovery", "history-evidence", "worker-roster", "collection-bounds"):
        portfolio = destination / scenario
        portfolio.mkdir()
        (portfolio / "portfolio.md").write_text(f"ISOLATED FIXTURE: {scenario}; never live work\n")
        work.register(portfolio, f"fixture-{scenario}", fixture=True)
        sequence = 0
        at = now - timedelta(minutes=20)

        def publish(kind, **fields):
            nonlocal sequence, at
            sequence += 1
            at += timedelta(seconds=15)
            work.publish(portfolio, {"id": f"fixture-{sequence}", "kind": kind, "task": "T001", **fields}, at=at.isoformat().replace("+00:00", "Z"))

        def publish_many(extra):
            # Exercise the same validation/projection with a bulk fixture history,
            # avoiding quadratic full-history replay for every synthetic sample.
            records = work.events(portfolio)
            old_count = len(records)
            for event in extra:
                records.append({"seq": len(records) + 1, "at": at.isoformat().replace("+00:00", "Z"), "event": work.validate_event(event)})
            registration = work.read_json(portfolio / "work/registration.json")
            snapshot = work.project(portfolio, registration, records)
            for record in records[old_count:]:
                work.atomic_json(portfolio / "work/events" / f'{record["seq"]:012d}.json', record)
            work.atomic_json(portfolio / "work/snapshot.json", snapshot)

        cp = [{"id": "prepare", "title": "Prepare fixture", "depends": [], "acceptance": "Labeled fixture artifact exists"},
              {"id": "check", "title": "Inspect native rendering", "depends": ["prepare"], "acceptance": "Coordinator captures actual native screenshot"}]
        if scenario == "history-evidence":
            cp.append({"id": "obsolete", "title": "Removed checkpoint", "depends": [], "acceptance": "Original removed criterion"})
        publish("task", outcome=f"ISOLATED FIXTURE · {scenario}", next_action="Inspect fixture scenario")
        publish("plan", checkpoints=cp)
        publish("lifecycle", state="active", next_action="Inspect native rendering")
        publish("verify", checkpoint="prepare", summary="Fixture created (synthetic evidence)", evidence=[str(portfolio / "portfolio.md")])
        publish("check-in", step="check", summary="Waiting for scenario inspection", next_action="Select checkpoint evidence")
        publish("worker", terminal="tfixtureworker", status="working", summary="Synthetic worker report; never live progress")
        if scenario == "quiet":
            at = now - timedelta(minutes=1)
            publish("check-in", step="check", summary="Declared quiet operation", next_action="Read result after quiet window", quiet_seconds=1800, quiet_reason="Labeled quiet fixture")
        elif scenario == "blocker":
            publish("block", issue="fixture-decision", checkpoint="check", needs_user=True, message="ISOLATED FIXTURE decision; OS notification intentionally suppressed")
        elif scenario == "revision":
            publish("revise", reason="Fixture adds a recovery check", checkpoints=cp + [{"id": "recover", "title": "Check recovery", "depends": ["check"], "acceptance": "Retained history survives source outage"}])
        elif scenario == "history-evidence":
            publish("verify", checkpoint="obsolete", summary="Historical accepted result", evidence=[str(portfolio / "portfolio.md") + ": removed checkpoint proof"])
            revised = [cp[0], {**cp[1], "acceptance": "First revised native criterion"}]
            publish("revise", reason="Remove obsolete and revise native criterion", checkpoints=revised)
            publish("revise", reason="Refine native criterion again", checkpoints=[cp[0], {**cp[1], "acceptance": "Current native criterion"}])
        elif scenario == "worker-roster":
            publish_many([{"id": f"busy-{i}", "kind": "worker", "task": "T001", "terminal": "tfixtureother", "status": "working", "summary": f"Synthetic busy report {i}"} for i in range(64)])
        elif scenario == "collection-bounds":
            extra = []
            for i in range(257):
                extra += [{"id": f"closed-block-{i}", "kind": "block", "task": "T001", "issue": f"closed-{i}", "message": "Resolved fixture issue", "needs_user": True},
                          {"id": f"closed-resolve-{i}", "kind": "resolve", "task": "T001", "issue": f"closed-{i}", "summary": "Resolved fixture"}]
            extra += [{"id": f"open-{i}", "kind": "block", "task": "T001", "issue": f"open-{i}", "message": "Unresolved fixture decision", "needs_user": True} for i in range(257)]
            extra += [{"id": f"task-{i}", "kind": "task", "task": f"T{i+2:03d}", "outcome": "Isolated queued fixture", "next_action": "Fixture inspection"} for i in range(257)]
            publish_many(extra)
        if scenario in ("coordinator-missing", "coordinator-recovery"):
            at = now - timedelta(seconds=30)
            publish("check-in", step="check", summary="Saved work survives coordinator absence", next_action="Inspect unavailable and recovered observations")
        result[scenario] = {"source": str(portfolio / "work/snapshot.json"), "fixtureCoordinator": "idle" if scenario == "coordinator-recovery" else "unavailable"}
    (destination / "scenarios.json").write_text(json.dumps(result, indent=2) + "\n")
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path, help="New absolute directory for isolated fixtures (must not exist)")
    args = parser.parse_args()
    if not args.output.is_absolute() or any(part.startswith("-") for part in args.output.parts):
        parser.error("Use an explicit absolute output path without option-like directory names")
    if args.output.exists() or args.output.is_symlink():
        parser.error("Output directory must not already exist")
    print(json.dumps(generate(args.output.resolve()), indent=2))
