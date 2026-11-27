#!/usr/bin/env python3
"""Toggle a floating top-center drop-down window in Niri via JSON IPC."""

import argparse
import json
import os
import re
import socket
import subprocess
import sys


def resolve_socket() -> str:
    sock = os.environ.get("NIRI_SOCKET")
    if sock and os.path.exists(sock):
        return sock
    out = subprocess.check_output(
        ["systemctl", "--user", "show-environment"], text=True
    )
    for line in out.splitlines():
        if line.startswith("NIRI_SOCKET="):
            candidate = line.split("=", 1)[1]
            if candidate and os.path.exists(candidate):
                return candidate
    raise RuntimeError("NIRI_SOCKET is not set or does not exist")


def niri_request(sock_path: str, payload):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
        conn.connect(sock_path)
        conn.sendall((json.dumps(payload) + "\n").encode("utf-8"))
        conn.shutdown(socket.SHUT_WR)
        chunks = []
        while True:
            chunk = conn.recv(65536)
            if not chunk:
                break
            chunks.append(chunk)
    response = json.loads(b"".join(chunks).decode("utf-8"))
    if "Err" in response:
        raise RuntimeError(f"Niri IPC error for {payload!r}: {response['Err']}")
    return response["Ok"]


def matches_window(window: dict, app_id_re, title_re) -> bool:
    app_id = window.get("app_id") or ""
    title = window.get("title") or ""
    if app_id_re is not None and not app_id_re.search(app_id):
        return False
    if title_re is not None and not title_re.search(title):
        return False
    return True


def select_window(windows: list[dict], focused_ws_id: int | None) -> dict | None:
    if not windows:
        return None

    def sort_key(win: dict):
        ts = win.get("focus_timestamp") or {}
        return (
            1 if win.get("is_focused") else 0,
            1 if (focused_ws_id is not None and win.get("workspace_id") == focused_ws_id) else 0,
            ts.get("secs", 0),
            ts.get("nanos", 0),
            win.get("id", 0),
        )

    return max(windows, key=sort_key)


def plan_actions(
    *,
    windows: list[dict],
    workspaces: list[dict],
    app_id_pattern: str | None,
    title_pattern: str | None,
    command: list[str],
    scratch_workspace: str,
    width_pct: float,
    height_pct: float,
) -> list[dict]:
    app_id_re = re.compile(app_id_pattern) if app_id_pattern else None
    title_re = re.compile(title_pattern) if title_pattern else None

    focused_ws = next((w for w in workspaces if w.get("is_focused")), None)
    if focused_ws is None:
        focused_ws = next((w for w in workspaces if w.get("is_active")), None)
    focused_ws_id = focused_ws["id"] if focused_ws else None

    matched = [w for w in windows if matches_window(w, app_id_re, title_re)]
    target = select_window(matched, focused_ws_id)

    if target is None:
        return [{"Action": {"Spawn": {"command": command}}}]

    wid = target["id"]
    on_focused_ws = focused_ws_id is not None and target.get("workspace_id") == focused_ws_id

    if target.get("is_focused") and on_focused_ws:
        return [
            {
                "Action": {
                    "MoveWindowToWorkspace": {
                        "window_id": wid,
                        "reference": {"Name": scratch_workspace},
                        "focus": False,
                    }
                }
            }
        ]

    actions: list[dict] = []
    if focused_ws_id is not None and not on_focused_ws:
        actions.append(
            {
                "Action": {
                    "MoveWindowToWorkspace": {
                        "window_id": wid,
                        "reference": {"Id": focused_ws_id},
                        "focus": False,
                    }
                }
            }
        )

    if not target.get("is_floating"):
        actions.append({"Action": {"MoveWindowToFloating": {"id": wid}}})

    actions.append(
        {
            "Action": {
                "SetWindowWidth": {"id": wid, "change": {"SetProportion": width_pct}}
            }
        }
    )
    actions.append(
        {
            "Action": {
                "SetWindowHeight": {"id": wid, "change": {"SetProportion": height_pct}}
            }
        }
    )

    actions.append({"Action": {"CenterWindow": {"id": wid}}})

    actions.append({"Action": {"FocusWindow": {"id": wid}}})
    return actions


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Toggle a Niri drop-down window")
    parser.add_argument("--app-id", help="Regex matching window app_id")
    parser.add_argument("--title", help="Regex matching window title")
    parser.add_argument("--scratch-workspace", default="scratch")
    parser.add_argument("--width-pct", type=float, default=65.0)
    parser.add_argument("--height-pct", type=float, default=65.0)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)

    cmd = list(args.command)
    if cmd and cmd[0] == "--":
        cmd = cmd[1:]
    if not cmd:
        parser.error("missing command to spawn after --")
    if not args.app_id and not args.title:
        parser.error("at least one of --app-id or --title is required")

    sock_path = resolve_socket()
    workspaces = niri_request(sock_path, "Workspaces")["Workspaces"]
    windows = niri_request(sock_path, "Windows")["Windows"]

    actions = plan_actions(
        windows=windows,
        workspaces=workspaces,
        app_id_pattern=args.app_id,
        title_pattern=args.title,
        command=cmd,
        scratch_workspace=args.scratch_workspace,
        width_pct=args.width_pct,
        height_pct=args.height_pct,
    )
    for action in actions:
        niri_request(sock_path, action)
    return 0


if __name__ == "__main__":
    sys.exit(main())
