"""Place Niri's virtual outputs using the layout reported by Parallels Tools."""

import argparse
import json
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
    left_width = outputs[left]["logical"]["width"]
    center_width = outputs["Virtual-1"]["logical"]["width"]
    return {left: 0, "Virtual-1": left_width, right: left_width + center_width}


def apply_layout(layout, niri_bin, dry_run=False):
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
    if options.once:
        layout = read_layout(options.log).latest
        return 0 if layout and apply_layout(layout, niri_bin, options.dry_run) else 1

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
        apply_layout(layout.latest, niri_bin)
    while True:
        try:
            line = events.get(timeout=5)
        except queue.Empty:
            if layout.latest:
                apply_layout(layout.latest, niri_bin)
            continue
        if line is None:
            return 1
        if layout.feed(line):
            apply_layout(layout.latest, niri_bin)


if __name__ == "__main__":
    raise SystemExit(main())
