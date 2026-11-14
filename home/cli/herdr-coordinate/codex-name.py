#!/usr/bin/env python3
"""Name an idle, fresh Codex worker before its first model prompt."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time


def hc(*arguments):
    result = subprocess.run(["hc", *arguments], check=True, text=True, capture_output=True, timeout=70)
    return json.loads(result.stdout)


def saved_name(index, offset, name):
    try:
        with index.open("rb") as stream:
            stream.seek(offset)
            contents = stream.read()
    except FileNotFoundError:
        return None
    for line in contents.split(b"\n")[:-1]:
        entry = json.loads(line)
        if entry.get("thread_name") == name:
            return entry["id"]
    return None


def name_worker(terminal, name, home, timeout):
    if not name.strip() or any(ord(c) < 32 or ord(c) == 127 for c in name):
        raise ValueError("Use a nonempty, single-line task name without control characters")
    state = hc("get", terminal)
    address = state["address"]
    if not re.fullmatch(r"t[0-9a-z]+", address):
        raise ValueError("Run this helper on the worker host; remote session indexes are not local")
    if state["state"] != "live" or (state.get("status") or {}).get("state") != "idle":
        raise ValueError(f"{address} must be an idle Codex worker before naming; inspect with hc read")
    # The terminal suffix disambiguates concurrent task names in the shared index.
    title = f"{name.strip()} [{address}]"
    index = home / "session_index.jsonl"
    offset = index.stat().st_size if index.exists() else 0
    hc("send", "--if", "idle", address, "/rename " + title)
    deadline = time.monotonic() + timeout
    while True:
        thread = saved_name(index, offset, title)
        if thread:
            return {"address": address, "named": True, "thread_id": thread, "thread_name": title}
        if time.monotonic() >= deadline:
            raise TimeoutError(f"Name not confirmed for {address}; inspect with hc read. No assignment was sent")
        state = hc("get", address)
        if state["state"] != "live" or (state.get("status") or {}).get("state") in ["blocked", "error", "working"]:
            raise RuntimeError(f"{address} stopped being idle before its name was confirmed; inspect with hc read")
        hc("wait", address, "--output", title, "--timeout", "1")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("terminal", help="New, idle Codex worker's Herdr terminal")
    parser.add_argument("name", help="Task and role, for example t001-review")
    parser.add_argument("--codex-home", type=Path, default=Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex"))))
    parser.add_argument("--timeout", type=float, default=30)
    args = parser.parse_args()
    if not os.environ.get("HC_TERMINAL_ID"):
        parser.error("Run from the coordinating herdr-core terminal")
    if args.timeout <= 0:
        parser.error("--timeout must be positive")
    try:
        print(json.dumps(name_worker(args.terminal, args.name, args.codex_home, args.timeout)))
    except (ValueError, OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
