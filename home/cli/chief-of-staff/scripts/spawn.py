#!/usr/bin/env python3
"""Deterministic worker launch + task-record helper for chief-of-staff."""

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time

SKILL_ROOT = Path(__file__).resolve().parent.parent
TASK_TEMPLATE = SKILL_ROOT / "templates" / "task.md"
MAX_SPLITS_PER_TAB = 4


def run_cmd(cmd, *, timeout=40):
    return subprocess.run(cmd, check=True, text=True, capture_output=True, timeout=timeout)


def run_json(cmd, *, timeout=40):
    return json.loads(run_cmd(cmd, timeout=timeout).stdout)


def atomic_write(path: Path, text: str, mode: int = 0o600):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=str(path.parent))
    try:
        os.chmod(fd, mode)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(text)
        os.replace(tmp_name, path)
    except Exception:
        try:
            os.unlink(tmp_name)
        except OSError:
            pass
        raise


def find_space_and_my_tab(app_ls: dict, addr: str):
    for space in app_ls.get("spaces") or []:
        for tab in space.get("tabs") or []:
            for term in tab.get("terminals") or []:
                if term.get("terminal") == addr:
                    return space, tab
    return None, None


def next_task_id(tasks_dir: Path) -> str:
    max_id = 0
    if tasks_dir.is_dir():
        for p in tasks_dir.glob("T*.md"):
            m = re.fullmatch(r"T(\d+)", p.stem)
            if m:
                max_id = max(max_id, int(m.group(1)))
    return f"T{max_id + 1:03d}"


def choose_worker_tab(space: dict | None, chief_tab_id: str | None, requested_tab_id: str | None, tab_name: str | None):
    if not space:
        return None
    tabs = space.get("tabs") or []
    worker_tabs = [t for t in tabs if t.get("id") != chief_tab_id and t.get("name") != "chief-of-staff"]
    if requested_tab_id:
        match = next((t for t in worker_tabs if t.get("id") == requested_tab_id), None)
        if not match:
            raise ValueError(f"Requested tab {requested_tab_id} is not a worker tab in this space")
        if len(match.get("terminals") or []) >= MAX_SPLITS_PER_TAB:
            raise ValueError(f"Requested tab {requested_tab_id} already has {MAX_SPLITS_PER_TAB} panes")
        return match
    if tab_name:
        for t in worker_tabs:
            if t.get("name") == tab_name and len(t.get("terminals") or []) < MAX_SPLITS_PER_TAB:
                return t
        return None
    for t in reversed(worker_tabs):
        if len(t.get("terminals") or []) < MAX_SPLITS_PER_TAB:
            return t
    return None


def wait_for_terminal_tab(addr: str, space_id: str, timeout: float = 3.0):
    deadline = time.monotonic() + timeout
    while True:
        app_ls = run_json(["herdr-app", "ls"])
        for space in app_ls.get("spaces") or []:
            if space_id and space.get("id") != space_id:
                continue
            for tab in space.get("tabs") or []:
                for term in tab.get("terminals") or []:
                    if term.get("terminal") == addr:
                        return tab
        if time.monotonic() >= deadline:
            return None
        time.sleep(0.15)


def ensure_task_file(
    tasks_dir: Path,
    *,
    task_id: str,
    goal: str,
    request_text: str,
    cwd: str,
    scope: str,
    deliverable: str,
    checks: str,
    worker_line: str,
) -> Path:
    task_path = tasks_dir / f"{task_id}.md"
    if not task_path.is_file():
        text = TASK_TEMPLATE.read_text(encoding="utf-8")
        replacements = {
            "<task ID>: <goal>": f"{task_id}: {goal}",
            "State: queued": "State: active",
            "<stage or not applicable>": "not applicable",
            "<literal request and identifier if available>": request_text or goal,
            "<task IDs or none>": "none",
            "<absolute path>": cwd,
            "<coordinator-owned checkout/branch, or not applicable>": cwd,
            "<paths and boundaries>": scope or cwd,
            "<concrete outcome>": deliverable or goal,
            "<required evidence>": checks or "targeted verification",
            "<specific action>": "Await worker completion and review findings",
        }
        for old, new in replacements.items():
            text = text.replace(old, new)
    else:
        text = task_path.read_text(encoding="utf-8")
    text = text.rstrip() + f"\n\n- Dispatched: {worker_line}\n"
    atomic_write(task_path, text, mode=0o600)
    return task_path


def append_portfolio_rows(portfolio_file: Path, *, task_row: str, worker_row: str, decision_line: str):
    if not portfolio_file.is_file():
        return
    text = portfolio_file.read_text(encoding="utf-8")
    if task_row and f"| {task_row.split('|')[1].strip()} |" not in text:
        text = re.sub(r"\n+(?=## Live worker inventory)", f"\n{task_row}\n\n", text, count=1)
    if worker_row:
        text = re.sub(r"\n+(?=## Other owned resources)", f"\n{worker_row}\n\n", text, count=1)
    text = text.rstrip() + f"\n- {decision_line}\n"
    atomic_write(portfolio_file, text, mode=0o600)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--portfolio", type=Path, required=True, help="Portfolio dir or portfolio.md")
    parser.add_argument("--task-id", help="Task ID (e.g. T001); auto-allocated when omitted")
    parser.add_argument("--goal", required=True, help="Short task goal")
    parser.add_argument("--request", default="", help="Original user request")
    parser.add_argument("--role", default="impl", help="Worker role (impl, review, check, etc.)")
    parser.add_argument("--name", required=True, help="Kebab-case terminal name (e.g. t001-impl)")
    parser.add_argument("--cwd", required=True, help="Absolute working directory")
    parser.add_argument("--tab-id", help="Explicit worker tab ID (< 4 splits)")
    parser.add_argument("--tab-name", help="Worker tab name if creating or matching a tab")
    parser.add_argument("--harness", default="auto", choices=["auto", "codex", "pi", "opencode", "cursor", "shell"])
    parser.add_argument("--model", default="unspecified", help="Recorded model/effort for portfolio tracking")
    parser.add_argument("--scope", default="", help="Allowed paths / scope")
    parser.add_argument("--deliverable", default="", help="Expected deliverable")
    parser.add_argument("--checks", default="", help="Required verification")
    parser.add_argument("--no-codex-name", action="store_true", help="Skip automatic herdr-codex-name")
    parser.add_argument("command", nargs=argparse.REMAINDER, help="Command to run (after --)")
    args = parser.parse_args()

    os.umask(0o077)
    coord = (os.environ.get("HC_TERMINAL_ID") or "").strip()
    if not coord:
        print(json.dumps({"status": "error", "error": "missing_host_context", "message": "HC_TERMINAL_ID is required"}))
        return 2

    cmd = list(args.command)
    if cmd and cmd[0] == "--":
        cmd = cmd[1:]
    if not cmd:
        print(json.dumps({"status": "error", "error": "missing_command", "message": "Provide the worker command after --"}))
        return 2

    portfolio_dir = args.portfolio if args.portfolio.is_dir() else args.portfolio.parent
    portfolio_file = portfolio_dir / "portfolio.md"
    tasks_dir = portfolio_dir / "tasks"
    tasks_dir.mkdir(parents=True, exist_ok=True)
    task_id = args.task_id or next_task_id(tasks_dir)

    try:
        app_ls = run_json(["herdr-app", "ls"])
        space, chief_tab = find_space_and_my_tab(app_ls, coord)
        space_id = (space or {}).get("id") or ""
        local_space_id = space_id.split("/")[-1] if space_id else ""
        target_tab = choose_worker_tab(space, (chief_tab or {}).get("id"), args.tab_id, args.tab_name)
    except (ValueError, subprocess.SubprocessError, json.JSONDecodeError) as exc:
        print(json.dumps({"status": "error", "error": "tab_resolution_failed", "message": str(exc)}))
        return 1

    hc_cmd = [
        "hc", "run", "--bg", "--json",
        "--name", args.name,
        "--cwd", args.cwd,
        "--label", f"herdr.name={args.name}",
        "--label", f"herdr.task={task_id}",
        "--label", f"herdr.role={args.role}",
    ]
    if local_space_id:
        hc_cmd.extend(["--label", f"herdr.space={local_space_id}"])
    if target_tab and target_tab.get("id"):
        local_tab_id = target_tab["id"].split("/")[-1]
        hc_cmd.extend(["--label", f"herdr.tab={local_tab_id}"])
    hc_cmd.append("--")
    hc_cmd.extend(cmd)

    try:
        launch = run_json(hc_cmd, timeout=30)
    except (subprocess.SubprocessError, json.JSONDecodeError) as exc:
        print(json.dumps({"status": "error", "error": "launch_failed", "message": str(exc)}))
        return 1

    addr = launch.get("address")
    if not addr:
        print(json.dumps({"status": "error", "error": "missing_address", "launch": launch}))
        return 1

    tab_name = args.tab_name or f"{task_id} · {args.goal[:32]}".strip()
    placed_tab = target_tab
    if placed_tab is None and space_id:
        placed_tab = wait_for_terminal_tab(addr, space_id)
        if placed_tab and placed_tab.get("id") and placed_tab.get("name") != tab_name:
            try:
                run_cmd(["herdr-app", "do", "tab.rename", "--id", placed_tab["id"], "--name", tab_name])
                placed_tab["name"] = tab_name
            except subprocess.SubprocessError:
                pass

    harness = args.harness
    if harness == "auto":
        prog = Path(cmd[0]).name
        if "codex" in prog:
            harness = "codex"
        elif "cursor" in prog:
            harness = "cursor"
        elif prog == "pi":
            harness = "pi"
        elif "opencode" in prog:
            harness = "opencode"
        else:
            harness = "shell"

    codex_meta = None
    if harness == "codex" and not args.no_codex_name:
        try:
            run_cmd(["hc", "wait", addr, "--timeout", "30"], timeout=35)
            codex_meta = run_json(["herdr-codex-name", addr, args.name], timeout=35)
        except (subprocess.SubprocessError, json.JSONDecodeError) as exc:
            print(json.dumps({
                "status": "error",
                "error": "codex_name_failed",
                "address": addr,
                "task_id": task_id,
                "message": str(exc),
            }))
            return 1

    tab_label = (placed_tab or {}).get("name") or tab_name
    worker_line = f"`{addr}` ({args.name}, {harness}, tab `{tab_label}`, cwd `{args.cwd}`)"
    task_path = ensure_task_file(
        tasks_dir,
        task_id=task_id,
        goal=args.goal,
        request_text=args.request,
        cwd=args.cwd,
        scope=args.scope,
        deliverable=args.deliverable,
        checks=args.checks,
        worker_line=worker_line,
    )
    resume_id = (codex_meta or {}).get("thread_id") or "-"
    task_row = f"| {task_id} | {args.goal} ({args.cwd}) | active | FIFO | - | `tasks/{task_id}.md` | Await `{addr}` |"
    worker_row = f"| {addr} | {tab_label} / {args.name} | {task_id} | {args.role} | {harness} ({args.model}) | launched | {args.cwd} (`{resume_id}`) |"
    append_portfolio_rows(
        portfolio_file,
        task_row=task_row,
        worker_row=worker_row,
        decision_line=f"Launched `{addr}` (`{args.name}`) for `{task_id}` on worker tab `{tab_label}`.",
    )

    print(json.dumps({
        "status": "ok",
        "task_id": task_id,
        "task_path": str(task_path),
        "address": addr,
        "name": args.name,
        "harness": harness,
        "tab": {"id": (placed_tab or {}).get("id"), "name": tab_label},
        "codex": codex_meta,
        "launch": launch,
    }))
    return 0


if __name__ == "__main__":
    sys.exit(main())
