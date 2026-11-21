#!/usr/bin/env python3
"""Run a fresh, bounded Terra/Pi Chat worker in a watchable Herdr terminal."""
import argparse
import json
import math
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

from chat_send import EXIT, Stop, TOKEN, atomic, digest, lock, payload_config, private_dir, read_json, route_config

BASE = Path(__file__).resolve().parent
MODEL = "gpt-6.1-terra"
PROVIDER = "litellm"
SYSTEM = (BASE / "worker-system.txt").read_text()
SETTINGS = {"retry": {"enabled": True, "maxRetries": 1, "baseDelayMs": 500, "provider": {"maxRetries": 0, "timeoutMs": 45000}}, "compaction": {"enabled": False}, "quietStartup": True}


def command(args, timeout=45, diagnostics=None):
    result = subprocess.run(args, capture_output=True, text=True, timeout=timeout, check=False)
    if result.returncode or len(result.stdout) > 131072:
        if diagnostics:
            atomic(diagnostics, {"argv": args, "exit": result.returncode, "stdout": result.stdout[-16384:], "stderr": result.stderr[-16384:]})
        raise Stop("worker_command_failed")
    value = json.loads(result.stdout)
    if not isinstance(value, dict):
        raise Stop("worker_command_invalid_response")
    return value


def sender():
    binary = os.environ.get("CHAT_SEND_BIN") or shutil.which("chat-send")
    if not binary or not Path(binary).is_file():
        raise Stop("chat_send_unavailable")
    return str(Path(binary).resolve())


def accounting(directory):
    records = {}
    path = directory / "telemetry.jsonl"
    if path.exists():
        for line in path.read_text().splitlines():
            try:
                event = json.loads(line)
                if event.get("event") == "wire_usage":
                    data = event["data"]
                    records[(data["request"], data.get("id"))] = data
            except (ValueError, KeyError, TypeError):
                continue  # An interrupted final telemetry write is missing, never zero.
    done = read_json(directory / "done.json", private=True) if (directory / "done.json").exists() else {}
    costs = [r["usage"].get("cost") for r in records.values()]
    complete = len({r["request"] for r in records.values()}) == done.get("requests")
    known = bool(costs) and complete and all(isinstance(c, (int, float)) and math.isfinite(c) and c >= 0 for c in costs)
    return {"requests": done.get("requests"), "responses": list(records.values()), "usage_complete": complete, "gateway_cost": sum(costs) if known else None, "cost_source": "gateway usage.cost" if known else "unknown"}


def result_for(root, operation, directory, native=None):
    receipt = root / operation / "receipt.json"
    if receipt.exists():
        record = read_json(receipt, private=True)
        manifest = read_json(directory / "job.json", private=True) if (directory / "job.json").exists() else None
        if manifest:
            payload, _, _ = payload_config(directory / "payload.json")
            if record.get("operation_id") != operation or record["request"]["route"] != manifest["request"]["route"] or record["request"]["payload"] != payload:
                raise Stop("worker_receipt_binding_mismatch", "uncertain")
        value = {"outcome": record.get("outcome", "failed"), "reason": record.get("reason", "unknown"), "operation_id": operation, "receipt": str(receipt), "send_attempted": bool(record.get("send_attempted"))}
        if native:
            value.update({k: native[k] for k in ("outcome", "reason", "send_attempted") if k in native})
    else:
        value = {"outcome": "needs_attention", "reason": "worker_has_no_sender_receipt_inspect_original_job", "operation_id": operation, "receipt": str(directory / "job.json")}
    if not receipt.exists() and (directory / "done.json").exists():
        stopped = read_json(directory / "done.json", private=True).get("result")
        if isinstance(stopped, dict) and stopped.get("operation_id") == operation and stopped.get("reason") == "brief_needs_clarification" and isinstance(stopped.get("detail"), str) and 0 < len(stopped["detail"]) <= 400:
            value.update(outcome="needs_attention", reason="brief_needs_clarification", detail=stopped["detail"], send_attempted=False)
    value.update(worker_job=str(directory), payload=str(directory / "payload.json"), provider=PROVIDER, model=MODEL, thinking="low", accounting=accounting(directory))
    if (directory / "job.json").exists():
        manifest = read_json(directory / "job.json", private=True)
        value.update(route=manifest["alias"], routes_file=manifest["routes_file"], state_dir=str(root))
    return value


def wait_file(path, terminal, marker, deadline):
    while not path.exists():
        if time.monotonic() >= deadline:
            raise Stop("worker_deadline_check_original_operation", "uncertain")
        observed = command(["hc", "wait", terminal, "--output", marker, "--timeout", "10"], timeout=15)
        if observed.get("reason") == "exit" and not path.exists():
            raise Stop("worker_exited_check_original_operation", "uncertain")


def worker_command(directory):
    pi_task = shutil.which("pi-task")
    if not pi_task:
        raise Stop("pi_task_unavailable")
    if not shutil.which("hc"):
        raise Stop("herdr_unavailable")
    return ["env", "CHAT_SEND_JOB=" + str(directory / "job.json"), pi_task,
            "--provider", PROVIDER, "--model", MODEL, "--thinking", "low",
            "--no-builtin-tools", "--tools", "deliver_message", "--no-mcp",
            "--no-extensions", "-e", str(BASE / "worker.ts"), "--no-skills",
            "--no-context-files", "--no-prompt-templates", "--no-themes",
            "--offline", "--approve", "--name", "chat-" + directory.name,
            "--session-dir", str(directory / "sessions"), "--system-prompt", SYSTEM]


def launch(args, directory):
    name = "chat-" + args.operation[:18].lower() + "-" + digest(args.operation)[:8]
    run = worker_command(directory)
    if args.portfolio:
        if not args.task_id:
            raise Stop("portfolio_requires_existing_task_id")
        return ["chief-of-staff-spawn", "--portfolio", str(args.portfolio), "--task-id", args.task_id,
                "--goal", "Prepare the bounded Google Chat job", "--role", "check", "--name", name,
                "--tab-name", "Chat messages", "--cwd", str(directory), "--harness", "pi",
                "--model", "litellm/" + MODEL + "/low", "--no-codex-name", "--", *run]
    return ["hc", "run", "--bg", "--name", name, "--cwd", str(directory), *run]


def execute(args):
    if not TOKEN.fullmatch(args.operation):
        raise Stop("invalid_operation_id")
    root = private_dir(Path(os.path.abspath(args.state_dir.expanduser())))
    jobs = private_dir(root / ".workers")
    directory = jobs / args.operation
    if args.mode:
        if args.route or args.brief or args.send or args.mention_email or args.mention_query:
            raise Stop("status_cancel_require_only_operation")
        if args.mode == "status" and not (root / args.operation / "receipt.json").exists() and directory.exists():
            return result_for(root, args.operation, directory)
        # Native CLI uses nonzero exits for bounded uncertainty; preserve its result.
        return native_result(args.mode, root, args.operation, directory)
    if not args.route or not args.brief:
        raise Stop("route_and_brief_required")
    route = route_config(args.routes_file, args.route)
    with args.brief.open("rb") as inp:
        raw = inp.read(16385)
    if not 1 <= len(raw) <= 16384:
        raise Stop("brief_must_be_1_to_16384_bytes")
    brief = raw.decode("utf-8")
    if not brief.strip() or any(ord(c) < 32 and c not in "\n\t" for c in brief) or "\x7f" in brief:
        raise Stop("invalid_brief_text")
    if bool(args.mention_email) != bool(args.mention_query):
        raise Stop("mention_requires_email_and_query")
    mention = {"email": args.mention_email, "query": args.mention_query} if args.mention_email else None
    if mention and route.get("kind", "dm") != "group":
        raise Stop("required_dm_mention_unsupported")
    request = {"alias": args.route, "route": route, "brief": brief, "send_authorized": args.send, "mention": mention}
    fingerprint = digest(request)
    with lock(jobs / (args.operation + ".lock")):
        directory = private_dir(directory)
        manifest = directory / "job.json"
        if manifest.exists():
            job = read_json(manifest, private=True)
            if job["fingerprint"] != fingerprint:
                raise Stop("worker_operation_request_changed")
            if (directory / "dispatch.json").exists():
                return native_result("status", root, args.operation, directory) if (root / args.operation / "receipt.json").exists() else result_for(root, args.operation, directory)
        elif (root / args.operation / "receipt.json").exists():
            raise Stop("operation_exists_use_chat_send_status")
        else:
            snapshot = directory / "routes.json"
            atomic(snapshot, {"version": 1, "routes": {args.route: route}})
            if mention:
                probe = directory / "mention-validation.json"
                atomic(probe, {"version": 1, "blocks": [{"type": "text", "text": "validation"}], "mention": mention})
                payload_config(probe)
                probe.unlink()
            job = {"version": 1, "operation": args.operation, "alias": args.route, "sender": sender(),
                   "routes_file": str(snapshot), "state_dir": str(root), "send_authorized": args.send,
                   "mention": mention, "request": request, "fingerprint": fingerprint}
            atomic(manifest, job)
        local = private_dir(directory / ".pi")
        atomic(local / "settings.json", SETTINGS)
        argv = launch(args, directory)  # Validate runtime before reserving dispatch.
        atomic(directory / "dispatch.json", {"reserved_at": time.time()})
        terminal = None
        prompt_attempted = False
        try:
            handle = command(argv, timeout=75, diagnostics=directory / "launch-error.json")
            terminal = handle["address"]
            atomic(directory / "dispatch.json", {"terminal": terminal, "launched_at": time.time()})
            wait_file(directory / "ready.json", terminal, "CHAT_SEND_READY", time.monotonic() + 45)
            ready = read_json(directory / "ready.json", private=True)
            if ready.get("model") != MODEL or ready.get("provider") != PROVIDER or ready.get("thinking") != "low" or ready.get("tools") != ["deliver_message"] or ready.get("system_prompt") != SYSTEM + "\n\n<cwd>\n" + str(directory.resolve()) + "\n</cwd>":
                raise Stop("worker_startup_scope_mismatch")
            prompt_attempted = True
            atomic(directory / "prompt-attempt.json", {"at": time.time(), "terminal": terminal})
            sent = command(["hc", "send", terminal, "Prepare the message from this self-contained brief:\n\n" + brief], timeout=75)
            if sent.get("started") is False:
                raise Stop("prompt_delivery_uncertain_check_original_worker", "uncertain")
            wait_file(directory / "done.json", terminal, "CHAT_SEND_DONE", time.monotonic() + 210)
            result = result_for(root, args.operation, directory)
            atomic(directory / "result.json", result)
            return result
        except (Stop, OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
            if prompt_attempted:
                raise Stop("worker_interrupted_check_original_operation", "uncertain") from error
            raise
        finally:
            if terminal:
                cleanup = {}
                for action in ("kill", "rm"):
                    try:
                        cleanup[action] = subprocess.run(["hc", action, terminal], capture_output=True, timeout=15).returncode
                    except (OSError, subprocess.SubprocessError):
                        cleanup[action] = "unconfirmed"
                atomic(directory / "cleanup.json", {"terminal": terminal, **cleanup})


def native_result(mode, root, operation, directory):
    result = subprocess.run([sender(), mode, "--operation", operation, "--state-dir", str(root)], capture_output=True, text=True, timeout=90)
    if len(result.stdout) > 131072:
        raise Stop("sender_output_invalid")
    value = json.loads(result.stdout)
    if not isinstance(value, dict) or value.get("operation_id") != operation or value.get("outcome") not in EXIT:
        raise Stop("sender_output_invalid")
    if not (root / operation / "receipt.json").exists():
        return value
    return result_for(root, operation, directory, value)


def parser():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("mode", nargs="?", choices=("status", "cancel"))
    p.add_argument("--route")
    p.add_argument("--brief", type=Path)
    p.add_argument("--operation", required=True)
    p.add_argument("--send", action="store_true")
    p.add_argument("--mention-email")
    p.add_argument("--mention-query")
    p.add_argument("--portfolio", type=Path)
    p.add_argument("--task-id")
    p.add_argument("--routes-file", type=Path, default=Path(os.environ.get("XDG_CONFIG_HOME", str(Path.home() / ".config"))) / "chat-send/routes.json")
    p.add_argument("--state-dir", type=Path, default=Path(os.environ.get("XDG_STATE_HOME", str(Path.home() / ".local/state"))) / "chat-send")
    return p


def main():
    os.umask(0o077)
    args = parser().parse_args()
    try:
        result = execute(args)
    except (Stop, OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        result = {"outcome": error.outcome if isinstance(error, Stop) else "needs_attention", "reason": error.reason if isinstance(error, Stop) else "worker_runtime_or_storage_error", "operation_id": args.operation}
        if TOKEN.fullmatch(args.operation):
            directory = args.state_dir / ".workers" / args.operation
            if directory.exists():
                result["worker_job"] = str(directory)
                if (directory / "launch-error.json").exists():
                    result["diagnostics"] = str(directory / "launch-error.json")
    print(json.dumps(result, separators=(",", ":")))
    return EXIT[result["outcome"]]


if __name__ == "__main__":
    sys.exit(main())
