#!/usr/bin/env python3
"""Toggle a top-center drop-down special workspace in Hyprland, adopting existing windows."""

import argparse
import json
import re
import subprocess
import sys


def hyprctl_json(cmd: str):
    out = subprocess.check_output(["hyprctl", "-j", cmd], text=True)
    return json.loads(out)


def matches_client(client: dict, class_re, title_re) -> bool:
    cls = client.get("class") or ""
    title = client.get("title") or ""
    if class_re is not None and not class_re.search(cls):
        return False
    if title_re is not None and not title_re.search(title):
        return False
    return True


def select_client(clients: list[dict], special_ws_name: str) -> dict | None:
    if not clients:
        return None

    def sort_key(client: dict):
        in_special = (client.get("workspace") or {}).get("name") == special_ws_name
        # Lower focusHistoryID means more recently focused in Hyprland.
        focus_id = client.get("focusHistoryID", 10**9)
        return (1 if in_special else 0, -focus_id)

    return max(clients, key=sort_key)


def monitor_geometry(monitors: list[dict]) -> tuple[int, int, int, int] | None:
    mon = next((m for m in monitors if m.get("focused")), None)
    if mon is None and monitors:
        mon = monitors[0]
    if mon is None:
        return None
    mon_x = int(mon.get("x") or 0)
    mon_y = int(mon.get("y") or 0)
    scale = float(mon.get("scale") or 1.0)
    w = float(mon.get("width") or 0) / scale
    h = float(mon.get("height") or 0) / scale
    transform = int(mon.get("transform") or 0)
    if transform in (1, 3, 5, 7):
        w, h = h, w
    return mon_x, mon_y, round(w), round(h)


def plan_dispatches(
    *,
    clients: list[dict],
    monitors: list[dict],
    special_name: str,
    class_pattern: str | None,
    title_pattern: str | None,
    width_pct: float,
    height_pct: float,
) -> list[str]:
    special_ws_name = f"special:{special_name}"
    focused_mon = next((m for m in monitors if m.get("focused")), None)
    active_special = (
        (focused_mon.get("specialWorkspace") or {}).get("name") if focused_mon else ""
    )

    if active_special == special_ws_name:
        return [f"dispatch togglespecialworkspace {special_name}"]

    class_re = re.compile(class_pattern) if class_pattern else None
    title_re = re.compile(title_pattern) if title_pattern else None
    matched = [c for c in clients if matches_client(c, class_re, title_re)]
    target = select_client(matched, special_ws_name)

    if target is None:
        return [f"dispatch togglespecialworkspace {special_name}"]

    addr = target["address"]
    cmds: list[str] = []
    if not target.get("floating"):
        cmds.append(f"dispatch setfloating address:{addr}")
    if (target.get("workspace") or {}).get("name") != special_ws_name:
        cmds.append(f"dispatch movetoworkspacesilent {special_ws_name},address:{addr}")

    cmds.append(f"dispatch togglespecialworkspace {special_name}")
    cmds.append(f"dispatch focuswindow address:{addr}")

    geom = monitor_geometry(monitors)
    if geom and geom[2] > 0 and geom[3] > 0:
        mon_x, mon_y, mon_w, mon_h = geom
        win_w = round(mon_w * (width_pct / 100.0))
        win_h = round(mon_h * (height_pct / 100.0))
        x_pos = mon_x + max(0, round((mon_w - win_w) / 2))
        y_pos = mon_y + max(0, round((mon_h - win_h) / 2))
        cmds.append(f"dispatch resizewindowpixel exact {win_w} {win_h},address:{addr}")
        cmds.append(f"dispatch movewindowpixel exact {x_pos} {y_pos},address:{addr}")

    return cmds


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Toggle a Hyprland drop-down special workspace")
    parser.add_argument("--special", required=True, help="Special workspace name (without special:)")
    parser.add_argument("--class", dest="class_pattern", help="Regex matching client class")
    parser.add_argument("--title", dest="title_pattern", help="Regex matching client title")
    parser.add_argument("--width-pct", type=float, default=65.0)
    parser.add_argument("--height-pct", type=float, default=65.0)
    args = parser.parse_args(argv)

    if not args.class_pattern and not args.title_pattern:
        parser.error("at least one of --class or --title is required")

    clients = hyprctl_json("clients")
    monitors = hyprctl_json("monitors")
    dispatches = plan_dispatches(
        clients=clients,
        monitors=monitors,
        special_name=args.special,
        class_pattern=args.class_pattern,
        title_pattern=args.title_pattern,
        width_pct=args.width_pct,
        height_pct=args.height_pct,
    )
    if dispatches:
        subprocess.run(["hyprctl", "--batch", "; ".join(dispatches)], check=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
