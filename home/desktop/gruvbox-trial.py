#!/usr/bin/env python3
"""A reversible Noctalia, GTK and Ghostty appearance trial."""

import argparse
import base64
import fcntl
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import tomllib


KEYS = ("theme.source", "theme.builtin", "theme.mode", "theme.shell_mode",
        "wallpaper.automation.enabled")
OUTPUTS = {"Virtual-1": "center", "Virtual-2": "portrait", "Virtual-3": "portrait"}


def ipc(*args):
    result = subprocess.run(["noctalia", "msg", *args], check=True,
                            capture_output=True, text=True, timeout=15).stdout.strip()
    if result.startswith("error:"):
        raise RuntimeError(result)
    return result


def appearance():
    return {key: tomllib.loads("value = " + ipc("config-get", key))["value"]
            for key in KEYS}


def file_state(path):
    if path.is_symlink():
        return {"link": os.readlink(path)}
    if path.exists():
        return {"data": base64.b64encode(path.read_bytes()).decode(),
                "mode": stat.S_IMODE(path.stat().st_mode)}
    return None


def atomic_write(path, data, mode=0o600):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(dir=path.parent, prefix=".gruvbox-")
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


def restore_file(path, original):
    if original is None:
        path.unlink(missing_ok=True)
    elif "link" in original:
        with tempfile.TemporaryDirectory(dir=path.parent, prefix=".gruvbox-restore-") as directory:
            temporary = Path(directory) / "link"
            temporary.symlink_to(original["link"])
            os.replace(temporary, path)
    else:
        atomic_write(path, base64.b64decode(original["data"]), original["mode"])


def css(mode):
    bg, base, fg, accent, on_accent, error = (
        ("#282828", "#3c3836", "#ebdbb2", "#b8bb26", "#282828", "#fb4934")
        if mode == "dark" else
        ("#fbf1c7", "#ebdbb2", "#3c3836", "#79740e", "#fbf1c7", "#9d0006"))
    colors = {
        "theme_bg_color": bg, "theme_base_color": base, "theme_fg_color": fg,
        "theme_text_color": fg, "theme_selected_bg_color": accent,
        "theme_selected_fg_color": on_accent, "borders": "#928374",
        "window_bg_color": bg, "window_fg_color": fg,
        "view_bg_color": base, "view_fg_color": fg,
        "headerbar_bg_color": base, "headerbar_fg_color": fg,
        "card_bg_color": base, "card_fg_color": fg,
        "dialog_bg_color": bg, "dialog_fg_color": fg,
        "popover_bg_color": base, "popover_fg_color": fg,
        "sidebar_bg_color": base, "sidebar_fg_color": fg,
        "accent_color": accent, "accent_bg_color": accent,
        "accent_fg_color": on_accent, "error_color": error,
    }
    return "\n".join(f"@define-color {key} {value};" for key, value in colors.items()) + "\n"


def render_wallpapers(source, destination):
    from PIL import Image, ImageEnhance, ImageOps

    destination.mkdir(parents=True, exist_ok=True)
    for mode, images in {
        "dark": {"center": "fuji-pagoda-sunset.jpg", "portrait": "atake-sudden-shower.jpg"},
        "light": {"center": "blue-jays.png", "portrait": "kameido-plum-park.jpg"},
    }.items():
        for slot, name in images.items():
            image = Image.open(source / name).convert("RGB")
            image = ImageEnhance.Color(image).enhance(0.65)
            warm = ImageOps.colorize(ImageOps.grayscale(image), "#282828", "#ebdbb2")
            image = Image.blend(image, warm, 0.45)
            image = ImageEnhance.Brightness(image).enhance(0.82 if mode == "dark" else 1.08)
            image.save(destination / f"{slot}-{mode}.jpg", quality=94)


class Trial:
    def __init__(self, config, state, wallpapers):
        self.config = config
        self.snapshot = state / "snapshot.json"
        self.wallpapers = wallpapers

    def save(self, snapshot):
        atomic_write(self.snapshot, json.dumps(snapshot, indent=2).encode())

    def current(self):
        return {"shell": appearance(),
                "wallpapers": {output: ipc("wallpaper-get", output) for output in OUTPUTS}}

    def check(self, snapshot):
        conflicts = []
        for name, record in snapshot["files"].items():
            if file_state(self.config / name) not in (record["original"], record["applied"],
                                                     record.get("previous")):
                conflicts.append(name)
        current = self.current()
        for section in ("shell", "wallpapers"):
            for key, value in current[section].items():
                if value not in (snapshot["original"][section][key], snapshot["applied"][section][key],
                                 snapshot.get("previous", snapshot["original"])[section][key]):
                    conflicts.append(key)
        if conflicts:
            raise RuntimeError("Changed outside the trial; not overwriting: " + ", ".join(conflicts))

    def apply(self, mode):
        outputs = json.loads(subprocess.run(["niri", "msg", "--json", "outputs"],
                             check=True, capture_output=True, text=True, timeout=15).stdout)
        if not all(outputs.get(output, {}).get("logical") for output in OUTPUTS):
            raise RuntimeError("This trial needs the three active Virtual-1/2/3 displays on prl-dev-vm")
        if self.snapshot.exists():
            snapshot = json.loads(self.snapshot.read_text())
            self.check(snapshot)
        else:
            original = self.current()
            snapshot = {"original": original, "applied": original, "files": {}}
        updates = {}
        ghostty = "ghostty/config"
        record = snapshot["files"].get(ghostty)
        original = record["original"] if record else file_state(self.config / ghostty)
        if original is None:
            raise RuntimeError("No existing Ghostty configuration")
        content = ((self.config / ghostty).parent.joinpath(original["link"]).read_text() if "link" in original
                   else base64.b64decode(original["data"]).decode())
        updates[ghostty] = content + "\n# Gruvbox trial\ntheme = light:Gruvbox Light,dark:Gruvbox Dark\n"
        for version in ("3.0", "4.0"):
            name = f"gtk-{version}/gtk.css"
            record = snapshot["files"].get(name)
            original = record["original"] if record else file_state(self.config / name)
            content = ((self.config / name).parent.joinpath(original["link"]).read_text() if original and "link" in original
                       else base64.b64decode(original["data"]).decode() if original else "")
            updates[name] = content + "\n/* Gruvbox trial */\n" + css(mode)
        desired = {"shell": {"theme.source": "builtin", "theme.builtin": "Gruvbox",
                              "theme.mode": mode, "theme.shell_mode": "follow",
                              "wallpaper.automation.enabled": False},
                   "wallpapers": {output: str(self.wallpapers / f"{slot}-{mode}.jpg")
                                  for output, slot in OUTPUTS.items()}}
        for path in desired["wallpapers"].values():
            if not Path(path).is_file():
                raise RuntimeError("Missing trial wallpaper: " + path)
        snapshot["previous"] = snapshot["applied"]
        snapshot["applied"] = desired
        for name, content in updates.items():
            record = snapshot["files"].setdefault(name, {"original": file_state(self.config / name)})
            record["previous"] = record.get("applied", record["original"])
            record["applied"] = {"data": base64.b64encode(content.encode()).decode(), "mode": 0o600}
        self.save(snapshot)  # Keep recovery information before any desktop mutation.
        for name, content in updates.items():
            atomic_write(self.config / name, content.encode())
        self.set_appearance(desired)
        self.reload_ghostty()
        print(f"Gruvbox {mode} applied: shell, GTK, Ghostty and all three wallpapers.")
        print("Reopen GTK apps if needed. Restore with: gruvbox-trial restore")

    def set_appearance(self, values):
        for key, value in values["shell"].items():
            ipc("config-set", key, json.dumps(value))
        for output, path in values["wallpapers"].items():
            ipc("wallpaper-set", output, path)
        if self.current() != values:
            raise RuntimeError("Desktop readback differs from requested appearance; snapshot retained")

    def reload_ghostty(self):
        result = subprocess.run([
            "gdbus", "call", "--session", "--dest", "com.mitchellh.ghostty",
            "--object-path", "/com/mitchellh/ghostty", "--method", "org.gtk.Actions.Activate",
            "reload-config", "[]", "{}"], capture_output=True, timeout=15)
        if result.returncode:
            print("Ghostty: reopen or press Ctrl+Shift+, to reload its palette.")

    def restore(self):
        if not self.snapshot.exists():
            print("No active Gruvbox trial.")
            return
        snapshot = json.loads(self.snapshot.read_text())
        self.check(snapshot)
        self.set_appearance(snapshot["original"])
        for name, record in snapshot["files"].items():
            restore_file(self.config / name, record["original"])
        self.reload_ghostty()
        self.snapshot.unlink()
        print("Pre-trial appearance restored.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("dark", "light", "restore", "render"))
    parser.add_argument("--wallpapers", type=Path, required=True)
    parser.add_argument("--source", type=Path)
    args = parser.parse_args()
    if args.action == "render":
        render_wallpapers(args.source, args.wallpapers)
        return
    config = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config"))
    state = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state")) / "gruvbox-trial"
    state.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (state / "lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        trial = Trial(config, state, args.wallpapers)
        if args.action == "restore":
            trial.restore()
        else:
            trial.apply(args.action)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, subprocess.SubprocessError, ValueError) as error:
        sys.exit(f"Gruvbox trial: {error}")
