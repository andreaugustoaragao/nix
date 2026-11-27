#!/usr/bin/env python3
"""Focus or move columns to a numbered workspace slot on the focused Niri output."""

import argparse
import json
import os
import re
import socket
import subprocess
import sys

_NUMBERED_WS_RE = re.compile(r"^([pv]?)([1-9][0-9]*)$")


def resolve_socket() -> str:
    sock = os.environ.get("NIRI_SOCKET")
    if sock and os.path.exists(sock):
        return sock
    out = subprocess.check_output(
        ["systemctl", "--user", "show-environment"], text=True
    )
    for line in out.splitlines():
        if line.startswith("NIRI_SOCKET="):
            candidate = line.split("=", 1)[1].strip()
            if candidate and os.path.exists(candidate):
                return candidate
    raise RuntimeError("NIRI_SOCKET is not set or does not exist")


def niri_request(sock_path: str, payload):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
        conn.connect(sock_path)
        conn.sendall((json.dumps(payload) + "\n").encode("utf-8"))
        conn.shutdown(socket.SHUT_WR)
        raw = conn.makefile("r", encoding="utf-8").readline()
    if not raw:
        raise RuntimeError(f"Empty reply from niri for {payload!r}")
    response = json.loads(raw)
    if "Err" in response:
        raise RuntimeError(f"niri IPC error for {payload!r}: {response['Err']}")
    return response["Ok"]


def scratch_order_action(workspaces: list[dict], scratch_workspace: str) -> dict | None:
    scratch_ws = next((w for w in workspaces if w.get("name") == scratch_workspace), None)
    if scratch_ws is None:
        return None
    output = scratch_ws.get("output")
    scratch_idx = scratch_ws.get("idx")
    if not output or not isinstance(scratch_idx, int):
        return None
    max_numbered_idx = max(
        (
            w.get("idx", 0)
            for w in workspaces
            if w.get("output") == output
            and isinstance(w.get("idx"), int)
            and _NUMBERED_WS_RE.match(w.get("name") or "")
        ),
        default=0,
    )
    if max_numbered_idx > 0 and scratch_idx <= max_numbered_idx:
        return {
            "Action": {
                "MoveWorkspaceToIndex": {
                    "index": max_numbered_idx + 1,
                    "reference": {"Name": scratch_workspace},
                }
            }
        }
    return None


def resolve_slot_workspace(workspaces: list[dict], output: str | None, slot: int) -> dict | None:
    if not output:
        return None
    same_output = [w for w in workspaces if w.get("output") == output]
    candidates = {str(slot), f"p{slot}", f"v{slot}"}
    for w in same_output:
        if w.get("name") in candidates:
            return w
    return None


def plan_actions(
    *,
    workspaces: list[dict],
    mode: str,
    slot: int,
    scratch_workspace: str = "scratch",
) -> list[dict]:
    focused_ws = next((w for w in workspaces if w.get("is_focused")), None)
    if focused_ws is None:
        focused_ws = next((w for w in workspaces if w.get("is_active")), None)
    focused_output = focused_ws.get("output") if focused_ws else None

    actions: list[dict] = []
    repair = scratch_order_action(workspaces, scratch_workspace)
    if repair is not None:
        actions.append(repair)

    target_ws = resolve_slot_workspace(workspaces, focused_output, slot)
    ref = {"Id": target_ws["id"]} if target_ws is not None else {"Index": slot}

    if mode == "focus":
        actions.append({"Action": {"FocusWorkspace": {"reference": ref}}})
    elif mode == "move":
        actions.append(
            {"Action": {"MoveColumnToWorkspace": {"reference": ref, "focus": True}}}
        )
    else:
        raise ValueError(f"Unsupported mode: {mode}")

    return actions


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Focus or move the focused column to a named numbered Niri workspace slot"
    )
    parser.add_argument("mode", choices=["focus", "move"])
    parser.add_argument("slot", type=int)
    parser.add_argument("--scratch-workspace", default="scratch")
    args = parser.parse_args(argv)

    sock_path = resolve_socket()
    workspaces = niri_request(sock_path, "Workspaces")["Workspaces"]
    actions = plan_actions(
        workspaces=workspaces,
        mode=args.mode,
        slot=args.slot,
        scratch_workspace=args.scratch_workspace,
    )
    for action in actions:
        niri_request(sock_path, action)
    return 0


if __name__ == "__main__":
    sys.exit(main())
