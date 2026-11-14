#!/usr/bin/env python3
"""Deterministic activation / resume helper for chief-of-staff mode."""

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import uuid

SKILL_ROOT = Path(__file__).resolve().parent.parent
PORTFOLIO_TEMPLATE = SKILL_ROOT / "templates" / "portfolio.md"


def run_cmd(cmd, *, timeout=15):
    return subprocess.run(cmd, check=True, text=True, capture_output=True, timeout=timeout)


def run_json(cmd, *, timeout=15):
    return json.loads(run_cmd(cmd, timeout=timeout).stdout)


def state_root() -> Path:
    base = Path(os.environ.get("XDG_STATE_HOME") or (Path.home() / ".local" / "state"))
    return base / "chief-of-staff"


def conversation_id() -> str:
    for key in ("CODEX_THREAD_ID", "CODEX_CONVERSATION_ID", "PI_SESSION_ID", "OPENCODE_SESSION_ID"):
        val = (os.environ.get(key) or "").strip()
        if val:
            return f"{key}={val}"
    return "unavailable"


def slugify(text: str) -> str:
    s = re.sub(r"[^a-z0-9]+", "-", (text or "space").lower()).strip("-")
    return s[:40] or "space"


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


def terminal_addresses(term: dict):
    if addr := term.get("terminal"):
        yield addr
    for sub in term.get("sub_agents") or []:
        addr = sub if isinstance(sub, str) else sub.get("terminal")
        if addr:
            yield addr


def find_space_and_tab(app_ls: dict, addr: str):
    for space in app_ls.get("spaces") or []:
        for tab in space.get("tabs") or []:
            for term in tab.get("terminals") or []:
                if addr in terminal_addresses(term):
                    return space, tab
    return None, None


def local_space_id(space: dict | None) -> str:
    sid = (space or {}).get("id") or ""
    return sid.split("/")[-1] if sid else ""


def check_conflict(space: dict | None, my_tab: dict | None, my_addr: str, hc_terminals: list[dict]):
    if not space:
        return None
    my_tab_id = (my_tab or {}).get("id")
    space_addrs = set()
    for tab in space.get("tabs") or []:
        tab_terms = [addr for term in tab.get("terminals") or [] for addr in terminal_addresses(term)]
        space_addrs.update(tab_terms)
        if tab.get("name") == "chief-of-staff" and tab.get("id") != my_tab_id and any(a != my_addr for a in tab_terms):
            return {
                "reason": "existing_chief_of_staff_tab",
                "tab_id": tab.get("id"),
                "tab_name": tab.get("name"),
                "terminals": tab_terms,
            }

    lsid = local_space_id(space)
    for term in hc_terminals:
        if term.get("state") != "live":
            continue
        addr = term.get("address")
        if not addr or addr == my_addr:
            continue
        labels = term.get("labels") or {}
        in_space = addr in space_addrs or (lsid and labels.get("herdr.space") == lsid)
        if in_space and labels.get("herdr.role") == "chief-of-staff":
            return {
                "reason": "existing_chief_of_staff_terminal",
                "terminal": addr,
                "tab_id": labels.get("herdr.tab"),
            }
    return None


def find_existing_portfolio(root: Path, my_addr: str, space_id: str) -> Path | None:
    if not root.is_dir():
        return None
    candidates = sorted(root.glob("*/portfolio.md"), key=lambda p: p.stat().st_mtime, reverse=True)
    for pfile in candidates:
        try:
            text = pfile.read_text(encoding="utf-8")
        except OSError:
            continue
        if "- Mode: active" not in text:
            continue
        if f"- Coordinator terminal: {my_addr}" in text:
            return pfile
        if space_id and f"- Space ID: {space_id}" in text and f"- Coordinator terminal: {my_addr}" in text:
            return pfile
    return None


def build_portfolio_text(
    *,
    portfolio_id: str,
    conv_id: str,
    coord_addr: str,
    core_socket: str,
    space: dict | None,
    tab: dict | None,
    other_terms: list[dict],
) -> str:
    template = PORTFOLIO_TEMPLATE.read_text(encoding="utf-8")
    space_name = (space or {}).get("name") or "unknown"
    space_id = (space or {}).get("id") or "unknown"
    tab_id = (tab or {}).get("id") or "unknown"
    replacements = {
        "<unique ID>": portfolio_id,
        "<identifier, or unavailable>": conv_id,
        "<literal HC_TERMINAL_ID>": coord_addr,
        "<HC_TERMINAL_SOCKET>": core_socket,
        "<tab count, splits per tab or total, coordinator included, and host/session limit>": (
            f"space={space_name} ({space_id}); chief-of-staff tab={tab_id}; separate worker tabs (<= 4 splits/tab)"
        ),
        "<user choices and verified current availability>": "per routing.md (check requested harnesses/models on intake)",
        "<known allowance/reset/marginal charge per route, checked-at time, or unknown; separate from API cost>": "unknown",
        "<specific action or waiting for user input>": "Intake user request",
    }
    text = template
    for old, new in replacements.items():
        text = text.replace(old, new)

    # Inject Space ID metadata right after Owning core so resume matching is exact.
    text = text.replace(
        f"- Owning core: {core_socket}\n",
        f"- Owning core: {core_socket}\n- Space ID: {space_id} ({space_name})\n",
        1,
    )

    if other_terms:
        rows = "\n".join(
            f"| {t['address']} | {t.get('tab_name') or '-'} | pre-existing | observed | {t.get('app') or 'shell'} | {t.get('status') or 'live'} | {t.get('cwd') or ''} |"
            for t in other_terms
        )
        text = text.replace(
            "| Terminal ID / core | Tab / split | Task | Role | Harness / subscription / model / effort | Observed status | Worktree / resume ID |\n| --- | --- | --- | --- | --- | --- | --- |\n",
            "| Terminal ID / core | Tab / split | Task | Role | Harness / subscription / model / effort | Observed status | Worktree / resume ID |\n| --- | --- | --- | --- | --- | --- | --- |\n"
            + rows
            + "\n",
            1,
        )

    note = f"\n- Initialized chief-of-staff portfolio `{portfolio_id}` on coordinator `{coord_addr}` (space `{space_name}` / `{space_id}`, tab `chief-of-staff`).\n"
    text = text.rstrip() + "\n" + note
    return text


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--portfolio", type=Path, help="Explicit existing portfolio directory or portfolio.md to reuse")
    parser.add_argument("--force-new", action="store_true", help="Create a new portfolio even if an active one matches this coordinator")
    args = parser.parse_args()

    os.umask(0o077)
    my_addr = (os.environ.get("HC_TERMINAL_ID") or "").strip()
    core_socket = (os.environ.get("HC_TERMINAL_SOCKET") or "").strip()
    if not my_addr or not core_socket:
        print(json.dumps({
            "status": "error",
            "error": "missing_host_context",
            "message": "HC_TERMINAL_ID and HC_TERMINAL_SOCKET are required to initialize chief-of-staff.",
        }))
        return 2

    try:
        app_ls = run_json(["herdr-app", "ls"])
        hc_ls = run_json(["hc", "ls", "--json"])
        my_info = run_json(["hc", "get", my_addr])
        templates = run_json(["hc", "templates"]).get("templates") or []
    except (subprocess.SubprocessError, json.JSONDecodeError) as exc:
        print(json.dumps({
            "status": "error",
            "error": "host_query_failed",
            "message": str(exc),
        }))
        return 1

    hc_terminals = hc_ls.get("terminals") or []
    hc_by_addr = {t.get("address"): t for t in hc_terminals if t.get("address")}
    space, tab = find_space_and_tab(app_ls, my_addr)

    conflict = check_conflict(space, tab, my_addr, hc_terminals)
    if conflict:
        print(json.dumps({
            "status": "conflict",
            "space": {"id": (space or {}).get("id"), "name": (space or {}).get("name")},
            "conflict": conflict,
            "message": "This space already has an active chief-of-staff coordinator; direct the user there instead of starting a second one.",
        }))
        return 3

    # Claim coordinator role on terminal and rename tab to chief-of-staff.
    try:
        run_cmd(["hc", "label", my_addr, "herdr.role=chief-of-staff", "herdr.name=chief-of-staff"])
        if tab and tab.get("id") and tab.get("name") != "chief-of-staff":
            run_cmd(["herdr-app", "do", "tab.rename", "--id", tab["id"], "--name", "chief-of-staff"])
            tab["name"] = "chief-of-staff"
    except subprocess.SubprocessError as exc:
        print(json.dumps({
            "status": "error",
            "error": "claim_failed",
            "message": str(exc),
        }))
        return 1

    lsid = local_space_id(space)
    other_terms = []
    if space:
        for t in space.get("tabs") or []:
            for term in t.get("terminals") or []:
                addr = term.get("terminal")
                if not addr or addr == my_addr:
                    continue
                hc_rec = hc_by_addr.get(addr) or {}
                other_terms.append({
                    "address": addr,
                    "tab_id": t.get("id"),
                    "tab_name": t.get("name"),
                    "app": term.get("app") or (hc_rec.get("status") or {}).get("app"),
                    "status": term.get("status") or (hc_rec.get("status") or {}).get("state"),
                    "cwd": (hc_rec.get("foreground") or {}).get("cwd") or hc_rec.get("cwd"),
                })

    root = state_root()
    root.mkdir(parents=True, exist_ok=True)
    os.chmod(root, 0o700)

    reused = False
    portfolio_file: Path | None = None
    if args.portfolio:
        p = args.portfolio
        portfolio_file = p / "portfolio.md" if p.is_dir() else p
        if not portfolio_file.is_file():
            print(json.dumps({
                "status": "error",
                "error": "portfolio_not_found",
                "message": f"Portfolio not found: {portfolio_file}",
            }))
            return 1
        reused = True
    elif not args.force_new:
        portfolio_file = find_existing_portfolio(root, my_addr, (space or {}).get("id") or "")
        reused = portfolio_file is not None

    if portfolio_file is None:
        base_name = (space or {}).get("name") or Path(my_info.get("cwd") or "workspace").name
        portfolio_id = f"{slugify(base_name)}-{uuid.uuid4().hex[:8]}"
        portfolio_dir = root / portfolio_id
        portfolio_dir.mkdir(parents=True, exist_ok=True)
        os.chmod(portfolio_dir, 0o700)
        tasks_dir = portfolio_dir / "tasks"
        tasks_dir.mkdir(parents=True, exist_ok=True)
        os.chmod(tasks_dir, 0o700)
        portfolio_file = portfolio_dir / "portfolio.md"
        text = build_portfolio_text(
            portfolio_id=portfolio_id,
            conv_id=conversation_id(),
            coord_addr=my_addr,
            core_socket=core_socket,
            space=space,
            tab=tab,
            other_terms=other_terms,
        )
        atomic_write(portfolio_file, text, mode=0o600)
    else:
        portfolio_dir = portfolio_file.parent
        portfolio_id = portfolio_dir.name
        tasks_dir = portfolio_dir / "tasks"
        tasks_dir.mkdir(parents=True, exist_ok=True)

    harnesses = {
        name: shutil.which(name) is not None
        for name in ("codex", "pi", "opencode", "herdr-cursor", "cursor-agent")
    }

    print(json.dumps({
        "status": "ok",
        "reused": reused,
        "portfolio_id": portfolio_id,
        "portfolio_dir": str(portfolio_dir),
        "portfolio_path": str(portfolio_file),
        "tasks_dir": str(tasks_dir),
        "coordinator": my_addr,
        "owning_core": core_socket,
        "conversation_id": conversation_id(),
        "space": {
            "id": (space or {}).get("id"),
            "local_id": lsid,
            "name": (space or {}).get("name"),
            "folder": (space or {}).get("folder") or my_info.get("cwd"),
        },
        "tab": {
            "id": (tab or {}).get("id"),
            "name": (tab or {}).get("name") or "chief-of-staff",
        },
        "other_live_terminals": other_terms,
        "templates": templates,
        "harnesses": harnesses,
    }))
    return 0


if __name__ == "__main__":
    sys.exit(main())
