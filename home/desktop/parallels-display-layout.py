"""Place Niri or Hyprland virtual outputs using the Parallels host display layout."""

import argparse
import json
import math
import os
import queue
import re
import subprocess
import sys
import threading
from pathlib import Path


CONFIG = re.compile(r"Dynamic Resolution: new heads config .*heads_count=(\d+)")
HEAD = re.compile(
    r"Dynamic Resolution:\s+head ([012])\) width=\d+, height=\d+, x=(-?\d+), y=-?\d+"
)


class HeadLayout:
    def __init__(self):
        self.pending = False
        self.heads = {}
        self.latest = None

    def feed(self, line):
        config = CONFIG.search(line)
        if config:
            self.pending = int(config.group(1)) == 3
            self.heads = {}
            self.latest = None
            return None

        if not self.pending:
            return None
        head = HEAD.search(line)
        if not head:
            return None
        self.heads[int(head.group(1))] = int(head.group(2))
        if len(self.heads) != 3:
            return None

        self.pending = False
        center, second, third = (self.heads[index] for index in range(3))
        if second < center < third:
            self.latest = ("Virtual-2", "Virtual-3")
        elif third < center < second:
            self.latest = ("Virtual-3", "Virtual-2")
        return self.latest


def read_layout(log_path):
    layout = HeadLayout()
    try:
        with log_path.open(errors="replace") as log:
            for line in log:
                layout.feed(line)
    except FileNotFoundError:
        pass
    return layout


def desired_positions(layout, outputs):
    left, right = layout
    if any(
        name not in outputs or not outputs[name].get("logical")
        for name in (left, "Virtual-1", right)
    ):
        return None

    def occupied_width(name):
        output = outputs[name]
        mode = output["modes"][output["current_mode"]]
        # Niri reports fractional logical widths rounded down, but a
        # touching output needs to start after the full occupied width.
        return math.ceil(mode["width"] / output["logical"]["scale"])

    left_width = occupied_width(left)
    center_width = occupied_width("Virtual-1")
    return {left: 0, "Virtual-1": left_width, right: left_width + center_width}


def hyprland_desired_positions(layout, monitors):
    by_name = {monitor.get("name"): monitor for monitor in monitors if monitor.get("name")}
    left, right = layout
    if any(
        name not in by_name
        or not by_name[name].get("width")
        or not by_name[name].get("scale")
        for name in (left, "Virtual-1", right)
    ):
        return None

    def occupied_width(name):
        monitor = by_name[name]
        transform = monitor.get("transform", 0)
        pixel_width = monitor["height"] if transform % 2 == 1 else monitor["width"]
        # Hyprland 0.55.4 computes logical m_size via std::round(xfmd / scale).
        return math.floor(pixel_width / monitor["scale"] + 0.5)

    left_width = occupied_width(left)
    center_width = occupied_width("Virtual-1")
    return {left: 0, "Virtual-1": left_width, right: left_width + center_width}


def apply_niri_layout(layout, niri_bin, dry_run=False):
    try:
        result = subprocess.run(
            [niri_bin, "msg", "--json", "outputs"],
            check=True,
            capture_output=True,
            text=True,
            timeout=5,
        )
        outputs = json.loads(result.stdout)
        positions = desired_positions(layout, outputs)
        if positions is None:
            return False
        if dry_run:
            print(f"Parallels layout: {positions}", flush=True)
            return True
        if all(
            outputs[name]["logical"]["x"] == x and outputs[name]["logical"]["y"] == 0
            for name, x in positions.items()
        ):
            return True
        for name, x in positions.items():
            subprocess.run(
                [niri_bin, "msg", "output", name, "position", "set", str(x), "0"],
                check=True,
                capture_output=True,
                text=True,
                timeout=5,
            )
        print(f"Applied Parallels layout: {positions}", flush=True)
        return True
    except (json.JSONDecodeError, OSError, subprocess.SubprocessError) as error:
        print(f"Could not apply Parallels layout: {error}", file=sys.stderr, flush=True)
        return False


def apply_hyprland_layout(layout, hyprctl_bin, dry_run=False):
    try:
        result = subprocess.run(
            [hyprctl_bin, "-j", "monitors"],
            check=True,
            capture_output=True,
            text=True,
            timeout=5,
        )
        monitors = json.loads(result.stdout)
        positions = hyprland_desired_positions(layout, monitors)
        if positions is None:
            return False
        if dry_run:
            print(f"Parallels layout: {positions}", flush=True)
            return True
        by_name = {monitor["name"]: monitor for monitor in monitors if monitor.get("name")}
        if all(
            by_name[name].get("x") == x and by_name[name].get("y") == 0
            for name, x in positions.items()
        ):
            return True
        for name, x in positions.items():
            monitor = by_name[name]
            scale = monitor["scale"]
            transform = monitor.get("transform", 0)
            rule = f"{name},preferred,{x}x0,{scale:g}"
            if transform:
                rule = f"{rule},transform,{transform}"
            subprocess.run(
                [hyprctl_bin, "keyword", "monitor", rule],
                check=True,
                capture_output=True,
                text=True,
                timeout=5,
            )
        print(f"Applied Parallels layout: {positions}", flush=True)
        return True
    except (json.JSONDecodeError, OSError, subprocess.SubprocessError) as error:
        print(f"Could not apply Parallels layout: {error}", file=sys.stderr, flush=True)
        return False


def apply_layout(layout, niri_bin, dry_run=False, hyprctl_bin=None):
    if os.environ.get("HYPRLAND_INSTANCE_SIGNATURE"):
        return apply_hyprland_layout(
            layout, hyprctl_bin or os.environ.get("HYPRCTL_BIN", "hyprctl"), dry_run
        )
    if os.environ.get("NIRI_SOCKET"):
        return apply_niri_layout(layout, niri_bin, dry_run)
    desktop = os.environ.get("XDG_CURRENT_DESKTOP", "").lower()
    if "hyprland" in desktop:
        return apply_hyprland_layout(
            layout, hyprctl_bin or os.environ.get("HYPRCTL_BIN", "hyprctl"), dry_run
        )
    return apply_niri_layout(layout, niri_bin, dry_run)


def enqueue_lines(stream, events):
    for line in stream:
        if "new heads config" in line or "Dynamic Resolution:  head " in line:
            events.put(line)
    events.put(None)


def main():
    args = argparse.ArgumentParser(description=__doc__)
    args.add_argument("--log", type=Path, default=Path("/var/log/parallels.log"))
    args.add_argument("--once", action="store_true")
    args.add_argument("--dry-run", action="store_true")
    options = args.parse_args()

    niri_bin = os.environ.get("NIRI_BIN", "niri")
    hyprctl_bin = os.environ.get("HYPRCTL_BIN", "hyprctl")
    if options.once:
        layout = read_layout(options.log).latest
        return 0 if layout and apply_layout(layout, niri_bin, options.dry_run, hyprctl_bin) else 1

    events = queue.Queue()
    tail = subprocess.Popen(
        [os.environ.get("TAIL_BIN", "tail"), "-n", "0", "-F", str(options.log)],
        stdout=subprocess.PIPE,
        text=True,
        bufsize=1,
    )
    threading.Thread(
        target=enqueue_lines, args=(tail.stdout, events), daemon=True
    ).start()

    layout = read_layout(options.log)
    if layout.latest:
        apply_layout(layout.latest, niri_bin, hyprctl_bin=hyprctl_bin)
    while True:
        try:
            line = events.get(timeout=5)
        except queue.Empty:
            if layout.latest:
                apply_layout(layout.latest, niri_bin, hyprctl_bin=hyprctl_bin)
            continue
        if line is None:
            return 1
        if layout.feed(line):
            apply_layout(layout.latest, niri_bin, hyprctl_bin=hyprctl_bin)


if __name__ == "__main__":
    raise SystemExit(main())
