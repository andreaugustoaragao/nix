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
import time
from pathlib import Path


CONFIG = re.compile(r"Dynamic Resolution: new heads config .*heads_count=(\d+)")
HEAD = re.compile(
    r"Dynamic Resolution:\s+head ([012])\) width=\d+, height=\d+, x=(-?\d+), y=-?\d+"
)
DRM_MODE = re.compile(r"^(\d+)x(\d+)$")
AVAILABLE_MODE = re.compile(r"^(\d+)x(\d+)@(\d+(?:\.\d+)?)Hz$")
DRM_ROOT = Path("/sys/class/drm")
DRM_EVENT = object()
MODE_SETTLE_ATTEMPTS = 6
MODE_SETTLE_INTERVAL = 0.15
VIRTUAL1_SMALL_MAX_WIDTH = 2560
VIRTUAL1_SMALL_SCALE = 1.25
VIRTUAL1_LARGE_SCALE = 1.5


def target_scale_for_width(
    width,
    threshold=VIRTUAL1_SMALL_MAX_WIDTH,
    small_scale=VIRTUAL1_SMALL_SCALE,
    large_scale=VIRTUAL1_LARGE_SCALE,
    docked=False,
):
    if docked:
        return large_scale
    return small_scale if width <= threshold else large_scale


def desired_scale(outputs, output_name="Virtual-1"):
    output = outputs.get(output_name)
    if not output or not output.get("logical"):
        return None
    docked = any(
        (outputs.get(name) or {}).get("logical") for name in ("Virtual-2", "Virtual-3")
    )
    if docked:
        return VIRTUAL1_LARGE_SCALE
    current_mode = output.get("current_mode")
    modes = output.get("modes") or []
    if current_mode is None or not (0 <= current_mode < len(modes)):
        return None
    width = modes[current_mode].get("width")
    if not width:
        return None
    return target_scale_for_width(width)


def read_drm_preferred_modes(drm_root=DRM_ROOT):
    modes = {}
    if drm_root is None:
        return modes
    try:
        connectors = sorted(drm_root.glob("card*-Virtual-*"))
    except OSError:
        return modes
    for connector in connectors:
        try:
            if (connector / "status").read_text().strip() != "connected":
                continue
            lines = (connector / "modes").read_text().splitlines()
        except OSError:
            continue
        first_mode = next((line.strip() for line in lines if line.strip()), "")
        match = DRM_MODE.match(first_mode)
        if not match or "-" not in connector.name:
            continue
        output_name = connector.name.split("-", 1)[1]
        modes[output_name] = (int(match.group(1)), int(match.group(2)))
    return modes


def hyprland_mode_spec(monitor, target_size=None):
    if target_size is None:
        width = monitor.get("width")
        height = monitor.get("height")
        if not width or not height:
            return "preferred"
        target_size = (width, height)

    width, height = target_size
    matches = []
    for entry in monitor.get("availableModes") or []:
        match = AVAILABLE_MODE.match(entry)
        if not match:
            continue
        if int(match.group(1)) == width and int(match.group(2)) == height:
            matches.append((float(match.group(3)), match.group(3)))

    if matches:
        under_60 = [item for item in matches if item[0] <= 60.05]
        chosen = max(under_60, key=lambda item: item[0]) if under_60 else min(matches, key=lambda item: item[0])
        return f"{width}x{height}@{chosen[1]}"

    if (
        monitor.get("width") == width
        and monitor.get("height") == height
        and monitor.get("refreshRate")
    ):
        return f"{width}x{height}@{monitor['refreshRate']:.2f}"
    return f"{width}x{height}@60"


def hyprland_desired_scale(monitors, output_name="Virtual-1", drm_modes=None):
    by_name = {monitor.get("name"): monitor for monitor in monitors if monitor.get("name")}
    monitor = by_name.get(output_name)
    if not monitor or not monitor.get("width"):
        return None
    docked = any(
        by_name.get(name, {}).get("width") for name in ("Virtual-2", "Virtual-3")
    )
    if docked:
        return VIRTUAL1_LARGE_SCALE
    transform = monitor.get("transform", 0)
    if drm_modes and output_name in drm_modes:
        width, height = drm_modes[output_name]
    else:
        width, height = monitor["width"], monitor["height"]
    pixel_width = height if transform % 2 == 1 else width
    return target_scale_for_width(pixel_width)



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
        def read_outputs():
            result = subprocess.run(
                [niri_bin, "msg", "--json", "outputs"],
                check=True,
                capture_output=True,
                text=True,
                timeout=5,
            )
            return json.loads(result.stdout)

        outputs = read_outputs()
        scale_target = desired_scale(outputs)
        if scale_target is not None:
            current_scale = outputs["Virtual-1"]["logical"]["scale"]
            if not math.isclose(current_scale, scale_target, abs_tol=1e-3):
                if dry_run:
                    print(f"Parallels scale: Virtual-1 -> {scale_target:g}", flush=True)
                else:
                    subprocess.run(
                        [niri_bin, "msg", "output", "Virtual-1", "scale", f"{scale_target:g}"],
                        check=True,
                        capture_output=True,
                        text=True,
                        timeout=5,
                    )
                    print(f"Applied Parallels scale: Virtual-1 -> {scale_target:g}", flush=True)
                    outputs = read_outputs()

        if layout is None:
            return True
        positions = desired_positions(layout, outputs)
        if positions is None:
            return True
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

def is_hyprland_session():
    if os.environ.get("HYPRLAND_INSTANCE_SIGNATURE"):
        return True
    if os.environ.get("NIRI_SOCKET"):
        return False
    return "hyprland" in os.environ.get("XDG_CURRENT_DESKTOP", "").lower()


def apply_hyprland_layout(
    layout,
    hyprctl_bin,
    dry_run=False,
    drm_root=DRM_ROOT,
    rejected_modes=None,
    settle_attempts=MODE_SETTLE_ATTEMPTS,
    settle_interval=MODE_SETTLE_INTERVAL,
):
    try:
        def read_monitors():
            result = subprocess.run(
                [hyprctl_bin, "-j", "monitors"],
                check=True,
                capture_output=True,
                text=True,
                timeout=5,
            )
            return json.loads(result.stdout)

        monitors = read_monitors()
        drm_modes = read_drm_preferred_modes(drm_root)
        if rejected_modes is not None:
            for name in list(rejected_modes):
                if drm_modes.get(name) != rejected_modes[name]:
                    del rejected_modes[name]
        active_drm_modes = {
            name: size
            for name, size in drm_modes.items()
            if rejected_modes is None or rejected_modes.get(name) != size
        }

        scale_target = hyprland_desired_scale(monitors, drm_modes=active_drm_modes)
        by_name = {monitor["name"]: monitor for monitor in monitors if monitor.get("name")}
        applied_modes = {}
        changed = False
        for monitor in monitors:
            name = monitor.get("name")
            if not name:
                continue
            target_size = active_drm_modes.get(name)
            needs_mode = (
                target_size is not None
                and (monitor.get("width"), monitor.get("height")) != target_size
            )
            current_scale = monitor.get("scale", 1.0)
            desired_scale_val = (
                scale_target
                if name == "Virtual-1" and scale_target is not None
                else current_scale
            )
            needs_scale = (
                name == "Virtual-1"
                and scale_target is not None
                and not math.isclose(current_scale, desired_scale_val, abs_tol=1e-3)
            )
            if not (needs_mode or needs_scale):
                continue

            mode = hyprland_mode_spec(monitor, target_size)
            x = monitor.get("x", 0)
            y = monitor.get("y", 0)
            transform = monitor.get("transform", 0)
            rule = f"{name},{mode},{x}x{y},{desired_scale_val:g}"
            if transform:
                rule = f"{rule},transform,{transform}"
            if dry_run:
                print(f"Parallels display: {rule}", flush=True)
                continue
            subprocess.run(
                [hyprctl_bin, "keyword", "monitor", rule],
                check=True,
                capture_output=True,
                text=True,
                timeout=5,
            )
            changed = True
            if needs_mode:
                applied_modes[name] = target_size
            print(f"Applied Parallels display: {rule}", flush=True)

        had_rejection = False
        if changed:
            attempts = max(1, settle_attempts) if applied_modes else 1
            for attempt in range(attempts):
                if attempt > 0 and settle_interval > 0:
                    time.sleep(settle_interval)
                monitors = read_monitors()
                by_name = {m["name"]: m for m in monitors if m.get("name")}
                if all(
                    (by_name.get(name, {}).get("width"), by_name.get(name, {}).get("height"))
                    == target_size
                    for name, target_size in applied_modes.items()
                ):
                    break
            for name, target_size in applied_modes.items():
                updated = by_name.get(name)
                actual = (updated.get("width"), updated.get("height")) if updated else None
                if actual != target_size:
                    had_rejection = True
                    print(
                        f"Hyprland rejected mode {target_size[0]}x{target_size[1]} for {name} "
                        f"(kept {actual}); waiting for DRM mode change",
                        file=sys.stderr,
                        flush=True,
                    )
                    if rejected_modes is not None:
                        rejected_modes[name] = target_size
                        active_drm_modes.pop(name, None)
        if layout is None:
            return not had_rejection
        positions = hyprland_desired_positions(layout, monitors)
        if positions is None:
            return not had_rejection
        if dry_run:
            print(f"Parallels layout: {positions}", flush=True)
            return not had_rejection
        if all(
            by_name[name].get("x") == x and by_name[name].get("y") == 0
            for name, x in positions.items()
        ):
            return not had_rejection
        for name, x in positions.items():
            monitor = by_name[name]
            mode = hyprland_mode_spec(monitor, active_drm_modes.get(name))
            scale = monitor["scale"]
            transform = monitor.get("transform", 0)
            rule = f"{name},{mode},{x}x0,{scale:g}"
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
        return not had_rejection
    except (json.JSONDecodeError, OSError, subprocess.SubprocessError) as error:
        print(f"Could not apply Parallels layout: {error}", file=sys.stderr, flush=True)
        return False


def apply_layout(
    layout,
    niri_bin,
    dry_run=False,
    hyprctl_bin=None,
    drm_root=DRM_ROOT,
    rejected_modes=None,
):
    if is_hyprland_session():
        return apply_hyprland_layout(
            layout,
            hyprctl_bin or os.environ.get("HYPRCTL_BIN", "hyprctl"),
            dry_run,
            drm_root=drm_root,
            rejected_modes=rejected_modes,
        )
    return apply_niri_layout(layout, niri_bin, dry_run)


def enqueue_lines(stream, events):
    for line in stream:
        if "new heads config" in line or "Dynamic Resolution:  head " in line:
            events.put(line)
    events.put(None)


def enqueue_drm_events(stream, events):
    for line in stream:
        if "change" in line and "/drm/" in line:
            events.put(DRM_EVENT)


def main():
    args = argparse.ArgumentParser(description=__doc__)
    args.add_argument("--log", type=Path, default=Path("/var/log/parallels.log"))
    args.add_argument("--drm-root", type=Path, default=DRM_ROOT)
    args.add_argument("--once", action="store_true")
    args.add_argument("--dry-run", action="store_true")
    options = args.parse_args()

    niri_bin = os.environ.get("NIRI_BIN", "niri")
    hyprctl_bin = os.environ.get("HYPRCTL_BIN", "hyprctl")
    udevadm_bin = os.environ.get("UDEVADM_BIN", "udevadm")
    rejected_modes = {}
    if options.once:
        layout = read_layout(options.log).latest
        return (
            0
            if apply_layout(
                layout,
                niri_bin,
                options.dry_run,
                hyprctl_bin,
                drm_root=options.drm_root,
                rejected_modes=rejected_modes,
            )
            else 1
        )

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

    if is_hyprland_session():
        try:
            udev = subprocess.Popen(
                [udevadm_bin, "monitor", "--udev", "--subsystem-match=drm"],
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
                bufsize=1,
            )
            threading.Thread(
                target=enqueue_drm_events, args=(udev.stdout, events), daemon=True
            ).start()
        except OSError as error:
            print(f"Could not watch DRM uevents: {error}", file=sys.stderr, flush=True)

    layout = read_layout(options.log)
    apply_layout(
        layout.latest,
        niri_bin,
        hyprctl_bin=hyprctl_bin,
        drm_root=options.drm_root,
        rejected_modes=rejected_modes,
    )
    while True:
        try:
            item = events.get(timeout=5)
        except queue.Empty:
            apply_layout(
                layout.latest,
                niri_bin,
                hyprctl_bin=hyprctl_bin,
                drm_root=options.drm_root,
                rejected_modes=rejected_modes,
            )
            continue
        if item is None:
            return 1
        if item is DRM_EVENT:
            time.sleep(0.2)
            while True:
                try:
                    queued = events.get_nowait()
                except queue.Empty:
                    break
                if queued is None:
                    return 1
                if queued is not DRM_EVENT:
                    layout.feed(queued)
            apply_layout(
                layout.latest,
                niri_bin,
                hyprctl_bin=hyprctl_bin,
                drm_root=options.drm_root,
                rejected_modes=rejected_modes,
            )
            continue
        if layout.feed(item) or CONFIG.search(item):
            apply_layout(
                layout.latest,
                niri_bin,
                hyprctl_bin=hyprctl_bin,
                drm_root=options.drm_root,
                rejected_modes=rejected_modes,
            )
if __name__ == "__main__":
    raise SystemExit(main())
